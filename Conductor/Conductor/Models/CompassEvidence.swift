import Foundation

struct CompassConnection: Sendable, Equatable {
    let socketPath: String
    let readerKeyPath: String
}

struct CompassHealth: Codable, Sendable, Equatable {
    struct Capabilities: Codable, Sendable, Equatable {
        let readerRole: Bool
        let sessionEvidence: Int
    }
    let ok: Bool
    let capabilities: Capabilities?
}

struct CompassEvidenceSummary: Codable, Sendable, Equatable {
    let events: Int
    let grounding: Int
}

struct CompassEvidenceEvent: Codable, Sendable, Equatable, Identifiable {
    struct Decision: Codable, Sendable, Equatable {
        let action: String
        let ruleIDs: [String]
        let reason: String?
    }
    struct Metadata: Codable, Sendable, Equatable {
        struct Source: Codable, Sendable, Equatable {
            let kind: String
            let ref: String
        }
        let sources: [Source]?
        let matchReason: String?
        let bytes: Int?
        let approxTokens: Int?
    }
    let eventID: String
    let eventType: String
    let timestamp: String
    let decision: Decision?
    let metadata: Metadata?
    var id: String { eventID }
    var displayEventType: String {
        eventType.count == 64 && eventType.allSatisfy { "0123456789abcdef".contains($0) } ? "Other" : eventType
    }
}

struct CompassEvidencePage: Codable, Sendable, Equatable {
    let version: Int
    let state: String
    var snapshotID: String? = nil
    var head: String? = nil
    var eventCount: Int? = nil
    var expiresAt: Double? = nil
    var summary: CompassEvidenceSummary? = nil
    var events: [CompassEvidenceEvent] = []
    var nextCursor: String? = nil
    var groundingState: String? = nil
    var relationship: String? = nil
    // Local explanations are fixed prose, never interpolated native IDs or paths.
    var reason: String? = nil

    init(state: String, reason: String? = nil) {
        version = 1; self.state = state; self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case version, state, snapshotID, head, eventCount, expiresAt, summary, events, nextCursor, groundingState, relationship, reason
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        state = try values.decode(String.self, forKey: .state)
        snapshotID = try values.decodeIfPresent(String.self, forKey: .snapshotID)
        head = try values.decodeIfPresent(String.self, forKey: .head)
        eventCount = try values.decodeIfPresent(Int.self, forKey: .eventCount)
        expiresAt = try values.decodeIfPresent(Double.self, forKey: .expiresAt)
        summary = try values.decodeIfPresent(CompassEvidenceSummary.self, forKey: .summary)
        events = try values.decodeIfPresent([CompassEvidenceEvent].self, forKey: .events) ?? []
        nextCursor = try values.decodeIfPresent(String.self, forKey: .nextCursor)
        groundingState = try values.decodeIfPresent(String.self, forKey: .groundingState)
        relationship = try values.decodeIfPresent(String.self, forKey: .relationship)
        // v1 has no server reason. Ignore unsolicited server prose.
    }
}

struct CompassEvidenceSelector: Encodable, Sendable, Equatable {
    struct Subject: Codable, Sendable, Equatable {
        let kind: String
        let nativeID: String
    }
    let version = 1
    let platform: String
    let rootSessionID: String
    let subject: Subject

    init?(session: Session) {
        guard session.role == .main || session.role == .child else { return nil }
        let selectedID = session.effectiveNativeID
        let rootID: String
        if session.role == .main { rootID = session.rootNativeID ?? selectedID }
        else {
            guard let knownRoot = session.rootNativeID, !knownRoot.isEmpty else { return nil }
            rootID = knownRoot
        }
        guard Self.validID(selectedID), Self.validID(rootID) else { return nil }
        // A main row cannot silently select a different ancestor as its own subject.
        if session.role == .main && rootID != selectedID { return nil }
        platform = session.source.rawValue
        rootSessionID = rootID
        subject = Subject(kind: session.role == .main ? "root" : session.source == .opencode ? "session" : "agent", nativeID: selectedID)
    }
    private static func validID(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 1024
    }
}
