import Testing
import Foundation
import GRDB
@testable import Conductor

@Test func parseCodexThread() throws {
    let thread = CodexIngestor.parseThread(
        id: "019dd132-6511-7180-90af-3a51d43f710b",
        cwd: "/Users/test/go/src/project",
        title: "Hi",
        gitBranch: "feature/DEMO-123-example",
        gitOriginUrl: "https://github.com/example/project.git",
        tokensUsed: 5039994,
        model: "gpt-5.4",
        cliVersion: "0.125.0",
        createdAt: 1777331234,
        updatedAt: 1777589602,
        firstUserMessage: "Hi"
    )

    #expect(thread.id == "019dd132-6511-7180-90af-3a51d43f710b")
    #expect(thread.source == .codex)
    #expect(thread.project == "project")
    #expect(thread.gitBranch == "feature/DEMO-123-example")
    #expect(thread.ticketId == "DEMO-123")
    #expect(thread.tokensUsed == 5039994)
    // title == firstUserMessage ("Hi" == "Hi") -> auto-titled, not explicit
    #expect(thread.isExplicitlyNamed == false)
}

@Test func parseCodexThreadWithBlankTitleIsNotExplicitlyNamed() throws {
    // Finding 9a: a blank title must never be "explicitly named", regardless
    // of firstUserMessage being present.
    let thread = CodexIngestor.parseThread(
        id: "019dd132-blank-title",
        cwd: "/Users/test/go/src/project",
        title: "",
        gitBranch: nil,
        gitOriginUrl: nil,
        tokensUsed: 0,
        model: "gpt-5.4",
        cliVersion: "0.125.0",
        createdAt: 1777331234,
        updatedAt: 1777589602,
        firstUserMessage: "some real first message"
    )

    #expect(thread.isExplicitlyNamed == false)
}

@Test func parseCodexThreadWithBlankTitleAndBlankFirstMessageIsNotExplicitlyNamed() throws {
    // Finding 9a real-world edge case: 7 real rows have both title and
    // firstUserMessage blank.
    let thread = CodexIngestor.parseThread(
        id: "019dd132-blank-both",
        cwd: "/Users/test/go/src/project",
        title: "",
        gitBranch: nil,
        gitOriginUrl: nil,
        tokensUsed: 0,
        model: "gpt-5.4",
        cliVersion: "0.125.0",
        createdAt: 1777331234,
        updatedAt: 1777589602,
        firstUserMessage: ""
    )

    #expect(thread.isExplicitlyNamed == false)
}

@Test func parseCodexReviewThread() throws {
    let thread = CodexIngestor.parseThread(
        id: "019dd290-f4e4",
        cwd: "/Users/test/go/src/project",
        title: "Review the code changes",
        gitBranch: nil,
        gitOriginUrl: nil,
        tokensUsed: 0,
        model: "gpt-5.4",
        cliVersion: "0.125.0",
        createdAt: 1777354208,
        updatedAt: 1777354220,
        firstUserMessage: "Review the code changes against the base branch"
    )

    #expect(thread.sessionType == .review)
    // title ("Review the code changes") differs from firstUserMessage
    // ("Review the code changes against the base branch") -> explicitly named
    #expect(thread.isExplicitlyNamed == true)
}
