import Foundation
import GRDB

struct Repo: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "repos"

    var id: Int64?
    var path: String
    var originUrl: String?
    var lastScannedAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
