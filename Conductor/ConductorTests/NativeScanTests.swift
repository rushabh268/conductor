import Foundation
import GRDB
import Testing
@testable import Conductor

@Test(arguments: [SessionSource.codex, .opencode])
func nativeScanConcurrentDeletionAndBackdatedInsertion(source: SessionSource) async throws {
    let fixture = try CoreFixture(); defer { fixture.remove() }
    let root = source == .codex ? fixture.paths.codexRoot : fixture.paths.openCodeRoot
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let path = source == .codex ? root.appendingPathComponent("state_5.sqlite") : fixture.paths.openCodeDatabase
    let writer = try DatabaseQueue(path: path.path)
    let table = source == .codex ? "threads" : "session"
    try await writer.write { native in
        if source == .codex {
            try native.execute(sql: "CREATE TABLE threads(id TEXT PRIMARY KEY, cwd TEXT, title TEXT, created_at INTEGER, updated_at INTEGER)")
        } else {
            try native.execute(sql: "CREATE TABLE session(id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT, title TEXT, version TEXT, time_created INTEGER, time_updated INTEGER)")
        }
        for index in 0...500 {
            let id = String(format: "%04d", index)
            let stamp = index == 0 ? 200 : 100
            if source == .codex {
                try native.execute(sql: "INSERT INTO threads VALUES (?, '/fixture', '', 1, ?)", arguments: [id, stamp])
            } else {
                try native.execute(sql: "INSERT INTO session VALUES (?, NULL, '/fixture', '', 'fixture', 1, ?)", arguments: [id, stamp])
            }
        }
    }
    let local = try AppDatabase(inMemory: true)
    let ingestion = Task {
        if source == .codex { try await CodexIngestor.ingestAll(into: local, paths: fixture.paths) }
        else { try await OpenCodeIngestor.ingestAll(into: local, paths: fixture.paths) }
    }
    var observedFirst = false
    for _ in 0..<10000 {
        if try await local.fetchSession(source: source, nativeID: "0000") != nil { observedFirst = true; break }
        await Task.yield()
    }
    #expect(observedFirst)
    // The first page is being saved locally: shifting OFFSET now must not lose 0500.
    #expect(try await local.fetchSession(source: source, nativeID: "0500") == nil)
    try await writer.write { native in
        try native.execute(sql: "DELETE FROM \(table) WHERE id = '0000'")
        if source == .codex {
            try native.execute(sql: "INSERT INTO threads VALUES ('backdated', '/fixture', '', 1, 50)")
        } else {
            try native.execute(sql: "INSERT INTO session VALUES ('backdated', NULL, '/fixture', '', 'fixture', 1, 50)")
        }
    }
    try await ingestion.value
    let afterWriter = try Data(contentsOf: path)
    if source == .codex { try await CodexIngestor.ingestAll(into: local, paths: fixture.paths) }
    else { try await OpenCodeIngestor.ingestAll(into: local, paths: fixture.paths) }
    #expect(try await local.fetchSession(source: source, nativeID: "0500") != nil)
    #expect(try await local.fetchSession(source: source, nativeID: "backdated") != nil)
    #expect(try Data(contentsOf: path) == afterWriter)
    // A later import may legitimately preserve its old timestamp, below 200.
    try await writer.write { native in
        if source == .codex {
            try native.execute(sql: "INSERT INTO threads VALUES ('later-import', '/fixture', '', 1, 25)")
        } else {
            try native.execute(sql: "INSERT INTO session VALUES ('later-import', NULL, '/fixture', '', 'fixture', 1, 25)")
        }
    }
    if source == .codex { try await CodexIngestor.ingestAll(into: local, paths: fixture.paths) }
    else { try await OpenCodeIngestor.ingestAll(into: local, paths: fixture.paths) }
    #expect(try await local.fetchSession(source: source, nativeID: "later-import") != nil)
}

@Test func jsonlSameInodeTruncateAndRegrowResetsGeneration() throws {
    let fixture = try CoreFixture(); defer { fixture.remove() }
    let file = fixture.root.appendingPathComponent("history.jsonl")
    let old = Data("{\"text\":\"old\"}\n".utf8)
    try old.write(to: file)
    let initial = try JSONLReader.read(file, offset: 0, fingerprint: nil)
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: 0)
    let replacement = Data("{\"text\":\"replacement much longer than old content\"}\n".utf8)
    try handle.write(contentsOf: replacement); try handle.close()
    let current = try JSONLReader.read(file, offset: initial.nextOffset, fingerprint: initial.fingerprint)
    #expect(current.reset)
    #expect(current.data == replacement)
}

@Test func jsonlUnchangedAndAppendPreserveBoundedOffsets() throws {
    let fixture = try CoreFixture(); defer { fixture.remove() }
    let file = fixture.root.appendingPathComponent("history.jsonl")
    let line = Data("{\"text\":\"record\"}\n".utf8)
    try (line + line + line).write(to: file)
    let first = try JSONLReader.read(file, offset: 0, fingerprint: nil, budget: line.count)
    let second = try JSONLReader.read(file, offset: first.nextOffset, fingerprint: first.fingerprint, budget: line.count)
    #expect(!second.reset)
    #expect(second.data.count == line.count)
    #expect(second.nextOffset == Int64(line.count * 2))
    let third = try JSONLReader.read(file, offset: second.nextOffset, fingerprint: second.fingerprint, budget: line.count)
    let unchanged = try JSONLReader.read(file, offset: third.nextOffset, fingerprint: third.fingerprint)
    #expect(!unchanged.reset)
    #expect(unchanged.data.isEmpty)
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd(); try handle.write(contentsOf: line); try handle.close()
    let appended = try JSONLReader.read(file, offset: third.nextOffset, fingerprint: third.fingerprint, budget: line.count)
    #expect(!appended.reset)
    #expect(appended.data == line)
}

@Test(arguments: [SessionSource.codex, .opencode], [false, true])
func nativeSnapshotOverflowNeverWritesLocalRowsOrCheckpoint(source: SessionSource, oversizedText: Bool) async throws {
    let fixture = try CoreFixture(); defer { fixture.remove() }
    let root = source == .codex ? fixture.paths.codexRoot : fixture.paths.openCodeRoot
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let path = source == .codex ? root.appendingPathComponent("state_5.sqlite") : fixture.paths.openCodeDatabase
    let writer = try DatabaseQueue(path: path.path)
    let table = source == .codex ? "threads" : "session"
    try await writer.write { native in
        if source == .codex {
            try native.execute(sql: "CREATE TABLE threads(id TEXT PRIMARY KEY, cwd TEXT, title TEXT, created_at INTEGER, updated_at INTEGER)")
        } else {
            try native.execute(sql: "CREATE TABLE session(id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT, title TEXT, version TEXT, time_created INTEGER, time_updated INTEGER)")
        }
        for index in 0..<(oversizedText ? 1 : NativeMetadataSnapshot.rowLimit + 1) {
            if source == .codex {
                try native.execute(sql: "INSERT INTO threads VALUES (?, '/fixture', '', 1, 1)", arguments: [String(index)])
            } else {
                try native.execute(sql: "INSERT INTO session VALUES (?, NULL, '/fixture', '', 'fixture', 1, 1)", arguments: [String(index)])
            }
        }
        if oversizedText { try native.execute(sql: "UPDATE \(table) SET title = hex(zeroblob(?))", arguments: [NativeMetadataSnapshot.byteLimit / 2 + 1]) }
    }
    let local = try AppDatabase(inMemory: true)
    do {
        if source == .codex { try await CodexIngestor.ingestAll(into: local, paths: fixture.paths) }
        else { try await OpenCodeIngestor.ingestAll(into: local, paths: fixture.paths) }
        Issue.record("Expected snapshot admission rejection")
    } catch NativeReaderError.recordTooLarge { }
    #expect(try await local.fetchAllSessions().isEmpty)
    #expect(try await local.checkpoint(path: "\(source.rawValue):default:\(path.path)") == nil)
}

@Test func jsonlFinalObjectWithoutNewlineAndPartialTailRemainSupported() throws {
    let fixture = try CoreFixture(); defer { fixture.remove() }
    let file = fixture.root.appendingPathComponent("history.jsonl")
    let complete = Data("{\"text\":\"complete\"}".utf8)
    try complete.write(to: file)
    let first = try JSONLReader.read(file, offset: 0, fingerprint: nil)
    #expect(first.data == complete)
    try Data("{\"text\":\"first\"}\n{\"text\":".utf8).write(to: file)
    let partial = try JSONLReader.read(file, offset: 0, fingerprint: nil)
    #expect(partial.data == Data("{\"text\":\"first\"}\n".utf8))
    let append = try FileHandle(forWritingTo: file)
    try append.seekToEnd(); try append.write(contentsOf: Data("\"second\"}".utf8)); try append.close()
    let final = try JSONLReader.read(file, offset: partial.nextOffset, fingerprint: partial.fingerprint)
    #expect(!final.reset)
    #expect(final.data == Data("{\"text\":\"second\"}".utf8))
}

@Test func jsonlPreservedLargePrefixButRewrittenCheckpointTailResets() throws {
    let fixture = try CoreFixture(); defer { fixture.remove() }
    let file = fixture.root.appendingPathComponent("history.jsonl")
    let prefix = String(repeating: "{\"text\":\"prefix\"}\n", count: 400)
    let oldTail = String(repeating: "{\"text\":\"old tail\"}\n", count: 400)
    let newTail = String(repeating: "{\"text\":\"new tail\"}\n", count: 400)
    let appended = Data("{\"text\":\"extra\"}\n".utf8)
    let original = Data((prefix + oldTail).utf8)
    try original.write(to: file)
    let first = try JSONLReader.read(file, offset: 0, fingerprint: nil)
    #expect(first.nextOffset > 8192)
    let replacement = Data((prefix + newTail).utf8) + appended
    #expect(replacement.prefix(4096) == original.prefix(4096))
    let writer = try FileHandle(forWritingTo: file)
    try writer.truncate(atOffset: 0)
    try writer.write(contentsOf: replacement); try writer.close()
    let rewritten = try JSONLReader.read(file, offset: first.nextOffset, fingerprint: first.fingerprint)
    #expect(rewritten.reset)
    #expect(rewritten.data == replacement)
    let append = try FileHandle(forWritingTo: file)
    try append.seekToEnd(); try append.write(contentsOf: appended); try append.close()
    let next = try JSONLReader.read(file, offset: rewritten.nextOffset, fingerprint: rewritten.fingerprint, budget: appended.count)
    #expect(!next.reset)
    #expect(next.data == appended)
}

@Test func jsonlOlderFingerprintResetsOnceAndTailIsBoundToOffset() throws {
    let fixture = try CoreFixture(); defer { fixture.remove() }
    let file = fixture.root.appendingPathComponent("history.jsonl")
    let record = Data("{\"text\":\"fixture\"}\n".utf8)
    try (record + record).write(to: file)
    let initial = try JSONLReader.read(file, offset: 0, fingerprint: nil, budget: record.count)
    let legacy = initial.fingerprint.components(separatedBy: "|").prefix(5).joined(separator: "|")
    let migrated = try JSONLReader.read(file, offset: initial.nextOffset, fingerprint: legacy, budget: record.count)
    #expect(migrated.reset)
    #expect(migrated.nextOffset == Int64(record.count))
    let next = try JSONLReader.read(file, offset: migrated.nextOffset, fingerprint: migrated.fingerprint, budget: record.count)
    #expect(!next.reset)
    #expect(next.nextOffset == Int64(record.count * 2))
    let mismatched = try JSONLReader.read(file, offset: 1, fingerprint: next.fingerprint, budget: record.count)
    #expect(mismatched.reset)
    #expect(mismatched.nextOffset == Int64(record.count))
}
