import Foundation
import GRDB

struct PullRequest: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "pull_requests"

    var id: Int64?
    var repoId: Int64
    var number: Int
    var title: String
    var state: String
    var ticketId: String?
    var additions: Int
    var deletions: Int
    var createdAt: Date
    var mergedAt: Date?
    var url: String?

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
