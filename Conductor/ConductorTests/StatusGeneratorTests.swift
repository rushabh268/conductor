import Testing
import Foundation
@testable import Conductor

@Test func generateDailyStatus() {
    let sessions = [
        Session(id: "1", source: .claude, sessionType: .coding, name: "example-work",
                cwd: "/Users/test/example", project: "example", gitBranch: "feature/APP-1234-rate-limit",
                ticketId: "APP-1234", status: "idle", model: nil, version: nil,
                messageCount: 100, toolCallCount: 20, tokensUsed: 5000,
                inputTokens: 0, outputTokens: 0, startedAt: Date(), endedAt: nil,
                isExplicitlyNamed: true, cacheReadTokens: 0, cacheCreationTokens: 0),
        Session(id: "2", source: .claude, sessionType: .coding, name: "example-work-2",
                cwd: "/Users/test/example", project: "example", gitBranch: "feature/APP-1234-rate-limit",
                ticketId: "APP-1234", status: "idle", model: nil, version: nil,
                messageCount: 50, toolCallCount: 10, tokensUsed: 3000,
                inputTokens: 0, outputTokens: 0, startedAt: Date(), endedAt: nil,
                isExplicitlyNamed: true, cacheReadTokens: 0, cacheCreationTokens: 0),
        Session(id: "3", source: .claude, sessionType: .review, name: "pr-review-1",
                cwd: "/Users/test/example", project: "example", gitBranch: nil,
                ticketId: nil, status: "idle", model: nil, version: nil,
                messageCount: 30, toolCallCount: 5, tokensUsed: 2000,
                inputTokens: 0, outputTokens: 0, startedAt: Date(), endedAt: nil,
                isExplicitlyNamed: true, cacheReadTokens: 0, cacheCreationTokens: 0),
    ]

    let lineStats = [
        StatusGenerator.ProjectLineStats(project: "example", additions: 342, deletions: 89)
    ]

    let content = StatusGenerator.generateDaily(
        date: "2026-05-05",
        sessions: sessions,
        lineStats: lineStats,
        reviewCount: 1
    )

    #expect(content.contains("Daily Status"))
    #expect(content.contains("APP-1234"))
    #expect(content.contains("example"))
    #expect(content.contains("+342"))
    #expect(content.contains("-89"))
    #expect(content.contains("Reviews: 1"))
    #expect(content.contains("Sessions"))
}
