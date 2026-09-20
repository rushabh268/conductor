import Foundation
import GRDB
import Testing
@testable import Conductor

@Test(arguments: [1, 2, 3]) func migratesHistoricalVersionsWithoutChangingLocalIdentity(version: Int) async throws {
    let fixture = try CoreFixture(); defer { fixture.remove() }
    let path = fixture.root.appendingPathComponent("legacy.db").path
    let queue = try DatabaseQueue(path: path)
    try await queue.write { db in
        try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
        for number in 1...version { try db.execute(sql: "INSERT INTO grdb_migrations VALUES (?)", arguments: ["v\(number)"]) }
        try db.execute(sql: """
            CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT NOT NULL, sessionType TEXT NOT NULL,
            name TEXT, cwd TEXT, project TEXT, gitBranch TEXT, ticketId TEXT, status TEXT, model TEXT, version TEXT,
            messageCount INTEGER NOT NULL DEFAULT 0, toolCallCount INTEGER NOT NULL DEFAULT 0,
            tokensUsed INTEGER NOT NULL DEFAULT 0, startedAt DATETIME NOT NULL, endedAt DATETIME)
            """)
        if version >= 2 {
            try db.execute(sql: "ALTER TABLE sessions ADD COLUMN inputTokens INTEGER NOT NULL DEFAULT 0")
            try db.execute(sql: "ALTER TABLE sessions ADD COLUMN outputTokens INTEGER NOT NULL DEFAULT 0")
        }
        if version >= 3 {
            try db.execute(sql: "ALTER TABLE sessions ADD COLUMN isExplicitlyNamed BOOLEAN NOT NULL DEFAULT 0")
            try db.execute(sql: "ALTER TABLE sessions ADD COLUMN cacheReadTokens INTEGER NOT NULL DEFAULT 0")
            try db.execute(sql: "ALTER TABLE sessions ADD COLUMN cacheCreationTokens INTEGER NOT NULL DEFAULT 0")
        }
        try db.execute(sql: "INSERT INTO sessions (id, source, sessionType, name, tokensUsed, startedAt) VALUES ('stable-id', 'claude', 'coding', 'kept', 55, ?)", arguments: [Date()])
        if version >= 3 { try db.execute(sql: "UPDATE sessions SET cacheReadTokens = 20, cacheCreationTokens = 10, isExplicitlyNamed = 1") }
    }
    let migrated = try AppDatabase(path: path)
    let session = try #require(await migrated.fetchSession(id: "stable-id"))
    #expect(session.nativeID == "stable-id")
    #expect(session.role == .unknown)
    #expect(session.name == "kept")
    #expect(session.tokensUsed == 55)
    if version == 3 { #expect(session.cacheReadTokens == 20); #expect(session.cacheCreationTokens == 10) }
    var reindexed = session; reindexed.role = .main
    let saved = try await migrated.saveSession(reindexed)
    #expect(saved.id == "stable-id")
    #expect(try await migrated.fetchAllSessions().count == 1)
}

@Test func failedBackfillRetriesAfterRestartAndDoesNotCrossDatabases() async throws {
    let fixture = try CoreFixture(); defer { fixture.remove() }
    let project = fixture.paths.claudeProjects.appendingPathComponent("synthetic")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let transcript = project.appendingPathComponent("root.jsonl")
    try Data("malformed\n".utf8).write(to: transcript)
    let path = fixture.root.appendingPathComponent("conductor.db").path
    let first = try AppDatabase(path: path)
    await #expect(throws: (any Error).self) { try await ClaudeIngestor.backfillHistoricalSessionsIfNeeded(into: first, paths: fixture.paths) }
    #expect(try await first.checkpoint(path: "claude:default:\(transcript.path)") == nil)
    try Data("{\"type\":\"custom-title\",\"customTitle\":\"repaired\"}\n".utf8).write(to: transcript)
    let restarted = try AppDatabase(path: path)
    try await ClaudeIngestor.backfillHistoricalSessionsIfNeeded(into: restarted, paths: fixture.paths)
    #expect(try await restarted.fetchAllSessions().first?.name == "repaired")
    let unrelated = try AppDatabase(inMemory: true)
    try await ClaudeIngestor.backfillHistoricalSessionsIfNeeded(into: unrelated, paths: fixture.paths)
    #expect(try await unrelated.fetchAllSessions().count == 1)
}

@Test func malformedTranscriptDoesNotPreventOtherBackfillFiles() async throws {
    let fixture = try CoreFixture(); defer { fixture.remove() }
    let project = fixture.paths.claudeProjects.appendingPathComponent("synthetic")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try Data("malformed\n".utf8).write(to: project.appendingPathComponent("broken.jsonl"))
    try Data("{\"type\":\"user\",\"message\":{\"content\":\"good\"}}\n".utf8).write(to: project.appendingPathComponent("good.jsonl"))
    let db = try AppDatabase(inMemory: true)
    await #expect(throws: (any Error).self) { try await ClaudeIngestor.backfillHistoricalSessionsIfNeeded(into: db, paths: fixture.paths) }
    #expect(try await db.fetchSession(source: .claude, nativeID: "good")?.messageCount == 1)
}
