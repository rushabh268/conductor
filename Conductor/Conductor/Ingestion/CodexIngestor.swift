import Foundation
import GRDB

enum CodexIngestor {
    static let codexDbPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/state_5.sqlite")

    static func parseThread(
        id: String,
        cwd: String,
        title: String,
        gitBranch: String?,
        gitOriginUrl: String?,
        tokensUsed: Int,
        model: String?,
        cliVersion: String?,
        createdAt: Int,
        updatedAt: Int,
        firstUserMessage: String?
    ) -> Session {
        let project = URL(fileURLWithPath: cwd).lastPathComponent
        let ticketId = gitBranch.flatMap { TicketParser.extractTicketId($0) }
            ?? TicketParser.extractTicketId(title)
        let sessionType = TicketParser.classifySession(name: title, firstMessage: firstUserMessage)

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let isExplicitlyNamed: Bool
        if trimmedTitle.isEmpty {
            isExplicitlyNamed = false
        } else if let firstUserMessage, !firstUserMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            isExplicitlyNamed = trimmedTitle != firstUserMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            isExplicitlyNamed = true
        }

        return Session(
            id: id,
            source: .codex,
            sessionType: sessionType,
            name: title,
            cwd: cwd,
            project: project,
            gitBranch: gitBranch,
            ticketId: ticketId,
            status: nil,
            model: model,
            version: cliVersion,
            messageCount: 0,
            toolCallCount: 0,
            tokensUsed: tokensUsed,
            inputTokens: 0,
            outputTokens: 0,
            startedAt: Date(timeIntervalSince1970: Double(createdAt)),
            endedAt: Date(timeIntervalSince1970: Double(updatedAt)),
            isExplicitlyNamed: isExplicitlyNamed,
            cacheReadTokens: 0,
            cacheCreationTokens: 0
        )
    }

    static func computeDailyStats(from db: AppDatabase) async throws {
        let since = Calendar.current.date(byAdding: .day, value: -90, to: Date())!
        let sessions = try await db.fetchSessions(since: since, source: .codex)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        let grouped = Dictionary(grouping: sessions) { session in
            formatter.string(from: session.startedAt)
        }

        for (date, daySessions) in grouped {
            let stat = DailyStat(
                id: nil,
                date: date,
                source: .codex,
                sessionCount: daySessions.count,
                messageCount: daySessions.reduce(0) { $0 + $1.messageCount },
                toolCallCount: daySessions.reduce(0) { $0 + $1.toolCallCount },
                tokensUsed: daySessions.reduce(0) { $0 + $1.tokensUsed }
            )
            try await db.saveDailyStat(stat)
        }
    }

    static func ingestAll(into db: AppDatabase, paths: SourcePaths = .default) async throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.codexRoot.path) else { return }
        let candidates = try fm.contentsOfDirectory(at: paths.codexRoot, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
        guard let url = candidates.first else { return }
        let nativeDB = try NativeDatabase.open(url, table: "threads", required: ["id", "cwd", "title", "created_at", "updated_at"])
        let fingerprint = try NativeDatabase.fingerprint(url)
        let key = "codex:\(paths.profileID):\(url.path)"
        let checkpoint = try await db.checkpoint(path: key)
        if checkpoint?.fingerprint == fingerprint { return }
        let columns = try await nativeDB.read { Set(try $0.columns(in: "threads").map(\.name)) }
        let schema = Data(columns.sorted().joined(separator: ",").utf8)
        // Reconcile all admitted metadata when the fingerprint changes: native writers
        // can insert historical rows whose timestamps precede our last observation.
        var newest: Int64 = 0
        func column(_ name: String, fallback: String = "NULL") -> String { columns.contains(name) ? name : "\(fallback) AS \(name)" }
        let fields = ["id", "cwd", "title", "created_at", "updated_at", "git_branch", "git_origin_url", "tokens_used", "model", "cli_version", "first_user_message", "source", "thread_source", "rollout_path", "name", "archived"].map { column($0) }.joined(separator: ", ")
        let rows = try NativeMetadataSnapshot.read(nativeDB, sql: "SELECT \(fields) FROM threads")
        for row in rows {
            try Task.checkCancellation()
            newest = max(newest, row["updated_at"] as Int64)
            let id: String = row["id"]
            var session = parseThread(id: id, cwd: row["cwd"] ?? "", title: row["name"] ?? row["title"] ?? "",
                gitBranch: row["git_branch"], gitOriginUrl: row["git_origin_url"], tokensUsed: row["tokens_used"] ?? 0,
                model: row["model"], cliVersion: row["cli_version"], createdAt: row["created_at"], updatedAt: row["updated_at"],
                firstUserMessage: row["first_user_message"])
            session.nativeID = id; session.profileID = paths.profileID
            let classification = classify(source: row["source"], threadSource: row["thread_source"], legacy: !columns.contains("source"))
            session.role = classification.role; session.parentNativeID = classification.parent
            session.rootNativeID = session.role == .main ? id : classification.parent
            session.subjectKind = session.role == .child ? .agent : .root
            session.classificationProvenance = "codex-source-metadata"
            session.sourceVersion = row["cli_version"] ?? url.lastPathComponent
            session.lastActivityAt = Date(timeIntervalSince1970: Double(row["updated_at"] as Int))
            session.endedAt = nil
            session.nameProvenance = (row["name"] as String?) != nil ? "native-name" : "native-title"
            session.transcriptPath = row["rollout_path"]
            session.status = (row["archived"] as Int?) == 1 ? "archived" : nil
            session.usageAvailable = columns.contains("tokens_used")
            session.usageBreakdownAvailable = false
            session.messageCountAvailable = false; session.toolCallCountAvailable = false
            try await db.saveSession(session)
        }
        try await db.resolveHierarchy(source: .codex, profileID: paths.profileID)
        try await db.saveCheckpoint(ReaderCheckpoint(path: key, fingerprint: fingerprint, offset: newest, state: schema))
    }
    static func classify(source: String?, threadSource: String?, legacy: Bool = false) -> (role: SessionRole, parent: String?) {
        if let source, let data = source.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            if let object = object as? [String: Any], let subagent = object["subagent"] {
                let parent = ((subagent as? [String: Any])?["thread_spawn"] as? [String: Any])?["parent_thread_id"] as? String
                return (.child, parent)
            }
            if let kind = object as? String, ["cli", "vscode", "appServer", "app_server", "exec"].contains(kind) { return (.main, nil) }
        }
        if threadSource == "subagent" { return (.child, nil) }
        if let source, ["cli", "vscode", "appServer", "app_server", "exec"].contains(source) { return (.main, nil) }
        if legacy { return (.main, nil) }
        return (.unknown, nil)
    }
}
