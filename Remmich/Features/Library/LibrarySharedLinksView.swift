import Observation
import SwiftUI

nonisolated struct LibrarySharedLink: Codable, Identifiable, Sendable {
    let id: String
    let name: String?
    let createdAt: Date
    let expiresAt: Date?
    let isPasswordProtected: Bool
    let publicURL: URL?
    let album: AlbumSummary?
    let assets: [TimelineAssetSummary]

    var title: String {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return album?.title ?? "Shared selection"
    }

    var cover: LibraryCoverAsset? {
        if let album, let assetID = album.thumbnailAssetID {
            return .init(id: assetID, revision: album.lastModifiedAssetTimestamp ?? album.updatedAt)
        }
        return assets.max { $0.isCaptured(before: $1) }.map(LibraryCoverAsset.init)
    }

    var isExpired: Bool {
        expiresAt.map { $0 <= .now } ?? false
    }

    var symbol: String {
        if isExpired {
            return "clock.badge.exclamationmark"
        }
        return isPasswordProtected ? "lock" : "link"
    }

    var detail: String {
        if isExpired {
            return "Expired"
        }
        if let expiresAt {
            return "Expires \(expiresAt.formatted(date: .abbreviated, time: .omitted))"
        }
        return album != nil ? "Album" : ""
    }
}

@MainActor @Observable
final class LibrarySharedLinksStore {
    private(set) var links: [LibrarySharedLink]?
    private(set) var didFail = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    var cover: LibraryCoverAsset? {
        links?.lazy.filter { !$0.isExpired }.compactMap(\.cover).first
    }

    func adoptIndexedLinks(_ links: [LibrarySharedLink]) {
        guard loadTask == nil else { return }
        self.links = links
        didFail = false
    }

    func load(source: ImmichTimelineRepository, refresh: Bool = false) async {
        if let loadTask {
            await loadTask.value; return
        }
        guard links == nil || refresh else { return }
        let task = Task {
            defer { loadTask = nil }
            await fetch(source: source, refresh: refresh)
        }
        loadTask = task
        await task.value
    }

    private func fetch(source: ImmichTimelineRepository, refresh: Bool) async {
        do {
            let result = try await source.librarySharedLinks(refresh: refresh)
            try Task.checkCancellation()
            links = result
            didFail = false
        } catch {
            guard !Task.isCancelled, !(error is CancellationError), (error as? TimelineReadError) != .staleGeneration else { return }
            didFail = true
        }
    }
}

struct LibrarySharedLinksCard: View {
    let source: ImmichTimelineRepository
    let media: MediaLibraryController
    let assetDetails: any AssetDetailReading
    let context: LibraryCollectionNavigation
    let store: LibrarySharedLinksStore

    var body: some View {
        let cover = store.cover
        LibraryHubLink {
            LibrarySharedLinksView(store: store, source: source, media: media, assetDetails: assetDetails, context: context)
        } label: {
            LibraryCollectionCard(title: "Shared Links", count: store.links?.count, symbol: "link",
                                  appearance: cover == nil ? .glass : .photographic)
            {
                if let cover {
                    LibraryAssetCover(assetID: cover.id, revision: cover.revision, media: media)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library-shared-links")
    }
}

private struct LibrarySharedLinksView: View {
    @Namespace private var cardTransition
    let store: LibrarySharedLinksStore
    let source: ImmichTimelineRepository
    let media: MediaLibraryController
    let assetDetails: any AssetDetailReading
    let context: LibraryCollectionNavigation

    var body: some View {
        Group {
            if let links = store.links, !links.isEmpty {
                GeometryReader { geometry in
                    let layout = LibraryCardRows(width: geometry.size.width, preferredColumns: nil)
                    LibraryCardScroll(initialRowID: links.first?.id ?? "", viewportHeight: geometry.size.height) {
                        LazyVStack(spacing: LibraryCollectionCardMetrics.spacing) {
                            ForEach(layout.identifiedRows(links)) { row in
                                HStack(spacing: LibraryCollectionCardMetrics.spacing) {
                                    ForEach(row.items) { link in
                                        LibraryCardLink(id: link.id, namespace: cardTransition) {
                                            timeline(for: link)
                                        } label: {
                                            card(for: link).frame(width: layout.itemWidth)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .scrollTargetLayout()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                    }
                    .refreshable { await store.load(source: source, refresh: true) }
                }
            } else if media.activeAPIURL == nil {
                ContentUnavailableView("Immich Is Unavailable", systemImage: "wifi.slash")
            } else if store.didFail {
                ErrorStateView(title: "Couldn’t Load Shared Links") { Task { await store.load(source: source) } }
            } else if store.links != nil {
                ContentUnavailableView("No Shared Links", systemImage: "link",
                                       description: Text("Links you create in Immich appear here."))
            } else {
                LoadingStateView(label: "Loading Shared Links")
            }
        }
        .libraryPageHeader("Shared Links")
        .task(id: media.activeAPIURL) {
            guard media.activeAPIURL != nil else { return }
            await store.load(source: source)
        }
    }

    private func card(for link: LibrarySharedLink) -> some View {
        let cover = link.cover
        let detail = link.detail
        return LibraryCollectionCard(title: link.title, count: detail.isEmpty ? link.assets.count : nil, detail: detail, symbol: link.symbol,
                                     appearance: cover == nil ? .glass : .photographic)
        {
            if let cover {
                LibraryAssetCover(assetID: cover.id, revision: cover.revision, media: media)
            }
        }
    }

    private func timeline(for link: LibrarySharedLink) -> some View {
        let reader: any TimelineReading = link.album == nil ? LibrarySelectionTimelineReader(assets: link.assets) : source
        let query = TimelineQuery(albumID: link.album?.id, includesStacks: true, includesPartners: false)
        return LibraryCollectionTimeline(title: link.title, source: reader, query: query, media: media, assetDetails: assetDetails,
                                         tabSelectionState: context.tabSelectionState, viewerPresentations: context.viewerPresentations,
                                         tabBarTop: context.tabBarTop, shareURL: link.isExpired ? nil : link.publicURL)
    }
}
