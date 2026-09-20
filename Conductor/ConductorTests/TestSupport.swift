import Foundation
@testable import Conductor

struct CoreFixture {
    let root: URL
    var paths: SourcePaths { SourcePaths(root: root, profileID: "default") }
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("conductor-core-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
