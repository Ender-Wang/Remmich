import Observation
import SwiftUI
import UIKit

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

extension AlbumScrollGeometry {
    init(_ geometry: ScrollGeometry) {
        self.init(offset: max(0, geometry.contentOffset.y + geometry.contentInsets.top),
                  topInset: geometry.contentInsets.top, viewportHeight: geometry.containerSize.height,
                  contentHeight: geometry.contentSize.height, bottomInset: geometry.contentInsets.bottom)
    }
}

enum AlbumScope: String, CaseIterable, Identifiable {
    case all = "All"
    case shared = "Shared"
    var id: Self {
        self
    }
}

private enum AlbumDiscoveryScrollTarget: Hashable {
    case content
}

private nonisolated struct AlbumScopeContentGeometry: Equatable {
    let scope: String
    let height: CGFloat
}

private struct AlbumScopeCaptureKey: Equatable {
    let albums: [AlbumSummary]
    let query: String
    let sort: AlbumSort
    let direction: AlbumSortDirection
    let list: Bool
    let labelHeight: CGFloat
    let viewport: CGSize
}

struct AlbumsOpeningSkeleton: View {
    var body: some View {
        GeometryReader { geometry in
            let isPad = UIDevice.current.userInterfaceIdiom == .pad
            let metrics = AlbumReflowMetrics.overview(availableWidth: geometry.size.width, isPad: isPad)
            let coverHeight = metrics.coverWidth * 0.75
            let rows = max(1, Int(ceil(geometry.size.height / (coverHeight + 20))))
            VStack(alignment: .leading, spacing: 20) {
                ForEach(0 ..< rows, id: \.self) { _ in
                    HStack(spacing: AlbumReflowMetrics.columnSpacing) {
                        ForEach(0 ..< metrics.columns, id: \.self) { _ in
                            VStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: DesignMetrics.defaultCornerRadius).fill(.quaternary)
                                    .frame(width: metrics.coverWidth, height: coverHeight)
                                AlbumOpeningLabels(width: metrics.coverWidth)
                            }
                        }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, metrics.gridLeadingInset)
            .padding([.horizontal, .bottom], 16)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottomLeading)
            .clipped()
        }
        .ignoresSafeArea(.container, edges: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct AlbumOpeningScroll<Content: View>: View {
    let initialOffset: CGFloat?
    @ViewBuilder let content: Content
    @State private var position: ScrollPosition
    @State private var initialAnchor: UnitPoint

    init(initialOffset: CGFloat?, @ViewBuilder content: () -> Content) {
        self.initialOffset = initialOffset
        self.content = content()
        _position = State(initialValue: initialOffset.map { ScrollPosition(y: $0) } ?? ScrollPosition())
        _initialAnchor = State(initialValue: initialOffset == nil ? .bottom : .top)
    }

    var body: some View {
        ScrollView { content }
            .defaultScrollAnchor(initialAnchor, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .alignment)
            .scrollPosition($position)
            .onChange(of: initialOffset) { _, offset in
                guard let offset else { return }
                position.scrollTo(y: offset)
            }
    }
}

struct AlbumsView: View {
    private struct LoadRequest: Equatable {
        let endpoint: URL?
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.scenePhase) private var scenePhase
    private var headerMetrics = MainTabHeaderMetrics()
    let source: any AlbumReading & TimelineReading
    let media: MediaLibraryController
    let assetDetails: any AssetDetailReading
    let activeEndpoint: URL?
    let scrollToLatestRequest: Int
    private let browsing: AccountBrowsingState?
    let persistence: (any AlbumCatalogStoring)?
    let accountScope: MediaAccountScope?
    let viewerPresentations: AssetViewerPresentationStore
    let tabSelectionState: NativeTabSelectionState
    @Binding var tabBarTop: CGFloat
    @Binding private var navigationPath: NavigationPath
    let windowTopInset: CGFloat
    let showsLoadingOverlay: Bool
    let openingContentReady: () -> Void
    let openAlbum: (AlbumSummary, Bool) -> Void
    private let store: AlbumsStore
    @State private var scope: AlbumScope = .all
    @State private var contentScope: AlbumScope = .all
    @State private var query = ""
    @State private var sort: AlbumSort = .mostRecentPhoto
    @State private var sortDirection: AlbumSortDirection = .ascending
    @State private var isReordering = false
    @State private var reorderGeneration = 0
    @State private var showsList = false
    @State private var albumLayoutProgress: CGFloat = 0
    @State private var pinchSettling = false
    @State private var searchFocusRequest: UUID?
    @State private var albumLabelHeight: CGFloat?
    @State private var reflowCompletion = AlbumReflowCompletion()
    @State private var reflowViewport = AlbumReflowViewport()
    @State private var pinchInteraction = AlbumPinchInteraction()
    @State private var listVisible = false
    @State private var pendingBrowsingPosition: AlbumBrowsingPosition?
    @State private var hasOpenedGrid = false
    @State private var transitionAlbumID: String?
    @State private var navigationRoot = CardNavigationRoot()
    @Namespace private var albumTransition
    @State private var timelineSessions = AlbumTimelineSessions()
    @State private var scopeSlide = AlbumScopeSlide()
    @FocusState private var searchFocused: Bool
    private let headerControlSize = MainTabHeaderMetrics.controlSize
    private static let contentBottomPadding: CGFloat = 16

    init(store: AlbumsStore, source: any AlbumReading & TimelineReading, media: MediaLibraryController,
         assetDetails: any AssetDetailReading, activeEndpoint: URL?,
         scrollToLatestRequest: Int = 0,
         browsing: AccountBrowsingState? = nil,
         persistence: (any AlbumCatalogStoring)? = nil, scope: MediaAccountScope? = nil,
         viewerPresentations: AssetViewerPresentationStore, tabSelectionState: NativeTabSelectionState,
         tabBarTop: Binding<CGFloat>, navigationPath: Binding<NavigationPath>, windowTopInset: CGFloat,
         showsLoadingOverlay: Bool = true,
         openingContentReady: @escaping () -> Void,
         openAlbum: @escaping (AlbumSummary, Bool) -> Void)
    {
        self.source = source
        self.media = media
        self.assetDetails = assetDetails
        self.activeEndpoint = activeEndpoint
        self.scrollToLatestRequest = scrollToLatestRequest
        self.browsing = browsing
        _pendingBrowsingPosition = State(initialValue: browsing?.albumPosition)
        self.persistence = persistence
        accountScope = scope
        self.viewerPresentations = viewerPresentations
        self.tabSelectionState = tabSelectionState
        _tabBarTop = tabBarTop
        _navigationPath = navigationPath
        self.windowTopInset = windowTopInset
        self.showsLoadingOverlay = showsLoadingOverlay
        self.openingContentReady = openingContentReady
        self.openAlbum = openAlbum
        self.store = store
    }

    private var filtered: [AlbumSummary] {
        sort.sorted(store.albums.filter {
            (contentScope == .all || $0.isShared) && (query.isEmpty || $0.title.localizedStandardContains(query))
        }, direction: sortDirection)
    }

    private var isSearchExpanded: Bool {
        tabSelectionState.isAlbumSearchExpanded
    }

    private var canDismissSearchBySwipe: Bool {
        isSearchExpanded && listVisible && navigationPath.isEmpty && tabSelectionState.canActivateContent(in: .albums)
    }

    private var isBrowsingAllAlbums: Bool {
        contentScope == .all && query.isEmpty && !isSearchExpanded && navigationPath.isEmpty
    }

    private var topClearance: CGFloat {
        windowTopInset + headerMetrics.height
    }

    private var showsOpeningSkeleton: Bool {
        albumLabelHeight == nil || store.isWaitingForInitialContent || (!store.albums.isEmpty && !hasOpenedGrid)
    }

    var body: some View {
        GeometryReader { geometry in
            let viewportWidth = geometry.size.width
            let viewportHeight = geometry.size.height
            let isPad = UIDevice.current.userInterfaceIdiom == .pad
            let metrics = AlbumReflowMetrics.overview(availableWidth: viewportWidth, isPad: isPad, labelHeight: albumLabelHeight ?? 58)
            ZStack {
                if showsOpeningSkeleton {
                    AlbumsOpeningSkeleton()
                        .transition(.opacity)
                }
                if albumLabelHeight != nil, !store.isWaitingForInitialContent {
                    albumContent(metrics: metrics, viewportHeight: viewportHeight)
                        .opacity(showsOpeningSkeleton ? 0 : 1)
                        .allowsHitTesting(!showsOpeningSkeleton)
                        .accessibilityHidden(showsOpeningSkeleton)
                }
            }
            .animation(RemmichLoadingOverlay.fadeAnimation(presenting: showsOpeningSkeleton, reduceMotion: reduceMotion),
                       value: showsOpeningSkeleton)
            .frame(width: viewportWidth)
            .overlay(alignment: .top) {
                albumHeader(metrics: metrics)
                    .allowsHitTesting(!showsOpeningSkeleton)
            }
            .overlay(alignment: .topLeading) {
                AlbumOpeningLabels(width: metrics.coverWidth)
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) {
                        viewportWidth > 0 && viewportHeight > 0 ? $0.size.height : 0
                    } action: { height in
                        guard height > 0 else { return }
                        if let albumLabelHeight, abs(albumLabelHeight - height) <= 0.01 {
                            return
                        }
                        albumLabelHeight = height
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        // The navigation container can change its top safe area as a prepared
        // tab attaches. Use the window inset for this overview's layout.
        .ignoresSafeArea(.container, edges: .top)
        .scrollDismissesKeyboard(.interactively)
        .overlay {
            if showsLoadingOverlay {
                LoadingStateView(isLoading: showsOpeningSkeleton, label: "Loading albums")
            }
        }
        .onChange(of: showsOpeningSkeleton, initial: true) { _, loading in
            if !loading {
                openingContentReady()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task(id: tabSelectionState.selection == .albums ? LoadRequest(endpoint: activeEndpoint) : nil) {
            guard tabSelectionState.selection == .albums else { return }
            await store.load()
        }
        .navigationDestination(for: AlbumSummary.self) { album in
            AlbumDetailView(album: album, source: source, media: media, assetDetails: assetDetails,
                            activeEndpoint: activeEndpoint, scrollToLatestRequest: scrollToLatestRequest,
                            persistence: persistence, scope: accountScope,
                            timelineRuntime: timelineSessions.runtime(albumID: album.id, namespace: accountScope?.cacheNamespace ?? "unscoped"),
                            viewerPresentations: viewerPresentations,
                            tabSelectionState: tabSelectionState, tabBarTop: $tabBarTop)
                .cardNavigationDestination(id: album.id, in: albumTransition)
                .cardNavigationBack(path: $navigationPath)
        }
        .accessibilityIdentifier("albums-root")
        .environment(\.thumbnailRevealsActive, tabSelectionState.canRevealThumbnails(in: .albums))
        .background { CardNavigationRootAnchor(root: navigationRoot).allowsHitTesting(false) }
        .onChange(of: tabSelectionState.selection) { _, current in
            if current != .albums {
                dismissSearch(animated: false)
            }
            cancelAlbumReflow()
            scopeSlide.cancel(clearCache: true)
        }
        .gesture(AlbumSearchDismissSwipe(enabled: canDismissSearchBySwipe, dismiss: dismissSearchBySwipe))
        .nativeEdgeBackAction(active: canDismissSearchBySwipe, animatesContent: false, action: dismissSearchBySwipe)
    }

    private func albumContent(metrics: AlbumReflowMetrics, viewportHeight: CGFloat) -> some View {
        let request = reorderGeneration
        let albums = filtered
        let openingHeight = metrics.height(count: albums.count, list: showsList)
        let openingExtent = max(0, viewportHeight) * CGFloat(TimelineGridOrder.openingScreenCount)
        let bookmarkIndex = pendingBrowsingPosition.flatMap { saved in albums.firstIndex { $0.id == saved.albumID } }
        let openingEnd = bookmarkIndex.map {
            min(openingHeight, metrics.frame(at: $0, count: albums.count, list: showsList).midY + openingExtent / 2)
        } ?? openingHeight
        let openingStart = openingEnd - openingExtent
        let openingOffset = hasOpenedGrid ? nil : bookmarkIndex.flatMap { index in
            pendingBrowsingPosition.map { position in
                metrics.openingOffset(at: index, count: albums.count, list: showsList, fraction: CGFloat(position.viewportFraction),
                                      viewportHeight: viewportHeight, topClearance: topClearance, bottomPadding: Self.contentBottomPadding)
            }
        }
        return ScrollViewReader { proxy in
            AlbumOpeningScroll(initialOffset: openingOffset) {
                VStack(spacing: 16) {
                    if store.errorMessage != nil, !store.hasLoaded {
                        ErrorStateView(title: "Couldn’t Load Albums") { Task { await store.load() } }
                    } else if albums.isEmpty {
                        ContentUnavailableView(
                            query.isEmpty ? (contentScope == .shared ? "No Shared Albums" : "No Albums") : "No Results",
                            systemImage: "rectangle.stack",
                            description: Text(query.isEmpty ? "Albums available to this account will appear here." : "Try another album name.")
                        )
                    } else {
                        AlbumReflowLayout(progress: albumLayoutProgress, metrics: metrics) {
                            ForEach(Array(albums.enumerated()), id: \.element.id) { index, album in
                                let frame = metrics.frame(at: index, count: albums.count, list: showsList)
                                albumLink(album, compact: showsList, progress: albumLayoutProgress,
                                          metrics: metrics, proxy: proxy, generation: request,
                                          initiallyMounted: frame.maxY > openingStart && frame.minY < openingEnd)
                            }
                        }
                        .gesture(AlbumPinchGesture(enabled: listVisible && !voiceOverEnabled,
                                                   canBegin: { canBeginAlbumPinch(at: $0) },
                                                   canReceive: { canReceiveAlbumPinch(at: $0) },
                                                   newInputBegan: { pinchInteraction.prepareForNewInput() },
                                                   update: { state, magnification, location in
                                                       handleAlbumPinch(state: state, magnification: magnification,
                                                                        location: location, metrics: metrics)
                                                   }))
                        .scrollTargetLayout()
                        .padding(.horizontal, 16)
                        .transition(.identity)
                        .transaction { transaction in
                            guard reflowCompletion.claim(request) else { return }
                            transaction.addAnimationCompletion(criteria: .removed) {
                                guard reorderGeneration == request, !pinchInteraction.isActive else { return }
                                isReordering = false
                                pinchSettling = false
                            }
                        }
                        .animation(isReordering && !pinchInteraction.isActive && !reduceMotion ? .smooth(duration: 0.35) : nil, value: request)
                    }
                }
                .padding(.bottom, Self.contentBottomPadding)
                // Count header clearance in the scroll extent from the first
                // layout, so attachment cannot rebase the bottom offset.
                .padding(.top, topClearance)
                .onGeometryChange(for: AlbumScopeContentGeometry.self) { [scopeName = contentScope.rawValue] geometry in
                    AlbumScopeContentGeometry(scope: scopeName, height: geometry.size.height)
                } action: { scopeSlide.contentChanged($0) }
                .background { AlbumScopeSlideAnchor(slide: scopeSlide) }
                // Explicit bottom requests include the trailing clearance.
                // This stable target installs no content-resize anchoring.
                .id(AlbumDiscoveryScrollTarget.content)
            }
            .scrollDisabled(pinchInteraction.isActive)
            .contentMargins(.top, topClearance, for: .scrollIndicators)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                reflowViewport.frame = frame
            }
            .onAppear {
                if contentScope != scope, !scopeSlide.isActive {
                    contentScope = scope
                }
                listVisible = true
            }
            .onDisappear {
                listVisible = false
                searchFocusRequest = nil
                searchFocused = false
                cancelAlbumReflow()
                scopeSlide.cancel(clearCache: true)
                // Navigation retains this ScrollView. Geometry callbacks report
                // changes, so an unchanged frame is not sent again on return.
                // Keep its measured geometry; visibility gates input while hidden.
            }
            .onChange(of: scrollToLatestRequest) {
                guard listVisible, !albums.isEmpty else { return }
                pendingBrowsingPosition = nil
                if isBrowsingAllAlbums {
                    browsing?.saveAlbumPosition(nil)
                }
                cancelAlbumReflow()
                scopeSlide.cancel(clearCache: true)
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) { proxy.scrollTo(AlbumDiscoveryScrollTarget.content, anchor: .bottom) }
            }
            .onScrollPhaseChange { previous, phase, context in
                if phase == .interacting, !pinchInteraction.isActive {
                    pendingBrowsingPosition = nil
                    reflowViewport.cancelMotion()
                }
                if phase == .idle, previous == .interacting || previous == .decelerating {
                    saveBrowsingPosition(albums: albums, geometry: AlbumScrollGeometry(context.geometry))
                }
            }
            .onScrollGeometryChange(for: AlbumScrollGeometry.self, of: AlbumScrollGeometry.init) { old, new in
                guard new.viewportHeight > 0 else { return }
                scopeSlide.scrollChanged(scope: contentScope.rawValue, geometry: new)
                if old.viewportHeight != new.viewportHeight || old.topInset != new.topInset || old.bottomInset != new.bottomInset {
                    cancelAlbumReflow()
                }
                // Reflow gestures still use the viewport below the
                // header, even though the reserved space is now in the content.
                reflowViewport.visibleHeight = max(0, new.viewportHeight - topClearance)
                if !hasOpenedGrid, !albums.isEmpty, openingOffset.map({ abs($0 - new.offset) <= 1 }) ?? true {
                    hasOpenedGrid = true
                }
            }
            .refreshable { await store.load() }
            .overlay(alignment: .top) {
                if let error = store.errorMessage, !store.albums.isEmpty {
                    Button { Task { await store.load() } } label: {
                        Label(error, systemImage: "arrow.clockwise")
                            .font(.callout)
                            .padding(8)
                            .background(.regularMaterial, in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
                    .padding(.top, topClearance)
                }
            }
            .onChange(of: contentScope) {
                cancelAlbumReflow()
                // A scope is a new collection. Sort/mode changes continue to
                // use their existing viewport and touched-album policies.
                withTransaction(Transaction(animation: nil)) {
                    proxy.scrollTo(AlbumDiscoveryScrollTarget.content, anchor: .bottom)
                }
                scopeSlide.start()
            }
            .onChange(of: Set(albums.map(\.id))) { _, _ in
                cancelAlbumReflow()
            }
            .onChange(of: metrics) { _, _ in
                cancelAlbumReflow()
                scopeSlide.cancel(clearCache: true)
            }
            .onChange(of: reduceMotion) { _, _ in
                cancelAlbumReflow()
                scopeSlide.cancel(clearCache: true)
            }
            .onChange(of: voiceOverEnabled) { _, _ in
                cancelAlbumReflow()
                scopeSlide.cancel(clearCache: true)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    scopeSlide.cancel(clearCache: true)
                } else if contentScope != scope {
                    contentScope = scope
                }
            }
            .onChange(of: query) { _, _ in scopeSlide.cancel(clearCache: true) }
            .onChange(of: store.albums) { _, _ in scopeSlide.cancel(clearCache: true) }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                scopeSlide.cancel(clearCache: true)
            }
            .onChange(of: scopeSlide.phase) { _, new in
                // Cached viewport motion gets its own render pass. Building
                // All's live card tree must not delay its first visible frame.
                if new == .installing || new == .idle, contentScope != scope {
                    withTransaction(Transaction(animation: nil)) { contentScope = scope }
                }
            }
            .allowsHitTesting(!scopeSlide.isActive)
            .overlay {
                AlbumScopeSlideHost(slide: scopeSlide)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.container, edges: .top)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .animation(nil, value: isSearchExpanded)
        }
        .id(!hasOpenedGrid && albums.isEmpty)
    }

    private func albumHeader(metrics: AlbumReflowMetrics) -> some View {
        let spacing: CGFloat = 12
        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        return GeometryReader { geometry in
            let searchWidth = isSearchExpanded ? max(headerControlSize, geometry.size.width - headerControlSize - spacing) : headerControlSize
            let scopeWidth = min(MainTabHeaderMetrics.segmentedControlMaximumWidth,
                                 max(0, geometry.size.width - 2 * (headerControlSize + spacing)))
            ZStack(alignment: .leading) {
                NativeSegmentedControl(selection: Binding(get: { scope }, set: selectAlbumScope),
                                       accessibilityIdentifier: "albums-scope")
                    .frame(width: isPhone ? nil : scopeWidth, height: headerMetrics.rowHeight)
                    .glassEffect(.regular, in: .capsule)
                    .fixedSize(horizontal: isPhone, vertical: false)
                    .frame(maxWidth: .infinity)
                    .opacity(isSearchExpanded ? 0 : 1)
                    .animation(scopeVisibilityAnimation, value: isSearchExpanded)
                    .allowsHitTesting(!isSearchExpanded && !scopeSlide.isActive)
                    .accessibilityHidden(isSearchExpanded)

                HStack(spacing: 0) {
                    searchControl(width: searchWidth)
                    Spacer(minLength: spacing)
                    albumOptions(metrics: metrics)
                }
                .allowsHitTesting(!scopeSlide.isActive)
            }
        }
        .frame(height: headerMetrics.rowHeight)
        .padding(.horizontal, MainTabHeaderMetrics.horizontalPadding)
        .padding(.top, windowTopInset + MainTabHeaderMetrics.topPadding)
        .padding(.bottom, MainTabHeaderMetrics.bottomPadding)
        .background {
            ZStack {
                TimelineMemoryGradientBackdrop(visible: true, extended: true, reduceMotion: reduceMotion)
                    .ignoresSafeArea(.container, edges: [.top, .horizontal])
                // Fill the gaps between controls so taps cannot open albums underneath.
                Color.clear
                    .contentShape(.rect)
                    .onTapGesture {}
                    .accessibilityHidden(true)
            }
        }
    }

    private var scopeVisibilityAnimation: Animation? {
        guard !reduceMotion, tabSelectionState.selection == .albums else { return nil }
        // The search field covers the selector until it starts to contract.
        return isSearchExpanded ? .easeOut(duration: 0.18) : .easeInOut(duration: 0.22).delay(0.12)
    }

    private func searchControl(width: CGFloat) -> some View {
        let focusRequest = searchFocusRequest
        return HStack(spacing: 0) {
            Button {
                if isSearchExpanded {
                    dismissSearch()
                } else {
                    expandSearch()
                }
            } label: {
                Image(systemName: isSearchExpanded ? "xmark" : "magnifyingglass")
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    .frame(width: headerControlSize, height: headerControlSize)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(isSearchExpanded ? "Close Search" : "Search Albums"))
            .accessibilityIdentifier(isSearchExpanded ? "albums-search-close-button" : "albums-search-button")

            if isSearchExpanded {
                TextField("Search Albums", text: $query)
                    .focused($searchFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .accessibilityIdentifier("albums-search")
                    .padding(.trailing, 16)
                    .transition(.opacity)
                    .task(id: focusRequest) {
                        guard let focusRequest, searchFocusRequest == focusRequest, canDismissSearchBySwipe, !Task.isCancelled else { return }
                        searchFocusRequest = nil
                        searchFocused = true
                    }
            }
        }
        .frame(width: width, height: isSearchExpanded ? headerMetrics.rowHeight : headerControlSize, alignment: .leading)
        .clipped()
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private func albumOptions(metrics: AlbumReflowMetrics) -> some View {
        Menu {
            Picker("Sort Albums", selection: Binding(get: { sort }, set: { updateAlbumLayout(sort: $0, direction: sortDirection, metrics: metrics) })) {
                ForEach(AlbumSort.allCases) { Text($0.rawValue).tag($0) }
            }
            Divider()
            Picker("Order", selection: Binding(get: { sortDirection }, set: { updateAlbumLayout(sort: sort, direction: $0, metrics: metrics) })) {
                ForEach(AlbumSortDirection.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("List View", isOn: Binding(get: { showsList }, set: { updateAlbumLayout(sort: sort, direction: sortDirection, list: $0, metrics: metrics) }))
        } label: {
            Image(systemName: "arrow.up.arrow.down").frame(width: headerControlSize, height: headerControlSize)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Album Options")
    }

    private func saveBrowsingPosition(albums: [AlbumSummary], geometry: AlbumScrollGeometry) {
        guard let browsing, listVisible, isBrowsingAllAlbums, tabSelectionState.canActivateContent(in: .albums),
              !scopeSlide.isActive, !isReordering, !pinchInteraction.isActive else { return }
        if geometry.bottomGap < 24 {
            browsing.saveAlbumPosition(nil)
        } else if let anchor = reflowViewport.anchor(in: albums.map(\.id)) {
            browsing.saveAlbumPosition(.init(albumID: anchor.albumID, viewportFraction: Double(anchor.unitY)))
        }
    }

    private func expandSearch() {
        guard !isSearchExpanded, !scopeSlide.isActive, tabSelectionState.canActivateContent(in: .albums) else { return }
        cancelAlbumReflow()
        searchFocusRequest = UUID()
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
            tabSelectionState.isAlbumSearchExpanded = true
        }
    }

    private func dismissSearch(animated: Bool = true) {
        guard isSearchExpanded else { return }
        searchFocusRequest = nil
        searchFocused = false
        query = ""
        withAnimation(animated && !reduceMotion ? .smooth(duration: 0.3) : nil) {
            tabSelectionState.isAlbumSearchExpanded = false
        }
    }

    private func dismissSearchBySwipe() {
        guard canDismissSearchBySwipe else { return }
        dismissSearch()
    }

    private func albumLink(_ album: AlbumSummary, compact: Bool, progress: CGFloat, metrics: AlbumReflowMetrics,
                           proxy: ScrollViewProxy, generation: Int, initiallyMounted: Bool) -> some View
    {
        Button { activateAlbum(album) } label: {
            AlbumCard(album: album, media: media, compact: compact, progress: progress, sort: sort, persistence: persistence,
                      scope: accountScope, transitionNamespace: albumTransition, coverWidth: metrics.coverWidth,
                      listWidth: metrics.width, isReordering: isReordering, initiallyMounted: initiallyMounted,
                      keepsTransitionSource: transitionAlbumID == album.id, coverRevision: store.coverRevisions[album.id],
                      coverVisible: {
                          if listVisible, tabSelectionState.selection == .albums {
                              store.openingCoverVisible()
                          }
                      })
                      // Retain the accepted inner text/layout endpoints. The outer
                      // wrapper reports the current animated proposal to scrolling.
                      .frame(height: metrics.itemSize(progress: progress).height, alignment: .top)
                      .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        }
        .buttonStyle(.plain)
        // Resolve each album's movement before drawing its descendants. Without
        // this boundary, sort interpolation can span far-apart text positions
        // in multi-thousand-point drawing surfaces across the scroll content.
        .geometryGroup()
        .allowsHitTesting(!isReordering || pinchInteraction.isActive || pinchSettling)
        .id(album.id)
        .transition(.identity)
        .onGeometryChange(for: AlbumReflowItemGeometry.self) {
            AlbumReflowItemGeometry(frame: $0.frame(in: .global), size: $0.size)
        } action: { geometry in
            guard generation == reorderGeneration else { return }
            reflowViewport.items[album.id] = geometry.frame
            if let anchor = reflowViewport.consumeMotionSample(albumID: album.id, size: geometry.size, generation: generation) {
                let alignment = anchor.alignment(for: geometry.size.height, topClearance: topClearance)
                withTransaction(Transaction(animation: nil)) {
                    proxy.scrollTo(anchor.albumID, anchor: UnitPoint(x: 0.5, y: alignment))
                }
            }
        }
        .onDisappear { reflowViewport.items[album.id] = nil }
        .accessibilityIdentifier("album-\(album.id)")
        .accessibilityAction { activateAlbum(album, accessibility: true) }
    }

    private func selectAlbumScope(_ next: AlbumScope) {
        guard scope != next, !scopeSlide.isActive else { return }
        let canCacheSource = !isReordering && !pinchInteraction.isActive
        cancelAlbumReflow()
        withTransaction(Transaction(animation: nil)) {
            if !reduceMotion, listVisible, store.hasLoaded, let albumLabelHeight {
                let viewport = reflowViewport.usableFrame
                scopeSlide.prepare(current: contentScope.rawValue, target: next.rawValue,
                                   key: AlbumScopeCaptureKey(albums: store.albums, query: query, sort: sort,
                                                             direction: sortDirection, list: showsList,
                                                             labelHeight: albumLabelHeight, viewport: viewport.size),
                                   cacheSource: canCacheSource, viewport: viewport,
                                   direction: next == .shared ? .next : .previous)
                scopeSlide.start()
            }
            scope = next
            // Cache misses still prepare new content behind the outgoing image.
            // A cache hit already has all pixels needed for the entire slide.
            if !scopeSlide.isActive || !scopeSlide.hasPreparedIncoming {
                contentScope = next
            }
        }
    }

    private func activateAlbum(_ album: AlbumSummary, accessibility: Bool = false) {
        guard !isReordering, !pinchInteraction.isActive, !scopeSlide.isActive,
              accessibility || !pinchInteraction.blocksAlbumActivation
        else { return }
        transitionAlbumID = album.id
        searchFocusRequest = nil
        searchFocused = false
        openAlbum(album, navigationRoot.isSettledRoot)
    }

    private func updateAlbumLayout(sort nextSort: AlbumSort, direction: AlbumSortDirection, list: Bool? = nil,
                                   metrics: AlbumReflowMetrics)
    {
        let nextList = list ?? showsList
        guard sort != nextSort || sortDirection != direction || showsList != nextList else { return }
        pinchInteraction.end(cancelled: true)
        let changesSort = sort != nextSort || sortDirection != direction
        let anchor = showsList != nextList && !changesSort ? reflowViewport.anchor(in: filtered.map(\.id)) : nil
        withTransaction(Transaction(animation: nil)) {
            reorderGeneration &+= 1
            pinchSettling = false
            let destination = metrics.itemSize(progress: nextList ? 1 : 0)
            reflowViewport.beginMotion(anchor: anchor, destinationSize: destination, generation: reorderGeneration)
            isReordering = !reduceMotion
            sort = nextSort
            sortDirection = direction
            showsList = nextList
            albumLayoutProgress = nextList ? 1 : 0
            // Only the album layout installs animation. Its selected item's
            // actual size drives anchoring; completion never requests scrolling.
        }
    }

    private func cancelAlbumReflow() {
        withTransaction(Transaction(animation: nil)) {
            pinchInteraction.end(cancelled: true)
            reflowViewport.cancelMotion()
            guard isReordering || pinchSettling || albumLayoutProgress != (showsList ? 1 : 0) else { return }
            reorderGeneration &+= 1
            isReordering = false
            pinchSettling = false
            albumLayoutProgress = showsList ? 1 : 0
        }
    }

    private func canReceiveAlbumPinch(at point: CGPoint) -> Bool {
        listVisible && !scopeSlide.isActive && tabSelectionState.canActivateContent(in: .albums)
            && reflowViewport.usableFrame.contains(point)
    }

    private func canBeginAlbumPinch(at point: CGPoint) -> Bool {
        canReceiveAlbumPinch(at: point) && store.hasLoaded && !filtered.isEmpty
            && (!isReordering || pinchSettling) && !searchFocused && !voiceOverEnabled && !pinchInteraction.isActive
    }

    private func handleAlbumPinch(state: UIGestureRecognizer.State, magnification: CGFloat, location: CGPoint, metrics: AlbumReflowMetrics) {
        switch state {
        case .began:
            guard canBeginAlbumPinch(at: location),
                  let anchor = reflowViewport.anchor(in: filtered.map(\.id), at: location) else { return }
            let progress = pinchSettling ? metrics.progress(for: anchor.itemFrame.size) ?? albumLayoutProgress : albumLayoutProgress
            withTransaction(Transaction(animation: nil)) {
                reorderGeneration &+= 1
                pinchSettling = false
                isReordering = true
                albumLayoutProgress = progress
                reflowViewport.beginMotion(anchor: anchor, destinationSize: nil, generation: reorderGeneration)
                pinchInteraction.begin(showsList: showsList, anchor: anchor, progress: progress)
            }
        case .changed, .ended:
            guard listVisible, tabSelectionState.canActivateContent(in: .albums), !searchFocused, !voiceOverEnabled else {
                cancelAlbumReflow()
                return
            }
            if let progress = pinchInteraction.update(magnification: magnification), !reduceMotion {
                withTransaction(Transaction(animation: nil)) {
                    albumLayoutProgress = progress
                }
            }
            if state == .ended {
                finishAlbumPinch(metrics: metrics, cancelled: false)
            }
        case .cancelled, .failed:
            finishAlbumPinch(metrics: metrics, cancelled: true)
        default:
            break
        }
    }

    private func finishAlbumPinch(metrics: AlbumReflowMetrics, cancelled: Bool) {
        guard let result = pinchInteraction.end(cancelled: cancelled) else { return }
        guard filtered.contains(where: { $0.id == result.anchor.albumID }) else {
            cancelAlbumReflow()
            return
        }
        withTransaction(Transaction(animation: nil)) {
            reorderGeneration &+= 1
            let target: CGFloat = result.list ? 1 : 0
            pinchSettling = !reduceMotion && abs(albumLayoutProgress - target) > 0.001
            isReordering = pinchSettling
            showsList = result.list
            reflowViewport.finishInteractiveMotion(destinationSize: metrics.itemSize(progress: target), generation: reorderGeneration)
            albumLayoutProgress = target
        }
    }
}

/// Local viewport wiring; both album scopes and root pages use the same animator.
@MainActor
@Observable
private final class AlbumScopeSlide {
    enum Phase: String { case idle, preparing, animating, installing }
    private(set) var phase = Phase.idle
    var isActive: Bool {
        phase != .idle
    }

    var hasPreparedIncoming: Bool {
        capturedIncoming
    }

    @ObservationIgnored weak var anchor: UIView?
    @ObservationIgnored weak var stageHost: UIView?
    @ObservationIgnored private weak var scrollView: UIScrollView?
    @ObservationIgnored private var cover: UIView?
    @ObservationIgnored private var outgoing: UIView?
    @ObservationIgnored private var incoming: UIView?
    @ObservationIgnored private var animator: UIViewPropertyAnimator?
    @ObservationIgnored private var targetScope = ""
    @ObservationIgnored private var capturedIncoming = false
    @ObservationIgnored private var cachedViewports: [String: UIView] = [:]
    @ObservationIgnored private var cacheKey: AlbumScopeCaptureKey?
    @ObservationIgnored private var cacheStyle = UIUserInterfaceStyle.unspecified
    @ObservationIgnored private var readinessTimeout: Task<Void, Never>?
    @ObservationIgnored private var contentGeometry: AlbumScopeContentGeometry?
    @ObservationIgnored private var scrollGeometry: AlbumScrollGeometry?
    @ObservationIgnored private var direction = NativeTabPageDirection.next
    @ObservationIgnored private var generation = 0

    var scrollViewContainingAnchor: UIScrollView? {
        var ancestor = anchor?.superview
        while let view = ancestor, !(view is UIScrollView) {
            ancestor = view.superview
        }
        return ancestor as? UIScrollView
    }

    func prepare(current: String, target: String, key: AlbumScopeCaptureKey,
                 cacheSource: Bool, viewport: CGRect, direction: NativeTabPageDirection)
    {
        cancel()
        guard let scroll = scrollViewContainingAnchor,
              let window = scroll.window, let stageHost, stageHost.window === window,
              !stageHost.isDescendant(of: scroll),
              !stageHost.bounds.isEmpty, !viewport.isEmpty else { return }
        if cacheKey != key || cacheStyle != scroll.traitCollection.userInterfaceStyle {
            cachedViewports.removeAll()
            cacheKey = key
            cacheStyle = scroll.traitCollection.userInterfaceStyle
        }
        // Use UIKit's current frame; a root transition can leave SwiftUI's
        // last global x-coordinate offscreen until its next geometry callback.
        let nativeFrame = scroll.convert(scroll.bounds, to: window)
        let bottom = nativeFrame.maxY - scroll.adjustedContentInset.bottom
        // Keep the real header above both pages. Its material must sample the
        // sliding content under it, including the region above the album rows.
        let top = nativeFrame.minY
        let nativeViewport = CGRect(x: nativeFrame.minX, y: top,
                                    width: nativeFrame.width, height: bottom - top)
        let crop = scroll.convert(nativeViewport, from: window).intersection(scroll.bounds)
        guard !crop.isEmpty,
              let captured = scroll.resizableSnapshotView(from: crop, afterScreenUpdates: false, withCapInsets: .zero)
        else { return }
        let container = UIView(frame: scroll.convert(crop, to: stageHost))
        container.clipsToBounds = true
        container.isUserInteractionEnabled = false
        container.accessibilityElementsHidden = true
        let resolved = scroll.backgroundColor?.resolvedColor(with: scroll.traitCollection)
        let background: UIColor = if let resolved, resolved.cgColor.alpha == 1 {
            resolved
        } else {
            UIColor.systemBackground.resolvedColor(with: scroll.traitCollection)
        }
        container.backgroundColor = background
        container.isOpaque = true
        let from = UIView(frame: container.bounds)
        let to = UIView(frame: container.bounds)
        from.backgroundColor = background
        to.backgroundColor = background
        from.isOpaque = true
        to.isOpaque = true
        from.isUserInteractionEnabled = false
        to.isUserInteractionEnabled = false
        from.accessibilityElementsHidden = true
        to.accessibilityElementsHidden = true
        to.isHidden = true
        captured.frame = CGRect(origin: .zero, size: crop.size)
        captured.isUserInteractionEnabled = false
        captured.accessibilityElementsHidden = true
        from.addSubview(captured)
        let nativeBottom = max(-scroll.adjustedContentInset.top,
                               scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
        if cacheSource, abs(scroll.contentOffset.y - nativeBottom) < 1 {
            cachedViewports[current] = captured
        }
        let cached = cachedViewports[target]
        if let cached, cached.bounds.size == crop.size {
            cached.frame = to.bounds
            to.addSubview(cached)
            capturedIncoming = true
        } else {
            capturedIncoming = false
        }
        container.addSubview(from)
        container.addSubview(to)
        stageHost.addSubview(container)
        cover = container
        outgoing = from
        incoming = to
        scrollView = scroll
        targetScope = target
        self.direction = direction
        phase = .preparing
        armTimeout(for: .preparing)
    }

    func start() {
        guard phase == .preparing, capturedIncoming, let outgoing, let incoming else { return }
        readinessTimeout?.cancel()
        readinessTimeout = nil
        let request = generation
        // UIKit animates only owned viewport stages. SwiftUI can install the
        // incoming collection behind them without rebasing an animated view.
        let animation = NativePageSlideAnimation.makeAnimator(from: outgoing, to: incoming,
                                                              direction: direction, width: outgoing.bounds.width)
        incoming.isHidden = false
        animation.addCompletion { [weak self] _ in
            guard let self, generation == request else { return }
            beginInstallation()
        }
        animator = animation
        phase = .animating
        animation.startAnimation()
    }

    func contentChanged(_ value: AlbumScopeContentGeometry) {
        if phase == .installing, value.scope != targetScope {
            return
        }
        contentGeometry = value
        if let scrollGeometry {
            _ = finishInstallation(scope: value.scope, geometry: scrollGeometry)
                || captureIncoming(scope: value.scope, geometry: scrollGeometry)
        }
    }

    func scrollChanged(scope: String, geometry: AlbumScrollGeometry) {
        scrollGeometry = geometry
        _ = finishInstallation(scope: scope, geometry: geometry) || captureIncoming(scope: scope, geometry: geometry)
    }

    private func nativeContentIsReady(scope: String, geometry: AlbumScrollGeometry) -> Bool {
        guard isActive, scope == targetScope,
              let contentGeometry, contentGeometry.scope == scope,
              abs(contentGeometry.height - geometry.contentHeight) < 1,
              let scrollView,
              abs(scrollView.contentSize.height - geometry.contentHeight) < 1,
              abs(scrollView.adjustedContentInset.top - geometry.topInset) < 1,
              abs(scrollView.adjustedContentInset.bottom - geometry.bottomInset) < 1,
              abs(max(0, scrollView.contentOffset.y + scrollView.adjustedContentInset.top) - geometry.offset) < 1,
              abs(geometry.offset - max(0, geometry.contentHeight - geometry.viewportHeight)) < 1
        else { return false }
        return true
    }

    private func captureIncoming(scope: String, geometry: AlbumScrollGeometry) -> Bool {
        guard phase == .preparing, !capturedIncoming, nativeContentIsReady(scope: scope, geometry: geometry),
              let scrollView, let cover, let incoming else { return false }
        capturedIncoming = true
        let crop = scrollView.convert(cover.bounds, from: cover).intersection(scrollView.bounds)
        guard !crop.isEmpty,
              let captured = scrollView.resizableSnapshotView(from: crop, afterScreenUpdates: true, withCapInsets: .zero)
        else {
            cancel()
            return false
        }
        UIView.performWithoutAnimation {
            captured.frame = CGRect(origin: .zero, size: crop.size)
            captured.isUserInteractionEnabled = false
            captured.accessibilityElementsHidden = true
            incoming.addSubview(captured)
        }
        cachedViewports[targetScope] = captured
        start()
        return true
    }

    private func beginInstallation() {
        animator = nil
        phase = .installing
        if let scrollGeometry, finishInstallation(scope: targetScope, geometry: scrollGeometry) {
            return
        }
        armTimeout(for: .installing)
    }

    private func finishInstallation(scope: String, geometry: AlbumScrollGeometry) -> Bool {
        guard phase == .installing, nativeContentIsReady(scope: scope, geometry: geometry) else { return false }
        cancel()
        return true
    }

    private func armTimeout(for waitingPhase: Phase) {
        readinessTimeout?.cancel()
        let request = generation
        readinessTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, generation == request, phase == waitingPhase else { return }
            cancel()
        }
    }

    func cancel(clearCache: Bool = false) {
        generation &+= 1
        readinessTimeout?.cancel()
        readinessTimeout = nil
        if animator?.state == .active {
            animator?.stopAnimation(true)
        }
        animator = nil
        cover?.removeFromSuperview()
        cover = nil
        outgoing = nil
        incoming = nil
        scrollView = nil
        capturedIncoming = false
        if clearCache {
            cachedViewports.removeAll()
            cacheKey = nil
        }
        phase = .idle
    }
}

/// Declare the native stage below the complete SwiftUI header, rather than
/// inserting a sibling above SwiftUI's shared drawing surface at runtime.
private struct AlbumScopeSlideHost: UIViewRepresentable {
    let slide: AlbumScopeSlide

    func makeUIView(context _: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        slide.stageHost = view
        return view
    }

    func updateUIView(_ uiView: UIView, context _: Context) {
        slide.stageHost = uiView
    }
}

private struct AlbumScopeSlideAnchor: UIViewRepresentable {
    let slide: AlbumScopeSlide
    func makeUIView(context _: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        slide.anchor = view
        return view
    }

    func updateUIView(_ view: UIView, context _: Context) {
        slide.anchor = view
    }
}

private struct AlbumSearchDismissSwipe: UIGestureRecognizerRepresentable {
    let enabled: Bool
    let dismiss: () -> Void

    func makeCoordinator(converter _: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UISwipeGestureRecognizer {
        let swipe = UISwipeGestureRecognizer()
        swipe.direction = .left
        swipe.cancelsTouchesInView = false
        swipe.isEnabled = enabled
        swipe.delegate = context.coordinator
        return swipe
    }

    func updateUIGestureRecognizer(_ swipe: UISwipeGestureRecognizer, context _: Context) {
        if swipe.isEnabled != enabled {
            swipe.isEnabled = enabled
        }
    }

    func handleUIGestureRecognizerAction(_ swipe: UISwipeGestureRecognizer, context _: Context) {
        if enabled, swipe.state == .ended {
            dismiss()
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var candidate = touch.view
            while let view = candidate {
                if view is UITextField || view is UITextView {
                    return false
                }
                candidate = view.superview
            }
            return true
        }

        func gestureRecognizer(_: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            other is UIPanGestureRecognizer
        }
    }
}

private struct AlbumOpeningLabels: View {
    let width: CGFloat

    var body: some View {
        VStack(spacing: 4) {
            Text("1 item").font(.caption).lineLimit(1)
                .hidden()
                .overlay {
                    Capsule().fill(.quaternary).frame(width: width * 0.37, height: 6)
                }
            Text("Album").font(.headline).lineLimit(2, reservesSpace: true)
                .hidden()
                .overlay(alignment: .top) {
                    Capsule().fill(.tertiary).frame(width: width * 0.62, height: 9)
                        .padding(.top, 4)
                }
        }
        .frame(width: width)
    }
}

private nonisolated struct AlbumCardVisibility: Equatable {
    let nearby: Bool
    let visible: Bool
}

private struct AlbumCard: View {
    let album: AlbumSummary
    let media: MediaLibraryController
    let compact: Bool
    let progress: CGFloat
    let sort: AlbumSort
    let persistence: (any AlbumCatalogStoring)?
    let scope: MediaAccountScope?
    let transitionNamespace: Namespace.ID
    let coverWidth: CGFloat
    let listWidth: CGFloat
    let isReordering: Bool
    let initiallyMounted: Bool
    let keepsTransitionSource: Bool
    let coverRevision: Date?
    let coverVisible: () -> Void
    @State private var mounted: Bool?
    @State private var visibility = AlbumCardVisibility(nearby: false, visible: false)
    @State private var coverLoaded = false

    var body: some View {
        Group {
            if keepsTransitionSource || (mounted ?? initiallyMounted) {
                AlbumCardReflowLayout(progress: progress, coverWidth: coverWidth, listWidth: listWidth) {
                    cover
                    labels(compact: false)
                        .opacity(1 - progress)
                        .accessibilityHidden(compact)
                    labels(compact: true)
                        .opacity(progress)
                        .accessibilityHidden(!compact)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        .opacity(progress)
                        .accessibilityHidden(!compact)
                }
            } else {
                Color.clear
                    .accessibilityLabel(album.title)
                    .accessibilityValue(album.countLabel)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .onGeometryChange(for: AlbumCardVisibility.self) { geometry in
            guard let viewport = geometry.bounds(of: .scrollView(axis: .vertical)),
                  !viewport.isEmpty, geometry.size.width > 0, geometry.size.height > 0
            else { return .init(nearby: false, visible: false) }
            let frame = CGRect(origin: .zero, size: geometry.size)
            let margin = max(viewport.height / 2, frame.height)
            return .init(nearby: frame.intersects(viewport.insetBy(dx: 0, dy: -margin)), visible: frame.intersects(viewport))
        } action: { next in
            visibility = next
            if next.nearby || !isReordering {
                updateMount(next.nearby)
            }
            if next.visible, coverLoaded {
                coverVisible()
            }
        }
        .onChange(of: isReordering) { _, active in
            if !active {
                updateMount(visibility.nearby)
            }
        }
    }

    private func updateMount(_ shouldMount: Bool) {
        guard mounted != shouldMount else { return }
        mounted = shouldMount
        if !shouldMount, !keepsTransitionSource {
            coverLoaded = false
        }
    }

    private func labels(compact: Bool) -> some View {
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
        let cornerRadius = DesignMetrics.defaultCornerRadius + (12 - DesignMetrics.defaultCornerRadius) * progress
        return AlbumCover(album: album, media: media, persistence: persistence, scope: scope,
                          requestWidth: coverWidth, cachedRevision: coverRevision)
        {
            coverLoaded = true
            if visibility.visible {
                coverVisible()
            }
        }
        .clipShape(.rect(cornerRadius: cornerRadius))
        .cardNavigationSource(id: album.id, in: transitionNamespace, cornerRadius: cornerRadius)
    }
}

private struct AlbumCover: View {
    @Environment(\.displayScale) private var displayScale
    let album: AlbumSummary
    let media: MediaLibraryController

    let persistence: (any AlbumCatalogStoring)?
    let scope: MediaAccountScope?
    let requestWidth: CGFloat
    let cachedRevision: Date?
    let didLoad: () -> Void
    @State private var revision: Date?

    var body: some View {
        GeometryReader { geometry in
            let descriptor = album.thumbnailAssetID.flatMap { id in
                (cachedRevision ?? revision).map {
                    AlbumReflowMetrics.coverDescriptor(assetID: id, revision: $0, width: requestWidth, scale: displayScale)
                }
            }
            Group {
                if let descriptor {
                    ImmichThumbnail(descriptor: descriptor, media: media, revealsImageOnLoad: true) { _ in didLoad() }
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay { Image(systemName: "rectangle.stack").foregroundStyle(.secondary) }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .accessibilityHidden(true)
        .task(id: "\(album.thumbnailAssetID ?? "none")|\(album.catalogRevision)|\(String(describing: cachedRevision))") {
            guard cachedRevision == nil, let assetID = album.thumbnailAssetID else { return }
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
         tabBarTop: Binding<CGFloat>)
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
        _detail = State(initialValue: album)
        let reader = AlbumTimelineReader(source: source, albumID: album.id, revision: album.catalogRevision,
                                         persistence: persistence, scope: scope)
        _reader = State(initialValue: reader)
        _store = State(initialValue: PhotosTimelineStore(reader: reader, openingSource: .init(label: "album") {
            guard let scope, let window = try await reader.openingWindow(limit: $0),
                  !Task.isCancelled, media.scope == scope else { return nil }
            media.registerWarmedThumbnails(
                LibraryThumbnailCache.projectIndexedThumbnails(records: window.thumbnails, scope: scope), replacing: false
            )
            return window.snapshot
        }))
    }

    var body: some View {
        PhotosView(store: store, presentation: presentation, media: media, assetDetails: assetDetails,
                   navigationPath: $path, tabBarTop: $tabBarTop, timelineRuntime: timelineRuntime,
                   scrollToLatestRequest: scrollToLatestRequest,
                   contentName: detail.title,
                   rootAccessibilityID: "album-assets-\(album.id)", collectionTitle: detail.title,
                   collectionSubtitle: detail.countLabel, collectionInfoAction: { showsDetails = true },
                   compactChromeChanged: { _ in }, tabSelectionState: tabSelectionState,
                   tabDestination: .albums, viewerPresentations: viewerPresentations)
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
