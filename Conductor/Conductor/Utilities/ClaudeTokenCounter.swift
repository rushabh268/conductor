import Foundation

enum ClaudeTokenCounter {
    struct TokenUsage {
        let inputTokens: Int
        let outputTokens: Int
        let cacheCreationTokens: Int
        let cacheReadTokens: Int

        var totalTokens: Int {
            inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
        }

        static let zero = TokenUsage(
            inputTokens: 0, outputTokens: 0,
            cacheCreationTokens: 0, cacheReadTokens: 0
        )

        static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
            TokenUsage(
                inputTokens: lhs.inputTokens + rhs.inputTokens,
                outputTokens: lhs.outputTokens + rhs.outputTokens,
                cacheCreationTokens: lhs.cacheCreationTokens + rhs.cacheCreationTokens,
                cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens
            )
        }
    }

    /// Compute the project hash used by Claude to name project directories.
    /// Claude replaces both "/" and "." with "-" in the cwd path.
    static func projectHash(for cwd: String) -> String {
        cwd.replacingOccurrences(of: "/", with: "-")
           .replacingOccurrences(of: ".", with: "-")
    }

    /// Build the JSONL file URL for a given session.
    static func jsonlPath(sessionId: String, cwd: String?, paths: SourcePaths = .default) -> String? {
        guard let cwd else { return nil }
        let hash = projectHash(for: cwd)
        return paths.claudeProjects
            .appendingPathComponent(hash)
            .appendingPathComponent("\(sessionId).jsonl")
            .path
    }

    /// Sum token usage from all assistant messages in a session JSONL.
    static func countTokens(sessionId: String, cwd: String?, paths: SourcePaths = .default) -> TokenUsage {
        guard let path = jsonlPath(sessionId: sessionId, cwd: cwd, paths: paths) else { return .zero }

        let url = URL(fileURLWithPath: path)
        guard let data = try? String(contentsOf: url, encoding: .utf8) else {
            return .zero
        }

        var result = TokenUsage.zero
        for line in data.components(separatedBy: "\n") where !line.isEmpty {
            guard let jsonData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }

            let input = usage["input_tokens"] as? Int ?? 0
            let output = usage["output_tokens"] as? Int ?? 0
            let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
            let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0

            result = result + TokenUsage(
                inputTokens: input,
                outputTokens: output,
                cacheCreationTokens: cacheCreation,
                cacheReadTokens: cacheRead
            )
        }
        return result
    }
}
