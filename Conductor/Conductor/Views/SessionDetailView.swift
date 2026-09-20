import SwiftUI

struct SessionDetailView: View {
    let session: Session
    let db: AppDatabase
    let settings: SettingsStore
    @State private var tab = "Transcript"
    @State private var checkpoint = ""
    @State private var excerpt = false
    @State private var checkpointTask: Task<Void, Never>?
    private let tabs = ["Transcript", "Children", "Compass", "Checkpoint"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(session.displayTitle).font(.title2.weight(.semibold)).textSelection(.enabled)
                        Text("\(session.source.displayName) · \(session.role.rawValue) · \(session.nameLabel)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open in \(session.source.displayName)") { TerminalLauncher.resumeSession(session) }
                        .disabled((try? TerminalLauncher.resumeCommand(session)) == nil)
                        .help(session.role == .child && session.source != .opencode ? "Resume the known parent session in its native tool" : "Explicitly resume this session in its native tool")
                }
                HStack {
                    Text(session.tokenDescription)
                    if session.usageBreakdownAvailable { Text("\(session.inputTokens.formatted()) in · \(session.outputTokens.formatted()) out") }
                    else { Text("Input/output breakdown unavailable") }
                }.font(.caption).foregroundStyle(.secondary)
                if let cwd = session.cwd { Text(cwd).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
                Text("Last recorded activity: \(session.activityAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Session details", selection: $tab) { ForEach(tabs, id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented)
            }.padding(16)
            Divider()
            switch tab {
            case "Children": SessionChildrenView(session: session, db: db, settings: settings)
            case "Compass": CompassEvidenceView(session: session, settings: settings)
            case "Checkpoint": checkpointView
            default: TranscriptView(session: session)
            }
        }.onDisappear { checkpointTask?.cancel() }
    }

    private var checkpointView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A factual draft you can edit before copying. It does not infer whether the work is complete.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Include a transcript excerpt in the preview", isOn: $excerpt)
            Button("Build checkpoint") {
                checkpointTask?.cancel()
                checkpointTask = Task {
                    var messages: [TranscriptMessage] = []
                    if excerpt { messages = (try? await TranscriptLoader.loadPage(for: session).messages) ?? [] }
                    guard !Task.isCancelled else { return }
                    checkpoint = HandoffBuilder.build(session: session, messages: messages, includeExcerpt: excerpt)
                }
            }
            TextEditor(text: $checkpoint).font(.system(.body, design: .monospaced)).cardStyle(padding: 8)
            HStack { Spacer(); Button("Copy reviewed checkpoint") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(checkpoint, forType: .string) }.disabled(checkpoint.isEmpty) }
        }.padding(16)
    }
}
