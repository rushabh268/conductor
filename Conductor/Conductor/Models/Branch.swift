import Foundation
import GRDB

struct Branch: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "branches"

    var id: Int64?
    var repoId: Int64
    var name: String
    var ticketId: String?
    var firstSeenAt: Date
    var lastSeenAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
