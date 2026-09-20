import SwiftUI

struct StatusView: View {
    let db: AppDatabase
    let settings: SettingsStore
    @State private var content = ""
    @State private var weekly = false
    @State private var busy = false
    @State private var result: String?
    @State private var task: Task<Void, Never>?
    @State private var confirmPost = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Handoff").font(.largeTitle.bold()); Spacer(); Toggle("Last 7 days", isOn: $weekly).toggleStyle(.switch) }
            Text(settings.scopeDescription).font(.caption).foregroundStyle(.secondary)
            Text("Build an editable summary of recorded activity. Raw transcripts are excluded. Review the preview before copying or sharing.").foregroundStyle(.secondary)
            Button(busy ? "Working…" : "Build preview") {
                task?.cancel()
                task = Task { await generate() }
            }.disabled(busy)
            TextEditor(text: $content).font(.system(.body, design: .monospaced)).cardStyle(padding: 8)
            HStack {
                if let result { Text(result).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Copy preview") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(content, forType: .string) }.disabled(content.isEmpty)
                Button("Post preview to Slack…") { confirmPost = true }.disabled(content.isEmpty || settings.slackWebhookUrl.isEmpty || busy)
            }
        }.padding(24)
        .confirmationDialog("Send this reviewed preview to your configured Slack destination?", isPresented: $confirmPost, titleVisibility: .visible) {
            Button("Post preview") { task = Task { await post() } }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Only the text currently shown in the editor will be sent.") }
        .onDisappear { task?.cancel() }
    }
    private func generate() async {
        busy = true
        defer { if !Task.isCancelled { busy = false } }
        let now = Date()
        let since = weekly ? Calendar.current.date(byAdding: .day, value: -7, to: now)! : Calendar.current.startOfDay(for: now)
        let query = settings.query(since: since, limit: 1000)
        do {
            let sessions = try await db.fetchSessions(query: query)
            let total = try await db.countSessions(query: query)
            try Task.checkCancellation()
            let date = DateFormatter(); date.dateFormat = "yyyy-MM-dd"
            let reviewCount = sessions.filter { $0.sessionType == .review }.count
            content = weekly
                ? StatusGenerator.generateWeekly(weekStart: date.string(from: since), weekEnd: date.string(from: now), sessions: sessions, lineStats: [], reviewCount: reviewCount)
                : StatusGenerator.generateDaily(date: date.string(from: now), sessions: sessions, lineStats: [], reviewCount: reviewCount)
            content = settings.scopeDescription + "\n\n" + content
            if total > sessions.count { content += "\n\nPreview limited to the newest \(sessions.count) of \(total) matching sessions." }
            result = "Preview ready. Edit it before sharing."
        } catch is CancellationError { } catch { result = "The local index could not be read." }
    }
    private func post() async {
        busy = true
        defer { if !Task.isCancelled { busy = false } }
        do {
            _ = try await SlackPoster.post(content: content, webhookUrl: settings.slackWebhookUrl)
            try Task.checkCancellation()
            result = "Posted the reviewed preview."
        } catch is CancellationError { } catch { result = error.localizedDescription }
    }
}
