import Foundation

enum TicketParser {
    private static let ticketPattern = try! NSRegularExpression(
        pattern: #"([A-Z]{2,10}-\d+)"#
    )

    private static let reviewNamePatterns = ["review", "pr-review", "code-review"]
    private static let reviewMessagePatterns = ["review the code changes", "review the pr", "provide prioritized, actionable findings"]

    static func extractTicketId(_ text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = ticketPattern.firstMatch(in: text, range: range) else { return nil }
        guard let matchRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[matchRange])
    }

    static func classifySession(name: String?, firstMessage: String?) -> SessionType {
        if let name = name?.lowercased() {
            for pattern in reviewNamePatterns {
                if name.contains(pattern) { return .review }
            }
        }
        if let msg = firstMessage?.lowercased() {
            for pattern in reviewMessagePatterns {
                if msg.contains(pattern) { return .review }
            }
        }
        return .coding
    }
}
