import Foundation
import SwiftUI

@Observable
final class SettingsStore {
    private let defaults: UserDefaults
    private let credentials: any CredentialStore
    var credentialError: String?
    var hasSeenOnboarding: Bool {
        didSet { defaults.set(hasSeenOnboarding, forKey: "hasSeenOnboarding") }
    }
    private(set) var slackWebhookUrl: String
    var refreshInterval: TimeInterval {
        didSet { defaults.set(refreshInterval, forKey: "refreshInterval") }
    }
    var retentionDays: Int {
        didSet { defaults.set(retentionDays, forKey: "retentionDays") }
    }
    var appearance: String {
        didSet { defaults.set(appearance, forKey: "appearance") }
    }
    var onlyNamedSessions: Bool {
        didSet { defaults.set(onlyNamedSessions, forKey: "onlyNamedSessions") }
    }
    var sessionRole: SessionRole = .main
    var sessionSource: SessionSource?
    var compassSocketPath: String {
        didSet { defaults.set(compassSocketPath, forKey: "compassSocketPath") }
    }
    var compassReaderKeyPath: String {
        didSet { defaults.set(compassReaderKeyPath, forKey: "compassReaderKeyPath") }
    }

    var scopeID: String { "\(sessionRole.rawValue):\(sessionSource?.rawValue ?? "all"):\(onlyNamedSessions)" }
    var scopeDescription: String {
        "\(sessionRole == .main ? "Main sessions" : sessionRole.rawValue.capitalized + " sessions") · \(sessionSource?.displayName ?? "All tools")\(onlyNamedSessions ? " · Named only" : "")"
    }
    func query(since: Date? = nil, limit: Int = 50, offset: Int = 0, search: String? = nil) -> SessionQuery {
        SessionQuery(role: sessionRole, source: sessionSource, since: since, limit: limit, offset: offset,
                     search: search, onlyNamed: onlyNamedSessions)
    }

    init(defaults: UserDefaults = .standard, credentials: (any CredentialStore)? = nil) {
        self.defaults = defaults
        let store: any CredentialStore = credentials ?? (defaults === UserDefaults.standard
            ? KeychainCredentialStore() as any CredentialStore : MemoryCredentialStore() as any CredentialStore)
        self.credentials = store
        self.hasSeenOnboarding = defaults.bool(forKey: "hasSeenOnboarding")
        self.slackWebhookUrl = ""
        self.refreshInterval = defaults.double(forKey: "refreshInterval").nonZero ?? 60
        self.retentionDays = defaults.integer(forKey: "retentionDays").nonZero ?? 90
        self.appearance = defaults.string(forKey: "appearance") ?? "system"
        self.onlyNamedSessions = defaults.object(forKey: "onlyNamedSessions") as? Bool ?? false
        self.compassSocketPath = defaults.string(forKey: "compassSocketPath") ?? ""
        self.compassReaderKeyPath = defaults.string(forKey: "compassReaderKeyPath") ?? ""
        do {
            if let saved = try store.read() { self.slackWebhookUrl = saved }
            else if let old = defaults.string(forKey: "slackWebhookUrl"), !old.isEmpty {
                try store.save(old)
                self.slackWebhookUrl = old
            }
            defaults.removeObject(forKey: "slackWebhookUrl")
        } catch { self.credentialError = "Could not migrate the sharing credential to Keychain. Sharing is disabled until it is saved again." }
    }

    func saveSlackWebhook(_ value: String) throws {
        if !value.isEmpty { _ = try SlackPoster.validatedURL(value) }
        try credentials.save(value)
        slackWebhookUrl = value
        defaults.removeObject(forKey: "slackWebhookUrl")
        credentialError = nil
    }

    var preferredColorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
