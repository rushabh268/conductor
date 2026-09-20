import Testing
import Foundation
@testable import Conductor

@Test func computeStatsFromCache() {
    let cache = StatsCache(
        totalSessions: 100,
        totalMessages: 5000,
        firstSessionDate: "2026-01-08T19:14:08.389Z",
        dailyActivity: [
            DailyActivity(date: "2026-05-10", messageCount: 200, sessionCount: 3, toolCallCount: 50),
            DailyActivity(date: "2026-05-09", messageCount: 150, sessionCount: 2, toolCallCount: 30),
            DailyActivity(date: "2026-05-08", messageCount: 0, sessionCount: 0, toolCallCount: 0),
            DailyActivity(date: "2026-05-07", messageCount: 80, sessionCount: 1, toolCallCount: 10),
        ],
        dailyModelTokens: nil,
        modelUsage: [
            "claude-opus-4-6": ModelUsage(inputTokens: 5000000, outputTokens: 1000000, cacheReadInputTokens: nil, cacheCreationInputTokens: nil),
            "claude-sonnet-4-6": ModelUsage(inputTokens: 2000000, outputTokens: 500000, cacheReadInputTokens: nil, cacheCreationInputTokens: nil),
        ],
        hourCounts: ["9": 10, "10": 25, "11": 30, "14": 20, "15": 15]
    )

    #expect(cache.totalSessions == 100)
    #expect(cache.totalMessages == 5000)

    let usage = cache.modelUsage!
    let totalTokens = usage.values.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
    #expect(totalTokens == 8_500_000)

    let activeDays = cache.dailyActivity!.filter { $0.messageCount > 0 }.count
    #expect(activeDays == 3)

    let peakHour = cache.hourCounts!.max { $0.value < $1.value }
    #expect(peakHour?.key == "11")
}

@Test func modelUsageTotalTokensIncludesCache() {
    let usage = ModelUsage(
        inputTokens: 100, outputTokens: 50,
        cacheReadInputTokens: 954_654_858, cacheCreationInputTokens: 121_029_484
    )
    #expect(usage.totalTokens == 100 + 50 + 954_654_858 + 121_029_484)
}

@Test func modelUsageTotalTokensHandlesNilCacheFields() {
    let usage = ModelUsage(inputTokens: 100, outputTokens: 50, cacheReadInputTokens: nil, cacheCreationInputTokens: nil)
    #expect(usage.totalTokens == 150)
}

@Test func modelNameMapping() {
    #expect(friendlyModelName("claude-opus-4-6") == "Opus 4.6")
    #expect(friendlyModelName("claude-opus-4-5-20251101") == "Opus 4.5")
    #expect(friendlyModelName("claude-sonnet-4-6") == "Sonnet 4.6")
    #expect(friendlyModelName("claude-haiku-4-5-20251001") == "Haiku 4.5")
    #expect(friendlyModelName("claude-opus-4-6") == "Opus 4.6")
    #expect(friendlyModelName("claude-sonnet-4-6") == "Sonnet 4.6")
}

@Test func timeRangeFilterAll() {
    let activities = [
        DailyActivity(date: "2026-01-01", messageCount: 10, sessionCount: 1, toolCallCount: 0),
        DailyActivity(date: "2026-05-10", messageCount: 20, sessionCount: 2, toolCallCount: 5),
    ]

    let filtered = StatsTimeRange.all.filter(activities)
    #expect(filtered.count == 2)
}

@Test func timeRangeFilter7Days() {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"

    let today = formatter.string(from: Date())
    let oldDate = formatter.string(from: Calendar.current.date(byAdding: .day, value: -30, to: Date())!)

    let activities = [
        DailyActivity(date: oldDate, messageCount: 10, sessionCount: 1, toolCallCount: 0),
        DailyActivity(date: today, messageCount: 20, sessionCount: 2, toolCallCount: 5),
    ]

    let filtered = StatsTimeRange.sevenDays.filter(activities)
    #expect(filtered.count == 1)
    #expect(filtered.first?.date == today)
}

@Test func timeRangeFilter30Days() {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"

    let today = formatter.string(from: Date())
    let twoWeeksAgo = formatter.string(from: Calendar.current.date(byAdding: .day, value: -14, to: Date())!)
    let threeMonthsAgo = formatter.string(from: Calendar.current.date(byAdding: .day, value: -90, to: Date())!)

    let activities = [
        DailyActivity(date: threeMonthsAgo, messageCount: 10, sessionCount: 1, toolCallCount: 0),
        DailyActivity(date: twoWeeksAgo, messageCount: 15, sessionCount: 1, toolCallCount: 3),
        DailyActivity(date: today, messageCount: 20, sessionCount: 2, toolCallCount: 5),
    ]

    let filtered = StatsTimeRange.thirtyDays.filter(activities)
    #expect(filtered.count == 2)
}

@Test func timeRangeFilterModelTokens() {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"

    let today = formatter.string(from: Date())
    let oldDate = formatter.string(from: Calendar.current.date(byAdding: .day, value: -60, to: Date())!)

    let tokens = [
        DailyModelTokens(date: oldDate, tokensByModel: ["claude-opus-4-6": 1000]),
        DailyModelTokens(date: today, tokensByModel: ["claude-opus-4-6": 5000]),
    ]

    let filtered7d = StatsTimeRange.sevenDays.filterModelTokens(tokens)
    #expect(filtered7d.count == 1)
    #expect(filtered7d.first?.tokensByModel["claude-opus-4-6"] == 5000)

    let filteredAll = StatsTimeRange.all.filterModelTokens(tokens)
    #expect(filteredAll.count == 2)
}

@Test func streakCalculation() {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"

    let today = Calendar.current.startOfDay(for: Date())

    // Build 5 consecutive days ending today
    var activities: [DailyActivity] = []
    for i in 0..<5 {
        let date = Calendar.current.date(byAdding: .day, value: -i, to: today)!
        activities.append(DailyActivity(
            date: formatter.string(from: date),
            messageCount: 10 + i,
            sessionCount: 1,
            toolCallCount: 0
        ))
    }
    // Add a gap then 2 more days
    for i in 7..<9 {
        let date = Calendar.current.date(byAdding: .day, value: -i, to: today)!
        activities.append(DailyActivity(
            date: formatter.string(from: date),
            messageCount: 5,
            sessionCount: 1,
            toolCallCount: 0
        ))
    }

    let activeDateSet = Set(
        activities
            .filter { $0.messageCount > 0 }
            .compactMap { formatter.date(from: $0.date) }
            .map { Calendar.current.startOfDay(for: $0) }
    )

    // Current streak: 5 consecutive days ending today
    var currentStreak = 0
    var checkDate = today
    while activeDateSet.contains(checkDate) {
        currentStreak += 1
        guard let prev = Calendar.current.date(byAdding: .day, value: -1, to: checkDate) else { break }
        checkDate = prev
    }
    #expect(currentStreak == 5)

    // Longest streak should also be 5 (the gap breaks it)
    let sortedDates = activeDateSet.sorted()
    var longestStreak = 0
    var currentRun = 0
    var previousDate: Date?
    for d in sortedDates {
        if let prev = previousDate,
           let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: prev),
           Calendar.current.isDate(d, inSameDayAs: nextDay) {
            currentRun += 1
        } else {
            currentRun = 1
        }
        longestStreak = max(longestStreak, currentRun)
        previousDate = d
    }
    #expect(longestStreak == 5)
}

@Test func peakHourFormatting() {
    let hourCounts: [String: Int] = ["0": 5, "9": 20, "11": 50, "14": 30, "23": 10]
    let peak = hourCounts.max { $0.value < $1.value }!
    let hour = Int(peak.key)!
    let h = hour % 12 == 0 ? 12 : hour % 12
    let ampm = hour < 12 ? "AM" : "PM"
    #expect("\(h) \(ampm)" == "11 AM")
}

@Test func statsCacheDecoding() throws {
    let json = """
    {
        "totalSessions": 493,
        "totalMessages": 126493,
        "firstSessionDate": "2026-01-08T19:14:08.389Z",
        "dailyActivity": [
            {"date": "2026-05-10", "messageCount": 200, "sessionCount": 3, "toolCallCount": 50}
        ],
        "dailyModelTokens": [
            {"date": "2026-05-10", "tokensByModel": {"claude-opus-4-6": 363111}}
        ],
        "modelUsage": {
            "claude-opus-4-6": {"inputTokens": 8852029, "outputTokens": 1855849}
        },
        "hourCounts": {"9": 20, "11": 50}
    }
    """.data(using: .utf8)!

    let cache = try JSONDecoder().decode(StatsCache.self, from: json)
    #expect(cache.totalSessions == 493)
    #expect(cache.totalMessages == 126493)
    #expect(cache.dailyActivity?.count == 1)
    #expect(cache.dailyModelTokens?.count == 1)
    #expect(cache.modelUsage?["claude-opus-4-6"]?.inputTokens == 8852029)
    #expect(cache.hourCounts?["11"] == 50)
}
