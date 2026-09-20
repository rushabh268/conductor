import Foundation

/// Resolving paths is pure; readers never create or modify these native locations.
struct SourcePaths: Sendable {
    var claudeRoot: URL
    var codexRoot: URL
    var openCodeRoot: URL
    var profileID: String = "default"
    static var `default`: SourcePaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return SourcePaths(claudeRoot: home.appendingPathComponent(".claude"),
                           codexRoot: home.appendingPathComponent(".codex"),
                           openCodeRoot: home.appendingPathComponent(".local/share/opencode"))
    }
    init(claudeRoot: URL, codexRoot: URL, openCodeRoot: URL, profileID: String = "default") {
        self.claudeRoot = claudeRoot; self.codexRoot = codexRoot
        self.openCodeRoot = openCodeRoot; self.profileID = profileID
    }
    init(root: URL, profileID: String = "fixture") {
        self.init(claudeRoot: root.appendingPathComponent("claude"), codexRoot: root.appendingPathComponent("codex"),
                  openCodeRoot: root.appendingPathComponent("opencode"), profileID: profileID)
    }
    var claudeProjects: URL { claudeRoot.appendingPathComponent("projects") }
    var claudeSessions: URL { claudeRoot.appendingPathComponent("sessions") }
    var openCodeDatabase: URL { openCodeRoot.appendingPathComponent("opencode.db") }
}
struct ReaderHealth: Identifiable, Sendable {
    var id: String { source.rawValue }
    var source: SessionSource
    var status: String
    var detail: String
    var checkedAt: Date = Date()
}
enum NativeReaderError: Error { case unsupportedSchema(String), malformedRecord, recordTooLarge }
