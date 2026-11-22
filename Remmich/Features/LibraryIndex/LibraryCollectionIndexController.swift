import Foundation
import Observation
import OSLog

@MainActor @Observable
final class LibraryCollectionIndexController {
    private nonisolated static let logger = Logger(subsystem: "io.github.ender-wang.Remmich", category: "CollectionIndex")

    private nonisolated struct Pass: Codable, Sendable {
        let rebuild: Bool
        var completed: Set<LibraryIndexCard> = []
    }

    private(set) var status: LibraryIndexController.Status = .idle
    private(set) var isPaused = false
    private(set) var cardCount: Int?
    private(set) var indexedCardCount = 0
    private(set) var currentCard: LibraryIndexCard?
    private(set) var checkedMonths = 0
    private(set) var monthsToCheck: Int?
    private(set) var failures: [LibraryIndexCard] = []
    private(set) var lastSyncedAt: Date?
    private(set) var publicationRevision = 0
    private(set) var featureRevision = 0

    private let source: ImmichTimelineRepository?
    private let store: SQLiteLibraryIndexStore
    private let defaults: UserDefaults
    private var scope: MediaAccountScope?
    @ObservationIgnored private var pass: Pass?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var runID = UUID()
    @ObservationIgnored private var lastAttempt: Date?

    init(source: ImmichTimelineRepository?, store: SQLiteLibraryIndexStore, defaults: UserDefaults) {
        self.source = source
        self.store = store
        self.defaults = defaults
    }

    var isRunning: Bool {
        status == .indexing
    }

    var automaticWorkEnabled: Bool {
        source != nil && !isPaused
    }

    var fractionCompleted: Double {
        guard let cardCount, cardCount > 0 else { return 0 }
        return Double(indexedCardCount) / Double(cardCount)
    }

    func configure(scope: MediaAccountScope) {
        clear()
        self.scope = scope
        isPaused = defaults.bool(forKey: key("pause", scope))
        lastSyncedAt = defaults.object(forKey: key("success", scope)) as? Date
        let lastTotal = defaults.object(forKey: key("count", scope)) as? Int
        if let encoded = defaults.data(forKey: key("pass", scope)) {
            pass = try? JSONDecoder().decode(Pass.self, from: encoded)
        }
        cardCount = lastTotal
        indexedCardCount = pass.map(\.completed.count) ?? lastTotal ?? 0
        if isPaused {
            status = .paused
        } else if pass == nil, lastSyncedAt != nil {
            status = .upToDate
        }
    }

    func start(automatic: Bool = true, rebuild: Bool = false) {
        guard let source, let scope, task == nil, !isPaused else { return }
        if automatic, let recent = lastAttempt ?? (pass == nil ? lastSyncedAt : nil),
           Date().timeIntervalSince(recent) < LibrarySyncPolicy.backgroundRequestInterval
        {
            return
        }
        lastAttempt = .now
        if rebuild || pass == nil {
            pass = Pass(rebuild: rebuild)
            savePass(scope)
            indexedCardCount = 0
        }
        let request = UUID()
        runID = request
        status = .indexing
        failures = []
        currentCard = nil
        monthsToCheck = nil
        cardCount = nil
        task = Task(priority: .utility) { await run(source: source, scope: scope, request: request) }
    }

    func pause() {
        guard let scope, isRunning else { return }
        isPaused = true
        defaults.set(true, forKey: key("pause", scope))
        suspend()
    }

    func resume() {
        guard let scope, isPaused else { return }
        isPaused = false
        defaults.set(false, forKey: key("pause", scope))
        start(automatic: false)
    }

    func suspend() {
        runID = UUID()
        task?.cancel()
        task = nil
        currentCard = nil
        monthsToCheck = nil
        if isRunning {
            status = isPaused ? .paused : .idle
        }
        // A suspended pass is eligible to resume at the next processing grant.
        if pass != nil {
            lastAttempt = nil
        }
    }

    func finish() async -> Bool {
        await task?.value
        return !Task.isCancelled && (source == nil || isPaused || status == .upToDate)
    }

    func clear() {
        suspend()
        scope = nil
        pass = nil
        lastAttempt = nil
        lastSyncedAt = nil
        isPaused = false
        cardCount = nil
        indexedCardCount = 0
        checkedMonths = 0
        publicationRevision = 0
        featureRevision = 0
        failures = []
        status = .idle
    }

    func removePreferences(namespace: String) {
        for setting in ["pause", "success", "count", "pass"] {
            defaults.removeObject(forKey: "collection-index-\(setting)-\(namespace)")
        }
    }

    private func run(source: ImmichTimelineRepository, scope: MediaAccountScope, request: UUID) async {
        defer {
            if runID == request {
                task = nil
                currentCard = nil
                monthsToCheck = nil
            }
        }
        do {
            try await source.requireCollectionAccount(scope)
            let features = try await source.libraryPreferences(refresh: true)
            let cards = LibraryIndexCard.enabled(in: features)
            try check(request)
            try await store.saveCollectionPayload(features, key: "preferences", scope: scope)
            try check(request)
            featureRevision &+= 1
            cardCount = cards.count
            defaults.set(cards.count, forKey: key("count", scope))
            pass?.completed.formIntersection(cards)
            let rebuild = pass?.rebuild == true
            indexedCardCount = pass?.completed.count ?? 0
            for card in cards where card != .places && pass?.completed.contains(card) != true {
                try check(request)
                currentCard = card
                checkedMonths = 0
                monthsToCheck = nil
                do {
                    if let query = card.timelineQuery {
                        try await syncTimeline(card, query: query, source: source, scope: scope, rebuild: rebuild, request: request)
                    } else {
                        try await syncDirectory(card, source: source, scope: scope, request: request)
                    }
                    try check(request)
                    // Both projections read the same accepted owner-only months.
                    if card == .recentlyTaken || card == .places {
                        pass?.completed.formUnion([.recentlyTaken, .places])
                    } else {
                        pass?.completed.insert(card)
                    }
                    indexedCardCount = pass?.completed.count ?? 0
                    savePass(scope)
                } catch {
                    try check(request)
                    if error as? TimelineReadError == .staleGeneration {
                        throw error
                    }
                    failures.append(card)
                    if card == .recentlyTaken {
                        failures.append(.places)
                    }
                    Self.logger.error("Library card sync failed card=\(card.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .private)")
                }
            }
            try check(request)
            publicationRevision &+= 1
            if failures.isEmpty {
                let completedAt = Date.now
                lastSyncedAt = completedAt
                defaults.set(completedAt, forKey: key("success", scope))
                pass = nil
                savePass(scope)
                status = .upToDate
            } else {
                status = .failed("Couldn’t index \(failures.map(\.title).joined(separator: ", ")).")
            }
        } catch {
            guard runID == request, !Task.isCancelled else { return }
            if error as? TimelineReadError == .staleGeneration {
                lastAttempt = nil
                status = .idle
            } else {
                status = .failed(error.localizedDescription)
            }
        }
    }

    private func syncTimeline(_ card: LibraryIndexCard, query: TimelineQuery, source: ImmichTimelineRepository,
                              scope: MediaAccountScope, rebuild: Bool, request: UUID) async throws
    {
        let key = card.timelineKey
        let saved = try await store.collectionTimeline(key, scope: scope)
        let reader = await source.collectionNetworkReader(for: query)
        if saved != nil || rebuild {
            await reader.invalidateCompletedReads()
        }
        let summaries = try await reader.bucketSummaries(query: query).sorted { $0.id.rawValue > $1.id.rawValue }
        try check(request)
        guard Set(summaries.map(\.id)).count == summaries.count else { throw TimelineReadError.invalidResponse }
        let delta = LibraryTimelineCatalog.delta(from: saved, summaries: summaries, rebuild: rebuild)
        monthsToCheck = delta.buckets.count
        var replacing: [TimelineBucketID: [TimelineAssetSummary]] = [:]
        for bucket in delta.buckets {
            let assets = try await reader.assets(in: bucket.id, query: query)
            try check(request)
            guard !assets.isEmpty || bucket.assetCount == 0 else { throw TimelineReadError.invalidResponse }
            replacing[bucket.id] = assets
            checkedMonths += 1
        }
        let removed = Set(saved?.summaries.map(\.id) ?? []).subtracting(summaries.map(\.id))
        try await source.requireCollectionAccount(scope)
        try check(request)
        try await store.saveCollectionTimeline(.init(summaries: summaries, olderCursor: delta.cursor), key: key,
                                               scope: scope, replacing: replacing, removing: removed)
    }

    private func syncDirectory(_ card: LibraryIndexCard, source: ImmichTimelineRepository,
                               scope: MediaAccountScope, request: UUID) async throws
    {
        func accept(_ payload: some Codable & Sendable, prefix: String? = nil, ids: Set<String> = []) async throws {
            try await source.requireCollectionAccount(scope)
            try check(request)
            try await store.saveCollectionPayload(payload, key: card.rawValue, scope: scope, childPrefix: prefix, childIDs: ids)
        }

        switch card {
        case .people:
            let people = try await source.libraryPeople(refresh: true)
            try await accept(people, prefix: "person:", ids: Set(people.map(\.id)))
        case .partners:
            let partners = try await source.libraryPartners(refresh: true)
            try await accept(partners, prefix: "partner:", ids: Set(partners.map(\.id)))
        case .sharedLinks: try await accept(source.librarySharedLinks(refresh: true))
        case .folders:
            let folders = try await source.libraryFolderTree(refresh: true)
            try await accept(folders, prefix: "folder:", ids: folders.assetPaths)
        case .memories:
            let size = 24
            var page = 1
            var seen = Set<String>()
            var memories: [TimelineMemorySummary] = []
            while true {
                let values = try await source.libraryMemories(page: page, size: size, refresh: true)
                try check(request)
                let unique = values.filter { seen.insert($0.id).inserted }
                memories.append(contentsOf: unique)
                if values.count < size {
                    break
                }
                guard !unique.isEmpty else { throw TimelineReadError.invalidResponse }
                page += 1
            }
            try await source.requireCollectionAccount(scope)
            try check(request)
            try await store.saveCollectionMemories(memories, scope: scope)
        default: throw TimelineReadError.invalidResponse
        }
    }

    private func check(_ request: UUID) throws {
        try Task.checkCancellation()
        guard request == runID else { throw CancellationError() }
    }

    private func savePass(_ scope: MediaAccountScope) {
        let value = pass.flatMap { try? JSONEncoder().encode($0) }
        defaults.set(value, forKey: key("pass", scope))
    }

    private func key(_ name: String, _ scope: MediaAccountScope) -> String {
        "collection-index-\(name)-\(scope.cacheNamespace)"
    }
}
