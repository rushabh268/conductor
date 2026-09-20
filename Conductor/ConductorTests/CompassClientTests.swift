import Foundation
import Testing
@testable import Conductor

private final class CompassFixtureBundle: NSObject {}

@Test func compassGoldenRequestsMatchNodeAndEveryFrameBoundary() throws {
    #if SWIFT_PACKAGE
    let bundle = Bundle.module
    #else
    let bundle = Bundle(for: CompassFixtureBundle.self)
    #endif
    let url = try #require(bundle.url(forResource: "compass-protocol-v1", withExtension: "json"))
    let fixture = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let readerKey = Data(repeating: 0x42, count: 32)
    let entries = try #require(fixture["requests"] as? [[String: Any]])
    for entry in entries {
        let request = try #require(entry["request"] as? [String: Any])
        let params = try JSONSerialization.data(withJSONObject: #require(request["params"]))
        let frame = try CompassWire.request(id: #require(request["id"] as? String), method: "beginSessionEvidence", params: params, key: readerKey)
        #expect(frame.map { String(format: "%02x", $0) }.joined() == entry["frameHex"] as? String)
        for split in 1..<frame.count {
            var decoder = CompassFrameDecoder()
            #expect(try decoder.append(frame.prefix(split)) == nil)
            let completed = try decoder.append(frame.dropFirst(split))
            let body = try #require(completed)
            let decoded = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(decoded["auth"] as? String == request["auth"] as? String)
        }
    }
}

@Test func compassFrameDecoderRejectsOversizeZeroAndTrailingBytes() throws {
    for bytes in [Data([0, 0, 0, 0]), Data([0, 16, 0, 1]), Data([0, 0, 0, 1, 65, 66])] {
        var decoder = CompassFrameDecoder()
        #expect(throws: CompassClientError.self) { try decoder.append(bytes) }
    }
}

private func compassSession(_ source: SessionSource, role: SessionRole = .main, root: String? = nil) -> Session {
    var session = Session(id: "local", source: source, sessionType: .coding, name: nil, cwd: nil, project: nil, gitBranch: nil, ticketId: nil, status: nil, model: nil, version: nil, messageCount: 0, toolCallCount: 0, tokensUsed: 0, inputTokens: 0, outputTokens: 0, startedAt: Date(), endedAt: nil, isExplicitlyNamed: false, cacheReadTokens: 0, cacheCreationTokens: 0)
    session.nativeID = role == .main ? "synthetic-root" : "synthetic-child"
    session.role = role; session.rootNativeID = root
    return session
}

@Test func compassSelectorsSeparateRootRunAndChildSubject() throws {
    for source in SessionSource.allCases {
        let main = try #require(CompassEvidenceSelector(session: compassSession(source)))
        #expect(main.rootSessionID == "synthetic-root")
        let child = try #require(CompassEvidenceSelector(session: compassSession(source, role: .child, root: "synthetic-root")))
        #expect(child.rootSessionID == "synthetic-root")
        #expect(child.subject.nativeID == "synthetic-child")
        #expect(child.subject.kind == (source == .opencode ? "session" : "agent"))
        #expect(CompassEvidenceSelector(session: compassSession(source, role: .child)) == nil)
        #expect(CompassEvidenceSelector(session: compassSession(source, role: .unknown)) == nil)
    }
}

import Darwin

private struct CompassClientFixture {
    let root: URL
    let connection: CompassConnection
    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/cc-" + UUID().uuidString.prefix(12))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let key = root.appendingPathComponent("reader.key")
        try Data(repeating: 0x42, count: 32).write(to: key)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
        connection = CompassConnection(socketPath: root.appendingPathComponent("rpc").path, readerKeyPath: key.path)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private func compassReply(_ request: Data, result: [String: Any], idOverride: String? = nil) throws -> Data {
    let object = try #require(JSONSerialization.jsonObject(with: request) as? [String: Any])
    let id = try #require(object["id"] as? String)
    let body = try JSONSerialization.data(withJSONObject: ["version": 1, "id": idOverride ?? id, "result": result])
    var length = UInt32(body.count).bigEndian
    var frame = withUnsafeBytes(of: &length) { Data($0) }; frame.append(body)
    return frame
}
private func compassReady(snapshot: String = "snapshot", head: String = String(repeating: "a", count: 64), expiry: Double, eventID: String = "event-1", count: Int = 1, cursor: String? = nil) -> [String: Any] {
    ["version": 1, "state": "ready", "snapshotID": snapshot, "head": head, "eventCount": count,
     "expiresAt": expiry, "summary": ["events": count, "grounding": 0],
     "relationship": "self", "groundingState": "available",
     "events": [["eventID": eventID, "eventType": "SessionStart", "timestamp": "2026-09-20T00:00:00.000Z"]],
     "nextCursor": cursor as Any? ?? NSNull()]
}

private final class CompassMockServer: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var clients = Set<Int32>()
    private var received: [Data] = []
    private let listener: Int32
    private let handler: @Sendable (Data) throws -> Data?
    private let fragmentSize: Int
    var requests: [Data] { lock.withLock { received } }
    init(path: String, fragmentSize: Int = 16384, handler: @escaping @Sendable (Data) throws -> Data?) throws {
        self.handler = handler; self.fragmentSize = fragmentSize
        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw CompassClientError.disconnected }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in buffer.initializeMemory(as: UInt8.self, repeating: 0); buffer.copyBytes(from: path.utf8) }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, Darwin.listen(listener, 8) == 0 else { Darwin.close(listener); throw CompassClientError.disconnected }
        _ = chmod(path, 0o600)
        DispatchQueue.global().async { [self] in serve() }
    }
    func stop() {
        lock.withLock {
            stopped = true
            _ = Darwin.shutdown(listener, SHUT_RDWR)
            for fd in clients { _ = Darwin.shutdown(fd, SHUT_RDWR) }
        }
    }
    private func serve() {
        defer { Darwin.close(listener) }
        while !lock.withLock({ stopped }) {
            var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&poller, 1, 50) > 0 else { continue }
            if lock.withLock({ stopped }) { break }
            let fd = Darwin.accept(listener, nil, nil)
            if fd < 0 { continue }
            lock.withLock { _ = clients.insert(fd) }
            process(fd)
            lock.withLock { _ = clients.remove(fd) }
            Darwin.close(fd)
        }
    }
    private func process(_ fd: Int32) {
        var noPipe: Int32 = 1; _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var decoder = CompassFrameDecoder(), buffer = [UInt8](repeating: 0, count: 4096)
        while !lock.withLock({ stopped }), ProcessInfo.processInfo.systemUptime < deadline {
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&poller, 1, 50) > 0 else { continue }
            let count = buffer.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
            if count <= 0 { return }
            do {
                guard let request = try decoder.append(Data(buffer.prefix(count))) else { continue }
                lock.withLock { received.append(request) }
                guard let response = try handler(request) else {
                    while !lock.withLock({ stopped }), ProcessInfo.processInfo.systemUptime < deadline {
                        var waiting = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                        if Darwin.poll(&waiting, 1, 50) > 0 { return }
                    }
                    return
                }
                var offset = 0
                while offset < response.count {
                    let count = response.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: offset), min(fragmentSize, response.count - offset), 0) }
                    if count <= 0 { return }; offset += count
                }
                return
            } catch { return }
        }
    }
}

@Test func compassCredentialValidationNeverFallsBackToWriterKey() throws {
    let fixture = try CompassClientFixture(); defer { fixture.remove() }
    let key = fixture.connection.readerKeyPath
    #expect(try CompassCredentials.read(key) == Data(repeating: 0x42, count: 32))
    let writer = fixture.root.appendingPathComponent("auth.key").path
    try FileManager.default.copyItem(atPath: key, toPath: writer)
    #expect(throws: CompassClientError.invalidCredential) { try CompassCredentials.read(writer) }
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: key)
    #expect(throws: CompassClientError.invalidCredential) { try CompassCredentials.read(key) }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key)
    let extra = fixture.root.appendingPathComponent("extra").path
    #expect(Darwin.link(key, extra) == 0)
    #expect(throws: CompassClientError.invalidCredential) { try CompassCredentials.read(key) }
    try FileManager.default.removeItem(atPath: extra)
    try FileManager.default.removeItem(atPath: key)
    try FileManager.default.createSymbolicLink(atPath: key, withDestinationPath: writer)
    #expect(throws: CompassClientError.invalidCredential) { try CompassCredentials.read(key) }
    #expect(throws: CompassClientError.invalidCredential) { try CompassCredentials.read("relative/reader.key") }
    #expect(throws: CompassClientError.invalidCredential) { try CompassCredentials.read(key + "\n") }
}

@Test func compassReaderHandshakeAndFragmentedPagesUseFreshIDs() async throws {
    let fixture = try CompassClientFixture(); defer { fixture.remove() }
    let expiry = Date().timeIntervalSince1970 * 1000 + 60000
    let server = try CompassMockServer(path: fixture.connection.socketPath, fragmentSize: 1) { request in
        let object = try #require(JSONSerialization.jsonObject(with: request) as? [String: Any])
        switch object["method"] as? String {
        case "health": return try compassReply(request, result: ["ok": true, "capabilities": ["readerRole": true, "sessionEvidence": 1]])
        case "beginSessionEvidence": return try compassReply(request, result: compassReady(expiry: expiry, count: 2, cursor: "next"))
        default: return try compassReply(request, result: compassReady(expiry: expiry, eventID: "event-2", count: 2))
        }
    }
    defer { server.stop() }
    let client = CompassClient(connection: fixture.connection)
    let first = try await client.begin(for: compassSession(.claude))
    #expect(first.state == "ready"); #expect(first.events.count == 1)
    let next = try await client.next(cursor: #require(first.nextCursor))
    #expect(next.snapshotID == first.snapshotID); #expect(next.events.first?.eventID == "event-2")
    let ids = try server.requests.map { try #require((JSONSerialization.jsonObject(with: $0) as? [String: Any])?["id"] as? String) }
    #expect(ids.count == 4); #expect(Set(ids).count == ids.count)
    #expect(try await client.next(cursor: "unissued").state == "stale")
}

@Test func compassUnknownChildDoesNotContactService() async throws {
    let connection = CompassConnection(socketPath: "/unavailable", readerKeyPath: "/unavailable/reader.key")
    let page = try await CompassClient(connection: connection).begin(for: compassSession(.opencode, role: .child))
    #expect(page.state == "unavailable"); #expect(page.reason != nil)
}

@Test func compassClientTimeoutAndCancellationCloseStalledTransport() async throws {
    let fixture = try CompassClientFixture(); defer { fixture.remove() }
    let server = try CompassMockServer(path: fixture.connection.socketPath) { _ in nil }; defer { server.stop() }
    let limited = CompassClient(connection: fixture.connection, timeout: 0.05)
    await #expect(throws: CompassClientError.timeout) { try await limited.health() }
    let client = CompassClient(connection: fixture.connection)
    let task = Task { try await client.health() }
    let deadline = ContinuousClock.now + .seconds(1)
    while server.requests.count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    #expect(server.requests.count == 2)
    let started = ContinuousClock.now; task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(ContinuousClock.now - started < .milliseconds(250))
}

@Test func compassWireRejectsMalformedVersionIDAndErrors() throws {
    for text in ["{", "{\"version\":true,\"id\":\"expected\",\"result\":{\"ok\":true}}", "{\"version\":2,\"id\":\"expected\",\"result\":{\"ok\":true}}", "{\"version\":1,\"id\":\"wrong\",\"result\":{\"ok\":true}}", "{\"version\":1,\"id\":\"expected\",\"result\":{\"ok\":true},\"error\":{}}"] {
        #expect(throws: CompassClientError.invalidResponse) { let _: CompassHealth = try CompassWire.response(Data(text.utf8), expectedID: "expected") }
    }
    let rejected = Data("{\"version\":1,\"id\":\"expected\",\"error\":{\"code\":\"PERMISSION_DENIED\",\"message\":\"private sentinel\"}}".utf8)
    #expect(throws: CompassClientError.permissionDenied) { let _: CompassHealth = try CompassWire.response(rejected, expectedID: "expected") }
    #expect(!CompassClientError.permissionDenied.localizedDescription.contains("private sentinel"))
}

@Test func compassHandshakeRejectsLegacyServerAndUnsafeSocket() async throws {
    let fixture = try CompassClientFixture(); defer { fixture.remove() }
    let server = try CompassMockServer(path: fixture.connection.socketPath) { try compassReply($0, result: ["ok": true]) }; defer { server.stop() }
    await #expect(throws: CompassClientError.incompatible) { try await CompassClient(connection: fixture.connection).health() }
    try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: fixture.connection.socketPath)
    await #expect(throws: CompassClientError.invalidConnection) { try await CompassClient(connection: fixture.connection).health() }
    for path in ["relative.sock", "/" + String(repeating: "x", count: 104), fixture.connection.socketPath + "\n"] {
        let connection = CompassConnection(socketPath: path, readerKeyPath: fixture.connection.readerKeyPath)
        await #expect(throws: CompassClientError.invalidConnection) { try await CompassClient(connection: connection).health() }
    }
    let missing = CompassConnection(socketPath: fixture.root.appendingPathComponent("missing").path, readerKeyPath: fixture.connection.readerKeyPath)
    await #expect(throws: CompassClientError.disconnected) { try await CompassClient(connection: missing).health() }
}

@Test func compassRejectsChangedSnapshotAndDuplicateEvents() async throws {
    for corruptHead in [true, false] {
        let fixture = try CompassClientFixture(); defer { fixture.remove() }
        let expiry = Date().timeIntervalSince1970 * 1000 + 60000
        let server = try CompassMockServer(path: fixture.connection.socketPath) { request in
            let object = try #require(JSONSerialization.jsonObject(with: request) as? [String: Any])
            if object["method"] as? String == "health" { return try compassReply(request, result: ["ok": true, "capabilities": ["readerRole": true, "sessionEvidence": 1]]) }
            if object["method"] as? String == "beginSessionEvidence" { return try compassReply(request, result: compassReady(expiry: expiry, count: 2, cursor: "next")) }
            return try compassReply(request, result: compassReady(head: String(repeating: corruptHead ? "b" : "a", count: 64), expiry: expiry, eventID: corruptHead ? "event-2" : "event-1", count: 2))
        }
        defer { server.stop() }
        let client = CompassClient(connection: fixture.connection)
        let page = try await client.begin(for: compassSession(.codex))
        await #expect(throws: CompassClientError.invalidResponse) { try await client.next(cursor: #require(page.nextCursor)) }
    }
}

@Test func compassCanonicalUnicodeMatchesNodeHMAC() throws {
    let nativeID = "é🧭/\n\u{2028}"
    let params = try JSONSerialization.data(withJSONObject: ["version": 1, "platform": "claude", "rootSessionID": nativeID, "subject": ["kind": "root", "nativeID": nativeID]])
    let framed = try CompassWire.request(id: "unicode", method: "beginSessionEvidence", params: params, key: Data(repeating: 0x42, count: 32))
    let body = try #require(JSONSerialization.jsonObject(with: Data(framed.dropFirst(4))) as? [String: Any])
    #expect(body["auth"] as? String == "5520caaf38a5511da1588fdfbc8a3c0c479e8a1c98de06b269616a5bd07fc992")
}

@Test func compassCredentialsRejectSizeAndSymlinkedParentsWithoutRepair() throws {
    let fixture = try CompassClientFixture(); defer { fixture.remove() }
    let key = fixture.connection.readerKeyPath
    for size in [0, 31, 4097] {
        try Data(repeating: 0x42, count: size).write(to: URL(fileURLWithPath: key))
        #expect(throws: CompassClientError.invalidCredential) { try CompassCredentials.read(key) }
    }
    try Data(repeating: 0x42, count: 32).write(to: URL(fileURLWithPath: key))
    let parent = fixture.root.appendingPathComponent("private", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let nested = parent.appendingPathComponent("reader.key")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: key), to: nested)
    let alias = fixture.root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: parent)
    #expect(throws: CompassClientError.invalidCredential) { try CompassCredentials.read(alias.appendingPathComponent("reader.key").path) }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
    #expect(throws: CompassClientError.invalidCredential) { try CompassCredentials.read(nested.path) }
    #expect((try FileManager.default.attributesOfItem(atPath: parent.path)[.posixPermissions] as? NSNumber)?.intValue == 0o755)
}

@Test func compassOverloadedClientBoundsRequestsAndPrecancelledTaskDoesNoIO() async throws {
    let fixture = try CompassClientFixture(); defer { fixture.remove() }
    let server = try CompassMockServer(path: fixture.connection.socketPath) { _ in nil }; defer { server.stop() }
    let client = CompassClient(connection: fixture.connection, timeout: 0.15)
    let errors = await withTaskGroup(of: CompassClientError?.self) { group in
        for _ in 0..<5 { group.addTask { do { _ = try await client.health(); return nil } catch { return error as? CompassClientError } } }
        var errors: [CompassClientError?] = []
        for await error in group { errors.append(error) }
        return errors
    }
    #expect(errors.contains(.resourceExhausted)); #expect(errors.count == 5)
    let cancelled = Task { try Task.checkCancellation(); return try await client.health() }
    cancelled.cancel()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
}

@Test func compassRejectsOversizedEvidenceAndInvalidReadyCounts() async throws {
    let oversized = try JSONSerialization.data(withJSONObject: ["version": 1, "id": "id", "result": ["version": 1, "state": "unavailable", "padding": String(repeating: "x", count: 65536)]])
    #expect(throws: CompassClientError.invalidResponse) { let _: CompassEvidencePage = try CompassWire.response(oversized, expectedID: "id") }
    let fixture = try CompassClientFixture(); defer { fixture.remove() }
    let expiry = Date().timeIntervalSince1970 * 1000 + 60000
    let server = try CompassMockServer(path: fixture.connection.socketPath) { request in
        let object = try #require(JSONSerialization.jsonObject(with: request) as? [String: Any])
        if object["method"] as? String == "health" { return try compassReply(request, result: ["ok": true, "capabilities": ["readerRole": true, "sessionEvidence": 1]]) }
        return try compassReply(request, result: compassReady(expiry: expiry, count: 2)) // no continuation despite remaining event
    }
    defer { server.stop() }
    await #expect(throws: CompassClientError.invalidResponse) { try await CompassClient(connection: fixture.connection).begin(for: compassSession(.opencode)) }
}

@Test func compassEvidenceDecoderKeepsMetadataButNeverDisplaysHashedEventLabels() throws {
    let page = Data("{\"version\":1,\"state\":\"ready\",\"events\":[{\"eventID\":\"event\",\"eventType\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"timestamp\":\"2026-09-20T00:00:00Z\",\"metadata\":{\"sources\":[{\"kind\":\"project-notes\",\"ref\":\"notes/status.md\"}],\"matchReason\":\"ticket\",\"bytes\":100,\"approxTokens\":25}}],\"reason\":\"untrusted server prose\"}".utf8)
    let decoded = try JSONDecoder().decode(CompassEvidencePage.self, from: page)
    #expect(decoded.events.first?.displayEventType == "Other")
    #expect(decoded.events.first?.metadata?.sources?.first?.ref == "notes/status.md")
    #expect(decoded.reason == nil)
}
