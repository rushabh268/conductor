import Foundation

enum ClaudeIngestor {
    private struct RawSession: Decodable {
        let pid: Int
        let sessionId: String
        let cwd: String?
        let startedAt: Int64
        let version: String?
        let kind: String?
        let entrypoint: String?
        let status: String?
        let updatedAt: Int64?
        let name: String?
        let nameSource: String?
        let parentSessionId: String?
        let agentId: String?
    }

    private struct RawStatsCache: Decodable {
        let dailyActivity: [RawDailyActivity]?
        let dailyModelTokens: [RawDailyModelTokens]?
    }

    private struct RawDailyActivity: Decodable {
        let date: String
        let messageCount: Int
        let sessionCount: Int
        let toolCallCount: Int
    }

    private struct RawDailyModelTokens: Decodable {
        let date: String
        let tokensByModel: [String: Int]
    }

    static func parseSessionFile(data: Data) throws -> Session {
        let raw = try JSONDecoder().decode(RawSession.self, from: data)
        let project = raw.cwd.flatMap { URL(fileURLWithPath: $0).lastPathComponent }
        let sessionType = TicketParser.classifySession(name: raw.name, firstMessage: nil)
        let gitBranch: String? = nil
        let ticketId = raw.name.flatMap { TicketParser.extractTicketId($0) }
        let isExplicitlyNamed = raw.nameSource != "derived"
            && !(raw.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        var session = Session(
            id: raw.sessionId,
            source: .claude,
            sessionType: sessionType,
            name: raw.name,
            cwd: raw.cwd,
            project: project,
            gitBranch: gitBranch,
            ticketId: ticketId,
            status: raw.status,
            model: nil,
            version: raw.version,
            messageCount: 0,
            toolCallCount: 0,
            tokensUsed: 0,
            inputTokens: 0,
            outputTokens: 0,
            startedAt: Date(timeIntervalSince1970: Double(raw.startedAt) / 1000.0),
            endedAt: nil,
            isExplicitlyNamed: isExplicitlyNamed,
            cacheReadTokens: 0,
            cacheCreationTokens: 0
        )
        session.nativeID = raw.sessionId
        session.parentNativeID = raw.parentSessionId
        session.rootNativeID = raw.parentSessionId ?? raw.sessionId
        session.role = raw.parentSessionId != nil ? .child : (raw.kind == "interactive" ? .main : .unknown)
        if raw.kind == "subagent" && raw.parentSessionId == nil { session.role = .child }
        session.subjectKind = session.role == .child ? .agent : .root
        session.classificationProvenance = "claude-session-metadata"
        session.nameProvenance = raw.nameSource ?? (isExplicitlyNamed ? "native-name" : "unknown")
        session.lastActivityAt = raw.updatedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        session.sourceVersion = raw.version
        session.usageAvailable = false; session.usageBreakdownAvailable = false
        session.messageCountAvailable = false; session.toolCallCountAvailable = false
        return session
    }

    static func parseStatsCache(data: Data) throws -> [DailyStat] {
        let raw = try JSONDecoder().decode(RawStatsCache.self, from: data)
        let activities = raw.dailyActivity ?? []
        let tokensByDate = Dictionary(
            uniqueKeysWithValues: (raw.dailyModelTokens ?? []).map {
                ($0.date, $0.tokensByModel.values.reduce(0, +))
            }
        )

        return activities.map { activity in
            DailyStat(
                id: nil,
                date: activity.date,
                source: .claude,
                sessionCount: activity.sessionCount,
                messageCount: activity.messageCount,
                toolCallCount: activity.toolCallCount,
                tokensUsed: tokensByDate[activity.date] ?? 0
            )
        }
    }

    static var claudeProjectsDir: URL { SourcePaths.default.claudeProjects }
    static func ingestAll(into db: AppDatabase, paths: SourcePaths = .default) async throws {
        try await ingestSessions(into: db, paths: paths)
        try await ingestHistoricalSessions(into: db, paths: paths)
        try await db.resolveHierarchy(source: .claude, profileID: paths.profileID)
    }
    struct SessionStats {
        var messageCount = 0; var toolCallCount = 0; var tokensUsed = 0
        var inputTokens = 0; var outputTokens = 0; var cacheReadTokens = 0; var cacheCreationTokens = 0
        static let zero = SessionStats()
    }
    static func countSessionStats(sessionId: String, cwd: String?, paths: SourcePaths = .default) -> SessionStats {
        guard let path = ClaudeTokenCounter.jsonlPath(sessionId: sessionId, cwd: cwd, paths: paths),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let meta = try? parseJsonlMetadata(data: data) else { return .zero }
        return SessionStats(messageCount: meta.messageCount, toolCallCount: meta.toolCallCount,
            tokensUsed: meta.inputTokens + meta.outputTokens + meta.cacheReadTokens + meta.cacheCreationTokens,
            inputTokens: meta.inputTokens, outputTokens: meta.outputTokens,
            cacheReadTokens: meta.cacheReadTokens, cacheCreationTokens: meta.cacheCreationTokens)
    }
    static func ingestSessions(into db: AppDatabase, paths: SourcePaths = .default) async throws {
        guard FileManager.default.fileExists(atPath: paths.claudeSessions.path) else { return }
        for file in try FileManager.default.contentsOfDirectory(at: paths.claudeSessions, includingPropertiesForKeys: nil)
            where file.pathExtension == "json" {
            try Task.checkCancellation()
            var session = try parseSessionFile(data: Data(contentsOf: file))
            session.profileID = paths.profileID
            if let old = try await db.fetchSession(source: .claude, profileID: paths.profileID, nativeID: session.effectiveNativeID) {
                session.messageCount = old.messageCount; session.toolCallCount = old.toolCallCount
                session.inputTokens = old.inputTokens; session.outputTokens = old.outputTokens
                session.cacheReadTokens = old.cacheReadTokens; session.cacheCreationTokens = old.cacheCreationTokens
                session.tokensUsed = old.tokensUsed; session.transcriptPath = old.transcriptPath
                session.usageAvailable = old.usageAvailable; session.usageBreakdownAvailable = old.usageBreakdownAvailable
                session.messageCountAvailable = old.messageCountAvailable; session.toolCallCountAvailable = old.toolCallCountAvailable
            }
            if let path = ClaudeTokenCounter.jsonlPath(sessionId: session.effectiveNativeID, cwd: session.cwd, paths: paths) {
                session.transcriptPath = path
            }
            classifyInternal(&session)
            try await db.saveSession(session)
        }
    }
    /// Per-database checkpoints persist successful reads; failed sources remain retryable after restart.
    static func ingestHistoricalSessions(into db: AppDatabase, paths: SourcePaths = .default) async throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.claudeProjects.path) else { return }
        var processedBytes = 0
        var hadFailures = false
        for project in try fm.contentsOfDirectory(at: paths.claudeProjects, includingPropertiesForKeys: [.isDirectoryKey]) {
            guard (try project.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { continue }
            for file in try fm.contentsOfDirectory(at: project, includingPropertiesForKeys: [.isDirectoryKey]) {
                try Task.checkCancellation()
                if file.pathExtension == "jsonl" {
                    do { processedBytes += try await ingestTranscript(file, db: db, paths: paths) }
                    catch is CancellationError { throw CancellationError() }
                    catch { hadFailures = true }
                    if processedBytes >= 16 * 1024 * 1024 {
                        if hadFailures { throw NativeReaderError.malformedRecord }
                        return
                    }
                } else if (try file.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
                    // Documented containment establishes parenthood without opening child histories.
                    let children = file.appendingPathComponent("subagents")
                    guard fm.fileExists(atPath: children.path) else { continue }
                    for child in try fm.contentsOfDirectory(at: children, includingPropertiesForKeys: [.contentModificationDateKey])
                        where child.pathExtension == "jsonl" && child.lastPathComponent.hasPrefix("agent-") {
                        let native = String(child.deletingPathExtension().lastPathComponent.dropFirst(6))
                        var session = emptySession(native: native, paths: paths)
                        session.role = .child; session.subjectKind = .agent
                        session.parentNativeID = file.lastPathComponent; session.rootNativeID = file.lastPathComponent
                        session.classificationProvenance = "claude-subagents-directory"
                        session.sourceVersion = "claude-subagents-v1"
                        session.transcriptPath = child.path; session.usageAvailable = false
                        session.usageBreakdownAvailable = false
                        session.messageCountAvailable = false; session.toolCallCountAvailable = false
                        session.lastActivityAt = try child.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                        try await db.saveSession(session)
                    }
                }
            }
        }
        if hadFailures { throw NativeReaderError.malformedRecord }
    }
    private static func emptySession(native: String, paths: SourcePaths) -> Session {
        var session = Session(id: native, source: .claude, sessionType: .coding, name: nil, cwd: nil,
            project: nil, gitBranch: nil, ticketId: nil, status: nil, model: nil, version: nil,
            messageCount: 0, toolCallCount: 0, tokensUsed: 0, inputTokens: 0, outputTokens: 0,
            startedAt: Date(timeIntervalSince1970: 0), endedAt: nil, isExplicitlyNamed: false,
            cacheReadTokens: 0, cacheCreationTokens: 0)
        session.nativeID = native; session.profileID = paths.profileID
        return session
    }
    private static func classifyInternal(_ session: inout Session) {
        if [".claude-mem", ".claude/plugins", "observer-sessions"].contains(where: { session.cwd?.contains($0) == true }) {
            session.role = .internal; session.classificationProvenance = "native-internal-cwd"
        }
    }
    private static func ingestTranscript(_ file: URL, db: AppDatabase, paths: SourcePaths) async throws -> Int {
        let checkpointKey = "claude:\(paths.profileID):\(file.resolvingSymlinksInPath().path)"
        let checkpoint = try await db.checkpoint(path: checkpointKey)
        let chunk = try JSONLReader.read(file, offset: checkpoint?.offset ?? 0, fingerprint: checkpoint?.fingerprint)
        if chunk.data.isEmpty { return 0 }
        let initial = !chunk.reset ? checkpoint?.state.flatMap { try? JSONDecoder().decode(JsonlMetadata.self, from: $0) } : nil
        let meta = try parseJsonlMetadata(data: chunk.data, initial: initial ?? JsonlMetadata())
        guard meta.validRecords > 0 else { return 0 }
        let native = file.deletingPathExtension().lastPathComponent
        var session = try await db.fetchSession(source: .claude, profileID: paths.profileID, nativeID: native)
            ?? emptySession(native: native, paths: paths)
        session.name = meta.explicitName ?? session.name ?? meta.name
        session.isExplicitlyNamed = meta.explicitName != nil || session.isExplicitlyNamed
        session.nameProvenance = meta.explicitName != nil ? "native-title" : (session.isExplicitlyNamed ? session.nameProvenance : "first-message")
        session.cwd = meta.cwd ?? session.cwd
        session.project = session.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
        session.model = meta.model ?? session.model
        session.gitBranch = meta.gitBranch ?? session.gitBranch
        session.messageCount = meta.messageCount; session.toolCallCount = meta.toolCallCount
        session.inputTokens = meta.inputTokens; session.outputTokens = meta.outputTokens
        session.cacheReadTokens = meta.cacheReadTokens; session.cacheCreationTokens = meta.cacheCreationTokens
        session.tokensUsed = meta.inputTokens + meta.outputTokens + meta.cacheReadTokens + meta.cacheCreationTokens
        session.startedAt = meta.startedAt ?? session.startedAt
        session.lastActivityAt = meta.lastTimestamp ?? session.lastActivityAt
        if session.classificationProvenance != "claude-session-metadata" || meta.role != .main {
            session.role = meta.role; session.parentNativeID = meta.parentNativeID
            session.rootNativeID = meta.parentNativeID ?? (meta.role == .main ? native : nil)
            session.classificationProvenance = "claude-jsonl-metadata"
        }
        session.subjectKind = session.role == .child ? .agent : .root
        session.transcriptPath = file.path; session.sourceVersion = "claude-jsonl-v1"
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        let complete = chunk.nextOffset >= size
        session.usageAvailable = complete; session.usageBreakdownAvailable = complete
        session.messageCountAvailable = complete; session.toolCallCountAvailable = complete
        classifyInternal(&session)
        try await db.saveSession(session)
        try await db.saveCheckpoint(ReaderCheckpoint(path: checkpointKey, fingerprint: chunk.fingerprint,
            offset: chunk.nextOffset, state: try JSONEncoder().encode(meta)))
        return chunk.data.count
    }
    private struct JsonlMetadata: Codable {
        var role: SessionRole = .unknown
        var parentNativeID: String?
        var validRecords = 0
        var isSidechain = false
        var name: String?
        var explicitName: String?
        var cwd: String?
        var model: String?
        var gitBranch: String?
        var startedAt: Date?
        var lastTimestamp: Date?
        var messageCount: Int = 0
        var toolCallCount: Int = 0
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var cacheReadTokens: Int = 0
        var cacheCreationTokens: Int = 0
    }

    private static func parseJsonlMetadata(data: Data, initial: JsonlMetadata = JsonlMetadata()) throws -> JsonlMetadata {
        guard let data = String(data: data, encoding: .utf8) else { throw NativeReaderError.malformedRecord }
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()

        var meta = initial

        for line in data.components(separatedBy: "\n") where !line.isEmpty {
            guard let jsonData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { throw NativeReaderError.malformedRecord }

            meta.validRecords += 1
            if obj["isSidechain"] as? Bool == true { meta.isSidechain = true }
            if let parent = obj["parentSessionId"] as? String { meta.parentNativeID = parent; meta.role = .child }
            else if obj["isSidechain"] as? Bool == true, meta.parentNativeID == nil { meta.role = .unknown }
            if meta.cwd == nil { meta.cwd = obj["cwd"] as? String }
            if let branch = obj["gitBranch"] as? String { meta.gitBranch = branch }
            let type = obj["type"] as? String ?? ""
            if meta.role == .unknown && meta.parentNativeID == nil && !meta.isSidechain,
               ["user", "assistant", "system", "custom-title", "agent-name"].contains(type) {
                meta.role = .main
            }

            // Extract timestamp
            if let tsStr = obj["timestamp"] as? String {
                let ts = isoFormatter.date(from: tsStr) ?? isoBasic.date(from: tsStr)
                if meta.startedAt == nil { meta.startedAt = ts }
                meta.lastTimestamp = ts
            }

            // Extract cwd from system messages
            if type == "system", meta.cwd == nil {
                if let message = obj["message"] as? [String: Any],
                   let cwd = message["cwd"] as? String {
                    meta.cwd = cwd
                }
            }

            // Count messages
            if type == "user" || type == "assistant" {
                meta.messageCount += 1
            }

            // Extract first user message as name
            if type == "user" && meta.name == nil {
                if let message = obj["message"] as? [String: Any] {
                    if let content = message["content"] as? String {
                        meta.name = String(content.prefix(80))
                    } else if let arr = message["content"] as? [[String: Any]] {
                        let text = arr.compactMap { $0["text"] as? String }.first
                        meta.name = text.map { String($0.prefix(80)) }
                    }
                }
            }

            // Extract explicit title events (custom-title preferred, last-seen wins:
            // jsonl lines are in chronological order, so a later rename should win)
            if type == "custom-title", let customTitle = obj["customTitle"] as? String, !customTitle.isEmpty {
                meta.explicitName = customTitle
            }
            if type == "agent-name", let agentName = obj["agentName"] as? String, !agentName.isEmpty {
                meta.explicitName = agentName
            }

            // Extract token counts and model from assistant messages
            if type == "assistant", let message = obj["message"] as? [String: Any] {
                if meta.model == nil, let model = message["model"] as? String {
                    meta.model = model
                }
                if let usage = message["usage"] as? [String: Any] {
                    meta.inputTokens += (usage["input_tokens"] as? Int) ?? 0
                    meta.outputTokens += (usage["output_tokens"] as? Int) ?? 0
                    meta.cacheReadTokens += (usage["cache_read_input_tokens"] as? Int) ?? 0
                    meta.cacheCreationTokens += (usage["cache_creation_input_tokens"] as? Int) ?? 0
                }
                if let content = message["content"] as? [[String: Any]] {
                    meta.toolCallCount += content.filter { ($0["type"] as? String) == "tool_use" }.count
                }
            }
        }

        return meta
    }

    static func computeDailyStats(from db: AppDatabase) async throws {
        let sessions = try await db.fetchAllSessions()
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        let grouped = Dictionary(grouping: sessions.filter { $0.source == .claude }) { formatter.string(from: $0.activityAt) }
        for (date, rows) in grouped {
            try await db.saveDailyStat(DailyStat(id: nil, date: date, source: .claude, sessionCount: rows.count,
                messageCount: rows.reduce(0) { $0 + $1.messageCount }, toolCallCount: rows.reduce(0) { $0 + $1.toolCallCount },
                tokensUsed: rows.reduce(0) { $0 + $1.tokensUsed }))
        }
    }
}
