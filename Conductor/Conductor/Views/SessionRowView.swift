import SwiftUI

struct SessionRowView: View {
    let session: Session
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: session.source.icon).foregroundStyle(.secondary).frame(width: 18)
                Text(session.displayTitle).font(.headline).lineLimit(2)
                Spacer(minLength: 0)
                if session.isPinned { Image(systemName: "pin.fill").font(.caption).accessibilityLabel("Pinned") }
            }
            HStack(spacing: 6) {
                Text(session.source.displayName).tagStyle()
                if session.role != .main { Text(session.role.rawValue.capitalized).tagStyle() }
                Text(session.nameLabel).font(.caption2).foregroundStyle(.secondary)
            }
            if let branch = session.gitBranch { Label(branch, systemImage: "arrow.triangle.branch").font(.caption).lineLimit(1).foregroundStyle(.secondary) }
            HStack {
                Text(session.tokenDescription).lineLimit(1)
                Spacer()
                Text(session.activityAt, style: .relative)
            }.font(.caption2).foregroundStyle(.secondary)
            if let reason = session.attentionReason { Label(reason, systemImage: "exclamationmark.circle").font(.caption2).foregroundStyle(.orange) }
        }.padding(.vertical, 6)
    }
}
