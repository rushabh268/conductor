import Foundation
import GRDB

struct AppDatabase: Sendable {
    private let dbWriter: any DatabaseWriter

    init(inMemory: Bool = false, path: String? = nil) throws {
        if inMemory {
            dbWriter = try DatabaseQueue()
        } else if let path {
            dbWriter = try DatabaseQueue(path: path)
        } else {
            let url = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Conductor", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let dbPath = url.appendingPathComponent("store.db").path
            dbWriter = try DatabasePool(path: dbPath)
        }
        try migrator.migrate(dbWriter)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "sessions") { t in
                t.primaryKey("id", .text)
                t.column("source", .text).notNull()
                t.column("sessionType", .text).notNull()
                t.column("name", .text)
                t.column("cwd", .text)
                t.column("project", .text)
                t.column("gitBranch", .text)
                t.column("ticketId", .text)
                t.column("status", .text)
                t.column("model", .text)
                t.column("version", .text)
                t.column("messageCount", .integer).notNull().defaults(to: 0)
                t.column("toolCallCount", .integer).notNull().defaults(to: 0)
                t.column("tokensUsed", .integer).notNull().defaults(to: 0)
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
            }

            try db.create(table: "daily_stats") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("date", .text).notNull()
                t.column("source", .text).notNull()
                t.column("sessionCount", .integer).notNull().defaults(to: 0)
                t.column("messageCount", .integer).notNull().defaults(to: 0)
                t.column("toolCallCount", .integer).notNull().defaults(to: 0)
                t.column("tokensUsed", .integer).notNull().defaults(to: 0)
                t.uniqueKey(["date", "source"])
            }

            try db.create(table: "repos") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("path", .text).notNull().unique()
                t.column("originUrl", .text)
                t.column("lastScannedAt", .datetime).notNull()
            }

            try db.create(table: "branches") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("repoId", .integer).notNull()
                    .references("repos", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("ticketId", .text)
                t.column("firstSeenAt", .datetime).notNull()
                t.column("lastSeenAt", .datetime).notNull()
                t.uniqueKey(["repoId", "name"])
            }

            try db.create(table: "pull_requests") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("repoId", .integer).notNull()
                    .references("repos", onDelete: .cascade)
                t.column("number", .integer).notNull()
                t.column("title", .text).notNull()
                t.column("state", .text).notNull()
                t.column("ticketId", .text)
                t.column("additions", .integer).notNull().defaults(to: 0)
                t.column("deletions", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("mergedAt", .datetime)
                t.column("url", .text)
                t.uniqueKey(["repoId", "number"])
            }

            try db.create(table: "line_stats") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("repoId", .integer).notNull()
                    .references("repos", onDelete: .cascade)
                t.column("date", .text).notNull()
                t.column("additions", .integer).notNull().defaults(to: 0)
                t.column("deletions", .integer).notNull().defaults(to: 0)
                t.uniqueKey(["repoId", "date"])
            }

            try db.create(table: "status_posts") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("type", .text).notNull()
                t.column("postedAt", .datetime).notNull()
                t.column("content", .text).notNull()
                t.column("slackResponse", .text)
            }
        }

        migrator.registerMigration("v2") { db in
            try db.alter(table: "sessions") { t in
                t.add(column: "inputTokens", .integer).notNull().defaults(to: 0)
                t.add(column: "outputTokens", .integer).notNull().defaults(to: 0)
            }
        }

        migrator.registerMigration("v3") { db in
            try db.alter(table: "sessions") { t in
                t.add(column: "isExplicitlyNamed", .boolean).notNull().defaults(to: false)
                t.add(column: "cacheReadTokens", .integer).notNull().defaults(to: 0)
                t.add(column: "cacheCreationTokens", .integer).notNull().defaults(to: 0)
            }
        }

        migrator.registerMigration("v4_session_identity") { db in
            try db.alter(table: "sessions") { t in
                t.add(column: "nativeID", .text).notNull().defaults(to: "")
                t.add(column: "profileID", .text).notNull().defaults(to: "default")
                t.add(column: "role", .text).notNull().defaults(to: "unknown")
                t.add(column: "parentNativeID", .text)
                t.add(column: "rootNativeID", .text)
                t.add(column: "subjectKind", .text).notNull().defaults(to: "root")
                t.add(column: "nameProvenance", .text).notNull().defaults(to: "unknown")
                t.add(column: "classificationProvenance", .text).notNull().defaults(to: "legacy")
                t.add(column: "lastActivityAt", .datetime)
                t.add(column: "sourceVersion", .text)
                // Historical shipped column retained for migration compatibility; reader health is source-level.
                t.add(column: "sourceCompatibility", .text).notNull().defaults(to: "supported")
                t.add(column: "transcriptPath", .text)
                t.add(column: "usageScope", .text).notNull().defaults(to: "own")
                t.add(column: "usageAvailable", .boolean).notNull().defaults(to: true)
                t.add(column: "usageBreakdownAvailable", .boolean).notNull().defaults(to: true)
                t.add(column: "messageCountAvailable", .boolean).notNull().defaults(to: true)
                t.add(column: "toolCallCountAvailable", .boolean).notNull().defaults(to: true)
                t.add(column: "isHidden", .boolean).notNull().defaults(to: false)
                t.add(column: "isPinned", .boolean).notNull().defaults(to: false)
            }
            try db.execute(sql: "UPDATE sessions SET nativeID = id, lastActivityAt = COALESCE(endedAt, startedAt)")
            try db.create(index: "session_identity", on: "sessions", columns: ["source", "profileID", "nativeID"], unique: true)
            try db.create(index: "session_parent", on: "sessions", columns: ["source", "profileID", "parentNativeID"])
            try db.create(table: "reader_checkpoints") { t in
                t.primaryKey("path", .text)
                t.column("fingerprint", .text).notNull()
                t.column("offset", .integer).notNull().defaults(to: 0)
                t.column("state", .blob)
            }
        }
        return migrator
    }

    /// User-facing populations exclude native archives independently of local hiding.
    /// Identity lookup and reconciliation deliberately retain both kinds of record.
    private static var visibleSessions: QueryInterfaceRequest<Session> {
        Session.filter(sql: "isHidden = 0 AND lower(COALESCE(status, '')) != 'archived'")
    }

    // MARK: - Session CRUD

    @discardableResult
    func saveSession(_ session: Session) async throws -> Session {
        try await dbWriter.write { db in
            var s = session
            let native = s.effectiveNativeID
            if let existing = try Session.filter(Column("source") == s.source)
                .filter(Column("profileID") == s.profileID).filter(Column("nativeID") == native).fetchOne(db) {
                s.id = existing.id
                s.isHidden = existing.isHidden
                s.isPinned = existing.isPinned
            } else if try (!s.nativeID.isEmpty || Session.fetchOne(db, key: s.id) != nil) {
                s.id = Session.localID(source: s.source, profile: s.profileID, nativeID: native)
            }
            s.nativeID = native
            try s.save(db)
            return s
        }
    }

    func fetchSession(id: String) async throws -> Session? {
        try await dbWriter.read { db in
            try Self.visibleSessions.filter(Column("id") == id).fetchOne(db)
        }
    }

    func fetchSessions(since: Date, source: SessionSource? = nil, onlyNamed: Bool = false) async throws -> [Session] {
        try await dbWriter.read { db in
            var request = Self.visibleSessions.filter(sql: "COALESCE(lastActivityAt, endedAt, startedAt) >= ?", arguments: [since]).filter(Column("role") == SessionRole.main)
            if let source {
                request = request.filter(Column("source") == source)
            }
            if onlyNamed {
                request = request.filter(Column("isExplicitlyNamed") == true)
            }
            return try request.order(Column("startedAt").desc).fetchAll(db)
        }
    }

    func fetchAllSessions(onlyNamed: Bool = false) async throws -> [Session] {
        try await dbWriter.read { db in
            var request = Self.visibleSessions.filter(Column("role") == SessionRole.main)
            if onlyNamed {
                request = request.filter(Column("isExplicitlyNamed") == true)
            }
            return try request.order(Column("startedAt").desc).fetchAll(db)
        }
    }

    // MARK: - Session Deletion

    func deleteSession(id: String) async throws {
        try await dbWriter.write { db in
            try db.execute(sql: "UPDATE sessions SET isHidden = 1 WHERE id = ?", arguments: [id])
        }
    }

    func deleteInternalSessions() async throws {
        // Internal rows remain available in the diagnostic role query.
    }

    func fetchReviewSessions(since: Date) async throws -> [Session] {
        try await dbWriter.read { db in
            try Self.visibleSessions
                .filter(Column("startedAt") >= since)
                .filter(Column("sessionType") == SessionType.review)
                .filter(Column("role") == SessionRole.main)
                .order(Column("startedAt").desc)
                .fetchAll(db)
        }
    }

    // MARK: - DailyStat CRUD

    @discardableResult
    func saveDailyStat(_ stat: DailyStat) async throws -> DailyStat {
        try await dbWriter.write { db in
            var s = stat
            try s.save(db, onConflict: .replace)
            return s
        }
    }

    func fetchDailyStats(since: String) async throws -> [DailyStat] {
        try await dbWriter.read { db in
            try DailyStat
                .filter(Column("date") >= since)
                .order(Column("date").desc)
                .fetchAll(db)
        }
    }

    // MARK: - Repo CRUD

    @discardableResult
    func saveRepo(_ repo: Repo) async throws -> Repo {
        try await dbWriter.write { db in
            var r = repo
            try r.save(db, onConflict: .replace)
            return r
        }
    }

    func fetchRepos() async throws -> [Repo] {
        try await dbWriter.read { db in
            try Repo.fetchAll(db)
        }
    }

    func fetchRepo(byPath path: String) async throws -> Repo? {
        try await dbWriter.read { db in
            try Repo.filter(Column("path") == path).fetchOne(db)
        }
    }

    // MARK: - Branch CRUD

    @discardableResult
    func saveBranch(_ branch: Branch) async throws -> Branch {
        try await dbWriter.write { db in
            var b = branch
            try b.save(db, onConflict: .replace)
            return b
        }
    }

    func fetchBranches(repoId: Int64) async throws -> [Branch] {
        try await dbWriter.read { db in
            try Branch.filter(Column("repoId") == repoId).fetchAll(db)
        }
    }

    // MARK: - PullRequest CRUD

    @discardableResult
    func savePullRequest(_ pr: PullRequest) async throws -> PullRequest {
        try await dbWriter.write { db in
            var p = pr
            try p.save(db, onConflict: .replace)
            return p
        }
    }

    func fetchPullRequests(repoId: Int64, since: Date) async throws -> [PullRequest] {
        try await dbWriter.read { db in
            try PullRequest
                .filter(Column("repoId") == repoId)
                .filter(Column("createdAt") >= since)
                .order(Column("createdAt").desc)
                .fetchAll(db)
        }
    }

    // MARK: - LineStat CRUD

    @discardableResult
    func saveLineStat(_ stat: LineStat) async throws -> LineStat {
        try await dbWriter.write { db in
            var s = stat
            try s.save(db, onConflict: .replace)
            return s
        }
    }

    // MARK: - StatusPost CRUD

    @discardableResult
    func saveStatusPost(_ post: StatusPost) async throws -> StatusPost {
        try await dbWriter.write { db in
            var p = post
            try p.save(db, onConflict: .replace)
            return p
        }
    }

    func fetchStatusPosts(limit: Int = 20) async throws -> [StatusPost] {
        try await dbWriter.read { db in
            try StatusPost
                .order(Column("postedAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    // MARK: - Retention

    func pruneOldRecords(olderThan days: Int = 90) async throws {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        try await dbWriter.write { db in
            try Session.filter(sql: "COALESCE(lastActivityAt, endedAt, startedAt) < ? AND COALESCE(status, '') NOT IN ('busy', 'active', 'running') AND isHidden = 0 AND isPinned = 0", arguments: [cutoff]).deleteAll(db)
            let dateStr = ISO8601DateFormatter().string(from: cutoff).prefix(10)
            try DailyStat.filter(Column("date") < String(dateStr)).deleteAll(db)
        }
    }
}

extension AppDatabase {
    func fetchSession(source: SessionSource, profileID: String = "default", nativeID: String) async throws -> Session? {
        try await dbWriter.read { db in
            try Session.filter(Column("source") == source).filter(Column("profileID") == profileID)
                .filter(Column("nativeID") == nativeID).fetchOne(db)
        }
    }
    func fetchSessions(query: SessionQuery) async throws -> [Session] {
        try await dbWriter.read { db in
            var request = Self.request(query)
            request = request.order(sql: "isPinned DESC, COALESCE(lastActivityAt, endedAt, startedAt) DESC, id")
            return try request.limit(min(max(query.limit, 1), 1000), offset: max(0, query.offset)).fetchAll(db)
        }
    }
    func countSessions(query: SessionQuery) async throws -> Int {
        try await dbWriter.read { db in try Self.request(query).fetchCount(db) }
    }
    func activity(query: SessionQuery) async throws -> [SessionActivity] {
        try await dbWriter.read { db in
            let request = Self.request(query)
                .select(sql: "date(COALESCE(lastActivityAt, endedAt, startedAt), 'localtime') AS day, source, COUNT(*) AS sessions, SUM(tokensUsed) AS tokens")
                .group(sql: "day, source").order(sql: "day, source")
            return try Row.fetchAll(db, request).map {
                SessionActivity(day: $0["day"], source: $0["source"], sessions: $0["sessions"], tokens: $0["tokens"])
            }
        }
    }
    private static func request(_ query: SessionQuery) -> QueryInterfaceRequest<Session> {
        var request = Self.visibleSessions
        if query.onlyNamed { request = request.filter(Column("isExplicitlyNamed") == true) }
        if let role = query.role { request = request.filter(Column("role") == role) }
        if let source = query.source { request = request.filter(Column("source") == source) }
        if query.attentionOnly {
            request = request.filter(sql: "(lower(COALESCE(status, '')) IN ('error', 'failed', 'waiting', 'waiting_for_input', 'waiting_for_approval'))")
        }
        if let profile = query.profileID { request = request.filter(Column("profileID") == profile) }
        if let parent = query.parentNativeID { request = request.filter(Column("parentNativeID") == parent) }
        if let since = query.since { request = request.filter(sql: "COALESCE(lastActivityAt, endedAt, startedAt) >= ?", arguments: [since]) }
        if let search = query.search, !search.isEmpty {
            request = request.filter(sql: "instr(lower(COALESCE(name, '') || ' ' || COALESCE(project, '') || ' ' || nativeID), lower(?)) > 0", arguments: [search])
        }
        return request
    }
    func fetchChildren(of session: Session, limit: Int = 50, offset: Int = 0) async throws -> [Session] {
        try await fetchSessions(query: SessionQuery(role: .child, source: session.source,
            parentNativeID: session.effectiveNativeID, profileID: session.profileID, limit: limit, offset: offset))
    }
    func sessionCounts() async throws -> SessionCounts {
        try await dbWriter.read { db in
            var result = SessionCounts()
            for row in try Row.fetchAll(db, Self.visibleSessions.select(sql: "role, COUNT(*) AS count").group(Column("role"))) {
                let count: Int = row["count"]
                switch row["role"] as String {
                case "main": result.main = count
                case "child": result.child = count
                case "internal": result.internalCount = count
                default: result.unknown = count
                }
            }
            return result
        }
    }
    func usage(query: SessionQuery = SessionQuery(), scope: UsageScope = .own) async throws -> SessionUsage {
        try await dbWriter.read { db in
            let selected = try Self.request(query).fetchAll(db)
            var sessions = selected
            if scope == .descendants {
                var visited = Set(selected.map(\.id))
                var pending = selected
                while let parent = pending.popLast() {
                    // Native aggregate usage must not be added to its own descendants.
                    guard parent.usageScope != "descendants" else { continue }
                    let children = try Self.visibleSessions.filter(Column("source") == parent.source)
                        .filter(Column("profileID") == parent.profileID)
                        .filter(Column("parentNativeID") == parent.effectiveNativeID).fetchAll(db)
                    for child in children where visited.insert(child.id).inserted {
                        sessions.append(child); pending.append(child)
                    }
                }
            }
            var usage = SessionUsage(scope: scope)
            for session in sessions {
                usage.inputTokens += session.inputTokens; usage.outputTokens += session.outputTokens
                usage.cacheReadTokens += session.cacheReadTokens; usage.cacheCreationTokens += session.cacheCreationTokens
                usage.tokensUsed += session.tokensUsed
                if !session.usageAvailable { usage.unavailableSessions += 1 }
                if !session.usageBreakdownAvailable { usage.breakdownUnavailableSessions += 1 }
            }
            return usage
        }
    }
    /// Resolve native ancestry with a visited set. Orphans and cycles have no asserted root.
    func resolveHierarchy(source: SessionSource, profileID: String) async throws {
        try await dbWriter.write { db in
            let sessions = try Session.filter(Column("source") == source).filter(Column("profileID") == profileID).fetchAll(db)
            let byNative = Dictionary(uniqueKeysWithValues: sessions.map { ($0.effectiveNativeID, $0) })
            for session in sessions {
                var cursor = session
                var visited = Set<String>()
                var root: String?
                while visited.insert(cursor.effectiveNativeID).inserted {
                    if cursor.role == .main { root = cursor.effectiveNativeID; break }
                    guard cursor.role == .child, let parent = cursor.parentNativeID,
                          let next = byNative[parent] else { break }
                    cursor = next
                }
                if session.rootNativeID != root {
                    try db.execute(sql: "UPDATE sessions SET rootNativeID = ? WHERE id = ?", arguments: [root, session.id])
                }
            }
        }
    }
    func setPinned(id: String, pinned: Bool) async throws {
        try await dbWriter.write { db in try db.execute(sql: "UPDATE sessions SET isPinned = ? WHERE id = ?", arguments: [pinned, id]) }
    }
    func checkpoint(path: String) async throws -> ReaderCheckpoint? {
        try await dbWriter.read { db in try ReaderCheckpoint.fetchOne(db, key: path) }
    }
    func saveCheckpoint(_ checkpoint: ReaderCheckpoint) async throws {
        try await dbWriter.write { db in try checkpoint.save(db) }
    }
}
struct ReaderCheckpoint: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "reader_checkpoints"
    var path: String
    var fingerprint: String
    var offset: Int64
    var state: Data?
}
