import Foundation
import GRDB

/// Reads the native SQLite history directly; it never starts an OpenCode server.
enum OpenCodeIngestor {
    static func ingestAll(into db: AppDatabase, paths: SourcePaths = .default) async throws {
        let url = paths.openCodeDatabase
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let nativeDB = try NativeDatabase.open(url, table: "session",
            required: ["id", "parent_id", "directory", "title", "version", "time_created", "time_updated"])
        let fingerprint = try NativeDatabase.fingerprint(url)
        let key = "opencode:\(paths.profileID):\(url.path)"
        let checkpoint = try await db.checkpoint(path: key)
        if checkpoint?.fingerprint == fingerprint { return }
        let columns = try await nativeDB.read { Set(try $0.columns(in: "session").map(\.name)) }
        let schema = Data(columns.sorted().joined(separator: ",").utf8)
        // Reconcile all admitted metadata when the fingerprint changes: native writers
        // can insert historical rows whose timestamps precede our last observation.
        var newest: Int64 = 0
        let optional = ["model", "agent", "tokens_input", "tokens_output", "tokens_cache_read", "tokens_cache_write", "time_archived"]
        let fields = (["id", "parent_id", "directory", "title", "version", "time_created", "time_updated"] + optional.map { columns.contains($0) ? $0 : "NULL AS \($0)" }).joined(separator: ", ")
        let rows = try NativeMetadataSnapshot.read(nativeDB, sql: "SELECT \(fields) FROM session")
        for row in rows {
            try Task.checkCancellation()
            newest = max(newest, row["time_updated"] as Int64)
            let native: String = row["id"]
            let parent: String? = row["parent_id"]
            let input: Int = row["tokens_input"] ?? 0, output: Int = row["tokens_output"] ?? 0
            let cacheRead: Int = row["tokens_cache_read"] ?? 0, cacheWrite: Int = row["tokens_cache_write"] ?? 0
            let directory: String = row["directory"]
            let title: String = row["title"]
            var session = Session(id: native, source: .opencode, sessionType: TicketParser.classifySession(name: title, firstMessage: nil),
                name: title, cwd: directory, project: URL(fileURLWithPath: directory).lastPathComponent,
                gitBranch: nil, ticketId: TicketParser.extractTicketId(title), status: nil,
                model: row["model"], version: row["version"], messageCount: 0, toolCallCount: 0,
                tokensUsed: input + output + cacheRead + cacheWrite, inputTokens: input, outputTokens: output,
                startedAt: Date(timeIntervalSince1970: Double(row["time_created"] as Int64) / 1000), endedAt: nil,
                isExplicitlyNamed: !title.isEmpty, cacheReadTokens: cacheRead, cacheCreationTokens: cacheWrite)
            session.nativeID = native; session.profileID = paths.profileID
            session.role = parent == nil ? .main : .child
            session.parentNativeID = parent; session.rootNativeID = parent ?? native
            session.subjectKind = parent == nil ? .root : .session
            session.classificationProvenance = "opencode-parent-id"; session.nameProvenance = "native-title"
            session.sourceVersion = row["version"]; session.transcriptPath = url.path
            session.lastActivityAt = Date(timeIntervalSince1970: Double(row["time_updated"] as Int64) / 1000)
            session.status = (row["time_archived"] as Int64?) != nil ? "archived" : nil
            session.usageAvailable = ["tokens_input", "tokens_output", "tokens_cache_read", "tokens_cache_write"].allSatisfy { columns.contains($0) }
            session.usageBreakdownAvailable = session.usageAvailable
            session.messageCountAvailable = false; session.toolCallCountAvailable = false
            try await db.saveSession(session)
        }
        try await db.resolveHierarchy(source: .opencode, profileID: paths.profileID)
        try await db.saveCheckpoint(ReaderCheckpoint(path: key, fingerprint: fingerprint, offset: newest, state: schema))
    }
}
