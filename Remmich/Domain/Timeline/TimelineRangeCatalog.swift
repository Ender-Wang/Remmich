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

    static func adjacentMonth(
        to bucketID: TimelineBucketID,
        offset: Int,
        in summaries: [TimelineBucketSummary]
    ) -> TimelineBucketID? {
        guard let date = bucketID.displayDate else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let adjacent = calendar.date(byAdding: .month, value: offset, to: date) else { return nil }
        let target = calendar.dateComponents([.year, .month], from: adjacent)
        return summaries.first { summary in
            guard let date = summary.id.displayDate else { return false }
            let components = calendar.dateComponents([.year, .month], from: date)
            return components.year == target.year && components.month == target.month
        }?.id
    }

    /// Each ISO week belongs to the month containing its Sunday. The prior month's
    /// days are merged so a boundary week has one card and a complete asset count.
    /// If there is no next month bucket, keep the final partial week here.
    static func libraryWeeks(
        endingIn bucketID: TimelineBucketID,
        current: TimelineSection,
        previous: TimelineSection?,
        hasNextMonth: Bool
    ) -> [TimelineWeekGroup] {
        guard let monthDate = bucketID.displayDate else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let month = calendar.dateComponents([.year, .month], from: monthDate)
        let days = (previous?.dayGroups ?? []) + current.dayGroups
        let grouped = Dictionary(grouping: days.compactMap { day -> (TimelineWeekID, TimelineDayGroup)? in
            guard let week = TimelineWeekID(day: day.id) else { return nil }
            return (week, day)
        }, by: \.0)
        return grouped.keys.sorted { $0.startDate < $1.startDate }.compactMap { week in
            guard let end = calendar.date(byAdding: .day, value: 6, to: week.startDate) else { return nil }
            let endingMonth = calendar.dateComponents([.year, .month], from: end)
            let startsInMonth = calendar.dateComponents([.year, .month], from: week.startDate) == month
            guard endingMonth == month || (!hasNextMonth && startsInMonth) else { return nil }
            return TimelineWeekGroup(
                id: week,
                days: grouped[week, default: []].map(\.1).sorted { $0.id.id < $1.id.id }
            )
        }
    }

    static func days(in section: TimelineSection, week: TimelineWeekID) -> [TimelineDayGroup] {
        weeks(in: section).first { $0.id == week }?.days ?? []
    }
}
