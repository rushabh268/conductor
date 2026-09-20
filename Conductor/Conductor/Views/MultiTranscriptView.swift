import SwiftUI

/// Kept for existing tabbed callers; each visible transcript still reads one page at a time.
struct MultiTranscriptView: View {
    let sessions: [Session]
    @Binding var selectedTabId: String?
    var onClose: ((String) -> Void)? = nil
    var body: some View {
        if let session = sessions.first(where: { $0.id == selectedTabId }) ?? sessions.first {
            TranscriptView(session: session).id(session.id)
        } else { ContentUnavailableView("Choose a session", systemImage: "doc.text") }
    }
}
