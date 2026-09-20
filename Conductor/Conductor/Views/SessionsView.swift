import SwiftUI

enum TimeRange: String, CaseIterable {
    case week = "7 days", month = "30 days", quarter = "90 days", all = "All retained"
    var days: Int { switch self { case .week: 7; case .month: 30; case .quarter: 90; case .all: 36500 } }
    var since: Date { Calendar.current.date(byAdding: .day, value: -days, to: Date())! }
}

struct SessionsView: View {
    let db: AppDatabase
    let settings: SettingsStore
    var revision: Date? = nil
    var todayOnly = false
    var attentionOnly = false
    @State private var selectedRange = TimeRange.month
    @State private var sessions: [Session] = []
    @State private var selected: Session?
    @State private var search = ""
    @State private var offset = 0
    @State private var total = 0
    @State private var loading = false
    @State private var error: String?
    @State private var refresh = 0
    private let pageSize = 50

    private var key: String { "\(settings.scopeID):\(search):\(selectedRange.rawValue):\(offset):\(revision?.timeIntervalSince1970 ?? 0):\(refresh)" }
    var body: some View {
        GeometryReader { geometry in
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(todayOnly ? "Today" : attentionOnly ? "Attention" : "Sessions").font(.title.bold())
                    Spacer()
                    Text(total.formatted()).font(.title3.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(settings.scopeDescription).font(.caption).foregroundStyle(.secondary)
                if attentionOnly {
                    Text("Waiting and error states reported by native history. Missing live status stays unknown.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextField("Search titles, projects, or native IDs", text: $search).textFieldStyle(.roundedBorder)
                    .onChange(of: search) { offset = 0 }
                if !todayOnly {
                    Picker("Activity", selection: $selectedRange) {
                        ForEach(TimeRange.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.onChange(of: selectedRange) { offset = 0 }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
                if loading && sessions.isEmpty { ProgressView("Reading the local index").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if sessions.isEmpty {
                    ContentUnavailableView(attentionOnly ? "Nothing flagged" : "No sessions in this scope", systemImage: attentionOnly ? "checkmark.circle" : "rectangle.stack", description: Text("Change the scope or check Connections for reader availability."))
                } else {
                    List(sessions, selection: Binding(get: { selected?.id }, set: { id in selected = sessions.first { $0.id == id } })) { session in
                        SessionRowView(session: session).tag(session.id)
                            .contextMenu {
                                Button(session.isPinned ? "Unpin" : "Pin") {
                                    Task { try? await db.setPinned(id: session.id, pinned: !session.isPinned); refresh += 1 }
                                }
                                Button("Hide from Conductor") {
                                    Task { try? await db.deleteSession(id: session.id); refresh += 1 }
                                }
                            }
                    }.listStyle(.inset).frame(minHeight: 200, maxHeight: .infinity)
                }
                HStack {
                    Button("Previous") { offset = max(0, offset - pageSize) }.disabled(offset == 0 || loading)
                    Spacer()
                    Text(total == 0 ? "0 sessions" : "\(offset + 1)–\(min(offset + sessions.count, total)) of \(total)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Next") { offset += pageSize }.disabled(offset + pageSize >= total || loading)
                }
            }.padding(16).frame(minWidth: 330, idealWidth: 420, maxWidth: 540, maxHeight: .infinity)
            Divider()
            if let selected {
                SessionDetailView(session: selected, db: db, settings: settings).id(selected.id).frame(minWidth: 420)
            } else {
                ContentUnavailableView("Choose a session", systemImage: "text.alignleft", description: Text("Read its transcript, open child sessions, or inspect Compass evidence.")).frame(minWidth: 420)
            }
        }.frame(width: geometry.size.width, height: geometry.size.height)
        }
        .task(id: key) { await load() }
        .onChange(of: settings.scopeID) { offset = 0 }
    }
    private func load() async {
        loading = true
        defer { if !Task.isCancelled { loading = false } }
        var query = settings.query(since: todayOnly ? Calendar.current.startOfDay(for: Date()) : selectedRange == .all ? nil : selectedRange.since,
                                   limit: pageSize, offset: offset, search: search)
        query.attentionOnly = attentionOnly
        do {
            let rows = try await db.fetchSessions(query: query)
            let count = try await db.countSessions(query: query)
            try Task.checkCancellation()
            sessions = rows; total = count; error = nil
            if let old = selected { selected = rows.first { $0.id == old.id } }
        } catch is CancellationError { } catch { self.error = "The local index could not be read. Try Refresh." }
    }
}
