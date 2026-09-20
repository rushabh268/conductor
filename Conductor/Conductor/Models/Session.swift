import Foundation
import GRDB

enum SessionSource: String, Codable, DatabaseValueConvertible, Sendable, CaseIterable {
    case claude
    case codex
    case opencode
}

enum SessionType: String, Codable, DatabaseValueConvertible, Sendable {
    case coding
    case review
    case other
}

struct Session: Identifiable, Codable, FetchableRecord, MutablePersistableRecord, Hashable, Sendable {
    static let databaseTableName = "sessions"

    var id: String
    var source: SessionSource
    var sessionType: SessionType
    var name: String?
    var cwd: String?
    var project: String?
    var gitBranch: String?
    var ticketId: String?
    var status: String?
    var model: String?
    var version: String?
    var messageCount: Int
    var toolCallCount: Int
    var tokensUsed: Int
    var inputTokens: Int
    var outputTokens: Int
    var startedAt: Date
    var endedAt: Date?
    var isExplicitlyNamed: Bool
    var cacheReadTokens: Int
    var cacheCreationTokens: Int
    var nativeID: String = ""
    var profileID: String = "default"
    var role: SessionRole = .main
    var parentNativeID: String? = nil
    var rootNativeID: String? = nil
    var subjectKind: SessionSubjectKind = .root
    var nameProvenance: String = "unknown"
    var classificationProvenance: String = "legacy"
    var lastActivityAt: Date? = nil
    var sourceVersion: String? = nil
    var sourceCompatibility: String = "supported"
    var transcriptPath: String? = nil
    var usageScope: String = "own"
    var usageAvailable: Bool = true
    var usageBreakdownAvailable: Bool = true
    var messageCountAvailable: Bool = true
    var toolCallCountAvailable: Bool = true
    var isHidden: Bool = false
    var isPinned: Bool = false

    var effectiveNativeID: String { nativeID.isEmpty ? id : nativeID }
    var activityAt: Date { lastActivityAt ?? endedAt ?? startedAt }
    static func localID(source: SessionSource, profile: String, nativeID: String) -> String {
        // Length framing avoids delimiter collisions in native IDs and profile paths.
        "\(source.rawValue):\(profile.utf8.count):\(profile):\(nativeID)"
    }
}

enum SessionRole: String, Codable, DatabaseValueConvertible, Sendable, CaseIterable {
    case main, child, `internal`, unknown
}
enum SessionSubjectKind: String, Codable, DatabaseValueConvertible, Sendable { case root, agent, session }
enum UsageScope: String, Sendable { case own, descendants }
struct SessionQuery: Sendable {
    var role: SessionRole? = .main
    var source: SessionSource? = nil
    var since: Date? = nil
    var parentNativeID: String? = nil
    var profileID: String? = nil
    var limit: Int = 50
    var offset: Int = 0
    var search: String? = nil
    var onlyNamed: Bool = false
    var attentionOnly: Bool = false
}
struct SessionCounts: Sendable {
    var main: Int = 0
    var child: Int = 0
    var unknown: Int = 0
    var internalCount: Int = 0
}
struct SessionUsage: Sendable {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheCreationTokens = 0
    var tokensUsed = 0
    var scope: UsageScope = .own
    var unavailableSessions = 0
    var breakdownUnavailableSessions = 0
}
