import Foundation

/// Sharing runs only after the user reviews the text and presses Post.
enum SlackPoster {
    static func validatedURL(_ value: String) throws -> URL {
        guard value.utf8.count <= 4096, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let parts = URLComponents(string: value), parts.scheme == "https",
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port == nil || parts.port == 443,
              ["hooks.slack.com", "hooks.slack-gov.com"].contains(parts.host?.lowercased() ?? ""),
              parts.path.hasPrefix("/services/"), parts.path.split(separator: "/").count >= 4,
              let url = parts.url else { throw SlackError.invalidURL }
        return url
    }

    static func request(content: String, webhookUrl: String) throws -> URLRequest {
        guard !content.isEmpty, content.utf8.count <= 64 * 1024 else { throw SlackError.invalidContent }
        var request = URLRequest(url: try validatedURL(webhookUrl), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": content])
        return request
    }

    static func post(content: String, webhookUrl: String) async throws -> String {
        let request = try request(content: content, webhookUrl: webhookUrl)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: NoSharingRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SlackError.failed }
        var received = 0
        for try await _ in bytes {
            received += 1
            guard received <= 4096 else { throw SlackError.failed }
        }
        return "Posted"
    }

    enum SlackError: LocalizedError {
        case invalidURL, invalidContent, failed
        var errorDescription: String? {
            switch self {
            case .invalidURL: "Enter an HTTPS Slack incoming-webhook URL."
            case .invalidContent: "Sharing requires a nonempty preview of at most 64 KiB."
            case .failed: "Slack did not accept the message. No response details were stored."
            }
        }
    }
}

private final class NoSharingRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
