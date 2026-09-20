import SwiftUI

struct SessionChildrenView: View {
    let session: Session
    let db: AppDatabase
    let settings: SettingsStore
    @State private var children: [Session] = []
    @State private var offset = 0
    @State private var hasNext = false
    @State private var selected: Session?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Direct children reported by the native source. Transcripts open only when you choose a child.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.secondary) }
            if children.isEmpty {
                ContentUnavailableView("No indexed children", systemImage: "point.3.filled.connected.trianglepath.dotted", description: Text("Missing parent metadata remains unknown and is available in the Unknown scope."))
            } else {
                List(children) { child in
                    Button { selected = child } label: { SessionRowView(session: child) }.buttonStyle(.plain)
                }
            }
            HStack {
                Button("Previous") { offset = max(0, offset - 50) }.disabled(offset == 0)
                Spacer()
                Button("Next") { offset += 50 }.disabled(!hasNext)
            }
        }.padding(16)
        .task(id: "\(session.id):\(offset)") {
            do {
                let page = try await db.fetchChildren(of: session, limit: 51, offset: offset)
                try Task.checkCancellation()
                children = Array(page.prefix(50)); hasNext = page.count > 50; error = nil
            } catch is CancellationError { } catch { self.error = "Child sessions could not be read from the local index." }
        }
        .sheet(item: $selected) { child in
            VStack {
                HStack { Spacer(); Button("Close") { selected = nil } }.padding(8)
                SessionDetailView(session: child, db: db, settings: settings)
            }.frame(minWidth: 720, minHeight: 580)
        }
    }
}
