import Foundation
import Testing
@testable import Conductor

@Test @MainActor func preferencesStayWithinInjectedStore() {
    let firstName = "conductor-tests-first-\(UUID().uuidString)"
    let secondName = "conductor-tests-second-\(UUID().uuidString)"
    let first = UserDefaults(suiteName: firstName)!
    let second = UserDefaults(suiteName: secondName)!
    defer {
        first.removePersistentDomain(forName: firstName)
        second.removePersistentDomain(forName: secondName)
    }
    let settings = SettingsStore(defaults: first)
    settings.retentionDays = 30
    settings.appearance = "dark"
    #expect(SettingsStore(defaults: first).retentionDays == 30)
    #expect(SettingsStore(defaults: first).appearance == "dark")
    #expect(SettingsStore(defaults: second).retentionDays == 90)
    #expect(second.object(forKey: "appearance") == nil)
}
