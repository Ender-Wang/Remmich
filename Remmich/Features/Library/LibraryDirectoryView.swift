import ImmichAPI
import Nuke
import NukeUI
import Observation
import SwiftUI

struct LibraryCollectionNavigation {
    let activeEndpoint: URL?
    let tabBarTop: Binding<CGFloat>
    let tabSelectionState: NativeTabSelectionState?
    let viewerPresentations: AssetViewerPresentationStore?
    let viewerVisibilityChanged: (Bool) -> Void
}

nonisolated enum LibraryDirectory: String {
    case people = "People"
    case places = "Places"
    case partners = "Partners"

    var symbol: String {
        switch self {
        case .people: "person.2"
        case .places: "map"
        case .partners: "person.2.wave.2"
        }
    }
}

private enum LibraryDirectoryEntry: Identifiable {
    case person(LibraryPerson)
    case place(TimelinePlace, cover: TimelineAssetSummary)
    case partner(ImmichPartner)

    var id: String {
        switch self {
        case let .person(person): person.id
        case let .place(place, _): "\(place.country ?? "")\u{1f}\(place.city ?? "")"
        case let .partner(partner): partner.id
        }
    }

    var name: String {
        switch self {
        case let .person(person): person.displayName
        case let .place(place, _): place.name
        case let .partner(partner): partner.name.isEmpty ? "Partner" : partner.name
        }
    }
}

@MainActor @Observable
private final class LibraryDirectoryStore {
    static let placeQuery = TimelineQuery(includesStacks: true, includesPartners: false)
    private(set) var entries: [LibraryDirectoryEntry] = []
    private(set) var error: String?
    private(set) var finished = false
    private var loading = false
    private var buckets: [TimelineBucketSummary]?
    private var nextBucket = 0
    private var places: Set<TimelinePlace> = []

    func loadNext(_ directory: LibraryDirectory, source: ImmichTimelineRepository) async {
        guard !loading, !finished, !Task.isCancelled else { return }
        loading = true
        defer { loading = false }
        do {
            switch directory {
            case .people:
                let people = try await source.libraryPeople()
                try Task.checkCancellation()
                entries = people.map(LibraryDirectoryEntry.person)
                finished = true
            case .partners:
                let partners = try await source.libraryPartners()
                try Task.checkCancellation()
                entries = partners.map(LibraryDirectoryEntry.partner)
                finished = true
            case .places:
                if buckets == nil {
                    buckets = try await source.bucketSummaries(query: Self.placeQuery)
                }
                guard let buckets else { return }
                let initialCount = entries.count
                while nextBucket < buckets.count, entries.count == initialCount {
                    try Task.checkCancellation()
                    let assets = try await source.assets(in: buckets[nextBucket].id, query: Self.placeQuery)
                    try Task.checkCancellation()
                    nextBucket += 1
                    for asset in assets where asset.mediaKind == .image || asset.mediaKind == .video {
                        if let place = asset.place, places.insert(place).inserted {
                            entries.append(.place(place, cover: asset))
                        }
                    }
                }
                finished = nextBucket == buckets.count
            }
            error = nil
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            self.error = error.localizedDescription
        }
    }
}

struct LibraryDirectoryCard: View {
    let directory: LibraryDirectory
    let source: ImmichTimelineRepository
    let media: MediaLibraryController
    let assetDetails: any AssetDetailReading
    let context: LibraryCollectionNavigation
    @State private var store = LibraryDirectoryStore()

    var body: some View {
        LibraryHubLink {
            LibraryDirectoryView(directory: directory, store: store, source: source, media: media, assetDetails: assetDetails, context: context)
        } label: {
            LibraryCollectionCard(title: directory.rawValue, detail: store.finished ? store.entries.count.formatted() : "",
                                  symbol: directory.symbol, appearance: store.entries.isEmpty ? .glass : .photographic)
            {
                if directory != .places {
                    GeometryReader { geometry in
                        let size = min(geometry.size.width / 4, geometry.size.height / 3)
                        let people = Array(store.entries.prefix(4))
                        VStack(spacing: 6) {
                            ForEach([0, 2], id: \.self) { offset in
                                HStack(spacing: 6) {
                                    ForEach(people.dropFirst(offset).prefix(2)) { entry in
                                        LibraryDirectoryPortrait(entry: entry, media: media, size: size)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                    }
                } else if case let .place(_, cover)? = store.entries.first {
                    LibraryAssetCover(assetID: cover.id, revision: cover.thumbnailRevision, media: media)
                }
            }
        }
        .buttonStyle(.plain)
        .task(id: context.activeEndpoint) {
            guard context.activeEndpoint != nil, store.entries.isEmpty else { return }
            await store.loadNext(directory, source: source)
        }
    }
}

private struct LibraryDirectoryView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let directory: LibraryDirectory
    let store: LibraryDirectoryStore
    let source: ImmichTimelineRepository
    let media: MediaLibraryController
    let assetDetails: any AssetDetailReading
    let context: LibraryCollectionNavigation
    @Namespace private var headerNamespace
    @State private var selected: LibraryDirectoryEntry?
    @State private var timeline: PhotosTimelineStore?

    var body: some View {
        ZStack {
            directoryContent
                .opacity(selected == nil ? 1 : 0)
                .allowsHitTesting(selected == nil)
                .accessibilityHidden(selected != nil)
            if let selected, let timeline {
                LibraryTimelineViewport { clearance in
                    LibraryTimelineLane(store: timeline, name: selected.name, active: true, media: media, assetDetails: assetDetails,
                                        tabSelectionState: context.tabSelectionState, viewerPresentations: context.viewerPresentations,
                                        tabBarTop: context.tabBarTop, clearance: clearance)
                        .id(selected.id)
                } header: {
                    header(selected, portraitWidth: 72)
                        .matchedGeometryEffect(id: selected.id, in: headerNamespace, isSource: false)
                        .padding(.top, 4)
                        .padding(.bottom, 8)
                        .frame(maxWidth: .infinity)
                        .background {
                            LibraryTitleBackdrop()
                                .ignoresSafeArea(.container, edges: .horizontal)
                        }
                }
            }
        }
        .navigationTitle(directory.rawValue)
        .navigationBarBackButtonHidden(selected != nil)
        .libraryNavigationChrome()
        .toolbar {
            if selected != nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: close) { Image(systemName: "chevron.left") }
                        .accessibilityLabel("Back to \(directory.rawValue)")
                }
            }
        }
        .nativeEdgeBackAction(active: selected != nil && context.viewerPresentations?.activeID == nil,
                              priority: 50, action: close)
        .task {
            if store.entries.isEmpty {
                await store.loadNext(directory, source: source)
            }
        }
    }

    @ViewBuilder private var directoryContent: some View {
        if !store.entries.isEmpty {
            GeometryReader { geometry in
                let peopleColumns = directory != .places ? max(4, Int(geometry.size.width / 98)) : nil
                let layout = LibraryCardRows(width: geometry.size.width, preferredColumns: peopleColumns)
                let rows = layout.identifiedRows(store.entries)
                LibraryCardScroll(initialRowID: store.entries.first?.id ?? "", viewportHeight: geometry.size.height,
                                  alignment: directory == .partners ? .top : .bottom,
                                  oldestRowID: directory == .places && selected == nil ? rows.first?.id : nil,
                                  oldestItemID: store.entries.last?.id, loadOlder: { await store.loadNext(directory, source: source) })
                {
                    LazyVStack(spacing: LibraryCollectionCardMetrics.spacing) {
                        ForEach(directory == .partners ? Array(rows.reversed()) : rows) { row in
                            HStack(alignment: .top, spacing: LibraryCollectionCardMetrics.spacing) {
                                ForEach(row.items) { entry in
                                    Button { open(entry) } label: {
                                        rowCard(entry, width: layout.itemWidth)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(directory == .partners ? .top : .bottom, row.id == store.entries.first?.id ? 16 : 0)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 16)
                    .padding(directory == .partners ? .bottom : .top, 16)
                }
            }
        } else if let error = store.error {
            ErrorStateView(title: "Couldn’t Load \(directory.rawValue)") {
                Task { await store.loadNext(directory, source: source) }
            }
            .accessibilityHint(error)
        } else if store.finished {
            ContentUnavailableView("No \(directory.rawValue)", systemImage: directory.symbol,
                                   description: directory == .partners ? Text("Partner libraries appear here when someone shares with you.") : nil)
        } else {
            ProgressView()
        }
    }

    @ViewBuilder private func rowCard(_ entry: LibraryDirectoryEntry, width: CGFloat) -> some View {
        switch entry {
        case .person, .partner:
            header(entry, portraitWidth: width)
                .matchedGeometryEffect(id: entry.id, in: headerNamespace)
                .frame(width: width)
        case let .place(place, cover):
            ZStack(alignment: .bottomLeading) {
                LibraryAssetCover(assetID: cover.id, revision: cover.thumbnailRevision, media: media)
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.headline)
                        .matchedGeometryEffect(id: entry.id, in: headerNamespace)
                    if place.city != nil, let country = place.country {
                        Text(country).font(.caption)
                    }
                }
                .foregroundStyle(.white)
                .padding(12)
            }
            .frame(width: width, height: width / LibraryCollectionCardMetrics.aspectRatio)
            .clipShape(.rect(cornerRadius: DesignMetrics.defaultCornerRadius))
        }
    }

    @ViewBuilder private func header(_ entry: LibraryDirectoryEntry, portraitWidth: CGFloat) -> some View {
        if directory != .places {
            VStack(spacing: 4) {
                LibraryDirectoryPortrait(entry: entry, media: media, size: portraitWidth)
                Text(entry.name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
            }
            .accessibilityElement(children: .combine)
        } else {
            Text(entry.name).font(.headline)
        }
    }

    private func open(_ entry: LibraryDirectoryEntry) {
        var query = LibraryDirectoryStore.placeQuery
        var place: TimelinePlace?
        var newestBucket: TimelineBucketID?
        switch entry {
        case let .person(person):
            query.personID = person.id
            query.visibility = nil
        case let .partner(partner):
            query.userID = partner.id
        case let .place(value, cover):
            place = value
            let day = TimelineCaptureDay(capturedAt: cover.captureLocalDate)
            newestBucket = .init(rawValue: String(format: "%04d-%02d-01", day.year, day.month))
        }
        let store = PhotosTimelineStore(reader: LibraryScopedTimelineReader(source: source, query: query, media: nil,
                                                                            place: place, newestBucket: newestBucket),
                                        hasUnfilteredBucketCounts: place != nil)
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) {
            timeline = store
            selected = entry
        }
    }

    private func close() {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) {
            selected = nil
            timeline = nil
        }
    }
}

private struct LibraryDirectoryPortrait: View {
    @Environment(\.displayScale) private var scale
    let entry: LibraryDirectoryEntry
    let media: MediaLibraryController
    let size: CGFloat

    var body: some View {
        LazyImage(request: request) { state in
            if let image = state.image {
                image.resizable().scaledToFill()
            } else if case .partner = entry {
                Text(entry.name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first).map(String.init).joined().uppercased())
                    .font(.system(size: size * 0.32, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.thinMaterial)
            } else {
                Image(systemName: "person.crop.circle.fill").resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
        .pipeline(media.pipeline ?? .shared)
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }

    private var request: ImageRequest? {
        let pixels = max(1, Int((size * scale).rounded(.up)))
        return switch entry {
        case let .person(person): media.personThumbnailRequest(person, pixels: pixels)
        case let .partner(partner): media.partnerProfileRequest(partner, pixels: pixels)
        case .place: nil
        }
    }
}
