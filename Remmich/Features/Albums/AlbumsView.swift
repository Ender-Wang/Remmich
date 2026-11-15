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

struct AlbumsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.scenePhase) private var scenePhase
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
    @State private var contentScope: AlbumScope = .all
    @State private var query = ""
    @State private var sort: AlbumSort = .mostRecentPhoto
    @State private var sortDirection: AlbumSortDirection = .ascending
    @State private var isReordering = false
    @State private var reorderGeneration = 0
    @State private var showsList = false
    @State private var albumLayoutProgress: CGFloat = 0
    @State private var pinchSettling = false
    @State private var chromeTracker = PhotosChromeTracker()
    @State private var searchHidden = false
    @State private var searchRowHeight: CGFloat = 44
    @State private var scopePickerHeight: CGFloat = 32
    @State private var userScrolling = false
    @State private var initialAlbumsPositioned = false
    @State private var albumLabelHeight: CGFloat = 58
    @State private var reflowCompletion = AlbumReflowCompletion()
    @State private var reflowViewport = AlbumReflowViewport()
    @State private var pinchInteraction = AlbumPinchInteraction()
    @State private var listVisible = false
    @Namespace private var albumTransition
    @State private var timelineSessions = AlbumTimelineSessions()
    @State private var scopeSlide = AlbumScopeSlide()
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
            (contentScope == .all || $0.isShared) && (query.isEmpty || $0.title.localizedStandardContains(query))
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
        let metrics = AlbumReflowMetrics(width: max(1, availableWidth - 32), columns: columnCount,
                                         coverWidth: coverWidth, labelHeight: albumLabelHeight)
        let request = reorderGeneration
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
                            query.isEmpty ? (contentScope == .shared ? "No Shared Albums" : "No Albums") : "No Results",
                            systemImage: "rectangle.stack",
                            description: Text(query.isEmpty ? "Albums available to this account will appear here." : "Try another album name.")
                        )
                    } else {
                        AlbumReflowLayout(progress: albumLayoutProgress, metrics: metrics) {
                            ForEach(filtered) { album in
                                albumLink(album, compact: showsList, progress: albumLayoutProgress,
                                          metrics: metrics, proxy: proxy, generation: request)
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
                .padding(.vertical)
                .onGeometryChange(for: AlbumScopeContentGeometry.self) {
                    AlbumScopeContentGeometry(scope: contentScope.rawValue, height: $0.size.height)
                } action: { scopeSlide.contentChanged($0) }
                .background { AlbumScopeSlideAnchor(slide: scopeSlide) }
                // Explicit bottom requests include the trailing clearance.
                // This stable target installs no content-resize anchoring.
                .id(AlbumDiscoveryScrollTarget.content)
            }
            .ignoresSafeArea(.container, edges: .horizontal)
            .scrollDisabled(pinchInteraction.isActive)
            // Like timeline Memories, compact chrome must not resize the viewport
            // or change the scroll clearance while the user is dragging.
            .contentMargins(.top, expandedHeaderHeight, for: .scrollContent)
            .contentMargins(.top, expandedHeaderHeight, for: .scrollIndicators)
            .defaultScrollAnchor(.bottom, for: .alignment)
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
                cancelAlbumReflow()
                scopeSlide.cancel(clearCache: true)
                // Navigation retains this ScrollView. Geometry callbacks report
                // changes, so an unchanged frame is not sent again on return.
                // Keep its measured geometry; visibility gates input while hidden.
            }
            .onChange(of: scrollToLatestRequest) {
                guard listVisible, !filtered.isEmpty else { return }
                cancelAlbumReflow()
                scopeSlide.cancel(clearCache: true)
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) { proxy.scrollTo(AlbumDiscoveryScrollTarget.content, anchor: .bottom) }
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting, !pinchInteraction.isActive {
                    reflowViewport.cancelMotion()
                }
                userScrolling = !pinchInteraction.isActive && (phase == .interacting || phase == .decelerating)
                if !userScrolling {
                    chromeTracker.scrollingEnded()
                }
            }
            .onScrollGeometryChange(for: AlbumScrollGeometry.self) {
                AlbumScrollGeometry(offset: max(0, $0.contentOffset.y + $0.contentInsets.top),
                                    topInset: $0.contentInsets.top, viewportHeight: $0.containerSize.height,
                                    contentHeight: $0.contentSize.height, bottomInset: $0.contentInsets.bottom)
            } action: { old, new in
                scopeSlide.scrollChanged(scope: contentScope.rawValue, geometry: new)
                if old.viewportHeight != new.viewportHeight || old.topInset != new.topInset || old.bottomInset != new.bottomInset {
                    cancelAlbumReflow()
                }
                reflowViewport.visibleHeight = new.viewportHeight
                if !initialAlbumsPositioned, store.hasLoaded, !filtered.isEmpty,
                   new.contentHeight >= metrics.height(count: filtered.count, list: showsList)
                {
                    // Consume before requesting so the resulting geometry cannot
                    // re-arm initial placement during a later mode change.
                    initialAlbumsPositioned = true
                    withTransaction(Transaction(animation: nil)) { proxy.scrollTo(AlbumDiscoveryScrollTarget.content, anchor: .bottom) }
                }
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
            .onChange(of: contentScope) {
                cancelAlbumReflow()
                // A scope is a new collection. Sort/mode changes continue to
                // use their existing viewport and touched-album policies.
                withTransaction(Transaction(animation: nil)) {
                    proxy.scrollTo(AlbumDiscoveryScrollTarget.content, anchor: .bottom)
                }
                scopeSlide.start()
            }
            .onChange(of: Set(filtered.map(\.id))) { _, _ in cancelAlbumReflow() }
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
            .onChange(of: tabSelectionState.selection) { _, _ in
                cancelAlbumReflow()
                scopeSlide.cancel(clearCache: true)
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
                    .ignoresSafeArea(.container, edges: [.top, .horizontal])
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .topLeading) {
                AlbumLabelMeasurement()
                    .frame(width: coverWidth)
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        guard height > 0, abs(albumLabelHeight - height) > 0.01 else { return }
                        albumLabelHeight = height
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
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
                            Image(systemName: "arrow.up.arrow.down").frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .accessibilityLabel("Album Options")
                        .allowsHitTesting(!scopeSlide.isActive)
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
                    Picker("Album scope", selection: Binding(get: { scope }, set: selectAlbumScope)) {
                        ForEach(AlbumScope.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .allowsHitTesting(!scopeSlide.isActive)
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
                .ignoresSafeArea(.container, edges: .horizontal)
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

    private func albumLink(_ album: AlbumSummary, compact: Bool, progress: CGFloat, metrics: AlbumReflowMetrics,
                           proxy: ScrollViewProxy, generation: Int) -> some View
    {
        Button { activateAlbum(album) } label: {
            AlbumCard(album: album, media: media, compact: compact, progress: progress, sort: sort, persistence: persistence,
                      scope: accountScope, transitionNamespace: albumTransition, coverWidth: metrics.coverWidth,
                      listWidth: metrics.width, isReordering: isReordering)
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
                withTransaction(Transaction(animation: nil)) {
                    proxy.scrollTo(anchor.albumID, anchor: UnitPoint(x: 0.5, y: anchor.alignment(for: geometry.size.height)))
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
            if !reduceMotion, listVisible, store.hasLoaded {
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
        openAlbum(album)
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
                userScrolling = false
                chromeTracker.scrollingEnded()
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

    func prepare(current: String, target: String, key: AlbumScopeCaptureKey,
                 cacheSource: Bool, viewport: CGRect, direction: NativeTabPageDirection)
    {
        cancel()
        var ancestor = anchor?.superview
        while let view = ancestor, !(view is UIScrollView) {
            ancestor = view.superview
        }
        guard let scroll = ancestor as? UIScrollView,
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

private struct AlbumLabelMeasurement: View {
    var body: some View {
        VStack(spacing: 4) {
            Text("1 item").font(.caption).lineLimit(1)
            Text("Album").font(.headline).lineLimit(2, reservesSpace: true)
        }
    }
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
    @State private var coverVisible = false
    @State private var intersectsViewport = false

    var body: some View {
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
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .onScrollVisibilityChange(threshold: 0.01) { visible in
            intersectsViewport = visible
            if visible || !isReordering {
                coverVisible = visible
            }
        }
        .onChange(of: isReordering) { _, active in
            if !active {
                coverVisible = intersectsViewport
            }
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
        AlbumCover(album: album, media: media, persistence: persistence, scope: scope,
                   requestWidth: coverWidth, isActive: coverVisible)
            .clipShape(.rect(cornerRadius: DesignMetrics.defaultCornerRadius + (12 - DesignMetrics.defaultCornerRadius) * progress))
            .matchedTransitionSource(id: album.id, in: transitionNamespace) { source in
                source.clipShape(.rect(cornerRadius: DesignMetrics.defaultCornerRadius + (12 - DesignMetrics.defaultCornerRadius) * progress))
            }
    }
}

private struct AlbumCover: View {
    @Environment(\.displayScale) private var displayScale
    let album: AlbumSummary
    let media: MediaLibraryController

    let persistence: (any AlbumCatalogStoring)?
    let scope: MediaAccountScope?
    let requestWidth: CGFloat
    let isActive: Bool
    @State private var revision: Date?

    var body: some View {
        GeometryReader { geometry in
            let descriptor = (isActive ? album.thumbnailAssetID : nil).flatMap { id in
                revision.map { MediaRequestDescriptor(assetID: id, updatedAt: $0, derivative: .thumbnail,
                                                      targetPixels: .init(width: Int(max(1, requestWidth) * displayScale),
                                                                          height: Int(max(1, requestWidth * 0.75) * displayScale))) }
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
        .task(id: "\(album.thumbnailAssetID ?? "none")|\(album.catalogRevision)|\(isActive)") {
            guard isActive, let assetID = album.thumbnailAssetID else { return }
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
