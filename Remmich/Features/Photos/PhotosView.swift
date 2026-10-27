import Nuke
import OSLog
import SwiftUI
import UIKit

private struct TimelineMemoryGradientBackdrop: UIViewRepresentable {
    let visible: Bool
    let extended: Bool
    let reduceMotion: Bool

    func makeUIView(context _: Context) -> TimelineMemoryGradientBackdropView {
        let view = TimelineMemoryGradientBackdropView()
        view.setVisible(visible, animated: false)
        view.setExtended(extended, animated: false)
        return view
    }

    func updateUIView(_ uiView: TimelineMemoryGradientBackdropView, context _: Context) {
        uiView.setVisible(visible, animated: !reduceMotion)
        uiView.setExtended(extended, animated: !reduceMotion)
    }
}

@MainActor
private final class TimelineMemoryGradientBackdropView: UIView {
    private let effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private let gradientMask = CAGradientLayer()
    private var visibilityAnimator: UIViewPropertyAnimator?
    private var visible: Bool?
    private var extended: Bool?

    private let extendedLocations: [NSNumber] = [0, 0.48, 0.78, 0.94, 1]
    private let statusLocations: [NSNumber] = [0, 0.18, 0.30, 0.42, 0.52]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        effectView.isUserInteractionEnabled = false
        addSubview(effectView)
        gradientMask.colors = [
            UIColor.black.cgColor,
            UIColor.black.withAlphaComponent(0.78).cgColor,
            UIColor.black.withAlphaComponent(0.32).cgColor,
            UIColor.black.withAlphaComponent(0.08).cgColor,
            UIColor.clear.cgColor,
        ]
        gradientMask.locations = extendedLocations
        gradientMask.startPoint = CGPoint(x: 0.5, y: 0)
        gradientMask.endPoint = CGPoint(x: 0.5, y: 1)
        effectView.layer.mask = gradientMask
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        effectView.frame = bounds
        gradientMask.frame = effectView.bounds
    }

    func setVisible(_ visible: Bool, animated: Bool) {
        guard self.visible != visible else { return }
        self.visible = visible
        visibilityAnimator?.stopAnimation(true)
        visibilityAnimator = nil
        guard animated else {
            alpha = visible ? 1 : 0
            return
        }
        let animator = UIViewPropertyAnimator(duration: 0.25, curve: .easeInOut) { [weak self] in
            self?.alpha = visible ? 1 : 0
        }
        visibilityAnimator = animator
        animator.addCompletion { [weak self, weak animator] _ in
            guard let self, let animator, visibilityAnimator === animator else { return }
            visibilityAnimator = nil
        }
        animator.startAnimation()
    }

    func setExtended(_ extended: Bool, animated: Bool) {
        guard self.extended != extended else { return }
        self.extended = extended

        let targetLocations = extended ? extendedLocations : statusLocations
        gradientMask.removeAnimation(forKey: "memory-gradient-coverage")
        let sourceLocations = gradientMask.presentation()?.locations ?? gradientMask.locations
        gradientMask.locations = targetLocations

        guard animated, let sourceLocations else {
            return
        }

        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = sourceLocations
        animation.toValue = targetLocations
        animation.duration = 0.25
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        gradientMask.add(animation, forKey: "memory-gradient-coverage")
    }
}

nonisolated enum TimelineViewportAnchor: Equatable {
    case latest
    case asset(id: String, viewportCenterOffset: CGFloat)
}

nonisolated enum TimelineScrollMotionPhase: String, Equatable {
    case idle
    case interacting
    case decelerating

    var isMoving: Bool {
        self != .idle
    }
}

nonisolated enum TimelineRotationScrollPolicy {
    static func shouldCancelRotation(
        phase: TimelineScrollMotionPhase,
        rotationOwnsScrollCallbacks: Bool
    ) -> Bool {
        phase.isMoving && !rotationOwnsScrollCallbacks
    }

    static func releasesRotationOwnership(phase: TimelineScrollMotionPhase) -> Bool {
        phase == .idle
    }
}

nonisolated enum TimelineViewportAnchorRetention {
    static let latestBoundary: CGFloat = 24

    static func restoredUnitAnchor(
        viewportCenterOffset: CGFloat,
        viewportHeight: CGFloat,
        rowHeight: CGFloat
    ) -> UnitPoint {
        let travel = viewportHeight - rowHeight
        guard abs(travel) > 0.5 else { return .center }
        let y = min(1, max(0, 0.5 + viewportCenterOffset / travel))
        return UnitPoint(x: 0.5, y: y)
    }
}

nonisolated struct TimelineAssetFrameSnapshot: Equatable {
    let layoutKey: TimelineDeterministicLayout.Key
    let containerSize: CGSize
    let frames: [String: CGRect]

    var visualCenter: CGPoint {
        CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)
    }

    var visibleFrames: [String: CGRect] {
        guard containerSize.width > 0, containerSize.height > 0 else { return [:] }
        let viewport = CGRect(origin: .zero, size: containerSize)
        return frames.filter { _, frame in
            frame.width > 0 && frame.height > 0 && frame.intersects(viewport)
        }
    }

    func assetNearestVisualCenter() -> (id: String, verticalOffset: CGFloat)? {
        let visible = visibleFrames
        guard let minimumVerticalDistance = visible.values.map({
            abs($0.midY - visualCenter.y)
        }).min() else { return nil }

        // Cells in one row share a vertical center. First choose that row,
        // then choose its cell closest to the horizontal visual center.
        let rowTolerance: CGFloat = 1
        return visible
            .filter { _, frame in
                abs(abs(frame.midY - visualCenter.y) - minimumVerticalDistance) <= rowTolerance
            }
            .min { lhs, rhs in
                abs(lhs.value.midX - visualCenter.x) < abs(rhs.value.midX - visualCenter.x)
            }
            .map { entry in
                (entry.key, entry.value.midY - visualCenter.y)
            }
    }
}

nonisolated enum TimelineAssetFrameSnapshotPolicy {
    static func isCoherent(_ snapshot: TimelineAssetFrameSnapshot) -> Bool {
        !snapshot.visibleFrames.isEmpty
    }
}

nonisolated enum TimelineRotationCapturePolicy {
    static func shouldCapture(
        generation: Int,
        isRotating: Bool,
        isTimelineActive: Bool,
        sourceSizes: [CGSize],
        targetSize: CGSize
    ) -> Bool {
        guard generation > 0,
              isRotating,
              isTimelineActive,
              targetSize.width > 0,
              targetSize.height > 0
        else { return false }

        return sourceSizes.contains { sourceSize in
            abs(sourceSize.width - targetSize.width) > 1
                || abs(sourceSize.height - targetSize.height) > 1
        }
    }
}

@MainActor
private final class TimelineViewportRuntime {
    var isTimelineActive = false
    var visibleDescriptors: [String: MediaRequestDescriptor] = [:]
    var visibleAssets: [String: Date] = [:]
    var viewportUpdateTask: Task<Void, Never>?
    var chromeTracker = PhotosChromeTracker()
    var lastResidencyPlan = TimelineResidencyPlan.empty
    var lastResidencyTarget: MediaPixelSize?
}

struct PhotosChromeTracker {
    private(set) var isCompact = false
    private var travel: CGFloat = 0
    private var reachedLatestDuringCurrentScroll = false
    private var leftLatestDuringCurrentScroll = false

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
            if userScrolling, offsetDelta >= 0, leftLatestDuringCurrentScroll {
                reachedLatestDuringCurrentScroll = true
            }
            guard isCompact else { return nil }
            isCompact = false
            return false
        }
        if userScrolling {
            leftLatestDuringCurrentScroll = true
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
        leftLatestDuringCurrentScroll = false
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
    private nonisolated static let coarserLayoutVisualEndpoint: CGFloat = 0.6
    private nonisolated static let finerLayoutVisualEndpoint: CGFloat = 1.5

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
    @State private var viewportRuntime = TimelineViewportRuntime()
    @State private var compactChrome = false
    @State private var semanticMemoryScaleVisible = true
    @State private var viewerOwnsTimelineChrome = false
    @State private var viewerChromeReleaseTask: Task<Void, Never>?
    @State private var hiddenLivePhotoBadgeAssetID: String?
    @State private var hiddenReturningThumbnailAssetID: String?
    @State private var libraryRange: TimelineLibraryRange = .all
    @State private var initialAssetByRoute: [PhotosRangeRoute: String] = [:]
    @State private var viewerRoute: AssetViewerRoute?
    @State private var memoryCardFrames: [String: CGRect] = [:]
    @State private var memoryLaneFrame: CGRect?
    @State private var memoryCoverAssetIDs: [String: String] = [:]
    @State private var hiddenMemoryCardID: String?
    @State private var loadingMemoryID: String?
    @State private var memoryPresentationTask: Task<Void, Never>?
    @State private var memoryViewerErrorMessage: String?
    @State private var memoryViewerContentOpacity = 1.0
    @State private var memoryViewerOpensFromSource = true
    @State private var memoryViewerIsSwitching = false
    @State private var memoryViewerDismissalRequest = 0
    @State private var semanticCatalog: TimelineSemanticCatalog?
    @State private var semanticCatalogRevision: UInt64 = 0
    @State private var semanticRuntime = TimelineSemanticRuntime()
    @State private var semanticLatestRequest = 0
    @State private var semanticLatestTask: Task<Void, Never>?

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
        .fullScreenCover(item: fullScreenViewerRoute) { route in
            assetViewer(route: route, opensFromSource: true)
        }
        .overlay {
            if let route = memoryOverlayRoute {
                assetViewer(
                    route: route,
                    opensFromSource: memoryViewerOpensFromSource
                )
                .allowsHitTesting(memoryViewerContentOpacity > 0.01)
                .zIndex(10)
            }
        }
        .alert(
            "Couldn’t Open Memory",
            isPresented: Binding(
                get: { memoryViewerErrorMessage != nil },
                set: { presented in
                    if !presented {
                        memoryViewerErrorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(memoryViewerErrorMessage ?? "The memory’s assets aren’t available.")
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
            rotationState?.setVisualHandoffEligible(
                false,
                for: tabDestination
            )
            media.beginTimelinePresentation()
            if isTimelineActive {
                media.beginTimelineContentPresentation(contentName)
            }
        }
        .task { await store.load() }
        .task(id: store.semanticContentRevision) {
            let revision = store.semanticContentRevision
            let assets = store.semanticAssetsSnapshot()
            let build = Task.detached(priority: .userInitiated) {
                TimelineSemanticCatalog(assets: assets)
            }
            let catalog = await withTaskCancellationHandler {
                await build.value
            } onCancel: {
                build.cancel()
            }
            guard !Task.isCancelled, revision == store.semanticContentRevision else { return }
            semanticCatalog = catalog
            semanticCatalogRevision = revision
        }
        .onChange(of: isTimelineActive) { _, isVisible in
            viewportRuntime.isTimelineActive = isVisible
            // The collection performs deterministic rotation directly. It does
            // not register for the retired SwiftUI scroll-settlement gate.
            rotationState?.setVisualHandoffEligible(false, for: tabDestination)
            if isVisible {
                media.beginTimelineContentPresentation(contentName)
            }
        }
        .onChange(of: scrollToLatestRequest) {
            if memoryOverlayRoute != nil {
                memoryViewerDismissalRequest &+= 1
                return
            }
            semanticLatestTask?.cancel()
            semanticLatestTask = Task { @MainActor in
                defer { store.completeJump(); semanticLatestTask = nil }
                guard let newest = store.bucketSummaries.first?.id,
                      await store.prepareJump(to: newest), !Task.isCancelled else { return }
                if store.semanticAssetsSnapshot().isEmpty {
                    await store.loadOlderSemanticPage()
                }
                let revision = store.semanticContentRevision
                let assets = store.semanticAssetsSnapshot()
                let build = Task.detached(priority: .userInitiated) { TimelineSemanticCatalog(assets: assets) }
                let catalog = await withTaskCancellationHandler { await build.value } onCancel: { build.cancel() }
                guard !Task.isCancelled else { return }
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    if revision >= semanticCatalogRevision {
                        semanticCatalog = catalog
                        semanticCatalogRevision = revision
                    }
                    navigationPath = []
                    libraryRange = .all
                    semanticLatestRequest &+= 1
                }
            }
        }
        .onChange(of: requestedLibraryRange, initial: true) { _, requestedLibraryRange in
            guard let requestedLibraryRange else { return }
            navigationPath.removeAll()
            libraryRange = requestedLibraryRange.range
            requestedLibraryRangeHandled()
        }
        .onChange(of: libraryRange, initial: true) { _, range in
            setSemanticMemoryScaleVisible(range == .all)
        }
        .onDisappear {
            semanticLatestTask?.cancel()
            semanticLatestTask = nil
            if memoryOverlayRoute != nil {
                closeViewer()
            }
            rotationState?.setVisualHandoffEligible(false, for: tabDestination)
            viewportRuntime.viewportUpdateTask?.cancel()
            viewportRuntime.viewportUpdateTask = nil
            memoryPresentationTask?.cancel()
            memoryPresentationTask = nil
            loadingMemoryID = nil
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
            semanticTimeline
                .opacity(navigationPath.isEmpty ? 1 : 0)
                .allowsHitTesting(navigationPath.isEmpty)
                .accessibilityHidden(!navigationPath.isEmpty)

            if let route = navigationPath.last {
                rangeDestination(route)
            }
        }
    }

    private var semanticScale: TimelineSemanticScale {
        switch libraryRange {
        case .all: presentation.preferences.assetLayout == .square ? .square : .natural
        case .day: .day
        case .week: .week
        case .month: .month
        case .year: .year
        }
    }

    private var semanticTimeline: some View {
        GeometryReader { geometry in
            let frame = geometry.frame(in: .global)
            let isPhone = UIDevice.current.userInterfaceIdiom == .phone
            let barHeight = tabBarTop > 0
                ? max(0, frame.maxY - tabBarTop)
                : TimelineRangeGridLayout.minimumBottomNavigationHeight(isPhone: isPhone, viewportSize: geometry.size)
            let topInset = TimelineMemoryLaneSafeArea.topInset(
                proposed: geometry.safeAreaInsets.top,
                window: TimelineMemoryLaneSafeArea.activeWindowTopInset
            )
            // Keep the row's scroll clearance while compact chrome hides it,
            // so showing the row does not move the timeline underneath it.
            let bottomClearance = isPhone ? barHeight : 0
            let reservesMemoryLane = semanticScale.isAssets
                && navigationPath.isEmpty
                && store.memoryLaneState == .loaded
                && !store.memories.isEmpty
            let topClearance = topInset + (reservesMemoryLane ? TimelineMemoryLaneSafeArea.laneHeight : 0)
            Group {
                if let semanticCatalog {
                    TimelineSemanticCollectionView(
                        catalog: semanticCatalog, revision: semanticCatalogRevision,
                        scale: semanticScale, media: media, namespace: viewerNamespace,
                        bottomClearance: bottomClearance, topClearance: topClearance,
                        runtime: semanticRuntime,
                        latestRequest: semanticLatestRequest,
                        isActive: isTabContentActivated && navigationPath.isEmpty && viewerRoute == nil,
                        hiddenThumbnailID: hiddenReturningThumbnailAssetID,
                        hiddenLivePhotoID: hiddenLivePhotoBadgeAssetID,
                        selectAsset: { asset, assets in
                            presentViewer(AssetViewerRoute(selectedAsset: asset, initialAssets: assets,
                                                           origin: .timeline(bucketID: semanticBucketID(for: asset), contentName: contentName)))
                        },
                        selectGroup: { route, coverID in
                            selectRoute(semanticRoute(route, coverID: coverID), initialAssetID: coverID)
                        },
                        scaleChanged: semanticScaleChanged,
                        transitionScaleChanged: semanticTransitionScaleChanged,
                        scrolled: { delta, gap, userScrolling in
                            guard !viewerOwnsTimelineChrome else { return }
                            if let compact = viewportRuntime.chromeTracker.update(offsetDelta: delta, bottomGap: gap,
                                                                                  userScrolling: userScrolling, programmaticJump: false)
                            {
                                setCompactChrome(compact)
                            }
                        },
                        visibleAssetsChanged: { assets, target, renderedScale in
                            let plan = renderedScale.isAssets
                                ? store.residencyPlan(visibleAssetIDs: Set(assets.map(\.id)))
                                : TimelineSemanticResidencyPolicy.groupedPlan(visibleAssets: assets)
                            guard plan != viewportRuntime.lastResidencyPlan || target != viewportRuntime.lastResidencyTarget else { return }
                            viewportRuntime.lastResidencyPlan = plan
                            viewportRuntime.lastResidencyTarget = target
                            media.updateTimelineResidency(plan, targetPixels: target)
                        },
                        refresh: { await store.refresh() },
                        loadOlder: { await store.loadOlderSemanticPage() },
                        focusChanged: { asset in
                            store.updateVisibleAnchor(.init(bucketID: semanticBucketID(for: asset), assetID: asset.id))
                        }
                    )
                } else {
                    LoadingStateView()
                }
            }
            .overlay {
                if semanticCatalog?.assets.isEmpty == true {
                    switch store.semanticHistoryState {
                    case .empty:
                        Text("No displayable assets in these periods.").foregroundStyle(.secondary)
                    case .failed:
                        Button("Retry loading timeline") { Task { await store.loadOlderSemanticPage() } }
                    case .idle, .loading, .loaded:
                        LoadingStateView()
                    }
                }
            }
            .overlay(alignment: .top) {
                semanticMemoryLane(topInset: topInset)
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: compactChrome)
        }
        .ignoresSafeArea(.container, edges: [.top, .horizontal, .bottom])
        .safeAreaInset(edge: .top, spacing: 0) {
            if case let .failed(message) = store.refreshState {
                TimelineRefreshError(message: message) {
                    Task { await store.refresh() }
                }
            } else if case let .failed(message) = store.semanticHistoryState {
                TimelineRefreshError(message: message) { Task { await store.loadOlderSemanticPage() } }
            }
        }
    }

    private func semanticMemoryLane(topInset: CGFloat) -> some View {
        ZStack(alignment: .top) {
            TimelineMemoryGradientBackdrop(
                visible: memoryMaterialVisible,
                extended: memoryLaneVisible,
                reduceMotion: reduceMotion
            )
            .frame(height: topInset + TimelineMemoryLaneSafeArea.laneHeight)
            .ignoresSafeArea(.container, edges: .top)

            if memoryLaneVisible {
                TimelineMemoryLane(
                    memories: store.memories, media: media, selectedMemoryID: presentedMemoryID,
                    frozenMemoryID: nil, hiddenMemoryID: nil, loadingMemoryID: loadingMemoryID,
                    preferredAssetIDs: memoryCoverAssetIDs, select: presentMemory,
                    laneFrameChanged: updateMemoryLaneFrame, frameChanged: updateMemoryCardFrame
                )
                .frame(height: 120)
                .padding(.bottom, 12)
                .padding(.top, topInset)
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(height: topInset + TimelineMemoryLaneSafeArea.laneHeight, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .top)
        .allowsHitTesting(memoryLaneVisible)
        .accessibilityHidden(!memoryLaneVisible)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: memoryLaneVisible)
    }

    private func semanticScaleChanged(_ scale: TimelineSemanticScale) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            switch scale {
            case .square, .natural:
                do { try presentation.setAssetLayout(scale == .square ? .square : .naturalAspect) }
                catch { Self.logger.error("Failed to persist semantic layout: \(error.localizedDescription, privacy: .public)") }
                libraryRange = .all
            case .day: libraryRange = .day
            case .week: libraryRange = .week
            case .month: libraryRange = .month
            case .year: libraryRange = .year
            }
        }
    }

    private func semanticTransitionScaleChanged(_ targetScale: TimelineSemanticScale) {
        setSemanticMemoryScaleVisible(targetScale.isAssets)
    }

    private func setSemanticMemoryScaleVisible(_ visible: Bool) {
        guard semanticMemoryScaleVisible != visible else { return }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
            semanticMemoryScaleVisible = visible
        }
    }

    private func semanticBucketID(for asset: TimelineAssetSummary) -> TimelineBucketID {
        let day = TimelineCaptureDay(capturedAt: asset.capturedAt)
        return semanticBucketID(for: day.displayDate!)
    }

    private func semanticBucketID(for date: Date) -> TimelineBucketID {
        let day = TimelineCaptureDay(capturedAt: date)
        return store.bucketSummaries.first { summary in
            guard let date = summary.id.displayDate else { return false }
            let other = TimelineCaptureDay(capturedAt: date)
            return day.year == other.year && day.month == other.month
        }?.id ?? TimelineBucketID(rawValue: String(format: "%04d-%02d-01", day.year, day.month))
    }

    private func semanticRoute(_ route: PhotosRangeRoute, coverID: String?) -> PhotosRangeRoute {
        switch route {
        case let .day(bucket, day):
            return .day(semanticBucketID(for: bucket.displayDate ?? day.displayDate!), day)
        case let .month(bucket):
            return .month(semanticBucketID(for: bucket.displayDate!))
        case let .week(bucket, week, scope):
            var owner = semanticBucketID(for: bucket.displayDate!)
            if !store.bucketSummaries.contains(where: { $0.id == owner }),
               let coverID, let catalog = semanticCatalog, let index = catalog.assetIndexes[coverID]
            {
                owner = semanticBucketID(for: catalog.assets[index])
            }
            return .week(owner, week, scope)
        case .year:
            return route
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
                presentViewer(AssetViewerRoute(
                    selectedAsset: asset,
                    initialAssets: assets,
                    origin: .scoped(route: route, contentName: contentName)
                ))
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
                semanticRuntime.changeScale(coarser: false)
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

        semanticRuntime.changeScale(coarser: gesture.direction == .coarser)
    }

    nonisolated static func naturalAspectProgress(
        magnification: CGFloat,
        layout: PhotosAssetLayout
    ) -> CGFloat {
        switch layout {
        case .square:
            let distance = max(0, 1 - magnification)
            let visualDistance = 1 - Self.coarserLayoutVisualEndpoint
            return min(1, distance / visualDistance)
        case .naturalAspect:
            let distance = max(0, magnification - 1)
            let visualDistance = Self.finerLayoutVisualEndpoint - 1
            return 1 - min(1, distance / visualDistance)
        }
    }

    private var memoryOverlayRoute: AssetViewerRoute? {
        guard let viewerRoute, case .memory = viewerRoute.origin else { return nil }
        return viewerRoute
    }

    private var fullScreenViewerRoute: Binding<AssetViewerRoute?> {
        Binding(
            get: {
                guard let route = viewerRoute else { return nil }
                if case .memory = route.origin {
                    return nil
                }
                return route
            },
            set: { route in
                if let route {
                    viewerRoute = route
                } else if let viewerRoute, case .memory = viewerRoute.origin {
                    return
                } else {
                    closeViewer()
                }
            }
        )
    }

    private func assetViewer(
        route: AssetViewerRoute,
        opensFromSource: Bool
    ) -> some View {
        AssetViewerView(
            route: route,
            store: store,
            media: media,
            assetDetails: assetDetails,
            tabBarTop: tabBarTop,
            opensFromSource: opensFromSource,
            memoryContentOpacity: memoryViewerContentOpacity,
            memoryRowFrame: memoryLaneFrame,
            dismissalRequest: memoryViewerDismissalRequest,
            memoryBoundaryChanged: movePresentedMemory,
            namespace: viewerNamespace,
            close: closeViewer,
            visibilityChanged: { visible in
                if !visible,
                   memoryViewerIsSwitching,
                   case .memory = route.origin
                {
                    return
                }
                if case .memory = route.origin {
                    // The embedded memory panel intentionally leaves the native navbar usable.
                } else {
                    viewerVisibilityChanged(visible)
                }
                if !visible {
                    hiddenReturningThumbnailAssetID = nil
                    hiddenMemoryCardID = nil
                    revealReturningLivePhotoBadge()
                }
            },
            returningLivePhotoBadgeChanged: { assetID in
                guard case .memory = route.origin else {
                    setReturningLivePhotoBadge(assetID)
                    return
                }
            },
            returningTimelineThumbnailChanged: { assetID in
                setReturningViewerSource(assetID, route: route)
            },
            dismissalTarget: { assetID in
                viewerDismissalTargetFrame(
                    for: assetID,
                    aspectRatio: route.selectedAsset.aspectRatio,
                    route: route
                )
            }
        )
    }

    private var presentedMemoryID: String? {
        guard let viewerRoute, case let .memory(context) = viewerRoute.origin else {
            return nil
        }
        return context.id
    }

    private func presentMemory(
        _ memory: TimelineMemorySummary,
        coverAssetID: String
    ) {
        let replacesPresentedMemory = presentedMemoryID != nil
        guard loadingMemoryID == nil,
              !memoryViewerIsSwitching,
              viewerRoute == nil || replacesPresentedMemory,
              presentedMemoryID != memory.id
        else { return }
        memoryPresentationTask?.cancel()
        memoryCoverAssetIDs[memory.id] = coverAssetID

        let cachedAssets = store.cachedMemoryAssets(for: memory)
        if cachedAssets.count == Set(memory.assets.map(\.id)).count,
           let route = memoryRoute(
               for: memory,
               coverAssetID: coverAssetID,
               assets: cachedAssets
           )
        {
            memoryCoverAssetIDs[memory.id] = route.selectedAsset.id
            if replacesPresentedMemory {
                memoryPresentationTask = Task { @MainActor in
                    await replaceMemoryViewer(with: route)
                    memoryPresentationTask = nil
                }
            } else {
                memoryViewerContentOpacity = 1
                memoryViewerOpensFromSource = true
                presentViewer(route)
            }
            return
        }

        loadingMemoryID = memory.id
        memoryPresentationTask = Task { @MainActor in
            let assets = await store.memoryAssets(for: memory)
            guard !Task.isCancelled else { return }
            loadingMemoryID = nil
            memoryPresentationTask = nil
            guard let route = memoryRoute(
                for: memory,
                coverAssetID: coverAssetID,
                assets: assets
            )
            else {
                memoryViewerErrorMessage = "The photos in this memory aren’t available in the current library."
                return
            }
            memoryCoverAssetIDs[memory.id] = route.selectedAsset.id
            if replacesPresentedMemory {
                await replaceMemoryViewer(with: route)
            } else {
                memoryViewerContentOpacity = 1
                memoryViewerOpensFromSource = true
                presentViewer(route)
            }
        }
    }

    private func movePresentedMemory(by offset: Int) -> Bool {
        guard offset != 0,
              let presentedMemoryID,
              !memoryViewerIsSwitching,
              loadingMemoryID == nil,
              let selectedIndex = store.memories.firstIndex(where: { $0.id == presentedMemoryID })
        else { return false }
        let targetIndex = selectedIndex + offset.signum()
        guard store.memories.indices.contains(targetIndex) else { return false }
        let memory = store.memories[targetIndex]
        guard let coverAssetID = memoryCoverAssetIDs[memory.id] ?? memory.assets.first?.id else { return false }
        presentMemory(memory, coverAssetID: coverAssetID)
        return true
    }

    private func memoryRoute(
        for memory: TimelineMemorySummary,
        coverAssetID: String,
        assets: [TimelineAssetSummary]
    ) -> AssetViewerRoute? {
        guard let selectedAsset = assets.first(where: { $0.id == coverAssetID })
            ?? assets.first
        else { return nil }
        return AssetViewerRoute(
            selectedAsset: selectedAsset,
            initialAssets: assets,
            origin: .memory(AssetViewerMemoryContext(
                id: memory.id,
                memoryAt: memory.memoryAt,
                sourceYear: memory.sourceYear
            ))
        )
    }

    private func replaceMemoryViewer(with route: AssetViewerRoute) async {
        memoryViewerIsSwitching = true
        defer { memoryViewerIsSwitching = false }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
            memoryViewerContentOpacity = 0
        }
        if !reduceMotion {
            try? await Task.sleep(for: .milliseconds(170))
            guard !Task.isCancelled else { return }
        }

        memoryViewerOpensFromSource = false
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if case let .memory(context) = route.origin {
                hiddenMemoryCardID = context.id
            }
            viewerRoute = route
        }

        await Task.yield()
        withAnimation(reduceMotion ? nil : .easeIn(duration: 0.18)) {
            memoryViewerContentOpacity = 1
        }
        if !reduceMotion {
            try? await Task.sleep(for: .milliseconds(190))
        }
        guard !Task.isCancelled else { return }
    }

    private func updateMemoryCardFrame(_ frame: CGRect, for memoryID: String) {
        guard frame.width > 0, frame.height > 0 else { return }
        if let current = memoryCardFrames[memoryID],
           abs(current.minX - frame.minX) < 0.5,
           abs(current.minY - frame.minY) < 0.5,
           abs(current.width - frame.width) < 0.5,
           abs(current.height - frame.height) < 0.5
        {
            return
        }
        memoryCardFrames[memoryID] = frame
    }

    private func updateMemoryLaneFrame(_ frame: CGRect) {
        guard frame.width > 0, frame.height > 0 else { return }
        if let current = memoryLaneFrame,
           abs(current.minX - frame.minX) < 0.5,
           abs(current.minY - frame.minY) < 0.5,
           abs(current.width - frame.width) < 0.5,
           abs(current.height - frame.height) < 0.5
        {
            return
        }
        memoryLaneFrame = frame
    }

    private func presentViewer(_ route: AssetViewerRoute) {
        hiddenLivePhotoBadgeAssetID = nil
        hiddenReturningThumbnailAssetID = nil
        viewerChromeReleaseTask?.cancel()
        viewerChromeReleaseTask = nil
        viewerOwnsTimelineChrome = true
        viewportRuntime.chromeTracker.scrollingEnded()
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if case let .memory(context) = route.origin {
                memoryViewerContentOpacity = 1
                memoryViewerOpensFromSource = true
                memoryViewerIsSwitching = false
                hiddenMemoryCardID = context.id
            } else {
                hiddenMemoryCardID = nil
            }
            viewerRoute = route
        }
    }

    private func closeViewer() {
        viewerRoute = nil
        hiddenMemoryCardID = nil
        memoryViewerContentOpacity = 1
        memoryViewerOpensFromSource = true
        memoryViewerIsSwitching = false
        viewerChromeReleaseTask?.cancel()
        viewerChromeReleaseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, viewerRoute == nil else { return }
            viewportRuntime.chromeTracker.scrollingEnded()
            viewerOwnsTimelineChrome = false
            viewerChromeReleaseTask = nil
        }
    }

    private func setReturningLivePhotoBadge(_ assetID: String?) {
        guard hiddenLivePhotoBadgeAssetID != assetID else { return }
        if let assetID {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                hiddenLivePhotoBadgeAssetID = assetID
            }
        } else {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
                hiddenLivePhotoBadgeAssetID = nil
            }
        }
    }

    private func setReturningTimelineThumbnail(_ assetID: String?) {
        guard hiddenReturningThumbnailAssetID != assetID else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            hiddenReturningThumbnailAssetID = assetID
        }
    }

    private func setReturningViewerSource(
        _ assetID: String?,
        route: AssetViewerRoute
    ) {
        guard case let .memory(context) = route.origin else {
            setReturningTimelineThumbnail(assetID)
            return
        }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if let assetID {
                memoryCoverAssetIDs[context.id] = assetID
                hiddenMemoryCardID = context.id
            } else {
                hiddenMemoryCardID = nil
            }
        }
    }

    private func revealReturningLivePhotoBadge() {
        guard hiddenLivePhotoBadgeAssetID != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled, viewerRoute == nil else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
                hiddenLivePhotoBadgeAssetID = nil
            }
        }
    }

    private func viewerDismissalTargetFrame(
        for assetID: String,
        aspectRatio: Double,
        route: AssetViewerRoute
    ) -> AssetViewerDismissalTarget? {
        if case let .memory(context) = route.origin,
           let frame = memoryCardFrames[context.id]
        {
            return AssetViewerDismissalTarget(
                imageFrame: frame,
                cornerRadius: DesignMetrics.defaultCornerRadius,
                fillsFrame: true
            )
        }
        guard showsMainTimeline,
              let target = semanticRuntime.dismissalTarget(assetID: assetID, aspectRatio: aspectRatio)
        else {
            return nil
        }
        return target
    }

    private var memoryMaterialVisible: Bool {
        !compactChrome
            && navigationPath.isEmpty
            && store.memoryLaneState == .loaded
            && !store.memories.isEmpty
    }

    private var memoryLaneVisible: Bool {
        memoryMaterialVisible && semanticMemoryScaleVisible
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
        guard isTimelineActive else { return }
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
}

nonisolated enum TimelineMemoryLaneSafeArea {
    static let laneHeight: CGFloat = 132

    static func topInset(proposed: CGFloat, window: CGFloat) -> CGFloat {
        max(0, max(proposed, window))
    }

    @MainActor
    static var activeWindowTopInset: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first
        return window?.safeAreaInsets.top ?? 0
    }
}

nonisolated enum TimelineSemanticResidencyPolicy {
    static let groupedAssetLimit = 96

    static func groupedPlan(visibleAssets: [TimelineAssetSummary]) -> TimelineResidencyPlan {
        var seen = Set<String>()
        let bounded = visibleAssets.filter { seen.insert($0.id).inserted }.prefix(groupedAssetLimit)
        return TimelineResidencyPlan(
            newestAssets: [],
            viewportAssets: Array(bounded),
            prefetchAssets: []
        )
    }
}

private struct TimelineMemoryLane: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let cardSpacing: CGFloat = 12
    private static let edgeInset = cardSpacing / 2
    private static let phoneFallbackCardWidth: CGFloat = 190
    private static let padCardWidth: CGFloat = 200

    let memories: [TimelineMemorySummary]
    let media: MediaLibraryController
    let selectedMemoryID: String?
    let frozenMemoryID: String?
    let hiddenMemoryID: String?
    let loadingMemoryID: String?
    let preferredAssetIDs: [String: String]
    let select: (TimelineMemorySummary, String) -> Void
    let laneFrameChanged: (CGRect) -> Void
    let frameChanged: (CGRect, String) -> Void

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
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: Self.cardSpacing) {
                    ForEach(Array(memories.enumerated()), id: \.element.id) { entry in
                        TimelineMemoryCard(
                            memory: entry.element,
                            media: media,
                            width: cardWidth,
                            initialDelay: TimelineCoverAnimation.cycleDuration
                                * Double(entry.offset)
                                / Double(max(1, memories.count)),
                            preferredAssetID: preferredAssetIDs[entry.element.id],
                            isFrozen: frozenMemoryID == entry.element.id
                                || loadingMemoryID == entry.element.id,
                            isHidden: hiddenMemoryID == entry.element.id,
                            isLoading: loadingMemoryID == entry.element.id,
                            select: { assetID in select(entry.element, assetID) },
                            frameChanged: { frame in frameChanged(frame, entry.element.id) }
                        )
                        .id(entry.element.id)
                    }
                }
            }
            .contentMargins(.horizontal, Self.edgeInset, for: .scrollContent)
            .scrollIndicators(.hidden)
            .onChange(of: selectedMemoryID) { _, memoryID in
                guard let memoryID else { return }
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.32)) {
                    proxy.scrollTo(memoryID, anchor: .center)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .ignoresSafeArea(.container, edges: .horizontal)
        .accessibilityIdentifier("memory-lane")
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            laneFrameChanged(frame)
        }
    }
}

private struct TimelineMemoryCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase

    let memory: TimelineMemorySummary
    let media: MediaLibraryController
    let width: CGFloat
    let initialDelay: Double
    let preferredAssetID: String?
    let isFrozen: Bool
    let isHidden: Bool
    let isLoading: Bool
    let select: (String) -> Void
    let frameChanged: (CGRect) -> Void

    @State private var currentIndex = 0
    @State private var incomingAsset: TimelineMemoryAssetSummary?
    @State private var coverScales: [String: Double] = [:]
    @State private var coverOpacities: [String: Double] = [:]
    @State private var isPresented = false
    @State private var appliedPreferredAssetID: String?

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

    private var relativeYearTitle: String {
        let currentYear = Calendar.autoupdatingCurrent.component(.year, from: .now)
        let years = max(1, currentYear - memory.sourceYear)
        return years == 1 ? "1 year ago" : "\(years.formatted()) years ago"
    }

    private var dominantAsset: TimelineMemoryAssetSummary? {
        renderedAssets.max { opacity(for: $0) < opacity(for: $1) }
    }

    var body: some View {
        Button {
            guard let assetID = dominantAsset?.id ?? currentAsset?.id else { return }
            select(assetID)
        } label: {
            ZStack(alignment: .bottomLeading) {
                Color(uiColor: .systemBackground)
                ZStack(alignment: .bottomLeading) {
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
                        Text(relativeYearTitle)
                            .font(.headline)
                        Text(memory.memoryAt.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                        Text(TimelineMemoryCardPresentation.itemCountLabel(memory.assets.count))
                            .font(.caption2)
                    }
                    .foregroundStyle(.white)
                    .padding(12)
                }
                .opacity(isHidden ? 0 : 1)

                if isLoading {
                    ProgressView()
                        .tint(.primary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.regularMaterial)
                        .accessibilityLabel("Opening memory")
                }
            }
            .frame(width: width, height: 120)
            .clipShape(.rect(cornerRadius: DesignMetrics.defaultCornerRadius))
            .contentShape(.rect(cornerRadius: DesignMetrics.defaultCornerRadius))
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(relativeYearTitle), \(memory.memoryAt.formatted(date: .long, time: .omitted))")
        .accessibilityHint("Opens this memory")
        .accessibilityIdentifier("memory-\(memory.id)")
        .accessibilityValue(coverAccessibilityValue)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            frameChanged(frame)
        }
        .onAppear { isPresented = true }
        .onDisappear { isPresented = false }
        .task(id: "\(isPresented):\(scenePhase):\(reduceMotion):\(slideshowID):\(initialDelay):\(isFrozen):\(preferredAssetID ?? "none")") {
            guard isPresented, scenePhase == .active else { return }
            installPreferredCoverIfNeeded()
            guard !isFrozen else { return }
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

    private func installPreferredCoverIfNeeded() {
        guard let preferredAssetID,
              preferredAssetID != appliedPreferredAssetID,
              let index = memory.assets.firstIndex(where: { $0.id == preferredAssetID })
        else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            currentIndex = index
            incomingAsset = nil
            coverScales = [preferredAssetID: 1]
            coverOpacities = [preferredAssetID: 1]
            appliedPreferredAssetID = preferredAssetID
        }
    }
}

nonisolated enum TimelineMemoryCardPresentation {
    static func itemCountLabel(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count.formatted()) items"
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
