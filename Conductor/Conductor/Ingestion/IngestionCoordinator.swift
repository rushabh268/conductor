import Foundation

@MainActor
@Observable
final class IngestionCoordinator {
    private let db: AppDatabase
    private let paths: SourcePaths
    var retentionDays: Int
    private var timer: Timer?
    private var flight: Task<Void, Never>?
    private var trailingRefresh = false
    var hasPendingRefresh: Bool { trailingRefresh }
    private var generation = 0
    private(set) var lastIngestionAt: Date?
    private(set) var isRunning = false
    private(set) var isIngesting = false
    private(set) var readerHealth: [ReaderHealth] = []
    private let operation: (@Sendable () async -> Void)?

    init(db: AppDatabase, paths: SourcePaths = .default, retentionDays: Int = 90,
         operation: (@Sendable () async -> Void)? = nil) {
        self.db = db; self.paths = paths; self.retentionDays = retentionDays; self.operation = operation
    }
    func start(interval: TimeInterval = 60) {
        guard !isRunning else { return }
        isRunning = true
        Task { await runIngestion() }
        timer = Timer.scheduledTimer(withTimeInterval: max(interval, 1), repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.runIngestion() }
        }
    }
    func stop() {
        timer?.invalidate(); timer = nil
        isRunning = false; trailingRefresh = false; generation += 1
        flight?.cancel()
    }
    func runIngestion() async {
        if let flight {
            trailingRefresh = true
            await flight.value
            return
        }
        let currentGeneration = generation
        isIngesting = true
        flight = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.trailingRefresh = false
                if let operation = self.operation { await operation() }
                else {
                    let db = self.db, paths = self.paths, retention = self.retentionDays
                    let worker = Task.detached { await Self.ingest(db: db, paths: paths, retention: retention) }
                    self.readerHealth = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
                }
                if !Task.isCancelled { self.lastIngestionAt = Date() }
            } while self.trailingRefresh && !Task.isCancelled && self.generation == currentGeneration
        }
        await flight?.value
        flight = nil; isIngesting = false
    }
    nonisolated private static func ingest(db: AppDatabase, paths: SourcePaths, retention: Int) async -> [ReaderHealth] {
        var health: [ReaderHealth] = []
        for source in SessionSource.allCases {
            if Task.isCancelled { break }
            do {
                let location: URL
                switch source {
                case .claude:
                    location = FileManager.default.fileExists(atPath: paths.claudeProjects.path) ? paths.claudeProjects : paths.claudeSessions
                    try await ClaudeIngestor.ingestAll(into: db, paths: paths)
                case .codex:
                    location = (try? FileManager.default.contentsOfDirectory(at: paths.codexRoot, includingPropertiesForKeys: nil))?
                        .first(where: { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" })
                        ?? paths.codexRoot.appendingPathComponent("state_5.sqlite")
                    try await CodexIngestor.ingestAll(into: db, paths: paths)
                case .opencode:
                    location = paths.openCodeDatabase
                    try await OpenCodeIngestor.ingestAll(into: db, paths: paths)
                }
                let available = FileManager.default.fileExists(atPath: location.path)
                health.append(ReaderHealth(source: source, status: available ? "ready" : "unavailable",
                    detail: available ? "Read-only native history" : "Native history is not installed at this profile"))
            } catch is CancellationError { break }
            catch {
                // Do not log native paths, session IDs, or transcript contents.
                health.append(ReaderHealth(source: source, status: "unavailable", detail: "Native history could not be read or its schema is unsupported"))
            }
        }
        if !Task.isCancelled { try? await db.pruneOldRecords(olderThan: max(1, retention)) }
        return health
    }
}
