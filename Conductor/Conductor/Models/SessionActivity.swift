import Foundation

struct SessionActivity: Identifiable, Sendable {
    let day: String
    let source: SessionSource
    let sessions: Int
    let tokens: Int
    var id: String { "\(day):\(source.rawValue)" }
}
