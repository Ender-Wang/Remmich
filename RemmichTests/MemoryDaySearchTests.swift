import Foundation
import Testing
@testable import Remmich

struct MemoryDaySearchTests {
    @Test func todayWinsWithoutRequestingFutureDays() async throws {
        let today = Self.date("2026-11-04T12:00:00Z")
        var requested: [String] = []
        let result = try await MemoryDaySearch.load(relativeTo: today, calendar: Self.calendar()) { day in
            requested.append(MemoryQueryDate.string(for: day, timeZone: Self.utc))
            return [Self.memory("today", date: "2025-11-04T00:00:00Z", year: 2025)]
        }
        #expect(requested == ["2026-11-04"])
        #expect(result.map(\.id) == ["today"])
        #expect(result.first?.upcomingDayLabel(relativeTo: today, calendar: Self.calendar()) == nil)
    }

    @Test func skipsEmptyAndUnusableDaysAndStopsAtFirstMatch() async throws {
        let today = Self.date("2026-11-04T12:00:00Z")
        var requested: [String] = []
        let result = try await MemoryDaySearch.load(relativeTo: today, calendar: Self.calendar()) { day in
            let key = MemoryQueryDate.string(for: day, timeZone: Self.utc)
            requested.append(key)
            switch key {
            case "2026-11-04": return []
            case "2026-11-05":
                return [Self.memory("empty", date: "2025-11-05T00:00:00Z", year: 2025, assets: []),
                        Self.memory("current-year", date: "2026-11-05T00:00:00Z", year: 2026)]
            default: return [Self.memory("upcoming", date: "2025-11-06T00:00:00Z", year: 2025)]
            }
        }
        #expect(requested == ["2026-11-04", "2026-11-05", "2026-11-06"])
        #expect(result.map(\.id) == ["upcoming"])
        #expect(result.first?.availableOn == Self.date("2026-11-06T00:00:00Z"))
        #expect(result.first?.upcomingDayLabel(relativeTo: today, calendar: Self.calendar()) == "In 2 days")
        let published = TimelineMemoryCatalog.nearestUpcoming(result, relativeTo: today, calendar: Self.calendar())
        #expect(published == result)
    }

    @Test func includesDayThreeButNeverRequestsDayFour() async throws {
        let today = Self.date("2026-11-04T12:00:00Z")
        var requested: [String] = []
        let result = try await MemoryDaySearch.load(relativeTo: today, calendar: Self.calendar()) { day in
            let key = MemoryQueryDate.string(for: day, timeZone: Self.utc)
            requested.append(key)
            return key == "2026-11-07" ? [Self.memory("last", date: "2025-11-07T00:00:00Z", year: 2025)] : []
        }
        #expect(requested.count == 4)
        #expect(requested.first == "2026-11-04")
        #expect(requested.last == "2026-11-07")
        #expect(result.map(\.id) == ["last"])
        #expect(TimelineMemoryCatalog.nearestUpcoming(
            [Self.memory("too-far", date: "2025-11-08T00:00:00Z", year: 2025)],
            relativeTo: today, calendar: Self.calendar()
        ).isEmpty)
    }

    @Test func emptyWindowRemainsEmpty() async throws {
        var count = 0
        let result = try await MemoryDaySearch.load(relativeTo: Self.date("2026-11-04T12:00:00Z"), calendar: Self.calendar()) { _ in
            count += 1
            return []
        }
        #expect(count == 4)
        #expect(result.isEmpty)
    }

    @Test func videoSearchSkipsPhotoOnlyToday() async throws {
        var requests = 0
        let result = try await MemoryDaySearch.load(relativeTo: Self.date("2026-11-04T12:00:00Z"), calendar: Self.calendar()) { _ in
            requests += 1
            let memory = requests == 1
                ? Self.memory("photo", date: "2025-11-04T00:00:00Z", year: 2025)
                : TimelineMemorySummary(id: "video", memoryAt: Self.date("2025-11-05T00:00:00Z"), sourceYear: 2025,
                                        assets: [.init(id: "video", revision: .distantPast, mediaKind: .video)])
            return [memory].compactMap { $0.filteringAssets(of: .video) }
        }
        #expect(requests == 2)
        #expect(result.map(\.id) == ["video"])
        #expect(result.first?.assets.first?.mediaKind == .video)
    }

    @Test func crossesYearBoundaryAndLabelsTomorrow() async throws {
        let today = Self.date("2026-12-31T12:00:00Z")
        var requested: [String] = []
        let result = try await MemoryDaySearch.load(relativeTo: today, calendar: Self.calendar()) { day in
            let key = MemoryQueryDate.string(for: day, timeZone: Self.utc)
            requested.append(key)
            return key == "2027-01-01" ? [Self.memory("new-year", date: "2026-01-01T00:00:00Z", year: 2026)] : []
        }
        #expect(requested == ["2026-12-31", "2027-01-01"])
        #expect(result.first?.availableOn == Self.date("2027-01-01T00:00:00Z"))
        #expect(result.first?.upcomingDayLabel(relativeTo: today, calendar: Self.calendar()) == "Tomorrow")
    }

    @Test func calendarDaysRemainSequentialAcrossDaylightSaving() async throws {
        let timezone = try #require(TimeZone(identifier: "Europe/London"))
        let calendar = Self.calendar(timeZone: timezone)
        var requested: [String] = []
        _ = try await MemoryDaySearch.load(relativeTo: Self.date("2026-03-28T12:00:00Z"), calendar: calendar) { day in
            requested.append(MemoryQueryDate.string(for: day, timeZone: timezone))
            return []
        }
        #expect(requested == ["2026-03-28", "2026-03-29", "2026-03-30", "2026-03-31"])
    }

    @Test func requestFailureStopsTheSearch() async {
        var requests = 0
        await #expect(throws: TimelineReadError.staleGeneration) {
            try await MemoryDaySearch.load(relativeTo: Self.date("2026-11-04T12:00:00Z"), calendar: Self.calendar()) { _ in
                requests += 1
                throw TimelineReadError.staleGeneration
            }
        }
        #expect(requests == 1)
    }

    @Test func cancellationDoesNotRequestAnotherDay() async throws {
        let search = Task {
            var requests = 0
            do {
                _ = try await MemoryDaySearch.load(relativeTo: Self.date("2026-11-04T12:00:00Z"), calendar: Self.calendar()) { _ in
                    requests += 1
                    withUnsafeCurrentTask { $0?.cancel() }
                    return []
                }
                Issue.record("Cancelled search returned normally")
            } catch is CancellationError {
                #expect(requests == 1)
            }
        }
        try await search.value
    }

    private static let utc = TimeZone(secondsFromGMT: 0)!

    private static func calendar(timeZone: TimeZone = utc) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private static func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private static func memory(_ id: String, date value: String, year: Int, assets: [String] = ["asset"]) -> TimelineMemorySummary {
        let capturedAt = date(value)
        return .init(id: id, memoryAt: capturedAt, sourceYear: year, assets: assets.map {
            .init(id: $0, revision: capturedAt, mediaKind: .image)
        })
    }
}
