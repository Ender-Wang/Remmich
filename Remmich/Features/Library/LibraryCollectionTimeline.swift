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

    var usesRecentWindow: Bool {
        self == .recentlyTaken || self == .recentlyAdded
    }

    var separatesMedia: Bool {
        usesRecentWindow || self == .favorites
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
    let count: Int
    let cover: TimelineAssetSummary?
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

    init(source: any TimelineReading, query: TimelineQuery, media: SavedPhotosMedia?,
         place: TimelinePlace? = nil, newestBucket: TimelineBucketID? = nil)
    {
        self.source = source
        self.query = query
        self.media = media
        self.place = place
        self.newestBucket = newestBucket
    }

    func bucketSummaries(query _: TimelineQuery) async throws -> [TimelineBucketSummary] {
        let buckets = try await source.bucketSummaries(query: query)
        guard let newestBucket else { return buckets }
        return buckets.filter { $0.id.rawValue <= newestBucket.rawValue }
    }

    func assets(in bucketID: TimelineBucketID, query _: TimelineQuery) async throws -> [TimelineAssetSummary] {
        let values = try await source.assets(in: bucketID, query: query)
        return values.compactMap { value in
            guard value.mediaKind == .image || value.mediaKind == .video,
                  media?.includes(video: value.mediaKind == .video) != false,
                  place == nil || value.place == place else { return nil }
            var asset = value
            if query.orderBy == .createdAt {
                asset.usesUploadDate = true
            }
            return asset
        }
    }

    func memories() -> [TimelineMemorySummary] {
        []
    }

    func preview(for collection: LibraryAssetCollection, now: Date = .now) async throws -> LibraryCollectionPreview {
        let summaries = try await bucketSummaries(query: query)
        if !collection.usesRecentWindow {
            let cover = collection == .trash ? nil : try await newestCover(from: summaries)
            return .init(count: summaries.reduce(0) { $0 + $1.assetCount }, cover: cover)
        }

        let cutoff = now.addingTimeInterval(-7 * 86400)
        // Capture buckets use capture-local month boundaries. Include the
        // preceding day to cover assets whose capture offset crosses midnight.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let firstMonth = calendar.dateInterval(of: .month, for: cutoff.addingTimeInterval(-86400))?.start ?? cutoff
        var matches: [String: TimelineAssetSummary] = [:]
        var newestAvailable: TimelineAssetSummary?
        var olderBuckets: [TimelineBucketSummary] = []
        for bucket in summaries {
            guard (bucket.id.displayDate ?? .distantPast) >= firstMonth else {
                olderBuckets.append(bucket)
                continue
            }
            try Task.checkCancellation()
            let values = try await assets(in: bucket.id, query: query)
            newestAvailable = newestAvailable ?? values.first
            for asset in values {
                let timestamp = collection == .recentlyAdded ? asset.uploadedAt : asset.capturedAt
                if timestamp >= cutoff, timestamp <= now {
                    matches[asset.id] = asset
                }
            }
        }
        let cover = matches.values.max { first, second in
            let lhs = collection == .recentlyAdded ? first.uploadedAt : first.capturedAt
            let rhs = collection == .recentlyAdded ? second.uploadedAt : second.capturedAt
            return lhs == rhs ? first.id < second.id : lhs < rhs
        }
        if let cover = cover ?? newestAvailable {
            return .init(count: matches.count, cover: cover)
        }
        return try await .init(count: matches.count, cover: newestCover(from: olderBuckets))
    }

    private func newestCover(from summaries: [TimelineBucketSummary]) async throws -> TimelineAssetSummary? {
        for bucket in summaries {
            try Task.checkCancellation()
            if let cover = try await assets(in: bucket.id, query: query).first {
                return cover
            }
        }
        return nil
    }
}

struct LibraryAssetCollectionCard: View {
    let collection: LibraryAssetCollection
    let source: any TimelineReading
    let media: MediaLibraryController
    let activeEndpoint: URL?
    let isActive: Bool
    @State private var preview: LibraryCollectionPreview?

    var body: some View {
        LibraryCollectionCard(title: collection.rawValue, detail: detail, symbol: collection.symbol,
                              appearance: preview?.cover == nil ? .glass : .photographic)
        {
            if let asset = preview?.cover {
                LibraryAssetCover(assetID: asset.id, revision: asset.thumbnailRevision, media: media)
            }
        }
        .task(id: isActive ? activeEndpoint : nil) {
            guard isActive, activeEndpoint != nil else { return }
            let reader = LibraryScopedTimelineReader(source: source, query: collection.query, media: nil)
            guard let result = try? await reader.preview(for: collection), !Task.isCancelled else { return }
            preview = result
        }
    }

    private var detail: String {
        guard let preview else { return collection.usesRecentWindow ? "Past 7 days" : "" }
        let count = "\(preview.count.formatted()) \(preview.count == 1 ? "item" : "items")"
        return collection.usesRecentWindow ? "\(count) · past 7 days" : count
    }
}

struct LibraryCollectionTimeline: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let media: MediaLibraryController
    let assetDetails: any AssetDetailReading
    let tabSelectionState: NativeTabSelectionState?
    let viewerPresentations: AssetViewerPresentationStore?
    @Binding var tabBarTop: CGFloat
    @State private var selected = SavedPhotosMedia.photos
    @State private var photos: PhotosTimelineStore
    @State private var videos: PhotosTimelineStore?

    init(title: String, source: any TimelineReading, query: TimelineQuery, separatesMedia: Bool = false,
         media: MediaLibraryController, assetDetails: any AssetDetailReading,
         tabSelectionState: NativeTabSelectionState?, viewerPresentations: AssetViewerPresentationStore?, tabBarTop: Binding<CGFloat>)
    {
        self.title = title
        self.media = media
        self.assetDetails = assetDetails
        self.tabSelectionState = tabSelectionState
        self.viewerPresentations = viewerPresentations
        _tabBarTop = tabBarTop
        _photos = State(initialValue: PhotosTimelineStore(reader: LibraryScopedTimelineReader(
            source: source, query: query, media: separatesMedia ? .photos : nil
        ), hasUnfilteredBucketCounts: separatesMedia))
        _videos = State(initialValue: separatesMedia ? PhotosTimelineStore(reader: LibraryScopedTimelineReader(
            source: source, query: query, media: .videos
        ), hasUnfilteredBucketCounts: true) : nil)
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
            if videos != nil {
                Picker("Media", selection: $selected) {
                    ForEach(SavedPhotosMedia.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .navigationTitle(title)
        .libraryNavigationChrome()
    }

    private func timeline(_ store: PhotosTimelineStore, name: String, active: Bool, clearance: EdgeInsets) -> some View {
        LibraryTimelineLane(store: store, name: name, active: active, media: media, assetDetails: assetDetails,
                            tabSelectionState: tabSelectionState, viewerPresentations: viewerPresentations, tabBarTop: $tabBarTop,
                            clearance: clearance)
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
                   navigationPath: $path, tabBarTop: $tabBarTop, contentName: name,
                   rootAccessibilityID: "library-collection-timeline", compactChromeChanged: { _ in },
                   tabSelectionState: tabSelectionState, tabDestination: .library, isCollectionPageActive: active,
                   libraryTimelineClearance: clearance,
                   viewerPresentations: viewerPresentations, loadTimeline: {
                       await store.load(resumingDeferred: true)
                       if store.semanticAssetsSnapshot().isEmpty, store.hasUnloadedSemanticBuckets {
                           await store.loadOlderSemanticPage()
                       }
                   })
    }
}
