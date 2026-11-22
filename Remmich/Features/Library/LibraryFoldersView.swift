import Observation
import SwiftUI

nonisolated struct LibraryFolder: Identifiable, Sendable {
    let path: String
    let name: String

    var id: String {
        path
    }
}

nonisolated struct LibraryFolderTree: Sendable {
    let assetPaths: Set<String>
    let coverSamplePaths: [String]
    private let childrenByPath: [String: [LibraryFolder]]

    init(paths: [String]) {
        var children: [String: [LibraryFolder]] = [:]
        var visited: Set<String> = []
        var assetPaths: Set<String> = []
        for path in paths {
            let components = path.split(separator: "/")
            guard !components.isEmpty, !components.contains("."), !components.contains("..") else { continue }
            var parent = ""
            var current = path.hasPrefix("/") ? "/" : ""
            for name in components {
                current += (parent.isEmpty ? "" : "/") + name
                if visited.insert(current).inserted {
                    children[parent, default: []].append(.init(path: current, name: String(name)))
                }
                parent = current
            }
            // Only paths reported by the server may be requested as media directories.
            if current == path {
                assetPaths.insert(path)
            }
        }
        self.assetPaths = assetPaths
        coverSamplePaths = Array(assetPaths.sorted().prefix(4))
        childrenByPath = children.mapValues { items in
            items.sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
            }
        }
    }

    func children(of folder: LibraryFolder?) -> [LibraryFolder] {
        childrenByPath[folder?.path ?? ""] ?? []
    }
}

@MainActor @Observable
final class LibraryFoldersStore {
    private(set) var tree: LibraryFolderTree?
    private(set) var didFail = false
    private(set) var coversByPath: [String: LibraryCoverAsset] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadingCoverPaths: Set<String> = []

    private var sampledPaths: [String] {
        tree?.coverSamplePaths ?? []
    }

    var covers: [LibraryCoverAsset] {
        sampledPaths.compactMap { coversByPath[$0] }
    }

    func load(source: ImmichTimelineRepository, refresh: Bool = false) async {
        if let loadTask {
            await loadTask.value; return
        }
        guard tree == nil || refresh else { return }
        let task = Task {
            defer { loadTask = nil }
            await fetch(source: source)
        }
        loadTask = task
        await task.value
    }

    private func fetch(source: ImmichTimelineRepository) async {
        do {
            let tree = try await source.libraryFolderTree()
            try Task.checkCancellation()
            coversByPath = coversByPath.filter { tree.assetPaths.contains($0.key) }
            self.tree = tree
            didFail = false
        } catch {
            guard !Task.isCancelled, !(error is CancellationError), (error as? TimelineReadError) != .staleGeneration else { return }
            didFail = true
        }
    }

    func loadCovers(source: ImmichTimelineRepository, paths: [String]? = nil) async {
        for path in paths ?? sampledPaths {
            guard !Task.isCancelled else { return }
            guard coversByPath[path] == nil, loadingCoverPaths.insert(path).inserted else { continue }
            defer { loadingCoverPaths.remove(path) }
            if let assets = try? await source.libraryFolderAssets(path: path), !Task.isCancelled,
               tree?.assetPaths.contains(path) == true,
               let cover = assets.max(by: { $0.isCaptured(before: $1) })
            {
                coversByPath[path] = LibraryCoverAsset(cover)
            }
        }
    }
}

struct LibraryFoldersCard: View {
    let source: ImmichTimelineRepository
    let media: MediaLibraryController
    let assetDetails: any AssetDetailReading
    let context: LibraryCollectionNavigation
    let store: LibraryFoldersStore

    var body: some View {
        LibraryHubLink {
            LibraryFoldersView(folder: nil, store: store, source: source, media: media, assetDetails: assetDetails, context: context)
        } label: {
            LibraryCollectionCard(title: "Folders", count: store.tree?.assetPaths.count, symbol: "folder",
                                  appearance: store.covers.isEmpty ? .glass : .photographic)
            {
                let covers = store.covers
                if !covers.isEmpty {
                    GeometryReader { geometry in
                        let width = max(1, (geometry.size.width - 2 * CGFloat(covers.count - 1)) / CGFloat(covers.count))
                        HStack(spacing: 2) {
                            ForEach(covers) { cover in
                                LibraryAssetCover(assetID: cover.id, revision: cover.revision, media: media)
                                    .frame(width: width, height: geometry.size.height)
                                    .clipped()
                            }
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library-folders")
    }
}

private struct LibraryFoldersView: View {
    @Namespace private var cardTransition
    let folder: LibraryFolder?
    let store: LibraryFoldersStore
    let source: ImmichTimelineRepository
    let media: MediaLibraryController
    let assetDetails: any AssetDetailReading
    let context: LibraryCollectionNavigation

    private var columns: [GridItem] {
        [.init(.adaptive(minimum: LibraryCollectionCardMetrics.minimumWidth,
                         maximum: LibraryCollectionCardMetrics.maximumWidth), spacing: LibraryCollectionCardMetrics.spacing)]
    }

    var body: some View {
        Group {
            if let folder, let tree = store.tree, tree.children(of: folder).isEmpty, tree.assetPaths.contains(folder.path) {
                folderTimeline(folder, title: folder.name)
            } else {
                folderListing
                    .libraryPageHeader(folder?.name ?? "Folders")
            }
        }
        .task(id: media.activeAPIURL) {
            guard store.tree == nil, media.activeAPIURL != nil else { return }
            await store.load(source: source)
        }
    }

    @ViewBuilder private var folderListing: some View {
        if let tree = store.tree {
            let children = tree.children(of: folder)
            if children.isEmpty {
                ContentUnavailableView("No Folders", systemImage: "folder",
                                       description: Text("Folders containing photos and videos in Immich appear here."))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: LibraryCollectionCardMetrics.spacing) {
                        if let folder, tree.assetPaths.contains(folder.path) {
                            LibraryCardLink(id: CardSource.assets, namespace: cardTransition) {
                                folderTimeline(folder, title: "Photos & Videos")
                            } label: {
                                folderCard(title: "Photos & Videos", symbol: "photo.on.rectangle", folder: folder)
                            }
                        }
                        ForEach(children) { child in
                            LibraryCardLink(id: CardSource.folder(child.id), namespace: cardTransition) {
                                LibraryFoldersView(folder: child, store: store, source: source,
                                                   media: media, assetDetails: assetDetails, context: context)
                            } label: {
                                folderCard(title: child.name, symbol: "folder", folder: child, count: tree.children(of: child).count)
                            }
                        }
                    }
                    .padding(16)
                }
                .refreshable {
                    await store.load(source: source, refresh: true)
                    await store.loadCovers(source: source)
                }
            }
        } else if media.activeAPIURL == nil {
            ContentUnavailableView("Immich Is Unavailable", systemImage: "wifi.slash")
        } else if store.didFail {
            ErrorStateView(title: "Couldn’t Load Folders") { Task { await store.load(source: source) } }
        } else {
            LoadingStateView(label: "Loading Folders")
        }
    }

    private enum CardSource: Hashable {
        case assets
        case folder(LibraryFolder.ID)
    }

    private func folderCard(title: String, symbol: String, folder: LibraryFolder, count: Int? = nil) -> some View {
        let cover = store.coversByPath[folder.path]
        return LibraryCollectionCard(title: title, count: count, symbol: symbol, appearance: cover == nil ? .glass : .photographic) {
            if let cover {
                LibraryAssetCover(assetID: cover.id, revision: cover.revision, media: media)
            }
        }
    }

    private func folderTimeline(_ folder: LibraryFolder, title: String) -> some View {
        let reader = LibrarySelectionTimelineReader { [source] in
            try await source.libraryFolderAssets(path: folder.path)
        }
        return LibraryCollectionTimeline(title: title, source: reader, query: .init(includesPartners: false),
                                         media: media, assetDetails: assetDetails, tabSelectionState: context.tabSelectionState,
                                         viewerPresentations: context.viewerPresentations, tabBarTop: context.tabBarTop)
    }
}
