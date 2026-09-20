import Foundation
import GRDB

enum NativeDatabase {
    static func open(_ url: URL, table: String, required: Set<String>) throws -> DatabaseQueue {
        var config = Configuration()
        config.readonly = true
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA query_only = ON") }
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        try queue.read { db in
            guard try db.tableExists(table) else { throw NativeReaderError.unsupportedSchema(table) }
            let columns = Set(try db.columns(in: table).map(\.name))
            guard required.isSubset(of: columns) else { throw NativeReaderError.unsupportedSchema(table) }
        }
        return queue
    }
    static func fingerprint(_ url: URL) throws -> String {
        // WAL commits can change without changing the main database file.
        try [url.path, url.path + "-wal"].map { path in
            guard FileManager.default.fileExists(atPath: path) else { return "absent" }
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            return "\(attrs[.systemFileNumber] ?? ""):\(attrs[.size] ?? ""):\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "|")
    }
}
