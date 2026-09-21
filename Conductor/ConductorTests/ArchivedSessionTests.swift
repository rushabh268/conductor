import Foundation
import GRDB
import Testing
@testable import Conductor

private func archiveSession(_ id: String, role: SessionRole = .main, parent: String? = nil, status: String? = nil) -> Session {
    Session(id: id, source: .codex, sessionType: .review, name: "Review example",
        cwd: "/fixture", project: "example", gitBranch: nil, ticketId: nil, status: status,
        model: nil, version: nil, messageCount: 1, toolCallCount: 0, tokensUsed: 10,
        inputTokens: 10, outputTokens: 0, startedAt: Date(), endedAt: nil,
        isExplicitlyNamed: true, cacheReadTokens: 0, cacheCreationTokens: 0,
        nativeID: id, role: role, parentNativeID: parent)
}

@Test func indexedArchivesAreExcludedFromEveryVisiblePopulationWithoutRescan() async throws {
    let db = try AppDatabase(inMemory: true)
    for role in SessionRole.allCases {
        try await db.saveSession(archiveSession("archived-\(role)", role: role, status: "archived"))
        var hidden = archiveSession("hidden-\(role)", role: role); hidden.isHidden = true
        try await db.saveSession(hidden)
    }
    try await db.saveSession(archiveSession("visible", status: "waiting"))
    let all = SessionQuery(role: nil)
    #expect(try await db.fetchSessions(query: all).map(\.nativeID) == ["visible"])
    #expect(try await db.countSessions(query: all) == 1)
    #expect(try await db.activity(query: all).reduce(0) { $0 + $1.sessions } == 1)
    #expect(try await db.usage(query: all).tokensUsed == 10)
    #expect(try await db.fetchAllSessions(onlyNamed: true).count == 1)
    #expect(try await db.fetchSessions(since: .distantPast).count == 1)
    #expect(try await db.fetchReviewSessions(since: .distantPast).count == 1)
    #expect(try await db.countSessions(query: SessionQuery(attentionOnly: true)) == 1)
    let counts = try await db.sessionCounts()
    #expect(counts.main == 1 && counts.child == 0 && counts.internalCount == 0 && counts.unknown == 0)
    let archived = try #require(await db.fetchSession(source: .codex, nativeID: "archived-main"))
    #expect(try await db.fetchSession(id: archived.id) == nil)
}

@Test func descendantUsageStopsAtArchivedAndHiddenBranchesAndTerminatesCycles() async throws {
    let db = try AppDatabase(inMemory: true)
    try await db.saveSession(archiveSession("root", parent: "visible-child"))
    for (id, status) in [("archived", "archived"), ("hidden", "waiting"), ("visible-child", "waiting")] {
        var child = archiveSession(id, role: .child, parent: "root", status: status)
        child.isHidden = id == "hidden"
        try await db.saveSession(child)
        if id != "visible-child" {
            try await db.saveSession(archiveSession("\(id)-grandchild", role: .child, parent: id))
        }
    }
    let root = try #require(await db.fetchSession(source: .codex, nativeID: "root"))
    #expect(try await db.fetchChildren(of: root).map(\.nativeID) == ["visible-child"])
    #expect(try await db.usage(scope: .descendants).tokensUsed == 20)
}

@Test(arguments: [SessionSource.codex, .opencode], [false, true])
func nativeArchiveRoundTripPreservesIdentityAndUserFlags(source: SessionSource, archiveColumn: Bool) async throws {
    let fixture = try CoreFixture(); defer { fixture.remove() }
    let root = source == .codex ? fixture.paths.codexRoot : fixture.paths.openCodeRoot
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let path = source == .codex ? root.appendingPathComponent("state_5.sqlite") : fixture.paths.openCodeDatabase
    let writer = try DatabaseQueue(path: path.path)
    try await writer.write { native in
        if source == .codex {
            try native.execute(sql: "CREATE TABLE threads(id TEXT PRIMARY KEY, cwd TEXT, title TEXT, created_at INTEGER, updated_at INTEGER)")
            try native.execute(sql: "INSERT INTO threads VALUES ('root', '/fixture', 'Review example', 1, 2), ('hidden', '/fixture', 'Hidden example', 1, 2)")
            if archiveColumn { try native.execute(sql: "ALTER TABLE threads ADD COLUMN archived INTEGER DEFAULT 0") }
        } else {
            try native.execute(sql: "CREATE TABLE session(id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT, title TEXT, version TEXT, time_created INTEGER, time_updated INTEGER)")
            try native.execute(sql: "INSERT INTO session VALUES ('root', NULL, '/fixture', 'Review example', 'fixture', 1, 2), ('hidden', NULL, '/fixture', 'Hidden example', 'fixture', 1, 2)")
            if archiveColumn { try native.execute(sql: "ALTER TABLE session ADD COLUMN time_archived INTEGER") }
        }
    }
    let local = try AppDatabase(inMemory: true)
    func ingest() async throws {
        let before = try Data(contentsOf: path)
        if source == .codex { try await CodexIngestor.ingestAll(into: local, paths: fixture.paths) }
        else { try await OpenCodeIngestor.ingestAll(into: local, paths: fixture.paths) }
        #expect(try Data(contentsOf: path) == before)
    }
    try await ingest()
    let original = try #require(await local.fetchSession(source: source, nativeID: "root"))
    let hidden = try #require(await local.fetchSession(source: source, nativeID: "hidden"))
    try await local.setPinned(id: original.id, pinned: true)
    try await local.deleteSession(id: hidden.id)
    #expect(try await local.fetchAllSessions().count == 1)
    guard archiveColumn else { #expect(original.status == nil); return }
    for archived in [true, false] {
        try await writer.write { native in
            if source == .codex { try native.execute(sql: "UPDATE threads SET archived = ?", arguments: [archived ? 1 : 0]) }
            else { try native.execute(sql: "UPDATE session SET time_archived = ?", arguments: [archived ? 3 : nil]) }
        }
        try await ingest()
        let current = try #require(await local.fetchSession(source: source, nativeID: "root"))
        #expect(current.id == original.id && current.isPinned && !current.isHidden)
        #expect(current.status == (archived ? "archived" : nil))
        #expect(try await local.fetchSession(source: source, nativeID: "hidden")?.isHidden == true)
        #expect(try await local.fetchAllSessions().count == (archived ? 0 : 1))
        // The checkpoint-skipped pass must preserve the same archive visibility.
        try await ingest()
        #expect(try await local.countSessions(query: SessionQuery()) == (archived ? 0 : 1))
    }
}
