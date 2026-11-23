import Nuke
import Observation
import SwiftUI

@MainActor @Observable
final class LibraryMemoriesStore {
    private(set) var memories: [TimelineMemorySummary] = []
    private var previewCovers: [LibraryMemoryCover] = []
    private(set) var coversFinished = false
    private var usesIndexedCovers = false
    private(set) var coverPagingFailed = false
    @ObservationIgnored private var coverPage = 1
    @ObservationIgnored private var coverPageTask: Task<Bool, Never>?
    @ObservationIgnored private var seenCoverMemories: Set<String> = []
    private let coverPageSize = 12
    private(set) var error: String?
    private(set) var finished = false
    private var loading = false
    private var page = 1
    private var pageSize = 24

    var isConfirmedEmpty: Bool {
        coversFinished && previewCovers.isEmpty && memories.isEmpty
    }

    var covers: [LibraryMemoryCover] {
        let loaded = usesIndexedCovers ? [] : Self.coverChoices(memories)
        var seen = Set<String>()
        return (loaded + previewCovers).filter { seen.insert($0.id).inserted }.sorted {
            $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date
        }
    }

    func adoptIndexedCovers(_ entries: [TimelineMemorySummary], from source: ImmichTimelineRepository) async {
        guard coverPageTask == nil else { return }
        previewCovers = Self.coverChoices(entries)
        usesIndexedCovers = true
        coversFinished = true
        coverPagingFailed = false
        guard page > 1, !loading else { return }
        let readPage = page
        let loadedCount = (readPage - 1) * pageSize
        guard let latest = try? await source.libraryMemories(page: 1, size: loadedCount),
              !Task.isCancelled, !loading, page == readPage else { return }
        memories = latest.filter { !$0.assets.isEmpty }.sorted(by: Self.isNewer)
        finished = latest.count < loadedCount
        error = nil
    }

    func loadCovers(from source: ImmichTimelineRepository) async {
        guard coverPage == 1, !coversFinished else { return }
        _ = await loadCoverPage(from: source)
    }

    func loadRemainingCovers(from source: ImmichTimelineRepository) async {
        coverPagingFailed = false
        while !Task.isCancelled, !coversFinished {
            if await loadCoverPage(from: source) {
                continue
            }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            if await loadCoverPage(from: source) {
                continue
            }
            coverPagingFailed = !Task.isCancelled
            return
        }
    }

    private func loadCoverPage(from source: ImmichTimelineRepository) async -> Bool {
        if let coverPageTask {
            return await coverPageTask.value
        }
        let task = Task(priority: .utility) {
            defer { coverPageTask = nil }
            guard let values = try? await source.libraryMemories(page: coverPage, size: coverPageSize, includeTimelineAssets: false),
                  !Task.isCancelled else { return false }
            let unique = values.filter { seenCoverMemories.insert($0.id).inserted }
            previewCovers.append(contentsOf: Self.coverChoices(unique))
            coversFinished = values.count < coverPageSize || unique.isEmpty
            if coverPage == 1, values.isEmpty, memories.isEmpty {
                finished = true
            }
            coverPage += 1
            return true
        }
        coverPageTask = task
        return await task.value
    }

    private static func coverChoices(_ memories: [TimelineMemorySummary]) -> [LibraryMemoryCover] {
        memories.compactMap { memory in
            memory.assets.first.map { LibraryMemoryCover(id: memory.id, date: memory.memoryAt, asset: .init(id: $0.id, revision: $0.revision)) }
        }
    }

    private static func isNewer(_ lhs: TimelineMemorySummary, _ rhs: TimelineMemorySummary) -> Bool {
        let first = lhs.availableOn ?? lhs.memoryAt
        let second = rhs.availableOn ?? rhs.memoryAt
        if first != second {
            return first > second
        }
        return lhs.memoryAt == rhs.memoryAt ? lhs.id < rhs.id : lhs.memoryAt > rhs.memoryAt
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
            memories.sort(by: Self.isNewer)
            finished = values.count < size || unique.isEmpty
            page += 1
            error = nil
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            self.error = error.localizedDescription
        }
    }
}

nonisolated struct LibraryMemoryCover: Identifiable, Equatable {
    let id: String
    let date: Date
    let asset: LibraryCoverAsset
}

struct LibraryMemoriesCard: View {
    let source: ImmichTimelineRepository
    let media: MediaLibraryController
    let assetDetails: any AssetDetailReading
    let context: LibraryCollectionNavigation
    let catalog: LibraryMemoriesStore
    let rotationEnabled: Bool
    @State private var displayedCover: (cover: LibraryMemoryCover, image: UIImage)?

    var body: some View {
        LibraryHubLink {
            LibraryMemoriesView(source: source, catalog: catalog, media: media, assetDetails: assetDetails, context: context)
        } label: {
            let covers = catalog.covers
            let count: Int? = if catalog.coversFinished {
                covers.count
            } else if catalog.finished {
                catalog.memories.count
            } else {
                nil
            }
            LibraryCollectionCard(title: "Memories", count: count,
                                  symbol: "sparkles.rectangle.stack", appearance: covers.isEmpty ? .glass : .photographic)
            {
                LibraryMemoryCoverRotation(catalog: catalog, source: source, media: media,
                                           enabled: rotationEnabled, current: $displayedCover)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct LibraryMemoryCoverRotation: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    let catalog: LibraryMemoriesStore
    let source: ImmichTimelineRepository
    let media: MediaLibraryController
    let enabled: Bool
    @Binding var current: (cover: LibraryMemoryCover, image: UIImage)?
    @State private var visible = false
    @State private var incoming: (cover: LibraryMemoryCover, image: UIImage)?
    @State private var showsIncoming = false

    var body: some View {
        let active = enabled && visible && scenePhase == .active && !reduceMotion
        let shouldRotate = active && (catalog.coversFinished || catalog.coverPagingFailed)
        GeometryReader { geometry in
            ZStack {
                if let current {
                    artwork(current, size: geometry.size)
                } else if let fallback = catalog.covers.first {
                    LibraryAssetCover(assetID: fallback.asset.id, revision: fallback.asset.revision, media: media)
                        .overlay(alignment: .topTrailing) { dateLabel(fallback.date) }
                }
                if let incoming {
                    artwork(incoming, size: geometry.size).opacity(showsIncoming ? 1 : 0)
                }
            }
        }
        .background { LibraryHubCardVisibility(visible: $visible) }
        .task(id: active) {
            if active {
                await catalog.loadRemainingCovers(from: source)
            }
        }
        .task(id: RotationRequest(active: shouldRotate, scale: displayScale, pipeline: media.pipeline.map(ObjectIdentifier.init))) {
            incoming = nil
            showsIncoming = false
            if shouldRotate {
                await rotate()
            }
        }
        .accessibilityHidden(true)
    }

    private struct RotationRequest: Equatable {
        let active: Bool
        let scale: CGFloat
        let pipeline: ObjectIdentifier?
    }

    private func artwork(_ slide: (cover: LibraryMemoryCover, image: UIImage), size: CGSize) -> some View {
        Image(uiImage: slide.image).resizable().scaledToFill()
            .frame(width: size.width, height: size.height)
            .clipped()
            .overlay(alignment: .topTrailing) { dateLabel(slide.cover.date) }
    }

    private func dateLabel(_ date: Date) -> some View {
        Text(date.formatted(date: .abbreviated, time: .omitted))
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .foregroundStyle(.white)
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
    }

    private func load(_ cover: LibraryMemoryCover) async -> UIImage? {
        guard let pipeline = media.pipeline,
              let request = media.imageRequest(for: LibraryCollectionCardMetrics.coverDescriptor(cover.asset, scale: displayScale)) else { return nil }
        return try? await pipeline.imageTask(with: request).response.image
    }

    private func rotate() async {
        let covers = catalog.covers
        guard covers.count > 1, let first = covers.first else { return }
        var next = 1
        if let current, let index = covers.firstIndex(of: current.cover) {
            next = (index + 1) % covers.count
        } else {
            current = nil
            if let image = await load(first), !Task.isCancelled {
                current = (first, image)
            }
        }
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(TimelineCoverAnimation.initialHold)) } catch { return }
            let candidate = covers[next]
            next = (next + 1) % covers.count
            let image = if let current, current.cover.asset == candidate.asset {
                current.image
            } else {
                await load(candidate)
            }
            guard let image, !Task.isCancelled else { continue }
            incoming = (candidate, image)
            withAnimation(.linear(duration: TimelineCoverAnimation.fadeDuration)) { showsIncoming = true }
            do { try await Task.sleep(for: .seconds(TimelineCoverAnimation.fadeDuration)) } catch { return }
            current = (candidate, image)
            incoming = nil
            showsIncoming = false
        }
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
                           tabDestination: .library, isCollectionPageActive: true,
                           viewerPresentations: context.viewerPresentations, loadTimeline: {},
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
        .libraryPageHeader("Memories")
    }
}
