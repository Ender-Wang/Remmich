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
    let showAccount: () -> Void
    @State private var store: AlbumsStore
    @State private var scope: AlbumScope = .all
    @State private var query = ""
    @State private var sort: AlbumSort = .mostRecentPhoto
    @State private var sortDirection: AlbumSortDirection = .ascending
    @State private var showsList = false
    @State private var chromeTracker = PhotosChromeTracker()
    @State private var searchHidden = false
    @State private var searchRowHeight: CGFloat = 44
    @State private var scopePickerHeight: CGFloat = 32
    @State private var userScrolling = false
    @State private var listScrollPosition = ScrollPosition(edge: .bottom)
    @State private var listVisible = false
    @Namespace private var albumTransition
    @FocusState private var searchFocused: Bool

    init(source: any AlbumReading & TimelineReading, media: MediaLibraryController,
         assetDetails: any AssetDetailReading, activeEndpoint: URL?,
         scrollToLatestRequest: Int = 0,
         persistence: (any AlbumCatalogStoring)? = nil, scope: MediaAccountScope? = nil,
         viewerPresentations: AssetViewerPresentationStore, tabSelectionState: NativeTabSelectionState,
         tabBarTop: Binding<CGFloat>, loadingVisibilityChanged: ((Bool) -> Void)? = nil,
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
        return ScrollView {
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
                } else if showsList {
                    LazyVStack(spacing: 12) {
                        ForEach(filtered) { album in albumLink(album, compact: true) }
                    }.padding(.horizontal)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 155, maximum: 260), spacing: 16, alignment: .top), count: columnCount),
                              alignment: .leading, spacing: 20)
                    {
                        ForEach(sort.gridOrder(filtered, columns: columnCount)) { album in albumLink(album, compact: false) }
                    }.padding(.horizontal, 16)
                }
            }
            .padding(.vertical)
        }
        .defaultScrollAnchor(.bottom)
        .ignoresSafeArea(.container, edges: .horizontal)
        // Like timeline Memories, compact chrome must not resize the viewport
        // or change the scroll clearance while the user is dragging.
        .contentMargins(.top, expandedHeaderHeight, for: .scrollContent)
        .contentMargins(.top, expandedHeaderHeight, for: .scrollIndicators)
        .scrollPosition($listScrollPosition)
        .onAppear { listVisible = true }
        .onDisappear { listVisible = false }
        .onChange(of: sort) { listScrollPosition.scrollTo(edge: .bottom) }
        .onChange(of: sortDirection) { listScrollPosition.scrollTo(edge: .bottom) }
        .onChange(of: scrollToLatestRequest) {
            guard listVisible else { return }
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) { listScrollPosition.scrollTo(edge: .bottom) }
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
                        Picker("Sort Albums", selection: $sort) {
                            ForEach(AlbumSort.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Divider()
                        Picker("Order", selection: $sortDirection) {
                            ForEach(AlbumSortDirection.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.inline)
                        Divider()
                        Toggle("List View", isOn: $showsList)
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
                            viewerPresentations: viewerPresentations,
                            tabSelectionState: tabSelectionState, tabBarTop: $tabBarTop, showAccount: showAccount)
                .navigationTransition(.zoom(sourceID: album.id, in: albumTransition))
        }
        .accessibilityIdentifier("albums-root")
    }

    private func albumLink(_ album: AlbumSummary, compact: Bool) -> some View {
        NavigationLink(value: album) {
            AlbumCard(album: album, media: media, compact: compact, sort: sort, persistence: persistence,
                      scope: accountScope, transitionNamespace: albumTransition)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("album-\(album.id)")
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

    var body: some View {
        Group {
            if compact {
                HStack(spacing: 12) {
                    cover.frame(width: 72, height: 72)
                    labels
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    cover.aspectRatio(4 / 3, contentMode: .fit)
                    labels
                }
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

private struct AlbumDetailView: View {
    let album: AlbumSummary
    let source: any AlbumReading & TimelineReading
    let media: MediaLibraryController
    let assetDetails: any AssetDetailReading
    let activeEndpoint: URL?
    let scrollToLatestRequest: Int
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
         viewerPresentations: AssetViewerPresentationStore, tabSelectionState: NativeTabSelectionState,
         tabBarTop: Binding<CGFloat>, showAccount: @escaping () -> Void)
    {
        self.album = album
        self.source = source
        self.media = media
        self.assetDetails = assetDetails
        self.activeEndpoint = activeEndpoint
        self.scrollToLatestRequest = scrollToLatestRequest
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
                   navigationPath: $path, tabBarTop: $tabBarTop, scrollToLatestRequest: scrollToLatestRequest,
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
