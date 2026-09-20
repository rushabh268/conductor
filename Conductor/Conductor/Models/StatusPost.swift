import Foundation
import GRDB

enum StatusPostType: String, Codable, DatabaseValueConvertible {
    case daily
    case weekly
}

struct StatusPost: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "status_posts"

    var id: Int64?
    var type: StatusPostType
    var postedAt: Date
    var content: String
    var slackResponse: String?

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
