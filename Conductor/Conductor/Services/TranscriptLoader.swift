import Foundation
import GRDB

struct TranscriptMessage: Identifiable, Sendable {
    let id = UUID()
    let role: String  // "user" or "assistant"
    let text: String
    let timestamp: Date?
    let subAgentId: String?  // nil for main conversation
}

struct SubAgentInfo: Identifiable, Sendable {
    let id: String  // agentId (e.g., "a0653ef83681b13fe")
    let agentType: String
    let description: String
    let messages: [TranscriptMessage]
}

enum TranscriptLoader {
    static func loadClaudeTranscript(sessionId: String, cwd: String?, paths: SourcePaths = .default) -> [TranscriptMessage] {
        guard let cwd else { return [] }

        // Build project hash: replace / and . with -
        let projectHash = ClaudeTokenCounter.projectHash(for: cwd)
        let transcriptPath = paths.claudeProjects
            .appendingPathComponent(projectHash)
            .appendingPathComponent("\(sessionId).jsonl")

        return loadJsonlMessages(from: transcriptPath)
    }

    static func loadCodexTranscript(sessionId: String) -> [TranscriptMessage] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sessionsDir = home.appendingPathComponent(".codex/sessions")

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: nil
        ) else { return [] }

        // Find the session file that contains this ID
        guard let file = files.first(where: { $0.lastPathComponent.contains(sessionId) }) else { return [] }
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else { return [] }

        var messages: [TranscriptMessage] = []
        for item in items {
            guard let role = item["role"] as? String,
                  (role == "user" || role == "assistant"),
                  let content = item["content"] as? [[String: Any]] else { continue }

            let text = content.compactMap { c -> String? in
                guard let type = c["type"] as? String,
                      type == "input_text" || type == "output_text" || type == "text" else { return nil }
                return c["text"] as? String
            }.joined(separator: "\n")

            if !text.isEmpty {
                messages.append(TranscriptMessage(role: role, text: text, timestamp: nil, subAgentId: nil))
            }
        }
        return messages
    }

    /// Compatibility entry point bounded to the first page. UI uses loadPage for continuation.
    static func loadTranscript(for session: Session) -> [TranscriptMessage] {
        (try? page(for: session, offset: 0, limit: 50).messages) ?? []
    }
    static func loadFirstUserMessage(for session: Session) -> String? {
        guard let first = loadTranscript(for: session).first(where: { $0.role == "user" }) else { return nil }
        return String((first.text.components(separatedBy: "\n").first ?? first.text).prefix(80))
    }
    static func loadPage(for session: Session, offset: Int = 0, limit: Int = 50) async throws -> TranscriptPage {
        let task = Task.detached { try page(for: session, offset: offset, limit: min(100, max(1, limit))) }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    private static func page(for session: Session, offset: Int, limit: Int) throws -> TranscriptPage {
        guard let path = session.transcriptPath else {
            return TranscriptPage(messages: [], nextOffset: nil, unavailableReason: "Native transcript location is unavailable")
        }
        if session.source == .opencode { return try openCodePage(path: path, nativeID: session.effectiveNativeID, offset: max(0, offset), limit: limit) }
        let url = URL(fileURLWithPath: path)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 128) ?? Data()
        let size = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
        if session.source == .codex, String(data: prefix, encoding: .utf8)?.contains("\"items\"") == true {
            guard size <= JSONLReader.byteBudget else { throw NativeReaderError.recordTooLarge }
            try handle.seek(toOffset: 0)
            let data = try handle.readToEnd() ?? Data()
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = object["items"] as? [[String: Any]] else { throw NativeReaderError.malformedRecord }
            let messages = items.compactMap { parseMessage($0, source: .codex) }
            let start = min(max(0, offset), messages.count)
            let end = min(start + limit, messages.count)
            return TranscriptPage(messages: Array(messages[start..<end]), nextOffset: end < messages.count ? end : nil, unavailableReason: nil)
        }
        try handle.seek(toOffset: UInt64(max(0, offset)))
        let bytes = try handle.read(upToCount: JSONLReader.byteBudget) ?? Data()
        var messages: [TranscriptMessage] = []
        var consumed = 0
        for line in bytes.split(separator: 10, omittingEmptySubsequences: false) {
            try Task.checkCancellation()
            let terminated = consumed + line.count < bytes.count
            if !terminated && (try? JSONSerialization.jsonObject(with: Data(line))) == nil { break }
            consumed += line.count + (terminated ? 1 : 0)
            if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
               let message = parseMessage(object, source: session.source) { messages.append(message) }
            if messages.count == limit { break }
        }
        let next = max(0, offset) + consumed
        return TranscriptPage(messages: messages, nextOffset: next < size && consumed > 0 ? next : nil, unavailableReason: nil)
    }
    private static func parseMessage(_ object: [String: Any], source: SessionSource) -> TranscriptMessage? {
        var message = object
        var role = object["type"] as? String
        if source == .claude { message = object["message"] as? [String: Any] ?? [:] }
        else {
            if object["type"] as? String == "response_item" { message = object["payload"] as? [String: Any] ?? [:] }
            role = message["role"] as? String
        }
        guard let role, ["user", "assistant"].contains(role) else { return nil }
        let text: String
        if let content = message["content"] as? String { text = content }
        else { text = (message["content"] as? [[String: Any]] ?? []).compactMap { part -> String? in
            guard ["text", "input_text", "output_text"].contains(part["type"] as? String ?? "") else { return nil }
            return part["text"] as? String
        }.joined(separator: "\n") }
        guard !text.isEmpty else { return nil }
        let date = (object["timestamp"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return TranscriptMessage(role: role, text: String(text.prefix(64 * 1024)), timestamp: date, subAgentId: object["agentId"] as? String)
    }
    private static func openCodePage(path: String, nativeID: String, offset: Int, limit: Int) throws -> TranscriptPage {
        let queue = try NativeDatabase.open(URL(fileURLWithPath: path), table: "message", required: ["id", "session_id", "data", "time_created"])
        return try queue.read { db in
            guard try db.tableExists("part") else { throw NativeReaderError.unsupportedSchema("part") }
            let rows = try Row.fetchAll(db, sql: "SELECT id, data, time_created FROM message WHERE session_id = ? ORDER BY time_created, id LIMIT ? OFFSET ?", arguments: [nativeID, limit + 1, offset])
            var messages: [TranscriptMessage] = []
            for row in rows.prefix(limit) {
                try Task.checkCancellation()
                let data: String = row["data"]
                guard let object = try JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
                      let role = object["role"] as? String, ["user", "assistant"].contains(role) else { continue }
                let id: String = row["id"]
                let parts = try String.fetchAll(db, sql: "SELECT substr(data, 1, 65536) FROM part WHERE message_id = ? ORDER BY time_created, id LIMIT 100", arguments: [id])
                let text = parts.compactMap { part -> String? in
                    guard let value = try? JSONSerialization.jsonObject(with: Data(part.utf8)) as? [String: Any], value["type"] as? String == "text" else { return nil }
                    return value["text"] as? String
                }.joined(separator: "\n")
                if !text.isEmpty { messages.append(TranscriptMessage(role: role, text: String(text.prefix(64 * 1024)), timestamp: Date(timeIntervalSince1970: Double(row["time_created"] as Int64) / 1000), subAgentId: nil)) }
            }
            return TranscriptPage(messages: messages, nextOffset: rows.count > limit ? offset + limit : nil, unavailableReason: nil)
        }
    }

    // MARK: - Sub-agent Loading

    static func loadClaudeSubAgents(sessionId: String, cwd: String?, paths: SourcePaths = .default) -> [SubAgentInfo] {
        guard let cwd else { return [] }

        let hash = ClaudeTokenCounter.projectHash(for: cwd)
        let subagentsDir = paths.claudeProjects
            .appendingPathComponent(hash)
            .appendingPathComponent(sessionId)
            .appendingPathComponent("subagents")

        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: subagentsDir, includingPropertiesForKeys: nil
        ) else { return [] }

        let metaFiles = files.filter {
            $0.pathExtension == "json" && $0.lastPathComponent.hasSuffix(".meta.json")
        }

        var agents: [SubAgentInfo] = []
        for metaFile in metaFiles {
            // Extract agentId from filename: "agent-<id>.meta.json"
            let filename = metaFile.deletingPathExtension().deletingPathExtension().lastPathComponent
            guard filename.hasPrefix("agent-") else { continue }
            let agentId = String(filename.dropFirst("agent-".count))

            // Read meta
            guard let metaData = try? Data(contentsOf: metaFile),
                  let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any] else { continue }

            let agentType = meta["agentType"] as? String ?? "unknown"
            let description = meta["description"] as? String ?? "Sub-agent"

            // Read JSONL
            let jsonlFile = subagentsDir
                .appendingPathComponent("agent-\(agentId).jsonl")
            let messages = loadJsonlMessages(from: jsonlFile)

            agents.append(SubAgentInfo(
                id: agentId,
                agentType: agentType,
                description: description,
                messages: messages
            ))
        }

        // Sort by first message timestamp (chronological order of when they were spawned)
        return agents.sorted { a, b in
            (a.messages.first?.timestamp ?? .distantFuture) < (b.messages.first?.timestamp ?? .distantFuture)
        }
    }

    // MARK: - Shared JSONL Message Parser

    /// Shared JSONL message parser used by both main transcript and sub-agent loading.
    static func loadJsonlMessages(from url: URL) -> [TranscriptMessage] {
        guard let data = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var messages: [TranscriptMessage] = []
        for line in data.components(separatedBy: "\n") where !line.isEmpty {
            guard let jsonData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }

            let type = obj["type"] as? String ?? ""
            guard type == "user" || type == "assistant" else { continue }

            guard let message = obj["message"] as? [String: Any] else { continue }
            let content = message["content"]

            var text = ""
            if let str = content as? String {
                text = str
            } else if let arr = content as? [[String: Any]] {
                text = arr.compactMap { item -> String? in
                    guard let itemType = item["type"] as? String,
                          itemType == "text" || itemType == "input_text" || itemType == "output_text" else { return nil }
                    return item["text"] as? String
                }.joined(separator: "\n")
            }

            let timestamp: Date? = (obj["timestamp"] as? String).flatMap { str in
                isoFormatter.date(from: str) ?? ISO8601DateFormatter().date(from: str)
            }

            let agentId = obj["agentId"] as? String

            if !text.isEmpty {
                messages.append(TranscriptMessage(
                    role: type, text: text, timestamp: timestamp, subAgentId: agentId
                ))
            }
        }
        return messages
    }
}

struct TranscriptPage: Sendable {
    var messages: [TranscriptMessage]
    var nextOffset: Int?
    var unavailableReason: String?
}
