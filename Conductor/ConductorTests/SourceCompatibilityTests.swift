import Foundation
import GRDB
import Testing
@testable import Conductor

private func fixtureSession(_ id: String, source: SessionSource = .claude, role: SessionRole = .main, parent: String? = nil) -> Session {
    var session = Session(id: id, source: source, sessionType: .coding, name: nil, cwd: nil, project: nil,
        gitBranch: nil, ticketId: nil, status: nil, model: nil, version: nil, messageCount: 0,
        toolCallCount: 0, tokensUsed: 10, inputTokens: 3, outputTokens: 7, startedAt: Date(),
        endedAt: nil, isExplicitlyNamed: false, cacheReadTokens: 0, cacheCreationTokens: 0)
    session.nativeID = id; session.role = role; session.parentNativeID = parent
    return session
}

@Test func hierarchyScopesNamesAndCollidingNativeIDs() async throws {
    let db = try AppDatabase(inMemory: true)
    for source in SessionSource.allCases {
        var root = fixtureSession("root", source: source)
        root = try await db.saveSession(root)
        for index in 0..<300 {
            var child = fixtureSession("child-\(index)", source: source, role: .child, parent: "root")
            child.name = "Named child"; child.isExplicitlyNamed = true
            try await db.saveSession(child)
        }
        let rows = try await db.fetchSessions(query: SessionQuery(source: source))
        #expect(rows.count == 1)
        #expect(rows.first?.name == nil)
        #expect(try await db.fetchChildren(of: root, limit: 500).count == 300)
        #expect(try await db.usage(query: SessionQuery(source: source), scope: .own).tokensUsed == 10)
        #expect(try await db.usage(query: SessionQuery(source: source), scope: .descendants).tokensUsed == 3010)
    }
    #expect(try await db.sessionCounts().main == 3)
    #expect(Set(try await db.fetchAllSessions().map(\.id)).count == 3)
}

@Test func hiddenRowsStayHiddenAfterReingestionAndCyclesTerminate() async throws {
    let db = try AppDatabase(inMemory: true)
    let original = fixtureSession("root")
    let saved = try await db.saveSession(original)
    try await db.deleteSession(id: saved.id)
    try await db.saveSession(original)
    #expect(try await db.fetchAllSessions().isEmpty)
    try await db.saveSession(fixtureSession("a", role: .child, parent: "b"))
    try await db.saveSession(fixtureSession("b", role: .child, parent: "a"))
    #expect(try await db.usage(query: SessionQuery(role: .child), scope: .descendants).tokensUsed == 20)
}

@Test func currentCodexStructuredSourceAndPagedRolloutReadOnly() async throws {
    let fixture = try CoreFixture(); defer { fixture.remove() }
    try FileManager.default.createDirectory(at: fixture.paths.codexRoot, withIntermediateDirectories: true)
    let path = fixture.paths.codexRoot.appendingPathComponent("state_5.sqlite")
    let rollout = fixture.paths.codexRoot.appendingPathComponent("nested-rollout.jsonl")
    let lines = (0..<120).map { "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"message \($0)\"}]}}" }.joined(separator: "\n") + "\n"
    try Data(lines.utf8).write(to: rollout)
    let queue = try DatabaseQueue(path: path.path)
    try await queue.write { db in
        try db.execute(sql: "CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, title TEXT, created_at INTEGER, updated_at INTEGER, source TEXT, thread_source TEXT, rollout_path TEXT, tokens_used INTEGER, archived INTEGER, name TEXT)")
        try db.execute(sql: "INSERT INTO threads VALUES ('root', '/synthetic', '', 100, 200, 'appServer', NULL, ?, 42, 0, NULL)", arguments: [rollout.path])
        for index in 0..<300 {
            try db.execute(sql: "INSERT INTO threads VALUES (?, '/synthetic', 'named-child', 100, 200, ?, NULL, NULL, 1, 0, NULL)",
                arguments: ["child-\(index)", "{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"root\"}}}"])
        }
    }
    let before = try Data(contentsOf: path)
    let db = try AppDatabase(inMemory: true)
    try await CodexIngestor.ingestAll(into: db, paths: fixture.paths)
    let roots = try await db.fetchAllSessions()
    #expect(roots.count == 1)
    #expect(try await db.sessionCounts().child == 300)
    let first = try await TranscriptLoader.loadPage(for: #require(roots.first))
    #expect(first.messages.count == 50)
    let second = try await TranscriptLoader.loadPage(for: #require(roots.first), offset: #require(first.nextOffset))
    #expect(second.messages.first?.text == "message 50")
    #expect(try Data(contentsOf: path) == before)
    try await CodexIngestor.ingestAll(into: db, paths: fixture.paths)
    #expect(try await db.fetchAllSessions().count == 1)
    #expect(CodexIngestor.classify(source: "{\"future\":{}}", threadSource: nil).role == .unknown)
    #expect(CodexIngestor.classify(source: nil, threadSource: "subagent").role == .child)
}

@Test func openCodeCurrentSchemaDiscoveryChildrenTranscriptAndUsage() async throws {
    let fixture = try CoreFixture(); defer { fixture.remove() }
    try FileManager.default.createDirectory(at: fixture.paths.openCodeRoot, withIntermediateDirectories: true)
    let path = fixture.paths.openCodeDatabase
    let queue = try DatabaseQueue(path: path.path)
    try await queue.write { db in
        try db.execute(sql: "CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT, title TEXT, version TEXT, time_created INTEGER, time_updated INTEGER, tokens_input INTEGER, tokens_output INTEGER, tokens_cache_read INTEGER, tokens_cache_write INTEGER)")
        try db.execute(sql: "CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)")
        try db.execute(sql: "CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)")
        try db.execute(sql: "INSERT INTO session VALUES ('root', NULL, '/synthetic', '', '1.18.20', 1000, 2000, 3, 7, 5, 2)")
        for index in 0..<300 { try db.execute(sql: "INSERT INTO session VALUES (?, 'root', '/synthetic', 'named child', '1.18.20', 1000, 2000, 0, 0, 0, 0)", arguments: ["child-\(index)"]) }
        for index in 0..<55 {
            try db.execute(sql: "INSERT INTO message VALUES (?, 'root', ?, ?, ?)", arguments: ["m\(index)", index, index, "{\"role\":\"user\"}"])
            try db.execute(sql: "INSERT INTO part VALUES (?, ?, 'root', ?, ?, ?)", arguments: ["p\(index)", "m\(index)", index, index, "{\"type\":\"text\",\"text\":\"message \(index)\"}"])
        }
    }
    let before = try Data(contentsOf: path)
    let db = try AppDatabase(inMemory: true)
    try await OpenCodeIngestor.ingestAll(into: db, paths: fixture.paths)
    let root = try #require(await db.fetchAllSessions().first)
    #expect(root.source == .opencode)
    #expect(try await db.sessionCounts().child == 300)
    #expect(try await db.usage().tokensUsed == 17)
    let page = try await TranscriptLoader.loadPage(for: root)
    #expect(page.messages.count == 50)
    let next = try await TranscriptLoader.loadPage(for: root, offset: #require(page.nextOffset))
    #expect(next.messages.count == 5)
    #expect(next.messages.first?.text == "message 50")
    #expect(try Data(contentsOf: path) == before)
}

@Test func claudeNestedChildrenNeverRequireReadableTranscriptsAndIncrementalRetry() async throws {
    let fixture = try CoreFixture(); defer { fixture.remove() }
    let project = fixture.paths.claudeProjects.appendingPathComponent("synthetic")
    let children = project.appendingPathComponent("root/subagents")
    try FileManager.default.createDirectory(at: children, withIntermediateDirectories: true)
    let transcript = project.appendingPathComponent("root.jsonl")
    let line = "{\"type\":\"user\",\"cwd\":\"/synthetic\",\"message\":{\"content\":\"hello\"}}\n"
    try Data(line.utf8).write(to: transcript)
    for index in 0..<300 { try Data("not JSON; metadata discovery must not open this".utf8).write(to: children.appendingPathComponent("agent-\(index).jsonl")) }
    let db = try AppDatabase(inMemory: true)
    try await ClaudeIngestor.ingestAll(into: db, paths: fixture.paths)
    #expect(try await db.fetchAllSessions().count == 1)
    #expect(try await db.sessionCounts().child == 300)
    var root = try #require(await db.fetchSession(source: .claude, nativeID: "root"))
    #expect(root.messageCount == 1)
    #expect(try await TranscriptLoader.loadPage(for: root).messages.first?.text == "hello")
    let key = "claude:default:\(transcript.path)"
    let checkpoint = try #require(await db.checkpoint(path: key))
    try await ClaudeIngestor.ingestAll(into: db, paths: fixture.paths)
    #expect(try await db.checkpoint(path: key)?.offset == checkpoint.offset)
    let file = try FileHandle(forWritingTo: transcript)
    try file.seekToEnd(); try file.write(contentsOf: Data("{\"type\":\"user\"".utf8)); try file.close()
    try await ClaudeIngestor.ingestAll(into: db, paths: fixture.paths)
    #expect(try await db.checkpoint(path: key)?.offset == checkpoint.offset)
    let append = try FileHandle(forWritingTo: transcript)
    try append.seekToEnd(); try append.write(contentsOf: Data(",\"message\":{\"content\":\"second\"}}\n".utf8)); try append.close()
    try await ClaudeIngestor.ingestAll(into: db, paths: fixture.paths)
    root = try #require(await db.fetchSession(source: .claude, nativeID: "root"))
    #expect(root.messageCount == 2)
    // Truncation must reset cumulative counts instead of appending to the old state.
    try Data(line.utf8).write(to: transcript)
    try await ClaudeIngestor.ingestAll(into: db, paths: fixture.paths)
    #expect(try await db.fetchSession(source: .claude, nativeID: "root")?.messageCount == 1)
}

@Test func retentionUsesActivityAndKeepsKnownActiveRoots() async throws {
    let db = try AppDatabase(inMemory: true)
    var recent = fixtureSession("recent")
    recent.startedAt = .distantPast; recent.lastActivityAt = Date()
    var active = fixtureSession("active")
    active.startedAt = .distantPast; active.status = "busy"
    var old = fixtureSession("old"); old.startedAt = .distantPast
    try await db.saveSession(recent); try await db.saveSession(active); try await db.saveSession(old)
    try await db.pruneOldRecords(olderThan: 1)
    #expect(try await db.fetchAllSessions().count == 2)
}

@Test func nativeDatabaseRejectsWritesAndUnsupportedSchema() throws {
    let fixture = try CoreFixture(); defer { fixture.remove() }
    let path = fixture.root.appendingPathComponent("native.sqlite")
    let writer = try DatabaseQueue(path: path.path)
    try writer.write { try $0.execute(sql: "CREATE TABLE fixture (id TEXT PRIMARY KEY)") }
    let reader = try NativeDatabase.open(path, table: "fixture", required: ["id"])
    #expect(throws: (any Error).self) { try reader.write { try $0.execute(sql: "INSERT INTO fixture VALUES ('forbidden')") } }
    #expect(throws: (any Error).self) { try NativeDatabase.open(path, table: "fixture", required: ["missing"]) }
    #expect(try writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM fixture") } == 0)
}

@Test func flatClaudeMessageParentsNeverBecomeSessionParents() async throws {
    let fixture = try CoreFixture(); defer { fixture.remove() }
    let project = fixture.paths.claudeProjects.appendingPathComponent("synthetic")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try Data("{\"type\":\"user\",\"isSidechain\":true,\"parentUuid\":\"message-id\",\"message\":{\"content\":\"child\"}}\n".utf8).write(to: project.appendingPathComponent("orphan.jsonl"))
    try Data("{\"type\":\"user\",\"isSidechain\":true,\"parentSessionId\":\"absent-root\",\"message\":{\"content\":\"child\"}}\n".utf8).write(to: project.appendingPathComponent("child.jsonl"))
    let db = try AppDatabase(inMemory: true)
    try await ClaudeIngestor.ingestAll(into: db, paths: fixture.paths)
    #expect(try await db.fetchAllSessions().isEmpty)
    #expect(try await db.fetchSession(source: .claude, nativeID: "orphan")?.role == .unknown)
    #expect(try await db.fetchSession(source: .claude, nativeID: "child")?.role == .child)
    #expect(try await db.fetchSession(source: .claude, nativeID: "child")?.rootNativeID == nil)
}

@Test func sharedNameFilterKeepsQueryAndUsagePopulationIdentical() async throws {
    let db = try AppDatabase(inMemory: true)
    var named = fixtureSession("named")
    named.name = "Native name"; named.isExplicitlyNamed = true
    try await db.saveSession(named)
    try await db.saveSession(fixtureSession("unnamed"))
    var child = fixtureSession("child", role: .child, parent: "named")
    child.name = "Child title"; child.isExplicitlyNamed = true
    try await db.saveSession(child)
    let query = SessionQuery(onlyNamed: true)
    #expect(try await db.fetchSessions(query: query).count == 1)
    #expect(try await db.usage(query: query).tokensUsed == 10)
    #expect(try await db.usage(query: query, scope: .descendants).tokensUsed == 20)
    #expect(try await db.fetchSessions(query: SessionQuery()).count == 2)
}
