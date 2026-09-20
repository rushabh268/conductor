import Foundation
import Darwin

enum GitIngestor {
    static func parseNumstat(_ output: String) -> (additions: Int, deletions: Int) {
        var totalAdd = 0
        var totalDel = 0
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count >= 2,
                  let add = Int(parts[0]),
                  let del = Int(parts[1]) else { continue }
            totalAdd += add
            totalDel += del
        }
        return (totalAdd, totalDel)
    }

    static func runGit(in directory: String, args: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)

        let pipe = Pipe()
        // Merge stderr so both streams are drained while the process runs.
        process.standardOutput = pipe
        process.standardError = pipe
        process.environment = ProcessInfo.processInfo.environment.merging(["GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0"]) { _, new in new }
        try process.run()
        let timeout = Task.detached {
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled && process.isRunning {
                process.terminate()
                try? await Task.sleep(for: .seconds(1))
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            let data = await Task.detached { () -> Data in
                var result = Data()
                while let chunk = try? pipe.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    if result.count < 8 * 1024 * 1024 { result.append(chunk) }
                    else if process.isRunning { process.terminate() }
                }
                process.waitUntilExit()
                return result
            }.value
            try Task.checkCancellation()
            guard process.terminationStatus == 0 else { throw NativeReaderError.malformedRecord }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    static func fetchLineStats(repoPath: String, since: Date) async throws -> (additions: Int, deletions: Int) {
        let formatter = ISO8601DateFormatter()
        let sinceStr = formatter.string(from: since)

        // Try current branch first (--all can miss recent commits in some configurations)
        var output = try await runGit(in: repoPath, args: [
            "log", "--numstat", "--format=", "--since=\(sinceStr)"
        ])
        var result = parseNumstat(output)

        // Fallback: if no results, try without date filter on current branch
        if result.additions == 0 && result.deletions == 0 {
            output = try await runGit(in: repoPath, args: [
                "log", "--numstat", "--format=", "-10"
            ])
            result = parseNumstat(output)
        }

        return result
    }

    static func fetchCurrentBranch(repoPath: String) async throws -> String? {
        let output = try await runGit(in: repoPath, args: ["branch", "--show-current"])
        return output.isEmpty ? nil : output
    }

    static func isGitRepo(path: String) async -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        do {
            let output = try await runGit(in: path, args: ["rev-parse", "--git-dir"])
            return !output.isEmpty
        } catch {
            return false
        }
    }

    static func fetchOriginUrl(repoPath: String) async -> String? {
        guard let output = try? await runGit(in: repoPath, args: ["remote", "get-url", "origin"]),
              !output.isEmpty else { return nil }
        return output
    }

    static func fetchRecentBranches(repoPath: String, since: Date) async throws -> [String] {
        let formatter = ISO8601DateFormatter()
        let sinceStr = formatter.string(from: since)

        let output = try await runGit(in: repoPath, args: [
            "log", "--all", "--format=%D", "--since=\(sinceStr)"
        ])

        var branches = Set<String>()
        for line in output.split(separator: "\n") {
            for ref in line.split(separator: ",") {
                let trimmed = ref.trimmingCharacters(in: .whitespaces)
                if trimmed.contains("->") { continue }
                let cleaned = trimmed
                    .replacingOccurrences(of: "origin/", with: "")
                    .replacingOccurrences(of: "HEAD", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if !cleaned.isEmpty {
                    branches.insert(cleaned)
                }
            }
        }
        return Array(branches).sorted()
    }

    static func fetchDailyLineStats(repoPath: String, date: String) async throws -> (additions: Int, deletions: Int) {
        let output = try await runGit(in: repoPath, args: [
            "log", "--numstat", "--format=",
            "--since=\(date)T00:00:00", "--until=\(date)T23:59:59"
        ])
        return parseNumstat(output)
    }

    static func fetchChangedFiles(repoPath: String, branch: String) async throws -> [String] {
        // Get files changed on this branch vs its merge base with main/master
        let mainCheck = try? await runGit(in: repoPath, args: ["rev-parse", "--verify", "main"])
        let mainBranch = (mainCheck != nil && !(mainCheck ?? "").isEmpty) ? "main" : "master"

        guard let mergeBase = try? await runGit(in: repoPath, args: ["merge-base", mainBranch, branch]),
              !mergeBase.isEmpty else {
            return []
        }

        let output = try await runGit(in: repoPath, args: ["diff", "--name-status", mergeBase, branch])
        return output.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    static func ingestAll(into db: AppDatabase) async throws {
        let repos = try await db.fetchRepos()
        let since = Calendar.current.date(byAdding: .day, value: -1, to: Date())!

        for repo in repos {
            guard FileManager.default.fileExists(atPath: repo.path) else { continue }

            let todayStr = ISO8601DateFormatter().string(from: Date()).prefix(10)
            let (add, del) = try await fetchDailyLineStats(repoPath: repo.path, date: String(todayStr))

            let stat = LineStat(
                id: nil,
                repoId: repo.id!,
                date: String(todayStr),
                additions: add,
                deletions: del
            )
            try await db.saveLineStat(stat)

            let branches = try await fetchRecentBranches(repoPath: repo.path, since: since)
            for branchName in branches {
                let branch = Branch(
                    id: nil,
                    repoId: repo.id!,
                    name: branchName,
                    ticketId: TicketParser.extractTicketId(branchName),
                    firstSeenAt: Date(),
                    lastSeenAt: Date()
                )
                try await db.saveBranch(branch)
            }
        }
    }
}
