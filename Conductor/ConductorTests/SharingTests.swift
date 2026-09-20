import Foundation
import Testing
@testable import Conductor

@Test func sharingRejectsUnsafeDestinationsBeforeNetworking() throws {
    for value in ["http://hooks.slack.com/services/a/b/c", "https://example.org/services/a/b/c",
                  "https://user@hooks.slack.com/services/a/b/c", "https://hooks.slack.com/services/a/b/c?copy=yes",
                  "https://hooks.slack.com:444/services/a/b/c"] {
        #expect(throws: SlackPoster.SlackError.self) { try SlackPoster.validatedURL(value) }
    }
    let request = try SlackPoster.request(content: "An explicitly reviewed summary", webhookUrl: "https://hooks.slack.com/services/synthetic/team/example")
    #expect(request.httpMethod == "POST")
    #expect(request.timeoutInterval == 15)
    #expect(String(data: request.httpBody!, encoding: .utf8)!.contains("An explicitly reviewed summary"))
}

@Test @MainActor func sharingMigratesOnlyAfterCredentialWriteSucceeds() throws {
    let name = "conductor-credential-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let synthetic = "https://hooks.slack.com/services/synthetic/team/example"
    defaults.set(synthetic, forKey: "slackWebhookUrl")
    let settings = SettingsStore(defaults: defaults, credentials: MemoryCredentialStore())
    #expect(settings.slackWebhookUrl == synthetic)
    #expect(defaults.object(forKey: "slackWebhookUrl") == nil)
    try settings.saveSlackWebhook("")
    #expect(settings.slackWebhookUrl.isEmpty)

    defaults.set(synthetic, forKey: "slackWebhookUrl")
    let unavailable = SettingsStore(defaults: defaults, credentials: FailingCredentialStore())
    #expect(unavailable.slackWebhookUrl.isEmpty)
    #expect(unavailable.credentialError != nil)
    #expect(defaults.string(forKey: "slackWebhookUrl") == synthetic)
}

private struct FailingCredentialStore: CredentialStore {
    func read() throws -> String? { nil }
    func save(_ value: String) throws { throw CredentialError.unavailable }
}
