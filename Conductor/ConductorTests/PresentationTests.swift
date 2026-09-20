import Foundation
import Testing
@testable import Conductor

private func presentationSession(_ source: SessionSource, role: SessionRole = .main) -> Session {
    Session(id: "local-id", source: source, sessionType: .coding, name: "Synthetic work",
            cwd: "/tmp/project's $(echo example)", project: "example", gitBranch: "feature/example", ticketId: nil,
            status: "idle", model: nil, version: nil, messageCount: 0, toolCallCount: 0,
            tokensUsed: 0, inputTokens: 0, outputTokens: 0, startedAt: Date(timeIntervalSince1970: 1), endedAt: nil,
            isExplicitlyNamed: false, cacheReadTokens: 0, cacheCreationTokens: 0, nativeID: "native-session", role: role)
}

@Test func nativeHandoffAndAttentionHaveThreeSourceParity() throws {
    for source in SessionSource.allCases {
        var session = presentationSession(source)
        let command = try TerminalLauncher.resumeCommand(session)
        #expect(command.hasSuffix("'native-session'"))
        #expect(command.contains("'\\''"))
        #expect(command.contains(source == .claude ? "claude --resume" : source == .codex ? "codex resume" : "opencode --session"))
        #expect(session.attentionReason == nil)
        session.status = "waiting_for_approval"
        #expect(session.attentionReason != nil)
        session.nativeID = "bad'; touch /tmp/no"
        #expect(throws: TerminalLauncher.LaunchError.self) { try TerminalLauncher.resumeCommand(session) }
        let secret = TranscriptMessage(role: "user", text: "PRIVATE TRANSCRIPT", timestamp: nil, subAgentId: nil)
        #expect(!HandoffBuilder.build(session: session, messages: [secret]).contains(secret.text))
        #expect(HandoffBuilder.build(session: session, messages: [secret], includeExcerpt: true).contains(secret.text))
    }
}

@Test @MainActor func sharedScopePreservesUnnamedMainSessionsAndExcludesNamedChildren() async throws {
    let name = "conductor-scope-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = SettingsStore(defaults: defaults)
    let database = try AppDatabase(inMemory: true)
    for source in SessionSource.allCases {
        var root = presentationSession(source); root.id = source.rawValue + "-main"; root.name = nil
        var child = presentationSession(source, role: .child); child.id = source.rawValue + "-child"; child.isExplicitlyNamed = true; child.nativeID = "native-child"
        _ = try await database.saveSession(root); _ = try await database.saveSession(child)
    }
    #expect(try await database.fetchSessions(query: settings.query()).count == 3)
    #expect(try await database.countSessions(query: settings.query()) == 3)
    let activity = try await database.activity(query: settings.query())
    #expect(activity.reduce(0) { $0 + $1.sessions } == 3)
    #expect(Set(activity.map(\.source)) == Set(SessionSource.allCases))
    settings.sessionSource = .opencode
    #expect(try await database.fetchSessions(query: settings.query()).map(\.effectiveNativeID) == ["native-session"])
    settings.sessionRole = .child
    #expect(try await database.fetchSessions(query: settings.query()).map(\.effectiveNativeID) == ["native-child"])
}


@Test func statusGroupingKeepsDistinctWorktreesAndHasNoImplicitTranscript() {
    var first = presentationSession(.claude)
    var second = presentationSession(.codex)
    first.cwd = "/work/one/example"; second.cwd = "/work/two/example"
    let text = StatusGenerator.generateDaily(date: "2026-09-20", sessions: [first, second],
        lineStats: [], reviewCount: 0)
    #expect(text.components(separatedBy: "## example").count == 3)
    #expect(text.contains("Claude Code"))
    #expect(text.contains("Codex"))
    #expect(!text.contains("Selected excerpt"))
    #expect(text.contains("completion and test results are not inferred"))
}
