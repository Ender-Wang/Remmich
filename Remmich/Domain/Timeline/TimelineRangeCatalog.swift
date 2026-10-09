import Foundation

nonisolated struct TimelineYearSummary: Identifiable, Sendable {
    let id: Int
    let months: [TimelineBucketSummary]

    var assetCount: Int {
        months.reduce(0) { $0 + $1.assetCount }
    }
}

nonisolated struct TimelineWeekID: Hashable, Identifiable, Sendable {
    let year: Int
    let week: Int
    let startDate: Date

    var id: String {
        String(format: "%04d-W%02d", year, week)
    }

    init?(day: TimelineCaptureDay) {
        guard let date = day.displayDate else { return nil }
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        guard let year = components.yearForWeekOfYear,
              let week = components.weekOfYear,
              let startDate = calendar.dateInterval(of: .weekOfYear, for: date)?.start
        else { return nil }
        self.year = year
        self.week = week
        self.startDate = startDate
    }
}

nonisolated struct TimelineWeekGroup: Identifiable, Sendable {
    let id: TimelineWeekID
    let days: [TimelineDayGroup]

    var assetCount: Int {
        days.reduce(0) { $0 + $1.assets.count }
    }
}

nonisolated enum TimelineRangeCatalog {
    static func years(from summaries: [TimelineBucketSummary]) -> [TimelineYearSummary] {
        let grouped = Dictionary(grouping: summaries.compactMap { summary -> (Int, TimelineBucketSummary)? in
            guard let date = summary.id.displayDate else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            return (calendar.component(.year, from: date), summary)
        }, by: \.0)
        return grouped.keys.sorted().map { year in
            TimelineYearSummary(
                id: year,
                months: months(from: grouped[year, default: []].map(\.1))
            )
        }
    }

    static func months(from summaries: [TimelineBucketSummary]) -> [TimelineBucketSummary] {
        summaries.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    static func weeks(in section: TimelineSection) -> [TimelineWeekGroup] {
        let grouped = Dictionary(grouping: section.dayGroups.compactMap { day -> (TimelineWeekID, TimelineDayGroup)? in
            guard let week = TimelineWeekID(day: day.id) else { return nil }
            return (week, day)
        }, by: \.0)
        return grouped.keys.sorted { $0.startDate < $1.startDate }.map { week in
            TimelineWeekGroup(
                id: week,
                days: grouped[week, default: []].map(\.1).sorted { $0.id.id < $1.id.id }
            )
        }
    }

    static func days(in section: TimelineSection, week: TimelineWeekID) -> [TimelineDayGroup] {
        weeks(in: section).first { $0.id == week }?.days ?? []
    }
}
