import SwiftUI
import Charts

// MARK: - Data Models

struct StatsCache: Codable {
    let totalSessions: Int?
    let totalMessages: Int?
    let firstSessionDate: String?
    let dailyActivity: [DailyActivity]?
    let dailyModelTokens: [DailyModelTokens]?
    let modelUsage: [String: ModelUsage]?
    let hourCounts: [String: Int]?
}

struct DailyActivity: Codable, Identifiable {
    var id: String { date }
    let date: String
    let messageCount: Int
    let sessionCount: Int
    let toolCallCount: Int
}

struct DailyModelTokens: Codable, Identifiable {
    var id: String { date }
    let date: String
    let tokensByModel: [String: Int]
}

struct ModelUsage: Codable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?

    var totalTokens: Int {
        inputTokens + outputTokens + (cacheReadInputTokens ?? 0) + (cacheCreationInputTokens ?? 0)
    }
}

// MARK: - Derived Stats

struct DerivedStats {
    let totalSessions: Int
    let totalMessages: Int
    let totalTokens: Int
    let activeDays: Int
    let currentStreak: Int
    let longestStreak: Int
    let peakHour: String
    let favoriteModel: String
    let funComparison: String
    let firstSessionDate: Date?
}

// MARK: - Model Name Mapping

func friendlyModelName(_ raw: String) -> String {
    let stripped = raw
    switch stripped {
    case "claude-opus-4-6": return "Opus 4.6"
    case "claude-opus-4-5-20251101": return "Opus 4.5"
    case "claude-sonnet-4-6": return "Sonnet 4.6"
    case "claude-haiku-4-5-20251001": return "Haiku 4.5"
    default:
        // Try to extract a readable name
        let parts = stripped.replacingOccurrences(of: "claude-", with: "").split(separator: "-")
        if let first = parts.first {
            return first.prefix(1).uppercased() + first.dropFirst()
        }
        return stripped
    }
}

private func modelColor(_ raw: String) -> Color {
    Color.primary
}

// MARK: - Stat Computation

private func computeStats(from cache: StatsCache) -> DerivedStats {
    let activities = cache.dailyActivity ?? []
    let modelUsage = cache.modelUsage ?? [:]
    let hourCounts = cache.hourCounts ?? [:]

    // Compute from filtered activities (not global totals)
    let totalSessions = activities.reduce(0) { $0 + $1.sessionCount }
    let totalMessages = activities.reduce(0) { $0 + $1.messageCount }

    // Total tokens from model usage (includes cache read/creation tokens)
    let totalTokens = modelUsage.values.reduce(0) { $0 + $1.totalTokens }

    // Active days
    let activeDays = activities.filter { $0.messageCount > 0 }.count

    // Streaks - parse dates and sort
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd"
    dateFormatter.timeZone = TimeZone.current

    let activeDateSet = Set(
        activities
            .filter { $0.messageCount > 0 }
            .compactMap { dateFormatter.date(from: $0.date) }
            .map { Calendar.current.startOfDay(for: $0) }
    )

    let today = Calendar.current.startOfDay(for: Date())

    // Current streak: count backwards from today
    var currentStreak = 0
    var checkDate = today
    while activeDateSet.contains(checkDate) {
        currentStreak += 1
        guard let prev = Calendar.current.date(byAdding: .day, value: -1, to: checkDate) else { break }
        checkDate = prev
    }

    // Longest streak
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

    // Peak hour
    let peakHourEntry = hourCounts.max { $0.value < $1.value }
    let peakHourStr: String
    if let entry = peakHourEntry, let hour = Int(entry.key) {
        let h = hour % 12 == 0 ? 12 : hour % 12
        let ampm = hour < 12 ? "AM" : "PM"
        peakHourStr = "\(h) \(ampm)"
    } else {
        peakHourStr = "--"
    }

    // Favorite model
    let favModel = modelUsage.max { a, b in
        a.value.totalTokens < b.value.totalTokens
    }
    let favoriteModel = favModel.map { friendlyModelName($0.key) } ?? "--"

    // Fun comparison: LOTR ~576K words * 1.3 tokens/word ~= 750K tokens
    let lotrTokens = 750_000
    let multiplier = totalTokens > 0 ? Double(totalTokens) / Double(lotrTokens) : 0
    let funComparison: String
    if multiplier >= 1.0 {
        funComparison = String(format: "You've used ~%.0fx more tokens than Lord of the Rings", multiplier)
    } else {
        funComparison = String(format: "You've used ~%.1f of a Lord of the Rings in tokens", multiplier)
    }

    // First session date
    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let firstDate = cache.firstSessionDate.flatMap { isoFormatter.date(from: $0) }

    return DerivedStats(
        totalSessions: totalSessions,
        totalMessages: totalMessages,
        totalTokens: totalTokens,
        activeDays: activeDays,
        currentStreak: currentStreak,
        longestStreak: longestStreak,
        peakHour: peakHourStr,
        favoriteModel: favoriteModel,
        funComparison: funComparison,
        firstSessionDate: firstDate
    )
}

// MARK: - Time Range Filter

enum StatsTimeRange: String, CaseIterable {
    case all = "All"
    case thirtyDays = "30d"
    case sevenDays = "7d"

    func filter(_ activities: [DailyActivity]) -> [DailyActivity] {
        switch self {
        case .all:
            return activities
        case .thirtyDays:
            let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let cutoffStr = formatter.string(from: cutoff)
            return activities.filter { $0.date >= cutoffStr }
        case .sevenDays:
            let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let cutoffStr = formatter.string(from: cutoff)
            return activities.filter { $0.date >= cutoffStr }
        }
    }

    func filterModelTokens(_ tokens: [DailyModelTokens]) -> [DailyModelTokens] {
        switch self {
        case .all:
            return tokens
        case .thirtyDays:
            let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let cutoffStr = formatter.string(from: cutoff)
            return tokens.filter { $0.date >= cutoffStr }
        case .sevenDays:
            let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let cutoffStr = formatter.string(from: cutoff)
            return tokens.filter { $0.date >= cutoffStr }
        }
    }
}

// MARK: - Main View

struct CoworkStatsView: View {
    enum Tab: String, CaseIterable {
        case overview = "Overview"
        case models = "Models"
    }

    @State private var selectedTab: Tab = .overview
    @State private var timeRange: StatsTimeRange = .all
    @State private var cache: StatsCache?
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("", selection: $selectedTab) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .tint(.primary)
                .frame(width: 160)

                Spacer()

                Picker("", selection: $timeRange) {
                    ForEach(StatsTimeRange.allCases, id: \.self) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .tint(.primary)
                .frame(width: 130)
            }

            if let error = loadError {
                ContentUnavailableView(
                    "Could not load stats",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if let cache {
                let filteredActivities = timeRange.filter(cache.dailyActivity ?? [])
                let filteredCache = StatsCache(
                    totalSessions: cache.totalSessions,
                    totalMessages: cache.totalMessages,
                    firstSessionDate: cache.firstSessionDate,
                    dailyActivity: filteredActivities,
                    dailyModelTokens: timeRange.filterModelTokens(cache.dailyModelTokens ?? []),
                    modelUsage: cache.modelUsage,
                    hourCounts: cache.hourCounts
                )
                let stats = computeStats(from: filteredCache)

                switch selectedTab {
                case .overview:
                    overviewTab(stats: stats, activities: filteredActivities)
                case .models:
                    modelsTab(
                        cache: cache,
                        filteredTokens: timeRange.filterModelTokens(cache.dailyModelTokens ?? [])
                    )
                }
            } else {
                ProgressView("Loading stats...")
                    .frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .padding()
        .task {
            await loadStats()
        }
    }

    // MARK: - Overview Tab

    @ViewBuilder
    private func overviewTab(stats: DerivedStats, activities: [DailyActivity]) -> some View {
        // Stat tiles - 2 rows of 4
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                miniStatTile("Sessions", value: formatNumber(stats.totalSessions), icon: "list.bullet")
                miniStatTile("Messages", value: formatNumber(stats.totalMessages), icon: "message")
                miniStatTile("Total Tokens", value: formatTokens(stats.totalTokens), icon: "number")
                miniStatTile("Active Days", value: "\(stats.activeDays)", icon: "calendar")
            }
            HStack(spacing: 8) {
                miniStatTile("Current Streak", value: "\(stats.currentStreak)d", icon: "flame")
                miniStatTile("Longest Streak", value: "\(stats.longestStreak)d", icon: "trophy")
                miniStatTile("Peak Hour", value: stats.peakHour, icon: "clock")
                miniStatTile("Favorite Model", value: stats.favoriteModel, icon: "star")
            }
        }

        // Activity heatmap
        ActivityHeatmap(activities: activities)

        // Fun comparison
        Text(stats.funComparison)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Models Tab

    @ViewBuilder
    private func modelsTab(cache: StatsCache, filteredTokens: [DailyModelTokens]) -> some View {
        // Token usage stacked bar chart
        ModelTokenChart(dailyTokens: filteredTokens)
            .frame(height: 200)

        // Model breakdown list
        if let usage = cache.modelUsage {
            let totalTokens = usage.values.reduce(0) { $0 + $1.totalTokens }
            let sorted = usage.sorted { a, b in
                a.value.totalTokens > b.value.totalTokens
            }

            VStack(spacing: 6) {
                ForEach(sorted, id: \.key) { key, model in
                    let modelTotal = model.totalTokens
                    let pct = totalTokens > 0 ? Double(modelTotal) / Double(totalTokens) * 100 : 0
                    HStack {
                        Circle()
                            .fill(modelColor(key))
                            .frame(width: 8, height: 8)
                        Text(friendlyModelName(key))
                            .font(.callout.bold())
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            let cacheTotal = (model.cacheReadInputTokens ?? 0) + (model.cacheCreationInputTokens ?? 0)
                            Text(cacheTotal > 0
                                ? "\(formatTokens(model.inputTokens)) in / \(formatTokens(model.outputTokens)) out / \(formatTokens(cacheTotal)) cached"
                                : "\(formatTokens(model.inputTokens)) in / \(formatTokens(model.outputTokens)) out")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.1f%%", pct))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .cardStyle(cornerRadius: 6)
                }
            }
        }
    }

    // MARK: - Helpers

    private func miniStatTile(_ title: String, value: String, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.headline, design: .rounded).bold())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .cardStyle(cornerRadius: 8)
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000)
        } else if n >= 1_000 {
            return String(format: "%.1fk", Double(n) / 1_000)
        }
        return "\(n)"
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000_000 {
            return String(format: "%.1fB", Double(count) / 1_000_000_000)
        } else if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000)
        }
        return "\(count)"
    }

    private func loadStats() async {
        let home = NSHomeDirectory()
        let cacheUrl = URL(fileURLWithPath: home + "/.claude/stats-cache.json")
        let historyUrl = URL(fileURLWithPath: home + "/.claude/history.jsonl")

        do {
            let data = try Data(contentsOf: cacheUrl)
            var decoded = try JSONDecoder().decode(StatsCache.self, from: data)

            // Supplement with history.jsonl for recent daily activity
            if let historyData = try? String(contentsOf: historyUrl, encoding: .utf8) {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"

                var dailyCounts: [String: Int] = [:]
                var hourCounts: [String: Int] = [:]
                let cal = Calendar.current
                for line in historyData.components(separatedBy: "\n") where !line.isEmpty {
                    guard let jsonData = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                          let ts = obj["timestamp"] as? Int64 else { continue }
                    let date = Date(timeIntervalSince1970: Double(ts) / 1000.0)
                    dailyCounts[formatter.string(from: date), default: 0] += 1
                    let hour = cal.component(.hour, from: date)
                    hourCounts["\(hour)", default: 0] += 1
                }

                // Merge: keep existing stats-cache entries, add/update from history
                var existingByDate: [String: DailyActivity] = [:]
                for a in decoded.dailyActivity ?? [] {
                    existingByDate[a.date] = a
                }
                for (date, count) in dailyCounts {
                    if let existing = existingByDate[date] {
                        existingByDate[date] = DailyActivity(
                            date: date,
                            messageCount: max(existing.messageCount, count),
                            sessionCount: max(existing.sessionCount, 1),
                            toolCallCount: existing.toolCallCount
                        )
                    } else {
                        existingByDate[date] = DailyActivity(
                            date: date,
                            messageCount: count,
                            sessionCount: 1,
                            toolCallCount: 0
                        )
                    }
                }

                // Merge hour counts
                var mergedHours = decoded.hourCounts ?? [:]
                for (hour, count) in hourCounts {
                    mergedHours[hour] = max(mergedHours[hour] ?? 0, count)
                }

                decoded = StatsCache(
                    totalSessions: decoded.totalSessions,
                    totalMessages: decoded.totalMessages,
                    firstSessionDate: decoded.firstSessionDate,
                    dailyActivity: existingByDate.values.sorted { $0.date < $1.date },
                    dailyModelTokens: decoded.dailyModelTokens,
                    modelUsage: decoded.modelUsage,
                    hourCounts: mergedHours
                )
            }

            cache = decoded
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - Activity Heatmap

struct ActivityHeatmap: View {
    let activities: [DailyActivity]

    private let dayLabels = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private let cellSize: CGFloat = 10
    private let cellSpacing: CGFloat = 2

    var body: some View {
        let grid = buildGrid()
        let maxCount = activities.map(\.messageCount).max() ?? 1

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Activity")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                InfoButton(text: "Each square represents one day. Darker shading means more messages.")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 0) {
                    // Day labels
                    VStack(spacing: cellSpacing) {
                        ForEach(0..<7, id: \.self) { row in
                            if row % 2 == 1 {
                                Text(dayLabels[row])
                                    .font(.system(size: 8))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 24, height: cellSize)
                            } else {
                                Text("")
                                    .frame(width: 24, height: cellSize)
                            }
                        }
                    }

                    // Grid
                    HStack(spacing: cellSpacing) {
                        ForEach(0..<grid.count, id: \.self) { col in
                            VStack(spacing: cellSpacing) {
                                ForEach(0..<7, id: \.self) { row in
                                    let count = grid[col][row]
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(heatColor(count: count, max: maxCount))
                                        .frame(width: cellSize, height: cellSize)
                                        .help(helpText(col: col, row: row, count: count))
                                }
                            }
                        }
                    }
                }
            }
        }
        .cardStyle(padding: 8, cornerRadius: 8)
    }

    private func heatColor(count: Int, max: Int) -> Color {
        guard count > 0 else {
            return Color.primary.opacity(0.05)
        }
        let intensity = Double(count) / Double(max)
        // Map to 4 intensity levels
        if intensity > 0.75 {
            return Color.primary.opacity(0.7)
        } else if intensity > 0.5 {
            return Color.primary.opacity(0.5)
        } else if intensity > 0.25 {
            return Color.primary.opacity(0.35)
        } else {
            return Color.primary.opacity(0.2)
        }
    }

    private func helpText(col: Int, row: Int, count: Int) -> String {
        count > 0 ? "\(count) messages" : "No activity"
    }

    /// Build a 2D grid: columns = weeks, rows = days (0=Sun..6=Sat)
    private func buildGrid() -> [[Int]] {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        // Build date->count lookup
        var dateCounts: [String: Int] = [:]
        for a in activities {
            dateCounts[a.date] = a.messageCount
        }

        // Determine date range
        let sortedDates = activities.compactMap { dateFormatter.date(from: $0.date) }.sorted()
        guard let firstDate = sortedDates.first else { return [] }
        let lastDate = sortedDates.last ?? Date()

        let cal = Calendar.current

        // Align to start of week (Sunday)
        let firstWeekday = cal.component(.weekday, from: firstDate) // 1=Sun
        let startDate = cal.date(byAdding: .day, value: -(firstWeekday - 1), to: firstDate)!

        // Calculate number of weeks
        let daysBetween = cal.dateComponents([.day], from: startDate, to: lastDate).day ?? 0
        let numWeeks = (daysBetween / 7) + 1

        var grid: [[Int]] = []
        for week in 0..<numWeeks {
            var column: [Int] = []
            for day in 0..<7 {
                let offset = week * 7 + day
                if let date = cal.date(byAdding: .day, value: offset, to: startDate) {
                    let key = dateFormatter.string(from: date)
                    column.append(dateCounts[key] ?? 0)
                } else {
                    column.append(0)
                }
            }
            grid.append(column)
        }

        return grid
    }
}

// MARK: - Model Token Chart

struct ModelTokenChart: View {
    let dailyTokens: [DailyModelTokens]

    var body: some View {
        let entries = buildChartEntries()

        if entries.isEmpty {
            ContentUnavailableView(
                "No token data",
                systemImage: "chart.bar",
                description: Text("No model token data available for this time range")
            )
        } else {
            Chart(entries, id: \.id) { entry in
                BarMark(
                    x: .value("Date", entry.date),
                    y: .value("Tokens", entry.tokens)
                )
                .foregroundStyle(Color.primary.opacity(entry.opacity))
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let intVal = value.as(Int.self) {
                            Text(formatTokens(intVal))
                        }
                    }
                }
            }
        }
    }

    private struct ChartEntry: Identifiable {
        let id = UUID()
        let date: Date
        let model: String
        let tokens: Int
        let opacity: Double
    }

    private func buildChartEntries() -> [ChartEntry] {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        // Rank models by total tokens for opacity assignment
        var modelTotals: [String: Int] = [:]
        for day in dailyTokens {
            for (model, tokens) in day.tokensByModel {
                let name = friendlyModelName(model)
                modelTotals[name, default: 0] += tokens
            }
        }
        let rankedModels = modelTotals.sorted { $0.value > $1.value }.map(\.key)
        let opacities: [Double] = [0.85, 0.6, 0.4, 0.25, 0.15]

        var entries: [ChartEntry] = []
        for day in dailyTokens {
            guard let date = dateFormatter.date(from: day.date) else { continue }
            for (model, tokens) in day.tokensByModel {
                let name = friendlyModelName(model)
                let rank = rankedModels.firstIndex(of: name) ?? 0
                let opacity = opacities[min(rank, opacities.count - 1)]
                entries.append(ChartEntry(
                    date: date,
                    model: name,
                    tokens: tokens,
                    opacity: opacity
                ))
            }
        }
        return entries
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.0fk", Double(count) / 1_000)
        }
        return "\(count)"
    }
}
