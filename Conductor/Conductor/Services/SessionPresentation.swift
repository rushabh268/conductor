import Foundation

extension SessionSource {
    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        }
    }
    var icon: String {
        switch self {
        case .claude: "text.bubble"
        case .codex: "terminal"
        case .opencode: "chevron.left.forwardslash.chevron.right"
        }
    }
}

extension Session {
    var displayTitle: String { name.flatMap { $0.isEmpty ? nil : $0 } ?? project ?? "Untitled session" }
    var nameLabel: String { isExplicitlyNamed ? "Named" : (name == nil ? "Untitled" : "Native title") }
    /// File timestamps are observations, never proof that a native process is still running.
    var attentionReason: String? {
        switch status?.lowercased() {
        case "error", "failed": "Native source reported an error"
        case "waiting", "waiting_for_input", "waiting_for_approval": "Native source reported waiting"
        default: sourceCompatibility == "supported" ? nil : "Native source needs compatibility review"
        }
    }
    var tokenDescription: String { usageAvailable ? "\(tokensUsed.formatted()) recorded tokens" : "Token usage unavailable" }
}

enum HandoffBuilder {
    /// An editable checkpoint of recorded facts. It makes no claim about code correctness or task completion.
    static func build(session: Session, messages: [TranscriptMessage] = [], includeExcerpt: Bool = false) -> String {
        var lines = ["# Session checkpoint", "", "Tool: \(session.source.displayName)",
                     "Title: \(session.displayTitle)", "Role: \(session.role.rawValue)",
                     "Last recorded activity: \(ISO8601DateFormatter().string(from: session.activityAt))",
                     "Status: \(session.status ?? "Unavailable from native source")",
                     "Usage: \(session.tokenDescription) (\(session.usageScope))"]
        if let branch = session.gitBranch { lines.append("Recorded branch: \(branch)") }
        if includeExcerpt, let last = messages.last {
            lines += ["", "## Selected transcript excerpt (unverified)", String(last.text.prefix(2000))]
        }
        lines += ["", "## Next step", "Add your next step here.", "",
                  "Source: local native session metadata. Completion and test results have not been verified by Conductor."]
        return lines.joined(separator: "\n")
    }
}
