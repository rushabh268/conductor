import Foundation
import GRDB

struct DailyStat: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "daily_stats"

    var id: Int64?
    var date: String
    var source: SessionSource
    var sessionCount: Int
    var messageCount: Int
    var toolCallCount: Int
    var tokensUsed: Int

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension DailyStat {
    var chartId: String {
        "\(date)-\(source.rawValue)"
    }
}
