import Foundation
import CryptoKit

/// Bounded reads retain a partial trailing record for the next pass. File identity and
/// sampled-prefix or checkpoint-tail replacement invalidate state. An unchanged file
/// returns no transcript bytes; generation checks read at most two 4 KiB windows.
enum JSONLReader {
    struct Chunk {
        var data: Data
        var nextOffset: Int64
        var fingerprint: String
        var reset: Bool
    }
    static let generationPrefixBudget = 4096
    static let generationTailBudget = 4096
    static let byteBudget = 4 * 1024 * 1024
    static func read(_ url: URL, offset: Int64, fingerprint: String?, budget: Int = byteBudget) throws -> Chunk {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let identity = "\(attributes[.systemFileNumber] ?? ""):\(attributes[.creationDate] ?? "")"
        let stamp = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let previous = fingerprint?.components(separatedBy: "|") ?? []
        // The seven-field format binds the tail hash to its consumed offset. Older
        // fingerprints lack that evidence and safely reset once without a DB migration.
        let previousPrefixCount = previous.count == 7 ? Int(previous[3]).flatMap {
            (0...generationPrefixBudget).contains($0) ? $0 : nil
        } : nil
        let prefixCount = min(generationPrefixBudget, Int(size))
        let prefix = try handle.read(upToCount: prefixCount) ?? Data()
        func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
        // Compare exactly the previously sampled prefix: ordinary appends to a short
        // file must not look like replacement merely because the prefix grew.
        let prefixChanged = previousPrefixCount.map { count in
            count > prefix.count || digest(Data(prefix.prefix(count))) != previous[4]
        } ?? true
        let currentFileFingerprint = "\(identity)|\(stamp)|\(size)|\(prefixCount)|\(digest(prefix))"
        var previousTail = Data()
        var tailChanged = true
        if previous.count == 7, Int64(previous[5]) == offset, offset >= 0, offset <= size {
            let tailCount = Int(min(Int64(generationTailBudget), offset))
            try handle.seek(toOffset: UInt64(offset - Int64(tailCount)))
            previousTail = try handle.read(upToCount: tailCount) ?? Data()
            tailChanged = previousTail.count != tailCount || digest(previousTail) != previous[6]
        }
        let reset = previous.first != identity || offset > size || prefixChanged || tailChanged
            || (size == offset && previous.prefix(5).joined(separator: "|") != currentFileFingerprint)
        let start = reset ? 0 : max(0, offset)
        try handle.seek(toOffset: UInt64(start))
        var data = try handle.read(upToCount: budget) ?? Data()
        if let newline = data.lastIndex(of: 10) {
            let tail = data.suffix(from: data.index(after: newline))
            if !tail.isEmpty && (try? JSONSerialization.jsonObject(with: Data(tail))) != nil {
                // Legacy writers may omit the final newline on an otherwise complete record.
            } else { data = data.prefix(through: newline) }
        } else if data.count == budget {
            throw NativeReaderError.recordTooLarge
        } else {
            // A valid final object is accepted even for legacy files lacking a newline.
            // Invalid partial records remain unconsumed and are retried after append.
            if (try? JSONSerialization.jsonObject(with: data)) == nil { data = Data() }
        }
        let nextOffset = start + Int64(data.count)
        // Reuse the validated old tail and newly consumed data rather than rereading
        // behind the new offset; this also binds the checkpoint to the bytes we parsed.
        var nextTail = reset ? Data() : previousTail
        nextTail.append(data.suffix(generationTailBudget))
        let tailHash = digest(Data(nextTail.suffix(generationTailBudget)))
        let nextFingerprint = "\(currentFileFingerprint)|\(nextOffset)|\(tailHash)"
        return Chunk(data: data, nextOffset: nextOffset, fingerprint: nextFingerprint, reset: reset)
    }
}
