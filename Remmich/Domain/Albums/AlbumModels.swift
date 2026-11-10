import Foundation
import OSLog

nonisolated struct AlbumSummary: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let description: String
    let thumbnailAssetID: String?
    let assetCount: Int
    let updatedAt: Date
    let createdAt: Date
    let startDate: Date?
    let endDate: Date?
    let isShared: Bool
    var lastModifiedAssetTimestamp: Date? = nil
    let ownerName: String?
    let ownerID: String?

    var title: String {
        name.isEmpty ? "Untitled Album" : name
    }

    var countLabel: String {
        assetCount == 1 ? "1 item" : "\(assetCount.formatted()) items"
    }

    var catalogRevision: String {
        let dates: [Date?] = [updatedAt, lastModifiedAssetTimestamp, startDate, endDate]
        return dates
            .map { $0.map { String($0.timeIntervalSince1970) } ?? "none" }
            .joined(separator: "|") + "|\(assetCount)"
    }
}

nonisolated struct AlbumCatalog: Codable, Sendable {
    let summaries: [TimelineBucketSummary]
    let assetsByBucket: [TimelineBucketID: [TimelineAssetSummary]]
    let revision: String
    let fetchedAt: Date
    var groupedCatalogs: TimelineGroupedCatalogCache? = nil

    func preparingGroups() async throws -> Self {
        guard groupedCatalogs == nil else { return self }
        let summaries = summaries
        let assets = assetsByBucket
        let build = Task.detached(priority: .utility) {
            var base = TimelineGroupedCatalogCache()
            base.replaceSummaryCatalogs(with: summaries)
            return try TimelineCompleteGroupedCatalogBuilder.build(summaries: summaries, assetsByBucket: assets, baseCatalogs: base)
        }
        let groups = try await withTaskCancellationHandler { try await build.value } onCancel: { build.cancel() }
        try Task.checkCancellation()
        var prepared = self
        prepared.groupedCatalogs = groups
        return prepared
    }
}

nonisolated protocol AlbumCatalogStoring: Sendable {
    func albumCatalog(scope: MediaAccountScope, albumID: String) async throws -> AlbumCatalog?
    func saveAlbumCatalog(_ catalog: AlbumCatalog, scope: MediaAccountScope, albumID: String) async throws
    func albumList(scope: MediaAccountScope) async throws -> [AlbumSummary]?
    func saveAlbumList(_ albums: [AlbumSummary], scope: MediaAccountScope) async throws
    func albumCoverRevision(scope: MediaAccountScope, albumID: String, assetID: String) async throws -> Date?
}

extension AlbumCatalogStoring {
    nonisolated func albumCoverRevision(scope: MediaAccountScope, albumID: String, assetID: String) async throws -> Date? {
        try await albumCatalog(scope: scope, albumID: albumID)?.assetsByBucket.values
            .lazy.flatMap(\.self).first { $0.id == assetID }?.thumbnailRevision
    }
}

nonisolated enum AlbumSort: String, CaseIterable, Identifiable, Sendable {
    case title = "Title"
    case itemCount = "Number of items"
    case dateModified = "Date modified"
    case dateCreated = "Date created"
    case mostRecentPhoto = "Most recent photo"
    case oldestPhoto = "Oldest photo"

    var id: Self {
        self
    }

    func sorted(_ albums: [AlbumSummary]) -> [AlbumSummary] {
        albums.sorted { lhs, rhs in
            switch self {
            case .itemCount where lhs.assetCount != rhs.assetCount: return lhs.assetCount > rhs.assetCount
            case .dateModified, .dateCreated, .mostRecentPhoto, .oldestPhoto:
                switch (date(in: lhs), date(in: rhs)) {
                case let (left?, right?) where left != right:
                    return left < right
                case (_?, nil): return false
                case (nil, _?): return true
                default: break
                }
            default: break
            }
            let comparison = lhs.title.localizedStandardCompare(rhs.title)
            return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
        }
    }

    private func date(in album: AlbumSummary) -> Date? {
        switch self {
        case .dateModified: album.updatedAt
        case .dateCreated: album.createdAt
        case .mostRecentPhoto: album.endDate
        case .oldestPhoto: album.startDate
        case .title, .itemCount: nil
        }
    }
}

/// Publishes one complete album metadata catalog through the existing timeline contract.
actor AlbumTimelineReader: CompleteTimelineCatalogReading {
    private static let logger = Logger(subsystem: "io.github.ender-wang.Remmich", category: "AlbumCatalog")
    let source: any TimelineReading
    let albumID: String
    private var assetsByBucket: [TimelineBucketID: [TimelineAssetSummary]] = [:]
    private var generation = 0
    private let persistence: (any AlbumCatalogStoring)?
    private let scope: MediaAccountScope?
    private var expectedRevision: String
    private var catalog: AlbumCatalog?
    private var hasServedCatalog = false

    init(source: any TimelineReading, albumID: String, revision: String = "",
         persistence: (any AlbumCatalogStoring)? = nil, scope: MediaAccountScope? = nil)
    {
        self.source = source
        self.albumID = albumID
        expectedRevision = revision
        self.persistence = persistence
        self.scope = scope
    }

    private func scoped(_ query: TimelineQuery) -> TimelineQuery {
        var scoped = query
        scoped.albumID = albumID
        scoped.includesStacks = true
        scoped.includesPartners = false
        return scoped
    }

    func bucketSummaries(query: TimelineQuery) async throws -> [TimelineBucketSummary] {
        let started = Date()
        generation &+= 1
        let request = generation
        if !hasServedCatalog, let persistence, let scope,
           let saved = try? await persistence.albumCatalog(scope: scope, albumID: albumID)
        {
            let cached = try await saved.preparingGroups()
            try Task.checkCancellation()
            guard request == generation else { throw CancellationError() }
            if saved.groupedCatalogs == nil {
                try await persistence.saveAlbumCatalog(cached, scope: scope, albumID: albumID)
            }
            catalog = cached
            assetsByBucket = cached.assetsByBucket
            hasServedCatalog = true
            Self.logger.info("Album catalog loaded source=local buckets=\(cached.summaries.count) assets=\(cached.assetsByBucket.values.reduce(0) { $0 + $1.count }) elapsedMs=\(Int(Date().timeIntervalSince(started) * 1000))")
            return cached.summaries
        }
        let query = scoped(query)
        let revision = expectedRevision
        let summaries = try await source.bucketSummaries(query: query)
        var complete: [TimelineBucketID: [TimelineAssetSummary]] = [:]
        for summary in summaries {
            try Task.checkCancellation()
            guard request == generation else { throw CancellationError() }
            complete[summary.id] = try await source.assets(in: summary.id, query: query)
        }
        try Task.checkCancellation()
        guard request == generation else { throw CancellationError() }
        assetsByBucket = complete
        let snapshot = try await AlbumCatalog(summaries: summaries, assetsByBucket: complete, revision: revision, fetchedAt: .now)
            .preparingGroups()
        try Task.checkCancellation()
        guard request == generation else { throw CancellationError() }
        catalog = snapshot
        hasServedCatalog = true
        if let persistence, let scope {
            do { try await persistence.saveAlbumCatalog(snapshot, scope: scope, albumID: albumID) }
            catch { Self.logger.error("Album catalog persistence failed: \(error.localizedDescription, privacy: .public)") }
        }
        Self.logger.info("Album catalog loaded source=remote buckets=\(summaries.count) assets=\(complete.values.reduce(0) { $0 + $1.count }) elapsedMs=\(Int(Date().timeIntervalSince(started) * 1000))")
        return summaries
    }

    func needsRefresh(for revision: String, now: Date = .now) -> Bool {
        expectedRevision = revision
        guard let catalog else { return true }
        return catalog.revision != revision || now.timeIntervalSince(catalog.fetchedAt) >= 900
    }

    func assets(in bucketID: TimelineBucketID, query _: TimelineQuery) async throws -> [TimelineAssetSummary] {
        assetsByBucket[bucketID] ?? []
    }

    func completeCatalogAssets() -> [TimelineBucketID: [TimelineAssetSummary]] {
        assetsByBucket
    }

    func preparedGroupedCatalogs() -> TimelineGroupedCatalogCache? {
        catalog?.groupedCatalogs
    }

    func memories() async throws -> [TimelineMemorySummary] {
        []
    }
}
