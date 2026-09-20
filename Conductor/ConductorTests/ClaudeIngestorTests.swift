import Testing
import Foundation
@testable import Conductor

@Test func parseClaudeSessionFile() throws {
    let json = """
    {
        "pid": 28159,
        "sessionId": "7fe2e055-0269-41a9-97ec-dbab90b0cfe7",
        "cwd": "/Users/test/work/conductor",
        "startedAt": 1778003922013,
        "procStart": "Tue May  5 17:58:41 2026",
        "version": "2.1.128",
        "peerProtocol": 1,
        "kind": "interactive",
        "entrypoint": "cli",
        "status": "busy",
        "updatedAt": 1778005243203,
        "name": "conductor"
    }
    """.data(using: .utf8)!

    let session = try ClaudeIngestor.parseSessionFile(data: json)
    #expect(session.id == "7fe2e055-0269-41a9-97ec-dbab90b0cfe7")
    #expect(session.source == .claude)
    #expect(session.name == "conductor")
    #expect(session.cwd == "/Users/test/work/conductor")
    #expect(session.project == "conductor")
    #expect(session.status == "busy")
    #expect(session.version == "2.1.128")
    #expect(session.isExplicitlyNamed == true)
}

@Test func parseClaudeSessionFileWithDerivedNameIsNotExplicitlyNamed() throws {
    let json = """
    {
        "pid": 28159,
        "sessionId": "7fe2e055-0269-41a9-97ec-dbab90b0cfe7",
        "cwd": "/Users/test/work/conductor",
        "startedAt": 1778003922013,
        "version": "2.1.128",
        "kind": "interactive",
        "entrypoint": "cli",
        "status": "busy",
        "updatedAt": 1778005243203,
        "name": "project-c3",
        "nameSource": "derived"
    }
    """.data(using: .utf8)!

    let session = try ClaudeIngestor.parseSessionFile(data: json)
    #expect(session.name == "project-c3")
    #expect(session.isExplicitlyNamed == false)
}

@Test func parseClaudeSessionFileWithBlankNameIsNotExplicitlyNamed() throws {
    // No nameSource field (so nameSource != "derived" is vacuously true) and a
    // blank name — regression test for finding 8: a blank name must never be
    // treated as explicitly named just because nameSource isn't "derived".
    let json = """
    {
        "pid": 28159,
        "sessionId": "7fe2e055-0269-41a9-97ec-dbab90b0cfe9",
        "cwd": "/Users/test/work/conductor",
        "startedAt": 1778003922013,
        "version": "2.1.128",
        "kind": "interactive",
        "entrypoint": "cli",
        "status": "busy",
        "updatedAt": 1778005243203,
        "name": "   "
    }
    """.data(using: .utf8)!

    let session = try ClaudeIngestor.parseSessionFile(data: json)
    #expect(session.isExplicitlyNamed == false)
}

@Test func parseClaudeSessionFileWithNilNameIsNotExplicitlyNamed() throws {
    // "name" key omitted entirely (decodes to nil) and no nameSource field —
    // covers the nil-coalescing branch of finding 8's fix.
    let json = """
    {
        "pid": 28159,
        "sessionId": "7fe2e055-0269-41a9-97ec-dbab90b0cfea",
        "cwd": "/Users/test/work/conductor",
        "startedAt": 1778003922013,
        "version": "2.1.128",
        "kind": "interactive",
        "entrypoint": "cli",
        "status": "busy",
        "updatedAt": 1778005243203
    }
    """.data(using: .utf8)!

    let session = try ClaudeIngestor.parseSessionFile(data: json)
    #expect(session.name == nil)
    #expect(session.isExplicitlyNamed == false)
}

@Test func parseClaudeReviewSession() throws {
    let json = """
    {
        "pid": 16065,
        "sessionId": "5753e16d-4fec-42d2-929e-233e9ea7df2d",
        "cwd": "/Users/test/go/src/project",
        "startedAt": 1777499543568,
        "version": "2.1.122",
        "kind": "interactive",
        "entrypoint": "cli",
        "status": "idle",
        "updatedAt": 1777500719760,
        "name": "pr-review-1"
    }
    """.data(using: .utf8)!

    let session = try ClaudeIngestor.parseSessionFile(data: json)
    #expect(session.sessionType == .review)
    #expect(session.project == "project")
}

@Test func countSessionStatsIncludesCacheTokens() throws {
    // All source files live under this test-owned temporary profile.
    let fixture = try CoreFixture()
    defer { fixture.remove() }
    let cwd = "/tmp/conductor-test-fixture-cache-tokens"
    let sessionId = "cache-token-test-session"
    guard let path = ClaudeTokenCounter.jsonlPath(sessionId: sessionId, cwd: cwd, paths: fixture.paths) else {
        Issue.record("jsonlPath returned nil for non-nil cwd")
        return
    }
    let dir = (path as NSString).deletingLastPathComponent
    defer { try? FileManager.default.removeItem(atPath: dir) }

    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let line = """
    {"type":"assistant","message":{"usage":{"input_tokens":3,"cache_creation_input_tokens":100,"cache_read_input_tokens":50,"output_tokens":41}}}
    """
    try line.write(toFile: path, atomically: true, encoding: .utf8)

    let stats = ClaudeIngestor.countSessionStats(sessionId: sessionId, cwd: cwd, paths: fixture.paths)
    #expect(stats.cacheReadTokens == 50)
    #expect(stats.cacheCreationTokens == 100)
    #expect(stats.tokensUsed == 3 + 41 + 100 + 50)
}

@Test func historicalSessionRenameUsesLastSeenTitleNotFirstSeen() async throws {
    // Exercise discovery through the public entry point with an isolated profile.
    let fixture = try CoreFixture()
    defer { fixture.remove() }
    let fakeHash = "conductor-test-fixture-rename-check"
    let sessionId = "conductor-test-rename-session"
    let projectDir = fixture.paths.claudeProjects.appendingPathComponent(fakeHash)
    defer { try? FileManager.default.removeItem(at: projectDir) }

    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    let jsonlFile = projectDir.appendingPathComponent("\(sessionId).jsonl")
    let lines = """
    {"type":"custom-title","customTitle":"first-name","sessionId":"\(sessionId)"}
    {"type":"custom-title","customTitle":"second-name","sessionId":"\(sessionId)"}
    """
    try lines.write(to: jsonlFile, atomically: true, encoding: .utf8)

    let db = try AppDatabase(inMemory: true)
    try await ClaudeIngestor.ingestHistoricalSessions(into: db, paths: fixture.paths)

    let session = try await db.fetchSession(source: .claude, nativeID: sessionId)
    #expect(session?.name == "second-name")
    #expect(session?.isExplicitlyNamed == true)
}

@Test func backfillHistoricalSessionsFillsInV3FieldsOnce() async throws {
    // Finding 5+7: pre-v3 rows were frozen at isExplicitlyNamed=false, cacheReadTokens=0,
    // cacheCreationTokens=0 forever. backfillHistoricalSessionsIfNeeded is the one-time fix.

    let fixture = try CoreFixture()
    defer { fixture.remove() }
    let fakeHash = "conductor-test-fixture-backfill-check"
    let sessionId = "conductor-test-backfill-session"
    let projectDir = fixture.paths.claudeProjects.appendingPathComponent(fakeHash)
    defer { try? FileManager.default.removeItem(at: projectDir) }

    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    let jsonlFile = projectDir.appendingPathComponent("\(sessionId).jsonl")
    let lines = """
    {"type":"custom-title","customTitle":"backfilled-title","sessionId":"\(sessionId)"}
    {"type":"assistant","message":{"usage":{"input_tokens":5,"output_tokens":7,"cache_creation_input_tokens":121029484,"cache_read_input_tokens":954654858}}}
    """
    try lines.write(to: jsonlFile, atomically: true, encoding: .utf8)

    let db = try AppDatabase(inMemory: true)

    // Simulate a pre-v3 row: defaulted isExplicitlyNamed=false, cache tokens=0,
    // tokensUsed using the old input+output-only formula.
    let preV3Session = Session(
        id: sessionId, source: .claude, sessionType: .coding, name: "old-derived-name",
        cwd: nil, project: "test", gitBranch: nil, ticketId: nil,
        status: nil, model: nil, version: nil,
        messageCount: 0, toolCallCount: 0, tokensUsed: 12,
        inputTokens: 5, outputTokens: 7, startedAt: Date(), endedAt: nil,
        isExplicitlyNamed: false, cacheReadTokens: 0, cacheCreationTokens: 0
    )
    try await db.saveSession(preV3Session)

    try await ClaudeIngestor.backfillHistoricalSessionsIfNeeded(into: db, paths: fixture.paths)

    let backfilled = try await db.fetchSession(source: .claude, nativeID: sessionId)
    #expect(backfilled?.isExplicitlyNamed == true)
    #expect(backfilled?.name == "backfilled-title")
    #expect(backfilled?.cacheReadTokens == 954654858)
    #expect(backfilled?.cacheCreationTokens == 121029484)
    #expect(backfilled?.tokensUsed == 5 + 7 + 121029484 + 954654858)

    // A persisted file checkpoint makes a second unchanged pass a no-op.
    try await ClaudeIngestor.backfillHistoricalSessionsIfNeeded(into: db, paths: fixture.paths)
}

@Test func backfillSkipsRowWhenJsonlParseYieldsNoData() async throws {
    // parseJsonlMetadata returns an all-zero/nil struct on any read failure
    // (I/O error, invalid UTF-8, huge file). Backfill must NOT clobber an
    // existing row to zeros in that case — it's a one-time pass, so a
    // clobbered row would stay wrong forever.

    let fixture = try CoreFixture()
    defer { fixture.remove() }
    let fakeHash = "conductor-test-fixture-backfill-empty-check"
    let sessionId = "conductor-test-backfill-empty-session"
    let projectDir = fixture.paths.claudeProjects.appendingPathComponent(fakeHash)
    defer { try? FileManager.default.removeItem(at: projectDir) }

    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    let jsonlFile = projectDir.appendingPathComponent("\(sessionId).jsonl")
    // Empty file: parseJsonlMetadata will parse zero lines, yielding a metadata
    // struct with explicitName == nil and all token counts == 0.
    try "".write(to: jsonlFile, atomically: true, encoding: .utf8)

    let db = try AppDatabase(inMemory: true)
    let preV3Session = Session(
        id: sessionId, source: .claude, sessionType: .coding, name: "existing-name",
        cwd: nil, project: "test", gitBranch: nil, ticketId: nil,
        status: nil, model: nil, version: nil,
        messageCount: 3, toolCallCount: 1, tokensUsed: 500,
        inputTokens: 300, outputTokens: 200, startedAt: Date(), endedAt: nil,
        isExplicitlyNamed: false, cacheReadTokens: 0, cacheCreationTokens: 0
    )
    try await db.saveSession(preV3Session)

    try await ClaudeIngestor.backfillHistoricalSessionsIfNeeded(into: db, paths: fixture.paths)

    let after = try await db.fetchSession(source: .claude, nativeID: sessionId)
    #expect(after?.name == "existing-name")
    #expect(after?.inputTokens == 300)
    #expect(after?.outputTokens == 200)
    #expect(after?.tokensUsed == 500)
}

@Test func parseStatsCacheFile() throws {
    let json = """
    {
        "version": 3,
        "dailyActivity": [
            {"date": "2026-04-21", "messageCount": 353, "sessionCount": 9, "toolCallCount": 0}
        ],
        "dailyModelTokens": [
            {"date": "2026-04-21", "tokensByModel": {"claude-opus-4-6": 363111}}
        ]
    }
    """.data(using: .utf8)!

    let stats = try ClaudeIngestor.parseStatsCache(data: json)
    #expect(stats.count == 1)
    #expect(stats[0].date == "2026-04-21")
    #expect(stats[0].messageCount == 353)
    #expect(stats[0].sessionCount == 9)
    #expect(stats[0].tokensUsed == 363111)
}
