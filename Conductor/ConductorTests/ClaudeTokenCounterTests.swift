import Testing
import Foundation
@testable import Conductor

@Test func projectHashReplacesSlashesAndDots() {
    let hash = ClaudeTokenCounter.projectHash(for: "/Users/sample.developer/work/conductor")
    #expect(hash == "-Users-sample-developer-work-conductor")
}

@Test func projectHashSimplePath() {
    let hash = ClaudeTokenCounter.projectHash(for: "/Users/testuser/project")
    #expect(hash == "-Users-testuser-project")
}

@Test func projectHashWithMultipleDots() {
    let hash = ClaudeTokenCounter.projectHash(for: "/Users/john.doe/my.project/src")
    #expect(hash == "-Users-john-doe-my-project-src")
}

@Test func countTokensMissingFile() throws {
    let fixture = try CoreFixture()
    defer { fixture.remove() }
    // Should return zero when the JSONL file doesn't exist
    let usage = ClaudeTokenCounter.countTokens(sessionId: "nonexistent-session-id", cwd: "/tmp/fake", paths: fixture.paths)
    #expect(usage.totalTokens == 0)
    #expect(usage.inputTokens == 0)
    #expect(usage.outputTokens == 0)
}

@Test func countTokensNilCwd() {
    let usage = ClaudeTokenCounter.countTokens(sessionId: "anything", cwd: nil)
    #expect(usage.totalTokens == 0)
}

@Test func jsonlPathBuildsCorrectly() {
    let path = ClaudeTokenCounter.jsonlPath(sessionId: "abc-123", cwd: "/Users/test.user/work")
    #expect(path != nil)
    #expect(path!.contains("-Users-test-user-work"))
    #expect(path!.hasSuffix("abc-123.jsonl"))
}

@Test func jsonlPathReturnsNilForNilCwd() {
    let path = ClaudeTokenCounter.jsonlPath(sessionId: "abc-123", cwd: nil)
    #expect(path == nil)
}
