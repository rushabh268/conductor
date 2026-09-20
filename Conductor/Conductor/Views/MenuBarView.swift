import SwiftUI

struct MenuBarView: View {
    let db: AppDatabase
    let settings: SettingsStore
    var revision: Date? = nil
    @State private var recent: [Session] = []
    @State private var count = 0
    @State private var usage = SessionUsage()
    var body: some View {
        Text(settings.scopeDescription)
        Text("Today: \(count) sessions · \(usage.tokensUsed.formatted()) recorded tokens")
        Divider()
        ForEach(recent) { session in
            Button("\(session.source.displayName): \(session.displayTitle)") { TerminalLauncher.resumeSession(session) }
                .disabled((try? TerminalLauncher.resumeCommand(session)) == nil)
        }
        Divider()
        Button("Open Conductor") {
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSApplication.shared.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
        }
        Button("Quit Conductor") { NSApplication.shared.terminate(nil) }
        .task(id: "\(settings.scopeID):\(revision?.timeIntervalSince1970 ?? 0)") {
            let query = settings.query(since: Calendar.current.startOfDay(for: Date()), limit: 5)
            do {
                let rows = try await db.fetchSessions(query: query)
                let total = try await db.countSessions(query: query)
                let tokens = try await db.usage(query: query)
                try Task.checkCancellation()
                recent = rows; count = total; usage = tokens
            } catch { }
        }
    }
}
