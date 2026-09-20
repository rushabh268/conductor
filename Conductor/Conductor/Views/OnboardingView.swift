import SwiftUI

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var currentPage = 0
    static let slides: [(icon: String, title: String, description: String)] = [
        ("waveform.path.ecg", "Welcome to Conductor", "One local workspace for Claude Code, Codex, and OpenCode history."),
        ("rectangle.stack", "Start with main sessions", "Main sessions lead the list. Open children when you need them; unknown ancestry remains visible in its own scope."),
        ("doc.text.magnifyingglass", "Read the source", "Browse transcripts one page at a time, inspect recorded usage, and build a factual handoff you can edit."),
        ("location.north.circle", "Add Compass when useful", "An optional reader connection shows retained audit and grounding evidence. Native browsing works without it."),
        ("lock.shield", "You control what leaves", "No native settings are changed. Sharing is optional and sends only a preview you explicitly approve.")
    ]
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            let slide = Self.slides[currentPage]
            Image(systemName: slide.icon).font(.system(size: 44))
            Text(slide.title).font(.title2.bold())
            Text(slide.description).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 350)
            Spacer()
            HStack {
                Button("Back") { currentPage -= 1 }.disabled(currentPage == 0)
                Spacer()
                Text("\(currentPage + 1) of \(Self.slides.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(currentPage == Self.slides.count - 1 ? "Get started" : "Next") {
                    if currentPage == Self.slides.count - 1 { dismiss() } else { currentPage += 1 }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 450, height: 360)
    }
}
