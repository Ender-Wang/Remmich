import Foundation

nonisolated enum MemoryDaySearch {
    static func load(
        relativeTo referenceDate: Date,
        calendar: Calendar = .autoupdatingCurrent,
        fetch: (Date) async throws -> [TimelineMemorySummary]
    ) async throws -> [TimelineMemorySummary] {
        for offset in 0 ... TimelineMemoryCatalog.maximumUpcomingDays {
            try Task.checkCancellation()
            guard let day = calendar.date(byAdding: .day, value: offset, to: referenceDate) else { continue }
            let memories = try await fetch(day)
            try Task.checkCancellation()
            let groups = TimelineMemoryCatalog.onThisDay(memories, relativeTo: day, calendar: calendar)
            if !groups.isEmpty {
                return groups
            }
        }
        return []
    }
}
