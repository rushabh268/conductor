import SwiftUI

struct ConnectionsView: View {
    let coordinator: IngestionCoordinator
    let settings: SettingsStore
    @State private var connectionStatus = "Not checked"
    @State private var checking = false
    @State private var checkTask: Task<Void, Never>?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Connections").font(.largeTitle.bold())
                Text("Conductor reads native history. It does not configure tools, start their services, or submit prompts.").foregroundStyle(.secondary)
                ForEach(SessionSource.allCases, id: \.self) { source in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(source.displayName, systemImage: source.icon).font(.headline)
                        if let health = coordinator.readerHealth.first(where: { $0.source == source }) {
                            Text(health.status.capitalized)
                            Text(health.detail).font(.caption).foregroundStyle(.secondary)
                            Text("Checked \(health.checkedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                        } else { Text("No completed scan yet").foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading).cardStyle(padding: 16)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Compass · optional").font(.headline)
                    Text(connectionStatus).font(.caption).foregroundStyle(.secondary)
                    Button(checking ? "Checking…" : "Check reader connection") {
                        checkTask?.cancel()
                        checkTask = Task {
                            checking = true
                            do {
                                let client = CompassClient(connection: CompassConnection(socketPath: settings.compassSocketPath, readerKeyPath: settings.compassReaderKeyPath))
                                _ = try await client.health()
                                guard !Task.isCancelled else { return }
                                connectionStatus = "Reader connected. Session evidence is available."
                            } catch is CancellationError { return }
                            catch { connectionStatus = error.localizedDescription }
                            checking = false
                        }
                    }.disabled(checking || settings.compassSocketPath.isEmpty || settings.compassReaderKeyPath.isEmpty)
                }.frame(maxWidth: .infinity, alignment: .leading).cardStyle(padding: 16)
            }.padding(24)
        }.onDisappear { checkTask?.cancel() }
    }
}
