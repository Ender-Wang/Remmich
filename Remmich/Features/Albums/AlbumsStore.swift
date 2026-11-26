import Foundation
import Observation

@MainActor
@Observable
final class AlbumsStore {
    private(set) var albums: [AlbumSummary] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    private(set) var coverRevisions: [String: Date] = [:]

    var isWaitingForInitialContent: Bool {
        !hasLoaded && errorMessage == nil
    }

    private let reader: any AlbumReading
    private let persistence: (any AlbumCatalogStoring)?
    private let scope: MediaAccountScope?
    private var generation = 0
    @ObservationIgnored private var cachedRead: Task<Void, Never>?
    @ObservationIgnored private var didShowCover = false

    init(reader: any AlbumReading, persistence: (any AlbumCatalogStoring)? = nil, scope: MediaAccountScope? = nil) {
        self.reader = reader
        self.persistence = persistence
        self.scope = scope
    }

    func prepareOpening() async {
        guard !hasLoaded, let persistence, let scope else { return }
        if let cachedRead {
            await cachedRead.value
            return
        }
        let read = Task { [weak self] in
            guard let self else { return }
            defer { cachedRead = nil }
            guard let cached = try? await persistence.cachedAlbumOverview(scope: scope), !hasLoaded else { return }
            coverRevisions = cached.coverRevisions
            albums = cached.albums
            hasLoaded = true
        }
        cachedRead = read
        await read.value
    }

    func warmOpeningCovers(media: MediaLibraryController, viewport: CGSize, scale: CGFloat) async {
        guard !didShowCover, let scope, media.scope == scope, hasLoaded, !albums.isEmpty,
              viewport.width > 0, viewport.height > 0, scale > 0 else { return }
        let metrics = AlbumReflowMetrics.overview(availableWidth: viewport.width)
        let rows = Int(ceil(viewport.height * CGFloat(TimelineGridOrder.openingScreenCount) / (metrics.cardHeight + 20)))
        let count = rows * metrics.columns
        let newest = AlbumSort.mostRecentPhoto.sorted(albums, direction: .ascending).suffix(count).reversed()
        let descriptors = newest.compactMap { album -> MediaRequestDescriptor? in
            guard let id = album.thumbnailAssetID else { return nil }
            return AlbumReflowMetrics.coverDescriptor(assetID: id, revision: coverRevisions[album.id] ?? album.updatedAt,
                                                      width: metrics.coverWidth, scale: scale)
        }
        if let persistence,
           let records = try? await persistence.albumCoverThumbnails(scope: scope, assetIDs: descriptors.map(\.assetID)),
           !records.isEmpty, !Task.isCancelled, media.scope == scope
        {
            let thumbnails = LibraryThumbnailCache.projectIndexedThumbnails(records: records, scope: scope)
            media.registerWarmedThumbnails(thumbnails, replacing: false)
        }
        guard !Task.isCancelled, media.scope == scope else { return }
        await media.prefetchManagedThumbnails(descriptors)
    }

    func openingCoverVisible() {
        didShowCover = true
    }

    func load() async {
        generation &+= 1
        let request = generation
        isLoading = true
        errorMessage = nil
        defer {
            if request == generation {
                isLoading = false
            }
        }
        async let cached: Void = prepareOpening()
        do {
            guard !Task.isCancelled, request == generation else { return }
            let values = try await reader.albums()
            guard !Task.isCancelled, request == generation else { return }
            var seen: Set<String> = []
            let next = values.filter { seen.insert($0.id).inserted }
            if !coverRevisions.isEmpty {
                let previous = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) })
                for album in next where previous[album.id]?.thumbnailAssetID != album.thumbnailAssetID
                    || previous[album.id]?.catalogRevision != album.catalogRevision
                {
                    coverRevisions[album.id] = nil
                }
            }
            albums = next
            hasLoaded = true
            if let persistence, let scope {
                try? await persistence.saveAlbumList(albums, scope: scope)
            }
        } catch {
            await cached
            guard !Task.isCancelled, request == generation, !(error is CancellationError) else { return }
            if hasLoaded, (error as? TimelineReadError) == .routeUnavailable {
                return
            }
            errorMessage = error.localizedDescription
        }
    }
}
