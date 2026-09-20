import Testing
import Foundation
@testable import Conductor

@Test func parseGitLogNumstat() {
    let output = """
    42\t10\tpkg/api/handler.go
    15\t3\tpkg/api/handler_test.go
    """
    let (additions, deletions) = GitIngestor.parseNumstat(output)
    #expect(additions == 57)
    #expect(deletions == 13)
}

@Test func parseGitLogNumstatWithBinary() {
    let output = """
    42\t10\tpkg/api/handler.go
    -\t-\timage.png
    15\t3\tpkg/api/handler_test.go
    """
    let (additions, deletions) = GitIngestor.parseNumstat(output)
    #expect(additions == 57)
    #expect(deletions == 13)
}

@Test func parseGitLogNumstatEmpty() {
    let (additions, deletions) = GitIngestor.parseNumstat("")
    #expect(additions == 0)
    #expect(deletions == 0)
}
