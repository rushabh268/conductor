import SwiftUI

struct SettingsView: View {
    @Bindable var settings: SettingsStore
    @State private var webhook = ""
    @State private var result: String?
    var body: some View {
        Form {
            Section("Local history") {
                Picker("Refresh interval", selection: $settings.refreshInterval) {
                    Text("30 seconds").tag(30.0); Text("1 minute").tag(60.0); Text("5 minutes").tag(300.0)
                }
                Toggle("Show only explicitly named sessions", isOn: $settings.onlyNamedSessions)
                Text("Main sessions are the default. An unnamed main session is still a main session; a named child is still a child.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Retain the local index for", selection: $settings.retentionDays) {
                    Text("30 days").tag(30); Text("60 days").tag(60); Text("90 days").tag(90)
                }
                Text("Retention affects Conductor's index and local summaries. Native session files are read only.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Compass · optional reader connection") {
                TextField("Absolute local socket path", text: $settings.compassSocketPath)
                TextField("Absolute path to reader.key", text: $settings.compassReaderKeyPath)
                Text("Use Compass's companion-enable command to prepare reader access. Conductor never loads the writer key, changes native settings, or starts Compass.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sharing · off until you choose Post") {
                SecureField("Slack incoming webhook", text: $webhook)
                HStack {
                    Button("Save in Keychain") { do { try settings.saveSlackWebhook(webhook); webhook = ""; result = "Saved in Keychain." } catch { result = error.localizedDescription } }
                    Button("Remove credential") { do { try settings.saveSlackWebhook(""); webhook = ""; result = "Credential removed." } catch { result = error.localizedDescription } }
                }
                Text(settings.slackWebhookUrl.isEmpty ? "No sharing credential is configured." : "A sharing credential is stored in Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
                if let result { Text(result).font(.caption) }
                if let error = settings.credentialError { Text(error).font(.caption).foregroundStyle(.orange) }
                Text("Only the editable Handoff preview is sent, after you explicitly post it. No model request is made by Conductor.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Appearance") {
                Picker("Color scheme", selection: $settings.appearance) {
                    Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                }.pickerStyle(.segmented)
            }
        }.formStyle(.grouped).padding(12)
    }
}
