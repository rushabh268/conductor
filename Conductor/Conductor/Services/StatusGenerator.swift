import Foundation

enum StatusGenerator {
    struct ProjectLineStats { let project: String; let additions: Int; let deletions: Int }
    struct BranchFileChanges { let branch: String; let files: [String] }

    static func generateDaily(date: String, sessions: [Session], lineStats: [ProjectLineStats], reviewCount: Int,
                              branchChanges: [BranchFileChanges] = [], sessionSummaries: [String: String] = [:]) -> String {
        generate(title: "Daily Status — \(date)", sessions: sessions, lineStats: lineStats, reviewCount: reviewCount,
                 branchChanges: branchChanges, summaries: sessionSummaries)
    }
    static func generateWeekly(weekStart: String, weekEnd: String, sessions: [Session], lineStats: [ProjectLineStats], reviewCount: Int,
                               branchChanges: [BranchFileChanges] = [], sessionSummaries: [String: String] = [:]) -> String {
        generate(title: "Weekly Status — \(weekStart) to \(weekEnd)", sessions: sessions, lineStats: lineStats, reviewCount: reviewCount,
                 branchChanges: branchChanges, summaries: sessionSummaries)
    }
    private static func generate(title: String, sessions: [Session], lineStats: [ProjectLineStats], reviewCount: Int,
                                 branchChanges: [BranchFileChanges], summaries: [String: String]) -> String {
        var lines = ["# \(title)", "", "Recorded native session activity; completion and test results are not inferred.", ""]
        // Worktrees with matching display names are separate local projects.
        let groups = Dictionary(grouping: sessions) { $0.cwd ?? "\($0.source.rawValue):\($0.profileID):\($0.project ?? "unknown")" }
        for key in groups.keys.sorted() {
            guard let group = groups[key], let first = group.first else { continue }
            lines.append("## \(first.project ?? "Untitled project")")
            lines.append("\(group.count) sessions · \(Set(group.map { $0.source.displayName }).sorted().joined(separator: ", "))")
            for session in group.sorted(by: { $0.activityAt > $1.activityAt }) {
                let ticket = session.ticketId.map { " [\($0)]" } ?? ""
                lines.append("- \(session.displayTitle)\(ticket) · \(session.role.rawValue) · \(session.status ?? "status unavailable")")
                if let branch = session.gitBranch { lines.append("  Recorded branch: \(branch)") }
                if let summary = summaries[session.id] { lines.append("  Selected excerpt (unverified): \(summary)") }
            }
            lines.append("")
        }
        lines += ["## Recorded totals", "", "Sessions: \(sessions.count)", "Reviews: \(reviewCount)"]
        let known = sessions.filter(\.usageAvailable)
        lines.append("Tokens: \(known.reduce(0) { $0 + $1.tokensUsed }) (\(sessions.count - known.count) sessions unavailable)")
        for stat in lineStats { lines.append("Repository observation — \(stat.project): +\(stat.additions) / -\(stat.deletions) lines; attribution to a session is not established.") }
        for change in branchChanges { lines.append("Recorded branch \(change.branch): \(change.files.prefix(8).joined(separator: ", "))") }
        lines += ["", "## Next step", "Add your next step here."]
        return lines.joined(separator: "\n")
    }
}
