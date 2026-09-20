import SwiftUI

struct CompassEvidenceView: View {
    let session: Session
    let settings: SettingsStore
    @State private var client: CompassClient?
    @State private var page: CompassEvidencePage?
    @State private var loading = false
    @State private var error: String?
    @State private var requestedCursor: String?
    @State private var generation = 0
    private var configured: Bool { !settings.compassSocketPath.isEmpty && !settings.compassReaderKeyPath.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Compass evidence").font(.headline)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button("Refresh snapshot") { requestedCursor = nil; generation += 1 }.disabled(!configured || loading)
            }
            Text("Verified retained observations from the optional local companion. Native history remains the transcript source.")
                .font(.caption).foregroundStyle(.secondary)
            if !configured {
                ContentUnavailableView("Compass is optional", systemImage: "location.north.circle", description: Text("Add its local socket and reader key in Settings to inspect session evidence."))
            } else if let error {
                ContentUnavailableView("Compass unavailable", systemImage: "wifi.slash", description: Text(error))
            } else if let page, page.state == "ready" {
                HStack(spacing: 18) {
                    Label("\(page.summary?.events ?? 0) events", systemImage: "checkmark.shield")
                    Label("\(page.summary?.grounding ?? 0) linked grounding records", systemImage: "doc.text.magnifyingglass")
                }.font(.caption).cardStyle()
                if page.relationship == "unknown" {
                    Text("Compass could not verify this session's relationship to the selected root.").font(.caption).foregroundStyle(.secondary)
                }
                if page.groundingState == "unavailable" {
                    Text("Session-linked grounding is unavailable. Older monthly totals are not attributed to this session.").font(.caption).foregroundStyle(.secondary)
                }
                List(page.events) { event in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text(event.displayEventType).font(.headline); Spacer(); Text(event.timestamp).font(.caption.monospaced()).foregroundStyle(.secondary) }
                        if let decision = event.decision { Text("Observed decision: \(decision.action)").font(.caption) }
                        if let metadata = event.metadata {
                            if let reason = metadata.matchReason { Text("Grounding match: \(reason)").font(.caption) }
                            ForEach(Array((metadata.sources ?? []).enumerated()), id: \.offset) { _, source in
                                Text("\(source.kind): \(source.ref)").font(.caption.monospaced()).textSelection(.enabled)
                            }
                            if let tokens = metadata.approxTokens { Text("Approximately \(tokens) grounding tokens; this is not model usage.").font(.caption).foregroundStyle(.secondary) }
                        }
                    }.padding(.vertical, 4)
                }
                HStack { Spacer(); Button("Next evidence page") { requestedCursor = page.nextCursor }.disabled(page.nextCursor == nil || loading) }
            } else if let page {
                ContentUnavailableView(stateTitle(page.state), systemImage: "tray", description: Text(page.reason ?? stateDetail(page.state)))
            } else { Spacer() }
        }.padding(16)
        .task(id: "\(session.id):\(settings.compassSocketPath):\(settings.compassReaderKeyPath):\(generation):\(requestedCursor ?? "first")") {
            guard configured else { return }
            loading = true; error = nil
            do {
                let response: CompassEvidencePage
                if let requestedCursor, let client { response = try await client.next(cursor: requestedCursor) }
                else {
                    let connection = CompassConnection(socketPath: settings.compassSocketPath, readerKeyPath: settings.compassReaderKeyPath)
                    let nextClient = CompassClient(connection: connection)
                    client = nextClient
                    response = try await nextClient.begin(for: session)
                }
                try Task.checkCancellation()
                page = response
            } catch is CancellationError { return }
            catch { page = nil; self.error = error.localizedDescription }
            loading = false
        }
    }
    private func stateTitle(_ state: String) -> String {
        switch state {
        case "absent": "No retained observations"
        case "pruned": "Audit run has been pruned"
        case "stale": "Snapshot expired"
        case "resource_exhausted": "Evidence request reached its limit"
        default: "Evidence unavailable"
        }
    }
    private func stateDetail(_ state: String) -> String {
        switch state {
        case "absent": "Compass has no retained observations matching this native session. That does not establish that no work occurred."
        case "pruned": "An authenticated archive receipt exists for this run. It cannot reconstruct deleted events or per-session monthly grounding."
        case "stale": "Refresh to request a new immutable snapshot."
        case "resource_exhausted": "The request exceeded the companion's bounded verification budget. Native history is still available."
        default: "This source or retained evidence cannot support the requested association."
        }
    }
}
