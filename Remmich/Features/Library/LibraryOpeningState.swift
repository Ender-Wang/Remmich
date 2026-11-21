import Nuke
import Observation
import UIKit

nonisolated struct LibraryOpeningViewport: Sendable {
    let size: CGSize
    let listSize: CGSize
    let scale: CGFloat
    let isPhone: Bool
    let isDark: Bool

    @MainActor init(window: UIWindow) {
        size = window.bounds.size
        let insets = window.safeAreaInsets
        listSize = CGSize(width: max(1, size.width - insets.left - insets.right),
                          height: max(1, size.height - insets.top - insets.bottom - 44))
        scale = window.traitCollection.displayScale
        isPhone = window.traitCollection.userInterfaceIdiom == .phone
        isDark = window.traitCollection.userInterfaceStyle == .dark
    }

    var cards: LibraryCardRows {
        LibraryCardRows(width: listSize.width, preferredColumns: nil)
    }

    var cardLimit: Int {
        cards.openingCount(viewportHeight: listSize.height, rowHeight: cards.itemWidth / LibraryCollectionCardMetrics.aspectRatio)
    }
}

@MainActor @Observable
final class LibraryOpeningState {
    private(set) var preferences: LibraryFeaturePreferences?
    private(set) var previews: [LibraryAssetCollection: LibraryCollectionPreview] = [:]
    private(set) var collections: [LibraryAssetCollection: LibraryCollectionOpening] = [:]
    private(set) var downloads: [SavedPhotosMedia: SavedPhotosTimelineState] = [:]
    let memories = LibraryMemoriesStore()
    let people = LibraryDirectoryStore()
    let places = LibraryDirectoryStore()
    let partners = LibraryDirectoryStore()
    let links = LibrarySharedLinksStore()
    let folders = LibraryFoldersStore()

    private var savedHistoryCover: (job: UUID, photo: SavedPhoto, scale: CGFloat, image: UIImage)?
    @ObservationIgnored private var previewDates: [LibraryAssetCollection: Date] = [:]
    @ObservationIgnored private var preferencesLoadedAt: Date?
    @ObservationIgnored private var preferenceTask: Task<LibraryFeaturePreferences?, Never>?
    @ObservationIgnored private var coverImages: (pipeline: ImagePipeline, prefetcher: ImagePrefetcher)?
    @ObservationIgnored private var destinationImages: [ObjectIdentifier: ImagePrefetcher] = [:]

    func collection(_ collection: LibraryAssetCollection, source: ImmichTimelineRepository, camera: LibraryCameraMetadata?) -> LibraryCollectionOpening? {
        configureCollections(source: source, camera: camera)
        return collections[collection]
    }

    private func configureCollections(source: ImmichTimelineRepository, camera: LibraryCameraMetadata?) {
        guard collections.isEmpty else { return }
        let placesQuery = LibraryDirectoryStore.placeQuery
        let placeOpening = places.placeReader(source: source)
        collections = Dictionary(uniqueKeysWithValues: LibraryAssetCollection.allCases.map { collection in
            let query = collection.query
            let opening = query == placesQuery ? placeOpening : LibraryOpeningBuckets(source: source, query: query)
            return (collection, LibraryCollectionOpening(collection: collection, opening: opening, camera: camera))
        })
    }

    func downloadTimelines(library: SavedPhotosLibrary, scope: MediaAccountScope) -> [SavedPhotosMedia: SavedPhotosTimelineState] {
        if downloads.isEmpty {
            downloads = Dictionary(uniqueKeysWithValues: SavedPhotosMedia.allCases.map {
                ($0, SavedPhotosTimelineState(library: library, scope: scope, kind: $0))
            })
        }
        return downloads
    }

    func historyImage(for job: MediaExportJob, photo: SavedPhoto?, scale: CGFloat) -> UIImage? {
        guard let photo, let cover = savedHistoryCover, cover.job == job.id, cover.scale == scale,
              cover.photo.id == photo.id, cover.photo.revision == photo.revision else { return nil }
        return cover.image
    }

    func prepareHistoryCover(_ job: MediaExportJob, savedPhotos: SavedPhotosLibrary, media: MediaLibraryController, scale: CGFloat) async {
        let photo = media.exports.journal.receipts.first { $0.key == job.key }
            .flatMap { savedPhotos.item(photosID: $0.photosID) }
        if let photo, historyImage(for: job, photo: photo, scale: scale) == nil,
           let image = try? await SavedPhotosLibrary.image(photo, pixels: LibraryCollectionCardMetrics.coverPixels(scale: scale)),
           !Task.isCancelled, media.exports.latestCompletedDownload?.id == job.id
        {
            savedHistoryCover = (job.id, photo, scale, image)
        } else if historyImage(for: job, photo: photo, scale: scale) == nil {
            prefetchCovers([.init(id: job.assetID, revision: job.revision)], media: media, scale: scale)
        }
    }

    func prepareCovers(source: ImmichTimelineRepository, media: MediaLibraryController, viewport: LibraryOpeningViewport, camera: LibraryCameraMetadata?) async {
        configureCollections(source: source, camera: camera)
        await loadPreferences(source: source)
        let scale = viewport.scale
        var jobs: [@MainActor @Sendable () async -> Void] = LibraryAssetCollection.allCases.filter { $0 != .trash }.map { collection in
            { await self.prepareCollectionCover(collection, media: media, scale: scale) }
        }
        if preferences?.memoriesEnabled == true {
            jobs.append {
                await self.memories.loadCover(from: source)
                self.prefetchCovers([self.memories.cover].compactMap(\.self), media: media, scale: scale)
            }
        }
        if preferences?.peopleEnabled == true {
            jobs.append { await self.prepareDirectoryCover(.people, store: self.people, source: source, media: media, viewport: viewport) }
        }
        jobs.append { await self.prepareDirectoryCover(.places, store: self.places, source: source, media: media, viewport: viewport) }
        if preferences?.sharedLinksEnabled == true {
            jobs.append {
                await self.links.load(source: source)
                self.prefetchCovers([self.links.cover].compactMap(\.self), media: media, scale: scale)
            }
        }
        jobs.append { await self.prepareDirectoryCover(.partners, store: self.partners, source: source, media: media, viewport: viewport) }
        if preferences?.foldersEnabled == true {
            jobs.append {
                await self.folders.load(source: source)
                await self.folders.loadCovers(source: source)
                self.prefetchCovers(self.folders.covers, media: media, scale: scale)
            }
        }
        await run(jobs)
    }

    func prepareDownloads(library: SavedPhotosLibrary, scope: MediaAccountScope, viewport: LibraryOpeningViewport) async {
        guard library.state == .ready, !Task.isCancelled else { return }
        let downloads = downloadTimelines(library: library, scope: scope)
        for kind in SavedPhotosMedia.allCases {
            guard let state = downloads[kind], !Task.isCancelled else { return }
            await prepareTimeline(state.store, runtime: state.runtime, media: state.media, viewport: viewport,
                                  layout: state.presentation.preferences.assetLayout)
        }
    }

    func prepareHistoryRows(media: MediaLibraryController, viewport: LibraryOpeningViewport) {
        let rows = Int(ceil(viewport.listSize.height / 108)) * TimelineGridOrder.openingScreenCount
        let requests = media.exports.jobs.prefix(rows).compactMap {
            media.imageRequest(for: DownloadsView.thumbnailDescriptor(for: $0, scale: viewport.scale), priority: .low)
        }
        prefetch(requests, media: media, forHub: false)
    }

    func prepareDestinations(source: ImmichTimelineRepository, media: MediaLibraryController, viewport: LibraryOpeningViewport,
                             camera: LibraryCameraMetadata?) async
    {
        configureCollections(source: source, camera: camera)
        await loadPreferences(source: source)
        let scale = viewport.scale
        let limit = viewport.cardLimit
        let layout = PhotosPresentationState().preferences.assetLayout
        var jobs: [@MainActor @Sendable () async -> Void] = LibraryAssetCollection.allCases.map { collection in
            {
                guard let opening = self.collections[collection] else { return }
                await self.prepareTimeline(opening.photos, runtime: opening.photoRuntime, media: media, viewport: viewport, layout: layout)
                if let videos = opening.videos {
                    await self.prepareTimeline(videos, runtime: opening.videoRuntime, media: media, viewport: viewport, layout: layout)
                }
                await self.prepareCollectionCover(collection, media: media, scale: scale)
            }
        }
        if preferences?.memoriesEnabled == true {
            jobs.append {
                await self.memories.prepareOpening(from: source, limit: limit)
                let width = viewport.cards.itemWidth
                let requests = self.memories.memories.prefix(limit).compactMap { memory in
                    memory.assets.first.flatMap {
                        media.imageRequest(for: TimelineMemoryCardPresentation.coverDescriptor(
                            for: $0, width: width, height: width / LibraryCollectionCardMetrics.aspectRatio, scale: scale
                        ), priority: .low)
                    }
                }
                self.prefetch(requests, media: media, forHub: false)
            }
        }
        if preferences?.peopleEnabled == true {
            jobs.append { await self.prepareDirectory(.people, store: self.people, source: source, media: media, viewport: viewport) }
        }
        jobs.append { await self.prepareDirectory(.places, store: self.places, source: source, media: media, viewport: viewport) }
        if preferences?.sharedLinksEnabled == true {
            jobs.append {
                await self.links.load(source: source)
                let covers = self.links.links?.prefix(limit).compactMap(\.cover) ?? []
                self.prefetchDestinationCovers(covers, media: media, scale: scale)
            }
        }
        jobs.append { await self.prepareDirectory(.partners, store: self.partners, source: source, media: media, viewport: viewport) }
        if preferences?.foldersEnabled == true {
            jobs.append {
                await self.folders.load(source: source)
                guard let tree = self.folders.tree else { return }
                let paths = tree.children(of: nil).prefix(limit).map(\.path).filter { tree.assetPaths.contains($0) }
                await self.folders.loadCovers(source: source, paths: paths)
                self.prefetchDestinationCovers(paths.compactMap { self.folders.coversByPath[$0] }, media: media, scale: scale)
            }
        }
        await run(jobs)
    }

    func stopDestinationImages() {
        for prefetcher in destinationImages.values {
            prefetcher.stopPrefetching()
        }
        destinationImages.removeAll()
    }

    func refreshIncompleteTakenCover(media: MediaLibraryController, scale: CGFloat) async {
        guard previews[.recentlyTaken]?.hasMissingMetadata == true else { return }
        previewDates[.recentlyTaken] = nil
        await prepareCollectionCover(.recentlyTaken, media: media, scale: scale)
    }

    private func loadPreferences(source: ImmichTimelineRepository) async {
        if let preferenceTask {
            _ = await preferenceTask.value; return
        }
        if let preferencesLoadedAt, Date.now.timeIntervalSince(preferencesLoadedAt) < 5 {
            return
        }
        let task = Task {
            let result = try? await source.libraryPreferences()
            if let result, !Task.isCancelled {
                preferences = result
                preferencesLoadedAt = .now
            }
            preferenceTask = nil
            return result
        }
        preferenceTask = task
        _ = await task.value
    }

    private func prepareCollectionCover(_ collection: LibraryAssetCollection, media: MediaLibraryController, scale: CGFloat) async {
        guard !Task.isCancelled, let opening = collections[collection] else { return }
        if let date = previewDates[collection], Date.now.timeIntervalSince(date) < 5 {
            return
        }
        guard let preview = try? await opening.preview(for: collection),
              !Task.isCancelled else { return }
        previewDates[collection] = .now
        previews[collection] = preview
        if let cover = preview.cover {
            prefetchCovers([.init(cover)], media: media, scale: scale)
        }
    }

    private func prepareDirectoryCover(_ directory: LibraryDirectory, store: LibraryDirectoryStore, source: ImmichTimelineRepository,
                                       media: MediaLibraryController, viewport: LibraryOpeningViewport) async
    {
        await store.loadNext(directory, source: source, openingLimit: directory == .places ? 1 : 4)
        prefetch(store.imageRequests(directory: directory, media: media, scale: viewport.scale,
                                     cardWidth: viewport.cards.itemWidth, limit: directory == .places ? 1 : 4, forHub: true),
                 media: media, forHub: true)
    }

    private func prepareDirectory(_ directory: LibraryDirectory, store: LibraryDirectoryStore, source: ImmichTimelineRepository,
                                  media: MediaLibraryController, viewport: LibraryOpeningViewport) async
    {
        let isPlace = directory == .places
        let columns = isPlace ? nil : max(4, Int(viewport.listSize.width / 98))
        let cards = LibraryCardRows(width: viewport.listSize.width, preferredColumns: columns)
        let rowHeight = isPlace ? cards.itemWidth / LibraryCollectionCardMetrics.aspectRatio : cards.itemWidth + 34
        let limit = cards.openingCount(viewportHeight: viewport.listSize.height, rowHeight: rowHeight)
        await store.loadNext(directory, source: source, openingLimit: limit)
        prefetch(store.imageRequests(directory: directory, media: media, scale: viewport.scale, cardWidth: cards.itemWidth,
                                     limit: limit, forHub: false), media: media, forHub: false)
    }

    private func prepareTimeline(_ store: PhotosTimelineStore, runtime: TimelineSemanticRuntime, media: MediaLibraryController,
                                 viewport: LibraryOpeningViewport, layout: PhotosAssetLayout) async
    {
        guard !Task.isCancelled else { return }
        await store.preloadOpening()
        guard store.isOpeningWindow, !Task.isCancelled else { return }
        let revision = store.semanticContentRevision
        let assets = store.newestSemanticAssets(limit: TimelineGridOrder.openingWindowLimit())
        let scale: TimelineSemanticScale = layout == .square ? .square : .natural
        let build = Task.detached(priority: .utility) {
            let catalog = TimelineSemanticCatalog(assets: assets)
            let projection = TimelineSemanticProjection.complete(catalog: catalog, scale: scale, size: viewport.size,
                                                                 isPhone: viewport.isPhone, dark: viewport.isDark)
            let descriptors = projection.items.reversed().filter { !$0.isHeader }.map {
                TimelineAssetThumbnail.thumbnailDescriptor(for: catalog.assets[$0.nodeIndex],
                                                           points: max($0.frame.width, $0.frame.height), scale: viewport.scale)
            }
            return (catalog, descriptors)
        }
        let (catalog, descriptors) = await withTaskCancellationHandler { await build.value } onCancel: { build.cancel() }
        guard !Task.isCancelled, store.isOpeningWindow, store.semanticContentRevision == revision else { return }
        runtime.preparedOpeningCatalog = catalog
        prefetch(descriptors.compactMap { media.imageRequest(for: $0, priority: .low) }, media: media, forHub: false)
    }

    private func prefetchCovers(_ covers: [LibraryCoverAsset], media: MediaLibraryController, scale: CGFloat) {
        prefetch(coverRequests(covers, media: media, scale: scale), media: media, forHub: true)
    }

    private func prefetchDestinationCovers(_ covers: [LibraryCoverAsset], media: MediaLibraryController, scale: CGFloat) {
        prefetch(coverRequests(covers, media: media, scale: scale), media: media, forHub: false)
    }

    private func coverRequests(_ covers: [LibraryCoverAsset], media: MediaLibraryController, scale: CGFloat) -> [ImageRequest] {
        covers.compactMap { media.imageRequest(for: LibraryCollectionCardMetrics.coverDescriptor($0, scale: scale), priority: .low) }
    }

    private func prefetch(_ requests: [ImageRequest], media: MediaLibraryController, forHub: Bool) {
        guard !Task.isCancelled, !requests.isEmpty, let pipeline = media.pipeline else { return }
        if forHub {
            if coverImages?.pipeline !== pipeline {
                coverImages = (pipeline, ImagePrefetcher(pipeline: pipeline, maxConcurrentRequestCount: 2))
            }
            coverImages?.prefetcher.startPrefetching(with: requests)
        } else {
            let id = ObjectIdentifier(pipeline)
            let prefetcher = destinationImages[id] ?? ImagePrefetcher(pipeline: pipeline, maxConcurrentRequestCount: 2)
            destinationImages[id] = prefetcher
            prefetcher.startPrefetching(with: requests)
        }
    }

    private func run(_ jobs: [@MainActor @Sendable () async -> Void]) async {
        await withTaskGroup(of: Void.self) { group in
            for (index, job) in jobs.enumerated() {
                if index >= 2 {
                    _ = await group.next()
                }
                guard !Task.isCancelled else { break }
                group.addTask(priority: .utility) { await job() }
            }
        }
    }
}
