import Observation
import SwiftUI

nonisolated enum LibraryAssetCollection: String, CaseIterable, Identifiable {
    case recentlyTaken = "Recently taken"
    case recentlyAdded = "Recently added"
    case favorites = "Favorites"
    case archive = "Archive"
    case trash = "Trash"

    var id: Self {
        self
    }

    var showsCardCount: Bool {
        self != .recentlyTaken && self != .recentlyAdded
    }

    var separatesMedia: Bool {
        self == .recentlyTaken || self == .recentlyAdded || self == .favorites
    }

    var symbol: String {
        switch self {
        case .recentlyTaken: "clock"
        case .recentlyAdded: "square.and.arrow.down"
        case .favorites: "heart"
        case .archive: "archivebox"
        case .trash: "trash"
        }
    }

    var query: TimelineQuery {
        var query = TimelineQuery(includesStacks: true, includesPartners: false)
        switch self {
        case .recentlyTaken: break
        case .recentlyAdded:
            query.orderBy = .createdAt
            query.visibility = nil
        case .favorites:
            query.visibility = nil
            query.isFavorite = true
        case .archive:
            query.visibility = .archive
        case .trash:
            query.visibility = nil
            query.includesTrashed = true
        }
        return query
    }
}

nonisolated struct LibraryCollectionPreview: Sendable {
    let count: Int?
    let cover: TimelineAssetSummary?
    let hasMissingMetadata: Bool
}

nonisolated struct LibraryCameraMetadata: Sendable {
    let store: SQLiteLibraryIndexStore
    let scope: MediaAccountScope
    let details: CachedAssetDetailReader

    func matching(_ assets: [TimelineAssetSummary], canFetch: Bool) async throws -> (assets: [TimelineAssetSummary], unknown: [TimelineAssetSummary]) {
        var flags = try await store.libraryCameraMetadata(assetIDs: assets.map(\.id), scope: scope)
        if canFetch, !flags.values.contains(true) {
            // Try a few assets only on a browsed bucket whose cache has no matches.
            // Covers and opening preload always use the cache alone.
            let candidates = Array(assets.lazy.filter { flags[$0.id] == nil }.prefix(4))
            for asset in candidates {
                try Task.checkCancellation()
                if let detail = try? await details.assetDetail(id: asset.id, scope: scope) {
                    flags[asset.id] = AssetDetail.hasCameraMetadata(make: detail.cameraMake, model: detail.cameraModel)
                }
            }
        }
        try Task.checkCancellation()
        return (assets.filter { flags[$0.id] == true }, assets.filter { flags[$0.id] == nil })
    }
}

@MainActor @Observable
final class LibraryCameraCoverage {
    private(set) var incompleteBuckets: Set<TimelineBucketID> = []

    var hasMissingMetadata: Bool {
        !incompleteBuckets.isEmpty
    }

    func record(_ bucket: TimelineBucketID, incomplete: Bool) {
        if incomplete {
            incompleteBuckets.insert(bucket)
        } else {
            incompleteBuckets.remove(bucket)
        }
    }
}

/// Share raw reads between Library consumers of one exact timeline query.
actor LibraryOpeningBuckets: TimelineReading {
    static let monthLimit = 3
    static let lifetime: Duration = .seconds(60)

    private struct Read<Value: Sendable> {
        let task: Task<Value, Error>
        var finishedAt: ContinuousClock.Instant?

        var isFresh: Bool {
            finishedAt.map { ContinuousClock.now - $0 < LibraryOpeningBuckets.lifetime } ?? true
        }
    }

    private let source: any TimelineReading
    private let query: TimelineQuery
    private var summaries: Read<[TimelineBucketSummary]>?
    private var months: [TimelineBucketID: Read<[TimelineAssetSummary]>] = [:]
    private var generation: UInt64?

    init(source: any TimelineReading, query: TimelineQuery) {
        self.source = source
        self.query = query
    }

    func bucketSummaries(query: TimelineQuery) async throws -> [TimelineBucketSummary] {
        guard query == self.query else { return try await source.bucketSummaries(query: query) }
        let generation = try await prepareRead()
        if let summaries, summaries.isFresh {
            let value = try await summaries.task.value
            try await validate(generation)
            return value
        }
        let task = Task(priority: .utility) { try await source.bucketSummaries(query: query) }
        summaries = .init(task: task)
        do {
            let value = try await task.value
            try await validate(generation)
            if summaries?.task == task {
                summaries?.finishedAt = .now
            }
            return value
        } catch {
            if summaries?.task == task {
                summaries = nil
            }
            throw error
        }
    }

    func assets(in bucket: TimelineBucketID, query: TimelineQuery) async throws -> [TimelineAssetSummary] {
        guard query == self.query else { return try await source.assets(in: bucket, query: query) }
        let generation = try await prepareRead()
        if let existing = months[bucket], existing.isFresh {
            let value = try await existing.task.value
            try await validate(generation)
            return value
        }
        let task = Task(priority: .utility) { try await source.assets(in: bucket, query: query) }
        months[bucket] = .init(task: task)
        do {
            let value = try await task.value
            try await validate(generation)
            if months[bucket]?.task == task {
                months[bucket]?.finishedAt = .now
                let completed = months.compactMap { id, read in read.finishedAt.map { (id, $0) } }
                    .sorted { $0.1 > $1.1 }
                for (id, _) in completed.dropFirst(Self.monthLimit) {
                    months[id] = nil
                }
            }
            return value
        } catch {
            if months[bucket]?.task == task {
                months[bucket] = nil
            }
            throw error
        }
    }

    func memories() -> [TimelineMemorySummary] {
        []
    }

    func invalidateCompletedReads() {
        if summaries?.finishedAt != nil {
            summaries = nil
        }
        months = months.filter { $0.value.finishedAt == nil }
    }

    private func prepareRead() async throws -> UInt64? {
        guard let repository = source as? ImmichTimelineRepository else { return nil }
        let current = try await repository.timelineReadGeneration()
        if let generation, current < generation {
            throw TimelineReadError.staleGeneration
        }
        if generation != current {
            generation = current
            summaries?.task.cancel()
            summaries = nil
            for read in months.values {
                read.task.cancel()
            }
            months.removeAll()
        }
        return current
    }

    private func validate(_ generation: UInt64?) async throws {
        if let generation, let repository = source as? ImmichTimelineRepository,
           try await repository.timelineReadGeneration() != generation
        {
            throw TimelineReadError.staleGeneration
        }
    }
}

@MainActor
final class LibraryCollectionOpening {
    let photos: PhotosTimelineStore
    let videos: PhotosTimelineStore?
    let photoRuntime = TimelineSemanticRuntime()
    let videoRuntime = TimelineSemanticRuntime()
    let photoCameraCoverage: LibraryCameraCoverage?
    let videoCameraCoverage: LibraryCameraCoverage?
    private let coverReader: LibraryScopedTimelineReader
    let sharedReads: LibraryOpeningBuckets
    private var coverTask: Task<LibraryCollectionPreview, Error>?

    init(collection: LibraryAssetCollection, opening: LibraryOpeningBuckets, camera: LibraryCameraMetadata? = nil) {
        let query = collection.query
        let camera = collection == .recentlyTaken ? camera : nil
        photoCameraCoverage = camera.map { _ in LibraryCameraCoverage() }
        videoCameraCoverage = camera.map { _ in LibraryCameraCoverage() }
        sharedReads = opening
        coverReader = LibraryScopedTimelineReader(source: opening, query: query, media: nil, camera: camera)
        photos = Self.store(opening: opening, query: query, lane: collection.separatesMedia ? .photos : nil,
                            camera: camera, coverage: photoCameraCoverage)
        videos = collection.separatesMedia
            ? Self.store(opening: opening, query: query, lane: .videos, camera: camera, coverage: videoCameraCoverage) : nil
    }

    func preview(for collection: LibraryAssetCollection) async throws -> LibraryCollectionPreview {
        if let coverTask {
            return try await coverTask.value
        }
        let task = Task(priority: .utility) { try await coverReader.preview(for: collection) }
        coverTask = task
        defer { coverTask = nil }
        return try await task.value
    }

    private static func store(opening: LibraryOpeningBuckets, query: TimelineQuery,
                              lane: SavedPhotosMedia?, camera: LibraryCameraMetadata?, coverage: LibraryCameraCoverage?) -> PhotosTimelineStore
    {
        let reader = LibraryScopedTimelineReader(source: opening, query: query, media: lane, camera: camera, coverage: coverage)
        return PhotosTimelineStore(reader: reader, openingSource: .init(label: "Library") { try await reader.openingWindow(limit: $0) },
                                   hasUnfilteredBucketCounts: lane != nil,
                                   semanticHistoryBucketLimit: camera == nil ? nil : LibraryOpeningBuckets.monthLimit)
    }
}

actor LibrarySelectionTimelineReader: TimelineReading {
    private let loadAssets: @Sendable () async throws -> [TimelineAssetSummary]
    private var assetsByBucket: [TimelineBucketID: [TimelineAssetSummary]] = [:]

    init(assets: [TimelineAssetSummary]) {
        loadAssets = { assets }
    }

    init(loadAssets: @escaping @Sendable () async throws -> [TimelineAssetSummary]) {
        self.loadAssets = loadAssets
    }

    func bucketSummaries(query _: TimelineQuery) async throws -> [TimelineBucketSummary] {
        let assets = try await loadAssets()
        try Task.checkCancellation()
        var seen = Set<String>()
        let unique = assets.filter { seen.insert($0.id).inserted }
        let groups = Dictionary(grouping: unique) {
            let day = TimelineCaptureDay(capturedAt: $0.captureLocalDate)
            return TimelineBucketID(rawValue: day.id.prefix(7) + "-01")
        }
        assetsByBucket = groups.mapValues { $0.sorted { $1.isCaptured(before: $0) } }
        return groups.map { .init(id: $0.key, assetCount: $0.value.count) }
            .sorted { $0.id.rawValue > $1.id.rawValue }
    }

    func assets(in bucketID: TimelineBucketID, query _: TimelineQuery) async throws -> [TimelineAssetSummary] {
        assetsByBucket[bucketID] ?? []
    }

    func memories() async throws -> [TimelineMemorySummary] {
        []
    }
}

actor LibraryScopedTimelineReader: TimelineReading {
    let source: any TimelineReading
    let query: TimelineQuery
    let media: SavedPhotosMedia?
    let place: TimelinePlace?
    let newestBucket: TimelineBucketID?
    private let camera: LibraryCameraMetadata?
    private let coverage: LibraryCameraCoverage?

    init(source: any TimelineReading, query: TimelineQuery, media: SavedPhotosMedia?,
         place: TimelinePlace? = nil, newestBucket: TimelineBucketID? = nil,
         camera: LibraryCameraMetadata? = nil, coverage: LibraryCameraCoverage? = nil)
    {
        self.source = source
        self.query = query
        self.media = media
        self.place = place
        self.newestBucket = newestBucket
        self.camera = camera
        self.coverage = coverage
    }

    func bucketSummaries(query _: TimelineQuery) async throws -> [TimelineBucketSummary] {
        let buckets = try await source.bucketSummaries(query: query)
        guard let newestBucket else { return buckets }
        return buckets.filter { $0.id.rawValue <= newestBucket.rawValue }
    }

    func assets(in bucketID: TimelineBucketID, query _: TimelineQuery) async throws -> [TimelineAssetSummary] {
        let result = try await matchingAssets(in: bucketID, canFetch: true)
        return result.assets
    }

    func openingWindow(limit: Int) async throws -> TimelineBootstrapSnapshot? {
        let summaries = try await bucketSummaries(query: query)
        var window: [TimelineBucketID: [TimelineAssetSummary]] = [:]
        var seen = Set<String>()
        for summary in summaries.prefix(LibraryOpeningBuckets.monthLimit) {
            try Task.checkCancellation()
            let assets = try await matchingAssets(in: summary.id).assets
            var items: [TimelineAssetSummary] = []
            for asset in assets {
                if seen.insert(asset.id).inserted {
                    items.append(asset)
                }
                if seen.count == limit {
                    break
                }
            }
            if !items.isEmpty {
                window[summary.id] = items
            }
            if seen.count == limit {
                break
            }
        }
        try Task.checkCancellation()
        return TimelineOpeningWindow.snapshot(generation: 0, assetsByBucket: window)
    }

    private func matchingAssets(in bucket: TimelineBucketID, canFetch: Bool = false) async throws
        -> (assets: [TimelineAssetSummary], unknown: [TimelineAssetSummary])
    {
        let values = try await source.assets(in: bucket, query: query)
        let matches: [TimelineAssetSummary] = values.compactMap { value in
            guard value.mediaKind == .image || value.mediaKind == .video,
                  media?.includes(video: value.mediaKind == .video) != false,
                  place == nil || value.place == place else { return nil }
            var asset = value
            if query.orderBy == .createdAt {
                asset.usesUploadDate = true
            }
            return asset
        }
        guard let camera else { return (matches, []) }
        let result = try await camera.matching(matches, canFetch: canFetch)
        await coverage?.record(bucket, incomplete: !result.unknown.isEmpty)
        return result
    }

    func memories() -> [TimelineMemorySummary] {
        []
    }

    func preview(for collection: LibraryAssetCollection) async throws -> LibraryCollectionPreview {
        let summaries = try await bucketSummaries(query: query)
        let count = collection.showsCardCount ? summaries.reduce(0) { $0 + $1.assetCount } : nil
        if collection == .trash {
            return .init(count: count, cover: nil, hasMissingMetadata: false)
        }
        let buckets = camera == nil ? summaries[...] : summaries.prefix(LibraryOpeningBuckets.monthLimit)
        var hasMissingMetadata = false
        for bucket in buckets {
            try Task.checkCancellation()
            let result = try await matchingAssets(in: bucket.id)
            hasMissingMetadata = hasMissingMetadata || !result.unknown.isEmpty
            if let cover = result.assets.first {
                return .init(count: count, cover: cover, hasMissingMetadata: hasMissingMetadata)
            }
        }
        return .init(count: count, cover: nil, hasMissingMetadata: hasMissingMetadata)
    }
}

struct LibraryAssetCollectionCard: View {
    let collection: LibraryAssetCollection
    let media: MediaLibraryController
    let opening: LibraryOpeningState

    private var preview: LibraryCollectionPreview? {
        opening.previews[collection]
    }

    var body: some View {
        LibraryCollectionCard(title: collection.rawValue, count: preview?.count, symbol: collection.symbol,
                              appearance: preview?.cover == nil ? .glass : .photographic)
        {
            if let asset = preview?.cover {
                LibraryAssetCover(assetID: asset.id, revision: asset.thumbnailRevision, media: media)
            }
        }
    }
}

struct LibraryCollectionTimeline: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let media: MediaLibraryController
    let assetDetails: any AssetDetailReading
    let tabSelectionState: NativeTabSelectionState?
    let viewerPresentations: AssetViewerPresentationStore?
    let opening: LibraryCollectionOpening?
    let libraryIndex: LibraryIndexController?
    let shareURL: URL?
    @Binding var tabBarTop: CGFloat
    @State private var selected = SavedPhotosMedia.photos
    @State private var photos: PhotosTimelineStore
    @State private var videos: PhotosTimelineStore?

    init(title: String, source: any TimelineReading, query: TimelineQuery, separatesMedia: Bool = false,
         media: MediaLibraryController, assetDetails: any AssetDetailReading,
         tabSelectionState: NativeTabSelectionState?, viewerPresentations: AssetViewerPresentationStore?, tabBarTop: Binding<CGFloat>,
         opening: LibraryCollectionOpening? = nil, libraryIndex: LibraryIndexController? = nil, shareURL: URL? = nil)
    {
        self.title = title
        self.media = media
        self.assetDetails = assetDetails
        self.tabSelectionState = tabSelectionState
        self.viewerPresentations = viewerPresentations
        self.opening = opening
        self.libraryIndex = libraryIndex
        self.shareURL = shareURL
        _tabBarTop = tabBarTop
        _photos = State(initialValue: opening?.photos ?? PhotosTimelineStore(reader: LibraryScopedTimelineReader(
            source: source, query: query, media: separatesMedia ? .photos : nil
        ), hasUnfilteredBucketCounts: separatesMedia))
        _videos = State(initialValue: opening?.videos ?? (separatesMedia ? PhotosTimelineStore(reader: LibraryScopedTimelineReader(
            source: source, query: query, media: .videos
        ), hasUnfilteredBucketCounts: true) : nil))
    }

    var body: some View {
        LibraryTimelineViewport { clearance in
            if let videos {
                MediaTimelinePageHost(selection: selected.index, reduceMotion: reduceMotion,
                                      photos: AnyView(timeline(photos, name: "Photos", active: selected == .photos, clearance: clearance)),
                                      videos: AnyView(timeline(videos, name: "Videos", active: selected == .videos, clearance: clearance)))
            } else {
                timeline(photos, name: title, active: true, clearance: clearance)
            }
        } header: {
            VStack(spacing: 0) {
                LibraryPageHeader(title: title) {
                    if let shareURL {
                        ShareLink(item: shareURL) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.title3)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .accessibilityLabel("Share Link")
                    }
                }
                if videos != nil {
                    Picker("Media", selection: $selected) {
                        ForEach(SavedPhotosMedia.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    if (selected == .photos ? opening?.photoCameraCoverage : opening?.videoCameraCoverage)?.hasMissingMetadata == true {
                        Text("More items may appear after Asset Cache sync")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 6)
                    }
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task(id: libraryIndex?.thumbnailWarmingLastUpdatedAt) {
            guard libraryIndex?.thumbnailWarmingLastUpdatedAt != nil, media.activeAPIURL != nil else { return }
            let lane = selected == .photos ? photos : videos
            let coverage = selected == .photos ? opening?.photoCameraCoverage : opening?.videoCameraCoverage
            if let lane, let coverage, !lane.isOpeningWindow {
                let ids = lane.bucketSummaries.map(\.id).filter(coverage.incompleteBuckets.contains)
                for id in ids.prefix(LibraryOpeningBuckets.monthLimit) {
                    guard !Task.isCancelled else { return }
                    await lane.retryBucket(id)
                }
            }
        }
    }

    private func timeline(_ store: PhotosTimelineStore, name: String, active: Bool, clearance: EdgeInsets) -> some View {
        let runtime = store === photos ? opening?.photoRuntime : opening?.videoRuntime
        return LibraryTimelineLane(store: store, name: name, active: active, media: media, assetDetails: assetDetails,
                                   tabSelectionState: tabSelectionState, viewerPresentations: viewerPresentations, tabBarTop: $tabBarTop,
                                   clearance: clearance, openingRuntime: runtime, sharedReads: opening?.sharedReads)
    }
}

struct LibraryTimelineLane: View {
    let store: PhotosTimelineStore
    let name: String
    let active: Bool
    let media: MediaLibraryController
    let assetDetails: any AssetDetailReading
    let tabSelectionState: NativeTabSelectionState?
    let viewerPresentations: AssetViewerPresentationStore?
    @Binding var tabBarTop: CGFloat
    let clearance: EdgeInsets
    var openingRuntime: TimelineSemanticRuntime?
    var sharedReads: LibraryOpeningBuckets?
    @State private var path: [PhotosRangeRoute] = []
    @State private var presentation = PhotosPresentationState()

    var body: some View {
        Group {
            if media.activeAPIURL == nil, store.loadState != .loaded {
                ContentUnavailableView("Immich Is Unavailable", systemImage: "wifi.slash")
            } else {
                timeline
            }
        }
        .onChange(of: media.activeAPIURL) { _, endpoint in
            store.routeDidChange(isReachable: endpoint != nil && active && (tabSelectionState?.selection == .library || tabSelectionState == nil))
        }
    }

    private var timeline: some View {
        PhotosView(store: store, presentation: presentation, media: media, assetDetails: assetDetails,
                   navigationPath: $path, tabBarTop: $tabBarTop,
                   timelineRuntime: store.isOpeningWindow ? openingRuntime : nil, contentName: name,
                   rootAccessibilityID: "library-collection-timeline", compactChromeChanged: { _ in },
                   tabSelectionState: tabSelectionState, tabDestination: .library, isCollectionPageActive: active,
                   libraryTimelineClearance: clearance,
                   viewerPresentations: viewerPresentations, refreshSource: {
                       await sharedReads?.invalidateCompletedReads()
                   }, loadTimeline: {
                       if openingRuntime != nil, !store.isOpeningWindow, store.loadState == .loaded || store.loadState == .empty {
                           await store.refresh()
                       } else {
                           await store.load(resumingDeferred: true)
                       }
                       if store.semanticAssetsSnapshot().isEmpty, store.hasUnloadedSemanticBuckets {
                           await store.loadOlderSemanticPage()
                       }
                   })
    }
}
