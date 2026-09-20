import SwiftUI

private enum AppSection: String, CaseIterable, Identifiable {
    case today = "Today", sessions = "Sessions", attention = "Attention", usage = "Usage", handoff = "Handoff", health = "Connections", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .today: "sun.max"
        case .sessions: "rectangle.stack"
        case .attention: "exclamationmark.bubble"
        case .usage: "chart.bar"
        case .handoff: "doc.text"
        case .health: "point.3.connected.trianglepath.dotted"
        case .settings: "gearshape"
        }
    }
}

struct ContentView: View {
    let db: AppDatabase
    let coordinator: IngestionCoordinator
    @Bindable var settings: SettingsStore
    @State private var selectedSection: AppSection? = .today

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Conductor", systemImage: "waveform.path.ecg").font(.title2.weight(.semibold))
                    Text("Your coding workspace").font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 16).padding(.top, 22)
                List(AppSection.allCases, selection: $selectedSection) {
                    Label($0.rawValue, systemImage: $0.icon).tag($0)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("CLAUDE CODE · CODEX · OPENCODE").font(.system(size: 9, weight: .semibold))
                    Text("Native history stays local.").font(.caption)
                }.foregroundStyle(.secondary).padding(16)
            }.navigationSplitViewColumnWidth(min: 185, ideal: 205, max: 240)
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    Picker("Session scope", selection: $settings.sessionRole) {
                        Text("Main sessions").tag(SessionRole.main)
                        Text("Children").tag(SessionRole.child)
                        Text("Unknown").tag(SessionRole.unknown)
                        Text("Internal").tag(SessionRole.internal)
                    }.labelsHidden().frame(width: 190)
                    Picker("Tool", selection: $settings.sessionSource) {
                        Text("All tools").tag(nil as SessionSource?)
                        ForEach(SessionSource.allCases, id: \.self) { Text($0.displayName).tag($0 as SessionSource?) }
                    }.labelsHidden().frame(width: 175)
                    Spacer()
                    if coordinator.isIngesting { ProgressView().controlSize(.small) }
                    Button {
                        Task { await coordinator.runIngestion() }
                    } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Refresh Conductor's index from native history")
                }.padding(12)
                Divider()
                switch selectedSection ?? .today {
                case .today: DashboardView(db: db, coordinator: coordinator, settings: settings)
                case .sessions: SessionsView(db: db, settings: settings, revision: coordinator.lastIngestionAt)
                case .attention: SessionsView(db: db, settings: settings, revision: coordinator.lastIngestionAt, attentionOnly: true)
                case .usage: AnalyticsView(db: db, settings: settings, revision: coordinator.lastIngestionAt)
                case .handoff: StatusView(db: db, settings: settings)
                case .health: ConnectionsView(coordinator: coordinator, settings: settings)
                case .settings: SettingsView(settings: settings)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1000, minHeight: 620)
        .preferredColorScheme(settings.preferredColorScheme)
        .sheet(isPresented: Binding(get: { !settings.hasSeenOnboarding }, set: { if !$0 { settings.hasSeenOnboarding = true } })) { OnboardingView() }
        .onChange(of: settings.refreshInterval) { coordinator.stop(); coordinator.start(interval: settings.refreshInterval) }
        .onChange(of: settings.retentionDays) { coordinator.retentionDays = settings.retentionDays }
    }
}
