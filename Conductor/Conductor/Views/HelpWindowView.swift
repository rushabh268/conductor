import SwiftUI

struct HelpWindowView: View {
    static let sectionTitles = ["Getting started", "Session scope", "Native history", "Compass evidence", "Sharing and privacy", "Troubleshooting", "Uninstall"]
    private let explanations = [
        "Conductor reads existing Claude Code, Codex, and OpenCode history from local profiles. Open Connections to inspect reader availability. It does not start or configure a native tool.",
        "Main sessions are shown by default, including unnamed sessions. Children open separately. Unknown and internal records have explicit scopes. The selected role and tool apply across the workspace.",
        "Transcripts load one page at a time. Recorded activity is not proof of a running process. Usage fields may be unavailable, and native accounting conventions differ. Retention removes only Conductor's local index records.",
        "Compass is optional. Configure its socket and a dedicated reader.key after preparing companion access. Evidence is verified by Compass and paged from an immutable snapshot. Historical monthly grounding totals are never guessed onto individual sessions.",
        "Transcripts remain local. No remote model is called. Sharing sends only an editable preview after explicit approval. The Slack credential is stored in Keychain. Copied or shared text can contain private information, so review it first.",
        "A missing or unsupported source is reported in Connections. Refresh retries a read. Native format changes can require a reader update. If Compass is disconnected, native history still works.",
        "Run ./uninstall.sh from the source checkout to remove the user Applications copy. Data stays by default. Use --purge-data only when you also want to remove Conductor's Application Support folder. Native profiles are untouched."
    ]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Conductor Help").font(.largeTitle.bold())
                ForEach(Array(Self.sectionTitles.enumerated()), id: \.offset) { index, title in
                    VStack(alignment: .leading, spacing: 8) { Text(title).font(.headline); Text(explanations[index]).foregroundStyle(.secondary) }
                }
            }.padding(24)
        }.frame(minWidth: 550, minHeight: 500)
    }
}
