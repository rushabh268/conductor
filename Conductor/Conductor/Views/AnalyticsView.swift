import SwiftUI
import Charts

struct AnalyticsView: View {
    let db: AppDatabase
    let settings: SettingsStore
    var revision: Date? = nil
    @State private var range = TimeRange.week
    @State private var scope = UsageScope.own
    @State private var usage = SessionUsage()
    @State private var activity: [SessionActivity] = []
    @State private var count = 0
    @State private var error: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Usage").font(.largeTitle.bold()); Spacer()
                    Picker("Activity range", selection: $range) { ForEach(TimeRange.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 170)
                }
                Text(settings.scopeDescription).font(.caption).foregroundStyle(.secondary)
                Picker("Token accounting", selection: $scope) {
                    Text("Selected sessions only").tag(UsageScope.own)
                    Text("Include known descendants").tag(UsageScope.descendants)
                }.pickerStyle(.segmented)
                HStack(spacing: 18) {
                    metric("Selected sessions", count.formatted())
                    metric("Recorded tokens", usage.tokensUsed.formatted())
                    metric("Usage unavailable", usage.unavailableSessions.formatted())
                }
                Text("\(usage.breakdownUnavailableSessions) sessions lack an input/output breakdown. Native totals may use different accounting conventions; no cost estimate is inferred.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.secondary) }
                ChartCard(title: "Selected sessions by last activity day") {
                    Chart(activity) {
                        BarMark(x: .value("Day", $0.day), y: .value("Sessions", $0.sessions))
                            .foregroundStyle(by: .value("Tool", $0.source.displayName))
                    }
                }
                HStack(spacing: 18) {
                    metric("Reported input", usage.inputTokens.formatted())
                    metric("Reported output", usage.outputTokens.formatted())
                    metric("Cache read / creation", "\(usage.cacheReadTokens.formatted()) / \(usage.cacheCreationTokens.formatted())")
                }
                Text("The chart always counts the selected session population. Token totals use the accounting scope selected above.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }.task(id: "\(settings.scopeID):\(range.rawValue):\(scope.rawValue):\(revision?.timeIntervalSince1970 ?? 0)") {
            let query = settings.query(since: range == .all ? nil : range.since)
            do {
                let recorded = try await db.usage(query: query, scope: scope)
                let rows = try await db.activity(query: query)
                let total = try await db.countSessions(query: query)
                try Task.checkCancellation()
                usage = recorded; activity = rows; count = total; error = nil
            } catch is CancellationError { } catch { self.error = "Usage could not be read from the local index." }
        }
    }
    private func metric(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(.title2.monospacedDigit().weight(.semibold))
            Text(name).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).cardStyle(padding: 16)
    }
}

struct ChartCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { Text(title).font(.headline); content().frame(height: 220) }.cardStyle(padding: 16)
    }
}
