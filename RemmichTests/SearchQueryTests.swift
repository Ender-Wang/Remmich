import Foundation
import Testing
@testable import Remmich

struct SearchQueryTests {
    @Test func lastWeekUsesThePreviousLocalCalendarWeek() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        calendar.firstWeekday = 2
        let today = try #require(calendar.date(from: .init(year: 2026, month: 11, day: 4, hour: 13)))
        let start = try #require(calendar.date(from: .init(year: 2026, month: 10, day: 26)))
        let end = try #require(calendar.date(from: .init(year: 2026, month: 11, day: 2)))
        let range = try #require(SearchDate.lastWeek.interval(now: today, calendar: calendar))

        #expect(range.start == start)
        #expect(range.end == end)
        #expect(range.duration == (7 * 24 + 1) * 60 * 60)
    }

    @Test func sevenLocalDatesIncludeBothEndpointsAcrossDaylightSaving() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let date = try #require(calendar.date(from: .init(year: 2026, month: 11, day: 3, hour: 12)))
        let range = try #require(SearchDate.lastSevenDays(now: date, calendar: calendar).interval(now: date, calendar: calendar))
        #expect(calendar.component(.day, from: range.start) == 28)
        #expect(calendar.component(.month, from: range.start) == 10)
        #expect(calendar.component(.day, from: range.end) == 4)
        #expect(calendar.component(.month, from: range.end) == 11)
        #expect(calendar.dateComponents([.day], from: range.start, to: range.end).day == 7)
        #expect(range.duration == (7 * 24 + 1) * 60 * 60)
    }

    @Test func clearingDependentFiltersLeavesIndependentValuesIntact() {
        var filters = SearchFilters()
        filters.options = [.country: "Japan", .state: "Kyoto", .city: "Kyoto", .make: "Apple",
                           .model: "iPhone", .lens: "Wide"]
        filters.favorites = true
        filters.select(nil, for: .city)
        #expect(filters.options[.country] == "Japan")
        #expect(filters.options[.state] == "Kyoto")
        filters.select("Canon", for: .make)
        #expect(filters.options[.make] == "Canon")
        #expect(filters.options[.model] == nil)
        #expect(filters.options[.lens] == nil)
        #expect(filters.favorites)
    }

    @MainActor
    @Test func aSupersededSearchCannotReplaceNewerResults() async throws {
        let source = PausedSearchReader()
        let suite = "SearchQueryTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = try Self.makeStore(source: source, defaults: defaults)
        store.text = "older query"
        store.submit()
        try await source.waitFor("older query")
        store.text = "newer query"
        store.submit()
        try await source.waitFor("newer query")

        await source.complete("newer query", cursor: "newer cursor")
        for _ in 0 ..< 200 where store.nextCursor != "newer cursor" {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.state == .results)
        #expect(store.applied?.text == "newer query")
        await source.complete("older query", cursor: "stale cursor")
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        #expect(store.nextCursor == "newer cursor")
    }

    @MainActor
    @Test func launchPreloadReadsOnlyLocalLandingData() async throws {
        let source = PausedSearchReader()
        let suite = "SearchPreloadTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = try Self.makeStore(source: source, defaults: defaults)

        await store.preloadLanding()

        #expect(await source.localReads == 2)
        #expect(await source.remoteReads == 0)
        #expect(store.state == .landing)
        #expect(store.applied == nil)
    }

    @MainActor
    @Test func anEmptyIndexedDirectoryChecksForPeopleOnTheActiveServer() async throws {
        let person = LibraryPerson(id: "person", name: "Rui", updatedAt: .now)
        let source = PausedSearchReader(indexedPeople: [], remotePeople: [person])
        let suite = "SearchPeopleTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = try Self.makeStore(source: source, defaults: defaults)
        let endpoint = try #require(URL(string: "https://example.com/api"))

        await store.preloadLanding()
        #expect(store.people.isEmpty)
        #expect(await source.remoteReads == 0)

        let read = SearchStore.PeopleRead(endpoint: endpoint, revision: 1)
        let result = try await store.loadPeople(for: read)
        #expect(result.map(\.id) == [person.id])
        #expect(store.people.map(\.id) == [person.id])
        #expect(await source.peopleRefreshes == [true])

        _ = try await store.loadPeople(for: read)
        #expect(await source.peopleRefreshes == [true])
    }

    @MainActor
    private static func makeStore(source: PausedSearchReader, defaults: UserDefaults) throws -> SearchStore {
        let account = try AccountSession(
            apiURL: #require(URL(string: "https://example.com/api")),
            accessToken: "test", userID: "user", userEmail: "", name: "",
            isAdmin: false, serverVersion: .init(major: 3, minor: 2, patch: 0, prerelease: nil)
        )
        return SearchStore(source: source, scope: .init(session: account), defaults: defaults)
    }
}

private actor PausedSearchReader: SearchReading {
    private var requests: [String: CheckedContinuation<SearchResultPage, Never>] = [:]
    private let indexedPeople: [LibraryPerson]?
    private let remotePeople: [LibraryPerson]
    private(set) var localReads = 0
    private(set) var remoteReads = 0
    private(set) var peopleRefreshes: [Bool] = []

    init(indexedPeople: [LibraryPerson]? = nil, remotePeople: [LibraryPerson] = []) {
        self.indexedPeople = indexedPeople
        self.remotePeople = remotePeople
    }

    func searchAssets(_ query: SearchQuery, cursor _: String?) async throws -> SearchResultPage {
        remoteReads += 1
        return await withCheckedContinuation { requests[query.text] = $0 }
    }

    func searchCapabilities() async throws -> SearchCapabilities {
        remoteReads += 1
        return .init(search: true, context: true, ocr: true, people: true)
    }

    func searchOptions(_: SearchOption, filters _: SearchFilters) async throws -> [String] {
        remoteReads += 1
        return []
    }

    func indexedSearchPeople() async throws -> [LibraryPerson]? {
        localReads += 1
        return indexedPeople
    }

    func libraryPeople(refresh: Bool) async throws -> [LibraryPerson] {
        remoteReads += 1
        peopleRefreshes.append(refresh)
        return remotePeople
    }

    func libraryPlaceCovers(offset _: Int, limit _: Int) async throws -> LibraryIndexedPlaces? {
        localReads += 1
        return nil
    }

    func waitFor(_ text: String) async throws {
        for _ in 0 ..< 200 {
            if requests[text] != nil {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw WaitError.missingRequest
    }

    func complete(_ text: String, cursor: String) {
        requests.removeValue(forKey: text)?.resume(returning: .init(assets: [], nextCursor: cursor))
    }

    private enum WaitError: Error { case missingRequest }
}
