import Foundation
import Testing
@testable import Conductor

private actor IngestionGate {
    var calls = 0
    var continuation: CheckedContinuation<Void, Never>?
    func run() async {
        calls += 1
        if calls == 1 { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor @Test func refreshRequestsCoalesceBehindSingleFlight() async throws {
    let fixture = try CoreFixture(); defer { fixture.remove() }
    let gate = IngestionGate()
    let coordinator = IngestionCoordinator(db: try AppDatabase(inMemory: true), paths: fixture.paths, operation: { await gate.run() })
    let first = Task { await coordinator.runIngestion() }
    let deadline = Date().addingTimeInterval(5)
    while await gate.calls == 0 && Date() < deadline { await Task.yield() }
    #expect(await gate.calls == 1)
    let requests = (0..<20).map { _ in Task { await coordinator.runIngestion() } }
    while !coordinator.hasPendingRefresh && Date() < deadline { await Task.yield() }
    #expect(coordinator.hasPendingRefresh)
    #expect(await gate.calls == 1)
    await gate.release()
    await first.value
    for task in requests { await task.value }
    #expect(await gate.calls == 2)
    #expect(!coordinator.isIngesting)
    coordinator.stop()
}

@MainActor @Test func stopCancelsTrailingRefresh() async throws {
    let fixture = try CoreFixture(); defer { fixture.remove() }
    let gate = IngestionGate()
    let coordinator = IngestionCoordinator(db: try AppDatabase(inMemory: true), paths: fixture.paths, operation: { await gate.run() })
    let first = Task { await coordinator.runIngestion() }
    let deadline = Date().addingTimeInterval(5)
    while await gate.calls == 0 && Date() < deadline { await Task.yield() }
    let pending = Task { await coordinator.runIngestion() }
    while !coordinator.hasPendingRefresh && Date() < deadline { await Task.yield() }
    coordinator.stop()
    await gate.release()
    await first.value; await pending.value
    #expect(await gate.calls == 1)
    #expect(coordinator.lastIngestionAt == nil)
}

@Test func gitDrainsOutputLargerThanPipeCapacityAndChecksExitStatus() async throws {
    let fixture = try CoreFixture(); defer { fixture.remove() }
    // This fixed, process-local alias writes stdout only; no Git configuration is persisted.
    let output = try await GitIngestor.runGit(in: fixture.root.path, args: ["-c", "alias.large=!/usr/bin/yes x | /usr/bin/head -c 200000", "large"])
    #expect(output.utf8.count > 190000)
    await #expect(throws: (any Error).self) {
        try await GitIngestor.runGit(in: fixture.root.path, args: ["rev-parse", "--verify", "missing"])
    }
}
