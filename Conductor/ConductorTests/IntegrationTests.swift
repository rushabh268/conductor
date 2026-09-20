import Testing
import Foundation
@testable import Conductor

@Test func fullIngestionAndStatusGeneration() async throws {
    let db = try AppDatabase(inMemory: true)

    // Simulate Claude sessions
    let session1 = Session(
        id: "s1", source: .claude, sessionType: .coding, name: "project-work",
        cwd: "/Users/test/project", project: "project",
        gitBranch: "feature/TASK-1234-rate-limit", ticketId: "TASK-1234",
        status: "idle", model: "claude-opus-4-6", version: "2.1.128",
        messageCount: 100, toolCallCount: 20, tokensUsed: 5000,
        inputTokens: 0, outputTokens: 0, startedAt: Date(), endedAt: nil,
        isExplicitlyNamed: true, cacheReadTokens: 0, cacheCreationTokens: 0
    )
    try await db.saveSession(session1)

    let session2 = Session(
        id: "s2", source: .claude, sessionType: .review, name: "pr-review-1",
        cwd: "/Users/test/project", project: "project",
        gitBranch: nil, ticketId: nil,
        status: "idle", model: nil, version: nil,
        messageCount: 30, toolCallCount: 5, tokensUsed: 2000,
        inputTokens: 0, outputTokens: 0, startedAt: Date(), endedAt: nil,
        isExplicitlyNamed: true, cacheReadTokens: 0, cacheCreationTokens: 0
    )
    try await db.saveSession(session2)

    let session3 = Session(
        id: "s3", source: .codex, sessionType: .coding, name: "codex-work",
        cwd: "/Users/test/nebula", project: "nebula",
        gitBranch: "feature/DEMO-123-example", ticketId: "DEMO-123",
        status: nil, model: "gpt-5.4", version: "0.125.0",
        messageCount: 0, toolCallCount: 0, tokensUsed: 50000,
        inputTokens: 0, outputTokens: 0, startedAt: Date(), endedAt: nil,
        isExplicitlyNamed: true, cacheReadTokens: 0, cacheCreationTokens: 0
    )
    try await db.saveSession(session3)

    // Verify fetch
    let allSessions = try await db.fetchSessions(since: Date.distantPast)
    #expect(allSessions.count == 3)

    let reviews = try await db.fetchReviewSessions(since: Date.distantPast)
    #expect(reviews.count == 1)

    // Generate status
    let lineStats = [
        StatusGenerator.ProjectLineStats(project: "project", additions: 342, deletions: 89),
        StatusGenerator.ProjectLineStats(project: "nebula", additions: 128, deletions: 45),
    ]

    let status = StatusGenerator.generateDaily(
        date: "2026-05-05",
        sessions: allSessions,
        lineStats: lineStats,
        reviewCount: reviews.count
    )

    #expect(status.contains("TASK-1234"))
    #expect(status.contains("DEMO-123"))
    #expect(status.contains("Reviews: 1"))
    #expect(status.contains("+342"))
    #expect(status.contains("+128"))
}

@Test func computeDailyStatsFromSessions() async throws {
    let db = try AppDatabase(inMemory: true)

    let today = Date()
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    let todayStr = formatter.string(from: today)

    // Insert sessions
    let s1 = Session(
        id: "s1", source: .claude, sessionType: .coding, name: "work",
        cwd: "/tmp", project: "test", gitBranch: nil, ticketId: nil,
        status: nil, model: nil, version: nil,
        messageCount: 10, toolCallCount: 5, tokensUsed: 1000, inputTokens: 0, outputTokens: 0,
        startedAt: today, endedAt: nil,
        isExplicitlyNamed: true, cacheReadTokens: 0, cacheCreationTokens: 0
    )
    let s2 = Session(
        id: "s2", source: .claude, sessionType: .coding, name: "work2",
        cwd: "/tmp", project: "test", gitBranch: nil, ticketId: nil,
        status: nil, model: nil, version: nil,
        messageCount: 20, toolCallCount: 10, tokensUsed: 2000, inputTokens: 0, outputTokens: 0,
        startedAt: today, endedAt: nil,
        isExplicitlyNamed: true, cacheReadTokens: 0, cacheCreationTokens: 0
    )
    try await db.saveSession(s1)
    try await db.saveSession(s2)

    // Compute daily stats
    try await ClaudeIngestor.computeDailyStats(from: db)

    // Verify session-scoped statistics without reading native global history;
    // we check that our session data is included, not exact counts
    let stats = try await db.fetchDailyStats(since: todayStr)
    #expect(!stats.isEmpty)
    let todayStat = stats.first { $0.date == todayStr }
    #expect(todayStat != nil)
    #expect(todayStat!.sessionCount >= 2)
    #expect(todayStat!.messageCount >= 30)
}

@Test func computeDailyStatsNoSessions() async throws {
    let db = try AppDatabase(inMemory: true)

    // Should not crash with no sessions — may still produce
    // stats from history.jsonl if it exists on disk
    try await ClaudeIngestor.computeDailyStats(from: db)
}

@Test func computeCodexDailyStats() async throws {
    let db = try AppDatabase(inMemory: true)

    let today = Date()
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    let todayStr = formatter.string(from: today)

    let s1 = Session(
        id: "c1", source: .codex, sessionType: .coding, name: "codex-work",
        cwd: "/tmp", project: "test", gitBranch: nil, ticketId: nil,
        status: nil, model: nil, version: nil,
        messageCount: 15, toolCallCount: 3, tokensUsed: 50000,
        inputTokens: 0, outputTokens: 0, startedAt: today, endedAt: nil,
        isExplicitlyNamed: true, cacheReadTokens: 0, cacheCreationTokens: 0
    )
    try await db.saveSession(s1)

    try await CodexIngestor.computeDailyStats(from: db)

    let stats = try await db.fetchDailyStats(since: todayStr)
    #expect(stats.count == 1)
    #expect(stats[0].source == .codex)
    #expect(stats[0].tokensUsed == 50000)
}

@Test func chartIdUniqueness() {
    let stat1 = DailyStat(
        id: nil, date: "2026-05-05", source: .claude,
        sessionCount: 1, messageCount: 10, toolCallCount: 5, tokensUsed: 1000
    )
    let stat2 = DailyStat(
        id: nil, date: "2026-05-05", source: .codex,
        sessionCount: 2, messageCount: 20, toolCallCount: 10, tokensUsed: 2000
    )

    #expect(stat1.chartId == "2026-05-05-claude")
    #expect(stat2.chartId == "2026-05-05-codex")
    #expect(stat1.chartId != stat2.chartId)
}
