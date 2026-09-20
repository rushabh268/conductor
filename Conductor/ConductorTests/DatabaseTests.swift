import Testing
import Foundation
import GRDB
@testable import Conductor

@Test func createDatabaseAndInsertSession() async throws {
    let db = try AppDatabase(inMemory: true)

    let session = Session(
        id: "test-123",
        source: .claude,
        sessionType: .coding,
        name: "test-session",
        cwd: "/Users/test/project",
        project: "project",
        gitBranch: "main",
        ticketId: nil,
        status: "idle",
        model: "claude-opus-4-6",
        version: "2.1.128",
        messageCount: 42,
        toolCallCount: 10,
        tokensUsed: 5000,
        inputTokens: 0, outputTokens: 0, startedAt: Date(),
        endedAt: nil,
        isExplicitlyNamed: true, cacheReadTokens: 0, cacheCreationTokens: 0
    )

    try await db.saveSession(session)
    let fetched = try await db.fetchSession(id: "test-123")
    #expect(fetched?.name == "test-session")
    #expect(fetched?.source == .claude)
    #expect(fetched?.sessionType == .coding)
}

@Test func createRepoAndBranch() async throws {
    let db = try AppDatabase(inMemory: true)

    let repo = try await db.saveRepo(Repo(
        id: nil,
        path: "/Users/test/project",
        originUrl: "git@github.com:org/project.git",
        lastScannedAt: Date()
    ))

    let branch = Branch(
        id: nil,
        repoId: repo.id!,
        name: "feature/TASK-123-rate-limit",
        ticketId: "TASK-123",
        firstSeenAt: Date(),
        lastSeenAt: Date()
    )
    try await db.saveBranch(branch)

    let branches = try await db.fetchBranches(repoId: repo.id!)
    #expect(branches.count == 1)
    #expect(branches.first?.ticketId == "TASK-123")
}

@Test func deleteSession() async throws {
    let db = try AppDatabase(inMemory: true)

    let session = Session(
        id: "delete-me",
        source: .claude,
        sessionType: .coding,
        name: "to-delete",
        cwd: "/tmp",
        project: "test",
        gitBranch: nil,
        ticketId: nil,
        status: nil,
        model: nil,
        version: nil,
        messageCount: 0,
        toolCallCount: 0,
        tokensUsed: 0,
        inputTokens: 0, outputTokens: 0, startedAt: Date(),
        endedAt: nil,
        isExplicitlyNamed: true, cacheReadTokens: 0, cacheCreationTokens: 0
    )
    try await db.saveSession(session)

    // Verify it exists
    let before = try await db.fetchSession(id: "delete-me")
    #expect(before != nil)

    // Delete
    try await db.deleteSession(id: "delete-me")

    // Verify it's gone
    let after = try await db.fetchSession(id: "delete-me")
    #expect(after == nil)
}

@Test func deleteNonexistentSession() async throws {
    let db = try AppDatabase(inMemory: true)

    // Should not crash when deleting a session that doesn't exist
    try await db.deleteSession(id: "does-not-exist")

    let result = try await db.fetchSession(id: "does-not-exist")
    #expect(result == nil)
}

@Test func deleteSessionPreservesOthers() async throws {
    let db = try AppDatabase(inMemory: true)

    let s1 = Session(
        id: "keep-me",
        source: .claude,
        sessionType: .coding,
        name: "keeper",
        cwd: "/tmp",
        project: "test",
        gitBranch: nil,
        ticketId: nil,
        status: nil,
        model: nil,
        version: nil,
        messageCount: 10,
        toolCallCount: 5,
        tokensUsed: 1000,
        inputTokens: 0, outputTokens: 0, startedAt: Date(),
        endedAt: nil,
        isExplicitlyNamed: true, cacheReadTokens: 0, cacheCreationTokens: 0
    )
    let s2 = Session(
        id: "delete-me",
        source: .claude,
        sessionType: .coding,
        name: "goner",
        cwd: "/tmp",
        project: "test",
        gitBranch: nil,
        ticketId: nil,
        status: nil,
        model: nil,
        version: nil,
        messageCount: 5,
        toolCallCount: 2,
        tokensUsed: 500,
        inputTokens: 0, outputTokens: 0, startedAt: Date(),
        endedAt: nil,
        isExplicitlyNamed: true, cacheReadTokens: 0, cacheCreationTokens: 0
    )
    try await db.saveSession(s1)
    try await db.saveSession(s2)

    try await db.deleteSession(id: "delete-me")

    let remaining = try await db.fetchSession(id: "keep-me")
    #expect(remaining != nil)
    #expect(remaining?.name == "keeper")

    let deleted = try await db.fetchSession(id: "delete-me")
    #expect(deleted == nil)
}

@Test func fetchAllSessionsOnlyNamedFiltersUnnamed() async throws {
    let db = try AppDatabase(inMemory: true)

    let named = Session(
        id: "named-1",
        source: .claude,
        sessionType: .coding,
        name: "conductor",
        cwd: "/tmp",
        project: "test",
        gitBranch: nil,
        ticketId: nil,
        status: nil,
        model: nil,
        version: nil,
        messageCount: 0,
        toolCallCount: 0,
        tokensUsed: 0,
        inputTokens: 0, outputTokens: 0, startedAt: Date(),
        endedAt: nil,
        isExplicitlyNamed: true, cacheReadTokens: 0, cacheCreationTokens: 0
    )
    let unnamed = Session(
        id: "unnamed-1",
        source: .claude,
        sessionType: .coding,
        name: "project-c3",
        cwd: "/tmp",
        project: "test",
        gitBranch: nil,
        ticketId: nil,
        status: nil,
        model: nil,
        version: nil,
        messageCount: 0,
        toolCallCount: 0,
        tokensUsed: 0,
        inputTokens: 0, outputTokens: 0, startedAt: Date(),
        endedAt: nil,
        isExplicitlyNamed: false, cacheReadTokens: 0, cacheCreationTokens: 0
    )
    try await db.saveSession(named)
    try await db.saveSession(unnamed)

    let onlyNamed = try await db.fetchAllSessions(onlyNamed: true)
    #expect(onlyNamed.count == 1)
    #expect(onlyNamed.first?.id == "named-1")

    let all = try await db.fetchAllSessions()
    #expect(all.count == 2)
}

@Test func createPullRequest() async throws {
    let db = try AppDatabase(inMemory: true)

    let repo = try await db.saveRepo(Repo(
        id: nil,
        path: "/Users/test/project",
        originUrl: "git@github.com:org/project.git",
        lastScannedAt: Date()
    ))

    let pr = PullRequest(
        id: nil,
        repoId: repo.id!,
        number: 892,
        title: "TASK-1234: Add rate limiting",
        state: "merged",
        ticketId: "TASK-1234",
        additions: 342,
        deletions: 89,
        createdAt: Date(),
        mergedAt: Date(),
        url: "https://github.com/org/project/pull/892"
    )
    try await db.savePullRequest(pr)

    let prs = try await db.fetchPullRequests(repoId: repo.id!, since: .distantPast)
    #expect(prs.count == 1)
    #expect(prs.first?.additions == 342)
}
