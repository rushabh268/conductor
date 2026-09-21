import Foundation
import Testing
import GRDB
@testable import Conductor

private actor IngestionGate {
    var calls = 0
    var continuation: CheckedContinuation<Void, Never>?
    func run() async {
        calls += 1
        if calls == 1 { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor @Test func refreshRequestsCoalesceBehindSingleFlight() async throws {
    let fixture = try CoreFixture(); defer { fixture.remove() }
    let gate = IngestionGate()
    let coordinator = IngestionCoordinator(db: try AppDatabase(inMemory: true), paths: fixture.paths, operation: { await gate.run() })
    let first = Task { await coordinator.runIngestion() }
    let deadline = Date().addingTimeInterval(5)
    while await gate.calls == 0 && Date() < deadline { await Task.yield() }
    #expect(await gate.calls == 1)
    let requests = (0..<20).map { _ in Task { await coordinator.runIngestion() } }
    while !coordinator.hasPendingRefresh && Date() < deadline { await Task.yield() }
    #expect(coordinator.hasPendingRefresh)
    #expect(await gate.calls == 1)
    await gate.release()
    await first.value
    for task in requests { await task.value }
    #expect(await gate.calls == 2)
    #expect(!coordinator.isIngesting)
    coordinator.stop()
}

@MainActor @Test func stopCancelsTrailingRefresh() async throws {
    let fixture = try CoreFixture(); defer { fixture.remove() }
    let gate = IngestionGate()
    let coordinator = IngestionCoordinator(db: try AppDatabase(inMemory: true), paths: fixture.paths, operation: { await gate.run() })
    let first = Task { await coordinator.runIngestion() }
    let deadline = Date().addingTimeInterval(5)
    while await gate.calls == 0 && Date() < deadline { await Task.yield() }
    let pending = Task { await coordinator.runIngestion() }
    while !coordinator.hasPendingRefresh && Date() < deadline { await Task.yield() }
    coordinator.stop()
    await gate.release()
    await first.value; await pending.value
    #expect(await gate.calls == 1)
    #expect(coordinator.lastIngestionAt == nil)
}

@Test func gitDrainsOutputLargerThanPipeCapacityAndChecksExitStatus() async throws {
    let fixture = try CoreFixture(); defer { fixture.remove() }
    // This fixed, process-local alias writes stdout only; no Git configuration is persisted.
    let output = try await GitIngestor.runGit(in: fixture.root.path, args: ["-c", "alias.large=!/usr/bin/yes x | /usr/bin/head -c 200000", "large"])
    #expect(output.utf8.count > 190000)
    await #expect(throws: (any Error).self) {
        try await GitIngestor.runGit(in: fixture.root.path, args: ["rev-parse", "--verify", "missing"])
    }
}

@MainActor @Test func unsupportedSchemaReportsReaderHealthWithoutChangingNativeLifecycle() async throws {
    let fixture = try CoreFixture(); defer { fixture.remove() }
    try FileManager.default.createDirectory(at: fixture.paths.codexRoot, withIntermediateDirectories: true)
    let nativeURL = fixture.paths.codexRoot.appendingPathComponent("state_5.sqlite")
    let writer = try DatabaseQueue(path: nativeURL.path)
    try await writer.write { try $0.execute(sql: "CREATE TABLE threads(id TEXT PRIMARY KEY)") }
    #expect(throws: NativeReaderError.self) {
        _ = try NativeDatabase.open(nativeURL, table: "threads", required: ["id", "title"])
    }
    let database = try AppDatabase(inMemory: true)
    let retained = CodexIngestor.parseThread(id: "retained", cwd: "/fixture", title: "Example",
        gitBranch: nil, gitOriginUrl: nil, tokensUsed: 42, model: nil, cliVersion: nil,
        createdAt: Int(Date().timeIntervalSince1970), updatedAt: Int(Date().timeIntervalSince1970), firstUserMessage: nil)
    let saved = try await database.saveSession(retained)
    try FileManager.default.createDirectory(at: fixture.paths.claudeSessions, withIntermediateDirectories: true)
    for status in ["waiting", "error"] {
        let data = Data("{\"pid\":123,\"sessionId\":\"\(status)\",\"cwd\":\"/fixture\",\"startedAt\":\(Int(Date().timeIntervalSince1970 * 1000)),\"status\":\"\(status)\",\"kind\":\"interactive\"}".utf8)
        try data.write(to: fixture.paths.claudeSessions.appendingPathComponent("\(status).json"))
    }
    let coordinator = IngestionCoordinator(db: database, paths: fixture.paths)
    await coordinator.runIngestion()
    let health = try #require(coordinator.readerHealth.first { $0.source == .codex })
    #expect(health.status == "unavailable")
    #expect(health.detail.contains("schema is unsupported"))
    let after = try #require(await database.fetchSession(source: .codex, nativeID: "retained"))
    #expect(after == saved)
    #expect(after.attentionReason == nil)
    let attention = try await database.fetchSessions(query: SessionQuery(attentionOnly: true))
    #expect(Set(attention.map(\.nativeID)) == ["waiting", "error"])
    #expect(attention.allSatisfy { $0.attentionReason != nil })
    coordinator.stop()
}
