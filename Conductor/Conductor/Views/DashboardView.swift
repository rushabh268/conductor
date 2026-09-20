import SwiftUI

struct DashboardView: View {
    let db: AppDatabase
    let coordinator: IngestionCoordinator
    let settings: SettingsStore
    var body: some View {
        SessionsView(db: db, settings: settings, revision: coordinator.lastIngestionAt, todayOnly: true)
    }
}
