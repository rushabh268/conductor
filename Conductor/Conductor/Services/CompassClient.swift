import CryptoKit
import Darwin
import Foundation

// This client knows only the separate reader credential and an explicitly chosen
// local socket. It never discovers auth.key, starts services, or installs hooks.
struct CompassClient: Sendable {
    let connection: CompassConnection
    private let timeout: TimeInterval
    private let snapshots = CompassSnapshotState()

    init(connection: CompassConnection, timeout: TimeInterval = 3) {
        self.connection = connection
        self.timeout = min(max(timeout, 0.01), 5)
    }

    func health() async throws -> CompassHealth {
        let health: CompassHealth = try await call("health", params: Data("{}".utf8))
        guard health.ok, health.capabilities?.readerRole == true, health.capabilities?.sessionEvidence == 1 else {
            throw CompassClientError.incompatible
        }
        return health
    }

    func begin(for session: Session) async throws -> CompassEvidencePage {
        guard let selector = CompassEvidenceSelector(session: session) else {
            return CompassEvidencePage(state: "unavailable", reason: "The native source has not established this session's root relationship.")
        }
        _ = try await health()
        let page: CompassEvidencePage = try await call("beginSessionEvidence", params: JSONEncoder().encode(selector))
        try await snapshots.accept(page, previous: nil)
        return page
    }

    func next(cursor: String) async throws -> CompassEvidencePage {
        guard let previous = await snapshots.snapshot(for: cursor) else { return CompassEvidencePage(state: "stale") }
        _ = try await health()
        struct Params: Encodable { let version = 1; let cursor: String }
        let page: CompassEvidencePage = try await call("continueSessionEvidence", params: JSONEncoder().encode(Params(cursor: cursor)))
        try await snapshots.accept(page, previous: previous)
        return page
    }

    private func call<Result: Decodable & Sendable>(_ method: String, params: Data) async throws -> Result {
        try Task.checkCancellation()
        try await snapshots.reserveRequest()
        do {
            let result: Result = try await transport(method, params: params)
            await snapshots.finishRequest()
            return result
        } catch {
            await snapshots.finishRequest()
            throw error
        }
    }

    private func transport<Result: Decodable & Sendable>(_ method: String, params: Data) async throws -> Result {
        let cancellation = CompassCancellation()
        let connection = connection, timeout = timeout, id = UUID().uuidString
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try cancellation.check()
                        var key = try CompassCredentials.read(connection.readerKeyPath)
                        defer { key.resetBytes(in: key.startIndex..<key.endIndex) }
                        let request = try CompassWire.request(id: id, method: method, params: params, key: key)
                        let data = try CompassSocket.exchange(connection.socketPath, request: request, timeout: timeout, cancellation: cancellation)
                        try cancellation.check()
                        let result: Result = try CompassWire.response(data, expectedID: id)
                        continuation.resume(returning: result)
                    } catch is CancellationError {
                        continuation.resume(throwing: CancellationError())
                    } catch let error as CompassClientError {
                        continuation.resume(throwing: error)
                    } catch {
                        continuation.resume(throwing: CompassClientError.invalidResponse)
                    }
                }
            }
        } onCancel: { cancellation.cancel() }
    }
}

enum CompassClientError: Error, LocalizedError, Sendable, Equatable {
    case invalidConnection, invalidCredential, disconnected, incompatible, timeout, invalidResponse, permissionDenied, resourceExhausted
    var errorDescription: String? {
        switch self {
        case .invalidConnection: "Choose an owner-only local Compass socket."
        case .invalidCredential: "Choose the separate owner-only Compass reader.key file."
        case .disconnected: "Compass is disconnected."
        case .incompatible: "This Compass service does not support reader evidence."
        case .timeout: "The Compass request timed out."
        case .invalidResponse: "Compass returned an invalid response."
        case .permissionDenied: "Compass rejected the reader credential or method."
        case .resourceExhausted: "Compass evidence is currently at its resource limit."
        }
    }
}

struct CompassFrameDecoder {
    static let maximumBytes = 1024 * 1024
    private var bytes = Data()
    private var bodyLength: Int?
    mutating func append(_ chunk: Data) throws -> Data? {
        guard bytes.count + chunk.count <= Self.maximumBytes + 4 else { throw CompassClientError.invalidResponse }
        bytes.append(chunk)
        if bodyLength == nil && bytes.count >= 4 {
            let length = bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0 && length <= Self.maximumBytes else { throw CompassClientError.invalidResponse }
            bodyLength = length
        }
        guard let length = bodyLength else { return nil }
        guard bytes.count <= length + 4 else { throw CompassClientError.invalidResponse }
        return bytes.count == length + 4 ? Data(bytes.dropFirst(4)) : nil
    }
}

enum CompassWire {
    static func request(id: String, method: String, params: Data, key: Data) throws -> Data {
        let value = try JSONSerialization.jsonObject(with: params)
        guard value is [String: Any], key.count >= 32 else { throw CompassClientError.invalidResponse }
        // Params contain only fixed ASCII keys, strings and integer version 1.
        // These options match JSON.stringify's escaping and recursively sorted keys.
        let unsigned: [String: Any] = ["version": 1, "id": id, "method": method, "params": value]
        let canonical = try JSONSerialization.data(withJSONObject: unsigned, options: [.sortedKeys, .withoutEscapingSlashes])
        let auth = HMAC<SHA256>.authenticationCode(for: canonical, using: SymmetricKey(data: key)).map { String(format: "%02x", $0) }.joined()
        // Node's frame fixture uses this insertion order. HMAC itself is canonical.
        let idJSON = try jsonString(id), methodJSON = try jsonString(method)
        let paramsJSON = try canonicalParamsInWireOrder(value)
        let body = Data("{\"version\":1,\"id\":\(idJSON),\"method\":\(methodJSON),\"params\":\(paramsJSON),\"auth\":\"\(auth)\"}".utf8)
        guard body.count <= CompassFrameDecoder.maximumBytes else { throw CompassClientError.invalidResponse }
        var length = UInt32(body.count).bigEndian
        var result = withUnsafeBytes(of: &length) { Data($0) }; result.append(body)
        return result
    }
    private static func jsonString(_ value: String) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    private static func canonicalParamsInWireOrder(_ value: Any) throws -> String {
        // The stable synthetic fixture's order is version/platform/rootSessionID/subject.
        // Other orderings are equally valid RPC v1; signatures always use sorted keys.
        guard let object = value as? [String: Any] else { throw CompassClientError.invalidResponse }
        let order = ["version", "platform", "rootSessionID", "subject", "cursor"]
        guard object.keys.allSatisfy({ order.contains($0) }) else { throw CompassClientError.invalidResponse }
        return "{" + (try order.compactMap { key -> String? in
            guard let item = object[key] else { return nil }
            let encoded: String
            if key == "subject", let subject = item as? [String: String], let kind = subject["kind"], let nativeID = subject["nativeID"], subject.count == 2 {
                encoded = "{\"kind\":\(try jsonString(kind)),\"nativeID\":\(try jsonString(nativeID))}"
            } else {
                encoded = String(decoding: try JSONSerialization.data(withJSONObject: item, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
            }
            return "\(try jsonString(key)):\(encoded)"
        }).joined(separator: ",") + "}"
    }
    private struct Header: Decodable { let version: Int; let id: String }
    static func response<Result: Decodable>(_ data: Data, expectedID: String) throws -> Result {
        guard let header = try? JSONDecoder().decode(Header.self, from: data), header.version == 1, header.id == expectedID,
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(envelope.keys).isSubset(of: ["version", "id", "result", "error"]),
              envelope["version"] as? Int == 1, envelope["id"] as? String == expectedID,
              (envelope["result"] != nil) != (envelope["error"] != nil) else { throw CompassClientError.invalidResponse }
        if let error = envelope["error"] as? [String: Any] {
            guard Set(error.keys) == ["code", "message"], error["message"] is String, let code = error["code"] as? String else { throw CompassClientError.invalidResponse }
            switch code {
            case "UNAUTHENTICATED", "PERMISSION_DENIED": throw CompassClientError.permissionDenied
            case "NOT_FOUND": throw CompassClientError.incompatible
            case "RESOURCE_EXHAUSTED": throw CompassClientError.resourceExhausted
            default: throw CompassClientError.invalidResponse
            }
        }
        guard let result = envelope["result"], JSONSerialization.isValidJSONObject(result) else { throw CompassClientError.invalidResponse }
        let body = try JSONSerialization.data(withJSONObject: result)
        if Result.self == CompassEvidencePage.self && body.count > 64 * 1024 { throw CompassClientError.invalidResponse }
        do { return try JSONDecoder().decode(Result.self, from: body) }
        catch { throw CompassClientError.invalidResponse }
    }
}

private actor CompassSnapshotState {
    struct Snapshot: Sendable {
        let id: String
        let head: String
        let count: Int
        let expiresAt: Double
        let summary: CompassEvidenceSummary
        let relationship: String
        let groundingState: String
        let position: Int
        let eventIDs: Set<String>
        let cursor: String
    }
    private var cursors: [String: Snapshot] = [:]
    private var order: [String] = []
    private var requests = 0
    func reserveRequest() throws {
        guard requests < 4 else { throw CompassClientError.resourceExhausted }
        requests += 1
    }
    func finishRequest() { requests -= 1 }
    func snapshot(for cursor: String) -> Snapshot? {
        guard cursor.utf8.count <= 4096, let snapshot = cursors[cursor], snapshot.expiresAt > Date().timeIntervalSince1970 * 1000 else {
            cursors.removeValue(forKey: cursor); order.removeAll { $0 == cursor }; return nil
        }
        return snapshot
    }
    func accept(_ page: CompassEvidencePage, previous: Snapshot?) throws {
        guard page.version == 1, ["ready", "pending", "absent", "pruned", "unavailable", "resource_exhausted", "stale"].contains(page.state) else { throw CompassClientError.invalidResponse }
        guard page.state == "ready" else {
            guard page.events.isEmpty, page.nextCursor == nil else { throw CompassClientError.invalidResponse }
            if let previous { cursors.removeValue(forKey: previous.cursor); order.removeAll { $0 == previous.cursor } }
            return
        }
        guard let id = page.snapshotID, !id.isEmpty, id.utf8.count <= 1024,
              let head = page.head, head.count == 64, head.allSatisfy({ "0123456789abcdef".contains($0) }),
              let count = page.eventCount, count > 0, count <= 50000,
              let expiry = page.expiresAt, expiry.isFinite, expiry > Date().timeIntervalSince1970 * 1000,
              expiry <= Date().timeIntervalSince1970 * 1000 + 65000,
              let summary = page.summary, summary.events >= 0, summary.grounding >= 0,
              summary.events <= count, summary.grounding <= count, summary.events + summary.grounding == count,
              let relationship = page.relationship, ["self", "direct", "unknown"].contains(relationship),
              let grounding = page.groundingState, ["available", "unavailable"].contains(grounding),
              !page.events.isEmpty, page.events.count <= 50 else { throw CompassClientError.invalidResponse }
        var eventIDs = previous?.eventIDs ?? []
        for event in page.events {
            guard !event.eventID.isEmpty, event.eventID.utf8.count <= 1024,
                  !event.eventType.isEmpty, event.eventType.utf8.count <= 1024,
                  !event.timestamp.isEmpty, event.timestamp.utf8.count <= 128,
                  eventIDs.insert(event.eventID).inserted else { throw CompassClientError.invalidResponse }
        }
        let position = (previous?.position ?? 0) + page.events.count
        guard position <= count, (page.nextCursor == nil) == (position == count) else { throw CompassClientError.invalidResponse }
        if let previous {
            guard previous.id == id, previous.head == head, previous.count == count, previous.expiresAt == expiry,
                  previous.summary == summary, previous.relationship == relationship, previous.groundingState == grounding,
                  page.nextCursor != previous.cursor else { throw CompassClientError.invalidResponse }
            cursors.removeValue(forKey: previous.cursor); order.removeAll { $0 == previous.cursor }
        }
        if let cursor = page.nextCursor {
            guard !cursor.isEmpty, cursor.utf8.count <= 4096 else { throw CompassClientError.invalidResponse }
            order.removeAll { $0 == cursor }
            cursors[cursor] = Snapshot(id: id, head: head, count: count, expiresAt: expiry, summary: summary, relationship: relationship, groundingState: grounding, position: position, eventIDs: eventIDs, cursor: cursor)
            order.append(cursor)
            while order.count > 8 { cursors.removeValue(forKey: order.removeFirst()) }
        }
    }
}

enum CompassCredentials {
    static func read(_ path: String) throws -> Data {
        let error = CompassClientError.invalidCredential
        guard URL(fileURLWithPath: path).lastPathComponent == "reader.key" else { throw error }
        let before = try CompassLocalPath.inspect(path, error: error)
        guard valid(before), try CompassLocalPath.privateParent(path, error: error) else { throw error }
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw error }; defer { Darwin.close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, valid(opened), before.st_dev == opened.st_dev, before.st_ino == opened.st_ino else { throw error }
        var data = Data(), chunk = [UInt8](repeating: 0, count: 4097)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 { if errno == EINTR { continue }; throw error }
            if count == 0 { break }
            guard data.count + count <= 4096 else { throw error }
            data.append(contentsOf: chunk.prefix(count))
        }
        let after = try CompassLocalPath.inspect(path, error: error)
        guard data.count >= 32, valid(after), after.st_dev == opened.st_dev, after.st_ino == opened.st_ino else { throw error }
        return data
    }
    private static func valid(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == geteuid() && (info.st_mode & 0o777) == 0o600 && info.st_nlink == 1 && info.st_size >= 32 && info.st_size <= 4096
    }
}

private enum CompassLocalPath {
    static func inspect(_ path: String, error: CompassClientError, missingError: CompassClientError? = nil) throws -> stat {
        guard path.hasPrefix("/"), path.utf8.count <= 4096,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !path.contains("//"), !path.hasSuffix("/"), path.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }) else { throw error }
        var current = "", info = stat()
        for part in path.split(separator: "/") {
            current += "/" + part
            guard lstat(current, &info) == 0 else { throw errno == ENOENT ? missingError ?? error : error }
            guard (info.st_mode & S_IFMT) != S_IFLNK else { throw error }
        }
        return info
    }
    static func privateParent(_ path: String, error: CompassClientError) throws -> Bool {
        let parent = try inspect(URL(fileURLWithPath: path).deletingLastPathComponent().path, error: error)
        return (parent.st_mode & S_IFMT) == S_IFDIR && parent.st_uid == geteuid() && (parent.st_mode & 0o777) == 0o700
    }
}

private final class CompassCancellation: @unchecked Sendable {
    // shutdown wakes polling I/O; only the worker closes the descriptor, avoiding
    // descriptor reuse races between cancellation and a later unrelated socket.
    private let lock = NSLock()
    private var cancelled = false
    private var descriptor: Int32 = -1
    func register(_ fd: Int32) throws {
        try lock.withLock {
            if cancelled { throw CancellationError() }
            descriptor = fd
        }
    }
    func release(_ fd: Int32) {
        lock.withLock { if descriptor == fd { descriptor = -1 } }
        Darwin.close(fd)
    }
    func cancel() {
        lock.withLock {
            cancelled = true
            if descriptor >= 0 { _ = Darwin.shutdown(descriptor, SHUT_RDWR) }
        }
    }
    func check() throws { if lock.withLock({ cancelled }) { throw CancellationError() } }
}

private enum CompassSocket {
    static func exchange(_ path: String, request: Data, timeout: TimeInterval, cancellation: CompassCancellation) throws -> Data {
        var address = sockaddr_un()
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw CompassClientError.invalidConnection }
        let before = try CompassLocalPath.inspect(path, error: .invalidConnection, missingError: .disconnected)
        guard (before.st_mode & S_IFMT) == S_IFSOCK, before.st_uid == geteuid(), before.st_nlink == 1,
              (before.st_mode & 0o777) == 0o600, try CompassLocalPath.privateParent(path, error: .invalidConnection) else { throw CompassClientError.invalidConnection }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CompassClientError.disconnected }
        defer { cancellation.release(fd) }
        try cancellation.register(fd)
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw CompassClientError.disconnected }
        var noPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout.size(ofValue: noPipe)))
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: path.utf8)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if connected != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { throw CompassClientError.disconnected }
            try wait(fd, events: Int16(POLLOUT), deadline: deadline, cancellation: cancellation)
            var failure: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &size) == 0, failure == 0 else { throw CompassClientError.disconnected }
        }
        let after = try CompassLocalPath.inspect(path, error: .invalidConnection)
        guard before.st_dev == after.st_dev, before.st_ino == after.st_ino else { throw CompassClientError.invalidConnection }
        var sent = 0
        while sent < request.count {
            try wait(fd, events: Int16(POLLOUT), deadline: deadline, cancellation: cancellation)
            let count = request.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: sent), $0.count - sent, 0) }
            if count < 0 { if errno == EINTR || errno == EAGAIN { continue }; throw CompassClientError.disconnected }
            guard count > 0 else { throw CompassClientError.disconnected }
            sent += count
        }
        var decoder = CompassFrameDecoder(), buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            try wait(fd, events: Int16(POLLIN), deadline: deadline, cancellation: cancellation)
            let count = buffer.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
            if count < 0 { if errno == EINTR || errno == EAGAIN { continue }; throw CompassClientError.disconnected }
            guard count > 0 else { throw CompassClientError.disconnected }
            if let body = try decoder.append(Data(buffer.prefix(count))) { return body }
        }
    }
    private static func wait(_ fd: Int32, events: Int16, deadline: TimeInterval, cancellation: CompassCancellation) throws {
        while true {
            try cancellation.check()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw CompassClientError.timeout }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = Darwin.poll(&descriptor, 1, Int32(min(50, max(1, remaining * 1000))))
            try cancellation.check()
            if result < 0 { if errno == EINTR { continue }; throw CompassClientError.disconnected }
            if result > 0 {
                if descriptor.revents & events != 0 { return }
                if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { throw CompassClientError.disconnected }
            }
        }
    }
}
