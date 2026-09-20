import Testing
@testable import Conductor

@Test func parseTicketFromBranchName() {
    #expect(TicketParser.extractTicketId("feature/APP-1234-rate-limiting") == "APP-1234")
    #expect(TicketParser.extractTicketId("feature/DEMO-123-example") == "DEMO-123")
    #expect(TicketParser.extractTicketId("fix/COND-567-filter-bug") == "COND-567")
    #expect(TicketParser.extractTicketId("main") == nil)
    #expect(TicketParser.extractTicketId("feature/example-cleanup") == nil)
}

@Test func parseTicketFromPRTitle() {
    #expect(TicketParser.extractTicketId("APP-1234: Add rate limiting") == "APP-1234")
    #expect(TicketParser.extractTicketId("[DEMO-123] Fix example pagination") == "DEMO-123")
    #expect(TicketParser.extractTicketId("random PR with no ticket") == nil)
}

@Test func classifySessionType() {
    #expect(TicketParser.classifySession(name: "pr-review-1", firstMessage: nil) == .review)
    #expect(TicketParser.classifySession(name: "review-example-pr", firstMessage: nil) == .review)
    #expect(TicketParser.classifySession(name: "feature-work", firstMessage: nil) == .coding)
    #expect(TicketParser.classifySession(name: nil, firstMessage: "Review the code changes against the base branch") == .review)
    #expect(TicketParser.classifySession(name: "example", firstMessage: nil) == .coding)
}
