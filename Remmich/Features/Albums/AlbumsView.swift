import SwiftUI

nonisolated struct AlbumScrollGeometry: Equatable {
    let offset: CGFloat
    let topInset: CGFloat
    let viewportHeight: CGFloat
    let contentHeight: CGFloat
    var bottomInset: CGFloat = 0

    var bottomGap: CGFloat {
        // SwiftUI's measured content extent already includes the scroll
        // margins. Offset is normalized by the top inset at collection time.
        max(0, contentHeight - viewportHeight - offset)
    }

    func scrollDelta(from previous: Self) -> CGFloat? {
        guard topInset == previous.topInset, bottomInset == previous.bottomInset, viewportHeight == previous.viewportHeight,
              contentHeight == previous.contentHeight else { return nil }
        return offset - previous.offset
    }
}

enum AlbumScope: String, CaseIterable, Identifiable {
    case all = "All"
    case shared = "Shared"
    var id: Self {
        self
    }
}

struct AlbumsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let source: any AlbumReading & TimelineReading
    let media: MediaLibraryController
    let assetDetails: any AssetDetailReading
    let activeEndpoint: URL?
    let scrollToLatestRequest: Int
    let persistence: (any AlbumCatalogStoring)?
    let accountScope: MediaAccountScope?
    let viewerPresentations: AssetViewerPresentationStore
    let tabSelectionState: NativeTabSelectionState
    @Binding var tabBarTop: CGFloat
    let loadingVisibilityChanged: ((Bool) -> Void)?
    let openAlbum: (AlbumSummary) -> Void
    let showAccount: () -> Void
    @State private var store: AlbumsStore
    @State private var scope: AlbumScope = .all
    @State private var query = ""
    @State private var sort: AlbumSort = .mostRecentPhoto
    @State private var sortDirection: AlbumSortDirection = .ascending
    @State private var isReordering = false
    @State private var reorderGeneration = 0
    @State private var showsList = false
    @State private var chromeTracker = PhotosChromeTracker()
    @State private var searchHidden = false
    @State private var searchRowHeight: CGFloat = 44
    @State private var scopePickerHeight: CGFloat = 32
    @State private var userScrolling = false
    @State private var visibleAlbumID: String?
    @State private var listVisible = false
    @Namespace private var albumTransition
    @State private var timelineSessions = AlbumTimelineSessions()
    @FocusState private var searchFocused: Bool

    init(source: any AlbumReading & TimelineReading, media: MediaLibraryController,
         assetDetails: any AssetDetailReading, activeEndpoint: URL?,
         scrollToLatestRequest: Int = 0,
         persistence: (any AlbumCatalogStoring)? = nil, scope: MediaAccountScope? = nil,
         viewerPresentations: AssetViewerPresentationStore, tabSelectionState: NativeTabSelectionState,
         tabBarTop: Binding<CGFloat>, loadingVisibilityChanged: ((Bool) -> Void)? = nil,
         openAlbum: @escaping (AlbumSummary) -> Void,
         showAccount: @escaping () -> Void)
    {
        self.source = source
        self.media = media
        self.assetDetails = assetDetails
        self.activeEndpoint = activeEndpoint
        self.scrollToLatestRequest = scrollToLatestRequest
        self.persistence = persistence
        accountScope = scope
        self.viewerPresentations = viewerPresentations
        self.tabSelectionState = tabSelectionState
        _tabBarTop = tabBarTop
        self.loadingVisibilityChanged = loadingVisibilityChanged
        self.openAlbum = openAlbum
        self.showAccount = showAccount
        _store = State(initialValue: AlbumsStore(reader: source, persistence: persistence, scope: scope))
    }

    private var filtered: [AlbumSummary] {
        sort.sorted(store.albums.filter {
            (scope == .all || $0.isShared) && (query.isEmpty || $0.title.localizedStandardContains(query))
        }, direction: sortDirection)
    }

    private var expandedHeaderHeight: CGFloat {
        searchRowHeight + 10 + scopePickerHeight + 16
    }

    var body: some View {
        GeometryReader { geometry in
            albumContent(availableWidth: geometry.size.width + geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing)
        }
        .overlay {
            if loadingVisibilityChanged == nil {
                LoadingStateView(isLoading: !store.hasLoaded && store.errorMessage == nil, label: "Loading albums")
            }
        }
        .onChange(of: !store.hasLoaded && store.errorMessage == nil, initial: true) { _, loading in
            loadingVisibilityChanged?(loading)
        }
    }

    private func albumContent(availableWidth: CGFloat) -> some View {
        let columnCount = max(1, Int((availableWidth - 32 + 16) / (155 + 16)))
        let coverWidth = min(260, max(1, (availableWidth - 32 - CGFloat(columnCount - 1) * 16) / CGFloat(columnCount)))
        let displayedAlbums = showsList ? filtered : sort.gridOrder(filtered, columns: columnCount)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    if let error = store.errorMessage, !store.albums.isEmpty {
                        Button { Task { await store.load() } } label: {
                            Label(error, systemImage: "arrow.clockwise").font(.callout)
                        }.padding(.horizontal)
                    }
                    if !store.hasLoaded, store.errorMessage == nil {
                        Color.clear
                    } else if store.errorMessage != nil, !store.hasLoaded {
                        ErrorStateView(title: "Couldn’t Load Albums") { Task { await store.load() } }
                    } else if filtered.isEmpty {
                        ContentUnavailableView(
                            query.isEmpty ? (scope == .shared ? "No Shared Albums" : "No Albums") : "No Results",
                            systemImage: "rectangle.stack",
                            description: Text(query.isEmpty ? "Albums available to this account will appear here." : "Try another album name.")
                        )
                    } else {
                        LazyVGrid(columns: showsList ? [GridItem(.flexible())]
                            : Array(repeating: GridItem(.flexible(minimum: 155, maximum: 260), spacing: 16, alignment: .top), count: columnCount),
                            alignment: .leading, spacing: showsList ? 12 : 20)
                        {
                            ForEach(displayedAlbums) { album in albumLink(album, compact: showsList, coverWidth: coverWidth) }
                        }
                        .scrollTargetLayout()
                        .padding(.horizontal, 16)
                        .transition(.identity)
                    }
                }
                .padding(.vertical)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .ignoresSafeArea(.container, edges: .horizontal)
            // Like timeline Memories, compact chrome must not resize the viewport
            // or change the scroll clearance while the user is dragging.
            .contentMargins(.top, expandedHeaderHeight, for: .scrollContent)
            .contentMargins(.top, expandedHeaderHeight, for: .scrollIndicators)
            .scrollPosition(id: $visibleAlbumID, anchor: .center)
            .onAppear { listVisible = true }
            .onDisappear {
                listVisible = false
                reorderGeneration &+= 1
                isReordering = false
            }
            .onChange(of: scrollToLatestRequest) {
                guard listVisible, let lastID = displayedAlbums.last?.id else { return }
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) { proxy.scrollTo(lastID, anchor: .bottom) }
            }
            .onScrollPhaseChange { _, phase in
                userScrolling = phase == .interacting || phase == .decelerating
                if !userScrolling {
                    chromeTracker.scrollingEnded()
                }
            }
            .onScrollGeometryChange(for: AlbumScrollGeometry.self) {
                AlbumScrollGeometry(offset: max(0, $0.contentOffset.y + $0.contentInsets.top),
                                    topInset: $0.contentInsets.top, viewportHeight: $0.containerSize.height,
                                    contentHeight: $0.contentSize.height, bottomInset: $0.contentInsets.bottom)
            } action: { old, new in
                guard !searchFocused else { return }
                // Inset animations and lazy content measurement can rebase the
                // offset without a finger changing direction. They are layout,
                // not scroll travel, and must not reverse the header decision.
                guard let delta = new.scrollDelta(from: old) else {
                    chromeTracker.scrollingEnded()
                    return
                }
                // Match the bottom-anchored main timelines' scroll convention.
                if let hidden = chromeTracker.update(offsetDelta: delta, bottomGap: new.bottomGap,
                                                     userScrolling: userScrolling, programmaticJump: false)
                {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { searchHidden = hidden }
                }
            }
            .refreshable { await store.load() }
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Search Albums", text: $query)
                                .focused($searchFocused)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .submitLabel(.search)
                                .accessibilityIdentifier("albums-search")
                            if !query.isEmpty {
                                Button { query = "" } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Clear Search")
                            }
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .background(.quaternary, in: .capsule)
                        Menu {
                            Picker("Sort Albums", selection: Binding(get: { sort }, set: { updateAlbumLayout(sort: $0, direction: sortDirection) })) {
                                ForEach(AlbumSort.allCases) { Text($0.rawValue).tag($0) }
                            }
                            Divider()
                            Picker("Order", selection: Binding(get: { sortDirection }, set: { updateAlbumLayout(sort: sort, direction: $0) })) {
                                ForEach(AlbumSortDirection.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.inline)
                            Divider()
                            Toggle("List View", isOn: Binding(get: { showsList }, set: { updateAlbumLayout(sort: sort, direction: sortDirection, list: $0) }))
                        } label: {
                            Image(systemName: "arrow.up.arrow.down").frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .accessibilityLabel("Album Options")
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        guard height > 0, abs(searchRowHeight - height) > 0.5 else { return }
                        searchRowHeight = height
                    }
                    .frame(height: searchHidden ? 0 : searchRowHeight, alignment: .top)
                    .opacity(searchHidden ? 0 : 1)
                    .clipped()
                    .allowsHitTesting(!searchHidden)
                    .accessibilityHidden(searchHidden)
                    Picker("Album scope", selection: $scope) {
                        ForEach(AlbumScope.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        guard height > 0, abs(scopePickerHeight - height) > 0.5 else { return }
                        scopePickerHeight = height
                    }
                    .padding(.top, searchHidden ? 0 : 10)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background {
                    ZStack {
                        TimelineMemoryGradientBackdrop(visible: true, extended: true, reduceMotion: reduceMotion)
                            .ignoresSafeArea(edges: .top)
                        // The shared blur is noninteractive. Fill the gaps behind
                        // the controls so taps cannot reach album links below it.
                        Color.clear
                            .contentShape(.rect)
                            .onTapGesture {}
                            .accessibilityHidden(true)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .scrollDismissesKeyboard(.interactively)
            .task(id: activeEndpoint) { await store.load() }
            .navigationDestination(for: AlbumSummary.self) { album in
                AlbumDetailView(album: album, source: source, media: media, assetDetails: assetDetails,
                                activeEndpoint: activeEndpoint, scrollToLatestRequest: scrollToLatestRequest,
                                persistence: persistence, scope: accountScope,
                                timelineRuntime: timelineSessions.runtime(albumID: album.id, namespace: accountScope?.cacheNamespace ?? "unscoped"),
                                viewerPresentations: viewerPresentations,
                                tabSelectionState: tabSelectionState, tabBarTop: $tabBarTop, showAccount: showAccount)
                    .navigationTransition(.zoom(sourceID: album.id, in: albumTransition))
            }
            .accessibilityIdentifier("albums-root")
        }
    }

    private func albumLink(_ album: AlbumSummary, compact: Bool, coverWidth: CGFloat) -> some View {
        Button {
            guard !isReordering else { return }
            openAlbum(album)
        } label: {
            AlbumCard(album: album, media: media, compact: compact, sort: sort, persistence: persistence,
                      scope: accountScope, transitionNamespace: albumTransition, coverWidth: coverWidth)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!isReordering)
        .id(album.id)
        .transition(.identity)
        .accessibilityIdentifier("album-\(album.id)")
    }

    private func updateAlbumLayout(sort nextSort: AlbumSort, direction: AlbumSortDirection, list: Bool? = nil) {
        let nextList = list ?? showsList
        guard sort != nextSort || sortDirection != direction || showsList != nextList else { return }
        if sort != nextSort || sortDirection != direction {
            // A density change keeps the current album; sorting must not chase
            // that album to its new rank across the whole collection.
            visibleAlbumID = nil
        }
        reorderGeneration &+= 1
        let request = reorderGeneration
        isReordering = !reduceMotion
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.35), completionCriteria: .removed) {
            sort = nextSort
            sortDirection = direction
            showsList = nextList
            // The existing bottom anchor and scroll position own the viewport.
            // Do not co-animate another scroll request with album rearrangement.
        } completion: {
            guard reorderGeneration == request else { return }
            isReordering = false
        }
    }
}

private struct AlbumCard: View {
    let album: AlbumSummary
    let media: MediaLibraryController
    let compact: Bool
    let sort: AlbumSort
    let persistence: (any AlbumCatalogStoring)?
    let scope: MediaAccountScope?
    let transitionNamespace: Namespace.ID
    let coverWidth: CGFloat

    var body: some View {
        let layout = compact ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
        return layout {
            cover.frame(width: compact ? 72 : coverWidth, height: compact ? 72 : coverWidth * 0.75)
            labels
            if compact {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var labels: some View {
        VStack(alignment: .center, spacing: 4) {
            HStack(spacing: 4) {
                if album.isShared {
                    Image(systemName: "person.2.fill")
                        .accessibilityLabel("Shared album")
                }
                if let date = sort.date(in: album) {
                    Text("\(album.countLabel) · \(date.formatted(.dateTime.month(.abbreviated).day().year()))")
                } else {
                    Text(album.countLabel)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(1).minimumScaleFactor(0.85)
            Text(album.title).font(.headline).foregroundStyle(.primary)
                .lineLimit(2, reservesSpace: !compact)
                .multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity, alignment: .center)
    }

    private var cover: some View {
        AlbumCover(album: album, media: media, persistence: persistence, scope: scope)
            .clipShape(.rect(cornerRadius: compact ? 12 : DesignMetrics.defaultCornerRadius))
            .matchedTransitionSource(id: album.id, in: transitionNamespace) { source in
                source.clipShape(.rect(cornerRadius: compact ? 12 : DesignMetrics.defaultCornerRadius))
            }
    }
}

private struct AlbumCover: View {
    @Environment(\.displayScale) private var displayScale
    let album: AlbumSummary
    let media: MediaLibraryController

    let persistence: (any AlbumCatalogStoring)?
    let scope: MediaAccountScope?
    @State private var revision: Date?

    var body: some View {
        GeometryReader { geometry in
            let descriptor = album.thumbnailAssetID.flatMap { id in
                revision.map { MediaRequestDescriptor(assetID: id, updatedAt: $0, derivative: .thumbnail,
                                                      targetPixels: .init(width: Int(max(1, geometry.size.width) * displayScale),
                                                                          height: Int(max(1, geometry.size.height) * displayScale))) }
            }
            Group {
                if let descriptor {
                    ImmichThumbnail(descriptor: descriptor, media: media)
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay { Image(systemName: "rectangle.stack").foregroundStyle(.secondary) }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .accessibilityHidden(true)
        .task(id: "\(album.thumbnailAssetID ?? "none")|\(album.catalogRevision)") {
            guard let assetID = album.thumbnailAssetID else { return }
            let canonical: Date? = if let persistence, let scope {
                try? await persistence.albumCoverRevision(scope: scope, albumID: album.id, assetID: assetID)
            } else {
                nil
            }
            guard !Task.isCancelled else { return }
            revision = canonical ?? album.updatedAt
        }
    }
}

@MainActor
private final class AlbumTimelineSessions {
    private var runtimes: [String: [String: TimelineSemanticRuntime]] = [:]

    func runtime(albumID: String, namespace: String) -> TimelineSemanticRuntime {
        if let runtime = runtimes[namespace]?[albumID] {
            return runtime
        }
        let runtime = TimelineSemanticRuntime()
        runtimes[namespace, default: [:]][albumID] = runtime
        return runtime
    }
}

private struct AlbumDetailView: View {
    let album: AlbumSummary
    let source: any AlbumReading & TimelineReading
    let media: MediaLibraryController
    let assetDetails: any AssetDetailReading
    let activeEndpoint: URL?
    let scrollToLatestRequest: Int
    let timelineRuntime: TimelineSemanticRuntime
    let viewerPresentations: AssetViewerPresentationStore
    let tabSelectionState: NativeTabSelectionState
    @Binding var tabBarTop: CGFloat
    let showAccount: () -> Void
    @State private var detail: AlbumSummary
    @State private var store: PhotosTimelineStore
    @State private var reader: AlbumTimelineReader
    @State private var presentation = PhotosPresentationState(
        store: UserDefaultsPresentationPreferencesStore(key: "album-presentation-preferences")
    )
    @State private var path: [PhotosRangeRoute] = []
    @State private var metadataError: String?
    @State private var metadataReload = 0
    @State private var showsDetails = false

    init(album: AlbumSummary, source: any AlbumReading & TimelineReading, media: MediaLibraryController,
         assetDetails: any AssetDetailReading, activeEndpoint: URL?,
         scrollToLatestRequest: Int,
         persistence: (any AlbumCatalogStoring)?, scope: MediaAccountScope?,
         timelineRuntime: TimelineSemanticRuntime,
         viewerPresentations: AssetViewerPresentationStore, tabSelectionState: NativeTabSelectionState,
         tabBarTop: Binding<CGFloat>, showAccount: @escaping () -> Void)
    {
        self.album = album
        self.source = source
        self.media = media
        self.assetDetails = assetDetails
        self.activeEndpoint = activeEndpoint
        self.scrollToLatestRequest = scrollToLatestRequest
        self.timelineRuntime = timelineRuntime
        self.viewerPresentations = viewerPresentations
        self.tabSelectionState = tabSelectionState
        _tabBarTop = tabBarTop
        self.showAccount = showAccount
        _detail = State(initialValue: album)
        let reader = AlbumTimelineReader(source: source, albumID: album.id, revision: album.catalogRevision,
                                         persistence: persistence, scope: scope)
        _reader = State(initialValue: reader)
        _store = State(initialValue: PhotosTimelineStore(reader: reader))
    }

    var body: some View {
        PhotosView(store: store, presentation: presentation, media: media, assetDetails: assetDetails,
                   navigationPath: $path, tabBarTop: $tabBarTop, timelineRuntime: timelineRuntime,
                   scrollToLatestRequest: scrollToLatestRequest,
                   contentName: detail.title,
                   rootAccessibilityID: "album-assets-\(album.id)", collectionTitle: detail.title,
                   collectionSubtitle: detail.countLabel, collectionInfoAction: { showsDetails = true },
                   compactChromeChanged: { _ in }, tabSelectionState: tabSelectionState,
                   tabDestination: .albums, viewerPresentations: viewerPresentations, showAccount: showAccount)
            .sheet(isPresented: $showsDetails) {
                NavigationStack {
                    Form {
                        Section {
                            Text(detail.countLabel)
                            if let owner = detail.ownerName, !owner.isEmpty {
                                LabeledContent("Owner", value: owner)
                            }
                            if detail.isShared {
                                Label("Shared Album", systemImage: "person.2")
                            }
                            if !detail.description.isEmpty {
                                Text(detail.description)
                            }
                            LabeledContent("Updated", value: detail.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        }
                        if let metadataError {
                            Section {
                                Text(metadataError).foregroundStyle(.secondary)
                                Button("Retry Album Details") { metadataReload &+= 1 }
                            }
                        }
                    }
                    .navigationTitle(detail.title)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsDetails = false } } }
                }
                .presentationDetents([.medium, .large])
            }
            .task(id: "\(activeEndpoint?.absoluteString ?? "")|\(metadataReload)") {
                await store.load()
                guard !Task.isCancelled else { return }
                do {
                    let loaded = try await source.album(id: album.id)
                    guard !Task.isCancelled else { return }
                    detail = loaded
                    metadataError = nil
                    if await reader.needsRefresh(for: loaded.catalogRevision), !Task.isCancelled {
                        await store.refresh()
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    metadataError = error.localizedDescription
                }
            }
            .onChange(of: activeEndpoint) { _, endpoint in
                store.routeDidChange(isReachable: endpoint != nil)
            }
    }
}
