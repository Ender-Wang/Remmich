import Observation
import SwiftUI

@MainActor @Observable
final class LibraryMemoriesStore {
    private(set) var memories: [TimelineMemorySummary] = []
    private(set) var previewCover: LibraryCoverAsset?
    private(set) var error: String?
    private(set) var finished = false
    private var loading = false
    private var page = 1
    private var pageSize = 24

    var cover: LibraryCoverAsset? {
        memories.first?.assets.first.map { .init(id: $0.id, revision: $0.revision) } ?? previewCover
    }

    func loadCover(from source: ImmichTimelineRepository) async {
        guard cover == nil,
              let values = try? await source.libraryMemories(page: 1, size: 4, includeTimelineAssets: false),
              !Task.isCancelled else { return }
        previewCover = values.lazy.compactMap(\.assets.first).first.map { .init(id: $0.id, revision: $0.revision) }
    }

    func prepareOpening(from source: ImmichTimelineRepository, limit: Int) async {
        guard page == 1, !loading else { return }
        pageSize = limit
        await loadNext(from: source)
    }

    func loadNext(from source: ImmichTimelineRepository) async {
        guard !finished, !loading, !Task.isCancelled else { return }
        loading = true
        defer { loading = false }
        let size = pageSize
        do {
            let values = try await source.libraryMemories(page: page, size: size)
            try Task.checkCancellation()
            var seen = Set(memories.map(\.id))
            let unique = values.filter { seen.insert($0.id).inserted && !$0.assets.isEmpty }
            memories.append(contentsOf: unique)
            memories.sort {
                let first = $0.availableOn ?? $0.memoryAt
                let second = $1.availableOn ?? $1.memoryAt
                if first != second {
                    return first > second
                }
                return $0.memoryAt == $1.memoryAt ? $0.id < $1.id : $0.memoryAt > $1.memoryAt
            }
            finished = values.count < size || unique.isEmpty
            page += 1
            error = nil
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            self.error = error.localizedDescription
        }
    }
}

struct LibraryMemoriesCard: View {
    let source: ImmichTimelineRepository
    let media: MediaLibraryController
    let assetDetails: any AssetDetailReading
    let context: LibraryCollectionNavigation
    let catalog: LibraryMemoriesStore

    var body: some View {
        LibraryHubLink {
            LibraryMemoriesView(source: source, catalog: catalog, media: media, assetDetails: assetDetails, context: context)
        } label: {
            let cover = catalog.cover
            LibraryCollectionCard(title: "Memories", count: catalog.finished ? catalog.memories.count : nil,
                                  symbol: "sparkles.rectangle.stack", appearance: cover == nil ? .glass : .photographic)
            {
                if let cover {
                    LibraryAssetCover(assetID: cover.id, revision: cover.revision, media: media)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct LibraryMemoriesView: View {
    let source: ImmichTimelineRepository
    let catalog: LibraryMemoriesStore
    let media: MediaLibraryController
    let assetDetails: any AssetDetailReading
    let context: LibraryCollectionNavigation
    @State private var path: [PhotosRangeRoute] = []
    @State private var presentation = PhotosPresentationState()
    @State private var timeline: PhotosTimelineStore

    init(source: ImmichTimelineRepository, catalog: LibraryMemoriesStore, media: MediaLibraryController,
         assetDetails: any AssetDetailReading, context: LibraryCollectionNavigation)
    {
        self.source = source
        self.catalog = catalog
        self.media = media
        self.assetDetails = assetDetails
        self.context = context
        _timeline = State(initialValue: PhotosTimelineStore(reader: source))
    }

    var body: some View {
        Group {
            if !catalog.memories.isEmpty {
                PhotosView(store: timeline, presentation: presentation, media: media, assetDetails: assetDetails,
                           navigationPath: $path, tabBarTop: context.tabBarTop, contentName: "Memories",
                           rootAccessibilityID: "library-memories", compactChromeChanged: { _ in },
                           viewerVisibilityChanged: context.viewerVisibilityChanged, tabSelectionState: context.tabSelectionState,
                           tabDestination: .library, viewerPresentations: context.viewerPresentations, loadTimeline: {},
                           libraryMemories: catalog.memories, loadOlderMemories: { await catalog.loadNext(from: source) })
            } else if let error = catalog.error {
                ErrorStateView(title: "Couldn’t Load Memories") {
                    Task { await catalog.loadNext(from: source) }
                }
                .accessibilityHint(error)
            } else if catalog.finished {
                ContentUnavailableView("No Memories", systemImage: "sparkles.rectangle.stack")
            } else {
                ProgressView()
            }
        }
        .task {
            if catalog.memories.isEmpty {
                await catalog.loadNext(from: source)
            }
        }
        .navigationTitle("Memories")
        .libraryNavigationChrome()
    }
}
