import Foundation
import GRDB

struct LineStat: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "line_stats"

    var id: Int64?
    var repoId: Int64
    var date: String
    var additions: Int
    var deletions: Int

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
