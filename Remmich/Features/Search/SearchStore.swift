import Foundation
import Observation

@MainActor
@Observable
final class SearchStore {
    nonisolated struct Recent: Codable, Hashable, Sendable {
        let text: String
        let mode: SearchMode
    }

    enum State: Equatable {
        case landing, loading, results, failure(String)
    }

    var text = ""
    private(set) var mode: SearchMode = .context
    private(set) var filters = SearchFilters()
    private(set) var applied: SearchQuery?
    private(set) var state = State.landing
    private(set) var resultCatalog = TimelineSemanticCatalog(searchResults: [])
    private(set) var resultRevision: UInt64 = 0
    private(set) var resultSetID: UInt64 = 0
    private(set) var nextCursor: String?
    private(set) var pageError: String?
    private(set) var isPaging = false
    private(set) var capabilities: SearchCapabilities?
    private(set) var availabilityError: String?
    private(set) var recents: [Recent] = []
    private(set) var people: [LibraryPerson] = []
    private(set) var places: [TimelineAssetSummary] = []
    private(set) var hasFullPlaceDirectory = false

    var assets: [TimelineAssetSummary] {
        resultCatalog.assets
    }

    @ObservationIgnored private let source: any SearchReading
    @ObservationIgnored private let historyKey: String
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var owner = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var route: URL?
    @ObservationIgnored private var peopleLoadedFor: PeopleRead?
    @ObservationIgnored private var loadedHistory = false

    struct PeopleRead: Hashable {
        let endpoint: URL?
        let revision: Int
    }

    init(source: any SearchReading, scope: MediaAccountScope, defaults: UserDefaults = .standard) {
        self.source = source
        self.defaults = defaults
        historyKey = "search.recents.\(scope.cacheNamespace)"
    }

    private func loadHistory() {
        if !loadedHistory {
            loadedHistory = true
            if let data = defaults.data(forKey: historyKey) {
                recents = (try? JSONDecoder().decode([Recent].self, from: data)) ?? []
            }
        }
    }

    func preloadLanding() async {
        loadHistory()
        async let places: Void = loadPlaces(limit: 8)
        if peopleLoadedFor == nil, let people = try? await source.indexedSearchPeople(),
           !Task.isCancelled, peopleLoadedFor == nil
        {
            self.people = people
        }
        await places
    }

    func prepare(endpoint: URL?) async {
        loadHistory()
        if route != endpoint {
            route = endpoint
            capabilities = nil
            availabilityError = nil
            if task != nil {
                cancelRequest()
                if state == .loading {
                    state = .failure("The connection changed. Try your search again.")
                }
            }
        }
        guard let endpoint else { return }
        if capabilities == nil {
            do {
                let value = try await source.searchCapabilities()
                guard !Task.isCancelled, route == endpoint else { return }
                capabilities = value
                availabilityError = value.search ? nil : SearchReadError.disabled.errorDescription
                if applied == nil, mode == .context, !value.context {
                    mode = .filename
                }
            } catch {
                guard !Task.isCancelled, route == endpoint else { return }
                if let error = error as? SearchReadError {
                    availabilityError = error.errorDescription
                    return
                }
            }
        }
    }

    func loadPlaces(limit: Int = .max) async {
        guard let indexed = try? await source.libraryPlaceCovers(offset: 0, limit: limit),
              !Task.isCancelled, limit == .max || (!hasFullPlaceDirectory && places.isEmpty) else { return }
        places = indexed.covers
        hasFullPlaceDirectory = limit == .max
    }

    func loadPeople(for read: PeopleRead, refresh: Bool = false) async throws -> [LibraryPerson] {
        if !refresh, peopleLoadedFor == read, !people.isEmpty || read.endpoint == nil {
            return people
        }
        let indexed = try await source.indexedSearchPeople()
        if read.endpoint == nil, !people.isEmpty, indexed?.isEmpty != false {
            return people
        }
        let value: [LibraryPerson] = if let indexed, read.endpoint == nil || (!refresh && !indexed.isEmpty) {
            indexed
        } else {
            try await source.libraryPeople(refresh: read.endpoint != nil)
        }
        try Task.checkCancellation()
        people = value
        peopleLoadedFor = read
        return value
    }

    func options(_ option: SearchOption, filters: SearchFilters) async throws -> [String] {
        try await source.searchOptions(option, filters: filters)
    }

    func selectMode(_ mode: SearchMode, editing: Bool) {
        guard self.mode != mode else { return }
        self.mode = mode
        if !editing {
            submit()
        }
    }

    func selectRecent(_ recent: Recent) {
        mode = recent.mode
        text = recent.text
        submit()
    }

    func clearText() {
        text = ""
        submit(recordHistory: false)
    }

    func apply(_ filters: SearchFilters) {
        self.filters = filters
        submit(recordHistory: false)
    }

    func submit(recordHistory: Bool = true) {
        let query = SearchQuery(mode: mode, text: text.trimmingCharacters(in: .whitespacesAndNewlines), filters: filters,
                                takenInterval: filters.date?.interval())
        if query == applied, state == .loading || state == .results {
            return
        }
        cancelRequest()
        resultSetID &+= 1
        resultCatalog = TimelineSemanticCatalog(searchResults: [])
        nextCursor = nil
        pageError = nil
        guard !query.isEmpty else {
            applied = nil
            state = .landing
            return
        }
        applied = query
        if let capabilities {
            guard capabilities.search else {
                state = .failure(SearchReadError.disabled.localizedDescription)
                return
            }
            if !query.text.isEmpty, !capabilities.supports(query.mode) {
                state = .failure(SearchReadError.unavailableMode(query.mode).localizedDescription)
                return
            }
        }
        text = query.text
        if recordHistory, !query.text.isEmpty {
            remember(.init(text: query.text, mode: query.mode))
        }
        state = .loading
        load(query, cursor: nil)
    }

    func nextPage() {
        guard task == nil, let nextCursor, let applied, state == .results else { return }
        isPaging = true
        pageError = nil
        load(applied, cursor: nextCursor)
    }

    func removeRecent(_ recent: Recent) {
        recents.removeAll { $0 == recent }
        saveHistory()
    }

    func clearHistory() {
        recents.removeAll()
        defaults.removeObject(forKey: historyKey)
    }

    func cancel() {
        cancelRequest()
    }

    private func load(_ query: SearchQuery, cursor: String?) {
        let owner = owner
        task = Task { [weak self, source] in
            do {
                let page = try await source.searchAssets(query, cursor: cursor)
                guard let self, !Task.isCancelled, self.owner == owner else { return }
                resultCatalog = TimelineSemanticCatalog(searchResults: assets + page.assets)
                resultRevision &+= 1
                nextCursor = page.nextCursor == cursor ? nil : page.nextCursor
                state = .results
                finishRequest()
            } catch {
                guard let self, !Task.isCancelled, self.owner == owner else { return }
                if cursor == nil {
                    state = .failure(error.localizedDescription)
                } else {
                    pageError = error.localizedDescription
                }
                finishRequest()
            }
        }
    }

    private func cancelRequest() {
        owner &+= 1
        task?.cancel()
        finishRequest()
    }

    private func finishRequest() {
        task = nil
        isPaging = false
    }

    private func remember(_ recent: Recent) {
        loadHistory()
        recents.removeAll { $0 == recent }
        recents.insert(recent, at: 0)
        recents = Array(recents.prefix(12))
        saveHistory()
    }

    private func saveHistory() {
        if let encoded = try? JSONEncoder().encode(recents) {
            defaults.set(encoded, forKey: historyKey)
        }
    }
}
