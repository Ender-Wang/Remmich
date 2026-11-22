import Nuke
import NukeUI
import Observation
import SwiftUI

struct LibraryCollectionNavigation {
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

nonisolated struct LibraryPortraitCoverLayout {
    static let spacing: CGFloat = 6
    static let topPadding: CGFloat = 8

    let columns: Int
    let count: Int
    let size: CGFloat

    init(width: CGFloat, height: CGFloat, count: Int, expands: Bool, footerHeight: CGFloat) {
        let space = max(1, height - footerHeight - Self.topPadding)
        let capacity = max(0, count)
        let availableWidth = max(1, width - 24)
        func size(columns: Int, rows: Int) -> CGFloat {
            min(52, max(1, (availableWidth - CGFloat(columns - 1) * Self.spacing) / CGFloat(columns)),
                max(1, (space - CGFloat(rows - 1) * Self.spacing) / CGFloat(rows)))
        }
        if expands, capacity >= 8, size(columns: 4, rows: 2) >= 38 {
            columns = 4
            self.count = 8
        } else if expands, capacity >= 6, size(columns: 3, rows: 2) >= 32 {
            columns = 3
            self.count = 6
        } else {
            columns = 2
            self.count = min(capacity, 4)
        }
        self.size = size(columns: columns, rows: self.count > columns ? 2 : 1)
    }
}

private enum LibraryDirectoryEntry: Identifiable {
    case person(LibraryPerson)
    case place(TimelinePlace, cover: TimelineAssetSummary)
    case partner(LibraryPartner)

    var id: String {
        switch self {
        case let .person(person): person.id
        case let .place(place, _): place.directoryID
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

    var place: TimelinePlace? {
        guard case let .place(place, _) = self else { return nil }
        return place
    }
}

private struct LibraryPlaceLabelRequest: Hashable {
    let place: TimelinePlace
    let revision: Int
}

private struct LibraryPlaceLabelLoad: Equatable {
    let request: LibraryPlaceLabelRequest
    let cacheSyncDate: Date?
}

@MainActor @Observable
final class LibraryDirectoryStore {
    static let placeQuery = TimelineQuery(includesStacks: true, includesPartners: false)
    fileprivate private(set) var entries: [LibraryDirectoryEntry] = []
    private(set) var error: String?
    private(set) var finished = false
    private(set) var indexedPlaceCount: Int?
    fileprivate var selectedPlace: LibraryDirectoryEntry?
    fileprivate private(set) var placeLabels: [LibraryPlaceLabelRequest: TimelinePlace] = [:]
    @ObservationIgnored private var loadingPlaceLabels: Set<LibraryPlaceLabelRequest> = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var placeOpening: LibraryOpeningBuckets?
    private var buckets: [TimelineBucketSummary]?
    private var nextBucket = 0
    private var places: Set<TimelinePlace> = []
    private var indexedPlaceOffset = 0

    func adoptIndexedPeople(_ people: [LibraryPerson]) {
        guard loadTask == nil else { return }
        entries = people.map(LibraryDirectoryEntry.person)
        finished = true
        error = nil
    }

    func adoptIndexedPartners(_ partners: [LibraryPartner]) {
        guard loadTask == nil else { return }
        entries = partners.map(LibraryDirectoryEntry.partner)
        finished = true
        error = nil
    }

    func refreshIndexedPlaces(source: ImmichTimelineRepository) async {
        guard loadTask == nil else { return }
        let loaded = entries.count
        guard let page = try? await source.libraryPlaceCovers(offset: 0, limit: loaded),
              !Task.isCancelled, loadTask == nil, entries.count == loaded else { return }
        indexedPlaceCount = page.count
        indexedPlaceOffset = page.covers.count
        buckets = nil
        nextBucket = 0
        entries.removeAll(keepingCapacity: true)
        places.removeAll(keepingCapacity: true)
        appendIndexedPlaces(page.covers)
        finished = indexedPlaceOffset >= page.count
        error = nil
    }

    private func appendIndexedPlaces(_ covers: [TimelineAssetSummary]) {
        entries.append(contentsOf: covers.compactMap { cover in
            guard let place = cover.place, places.insert(place).inserted else { return nil }
            return .place(place, cover: cover)
        })
    }

    @discardableResult
    func dismissSelectedPlace() -> Bool {
        guard selectedPlace != nil else { return false }
        selectedPlace = nil
        return true
    }

    fileprivate func loadPlaceLabel(_ request: LibraryPlaceLabelRequest, assetID: String, locations: AssetLocationStore,
                                    mapSource: LibraryPlacesMapSource?) async
    {
        guard placeLabels[request] == nil, loadingPlaceLabels.insert(request).inserted else { return }
        defer { loadingPlaceLabels.remove(request) }
        let place = request.place
        do {
            var label = try await locations.libraryPlaceLabel(assetID: assetID, place: place)
            if label == nil, let mapSource, usesLocalPlaceNames(place, preferences: locations.preferences) {
                let candidates = try await mapSource.store.libraryLocalPlaceLabelAssets(place, scope: mapSource.scope)
                for candidate in candidates where candidate != assetID {
                    try Task.checkCancellation()
                    label = try await locations.libraryPlaceLabel(assetID: candidate, place: place)
                    if label != nil {
                        break
                    }
                }
            }
            guard !Task.isCancelled, locations.revision == request.revision else { return }
            placeLabels[request] = label
        } catch {
            // An unavailable place cache leaves the Immich label usable.
        }
    }

    private func usesLocalPlaceNames(_ place: TimelinePlace, preferences: MapsPlacesPreferences) -> Bool {
        guard let country = place.country else { return !preferences.localCountries.isEmpty }
        let english = Locale(identifier: "en_US")
        return preferences.localCountries.contains {
            english.localizedString(forRegionCode: $0)?.caseInsensitiveCompare(country) == .orderedSame
        }
    }

    func placeReader(source: ImmichTimelineRepository) -> LibraryOpeningBuckets {
        if let placeOpening {
            return placeOpening
        }
        let reader = LibraryOpeningBuckets(source: source, query: Self.placeQuery)
        placeOpening = reader
        return reader
    }

    func loadNext(_ directory: LibraryDirectory, source: ImmichTimelineRepository, openingLimit: Int? = nil) async {
        if let loadTask {
            await loadTask.value
            if openingLimit == nil, !entries.isEmpty || error != nil {
                return
            }
        }
        guard !finished, !Task.isCancelled, loadTask == nil,
              openingLimit.map({ entries.count < $0 }) ?? true else { return }
        let task = Task(priority: openingLimit == nil ? .userInitiated : .utility) {
            defer { loadTask = nil }
            await loadPage(directory, source: source, openingLimit: openingLimit)
        }
        loadTask = task
        await task.value
    }

    private func loadPage(_ directory: LibraryDirectory, source: ImmichTimelineRepository, openingLimit: Int?) async {
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
                    let limit = max(1, openingLimit.map { $0 - entries.count } ?? 24)
                    let page = try await source.libraryPlaceCovers(offset: indexedPlaceOffset, limit: limit)
                    try Task.checkCancellation()
                    if let page {
                        indexedPlaceCount = page.count
                        indexedPlaceOffset += page.covers.count
                        appendIndexedPlaces(page.covers)
                        finished = indexedPlaceOffset >= page.count || page.covers.count < limit
                        error = nil
                        return
                    }
                }
                let reader = placeReader(source: source)
                if buckets == nil {
                    buckets = try await reader.bucketSummaries(query: Self.placeQuery)
                }
                guard let buckets else { return }
                let target = openingLimit ?? (entries.count + 1)
                let end = openingLimit == nil ? buckets.count : min(buckets.count, nextBucket + LibraryOpeningBuckets.monthLimit)
                while nextBucket < end, entries.count < target {
                    try Task.checkCancellation()
                    let assets = try await reader.assets(in: buckets[nextBucket].id, query: Self.placeQuery)
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

    func imageRequests(directory: LibraryDirectory, media: MediaLibraryController, scale: CGFloat,
                       cardWidth: CGFloat, limit: Int, forHub: Bool, footerHeight: CGFloat = 52) -> [ImageRequest]
    {
        let layout = LibraryPortraitCoverLayout(width: cardWidth, height: cardWidth / LibraryCollectionCardMetrics.aspectRatio,
                                                count: entries.count, expands: directory == .people, footerHeight: footerHeight)
        return entries.prefix(forHub ? min(limit, layout.count) : limit).compactMap { entry in
            if case let .place(_, asset) = entry {
                let descriptor = LibraryCollectionCardMetrics.coverDescriptor(.init(asset), scale: scale)
                return media.imageRequest(for: descriptor, priority: .low)
            }
            let size = forHub ? layout.size : cardWidth
            return LibraryDirectoryPortrait.request(for: entry, media: media, pixels: max(1, Int((size * scale).rounded(.up))))
        }
    }
}

struct LibraryDirectoryCard: View {
    @ScaledMetric(relativeTo: .caption) private var footerHeight: CGFloat = 52
    let directory: LibraryDirectory
    let source: ImmichTimelineRepository
    let media: MediaLibraryController
    let assetDetails: any AssetDetailReading
    let context: LibraryCollectionNavigation
    let store: LibraryDirectoryStore
    var heatmap: UIImage?
    var placesMapSource: LibraryPlacesMapSource?

    var body: some View {
        LibraryHubLink {
            LibraryDirectoryView(directory: directory, store: store, source: source, media: media, assetDetails: assetDetails,
                                 context: context, placesMapSource: placesMapSource)
        } label: {
            LibraryCollectionCard(title: directory.rawValue, count: store.indexedPlaceCount ?? (store.finished ? store.entries.count : nil),
                                  symbol: directory.symbol, appearance: hasCover ? .photographic : .glass)
            {
                if directory != .places {
                    GeometryReader { geometry in
                        let layout = LibraryPortraitCoverLayout(width: geometry.size.width, height: geometry.size.height,
                                                                count: store.entries.count, expands: directory == .people, footerHeight: footerHeight)
                        VStack(spacing: LibraryPortraitCoverLayout.spacing) {
                            ForEach(Array(stride(from: 0, to: layout.count, by: layout.columns)), id: \.self) { offset in
                                HStack(spacing: LibraryPortraitCoverLayout.spacing) {
                                    ForEach(store.entries[offset ..< min(layout.count, offset + layout.columns)]) { entry in
                                        LibraryDirectoryPortrait(entry: entry, media: media, size: layout.size)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, LibraryPortraitCoverLayout.topPadding)
                    }
                } else if let heatmap {
                    GeometryReader { geometry in
                        Image(uiImage: heatmap).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    }
                    .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var hasCover: Bool {
        directory == .places ? heatmap != nil : !store.entries.isEmpty
    }
}

private struct LibraryDirectoryView: View {
    @Environment(\.assetLocations) private var locations
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let directory: LibraryDirectory
    let store: LibraryDirectoryStore
    let source: ImmichTimelineRepository
    let media: MediaLibraryController
    let assetDetails: any AssetDetailReading
    let context: LibraryCollectionNavigation
    let placesMapSource: LibraryPlacesMapSource?
    @Namespace private var cardTransition

    var body: some View {
        Group {
            if directory == .places {
                placesPage
            } else {
                directoryContent.libraryPageHeader(directory.rawValue)
            }
        }
        .task {
            if store.entries.isEmpty {
                await store.loadNext(directory, source: source)
            }
        }
    }

    private var placesPage: some View {
        let selection = store.selectedPlace
        return GeometryReader { geometry in
            let layout = LibraryCardRows(availableWidth: geometry.size.width - 32)
            let twoRows = 2 * layout.itemWidth / LibraryCollectionCardMetrics.aspectRatio
            let mapHeight = min(twoRows, geometry.size.height * (geometry.size.width > geometry.size.height ? 0.46 : 0.55))
            VStack(spacing: 0) {
                placesMapHeader(height: mapHeight, selection: selection)
                placesContent(selection: selection)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .nativeEdgeBackAction(active: selection != nil && (context.tabSelectionState?.canActivateContent(in: .library) ?? true),
                              animatesContent: false, action: dismissPlace)
    }

    private func placesMapHeader(height: CGFloat, selection: LibraryDirectoryEntry?) -> some View {
        let backAction: (() -> Void)? = selection == nil ? nil : { dismissPlace() }
        return LibraryPlacesMap(source: placesMapSource, place: selection?.place)
            .ignoresSafeArea(.container, edges: [.top, .horizontal])
            .frame(height: height)
            .overlay(alignment: .top) {
                LibraryPageHeader(title: selection.map { title(for: $0) } ?? directory.rawValue,
                                  backLabel: selection == nil ? "Back to Library" : "Back to Places", backAction: backAction)
                {
                    EmptyView()
                }
                .background {
                    TimelineMemoryGradientBackdrop(visible: true, extended: true, reduceMotion: reduceMotion)
                        .ignoresSafeArea(.container, edges: [.top, .horizontal])
                        .allowsHitTesting(false)
                }
            }
    }

    private func placesContent(selection: LibraryDirectoryEntry?) -> some View {
        ZStack {
            directoryContent
                .opacity(selection == nil ? 1 : 0)
                .allowsHitTesting(selection == nil)
                .accessibilityHidden(selection != nil)
            if let selection {
                timeline(for: selection, showsHeader: false)
                    .id(selection.id)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: selection?.id)
    }

    private func dismissPlace() {
        store.dismissSelectedPlace()
    }

    @ViewBuilder private var directoryContent: some View {
        if !store.entries.isEmpty {
            GeometryReader { geometry in
                let peopleColumns = directory != .places ? max(4, Int(geometry.size.width / 98)) : nil
                let layout = LibraryCardRows(width: geometry.size.width, preferredColumns: peopleColumns)
                let rows = layout.identifiedRows(store.entries)
                LibraryCardScroll(initialRowID: store.entries.first?.id ?? "", viewportHeight: geometry.size.height,
                                  alignment: directory == .partners ? .top : .bottom,
                                  oldestRowID: directory == .places ? rows.first?.id : nil,
                                  oldestItemID: store.entries.last?.id, loadOlder: { await store.loadNext(directory, source: source) })
                {
                    LazyVStack(spacing: LibraryCollectionCardMetrics.spacing) {
                        ForEach(directory == .partners ? Array(rows.reversed()) : rows) { row in
                            HStack(alignment: .top, spacing: LibraryCollectionCardMetrics.spacing) {
                                ForEach(row.items) { entry in
                                    directoryLink(entry, width: layout.itemWidth)
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

    @ViewBuilder private func directoryLink(_ entry: LibraryDirectoryEntry, width: CGFloat) -> some View {
        if case let .place(place, cover) = entry {
            let load = locations.map {
                LibraryPlaceLabelLoad(request: .init(place: place, revision: $0.revision), cacheSyncDate: $0.cacheRun.lastSyncedAt)
            }
            Button {
                store.selectedPlace = entry
            } label: {
                rowCard(entry, width: width)
            }
            .buttonStyle(.plain)
            .task(id: load) {
                guard let load, let locations else { return }
                await store.loadPlaceLabel(load.request, assetID: cover.id, locations: locations, mapSource: placesMapSource)
            }
        } else {
            LibraryCardLink(id: entry.id, namespace: cardTransition) {
                timeline(for: entry)
            } label: {
                rowCard(entry, width: width)
            }
        }
    }

    private func localizedLabel(for place: TimelinePlace) -> TimelinePlace? {
        guard let locations else { return nil }
        return store.placeLabels[.init(place: place, revision: locations.revision)]
    }

    private func title(for entry: LibraryDirectoryEntry) -> String {
        guard let place = entry.place, let label = localizedLabel(for: place) else { return entry.name }
        return (place.city == nil ? label.country : label.city) ?? entry.name
    }

    @ViewBuilder private func rowCard(_ entry: LibraryDirectoryEntry, width: CGFloat) -> some View {
        switch entry {
        case .person, .partner:
            VStack(spacing: 4) {
                LibraryDirectoryPortrait(entry: entry, media: media, size: width)
                Text(entry.name)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(width: width)
            .accessibilityElement(children: .combine)
        case let .place(place, cover):
            let label = localizedLabel(for: place)
            ZStack(alignment: .bottomLeading) {
                LibraryAssetCover(assetID: cover.id, revision: cover.thumbnailRevision, media: media)
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(for: entry))
                        .font(.headline)
                        .lineLimit(2)
                    if place.city != nil, let country = label == nil ? place.country : label?.country {
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

    private func timeline(for entry: LibraryDirectoryEntry, showsHeader: Bool = true) -> some View {
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
        let sharedReads: LibraryOpeningBuckets = if place != nil {
            store.placeReader(source: source)
        } else {
            LibraryOpeningBuckets(source: source, query: query)
        }
        let timelineReader = LibraryScopedTimelineReader(source: sharedReads, query: query, media: nil, place: place, newestBucket: newestBucket)
        return LibraryDirectoryTimeline(entry: entry, directory: directory, media: media, assetDetails: assetDetails, context: context,
                                        sharedReads: sharedReads, title: title(for: entry), showsHeader: showsHeader,
                                        store: PhotosTimelineStore(reader: timelineReader, hasUnfilteredBucketCounts: place != nil))
    }
}

private struct LibraryDirectoryTimeline: View {
    let entry: LibraryDirectoryEntry
    let directory: LibraryDirectory
    let media: MediaLibraryController
    let assetDetails: any AssetDetailReading
    let context: LibraryCollectionNavigation
    let sharedReads: LibraryOpeningBuckets?
    let title: String
    let showsHeader: Bool
    @State var store: PhotosTimelineStore

    var body: some View {
        LibraryTimelineViewport { clearance in
            LibraryTimelineLane(store: store, name: title, active: true, media: media, assetDetails: assetDetails,
                                tabSelectionState: context.tabSelectionState, viewerPresentations: context.viewerPresentations,
                                tabBarTop: context.tabBarTop, clearance: clearance, sharedReads: sharedReads)
        } header: {
            if showsHeader {
                VStack(spacing: 0) {
                    LibraryPageHeader(title: title, backLabel: "Back to \(directory.rawValue)") { EmptyView() }
                    if directory != .places {
                        LibraryDirectoryPortrait(entry: entry, media: media, size: 72)
                            .padding(.top, 4)
                            .padding(.bottom, 8)
                    }
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
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
        return Self.request(for: entry, media: media, pixels: pixels)
    }

    static func request(for entry: LibraryDirectoryEntry, media: MediaLibraryController, pixels: Int) -> ImageRequest? {
        switch entry {
        case let .person(person): media.personThumbnailRequest(person, pixels: pixels)
        case let .partner(partner): media.partnerProfileRequest(partner, pixels: pixels)
        case .place: nil
        }
    }
}
