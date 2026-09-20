import SwiftUI

struct TranscriptView: View {
    let session: Session
    @State private var messages: [TranscriptMessage] = []
    @State private var offset = 0
    @State private var previousOffsets: [Int] = []
    @State private var nextOffset: Int?
    @State private var loading = true
    @State private var unavailable: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Native transcript · up to 50 messages per page").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }.padding(12)
            Divider()
            if let unavailable {
                ContentUnavailableView("Transcript unavailable", systemImage: "doc.text.magnifyingglass", description: Text(unavailable))
            } else if messages.isEmpty && !loading {
                ContentUnavailableView("No text on this page", systemImage: "doc.text", description: Text("Native history may contain tool records without message text."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(messages) { message in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(message.role.capitalized).font(.caption.weight(.semibold))
                                    if let date = message.timestamp { Text(date, style: .time).font(.caption).foregroundStyle(.secondary) }
                                }
                                Text(message.text).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.cardStyle()
                        }
                    }.padding(16)
                }
            }
            Spacer(minLength: 0)
            HStack {
                Button("Previous page") { if let previous = previousOffsets.popLast() { offset = previous } }
                    .disabled(previousOffsets.isEmpty || loading)
                Spacer()
                Button("Next page") { if let nextOffset { previousOffsets.append(offset); offset = nextOffset } }
                    .disabled(nextOffset == nil || loading)
            }.padding(12)
        }
        .task(id: "\(session.id):\(offset)") {
            loading = true
            do {
                let page = try await TranscriptLoader.loadPage(for: session, offset: offset)
                try Task.checkCancellation()
                messages = page.messages; nextOffset = page.nextOffset; unavailable = page.unavailableReason
            } catch is CancellationError { return }
            catch { messages = []; nextOffset = nil; unavailable = "The native file is missing, incompatible, or temporarily unreadable. Refresh the session index and try again." }
            loading = false
        }
    }
}
