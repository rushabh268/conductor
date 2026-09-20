import Foundation
import GRDB

/// Admit metadata only within fixed limits, in one read transaction. The transaction
/// ends before any awaited local writes, so ingestion never holds a native WAL snapshot.
enum NativeMetadataSnapshot {
    static let rowLimit = 10_000
    static let byteLimit = 16 * 1024 * 1024

    static func read(_ queue: DatabaseQueue, sql: String) throws -> [Row] {
        try queue.read { db in
            try Task.checkCancellation()
            let statement = try db.makeStatement(sql: sql)
            let lengths: String = statement.columnNames.map { name -> String in
                let quoted = "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                return "COALESCE(length(CAST(\(quoted) AS BLOB)), 0)"
            }.joined(separator: " + ")
            // Compute sizes inside SQLite before materializing potentially large text.
            let admission = try Row.fetchOne(db, sql: "SELECT COUNT(*) AS n, COALESCE(SUM(\(lengths)), 0) AS bytes FROM (\(sql) LIMIT \(rowLimit + 1))")!
            guard (admission["n"] as Int) <= rowLimit, (admission["bytes"] as Int) <= byteLimit else {
                throw NativeReaderError.recordTooLarge
            }
            return try Row.fetchAll(db, sql: "\(sql) LIMIT \(rowLimit)")
        }
    }
}
