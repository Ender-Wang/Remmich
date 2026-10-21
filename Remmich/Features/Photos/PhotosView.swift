import OSLog
import SwiftUI

private struct PhotosChromeGeometry: Equatable {
    let offset: CGFloat
    let bottomGap: CGFloat
    let containerSize: CGSize
    let contentSize: CGSize
}

nonisolated enum TimelineViewportAnchor: Equatable {
    case latest
    case asset(id: String, viewportCenterOffset: CGFloat)
}

nonisolated enum TimelineViewportAnchorRetention {
    static let latestBoundary: CGFloat = 24

    static func update(
        current: TimelineViewportAnchor,
        bottomGap: CGFloat,
        userScrolling: Bool,
        centeredAssetID: String?,
        viewportCenterOffset: CGFloat?
    ) -> TimelineViewportAnchor {
        if bottomGap <= latestBoundary {
            return .latest
        }
        guard userScrolling,
              let centeredAssetID,
              let viewportCenterOffset
        else { return current }
        return .asset(
            id: centeredAssetID,
            viewportCenterOffset: viewportCenterOffset
        )
    }

    static func restoredScrollOffset(
        assetCenter: CGFloat,
        viewportCenterOffset: CGFloat,
        viewportHeight: CGFloat,
        maximumOffset: CGFloat
    ) -> CGFloat {
        min(
            maximumOffset,
            max(0, assetCenter - viewportHeight / 2 - viewportCenterOffset)
        )
    }
}

@MainActor
private final class TimelineViewportRuntime {
    var isTimelineActive = false
    var visibleDescriptors: [String: MediaRequestDescriptor] = [:]
    var visibleAssets: [String: Date] = [:]
    var viewportUpdateTask: Task<Void, Never>?
    var timelineBottomGap = CGFloat.infinity
    var userScrollPhase = false
    var chromeTracker = PhotosChromeTracker()
    var lastResidencyPlan = TimelineResidencyPlan.empty
    var lastResidencyTarget: MediaPixelSize?
    var scrollOffset: CGFloat = 0
    var scrollContainerSize: CGSize = .zero
    var retainedAnchor = TimelineViewportAnchor.latest
    var layoutCache = TimelineDeterministicLayoutCache()
    var lastLoggedContainerSize: CGSize?
}

struct PhotosChromeTracker {
    private(set) var isCompact = false
    private var travel: CGFloat = 0
    private var reachedLatestDuringCurrentScroll = false

    mutating func update(
        offsetDelta: CGFloat,
        bottomGap: CGFloat,
        userScrolling: Bool,
        programmaticJump: Bool
    ) -> Bool? {
        if !userScrolling {
            scrollingEnded()
        }
        if bottomGap <= 24 {
            travel = 0
            if userScrolling, offsetDelta >= 0 {
                reachedLatestDuringCurrentScroll = true
            }
            guard isCompact else { return nil }
            isCompact = false
            return false
        }
        guard !reachedLatestDuringCurrentScroll, userScrolling, !programmaticJump, abs(offsetDelta) >= 1 else {
            travel = 0
            return nil
        }
        if travel.sign != offsetDelta.sign {
            travel = 0
        }
        travel += offsetDelta
        guard abs(travel) >= 48 else { return nil }
        let next = travel < 0
        travel = 0
        guard next != isCompact else { return nil }
        isCompact = next
        return next
    }

    mutating func scrollingEnded() {
        travel = 0
        reachedLatestDuringCurrentScroll = false
    }
}

nonisolated enum TimelineLibraryRange: Int, CaseIterable {
    case all
    case day
    case week
    case month
    case year

    func next(for direction: PhotosPinchDirection) -> Self? {
        let step = direction == .coarser ? 1 : -1
        return Self(rawValue: rawValue + step)
    }
}

nonisolated struct TimelinePresentationSelection: Equatable {
    let range: TimelineLibraryRange
    let assetLayout: PhotosAssetLayout
}

nonisolated struct TimelineLibraryRangeRequest: Equatable {
    let range: TimelineLibraryRange
    let generation: Int
}

nonisolated enum TimelineAssetLayoutLadder {
    static func layout(
        after direction: PhotosPinchDirection,
        from layout: PhotosAssetLayout
    ) -> PhotosAssetLayout? {
        switch (layout, direction) {
        case (.square, .coarser): .naturalAspect
        case (.naturalAspect, .finer): .square
        default: nil
        }
    }
}

nonisolated enum TimelinePresentationLadder {
    static func selection(
        after direction: PhotosPinchDirection,
        from selection: TimelinePresentationSelection
    ) -> TimelinePresentationSelection? {
        switch (selection.range, selection.assetLayout, direction) {
        case (.all, .square, .coarser):
            TimelinePresentationSelection(range: .all, assetLayout: .naturalAspect)
        case (.all, .naturalAspect, .finer):
            TimelinePresentationSelection(range: .all, assetLayout: .square)
        case (.all, .naturalAspect, .coarser):
            TimelinePresentationSelection(range: .day, assetLayout: .naturalAspect)
        case (.day, _, .finer):
            TimelinePresentationSelection(range: .all, assetLayout: .naturalAspect)
        default:
            selection.range.next(for: direction).map {
                TimelinePresentationSelection(range: $0, assetLayout: selection.assetLayout)
            }
        }
    }
}

struct PhotosView: View {
    private static let logger = Logger(
        subsystem: "io.github.ender-wang.Remmich",
        category: "PhotosTimeline"
    )

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let store: PhotosTimelineStore
    let presentation: PhotosPresentationState
    let media: MediaLibraryController
    let assetDetails: any AssetDetailReading
    @Binding var navigationPath: [PhotosRangeRoute]
    @Binding var tabBarTop: CGFloat
    var rotationState: TimelineRotationState?
    var scrollToLatestRequest = 0
    var requestedLibraryRange: TimelineLibraryRangeRequest?
    var requestedLibraryRangeHandled: () -> Void = {}
    var contentName = "Photos"
    var rootAccessibilityID = "photos-root"
    let compactChromeChanged: (Bool) -> Void
    var viewerVisibilityChanged: (Bool) -> Void = { _ in }
    var tabSelectionState: NativeTabSelectionState?
    var tabDestination: NativeTabDestination = .photos
    let showAccount: () -> Void

    @Namespace private var viewerNamespace
    @State private var timelinePosition = ScrollPosition(edge: .bottom)
    @State private var latestJumpTask: Task<Void, Never>?
    @State private var viewportRuntime = TimelineViewportRuntime()
    @State private var timelineSections: [TimelineSection]
    @State private var timelineResumeTask: Task<Void, Never>?
    @State private var rotationRestoreTask: Task<Void, Never>?
    @State private var contentRestoreTask: Task<Void, Never>?
    @State private var layoutRestoreTask: Task<Void, Never>?
    @State private var pendingViewportAnchor: TimelineViewportAnchor?
    @State private var layoutAnchorID: String?
    @State private var compactChrome = false
    @State private var libraryRange: TimelineLibraryRange = .all
    @State private var initialAssetByRoute: [PhotosRangeRoute: String] = [:]
    @State private var viewerRoute: AssetViewerRoute?

    init(
        store: PhotosTimelineStore,
        presentation: PhotosPresentationState,
        media: MediaLibraryController,
        assetDetails: any AssetDetailReading,
        navigationPath: Binding<[PhotosRangeRoute]>,
        tabBarTop: Binding<CGFloat>,
        rotationState: TimelineRotationState? = nil,
        scrollToLatestRequest: Int = 0,
        requestedLibraryRange: TimelineLibraryRangeRequest? = nil,
        requestedLibraryRangeHandled: @escaping () -> Void = {},
        contentName: String = "Photos",
        rootAccessibilityID: String = "photos-root",
        compactChromeChanged: @escaping (Bool) -> Void,
        viewerVisibilityChanged: @escaping (Bool) -> Void = { _ in },
        tabSelectionState: NativeTabSelectionState? = nil,
        tabDestination: NativeTabDestination = .photos,
        showAccount: @escaping () -> Void
    ) {
        self.store = store
        self.presentation = presentation
        self.media = media
        self.assetDetails = assetDetails
        _navigationPath = navigationPath
        _tabBarTop = tabBarTop
        self.rotationState = rotationState
        self.scrollToLatestRequest = scrollToLatestRequest
        self.requestedLibraryRange = requestedLibraryRange
        self.requestedLibraryRangeHandled = requestedLibraryRangeHandled
        self.contentName = contentName
        self.rootAccessibilityID = rootAccessibilityID
        self.compactChromeChanged = compactChromeChanged
        self.viewerVisibilityChanged = viewerVisibilityChanged
        self.tabSelectionState = tabSelectionState
        self.tabDestination = tabDestination
        self.showAccount = showAccount
        _timelineSections = State(initialValue: store.sections)
    }

    var body: some View {
        Group {
            switch store.loadState {
            case .idle, .loading:
                LoadingStateView()
            case .empty:
                EmptyStateView(
                    title: "No \(contentName)",
                    message: "\(contentName) from your Immich library will appear here.",
                    systemImage: contentName == "Videos" ? "video" : "photo.on.rectangle"
                )
            case let .failed(message):
                ErrorStateView(title: "Couldn’t Load \(contentName)") {
                    Task { await store.retryInitialLoad() }
                }
                .accessibilityHint(message)
            case .loaded:
                rangePresentation
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $viewerRoute) { route in
            AssetViewerView(
                route: route,
                store: store,
                media: media,
                assetDetails: assetDetails,
                namespace: viewerNamespace,
                close: { viewerRoute = nil },
                visibilityChanged: viewerVisibilityChanged
            )
        }
        .toolbarBackground(navigationPath.isEmpty ? .hidden : .visible, for: .navigationBar)
        .toolbar {
            if !navigationPath.isEmpty || libraryRange != .all {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: navigateBack) {
                        Label("Back", systemImage: "chevron.backward")
                    }
                    .accessibilityIdentifier("timeline-range-back")
                }
            }
            if UIDevice.current.userInterfaceIdiom == .pad,
               let title = navigationPath.last?.navigationTitle
            {
                ToolbarItem(placement: .principal) {
                    TimelineRangeNavigationTitle(title: title)
                }
            }
            AccountToolbarButton(action: showAccount)
        }
        .onAppear {
            viewportRuntime.isTimelineActive = isTimelineActive
            media.beginTimelinePresentation()
            if isTimelineActive {
                media.beginTimelineContentPresentation(contentName)
            }
        }
        .task { await store.load() }
        .onChange(
            of: sectionRevisionKeys,
            initial: true
        ) {
            guard isTimelineActive else { return }
            if viewportRuntime.userScrollPhase {
                contentRestoreTask?.cancel()
                pendingViewportAnchor = nil
            } else if rotationState?.isRotating != true {
                pendingViewportAnchor = captureViewportAnchor(
                    using: viewportRuntime.layoutCache.current
                )
            }
            timelineSections = store.sections
            scheduleViewportUpdate()
        }
        .onChange(of: isTimelineActive) { _, isVisible in
            viewportRuntime.isTimelineActive = isVisible
            timelineResumeTask?.cancel()
            if isVisible {
                media.beginTimelineContentPresentation(contentName)
                timelineResumeTask = Task { @MainActor in
                    // Reveal the retained timeline first, then reconcile its
                    // frozen section snapshot on the following run loop.
                    await Task.yield()
                    guard !Task.isCancelled, isTimelineActive else { return }
                    timelineSections = store.sections
                    restorePendingViewportAnchor(
                        using: viewportRuntime.layoutCache.current,
                        viewportHeight: viewportRuntime.scrollContainerSize.height,
                        generation: 0,
                        reason: "tab-resume",
                        clearsAnchor: false
                    )
                    scheduleViewportUpdate()
                    if let bucketID = store.visibleAnchor?.bucketID {
                        await store.loadBucket(bucketID)
                    }
                    timelineResumeTask = nil
                }
            } else {
                pendingViewportAnchor = captureViewportAnchor(
                    using: viewportRuntime.layoutCache.current
                )
                viewportRuntime.viewportUpdateTask?.cancel()
                viewportRuntime.viewportUpdateTask = nil
                timelineResumeTask = nil
            }
        }
        .onChange(of: scrollToLatestRequest) {
            guard libraryRange != .all || !navigationPath.isEmpty else { return }
            let request = scrollToLatestRequest
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                navigationPath = []
                libraryRange = .all
            }
            latestJumpTask?.cancel()
            latestJumpTask = Task { @MainActor in
                defer { latestJumpTask = nil }
                guard !Task.isCancelled,
                      request == scrollToLatestRequest,
                      let latest = store.bucketSummaries.first?.id,
                      await store.prepareJump(to: latest)
                else {
                    store.completeJump()
                    return
                }
                resetViewportTracking()
                var scrollTransaction = Transaction(animation: nil)
                scrollTransaction.disablesAnimations = true
                withTransaction(scrollTransaction) {
                    timelinePosition.scrollTo(edge: .bottom)
                }
                store.completeJump()
            }
        }
        .onChange(of: requestedLibraryRange, initial: true) { _, requestedLibraryRange in
            guard let requestedLibraryRange else { return }
            navigationPath.removeAll()
            libraryRange = requestedLibraryRange.range
            requestedLibraryRangeHandled()
        }
        .onDisappear {
            viewportRuntime.viewportUpdateTask?.cancel()
            viewportRuntime.viewportUpdateTask = nil
            timelineResumeTask?.cancel()
            rotationRestoreTask?.cancel()
            contentRestoreTask?.cancel()
            pendingViewportAnchor = nil
            layoutRestoreTask?.cancel()
            latestJumpTask?.cancel()
            latestJumpTask = nil
            store.completeJump()
        }
        .accessibilityIdentifier(rootAccessibilityID)
        .overlay(alignment: .bottomTrailing) {
            rangeUITestControls
        }
    }

    private var rangePresentation: some View {
        rangeContent
    }

    private var dayIconSystemImage: String {
        timelineDayIconSystemImage(contentName: contentName)
    }

    @ViewBuilder
    private var rangeUITestControls: some View {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ui-testing-range-library") {
                HStack(spacing: 0) {
                    Text(String(describing: libraryRange))
                        .opacity(0.01)
                        .accessibilityIdentifier("timeline-test-\(contentName.lowercased())-range")

                    Text(presentation.preferences.assetLayout.rawValue)
                        .opacity(0.01)
                        .accessibilityIdentifier("timeline-test-\(contentName.lowercased())-layout")

                    Button {
                        uiTestPinch(.finer)
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                            .opacity(0.01)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Refine \(contentName) timeline")
                    .accessibilityIdentifier("timeline-test-\(contentName.lowercased())-finer")

                    Button {
                        uiTestPinch(.coarser)
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                            .opacity(0.01)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Coarsen \(contentName) timeline")
                    .accessibilityIdentifier("timeline-test-\(contentName.lowercased())-coarser")

                    Button {
                        setCompactChrome(true)
                    } label: {
                        Image(systemName: "rectangle.compress.vertical")
                            .opacity(0.01)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Compact \(contentName) timeline navigation")
                    .accessibilityIdentifier("timeline-test-\(contentName.lowercased())-compact")

                    if libraryRange == .week {
                        Button(action: uiTestOpenNewestWeek) {
                            Image(systemName: "calendar")
                                .opacity(0.01)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Open newest \(contentName) week")
                        .accessibilityIdentifier("timeline-test-\(contentName.lowercased())-open-week")
                    }
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                .padding(.bottom, 76)
            }
        #else
            EmptyView()
        #endif
    }

    private func uiTestPinch(_ direction: PhotosPinchDirection) {
        let magnification: CGFloat = direction == .coarser ? 0.6 : 1.5
        guard let gesture = PhotosPinchGesture(magnification: magnification) else { return }
        pinchLibraryRange(gesture)
    }

    private func uiTestOpenNewestWeek() {
        guard libraryRange == .week,
              let newest = store.bucketSummaries.first?.id,
              let monthStart = newest.displayDate,
              let representativeDate = Calendar(identifier: .gregorian).date(
                  byAdding: .day,
                  value: 6,
                  to: monthStart
              ),
              let week = TimelineWeekID(day: TimelineCaptureDay(capturedAt: representativeDate))
        else { return }
        selectRoute(.week(newest, week, .library), initialAssetID: nil)
    }

    private var rangeContent: some View {
        ZStack {
            timeline
                .opacity(showsMainTimeline ? 1 : 0)
                .allowsHitTesting(showsMainTimeline)
                .accessibilityHidden(!showsMainTimeline)

            if !showsMainTimeline {
                if let route = navigationPath.last {
                    rangeDestination(route)
                } else {
                    groupedRangeContent
                }
            }
        }
    }

    private var showsMainTimeline: Bool {
        libraryRange == .all && navigationPath.isEmpty
    }

    private var isTimelineActive: Bool {
        isTabContentActivated && showsMainTimeline
    }

    private var isTabContentActivated: Bool {
        tabSelectionState.map { $0.selection == tabDestination } ?? true
    }

    @ViewBuilder
    private var groupedRangeContent: some View {
        switch libraryRange {
        case .all:
            EmptyView()
        case .day:
            PhotosLibraryDaysView(
                store: store,
                media: media,
                dayIconSystemImage: dayIconSystemImage,
                tabBarTop: tabBarTop,
                onSelect: selectRoute,
                onPinch: pinchLibraryRange
            )
        case .week:
            PhotosLibraryWeeksView(
                store: store, media: media, tabBarTop: tabBarTop,
                onSelect: selectRoute, onPinch: pinchLibraryRange
            )
        case .month:
            PhotosMonthsView(
                summaries: store.bucketSummaries, store: store, media: media,
                tabBarTop: tabBarTop, onSelect: selectRoute, onPinch: pinchLibraryRange
            )
        case .year:
            PhotosYearsView(
                store: store, media: media, tabBarTop: tabBarTop,
                onSelect: selectRoute, onPinch: pinchLibraryRange
            )
        }
    }

    private func rangeDestination(_ route: PhotosRangeRoute) -> some View {
        PhotosRangeAssetsView(
            route: route,
            store: store,
            media: media,
            tabBarTop: tabBarTop,
            assetLayout: presentation.preferences.assetLayout,
            initialAssetID: initialAssetByRoute[route],
            onPinch: pinchLibraryRange,
            visibilityChanged: updateVisibility,
            viewportChanged: updateViewport,
            transitionNamespace: viewerNamespace,
            assetSelected: { asset, assets in
                viewerRoute = AssetViewerRoute(
                    selectedAsset: asset,
                    initialAssets: assets,
                    origin: .scoped(route: route, contentName: contentName)
                )
            }
        )
        .navigationTitle(route.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private var navigationTitle: String {
        navigationPath.last?.navigationTitle ?? ""
    }

    private func selectRoute(_ route: PhotosRangeRoute, initialAssetID: String?) {
        if let initialAssetID {
            initialAssetByRoute[route] = initialAssetID
        } else {
            initialAssetByRoute.removeValue(forKey: route)
        }
        withAnimation(.smooth(duration: 0.25)) {
            navigationPath.append(route)
        }
    }

    private func navigateBack() {
        // Swapping an asset grid or grouped catalog back to its parent can
        // publish hundreds of visibility changes. Keep that structural swap
        // atomic instead of implicitly animating every outgoing and incoming
        // child in the same frame.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if !navigationPath.isEmpty {
                if let route = navigationPath.last {
                    initialAssetByRoute.removeValue(forKey: route)
                }
                navigationPath = Array(navigationPath.dropLast())
            } else {
                libraryRange = libraryRange.next(for: .finer) ?? .all
            }
        }
    }

    private func pinchLibraryRange(_ gesture: PhotosPinchGesture) {
        if !navigationPath.isEmpty {
            let current = presentation.preferences.assetLayout
            guard let next = TimelineAssetLayoutLadder.layout(
                after: gesture.direction,
                from: current
            ) else { return }
            do {
                try presentation.setAssetLayout(next)
            } catch {
                Self.logger.error(
                    "Failed to persist scoped \(contentName, privacy: .public) asset layout: \(error.localizedDescription, privacy: .public)"
                )
                return
            }
            Self.logger.info(
                "\(contentName, privacy: .public) scoped pinch changed layout to \(next.rawValue, privacy: .public)"
            )
            return
        }

        let current = TimelinePresentationSelection(
            range: libraryRange,
            assetLayout: presentation.preferences.assetLayout
        )
        guard let next = TimelinePresentationLadder.selection(after: gesture.direction, from: current)
        else { return }

        if next.range == .all, next.assetLayout != current.assetLayout {
            layoutAnchorID = centerVisibleAssetID
        }
        do {
            try presentation.setAssetLayout(next.assetLayout)
        } catch {
            Self.logger.error(
                "Failed to persist \(contentName, privacy: .public) asset layout: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            libraryRange = next.range
        }
        Self.logger.info(
            "\(contentName, privacy: .public) pinch changed presentation to layout=\(next.assetLayout.rawValue, privacy: .public) range=\(String(describing: next.range), privacy: .public)"
        )
    }

    private var timeline: some View {
        GeometryReader { geometry in
            let proposedWidth = rotationState?.isRotating == true
                ? rotationState?.targetSize?.width ?? geometry.size.width
                : geometry.size.width
            let layoutKey = TimelineDeterministicLayout.Key(
                width: proposedWidth,
                minimumColumnWidth: horizontalSizeClass == .regular ? 120 : 88,
                spacing: timelineItemSpacing,
                sectionRevisions: timelineSectionRevisionKeys
            )
            let layout = viewportRuntime.layoutCache.resolve(
                sections: timelineSections,
                key: layoutKey
            )

            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    if case let .failed(message) = store.refreshState {
                        TimelineRefreshError(message: message) {
                            Task { await store.refresh() }
                        }
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(layout.rows) { row in
                                timelineRow(row, layout: layout)
                                    .frame(width: proposedWidth, height: row.height, alignment: .topLeading)
                                    .id(row.id)
                                    .onScrollVisibilityChange(threshold: 0.01) { visible in
                                        guard isTimelineActive, visible else { return }
                                        store.updateVisibleAnchor(.init(
                                            bucketID: row.bucketID,
                                            assetID: row.anchorAssetID
                                        ))
                                        if store.jumpTarget == row.bucketID,
                                           row.bucketID != latestScrollTarget
                                        {
                                            Self.logger.info(
                                                "Calendar jump target became visible bucket=\(row.bucketID.rawValue, privacy: .public)"
                                            )
                                            store.completeJump()
                                        }
                                    }
                            }
                        }
                        .frame(width: proposedWidth, alignment: .topLeading)
                    }
                    .defaultScrollAnchor(.bottom)
                    .scrollPosition($timelinePosition)
                    .scrollEdgeEffectHidden(for: .bottom)
                    .simultaneousGesture(MagnifyGesture().onEnded { value in
                        guard let gesture = PhotosPinchGesture(magnification: value.magnification) else { return }
                        pinchLibraryRange(gesture)
                    })
                    .accessibilityAction(named: layoutAccessibilityActionName) {
                        guard libraryRange == .all else { return }
                        let magnification = presentation.preferences.assetLayout == .square ? 0.6 : 1.5
                        guard let gesture = PhotosPinchGesture(magnification: magnification) else { return }
                        pinchLibraryRange(gesture)
                    }
                    .onScrollPhaseChange { _, phase in
                        let isUserScrolling = phase == .interacting || phase == .decelerating
                        viewportRuntime.userScrollPhase = isUserScrolling
                        if isUserScrolling {
                            viewportRuntime.viewportUpdateTask?.cancel()
                            viewportRuntime.viewportUpdateTask = nil
                            rotationRestoreTask?.cancel()
                            contentRestoreTask?.cancel()
                            pendingViewportAnchor = nil
                        } else {
                            viewportRuntime.chromeTracker.scrollingEnded()
                            scheduleViewportUpdate()
                        }
                    }
                    .onScrollGeometryChange(for: PhotosChromeGeometry.self) { scrollGeometry in
                        let visibleBottom = scrollGeometry.contentOffset.y
                            + scrollGeometry.containerSize.height
                            - scrollGeometry.contentInsets.bottom
                        return PhotosChromeGeometry(
                            offset: scrollGeometry.contentOffset.y,
                            bottomGap: max(0, scrollGeometry.contentSize.height - visibleBottom),
                            containerSize: scrollGeometry.containerSize,
                            contentSize: scrollGeometry.contentSize
                        )
                    } action: { old, new in
                        guard isTimelineActive else { return }
                        viewportRuntime.timelineBottomGap = new.bottomGap
                        viewportRuntime.scrollOffset = new.offset
                        viewportRuntime.scrollContainerSize = new.containerSize
                        let centerY = new.offset + new.containerSize.height / 2
                        let centeredAssetID = layout.assetNearest(verticalOffset: centerY)
                        let viewportCenterOffset = centeredAssetID.flatMap {
                            layout.verticalCenter(of: $0).map { $0 - centerY }
                        }
                        viewportRuntime.retainedAnchor = TimelineViewportAnchorRetention.update(
                            current: viewportRuntime.retainedAnchor,
                            bottomGap: new.bottomGap,
                            userScrolling: viewportRuntime.userScrollPhase,
                            centeredAssetID: centeredAssetID,
                            viewportCenterOffset: viewportCenterOffset
                        )
                        if viewportRuntime.lastLoggedContainerSize != new.containerSize {
                            viewportRuntime.lastLoggedContainerSize = new.containerSize
                            let selectionElapsed = NativeTabTransitionTrace.elapsedMilliseconds(
                                for: tabDestination
                            ) ?? -1
                            Self.logger.info(
                                "Timeline geometry content=\(contentName, privacy: .public) container=\(Self.describe(new.containerSize), privacy: .public) content=\(Self.describe(new.contentSize), privacy: .public) layoutWidth=\(Int(layout.key.width)) columns=\(layout.columns) rows=\(layout.rows.count) height=\(Int(layout.totalHeight)) layoutBuildMs=\(layout.buildMilliseconds) selectionElapsedMs=\(selectionElapsed)"
                            )
                        }
                        if old.containerSize != new.containerSize,
                           rotationState?.isRotating == true,
                           pendingViewportAnchor != nil
                        {
                            restorePendingViewportAnchor(
                                using: layout,
                                viewportHeight: new.containerSize.height,
                                generation: rotationState?.generation ?? 0,
                                reason: "rotation-geometry",
                                clearsAnchor: false
                            )
                        }
                        updateChrome(old: old, new: new)
                        if new.bottomGap <= 24, store.jumpTarget == latestScrollTarget {
                            store.completeJump()
                        }
                    }
                    .ignoresSafeArea(.container, edges: [.top, .horizontal])
                    .ignoresSafeArea(
                        .container,
                        edges: UIDevice.current.userInterfaceIdiom == .pad ? .bottom : []
                    )
                    .contentMargins(.horizontal, 0, for: .scrollContent)
                    .contentMargins(
                        .bottom,
                        UIDevice.current.userInterfaceIdiom == .phone ? 20 : 0,
                        for: .scrollContent
                    )
                    .refreshable { await store.refresh() }
                    .overlay(alignment: .top) {
                        if memoryBackdropVisible {
                            TimelineMemoryLane(memories: store.memories, media: media)
                                .frame(height: 120)
                                .padding(.bottom, 12)
                                .background {
                                    LinearGradient(
                                        colors: [
                                            Color(uiColor: .systemBackground).opacity(0.72),
                                            Color(uiColor: .systemBackground).opacity(0),
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                    .ignoresSafeArea(.container, edges: .top)
                                }
                                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: compactChrome)
                    .onChange(of: rotationState?.generation ?? 0) { _, generation in
                        guard generation > 0 else { return }
                        let sourceLayout = viewportRuntime.layoutCache.previous.rows.isEmpty
                            ? layout
                            : viewportRuntime.layoutCache.previous
                        let anchor = captureViewportAnchor(using: sourceLayout)
                        pendingViewportAnchor = anchor
                        Self.logger.info(
                            "Timeline rotation captured content=\(contentName, privacy: .public) generation=\(generation) anchor=\(Self.describe(anchor), privacy: .public) sourceWidth=\(Int(sourceLayout.key.width)) targetWidth=\(Int(layout.key.width)) columns=\(sourceLayout.columns)->\(layout.columns) rows=\(layout.rows.count) buildMs=\(layout.buildMilliseconds)"
                        )
                        restorePendingViewportAnchor(
                            using: layout,
                            viewportHeight: viewportRuntime.scrollContainerSize.height,
                            generation: generation,
                            reason: "rotation",
                            clearsAnchor: false
                        )
                    }
                    .task(id: layout.key) {
                        guard pendingViewportAnchor != nil else { return }
                        let isRotating = rotationState?.isRotating == true
                        restorePendingViewportAnchor(
                            using: layout,
                            viewportHeight: viewportRuntime.scrollContainerSize.height,
                            generation: rotationState?.generation ?? 0,
                            reason: isRotating ? "rotation-layout" : "content",
                            clearsAnchor: !isRotating
                        )
                    }
                    .onChange(of: rotationState?.isRotating ?? false) { wasRotating, isRotating in
                        guard wasRotating, !isRotating, pendingViewportAnchor != nil else { return }
                        restorePendingViewportAnchor(
                            using: layout,
                            viewportHeight: viewportRuntime.scrollContainerSize.height,
                            generation: rotationState?.generation ?? 0,
                            reason: "rotation-complete",
                            clearsAnchor: true
                        )
                    }
                    .onChange(of: presentation.preferences.assetLayout) {
                        guard let layoutAnchorID else { return }
                        layoutRestoreTask?.cancel()
                        layoutRestoreTask = Task { @MainActor in
                            await Task.yield()
                            guard !Task.isCancelled else { return }
                            var transaction = Transaction(animation: nil)
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                proxy.scrollTo(layoutAnchorID, anchor: .center)
                            }
                            self.layoutAnchorID = nil
                            layoutRestoreTask = nil
                        }
                    }
                }
                .onChange(of: scrollToLatestRequest) {
                    guard navigationPath.isEmpty,
                          libraryRange == .all,
                          let latest = latestScrollTarget,
                          latestJumpTask == nil,
                          viewportRuntime.timelineBottomGap > 24
                    else { return }
                    rotationRestoreTask?.cancel()
                    rotationRestoreTask = nil
                    contentRestoreTask?.cancel()
                    contentRestoreTask = nil
                    pendingViewportAnchor = nil
                    store.completeJump()
                    latestJumpTask = Task { @MainActor in
                        defer { latestJumpTask = nil }
                        guard await store.prepareJump(to: latest), !Task.isCancelled else {
                            store.completeJump()
                            return
                        }
                        resetViewportTracking()
                        var transaction = Transaction(
                            animation: reduceMotion ? nil : .smooth(duration: 0.45)
                        )
                        transaction.disablesAnimations = reduceMotion
                        withTransaction(transaction) {
                            timelinePosition.scrollTo(edge: .bottom)
                        }
                        Self.logger.info(
                            "\(contentName, privacy: .public) re-tap scrolled to latest bucket=\(latest.rawValue, privacy: .public) animated=\(!reduceMotion)"
                        )
                    }
                }
            }
        }
        .ignoresSafeArea(.container, edges: .horizontal)
    }

    private var latestScrollTarget: TimelineBucketID? {
        store.sections.first?.id
    }

    @ViewBuilder
    private func timelineRow(
        _ row: TimelineDeterministicLayout.Row,
        layout: TimelineDeterministicLayout
    ) -> some View {
        switch row.content {
        case let .header(group):
            AssetSectionHeader(
                title: timelineDayTitle(group.id),
                subtitle: group.assets.count.formatted() + " items"
            )
            .frame(height: row.height)
            .accessibilityIdentifier("timeline-day-\(group.id.id)")
        case let .assets(assets):
            TimelineDeterministicAssetRow(
                assets: assets,
                media: media,
                itemSide: layout.itemSide,
                spacing: layout.key.spacing,
                assetLayout: presentation.preferences.assetLayout,
                visibilityChanged: updateVisibility,
                viewportChanged: updateViewport,
                transitionNamespace: viewerNamespace,
                assetSelected: { asset in
                    viewerRoute = AssetViewerRoute(
                        selectedAsset: asset,
                        initialAssets: [asset],
                        origin: .timeline(bucketID: row.bucketID, contentName: contentName)
                    )
                },
                isActive: isTimelineActive
            )
            .frame(height: row.height, alignment: .top)
        case let .placeholder(section):
            VStack(spacing: 8) {
                AssetSectionHeader(
                    title: section.id.displayDate?.formatted(date: .long, time: .omitted)
                        ?? section.id.rawValue,
                    subtitle: section.summary.assetCount.formatted() + " items"
                )
                switch section.loadState {
                case .unloaded, .loading:
                    ProgressView()
                        .task {
                            guard viewportRuntime.isTimelineActive else { return }
                            await store.loadBucket(section.id)
                        }
                case let .failed(message):
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Retry") {
                        Task { await store.retryBucket(section.id) }
                    }
                    .buttonStyle(.bordered)
                case .loaded:
                    Text("No \(contentName.lowercased()) in this section")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: row.height, alignment: .top)
            .accessibilityIdentifier("timeline-section-\(section.id.rawValue)")
        }
    }

    private var timelineItemSpacing: CGFloat {
        guard presentation.preferences.assetLayout == .naturalAspect else { return 2 }
        return UIDevice.current.userInterfaceIdiom == .pad ? 24 : 12
    }

    private var timelineSectionRevisionKeys: [String] {
        timelineSections.map { section in
            section.id.rawValue + ":" + String(section.contentRevision)
        }
    }

    private func timelineDayTitle(_ day: TimelineCaptureDay) -> String {
        guard let date = day.displayDate else { return day.id }
        return TimelineCaptureDateFormatting.string(
            from: date,
            dateStyle: .long,
            timeStyle: .none
        )
    }

    private func captureViewportAnchor(
        using layout: TimelineDeterministicLayout
    ) -> TimelineViewportAnchor? {
        guard !layout.rows.isEmpty else { return nil }
        switch viewportRuntime.retainedAnchor {
        case .latest:
            return .latest
        case let .asset(assetID, viewportCenterOffset)
            where layout.verticalCenter(of: assetID) != nil:
            return .asset(
                id: assetID,
                viewportCenterOffset: viewportCenterOffset
            )
        case .asset:
            break
        }
        let centerY = viewportRuntime.scrollOffset
            + viewportRuntime.scrollContainerSize.height / 2
        if let assetID = layout.assetNearest(verticalOffset: centerY),
           let assetCenter = layout.verticalCenter(of: assetID)
        {
            return .asset(
                id: assetID,
                viewportCenterOffset: assetCenter - centerY
            )
        }
        return nil
    }

    private func targetScrollOffset(
        for anchor: TimelineViewportAnchor,
        in layout: TimelineDeterministicLayout,
        viewportHeight: CGFloat
    ) -> CGFloat? {
        switch anchor {
        case .latest:
            return nil
        case let .asset(assetID, viewportCenterOffset):
            guard let center = layout.verticalCenter(of: assetID) else { return nil }
            let maximumOffset = max(0, layout.totalHeight - viewportHeight)
            return TimelineViewportAnchorRetention.restoredScrollOffset(
                assetCenter: center,
                viewportCenterOffset: viewportCenterOffset,
                viewportHeight: viewportHeight,
                maximumOffset: maximumOffset
            )
        }
    }

    private func restorePendingViewportAnchor(
        using layout: TimelineDeterministicLayout,
        viewportHeight: CGFloat,
        generation: Int,
        reason: String,
        clearsAnchor: Bool
    ) {
        guard let anchor = pendingViewportAnchor else { return }
        let task = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, pendingViewportAnchor == anchor else { return }
            guard !viewportRuntime.userScrollPhase else {
                pendingViewportAnchor = nil
                rotationRestoreTask = nil
                contentRestoreTask = nil
                return
            }
            let targetY = targetScrollOffset(
                for: anchor,
                in: layout,
                viewportHeight: viewportHeight
            )
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                switch anchor {
                case .latest:
                    timelinePosition.scrollTo(edge: .bottom)
                case .asset:
                    if let targetY {
                        timelinePosition.scrollTo(y: targetY)
                    }
                }
            }
            if clearsAnchor {
                pendingViewportAnchor = nil
            }
            rotationRestoreTask = nil
            contentRestoreTask = nil
            Self.logger.info(
                "Timeline anchor restored content=\(contentName, privacy: .public) reason=\(reason, privacy: .public) generation=\(generation) anchor=\(Self.describe(anchor), privacy: .public) targetY=\(targetY.map { String(Int($0)) } ?? "bottom", privacy: .public) layoutHeight=\(Int(layout.totalHeight)) viewportHeight=\(Int(viewportHeight))"
            )
        }
        if reason.hasPrefix("rotation") {
            rotationRestoreTask?.cancel()
            rotationRestoreTask = task
        } else {
            contentRestoreTask?.cancel()
            contentRestoreTask = task
        }
    }

    private var sectionRevisionKeys: [String] {
        store.sections.map { section in
            section.id.rawValue + ":" + String(section.contentRevision)
        }
    }

    private var memoryBackdropVisible: Bool {
        !compactChrome
            && navigationPath.isEmpty
            && libraryRange == .all
            && store.memoryLaneState == .loaded
            && !store.memories.isEmpty
    }

    private var centerVisibleAssetID: String? {
        if case let .asset(assetID, _) = captureViewportAnchor(
            using: viewportRuntime.layoutCache.current
        ) {
            return assetID
        }
        let ordered = viewportRuntime.visibleAssets.sorted { $0.value < $1.value }
        guard !ordered.isEmpty else { return nil }
        return ordered[ordered.count / 2].key
    }

    private func updateChrome(old: PhotosChromeGeometry, new: PhotosChromeGeometry) {
        let programmaticJump = store.jumpTarget != nil
            || latestJumpTask != nil
            || rotationRestoreTask != nil
            || contentRestoreTask != nil
            || layoutRestoreTask != nil
        if let compact = viewportRuntime.chromeTracker.update(
            offsetDelta: new.offset - old.offset,
            bottomGap: new.bottomGap,
            userScrolling: viewportRuntime.userScrollPhase,
            programmaticJump: programmaticJump
        ) {
            setCompactChrome(compact)
        }
    }

    private var layoutAccessibilityActionName: String {
        presentation.preferences.assetLayout == .square
            ? "Use Natural Aspect Layout"
            : "Use Square Layout"
    }

    private func setCompactChrome(_ compact: Bool) {
        guard compactChrome != compact else { return }
        compactChrome = compact
        compactChromeChanged(compact)
    }

    private func updateVisibility(
        assetID: String,
        descriptor: MediaRequestDescriptor?
    ) {
        guard isTimelineActive else { return }
        viewportRuntime.visibleDescriptors[assetID] = descriptor
        scheduleViewportUpdate()
    }

    private func updateViewport(_ asset: TimelineAssetSummary, visible: Bool) {
        guard isTimelineActive else { return }
        if visible {
            viewportRuntime.visibleAssets[asset.id] = asset.capturedAt
        } else {
            viewportRuntime.visibleAssets.removeValue(forKey: asset.id)
        }
        scheduleViewportUpdate()
    }

    private func scheduleViewportUpdate() {
        guard isTimelineActive, !viewportRuntime.userScrollPhase else { return }
        viewportRuntime.viewportUpdateTask?.cancel()
        viewportRuntime.viewportUpdateTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, isTimelineActive,
                  let target = viewportRuntime.visibleDescriptors.values.compactMap(\.targetPixels).max(by: {
                      $0.width * $0.height < $1.width * $1.height
                  })
            else { return }
            let plan = store.residencyPlan(
                visibleAssetIDs: Set(viewportRuntime.visibleAssets.keys)
            )
            guard plan != viewportRuntime.lastResidencyPlan
                || target != viewportRuntime.lastResidencyTarget
            else { return }
            viewportRuntime.lastResidencyPlan = plan
            viewportRuntime.lastResidencyTarget = target
            media.updateTimelineResidency(plan, targetPixels: target)
        }
    }

    private func resetViewportTracking() {
        viewportRuntime.viewportUpdateTask?.cancel()
        viewportRuntime.viewportUpdateTask = nil
        viewportRuntime.visibleDescriptors.removeAll(keepingCapacity: true)
        viewportRuntime.visibleAssets.removeAll(keepingCapacity: true)
        viewportRuntime.retainedAnchor = .latest
        viewportRuntime.lastResidencyPlan = .empty
        viewportRuntime.lastResidencyTarget = nil
    }

    private nonisolated static func describe(_ size: CGSize) -> String {
        "\(Int(size.width))x\(Int(size.height))"
    }

    private nonisolated static func describe(_ anchor: TimelineViewportAnchor?) -> String {
        switch anchor {
        case .latest:
            "latest"
        case let .asset(assetID, viewportCenterOffset):
            "asset:\(assetID.prefix(8))@\(Int(viewportCenterOffset))"
        case nil:
            "none"
        }
    }
}

private struct TimelineSectionView: View, Equatable {
    let section: TimelineSection
    let store: PhotosTimelineStore
    let media: MediaLibraryController
    let viewportRuntime: TimelineViewportRuntime
    let availableWidth: CGFloat
    let assetLayout: PhotosAssetLayout
    let visibilityChanged: (String, MediaRequestDescriptor?) -> Void
    let viewportChanged: (TimelineAssetSummary, Bool) -> Void
    let transitionNamespace: Namespace.ID
    let assetSelected: (TimelineAssetSummary, TimelineBucketID) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.section.summary == rhs.section.summary
            && lhs.section.loadState == rhs.section.loadState
            && lhs.section.contentRevision == rhs.section.contentRevision
            && lhs.availableWidth == rhs.availableWidth
            && lhs.assetLayout == rhs.assetLayout
            && lhs.store === rhs.store
            && lhs.media === rhs.media
            && lhs.viewportRuntime === rhs.viewportRuntime
    }

    var body: some View {
        VStack(spacing: 0) {
            switch section.loadState {
            case .unloaded, .loading:
                bucketHeader
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 88)
                    .task {
                        guard viewportRuntime.isTimelineActive else { return }
                        await store.loadBucket(section.id)
                    }
            case .loaded:
                if section.assets.isEmpty {
                    Text("No photos in this section")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 64)
                } else {
                    ForEach(Array(section.dayGroups.reversed())) { group in
                        TimelineDayAssetSection(
                            group: group,
                            media: media,
                            availableWidth: availableWidth,
                            assetLayout: assetLayout,
                            visibilityChanged: visibilityChanged,
                            viewportChanged: viewportChanged,
                            transitionNamespace: transitionNamespace,
                            assetSelected: { asset in assetSelected(asset, section.id) }
                        )
                    }
                }
            case let .failed(message):
                bucketHeader
                VStack(spacing: 8) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        Task { await store.retryBucket(section.id) }
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, minHeight: 88)
                .padding(.horizontal)
            }
        }
        .accessibilityIdentifier("timeline-section-\(section.id.rawValue)")
    }

    private var bucketHeader: some View {
        AssetSectionHeader(
            title: bucketTitle,
            subtitle: section.summary.assetCount.formatted() + " items"
        )
    }

    private var bucketTitle: String {
        section.id.displayDate?.formatted(date: .long, time: .omitted) ?? section.id.rawValue
    }
}

private struct TimelineMemoryLane: View {
    private static let cardSpacing: CGFloat = 12
    private static let edgeInset = cardSpacing / 2
    private static let phoneFallbackCardWidth: CGFloat = 190
    private static let padCardWidth: CGFloat = 200

    let memories: [TimelineMemorySummary]
    let media: MediaLibraryController

    private var cardWidth: CGFloat {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            return Self.padCardWidth
        }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let screen = (scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)?.screen else {
            return Self.phoneFallbackCardWidth
        }
        let portraitWidth = min(screen.bounds.width, screen.bounds.height)
        return (portraitWidth - (Self.edgeInset * 2) - Self.cardSpacing) / 2
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: Self.cardSpacing) {
                ForEach(Array(memories.enumerated()), id: \.element.id) { entry in
                    TimelineMemoryCard(
                        memory: entry.element,
                        media: media,
                        width: cardWidth,
                        initialDelay: TimelineCoverAnimation.cycleDuration
                            * Double(entry.offset)
                            / Double(max(1, memories.count))
                    )
                }
            }
        }
        .contentMargins(.horizontal, Self.edgeInset, for: .scrollContent)
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity)
        .ignoresSafeArea(.container, edges: .horizontal)
        .accessibilityIdentifier("memory-lane")
    }
}

private struct TimelineMemoryCard: View {
    private static let logger = Logger(
        subsystem: "io.github.ender-wang.Remmich",
        category: "TimelineMemoryCard"
    )

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase

    let memory: TimelineMemorySummary
    let media: MediaLibraryController
    let width: CGFloat
    let initialDelay: Double

    @State private var currentIndex = 0
    @State private var incomingAsset: TimelineMemoryAssetSummary?
    @State private var coverScales: [String: Double] = [:]
    @State private var coverOpacities: [String: Double] = [:]
    @State private var isPresented = false

    private var currentAsset: TimelineMemoryAssetSummary? {
        memory.assets.indices.contains(currentIndex) ? memory.assets[currentIndex] : memory.assets.first
    }

    private var renderedAssets: [TimelineMemoryAssetSummary] {
        var pair = currentAsset.map { [$0] } ?? []
        if let incomingAsset, incomingAsset.id != currentAsset?.id {
            pair.append(incomingAsset)
        }
        return pair
    }

    private var slideshowID: String {
        memory.assets.map { "\($0.id):\($0.revision.timeIntervalSinceReferenceDate)" }.joined(separator: "|")
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color(uiColor: .systemBackground)
            ForEach(renderedAssets) { asset in
                ImmichThumbnail(
                    descriptor: .init(
                        assetID: asset.id,
                        updatedAt: asset.revision,
                        derivative: .thumbnail,
                        targetPixels: .init(
                            width: Int(width * displayScale),
                            height: Int(120 * displayScale)
                        )
                    ),
                    media: media,
                    contentMode: .fill
                )
                .frame(width: width, height: 120)
                .opacity(opacity(for: asset))
                .scaleEffect(scale(for: asset), anchor: .center)
                .clipped()
                .allowsHitTesting(false)
            }
            LinearGradient(
                colors: [.clear, .black.opacity(0.65)],
                startPoint: .center,
                endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 2) {
                Text("On This Day")
                    .font(.headline)
                Text(memory.memoryAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                if memory.assets.count > 1 {
                    Text("\(memory.assets.count.formatted()) items")
                        .font(.caption2)
                }
            }
            .foregroundStyle(.white)
            .padding(12)
        }
        .frame(width: width, height: 120)
        .clipShape(.rect(cornerRadius: DesignMetrics.defaultCornerRadius))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("memory-\(memory.id)")
        .accessibilityValue(coverAccessibilityValue)
        .onAppear { isPresented = true }
        .onDisappear { isPresented = false }
        .task(id: "\(isPresented):\(scenePhase):\(reduceMotion):\(slideshowID):\(initialDelay)") {
            guard isPresented, scenePhase == .active else { return }
            Self.logger.info(
                "Memory slideshow evaluated id=\(memory.id, privacy: .public) assets=\(memory.assets.count) reduceMotion=\(reduceMotion)"
            )
            await runSlideshow()
        }
    }

    private var coverAccessibilityValue: String {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ui-testing-signed-in") {
                return currentAsset?.id ?? ""
            }
        #endif
        return ""
    }

    private func opacity(for asset: TimelineMemoryAssetSummary) -> Double {
        coverOpacities[asset.id] ?? (asset.id == currentAsset?.id && incomingAsset == nil ? 1 : 0)
    }

    private func scale(for asset: TimelineMemoryAssetSummary) -> Double {
        coverScales[asset.id] ?? 1
    }

    private func runSlideshow() async {
        guard !memory.assets.isEmpty else { return }
        if !memory.assets.indices.contains(currentIndex) {
            currentIndex = 0
        }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            coverScales = currentAsset.map { [$0.id: 1] } ?? [:]
            coverOpacities = currentAsset.map { [$0.id: 1] } ?? [:]
            incomingAsset = nil
        }
        guard !reduceMotion, memory.assets.count > 1 else { return }
        if initialDelay > 0 {
            do {
                try await Task.sleep(for: .seconds(initialDelay))
            } catch { return }
        }

        var timeBeforeFadeOut = TimelineCoverAnimation.initialHold
        while !Task.isCancelled {
            withTransaction(transaction) {
                incomingAsset = nil
                coverScales = coverScales.filter { $0.key == currentAsset?.id }
                coverOpacities = coverOpacities.filter { $0.key == currentAsset?.id }
            }
            guard !reduceMotion else { return }

            let nextIndex = (currentIndex + 1) % memory.assets.count
            let next = memory.assets[nextIndex]
            guard next.id != currentAsset?.id else { return }
            withTransaction(transaction) {
                incomingAsset = next
                coverScales[next.id] = 1
                coverOpacities[next.id] = 0
            }

            if timeBeforeFadeOut == TimelineCoverAnimation.initialHold, let currentAsset {
                withAnimation(.linear(duration: TimelineCoverAnimation.zoomDuration)) {
                    coverScales[currentAsset.id] = TimelineCoverAnimation.zoomScale
                }
            }
            do {
                try await Task.sleep(for: .seconds(timeBeforeFadeOut))
            } catch { return }
            if let currentAsset {
                withAnimation(.linear(duration: TimelineCoverAnimation.fadeDuration)) {
                    coverOpacities[currentAsset.id] = 0
                }
            }
            do {
                try await Task.sleep(for: .seconds(TimelineCoverAnimation.fadeDuration))
            } catch { return }
            withAnimation(.linear(duration: TimelineCoverAnimation.fadeDuration)) {
                coverOpacities[next.id] = 1
            }
            withAnimation(.linear(duration: TimelineCoverAnimation.zoomDuration)) {
                coverScales[next.id] = TimelineCoverAnimation.zoomScale
            }
            do {
                try await Task.sleep(for: .seconds(TimelineCoverAnimation.fadeDuration))
            } catch { return }
            withTransaction(transaction) {
                currentIndex = nextIndex
                incomingAsset = nil
            }
            timeBeforeFadeOut = TimelineCoverAnimation.initialHold
        }
    }
}

private struct TimelineRefreshError: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry", action: retry)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.08))
        .accessibilityIdentifier("timeline-refresh-error")
    }
}

#Preview("Loaded") {
    let store = PhotosTimelineStore(reader: PreviewTimelineReader())
    NavigationStack {
        PhotosView(
            store: store,
            presentation: .init(),
            media: .init(),
            assetDetails: PreviewTimelineReader(),
            navigationPath: .constant([]),
            tabBarTop: .constant(0),
            compactChromeChanged: { _ in },
            showAccount: {}
        )
    }
}

#Preview("Large Text") {
    let store = PhotosTimelineStore(reader: PreviewTimelineReader())
    NavigationStack {
        PhotosView(
            store: store,
            presentation: .init(),
            media: .init(),
            assetDetails: PreviewTimelineReader(),
            navigationPath: .constant([]),
            tabBarTop: .constant(0),
            compactChromeChanged: { _ in },
            showAccount: {}
        )
    }
    .environment(\.dynamicTypeSize, .accessibility3)
}
