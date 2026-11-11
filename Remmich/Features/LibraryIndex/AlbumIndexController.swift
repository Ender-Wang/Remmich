import Foundation
import Observation
import OSLog

/// Album metadata shares the account database and transfer queue, never a media cache.
@MainActor @Observable
final class AlbumIndexController {
    private static let logger = Logger(subsystem: "io.github.ender-wang.Remmich", category: "AlbumIndex")
    private(set) var status: LibraryIndexController.Status = .idle
    private(set) var albumCount = 0
    private(set) var indexedAlbumCount = 0
    private(set) var membershipCount = 0
    private(set) var totalItemCount = 0
    private(set) var processedItemCount = 0
    private(set) var currentAlbum: String?
    private(set) var currentAlbumItemCount: Int?
    private(set) var failures: [String] = []
    private(set) var lastUpdatedAt: Date?
    private(set) var isPaused = false
    private var startedAt: Date?
    private var completedElapsed: TimeInterval?
    private let source: (any AlbumReading & TimelineReading)?
    private let store: any AlbumCatalogStoring
    private let transfers: LibraryTransferQueue?
    private let preferences: UserDefaults
    private var scope: MediaAccountScope?
    private var task: Task<Void, Never>?
    private var generation = 0

    init(source: (any AlbumReading & TimelineReading)?, store: any AlbumCatalogStoring,
         transfers: LibraryTransferQueue?, preferences: UserDefaults)
    {
        self.source = source
        self.store = store
        self.transfers = transfers
        self.preferences = preferences
    }

    var isRunning: Bool {
        task != nil
    }

    var automaticWorkEnabled: Bool {
        source != nil && !isPaused
    }

    var fractionCompleted: Double {
        albumCount > 0 ? Double(indexedAlbumCount) / Double(albumCount) : 0
    }

    var diagnostics: String? {
        failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    func elapsed(at date: Date) -> TimeInterval? {
        startedAt.map { max(0, date.timeIntervalSince($0)) } ?? completedElapsed
    }

    func estimatedRemaining(at date: Date) -> TimeInterval? {
        guard status == .indexing, currentAlbum != nil, processedItemCount > 0, processedItemCount < totalItemCount,
              let elapsed = elapsed(at: date) else { return nil }
        return elapsed * Double(totalItemCount - processedItemCount) / Double(processedItemCount)
    }

    func configure(scope: MediaAccountScope) {
        guard self.scope != scope else { return }
        suspend()
        self.scope = scope
        albumCount = 0
        indexedAlbumCount = 0
        membershipCount = 0
        totalItemCount = 0
        processedItemCount = 0
        completedElapsed = preferences.object(forKey: elapsedKey(scope)) as? Double
        failures = []
        isPaused = preferences.bool(forKey: pauseKey(scope))
        lastUpdatedAt = preferences.object(forKey: successKey(scope)) as? Date
        status = isPaused ? .paused : .idle
    }

    func restore() async {
        guard let scope, task == nil else { return }
        let request = generation
        do {
            guard let albums = try await store.albumList(scope: scope) else { return }
            var indexed = 0
            var memberships = 0
            var groupsPrepared = true
            for album in albums {
                try Task.checkCancellation()
                if let catalog = try await store.albumCatalog(scope: scope, albumID: album.id) {
                    indexed += 1
                    memberships += catalog.assetsByBucket.values.reduce(0) { $0 + $1.count }
                    groupsPrepared = groupsPrepared && catalog.groupedCatalogs != nil
                }
            }
            guard self.scope == scope, generation == request, task == nil else { return }
            albumCount = albums.count
            indexedAlbumCount = indexed
            membershipCount = memberships
            totalItemCount = albums.reduce(0) { $0 + $1.assetCount }
            processedItemCount = memberships
            status = isPaused ? .paused : lastUpdatedAt != nil && indexed == albums.count && groupsPrepared ? .upToDate : .idle
        } catch {
            guard self.scope == scope, generation == request else { return }
            failures = [error.localizedDescription]
        }
    }

    func start(automatic: Bool = true, rebuild: Bool = false) {
        guard let scope, let source, task == nil, !isPaused else { return }
        if automatic, status == .upToDate, let lastUpdatedAt, Date().timeIntervalSince(lastUpdatedAt) < 900 {
            return
        }
        generation &+= 1
        let request = generation
        status = .indexing
        startedAt = .now
        completedElapsed = nil
        failures = []
        Self.logger.info("Album index pass started rebuild=\(rebuild)")
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == request {
                    self.completedElapsed = self.elapsed(at: .now)
                    self.startedAt = nil
                    self.task = nil
                    self.currentAlbum = nil
                    self.currentAlbumItemCount = nil
                }
            }
            do {
                await transfers?.finishAlbumIndexPass(namespace: scope.cacheNamespace)
                let albums = try await source.albums()
                try Task.checkCancellation()
                guard self.scope == scope, generation == request else { return }
                try await store.saveAlbumList(albums, scope: scope)
                albumCount = albums.count
                indexedAlbumCount = 0
                membershipCount = 0
                totalItemCount = albums.reduce(0) { $0 + $1.assetCount }
                processedItemCount = 0
                for album in albums {
                    try Task.checkCancellation()
                    guard self.scope == scope, generation == request else { return }
                    currentAlbum = album.title
                    currentAlbumItemCount = album.assetCount
                    let processedBeforeAlbum = processedItemCount
                    do {
                        let saved = try await store.albumCatalog(scope: scope, albumID: album.id)
                        let catalog: AlbumCatalog
                        if !rebuild, let saved, saved.revision == album.catalogRevision,
                           Date().timeIntervalSince(saved.fetchedAt) < 900
                        {
                            catalog = try await saved.preparingGroups()
                            if saved.groupedCatalogs == nil {
                                try Task.checkCancellation()
                                guard generation == request else { return }
                                try await store.saveAlbumCatalog(catalog, scope: scope, albumID: album.id)
                            }
                        } else {
                            let reader = AlbumTimelineReader(source: source, albumID: album.id, revision: album.catalogRevision) { [weak self] count in
                                guard let self, generation == request, self.scope == scope else { return }
                                processedItemCount = processedBeforeAlbum + count
                            }
                            let summaries = try await reader.bucketSummaries(query: .init())
                            let assets = await reader.completeCatalogAssets()
                            let groups = await reader.preparedGroupedCatalogs()
                            catalog = AlbumCatalog(summaries: summaries, assetsByBucket: assets,
                                                   revision: album.catalogRevision, fetchedAt: .now, groupedCatalogs: groups)
                            try Task.checkCancellation()
                            guard self.scope == scope, generation == request else { return }
                            try await store.saveAlbumCatalog(catalog, scope: scope, albumID: album.id)
                        }
                        try Task.checkCancellation()
                        guard generation == request else { return }
                        let actualCount = catalog.assetsByBucket.values.reduce(0) { $0 + $1.count }
                        indexedAlbumCount += 1
                        membershipCount += actualCount
                        processedItemCount = processedBeforeAlbum + actualCount
                    } catch {
                        try Task.checkCancellation()
                        guard generation == request else { return }
                        failures.append("\(album.title) [\(album.id)]: \(error.localizedDescription)")
                    }
                }
                guard generation == request else { return }
                completedElapsed = elapsed(at: .now)
                startedAt = nil
                if failures.isEmpty {
                    lastUpdatedAt = .now
                    preferences.set(lastUpdatedAt, forKey: successKey(scope))
                    preferences.set(completedElapsed, forKey: elapsedKey(scope))
                    status = .upToDate
                } else {
                    status = .failed("\(failures.count) album(s) could not be indexed.")
                }
                await transfers?.finishAlbumIndexPass(namespace: scope.cacheNamespace)
                Self.logger.info("Album index pass finished albums=\(self.indexedAlbumCount)/\(self.albumCount) memberships=\(self.membershipCount) failures=\(self.failures.count)")
            } catch {
                guard generation == request, !Task.isCancelled else { return }
                failures = [error.localizedDescription]
                status = .failed(error.localizedDescription)
                Self.logger.error("Album index pass failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func pause() {
        guard let scope else { return }
        isPaused = true
        preferences.set(true, forKey: pauseKey(scope))
        suspend()
        status = .paused
        Self.logger.info("Album index paused albums=\(self.indexedAlbumCount)/\(self.albumCount)")
    }

    func resume() {
        guard let scope else { return }
        isPaused = false
        preferences.set(false, forKey: pauseKey(scope))
        start(automatic: false)
    }

    func suspend() {
        completedElapsed = elapsed(at: .now)
        startedAt = nil
        generation &+= 1
        task?.cancel()
        task = nil
        currentAlbum = nil
        currentAlbumItemCount = nil
        if status == .indexing {
            status = isPaused ? .paused : .idle
        }
    }

    func clear() {
        suspend()
        scope = nil
        albumCount = 0
        indexedAlbumCount = 0
        membershipCount = 0
        totalItemCount = 0
        processedItemCount = 0
        completedElapsed = nil
        failures = []
        lastUpdatedAt = nil
        isPaused = false
        status = .idle
    }

    func finish() async -> Bool {
        await task?.value
        return !Task.isCancelled && (source == nil || isPaused || status == .upToDate)
    }

    func removePreferences(namespace: String) {
        preferences.removeObject(forKey: "album-index-paused-\(namespace)")
        preferences.removeObject(forKey: "album-index-success-\(namespace)")
        preferences.removeObject(forKey: "album-index-elapsed-\(namespace)")
    }

    private func pauseKey(_ scope: MediaAccountScope) -> String {
        "album-index-paused-\(scope.cacheNamespace)"
    }

    private func successKey(_ scope: MediaAccountScope) -> String {
        "album-index-success-\(scope.cacheNamespace)"
    }

    private func elapsedKey(_ scope: MediaAccountScope) -> String {
        "album-index-elapsed-\(scope.cacheNamespace)"
    }
}
