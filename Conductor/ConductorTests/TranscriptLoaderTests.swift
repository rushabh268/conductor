import Testing
import Foundation
@testable import Conductor

@Test func loadSubAgentMetaParsing() {
    // Test that the project hash fix works for sub-agent path construction
    let hash = ClaudeTokenCounter.projectHash(for: "/Users/john.doe/projects/test")
    #expect(hash == "-Users-john-doe-projects-test")
}

@Test func loadClaudeSubAgentsEmptyForNilCwd() {
    let agents = TranscriptLoader.loadClaudeSubAgents(sessionId: "some-session", cwd: nil)
    #expect(agents.isEmpty)
}

@Test func loadClaudeSubAgentsEmptyForMissingDir() throws {
    let fixture = try CoreFixture()
    defer { fixture.remove() }
    let agents = TranscriptLoader.loadClaudeSubAgents(sessionId: "nonexistent-session", cwd: "/tmp/fake-path", paths: fixture.paths)
    #expect(agents.isEmpty)
}

@Test func transcriptMessageHasSubAgentId() {
    // Verify TranscriptMessage can carry sub-agent attribution
    let msg = TranscriptMessage(role: "assistant", text: "Hello", timestamp: nil, subAgentId: "agent-abc123")
    #expect(msg.subAgentId == "agent-abc123")
    #expect(msg.role == "assistant")
}

@Test func transcriptMessageWithoutSubAgentId() {
    let msg = TranscriptMessage(role: "user", text: "Hello", timestamp: nil, subAgentId: nil)
    #expect(msg.subAgentId == nil)
}

@Test func subAgentInfoIdentifiable() {
    let agent = SubAgentInfo(
        id: "abc123",
        agentType: "general-purpose",
        description: "Test agent",
        messages: []
    )
    #expect(agent.id == "abc123")
    #expect(agent.agentType == "general-purpose")
    #expect(agent.messages.isEmpty)
}
