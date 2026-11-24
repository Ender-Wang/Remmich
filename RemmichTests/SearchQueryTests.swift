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

        await source.complete("newer query", nextCursor: "newer cursor")
        for _ in 0 ..< 200 where store.nextCursor != "newer cursor" {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.state == .results)
        #expect(store.applied?.text == "newer query")
        await source.complete("older query", nextCursor: "stale cursor")
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        #expect(store.nextCursor == "newer cursor")
    }

    @MainActor
    @Test func expandedSearchWindowAppendsUniqueResultsInRankOrder() async throws {
        let source = PausedSearchReader()
        let suite = "SearchPagingTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = try Self.makeStore(source: source, defaults: defaults)
        let query = "birds"
        let firstPage = (0 ..< 100).map { Self.asset("bird-\($0)", capturedAt: .distantFuture) }
        let nextAsset = Self.asset("extra-bird", capturedAt: .distantPast)
        store.text = query
        store.submit()
        try await source.waitFor(query)
        await source.complete(query, assets: firstPage, nextCursor: "200")
        try await Self.waitUntil { store.state == .results }
        let resultSetID = store.resultSetID
        let initialRevision = store.resultRevision

        store.nextPage()
        #expect(store.isPaging)
        #expect(store.assets.map(\.id) == firstPage.map(\.id))
        try await source.waitFor(query, cursor: "200")
        await source.complete(query, cursor: "200", assets: Array(firstPage.reversed()) + [nextAsset])
        try await Self.waitUntil { !store.isPaging }

        #expect(store.assets.map(\.id) == firstPage.map(\.id) + [nextAsset.id])
        #expect(store.resultSetID == resultSetID)
        #expect(store.resultRevision == initialRevision + 1)
        #expect(store.nextCursor == nil)
        store.nextPage()
        #expect(!store.isPaging)
    }

    @MainActor
    @Test func failedPageKeepsResultsAndCanRetryTheSameCursor() async throws {
        let source = PausedSearchReader()
        let suite = "SearchPageRetryTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = try Self.makeStore(source: source, defaults: defaults)
        let query = "vacation"
        let cursor = "next-page"
        let first = Self.asset("first")
        let second = Self.asset("second")
        store.selectMode(.filename, editing: true)
        store.text = query
        store.submit()
        try await source.waitFor(query)
        await source.complete(query, assets: [first], nextCursor: cursor)
        try await Self.waitUntil { store.state == .results }

        store.nextPage()
        try await source.waitFor(query, cursor: cursor)
        await source.fail(query, cursor: cursor)
        try await Self.waitUntil { store.pageError != nil && !store.isPaging }
        #expect(store.state == .results)
        #expect(store.nextCursor == cursor)
        #expect(store.assets.map(\.id) == [first.id])

        store.nextPage()
        #expect(store.pageError == nil)
        try await source.waitFor(query, cursor: cursor)
        await source.complete(query, cursor: cursor, assets: [second], nextCursor: cursor)
        try await Self.waitUntil { !store.isPaging }
        #expect(store.assets.map(\.id) == [first.id, second.id])
        #expect(store.nextCursor == nil)
    }

    @MainActor
    @Test func offlineSearchHistoryRestoresAndClearsOnlyForItsAccount() async throws {
        let source = PausedSearchReader()
        let suite = "SearchHistoryTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for account in ["first", "second"] {
            let store = try Self.makeStore(source: source, defaults: defaults, userID: account)
            store.selectMode(.filename, editing: true)
            store.text = " \(account) "
            store.submit()
            try await source.waitFor(account)
            await source.complete(account)
            try await Self.waitUntil { store.state == .results }
        }
        let first = try Self.makeStore(source: source, defaults: defaults, userID: "first")
        await first.prepare(endpoint: nil)
        #expect(first.recents == [.init(text: "first", mode: .filename)])
        first.clearHistory()

        let reopened = try Self.makeStore(source: source, defaults: defaults, userID: "first")
        let second = try Self.makeStore(source: source, defaults: defaults, userID: "second")
        await reopened.prepare(endpoint: nil)
        await second.prepare(endpoint: nil)
        #expect(reopened.recents.isEmpty)
        #expect(second.recents == [.init(text: "second", mode: .filename)])
        #expect(await source.remoteReads == 2)
    }

    @MainActor
    @Test(arguments: [true, false])
    func unavailableContextFallsBackToFileNamesWhenSearchIsEnabled(searchEnabled: Bool) async throws {
        let source = PausedSearchReader(capabilities: .init(search: searchEnabled, context: false, ocr: false, people: false))
        let suite = "SearchCapabilityTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = try Self.makeStore(source: source, defaults: defaults)
        let endpoint = try #require(URL(string: "https://example.com/api"))
        await store.prepare(endpoint: endpoint)

        let query = "birds"
        store.text = query
        store.submit()
        if searchEnabled {
            #expect(store.availabilityError == nil)
            #expect(store.mode == .filename)
            let requestedMode = try await source.waitFor(query)
            #expect(requestedMode == .filename)
            await source.complete(query)
            try await Self.waitUntil { store.state == .results }
            #expect(await source.remoteReads == 2)
        } else {
            let message = SearchReadError.disabled.localizedDescription
            #expect(store.availabilityError == message)
            #expect(store.state == .failure(message))
            #expect(await source.remoteReads == 1)
        }
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
    @Test func reopeningAfterFullPlaceLoadKeepsTheCompleteDirectory() async throws {
        let covers = (0 ..< 12).map { Self.asset("place-cover-\($0)") }
        let source = PausedSearchReader(placeCovers: covers)
        let suite = "SearchPlacesTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = try Self.makeStore(source: source, defaults: defaults)

        await store.preloadLanding()
        #expect(store.places.map(\.id) == covers.prefix(8).map(\.id))
        #expect(!store.hasFullPlaceDirectory)

        await store.loadPlaces()
        #expect(store.hasFullPlaceDirectory)
        #expect(store.places.map(\.id) == covers.map(\.id))

        await store.preloadLanding()
        #expect(store.hasFullPlaceDirectory)
        #expect(store.places.map(\.id) == covers.map(\.id))
        #expect(await source.remoteReads == 0)
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
    private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 200 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "Search state did not settle")
    }

    private static func asset(_ id: String, capturedAt: Date = .distantPast) -> TimelineAssetSummary {
        .init(id: id, ownerID: "user", capturedAt: capturedAt, uploadedAt: capturedAt, localOffsetHours: 0,
              mediaKind: .image, durationMilliseconds: nil, aspectRatio: 1, isFavorite: false,
              visibility: .timeline, livePhotoVideoID: nil, stack: nil, projectionType: nil,
              thumbhash: nil, thumbnailRevision: capturedAt)
    }

    @MainActor
    private static func makeStore(source: PausedSearchReader, defaults: UserDefaults, userID: String = "user") throws -> SearchStore {
        let account = try AccountSession(
            apiURL: #require(URL(string: "https://example.com/api")),
            accessToken: "test", userID: userID, userEmail: "", name: "",
            isAdmin: false, serverVersion: .init(major: 3, minor: 2, patch: 0, prerelease: nil)
        )
        return SearchStore(source: source, scope: .init(session: account), defaults: defaults)
    }
}

private actor PausedSearchReader: SearchReading {
    private struct Request: Hashable {
        let text: String
        let cursor: String?
    }

    private var requests: [Request: (mode: SearchMode, continuation: CheckedContinuation<SearchResultPage, any Error>)] = [:]
    private let indexedPeople: [LibraryPerson]?
    private let remotePeople: [LibraryPerson]
    private let capabilities: SearchCapabilities
    private let placeCovers: [TimelineAssetSummary]?
    private(set) var localReads = 0
    private(set) var remoteReads = 0
    private(set) var peopleRefreshes: [Bool] = []

    init(
        indexedPeople: [LibraryPerson]? = nil,
        remotePeople: [LibraryPerson] = [],
        capabilities: SearchCapabilities = .init(search: true, context: true, ocr: true, people: true),
        placeCovers: [TimelineAssetSummary]? = nil
    ) {
        self.indexedPeople = indexedPeople
        self.remotePeople = remotePeople
        self.capabilities = capabilities
        self.placeCovers = placeCovers
    }

    func searchAssets(_ query: SearchQuery, cursor: String?) async throws -> SearchResultPage {
        remoteReads += 1
        let request = Request(text: query.text, cursor: cursor)
        return try await withCheckedThrowingContinuation { requests[request] = (query.mode, $0) }
    }

    func searchCapabilities() async throws -> SearchCapabilities {
        remoteReads += 1
        return capabilities
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

    func libraryPlaceCovers(offset: Int, limit: Int) async throws -> LibraryIndexedPlaces? {
        localReads += 1
        return placeCovers.map { .init(count: $0.count, covers: Array($0.dropFirst(offset).prefix(limit))) }
    }

    @discardableResult
    func waitFor(_ text: String, cursor: String? = nil) async throws -> SearchMode {
        let request = Request(text: text, cursor: cursor)
        for _ in 0 ..< 200 {
            if let pending = requests[request] {
                return pending.mode
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw WaitError.missingRequest
    }

    func complete(_ text: String, cursor: String? = nil, assets: [TimelineAssetSummary] = [], nextCursor: String? = nil) {
        requests.removeValue(forKey: .init(text: text, cursor: cursor))?.continuation
            .resume(returning: .init(assets: assets, nextCursor: nextCursor))
    }

    func fail(_ text: String, cursor: String) {
        requests.removeValue(forKey: .init(text: text, cursor: cursor))?.continuation
            .resume(throwing: URLError(.networkConnectionLost))
    }

    private enum WaitError: Error { case missingRequest }
}
