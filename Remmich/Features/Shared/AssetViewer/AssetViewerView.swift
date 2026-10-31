import SwiftUI
import UIKit

struct AssetViewerDismissalTarget {
    let imageFrame: CGRect
    let cornerRadius: CGFloat
    let fillsFrame: Bool
}

struct AssetViewerView: View {
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.scenePhase) private var scenePhase

    let route: AssetViewerRoute
    let media: MediaLibraryController
    let assetDetails: any AssetDetailReading
    let tabBarTop: CGFloat
    let opensFromSource: Bool
    let memoryContentOpacity: Double
    let memoryRowFrame: CGRect?
    let dismissalRequest: Int
    let memoryBoundaryChanged: (Int) -> Bool
    let namespace: Namespace.ID
    let close: () -> Void
    let visibilityChanged: (Bool) -> Void
    let returningLivePhotoBadgeChanged: (String?) -> Void
    let returningTimelineThumbnailChanged: (String?) -> Void
    let dismissalTarget: (String) -> AssetViewerDismissalTarget?

    @State private var session: AssetViewerSession
    @State private var zoomedAssetID: String?
    @State private var chromeVisible = true
    @State private var showsInfo = false
    @State private var detailStates: [String: AssetViewerDetailState] = [:]
    @State private var cachedDetailMissAssetIDs: Set<String> = []
    @State private var refreshedDetailAssetIDs: Set<String> = []
    @State private var renderedImageMetadataByAssetID: [String: AssetViewerRenderedImageMetadata] = [:]
    @State private var videoPlaybackSession: VideoPlaybackSession?
    @State private var videoFirstFrameReady = false
    @State private var videoControlsVisible = true
    @State private var videoRoutePickerPresented = false
    @State private var resumesVideoAfterCancelledDismissal = false
    @State private var verticalDragRoute: AssetViewerVerticalDragRoute?
    @State private var fullResolutionRequestIDs: [String: Int] = [:]
    @State private var fullResolutionLoadErrors: [String: String] = [:]
    @State private var livePhotoMotionByteCounts: [String: Int] = [:]
    @State private var neighborLoadTask: Task<Void, Never>?
    @State private var infoContentHeightsByAssetID: [String: CGFloat] = [:]
    @State private var infoDragTranslation: CGFloat = 0
    @State private var viewerPreviewTargetPixels: MediaPixelSize?
    @State private var pagerPosition: String?
    @State private var pagerWindowCenterID: String
    @State private var pagerPhase: ScrollPhase = .idle
    @State private var pagerSelectionTask: Task<Void, Never>?
    @State private var openingIsActive: Bool
    @State private var openingProgress: CGFloat
    @State private var openingTask: Task<Void, Never>?
    @State private var isDismissing = false
    @State private var dismissalDragTranslation = CGSize.zero
    @State private var dismissalDragStartLocation = CGPoint.zero
    @State private var dismissalViewerRect: CGRect?
    @State private var dismissalBackdropOpacity: CGFloat = 1
    @State private var dismissalLandingScale: CGFloat?
    @State private var dismissalLandingTranslation: CGSize?
    @State private var dismissalLandingCornerRadius: CGFloat = 0
    @State private var dismissalCropTargetSize: CGSize?
    @State private var dismissalCropProgress: CGFloat = 0
    @State private var dismissalAssetOpacity: Double = 1
    @State private var nativeDismissalTransitionActive = false
    @State private var nativeDismissalController = AssetViewerNativeDismissalController()
    @State private var isLandingDismissal = false
    @State private var dismissalLandingTask: Task<Void, Never>?
    @State private var dismissalThumbnailRevealTask: Task<Void, Never>?
    @State private var livePhotoPlaybackAssetID: String?
    @State private var livePhotoSoundEnabled = false
    @State private var memoryAutoElapsed: TimeInterval = 0
    @State private var memoryAutoStartedAt: Date?
    @State private var memoryAutoAdvanceTask: Task<Void, Never>?
    @State private var memoryAssetPressActive = false
    @State private var memoryWrapOpacity = 1.0
    @State private var memoryWrapTask: Task<Void, Never>?
    @State private var memoryIsWrapping = false

    private let controlHitSize: CGFloat = 44
    private let controlVisualSize: CGFloat = 44
    private let topChromeHeight: CGFloat = 60
    private let infoGap: CGFloat = 12
    private let pagerWindowRadius = 3

    private var memoryContext: AssetViewerMemoryContext? {
        guard case let .memory(context) = route.origin else { return nil }
        return context
    }

    private var isMemoryViewer: Bool {
        memoryContext != nil
    }

    init(
        route: AssetViewerRoute,
        store: PhotosTimelineStore,
        media: MediaLibraryController,
        assetDetails: any AssetDetailReading,
        tabBarTop: CGFloat = 0,
        opensFromSource: Bool = true,
        memoryContentOpacity: Double = 1,
        memoryRowFrame: CGRect? = nil,
        dismissalRequest: Int = 0,
        memoryBoundaryChanged: @escaping (Int) -> Bool = { _ in false },
        namespace: Namespace.ID,
        close: @escaping () -> Void,
        visibilityChanged: @escaping (Bool) -> Void,
        returningLivePhotoBadgeChanged: @escaping (String?) -> Void = { _ in },
        returningTimelineThumbnailChanged: @escaping (String?) -> Void = { _ in },
        dismissalTarget: @escaping (String) -> AssetViewerDismissalTarget? = { _ in nil }
    ) {
        self.route = route
        self.media = media
        self.assetDetails = assetDetails
        self.tabBarTop = tabBarTop
        self.opensFromSource = opensFromSource
        self.memoryContentOpacity = memoryContentOpacity
        self.memoryRowFrame = memoryRowFrame
        self.dismissalRequest = dismissalRequest
        self.memoryBoundaryChanged = memoryBoundaryChanged
        self.namespace = namespace
        self.close = close
        self.visibilityChanged = visibilityChanged
        self.returningLivePhotoBadgeChanged = returningLivePhotoBadgeChanged
        self.returningTimelineThumbnailChanged = returningTimelineThumbnailChanged
        self.dismissalTarget = dismissalTarget
        _session = State(initialValue: AssetViewerSession(
            route: route,
            bucketIDs: store.bucketSummaries.map(\.id),
            loadBucket: { bucketID in
                await store.rangeCoverAssets(in: bucketID)
            }
        ))
        _pagerPosition = State(initialValue: route.selectedAsset.id)
        _pagerWindowCenterID = State(initialValue: route.selectedAsset.id)
        _videoPlaybackSession = State(initialValue: route.selectedAsset.mediaKind == .video
            ? VideoPlaybackSession(assetID: route.selectedAsset.id)
            : nil)
        _openingIsActive = State(initialValue: opensFromSource)
        _openingProgress = State(initialValue: opensFromSource ? 0 : 1)
    }

    var body: some View {
        GeometryReader { safeGeometry in
            GeometryReader { fullGeometry in
                let infoProgress = isMemoryViewer ? 0 : infoPresentationProgress
                let safeFrame = safeGeometry.frame(in: .global)
                let fullFrame = fullGeometry.frame(in: .global)
                let isLandscape = fullGeometry.size.width > fullGeometry.size.height
                let safeInsets = resolvedSafeAreaInsets(
                    safeGeometry: safeGeometry,
                    safeFrame: safeFrame,
                    fullFrame: fullFrame
                )
                let fullRect = CGRect(origin: .zero, size: fullGeometry.size)
                let previewTargetPixels = MediaPixelSize(
                    width: Int(max(1, fullGeometry.size.width * displayScale)),
                    height: Int(max(1, fullGeometry.size.height * displayScale))
                )
                let safeRect = CGRect(
                    x: safeInsets.leading,
                    y: safeInsets.top,
                    width: max(1, fullGeometry.size.width - safeInsets.leading - safeInsets.trailing),
                    height: max(1, fullGeometry.size.height - safeInsets.top - safeInsets.bottom)
                )
                let dismissalScale = AssetViewerDismissalGeometry.scale(
                    translationHeight: dismissalDragTranslation.height,
                    viewportHeight: fullGeometry.size.height
                )
                let activeDismissalScale = dismissalLandingScale ?? dismissalScale
                let activeDismissalTranslation = dismissalLandingTranslation
                    ?? dismissalDragTranslation
                let dismissalAnchor = AssetViewerDismissalGeometry.anchor(
                    startLocation: dismissalDragStartLocation,
                    viewportSize: fullGeometry.size
                )
                let shownInfoBottomInset = controlHitSize + infoGap
                let uiSafeAreaInsets = UIEdgeInsets(
                    top: safeInsets.top,
                    left: safeInsets.leading,
                    bottom: safeInsets.bottom,
                    right: safeInsets.trailing
                )
                let localTabBarTop = tabBarTop > 0
                    ? tabBarTop - fullFrame.minY
                    : 0
                let memorySourceFrame = isMemoryViewer
                    ? dismissalTarget(route.selectedAsset.id).map {
                        $0.imageFrame.offsetBy(dx: -fullFrame.minX, dy: -fullFrame.minY)
                    }
                    : nil
                let localizedMemoryRowFrame = isMemoryViewer
                    ? memoryRowFrame?.offsetBy(dx: -fullFrame.minX, dy: -fullFrame.minY)
                    : nil
                let memoryRowBottom = localizedMemoryRowFrame?.maxY ?? memorySourceFrame?.maxY ?? 0
                let memoryPanelRect = isMemoryViewer
                    ? AssetViewerMemoryGeometry.panelRect(
                        viewportSize: fullGeometry.size,
                        safeAreaInsets: uiSafeAreaInsets,
                        bottomNavigationTop: localTabBarTop,
                        memoryRowBottom: memoryRowBottom,
                        isPad: UIDevice.current.userInterfaceIdiom == .pad
                    )
                    : nil
                let memoryChromeTopInset = memoryPanelRect.map {
                    max(0, $0.minY - safeRect.minY + 8)
                } ?? 8
                let fittedViewerRect = isMemoryViewer
                    ? AssetViewerMemoryGeometry.mediaRect(
                        viewportSize: fullGeometry.size,
                        safeAreaInsets: uiSafeAreaInsets,
                        bottomNavigationTop: localTabBarTop,
                        memoryRowBottom: memoryRowBottom,
                        isPad: UIDevice.current.userInterfaceIdiom == .pad
                    )
                    : (session.isVideoPlayback && isLandscape
                        ? AssetViewerMediaGeometry.landscapeVideoInfoRect(
                            viewportSize: fullGeometry.size,
                            safeAreaInsets: uiSafeAreaInsets,
                            infoProgress: infoProgress,
                            topChromeHeight: topChromeHeight
                        )
                        : AssetViewerMediaGeometry.mediaRect(
                            viewportSize: fullGeometry.size,
                            safeAreaInsets: uiSafeAreaInsets,
                            infoProgress: infoProgress,
                            topChromeHeight: topChromeHeight,
                            shownInfoBottomInset: shownInfoBottomInset
                        ))
                let viewerRect = dismissalViewerRect ?? fittedViewerRect
                let selectedMediaRect = selectedMediaRect(
                    in: viewerRect,
                    infoProgress: infoProgress,
                    isLandscape: isLandscape
                )
                let dismissalImageRect = selectedRenderedImageRect(in: selectedMediaRect)
                let openingTarget = openingIsActive
                    ? dismissalTarget(route.selectedAsset.id) : nil
                let openingTransform = openingTarget.map { target in
                    AssetViewerDismissalGeometry.landingTransform(
                        imageRect: dismissalImageRect,
                        targetRect: target.imageFrame.offsetBy(
                            dx: -fullFrame.minX,
                            dy: -fullFrame.minY
                        ),
                        viewportSize: fullGeometry.size,
                        anchor: .center,
                        fillsTarget: target.fillsFrame
                    )
                }
                let isOpening = openingTransform != nil && !isDismissing
                let openingRemainder = isOpening ? 1 - openingProgress : 0
                let openingClipTarget = isOpening && openingTarget?.fillsFrame == true
                    ? openingTarget?.imageFrame.offsetBy(
                        dx: -fullFrame.minX,
                        dy: -fullFrame.minY
                    ) : nil
                let isolatesDismissalAsset = isOpening
                    || isDismissalInteractionActive || isDismissing
                let dismissalMaskRect = isolatesDismissalAsset
                    ? AssetViewerDismissalGeometry.croppedImageRect(
                        dismissalImageRect,
                        targetSize: isDismissing ? dismissalCropTargetSize : nil,
                        progress: dismissalCropProgress
                    ) : fullRect
                let openingScale = 1 + ((openingTransform?.scale ?? 1) - 1) * openingRemainder
                let openingTranslation = CGSize(
                    width: (openingTransform?.translation.width ?? 0) * openingRemainder,
                    height: (openingTransform?.translation.height ?? 0) * openingRemainder
                )
                let openingCornerRadius = (openingTarget?.cornerRadius ?? 0)
                    / max(openingTransform?.scale ?? 1, 0.04) * openingRemainder
                let isDraggingOrLanding = isDismissalInteractionActive || isLandingDismissal
                let usesNativeDismissal = nativeDismissalTransitionActive && !isOpening
                let viewerMaskRect = usesNativeDismissal ? fullRect : dismissalMaskRect
                let memoryPanelOpeningTransform = memoryPanelRect.map { panelRect in
                    guard isOpening, let memorySourceFrame else {
                        return (scale: CGSize(width: 1, height: 1), translation: CGSize.zero)
                    }
                    return AssetViewerMemoryGeometry.openingTransform(
                        from: memorySourceFrame,
                        to: panelRect,
                        progress: openingProgress
                    )
                }
                ZStack {
                    if !isMemoryViewer {
                        Color(uiColor: .systemBackground)
                            .opacity(usesNativeDismissal
                                ? 0
                                : (isOpening ? openingProgress : dismissalBackdropOpacity))
                    }
                    if isMemoryViewer {
                        if let memoryPanelRect {
                            memoryOutsideDismissalLayer(
                                viewportRect: fullRect,
                                panelRect: memoryPanelRect,
                                memoryRowFrame: localizedMemoryRowFrame ?? memorySourceFrame,
                                bottomNavigationTop: localTabBarTop,
                                viewportOrigin: fullFrame.origin,
                                mediaRect: selectedMediaRect
                            )

                            Color.clear
                                .frame(
                                    width: memoryPanelRect.width,
                                    height: memoryPanelRect.height
                                )
                                .glassEffect(
                                    .regular,
                                    in: .rect(cornerRadius: DesignMetrics.defaultCornerRadius)
                                )
                                .position(
                                    x: memoryPanelRect.midX,
                                    y: memoryPanelRect.midY
                                )
                                .scaleEffect(
                                    x: memoryPanelOpeningTransform?.scale.width ?? 1,
                                    y: memoryPanelOpeningTransform?.scale.height ?? 1
                                )
                                .offset(memoryPanelOpeningTransform?.translation ?? .zero)
                                .opacity(isDismissalInteractionActive || isDismissing ? 0 : 1)
                        }
                    }
                    viewerContent(
                        pageSize: fullGeometry.size,
                        viewportOrigin: fullFrame.origin,
                        safeAreaInsets: safeInsets,
                        viewerRect: viewerRect,
                        requestSize: fullGeometry.size,
                        isLandscape: isLandscape,
                        infoProgress: infoProgress,
                        selectedMediaRect: selectedMediaRect,
                        showsMediaBackground: !isolatesDismissalAsset
                    )
                    .contentShape(AssetViewerInteractionShape(
                        rect: isMemoryViewer ? memoryPanelRect : nil
                    ))
                    .mask {
                        RoundedRectangle(
                            cornerRadius: usesNativeDismissal
                                ? 0
                                : (isOpening
                                    ? openingCornerRadius : dismissalLandingCornerRadius),
                            style: .continuous
                        )
                        .frame(
                            width: viewerMaskRect.width,
                            height: viewerMaskRect.height
                        )
                        .position(
                            x: viewerMaskRect.midX,
                            y: viewerMaskRect.midY
                        )
                        .animation(.easeOut(duration: 0.14), value: dismissalCropProgress)
                    }
                    .scaleEffect(
                        !usesNativeDismissal && isDraggingOrLanding && !reduceMotion
                            ? activeDismissalScale : openingScale,
                        anchor: isOpening || usesNativeDismissal ? .center : dismissalAnchor
                    )
                    .offset(
                        !usesNativeDismissal && isDraggingOrLanding && !reduceMotion
                            ? activeDismissalTranslation : openingTranslation
                    )
                    .clipShape(AssetViewerTransitionClipShape(
                        target: openingClipTarget ?? fullRect,
                        progress: openingClipTarget == nil ? 0 : openingRemainder
                    ))
                    .opacity(
                        (usesNativeDismissal ? 0 : dismissalAssetOpacity)
                            * (isMemoryViewer ? memoryContentOpacity * memoryWrapOpacity : 1)
                    )

                    AssetViewerNativeDismissalSurface(
                        controller: nativeDismissalController
                    )
                    .frame(width: fullRect.width, height: fullRect.height)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .zIndex(2)
                    chrome(
                        infoProgress: infoProgress,
                        viewportSize: fullGeometry.size,
                        viewportOrigin: fullFrame.origin,
                        mediaRect: selectedMediaRect,
                        memoryPanelRect: memoryPanelRect,
                        memoryChromeTopInset: memoryChromeTopInset
                    )
                    .frame(width: safeRect.width, height: safeRect.height)
                    .position(x: safeRect.midX, y: safeRect.midY)
                    .zIndex(1)
                    .opacity((isOpening
                            ? openingProgress * (chromeVisible ? 1 : 0)
                            : (isolatesDismissalAsset ? 0 : (chromeVisible ? 1 : 0)))
                        * (isMemoryViewer ? memoryContentOpacity * memoryWrapOpacity : 1))
                    .allowsHitTesting(!isolatesDismissalAsset && (chromeVisible || showsInfo))
                    .accessibilityHidden(isolatesDismissalAsset || (!chromeVisible && !showsInfo))
                }
                .contentShape(isMemoryViewer
                    ? AssetViewerMemoryInteractionShape(
                        viewportRect: fullRect,
                        panelRect: memoryPanelRect ?? fullRect,
                        memoryRowFrame: localizedMemoryRowFrame ?? memorySourceFrame,
                        bottomNavigationTop: localTabBarTop
                    )
                    : AssetViewerMemoryInteractionShape(
                        viewportRect: fullRect,
                        panelRect: fullRect,
                        memoryRowFrame: nil,
                        bottomNavigationTop: fullRect.maxY
                    ))
                .simultaneousGesture(
                    verticalViewerGesture(
                        viewportSize: fullRect.size,
                        viewportOrigin: fullFrame.origin,
                        viewerRect: viewerRect,
                        mediaRect: selectedMediaRect
                    )
                )
                .onChange(of: dismissalRequest) {
                    guard isMemoryViewer else { return }
                    completeDragDismissal(
                        viewportSize: fullRect.size,
                        viewportOrigin: fullFrame.origin,
                        mediaRect: selectedMediaRect
                    )
                }
                .task(id: previewTargetPixels) {
                    viewerPreviewTargetPixels = previewTargetPixels
                    updateViewerPrefetch()
                }
            }
            .ignoresSafeArea(.container, edges: .all)
        }
        .foregroundStyle(.primary)
        .modifier(AssetViewerStatusBarVisibilityModifier(hidden: shouldHideStatusBar))
        .presentationBackground(.clear)
        .interactiveDismissDisabled(true)
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .task {
            await session.start()
            updateViewerPrefetch()
            resetMemoryAutoRotation()
        }
        .task(id: openingIsActive ? nil : videoPlaybackSession?.assetID) {
            guard !openingIsActive, let videoPlaybackSession else { return }
            await videoPlaybackSession.prepare(using: media)
        }
        .onChange(of: videoPlaybackSession?.generation) { _, _ in
            videoFirstFrameReady = false
            chromeVisible = true
        }
        .onChange(of: videoPlaybackSession?.phase) { _, phase in
            guard case .failed = phase else { return }
            withAnimation(chromeAnimation) {
                chromeVisible = true
            }
        }
        .task(id: AssetDetailLoadRequest(
            assetID: session.selectedAssetID,
            includesNeighbors: showsInfo
        )) {
            await loadSelectedAssetDetail()
        }
        .task(id: AssetDetailCacheWindowRequest(
            assetIDs: pagerWindowAssets.map(\.id)
        )) {
            await preloadCachedAssetDetails(pagerWindowAssets.map(\.id))
        }
        .onChange(of: session.selectedAssetID) { _, newAssetID in
            videoFirstFrameReady = false
            chromeVisible = true
            syncVideoPlaybackSession()
            nativeDismissalController.reset()
            nativeDismissalTransitionActive = false
            zoomedAssetID = nil
            livePhotoPlaybackAssetID = nil
            memoryAssetPressActive = false
            updateViewerPrefetch()
            if pagerPosition != newAssetID {
                pagerPosition = newAssetID
            }
            if !pagerWindowAssets.contains(where: { $0.id == newAssetID }) {
                pagerWindowCenterID = newAssetID
            }
            resetMemoryAutoRotation()
        }
        .onChange(of: route.id) { _, _ in
            replaceMemoryRoute()
        }
        .onAppear {
            visibilityChanged(true)
            beginOpeningAnimation()
        }
        .onDisappear {
            videoPlaybackSession?.close()
            openingTask?.cancel()
            dismissalLandingTask?.cancel()
            dismissalThumbnailRevealTask?.cancel()
            nativeDismissalController.reset()
            let requestedFullSizeAssets = session.assets.filter {
                fullResolutionRequestIDs[$0.id] != nil
            }
            neighborLoadTask?.cancel()
            pagerSelectionTask?.cancel()
            memoryAutoAdvanceTask?.cancel()
            memoryWrapTask?.cancel()
            memoryAutoStartedAt = nil
            livePhotoPlaybackAssetID = nil
            livePhotoSoundEnabled = false
            media.cancelViewerPrefetching()
            visibilityChanged(false)
            returningTimelineThumbnailChanged(nil)
            Task { @MainActor in
                await Task.yield()
                media.removeViewerOriginalCache(for: requestedFullSizeAssets)
                await media.removeViewerLivePhotoMotionCache()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                if let videoPlaybackSession {
                    Task { @MainActor in
                        await videoPlaybackSession.resumeFromSuspension()
                    }
                }
                resumeMemoryAutoRotation()
            } else {
                videoPlaybackSession?.suspend()
                pauseMemoryAutoRotation()
            }
        }
        .onChange(of: reduceMotion) {
            resetMemoryAutoRotation()
        }
        .onChange(of: voiceOverEnabled) {
            resetMemoryAutoRotation()
        }
    }

    private func viewerContent(
        pageSize: CGSize,
        viewportOrigin: CGPoint,
        safeAreaInsets: EdgeInsets,
        viewerRect: CGRect,
        requestSize: CGSize,
        isLandscape: Bool,
        infoProgress: CGFloat,
        selectedMediaRect: CGRect,
        showsMediaBackground: Bool
    ) -> some View {
        ZStack {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(pagerWindowAssets) { asset in
                        viewerPage(
                            asset: asset,
                            pageSize: pageSize,
                            viewerRect: viewerRect,
                            requestSize: requestSize,
                            isLandscape: isLandscape,
                            infoProgress: infoProgress,
                            showsMediaBackground: showsMediaBackground
                        )
                        .frame(width: pageSize.width, height: pageSize.height)
                        .clipped()
                        .id(asset.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $pagerPosition)
            .scrollDisabled(
                !session.allowsHorizontalPaging
                    || zoomedAssetID == session.selectedAssetID
                    || isDismissalInteractionActive || openingIsActive
            )
            .onChange(of: pagerPosition) { _, assetID in
                schedulePagerSelectionSync(assetID)
            }
            .onScrollPhaseChange { _, phase in
                pagerPhase = phase
                if phase == .idle {
                    schedulePagerSelectionSync(pagerPosition)
                    resumeMemoryAutoRotation()
                } else {
                    pagerSelectionTask?.cancel()
                    pauseMemoryAutoRotation()
                }
            }
            .simultaneousGesture(memoryAssetInteractionGesture(mediaRect: selectedMediaRect))

            if let videoPlaybackSession,
               videoPlaybackSession.assetID == session.selectedAssetID,
               !openingIsActive
            {
                ViewerVideoSurface(
                    session: videoPlaybackSession,
                    readyForDisplayChanged: videoReadyForDisplayChanged
                )
                .frame(
                    width: selectedMediaRect.width,
                    height: selectedMediaRect.height
                )
                .position(
                    x: selectedMediaRect.midX,
                    y: selectedMediaRect.midY
                )
                .opacity(
                    videoFirstFrameReady && showsMediaBackground
                        ? 1 : 0
                )
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.18),
                    value: videoFirstFrameReady && showsMediaBackground
                )
                .allowsHitTesting(
                    false
                )
                .accessibilityHidden(!videoFirstFrameReady || !showsMediaBackground)

                if videoFirstFrameReady, showsMediaBackground {
                    ViewerVideoControls(
                        session: videoPlaybackSession,
                        isVisible: $videoControlsVisible,
                        showsCloseButton: !showsInfo,
                        compactLandscape: isLandscape
                            && UIDevice.current.userInterfaceIdiom == .phone,
                        safeAreaInsets: EdgeInsets(
                            top: max(0, safeAreaInsets.top - selectedMediaRect.minY),
                            leading: max(0, safeAreaInsets.leading - selectedMediaRect.minX),
                            bottom: max(
                                0,
                                safeAreaInsets.bottom
                                    - (pageSize.height - selectedMediaRect.maxY)
                            ),
                            trailing: max(
                                0,
                                selectedMediaRect.maxX
                                    - (pageSize.width - safeAreaInsets.trailing)
                            )
                        ),
                        close: {
                            pauseVideoForDismissalIfNeeded()
                            completeDragDismissal(
                                viewportSize: pageSize,
                                viewportOrigin: viewportOrigin,
                                mediaRect: selectedMediaRect
                            )
                        },
                        visibilityChanged: videoControlVisibilityChanged,
                        routePresentationChanged: videoRoutePresentationChanged
                    )
                    .environment(\.colorScheme, .dark)
                    .frame(
                        width: selectedMediaRect.width,
                        height: selectedMediaRect.height
                    )
                    .position(
                        x: selectedMediaRect.midX,
                        y: selectedMediaRect.midY
                    )
                }

                videoPreparationOverlay(
                    session: videoPlaybackSession,
                    mediaRect: selectedMediaRect,
                    showsMediaBackground: showsMediaBackground
                )
                .environment(\.colorScheme, .dark)
            }
        }
    }

    private func viewerPage(
        asset: TimelineAssetSummary,
        pageSize: CGSize,
        viewerRect: CGRect,
        requestSize: CGSize,
        isLandscape: Bool,
        infoProgress: CGFloat,
        showsMediaBackground: Bool
    ) -> some View {
        let animatesFitChanges = AssetViewerMediaGeometry.animatesFitChanges(
            infoDragTranslation: infoDragTranslation
        )
        let targetInfoWidth = viewerRect.width / 2
        let infoWidth = targetInfoWidth * infoProgress
        let maxInfoHeight = max(0, viewerRect.height - 220 - infoGap)
        let selectedInfoContentHeight = infoContentHeight(for: session.selectedAssetID)
        let targetInfoHeight = min(maxInfoHeight, selectedInfoContentHeight)
        let infoHeight = targetInfoHeight * infoProgress
        let gap = infoGap * infoProgress
        let portraitMediaHeight = max(220, viewerRect.height - infoHeight - gap)
        let mediaRect = isLandscape
            ? CGRect(
                x: viewerRect.minX,
                y: viewerRect.minY,
                width: viewerRect.width - infoWidth,
                height: viewerRect.height
            )
            : CGRect(
                x: viewerRect.minX,
                y: viewerRect.minY,
                width: viewerRect.width,
                height: portraitMediaHeight
            )

        return ZStack {
            mediaPage(
                asset: asset,
                requestSize: requestSize,
                mediaRect: mediaRect,
                animatesFitChanges: animatesFitChanges,
                showsBackground: showsMediaBackground,
                usesInsetStage: isMemoryViewer
            )
            .frame(width: pageSize.width, height: pageSize.height)

            if isLandscape {
                ZStack(alignment: .leading) {
                    AssetViewerInfoView(
                        state: detailState(for: asset.id),
                        renderedImageMetadata: renderedImageMetadataForInfo(for: asset),
                        videoPlaybackMetadata: videoPlaybackMetadata(for: asset),
                        fullResolutionState: fullResolutionState(for: asset),
                        anchorsContentToBottom: true,
                        contentHeightChanged: { updateInfoContentHeight($0, for: asset.id) },
                        retry: { retryDetail(for: asset.id) },
                        loadFullResolution: { requestFullResolution(for: asset.id) }
                    )
                    .frame(width: targetInfoWidth)
                }
                .frame(width: infoWidth, height: viewerRect.height, alignment: .leading)
                .clipped()
                .position(x: viewerRect.maxX - infoWidth / 2, y: viewerRect.midY)
                .opacity(showsMediaBackground ? 1 : 0)
                .allowsHitTesting(
                    infoProgress > 0.5 && showsMediaBackground
                        && asset.id == session.selectedAssetID
                )
                .accessibilityHidden(
                    infoProgress < 0.5 || asset.id != session.selectedAssetID
                )
            } else {
                ZStack(alignment: .top) {
                    AssetViewerInfoView(
                        state: detailState(for: asset.id),
                        renderedImageMetadata: renderedImageMetadataForInfo(for: asset),
                        videoPlaybackMetadata: videoPlaybackMetadata(for: asset),
                        fullResolutionState: fullResolutionState(for: asset),
                        anchorsContentToBottom: false,
                        contentHeightChanged: { updateInfoContentHeight($0, for: asset.id) },
                        retry: { retryDetail(for: asset.id) },
                        loadFullResolution: { requestFullResolution(for: asset.id) }
                    )
                    .frame(height: targetInfoHeight)
                }
                .frame(width: viewerRect.width, height: infoHeight, alignment: .top)
                .clipped()
                .position(
                    x: viewerRect.midX,
                    y: mediaRect.maxY + gap + infoHeight / 2
                )
                .opacity(showsMediaBackground ? 1 : 0)
                .allowsHitTesting(
                    infoProgress > 0.5 && showsMediaBackground
                        && asset.id == session.selectedAssetID
                )
                .accessibilityHidden(
                    infoProgress < 0.5 || asset.id != session.selectedAssetID
                )
            }
        }
        .frame(width: pageSize.width, height: pageSize.height)
        .animation(infoAnimation, value: showsInfo)
        .animation(infoAnimation, value: targetInfoHeight)
        .accessibilityIdentifier(
            isLandscape
                ? (infoProgress > 0.5
                    ? "asset-viewer-landscape-split"
                    : "asset-viewer-landscape")
                : "asset-viewer-portrait"
        )
    }

    private func mediaPage(
        asset: TimelineAssetSummary,
        requestSize: CGSize,
        mediaRect: CGRect,
        animatesFitChanges: Bool,
        showsBackground: Bool,
        usesInsetStage: Bool
    ) -> some View {
        ZStack {
            AssetViewerFitPage(
                asset: asset,
                media: media,
                isSelected: asset.id == session.selectedAssetID,
                mediaRect: mediaRect,
                pageSize: requestSize,
                animatesFitChanges: animatesFitChanges,
                showsBackground: showsBackground,
                usesInsetStage: usesInsetStage,
                showsVideoPoster: asset.id != session.selectedAssetID || !videoFirstFrameReady
                    || isDismissalInteractionActive || isDismissing,
                targetPixels: .init(
                    width: Int(max(1, requestSize.width * displayScale)),
                    height: Int(max(1, requestSize.height * displayScale))
                ),
                fullResolutionRequestID: fullResolutionRequestIDs[asset.id],
                renderedImageMetadataChanged: { metadata in
                    renderedImageMetadataByAssetID[asset.id] = metadata
                    if metadata.source == .original {
                        fullResolutionLoadErrors.removeValue(forKey: asset.id)
                    }
                },
                fullResolutionLoadFailed: { message in
                    if let message {
                        fullResolutionLoadErrors[asset.id] = message
                    } else {
                        fullResolutionLoadErrors.removeValue(forKey: asset.id)
                    }
                },
                zoomChanged: { isZoomed in
                    guard asset.id == session.selectedAssetID else { return }
                    zoomedAssetID = isZoomed ? asset.id : nil
                    if isZoomed {
                        pauseMemoryAutoRotation()
                    } else {
                        resumeMemoryAutoRotation()
                    }
                    guard !isMemoryViewer,
                          isZoomed,
                          chromeVisible,
                          !showsInfo
                    else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                        chromeVisible = false
                    }
                },
                livePhotoPressChanged: { isPressing in
                    guard asset.id == session.selectedAssetID,
                          asset.livePhotoVideoID != nil,
                          zoomedAssetID == nil
                    else {
                        if livePhotoPlaybackAssetID == asset.id {
                            livePhotoPlaybackAssetID = nil
                        }
                        return
                    }
                    livePhotoPlaybackAssetID = isPressing ? asset.id : nil
                },
                toggleChrome: mediaTapped
            )

            if let motionAssetID = asset.livePhotoVideoID,
               asset.id == session.selectedAssetID
            {
                LivePhotoPlaybackView(
                    assetID: asset.id,
                    motionAssetID: motionAssetID,
                    media: media,
                    isHeld: livePhotoPlaybackAssetID == asset.id,
                    playsWithSound: livePhotoSoundEnabled,
                    playbackEnded: {
                        guard livePhotoPlaybackAssetID == asset.id else { return }
                        livePhotoPlaybackAssetID = nil
                    },
                    soundPlaybackFailed: {
                        livePhotoSoundEnabled = false
                    },
                    motionFileSizeChanged: { byteCount in
                        if let byteCount {
                            livePhotoMotionByteCounts[asset.id] = byteCount
                        } else {
                            livePhotoMotionByteCounts.removeValue(forKey: asset.id)
                        }
                    }
                )
                .frame(width: mediaRect.width, height: mediaRect.height)
                .position(x: mediaRect.midX, y: mediaRect.midY)
                .allowsHitTesting(false)
            }

            #if DEBUG
                if asset.mediaKind != .video,
                   asset.id == session.selectedAssetID,
                   let metadata = renderedImageMetadataByAssetID[asset.id],
                   ProcessInfo.processInfo.arguments.contains("-ui-testing-signed-in")
                {
                    GeometryReader { _ in
                        let renderedFrame = renderedImageFrame(
                            metadata: metadata,
                            boundingRect: mediaRect
                        )
                        Color.clear
                            .frame(width: renderedFrame.width, height: renderedFrame.height)
                            .position(x: renderedFrame.midX, y: renderedFrame.midY)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Rendered image pixels")
                            .accessibilityIdentifier("asset-viewer-rendered-pixels-\(asset.id)")
                            .allowsHitTesting(false)
                    }
                    .allowsHitTesting(false)
                }
            #endif
        }
        .mask {
            if usesInsetStage {
                Rectangle()
                    .frame(width: mediaRect.width, height: mediaRect.height)
                    .position(x: mediaRect.midX, y: mediaRect.midY)
            } else {
                Rectangle()
            }
        }
    }

    private func memoryAssetInteractionGesture(mediaRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard isMemoryViewer,
                      selectedRenderedImageRect(in: mediaRect).contains(value.startLocation)
                else { return }
                setMemoryAssetPressActive(true)
            }
            .onEnded { value in
                guard isMemoryViewer else { return }
                setMemoryAssetPressActive(false)
                moveToAdjacentMemoryIfNeeded(
                    mediaRect: mediaRect,
                    value: value
                )
            }
    }

    private func renderedImageFrame(
        metadata: AssetViewerRenderedImageMetadata,
        boundingRect: CGRect
    ) -> CGRect {
        AssetViewerMediaGeometry.renderedPixelRect(
            pixelSize: CGSize(
                width: CGFloat(metadata.pixelSize.width),
                height: CGFloat(metadata.pixelSize.height)
            ),
            in: boundingRect
        )
    }

    private func selectedMediaRect(
        in viewerRect: CGRect,
        infoProgress: CGFloat,
        isLandscape: Bool
    ) -> CGRect {
        if isLandscape {
            return CGRect(
                x: viewerRect.minX,
                y: viewerRect.minY,
                width: viewerRect.width - viewerRect.width / 2 * infoProgress,
                height: viewerRect.height
            )
        }
        let maxInfoHeight = max(0, viewerRect.height - 220 - infoGap)
        let infoHeight = min(maxInfoHeight, infoContentHeight(for: session.selectedAssetID))
            * infoProgress
        let gap = infoGap * infoProgress
        return CGRect(
            x: viewerRect.minX,
            y: viewerRect.minY,
            width: viewerRect.width,
            height: max(220, viewerRect.height - infoHeight - gap)
        )
    }

    private func selectedRenderedImageRect(in mediaRect: CGRect) -> CGRect {
        guard let asset = session.selectedAsset else { return mediaRect }
        return renderedImageRect(for: asset, in: mediaRect)
    }

    private func renderedImageRect(
        for asset: TimelineAssetSummary,
        in mediaRect: CGRect
    ) -> CGRect {
        let pixelSize = renderedImageMetadataByAssetID[asset.id].map {
            CGSize(width: CGFloat($0.pixelSize.width), height: CGFloat($0.pixelSize.height))
        } ?? CGSize(width: max(0.01, CGFloat(asset.aspectRatio)), height: 1)
        return AssetViewerMediaGeometry.renderedPixelRect(
            pixelSize: pixelSize,
            in: mediaRect
        )
    }

    @ViewBuilder
    private func chrome(
        infoProgress: CGFloat,
        viewportSize: CGSize,
        viewportOrigin: CGPoint,
        mediaRect: CGRect,
        memoryPanelRect: CGRect?,
        memoryChromeTopInset: CGFloat
    ) -> some View {
        if let memoryContext {
            memoryChrome(
                context: memoryContext,
                viewportSize: viewportSize,
                viewportOrigin: viewportOrigin,
                mediaRect: mediaRect,
                panelRect: memoryPanelRect,
                topInset: memoryChromeTopInset
            )
        } else {
            assetChrome(
                infoProgress: infoProgress,
                viewportSize: viewportSize,
                viewportOrigin: viewportOrigin,
                mediaRect: mediaRect
            )
        }
    }

    private func assetChrome(
        infoProgress: CGFloat,
        viewportSize: CGSize,
        viewportOrigin: CGPoint,
        mediaRect: CGRect
    ) -> some View {
        let showsFilmstrip = !session.isVideoPlayback
        let usesLandscapeVideoLayout = session.isVideoPlayback
            && viewportSize.width > viewportSize.height
        let actionColumnWidth = usesLandscapeVideoLayout
            ? mediaRect.width
            : viewportSize.width
        return VStack(spacing: 0) {
            GeometryReader { geometry in
                ZStack {
                    HStack {
                        glassCircleButton(
                            systemImage: "chevron.backward",
                            label: "Back",
                            identifier: "asset-viewer-back",
                            action: {
                                completeDragDismissal(
                                    viewportSize: viewportSize,
                                    viewportOrigin: viewportOrigin,
                                    mediaRect: mediaRect
                                )
                            }
                        )

                        Spacer()

                        ZStack {
                            if selectedAssetSupportsLivePhoto {
                                livePhotoSoundButton
                                    .transition(.opacity)
                            }
                        }
                        .frame(width: controlHitSize, height: controlHitSize)
                        .animation(
                            reduceMotion ? nil : .easeInOut(duration: 0.2),
                            value: selectedAssetSupportsLivePhoto
                        )
                    }

                    let contextWidth = min(240, max(120, geometry.size.width - 200))
                    AssetViewerContextHeader(
                        presentation: selectedAssetContextPresentation,
                        height: controlVisualSize
                    )
                    .equatable()
                    .frame(width: contextWidth)
                    .accessibilityIdentifier("asset-viewer-context")
                }
            }
            .frame(height: controlHitSize)
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer()

            VStack(spacing: 16) {
                if showsFilmstrip {
                    AssetViewerFilmstrip(
                        assets: session.assets,
                        selectedAssetID: session.selectedAssetID,
                        media: media,
                        select: { assetID in
                            selectPagerAsset(assetID)
                        }
                    )
                    .opacity(1 - infoProgress)
                    .allowsHitTesting(infoProgress < 0.5)
                    .accessibilityHidden(infoProgress >= 0.5)
                }

                bottomActions
                    .padding(.horizontal, 16)
            }
            .frame(width: actionColumnWidth)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func memoryChrome(
        context: AssetViewerMemoryContext,
        viewportSize: CGSize,
        viewportOrigin: CGPoint,
        mediaRect: CGRect,
        panelRect: CGRect?,
        topInset: CGFloat
    ) -> some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                let sideReservation: CGFloat = selectedAssetSupportsLivePhoto ? 88 : 52
                let titleWidth = max(72, geometry.size.width - sideReservation * 2)

                ZStack {
                    VStack(spacing: 1) {
                        Text(context.title)
                            .font(.headline)
                            .lineLimit(1)

                        Text(selectedMemoryAssetSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(width: titleWidth)

                    HStack(spacing: 8) {
                        glassCircleButton(
                            systemImage: "xmark",
                            label: "Close memory",
                            identifier: "memory-viewer-close",
                            action: {
                                completeDragDismissal(
                                    viewportSize: viewportSize,
                                    viewportOrigin: viewportOrigin,
                                    mediaRect: mediaRect
                                )
                            }
                        )

                        Spacer(minLength: 0)

                        HStack(spacing: 8) {
                            if selectedAssetSupportsLivePhoto {
                                livePhotoSoundButton
                                    .transition(.opacity)
                            }

                            Text(memoryPositionLabel)
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
            .frame(height: controlHitSize)

            AssetViewerMemoryProgress(
                count: session.assets.count,
                selectedIndex: session.selectedIndex ?? 0,
                autoElapsed: memoryAutoElapsed,
                autoStartedAt: memoryAutoStartedAt,
                autoRotationEnabled: memoryAutoRotationEnabled
            )
            .accessibilityAction(named: "Previous Photo") {
                moveMemorySelection(by: -1)
            }
            .accessibilityAction(named: "Next Photo") {
                moveMemorySelection(by: 1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, topInset)
        .frame(width: panelRect?.width ?? mediaRect.width)
        .frame(maxWidth: .infinity)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.16),
            value: session.selectedAssetID
        )
        .accessibilityIdentifier("memory-viewer-chrome")
    }

    private var memoryPositionLabel: String {
        "\((session.selectedIndex ?? 0) + 1) of \(session.assets.count)"
    }

    private var selectedMemoryAssetSubtitle: String {
        guard let presentation = selectedAssetContextPresentation else { return "" }
        let date = TimelineCaptureDateFormatting.string(
            from: presentation.capturedAt,
            dateStyle: .medium,
            timeStyle: .none
        )
        guard let location = presentation.location else { return date }
        return "\(date) · \(location)"
    }

    private func moveMemorySelection(by offset: Int) {
        guard let selectedIndex = session.selectedIndex else { return }
        let targetIndex = selectedIndex + offset
        guard session.assets.indices.contains(targetIndex) else {
            if memoryBoundaryChanged(offset.signum()) {
                pauseMemoryAutoRotation()
            }
            return
        }
        pauseMemoryAutoRotation()
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.36)) {
            pagerPosition = session.assets[targetIndex].id
            selectPagerAsset(session.assets[targetIndex].id, updatesPosition: false)
        }
    }

    private func moveToAdjacentMemoryIfNeeded(
        mediaRect: CGRect,
        value: DragGesture.Value
    ) {
        guard isMemoryViewer,
              selectedRenderedImageRect(in: mediaRect).contains(value.startLocation),
              let selectedIndex = session.selectedIndex,
              let offset = AssetViewerMemoryBoundaryNavigation.offset(
                  selectedIndex: selectedIndex,
                  assetCount: session.assets.count,
                  translation: value.translation,
                  predictedEndTranslation: value.predictedEndTranslation
              )
        else { return }
        if memoryBoundaryChanged(offset) {
            pauseMemoryAutoRotation()
        }
    }

    private var memoryAutoRotationEnabled: Bool {
        isMemoryViewer && AssetViewerMemoryAutoRotation.isEnabled(
            assetCount: session.assets.count,
            reduceMotion: reduceMotion,
            voiceOverEnabled: voiceOverEnabled
        )
    }

    private var memoryAutoRotationCanRun: Bool {
        memoryAutoRotationEnabled
            && scenePhase == .active
            && !memoryAssetPressActive
            && pagerPhase == .idle
            && pagerPosition == session.selectedAssetID
            && zoomedAssetID == nil
            && !openingIsActive
            && !isDismissing
            && !isDismissalInteractionActive
            && !memoryIsWrapping
    }

    private func resetMemoryAutoRotation() {
        memoryAutoAdvanceTask?.cancel()
        memoryAutoAdvanceTask = nil
        memoryAutoElapsed = 0
        memoryAutoStartedAt = nil
        resumeMemoryAutoRotation()
    }

    private func pauseMemoryAutoRotation() {
        if let startedAt = memoryAutoStartedAt {
            memoryAutoElapsed = AssetViewerMemoryAutoRotation.elapsed(
                base: memoryAutoElapsed,
                startedAt: startedAt,
                now: .now
            )
        }
        memoryAutoStartedAt = nil
        memoryAutoAdvanceTask?.cancel()
        memoryAutoAdvanceTask = nil
    }

    private func resumeMemoryAutoRotation() {
        guard memoryAutoRotationCanRun,
              memoryAutoStartedAt == nil,
              memoryAutoAdvanceTask == nil
        else { return }
        let remaining = AssetViewerMemoryAutoRotation.remaining(after: memoryAutoElapsed)
        guard remaining > 0 else {
            advanceMemoryAutomatically()
            return
        }
        memoryAutoStartedAt = .now
        memoryAutoAdvanceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(
                Int64((remaining * 1000).rounded(.up))
            ))
            guard !Task.isCancelled, memoryAutoRotationCanRun else { return }
            advanceMemoryAutomatically()
        }
    }

    private func setMemoryAssetPressActive(_ active: Bool) {
        guard memoryAssetPressActive != active else { return }
        memoryAssetPressActive = active
        if active {
            pauseMemoryAutoRotation()
        } else {
            resumeMemoryAutoRotation()
        }
    }

    private func advanceMemoryAutomatically() {
        guard memoryAutoRotationCanRun,
              let selectedIndex = session.selectedIndex
        else { return }
        memoryAutoAdvanceTask = nil
        memoryAutoStartedAt = nil
        memoryAutoElapsed = AssetViewerMemoryAutoRotation.duration
        let nextIndex = selectedIndex + 1
        if session.assets.indices.contains(nextIndex) {
            withAnimation(.smooth(duration: 0.36)) {
                pagerPosition = session.assets[nextIndex].id
                selectPagerAsset(session.assets[nextIndex].id, updatesPosition: false)
            }
        } else {
            beginMemoryWrap()
        }
    }

    private func beginMemoryWrap() {
        guard !memoryIsWrapping, let firstAsset = session.assets.first else { return }
        memoryIsWrapping = true
        memoryWrapTask?.cancel()
        memoryWrapTask = Task { @MainActor in
            withAnimation(.easeOut(duration: 0.16)) {
                memoryWrapOpacity = 0
            }
            try? await Task.sleep(for: .milliseconds(170))
            guard !Task.isCancelled else { return }

            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                pagerWindowCenterID = firstAsset.id
                pagerPosition = firstAsset.id
                _ = session.selectImmediately(firstAsset.id)
            }

            await Task.yield()
            withAnimation(.easeIn(duration: 0.18)) {
                memoryWrapOpacity = 1
            }
            try? await Task.sleep(for: .milliseconds(190))
            guard !Task.isCancelled else { return }
            memoryIsWrapping = false
            memoryWrapTask = nil
            resetMemoryAutoRotation()
        }
    }

    private var selectedAssetSupportsLivePhoto: Bool {
        session.selectedAsset?.livePhotoVideoID != nil
    }

    private var livePhotoSoundButton: some View {
        Button {
            livePhotoSoundEnabled.toggle()
        } label: {
            ZStack(alignment: .bottomLeading) {
                Image(systemName: "livephoto")
                    .font(.system(size: 22, weight: .semibold))
                    .symbolEffect(
                        .pulse,
                        isActive: livePhotoPlaybackAssetID == session.selectedAssetID && !reduceMotion
                    )
                    .frame(width: controlHitSize, height: controlHitSize)

                Image(systemName: livePhotoSoundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 16, height: 16)
                    .offset(x: 2, y: -2)
                    .accessibilityHidden(true)
            }
            .frame(width: controlHitSize, height: controlHitSize)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: Circle())
        .accessibilityLabel("Live Photo")
        .accessibilityValue(livePhotoSoundEnabled ? "Sound on" : "Muted")
        .accessibilityHint("Toggles sound for this viewer session. Press and hold the photo to play once.")
        .accessibilityIdentifier("asset-viewer-live-photo-indicator")
    }

    private var selectedAssetDetail: AssetDetail? {
        guard case let .loaded(detail)? = detailStates[session.selectedAssetID] else {
            return nil
        }
        return detail
    }

    private var selectedAssetContextPresentation: AssetViewerContextPresentation? {
        session.selectedAsset.map {
            AssetViewerContextPresentation(asset: $0, detail: selectedAssetDetail)
        }
    }

    private var bottomActions: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 0) {
                glassActionButton(
                    systemImage: "square.and.arrow.up",
                    label: "Share",
                    identifier: "asset-viewer-share",
                    enabled: false
                ) {}

                Spacer(minLength: 12)

                HStack(spacing: 0) {
                    Button {
                        setInfoVisible(!showsInfo)
                    } label: {
                        Image(systemName: showsInfo ? "info.circle.fill" : "info.circle")
                            .frame(width: controlHitSize, height: controlHitSize)
                    }
                    .accessibilityLabel(showsInfo ? "Hide Info" : "Show Info")
                    .accessibilityValue(showsInfo ? "Shown" : "Hidden")
                    .accessibilityIdentifier("asset-viewer-info")

                    Button {} label: {
                        Image(systemName: "square.and.arrow.down")
                            .frame(width: controlHitSize, height: controlHitSize)
                    }
                    .disabled(true)
                    .accessibilityLabel("Download")
                    .accessibilityHint("Coming in a later update")
                    .accessibilityIdentifier("asset-viewer-download")
                }
                .font(.title2.weight(.semibold))
                .buttonStyle(.plain)
                .frame(width: controlHitSize * 2, height: controlVisualSize)
                .glassEffect(.regular, in: Capsule())

                Spacer(minLength: 12)

                glassActionButton(
                    systemImage: "square.grid.2x2",
                    label: "Locate in Timeline",
                    identifier: "asset-viewer-locate",
                    enabled: false
                ) {}
            }
        }
    }

    private func glassActionButton(
        systemImage: String,
        label: String,
        identifier: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        glassCircleButton(
            systemImage: systemImage,
            label: label,
            identifier: identifier,
            action: action
        )
        .disabled(!enabled)
        .accessibilityHint(enabled ? "" : "Coming in a later update")
    }

    private func glassCircleButton(
        systemImage: String,
        label: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Color.clear
                    .frame(width: controlHitSize, height: controlHitSize)

                Image(systemName: systemImage)
                    .font(.title2.weight(.semibold))
                    .frame(width: controlVisualSize, height: controlVisualSize)
                    .glassEffect(.regular, in: Circle())
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private func verticalViewerGesture(
        viewportSize: CGSize,
        viewportOrigin: CGPoint,
        viewerRect: CGRect,
        mediaRect: CGRect
    ) -> some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                guard !openingIsActive,
                      !isDismissing,
                      zoomedAssetID == nil,
                      abs(value.translation.height) > abs(value.translation.width) * 1.2
                else { return }
                if isMemoryViewer {
                    pauseMemoryAutoRotation()
                }
                let dragRoute = AssetViewerVerticalDragRouting.resolve(
                    lockedRoute: verticalDragRoute,
                    translationHeight: value.translation.height,
                    startLocation: value.startLocation,
                    mediaRect: mediaRect,
                    showsInfo: showsInfo,
                    allowsUpwardDismissal: isMemoryViewer
                )
                if verticalDragRoute == nil {
                    verticalDragRoute = dragRoute
                }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                let drivesDismissal = dragRoute == .viewerDismissal
                    && (value.translation.height > 0
                        || (isMemoryViewer && value.translation.height < 0))
                if drivesDismissal {
                    guard !reduceMotion else { return }
                    pauseVideoForDismissalIfNeeded()
                    if nativeDismissalController.isActive {
                        updateNativeDismissal(
                            translation: value.translation,
                            viewportHeight: viewportSize.height
                        )
                        return
                    }
                    if dismissalDragTranslation.height == 0 {
                        if let asset = session.selectedAsset,
                           asset.mediaKind != .video,
                           let transitionImage = media.cachedViewerTransitionImage(
                               for: asset,
                               targetPixels: MediaPixelSize(
                                   width: Int(max(1, viewportSize.width * displayScale)),
                                   height: Int(max(1, viewportSize.height * displayScale))
                               )
                           )
                        {
                            let imageRect = selectedRenderedImageRect(in: mediaRect)
                            let anchor = AssetViewerDismissalGeometry.anchor(
                                startLocation: value.startLocation,
                                viewportSize: viewportSize
                            )
                            nativeDismissalController.begin(
                                image: transitionImage,
                                imageRect: imageRect,
                                viewportSize: viewportSize,
                                anchor: anchor,
                                backdropColor: isMemoryViewer ? .clear : .systemBackground
                            )
                            withTransaction(transaction) {
                                nativeDismissalTransitionActive = true
                                dismissalDragStartLocation = value.startLocation
                                infoDragTranslation = 0
                            }
                            beginReturningTimelineTransition(for: asset)
                            updateNativeDismissal(
                                translation: value.translation,
                                viewportHeight: viewportSize.height
                            )
                            return
                        }
                        if let asset = session.selectedAsset {
                            beginReturningTimelineTransition(for: asset)
                        }
                    }
                    withTransaction(transaction) {
                        if dismissalViewerRect == nil {
                            dismissalViewerRect = viewerRect
                        }
                        dismissalDragStartLocation = value.startLocation
                        dismissalDragTranslation = CGSize(
                            width: value.translation.width,
                            height: isMemoryViewer
                                ? value.translation.height
                                : max(0, value.translation.height)
                        )
                        dismissalBackdropOpacity = AssetViewerDismissalGeometry.backgroundOpacity(
                            translationHeight: AssetViewerDismissalGeometry.dismissalDistance(
                                translationHeight: value.translation.height,
                                allowsUpward: isMemoryViewer
                            ),
                            viewportHeight: viewportSize.height
                        )
                        infoDragTranslation = 0
                    }
                    return
                }
                if isMemoryViewer {
                    let wasDismissing = isDismissalInteractionActive
                    withTransaction(transaction) {
                        dismissalDragTranslation = .zero
                        dismissalViewerRect = nil
                        dismissalBackdropOpacity = 1
                        infoDragTranslation = 0
                    }
                    if wasDismissing {
                        returningTimelineThumbnailChanged(nil)
                    }
                    return
                }
                let wasDismissing = isDismissalInteractionActive
                withTransaction(transaction) {
                    dismissalDragTranslation = .zero
                    dismissalViewerRect = nil
                    dismissalBackdropOpacity = 1
                    infoDragTranslation = dragRoute == .infoPanel
                        ? (showsInfo
                            ? max(0, value.translation.height)
                            : min(0, value.translation.height))
                        : 0
                }
                if wasDismissing {
                    returningLivePhotoBadgeChanged(nil)
                    returningTimelineThumbnailChanged(nil)
                }
            }
            .onEnded { value in
                guard !openingIsActive, !isDismissing else {
                    verticalDragRoute = nil
                    return
                }
                let dragRoute = AssetViewerVerticalDragRouting.resolve(
                    lockedRoute: verticalDragRoute,
                    translationHeight: value.translation.height,
                    startLocation: value.startLocation,
                    mediaRect: mediaRect,
                    showsInfo: showsInfo,
                    allowsUpwardDismissal: isMemoryViewer
                )
                verticalDragRoute = nil
                guard zoomedAssetID == nil else {
                    cancelDismissalInteraction()
                    settleInfoGesture(visible: showsInfo)
                    return
                }
                let isVertical = abs(value.translation.height) > abs(value.translation.width) * 1.2
                let drivesDismissal = isVertical
                    && dragRoute == .viewerDismissal
                    && (value.translation.height > 0
                        || (isMemoryViewer && value.translation.height < 0))
                if drivesDismissal {
                    infoDragTranslation = 0
                    if AssetViewerDismissalGeometry.shouldComplete(
                        translationHeight: AssetViewerDismissalGeometry.dismissalDistance(
                            translationHeight: value.translation.height,
                            allowsUpward: isMemoryViewer
                        ),
                        predictedEndTranslationHeight: AssetViewerDismissalGeometry.dismissalDistance(
                            translationHeight: value.predictedEndTranslation.height,
                            allowsUpward: isMemoryViewer
                        )
                    ) {
                        completeDragDismissal(
                            viewportSize: viewportSize,
                            viewportOrigin: viewportOrigin,
                            mediaRect: mediaRect
                        )
                    } else {
                        cancelDismissalInteraction()
                    }
                    return
                }

                cancelDismissalInteraction()
                if isMemoryViewer {
                    resumeMemoryAutoRotation()
                    return
                }
                let crossesThreshold = abs(value.translation.height) >= 36
                guard isVertical, crossesThreshold else {
                    settleInfoGesture(visible: showsInfo)
                    return
                }

                if value.translation.height < 0 {
                    settleInfoGesture(visible: true)
                } else {
                    settleInfoGesture(visible: false)
                }
            }
    }

    private func memoryOutsideDismissalLayer(
        viewportRect: CGRect,
        panelRect: CGRect,
        memoryRowFrame: CGRect?,
        bottomNavigationTop: CGFloat,
        viewportOrigin: CGPoint,
        mediaRect: CGRect
    ) -> some View {
        let regions = AssetViewerMemoryInteractionGeometry.dismissalRects(
            viewportRect: viewportRect,
            panelRect: panelRect,
            memoryRowFrame: memoryRowFrame,
            bottomNavigationTop: bottomNavigationTop
        )
        return ZStack {
            ForEach(Array(regions.enumerated()), id: \.offset) { _, region in
                Color.clear
                    .contentShape(.rect)
                    .frame(width: region.width, height: region.height)
                    .position(x: region.midX, y: region.midY)
                    .onTapGesture {
                        completeDragDismissal(
                            viewportSize: viewportRect.size,
                            viewportOrigin: viewportOrigin,
                            mediaRect: mediaRect
                        )
                    }
            }
        }
        .accessibilityHidden(true)
    }

    private func beginReturningTimelineTransition(for asset: TimelineAssetSummary) {
        dismissalThumbnailRevealTask?.cancel()
        returningTimelineThumbnailChanged(asset.id)
        if asset.livePhotoVideoID != nil {
            returningLivePhotoBadgeChanged(asset.id)
        }
    }

    private func updateNativeDismissal(
        translation: CGSize,
        viewportHeight: CGFloat
    ) {
        let directedTranslation = CGSize(
            width: translation.width,
            height: isMemoryViewer ? translation.height : max(0, translation.height)
        )
        let dismissalDistance = AssetViewerDismissalGeometry.dismissalDistance(
            translationHeight: translation.height,
            allowsUpward: isMemoryViewer
        )
        nativeDismissalController.update(
            translation: directedTranslation,
            scale: AssetViewerDismissalGeometry.scale(
                translationHeight: dismissalDistance,
                viewportHeight: viewportHeight
            ),
            backdropOpacity: AssetViewerDismissalGeometry.backgroundOpacity(
                translationHeight: dismissalDistance,
                viewportHeight: viewportHeight
            )
        )
    }

    private func beginOpeningAnimation() {
        guard dismissalTarget(route.selectedAsset.id) != nil else {
            openingIsActive = false
            resumeMemoryAutoRotation()
            return
        }
        guard !reduceMotion else {
            openingProgress = 1
            openingIsActive = false
            return
        }
        openingTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.28)) {
                openingProgress = 1
            }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            openingIsActive = false
            resumeMemoryAutoRotation()
        }
    }

    private func replaceMemoryRoute() {
        guard isMemoryViewer else { return }
        let originalAssets = session.assets.filter {
            fullResolutionRequestIDs[$0.id] != nil
        }
        neighborLoadTask?.cancel()
        pagerSelectionTask?.cancel()
        memoryAutoAdvanceTask?.cancel()
        memoryWrapTask?.cancel()
        nativeDismissalController.reset()

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            session.replaceMemoryRoute(route)
            pagerPosition = route.selectedAsset.id
            pagerWindowCenterID = route.selectedAsset.id
            pagerPhase = .idle
            zoomedAssetID = nil
            livePhotoPlaybackAssetID = nil
            memoryAssetPressActive = false
            memoryWrapOpacity = 1
            memoryIsWrapping = false
            openingIsActive = false
            openingProgress = 1
            isDismissing = false
            dismissalDragTranslation = .zero
            dismissalDragStartLocation = .zero
            dismissalViewerRect = nil
            dismissalBackdropOpacity = 1
            dismissalLandingScale = nil
            dismissalLandingTranslation = nil
            dismissalLandingCornerRadius = 0
            dismissalCropTargetSize = nil
            dismissalCropProgress = 0
            dismissalAssetOpacity = 1
            nativeDismissalTransitionActive = false
            isLandingDismissal = false
            fullResolutionRequestIDs.removeAll()
            fullResolutionLoadErrors.removeAll()
            livePhotoMotionByteCounts.removeAll()
        }
        updateViewerPrefetch()
        syncVideoPlaybackSession()
        resetMemoryAutoRotation()
        guard !originalAssets.isEmpty else { return }
        Task { @MainActor in
            media.removeViewerOriginalCache(for: originalAssets)
            await media.removeViewerLivePhotoMotionCache()
        }
    }

    private func completeDragDismissal(
        viewportSize: CGSize,
        viewportOrigin: CGPoint,
        mediaRect: CGRect
    ) {
        guard !isDismissing else { return }
        pauseMemoryAutoRotation()
        memoryWrapTask?.cancel()
        memoryWrapTask = nil
        memoryIsWrapping = false
        memoryWrapOpacity = 1
        isDismissing = true
        guard let asset = session.selectedAsset else {
            closeWithoutAnimation()
            return
        }
        beginReturningTimelineTransition(for: asset)
        guard !reduceMotion else {
            closeWithoutAnimation()
            return
        }
        let destination = dismissalTarget(asset.id)
        let target = destination?.imageFrame.offsetBy(
            dx: -viewportOrigin.x,
            dy: -viewportOrigin.y
        ) ?? CGRect(
            x: viewportSize.width / 2 - 40,
            y: viewportSize.height - 120,
            width: 80,
            height: 80
        )
        let imageRect = selectedRenderedImageRect(in: mediaRect)
        let anchor = AssetViewerDismissalGeometry.anchor(
            startLocation: dismissalDragStartLocation,
            viewportSize: viewportSize
        )
        if isMemoryViewer,
           !nativeDismissalController.isActive,
           asset.mediaKind != .video,
           let transitionImage = media.cachedViewerTransitionImage(
               for: asset,
               targetPixels: MediaPixelSize(
                   width: Int(max(1, viewportSize.width * displayScale)),
                   height: Int(max(1, viewportSize.height * displayScale))
               )
           )
        {
            nativeDismissalController.begin(
                image: transitionImage,
                imageRect: imageRect,
                viewportSize: viewportSize,
                anchor: anchor,
                backdropColor: .clear
            )
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                nativeDismissalTransitionActive = true
            }
        }
        let landing = AssetViewerDismissalGeometry.landingTransform(
            imageRect: imageRect,
            targetRect: target,
            viewportSize: viewportSize,
            anchor: anchor,
            fillsTarget: destination?.fillsFrame == true
        )
        if nativeDismissalController.isActive {
            let cropSize = destination?.fillsFrame == true
                ? AssetViewerDismissalGeometry.sourceCropSize(
                    imageRect: imageRect,
                    targetRect: target,
                    landingScale: landing.scale
                )
                : imageRect.size
            let cropRect = CGRect(
                x: imageRect.midX - cropSize.width / 2,
                y: imageRect.midY - cropSize.height / 2,
                width: cropSize.width,
                height: cropSize.height
            )
            nativeDismissalController.complete(
                translation: landing.translation,
                scale: landing.scale,
                maskRect: cropRect,
                cornerRadius: (destination?.cornerRadius ?? 0)
                    / max(landing.scale, 0.04),
                duration: 0.28
            )
            withAnimation(.easeInOut(duration: 0.45)) {
                isLandingDismissal = true
            }
            dismissalLandingTask = Task { @MainActor in
                if destination?.fillsFrame == true {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    returningTimelineThumbnailChanged(nil)
                    nativeDismissalController.fadeImageOut(duration: 0.12)
                    try? await Task.sleep(for: .milliseconds(200))
                } else {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                guard !Task.isCancelled else { return }
                closeWithoutAnimation()
            }
            return
        }
        if destination?.fillsFrame == true {
            dismissalCropTargetSize = AssetViewerDismissalGeometry.sourceCropSize(
                imageRect: imageRect,
                targetRect: target,
                landingScale: landing.scale
            )
        }
        withAnimation(.easeOut(duration: 0.28)) {
            dismissalLandingScale = landing.scale
            dismissalLandingTranslation = landing.translation
            dismissalBackdropOpacity = 0
            dismissalLandingCornerRadius = (destination?.cornerRadius ?? 0)
                / max(landing.scale, 0.04)
        }
        if destination?.fillsFrame == true {
            dismissalCropProgress = 1
        }
        withAnimation(.easeInOut(duration: 0.45)) {
            isLandingDismissal = true
        }
        dismissalLandingTask = Task { @MainActor in
            if destination?.fillsFrame == true {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                returningTimelineThumbnailChanged(nil)
                withAnimation(.easeInOut(duration: 0.12)) {
                    dismissalAssetOpacity = 0
                }
                try? await Task.sleep(for: .milliseconds(200))
            } else {
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard !Task.isCancelled else { return }
            closeWithoutAnimation()
        }
    }

    private func closeWithoutAnimation() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { close() }
    }

    private func cancelDismissalInteraction() {
        guard isDismissalInteractionActive else { return }
        if nativeDismissalController.isActive {
            returningLivePhotoBadgeChanged(nil)
            dismissalThumbnailRevealTask?.cancel()
            nativeDismissalController.cancel(duration: 0.32) {
                guard !isDismissing else { return }
                returningTimelineThumbnailChanged(nil)
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    nativeDismissalTransitionActive = false
                    dismissalDragStartLocation = .zero
                }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(16))
                    guard !nativeDismissalController.isActive,
                          !nativeDismissalTransitionActive,
                          !isDismissing
                    else { return }
                    nativeDismissalController.reset()
                    resumeVideoAfterCancelledDismissalIfNeeded()
                    resumeMemoryAutoRotation()
                }
            }
            return
        }
        withAnimation(reduceMotion ? nil : .spring(duration: 0.32, bounce: 0.1)) {
            dismissalDragTranslation = .zero
            dismissalDragStartLocation = .zero
            dismissalBackdropOpacity = 1
        }
        dismissalViewerRect = nil
        resumeVideoAfterCancelledDismissalIfNeeded()
        returningLivePhotoBadgeChanged(nil)
        dismissalThumbnailRevealTask?.cancel()
        dismissalThumbnailRevealTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled, !isDismissing else { return }
            returningTimelineThumbnailChanged(nil)
            dismissalThumbnailRevealTask = nil
            resumeMemoryAutoRotation()
        }
    }

    private var infoPresentationProgress: CGFloat {
        guard !reduceMotion else { return showsInfo ? 1 : 0 }
        let revealDistance: CGFloat = 160
        let progress = showsInfo
            ? 1 - max(0, infoDragTranslation) / revealDistance
            : max(0, -infoDragTranslation) / revealDistance
        return min(1, max(0, progress))
    }

    private var isDismissalInteractionActive: Bool {
        nativeDismissalTransitionActive || dismissalDragTranslation.height > 0
    }

    private var shouldHideStatusBar: Bool {
        guard !videoRoutePickerPresented, !isLandingDismissal else { return false }
        if session.isVideoPlayback, videoFirstFrameReady, !showsInfo,
           !isDismissalInteractionActive, !isDismissing
        {
            return !videoControlsVisible
        }
        return isDismissalInteractionActive || isDismissing || (!chromeVisible && !showsInfo)
    }

    private func resolvedSafeAreaInsets(
        safeGeometry: GeometryProxy,
        safeFrame: CGRect,
        fullFrame: CGRect
    ) -> EdgeInsets {
        EdgeInsets(
            top: max(safeGeometry.safeAreaInsets.top, safeFrame.minY - fullFrame.minY, 0),
            leading: max(safeGeometry.safeAreaInsets.leading, safeFrame.minX - fullFrame.minX, 0),
            bottom: max(safeGeometry.safeAreaInsets.bottom, fullFrame.maxY - safeFrame.maxY, 0),
            trailing: max(safeGeometry.safeAreaInsets.trailing, fullFrame.maxX - safeFrame.maxX, 0)
        )
    }

    private func updateViewerPrefetch() {
        guard let selectedIndex = session.selectedIndex,
              let viewerPreviewTargetPixels
        else {
            media.cancelViewerPrefetching()
            return
        }
        let descriptors = [-1, 1, -2, 2]
            .compactMap { offset -> TimelineAssetSummary? in
                let index = selectedIndex + offset
                guard session.assets.indices.contains(index) else { return nil }
                return session.assets[index]
            }
            .map {
                MediaLibraryController.viewerPreviewDescriptor(
                    for: $0,
                    targetPixels: viewerPreviewTargetPixels
                )
            }
        media.updateViewerPrefetch(descriptors)
    }

    private func scheduleNeighborLoading(for assetID: String) {
        neighborLoadTask?.cancel()
        neighborLoadTask = Task {
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, session.selectedAssetID == assetID else { return }
            await session.loadNeighborsIfNeeded()
        }
    }

    private func schedulePagerSelectionSync(_ assetID: String?) {
        pagerSelectionTask?.cancel()
        guard let assetID, assetID != session.selectedAssetID else { return }
        pagerSelectionTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled,
                  pagerPhase == .idle, pagerPosition == assetID
            else { return }
            await preloadCachedAssetDetails([assetID])
            guard !Task.isCancelled,
                  pagerPhase == .idle,
                  pagerPosition == assetID,
                  session.selectImmediately(assetID)
            else { return }
            recenterPagerWindowIfNeeded(on: assetID)
            scheduleNeighborLoading(for: assetID)
        }
    }

    private func selectPagerAsset(
        _ assetID: String,
        updatesPosition: Bool = true
    ) {
        if updatesPosition {
            pagerPosition = assetID
        }
        guard session.selectImmediately(assetID) else { return }
        recenterPagerWindowIfNeeded(on: assetID)
        scheduleNeighborLoading(for: assetID)
    }

    private var pagerWindowAssets: ArraySlice<TimelineAssetSummary> {
        let centerIndex = session.assets.firstIndex(where: { $0.id == pagerWindowCenterID })
            ?? session.selectedIndex
            ?? session.assets.startIndex
        let lower = max(session.assets.startIndex, centerIndex - pagerWindowRadius)
        let upper = min(session.assets.endIndex, centerIndex + pagerWindowRadius + 1)
        return session.assets[lower ..< upper]
    }

    private func recenterPagerWindowIfNeeded(on assetID: String) {
        let window = pagerWindowAssets
        guard pagerWindowCenterID != assetID,
              let selectedIndex = session.assets.firstIndex(where: { $0.id == assetID }),
              let lower = window.indices.first,
              let upper = window.indices.last,
              selectedIndex - lower <= 1 || upper - selectedIndex <= 1
        else { return }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            pagerWindowCenterID = assetID
            pagerPosition = assetID
        }
    }

    private func updateInfoContentHeight(_ height: CGFloat, for assetID: String) {
        let measuredHeight = ceil(height)
        guard measuredHeight > 0,
              abs(measuredHeight - (infoContentHeightsByAssetID[assetID] ?? 0)) >= 1
        else { return }
        infoContentHeightsByAssetID[assetID] = measuredHeight
    }

    private func infoContentHeight(for assetID: String) -> CGFloat {
        infoContentHeightsByAssetID[assetID] ?? 220
    }

    private func toggleChrome() {
        guard !showsInfo else { return }
        withAnimation(chromeAnimation) {
            chromeVisible.toggle()
        }
    }

    private func fullResolutionState(
        for asset: TimelineAssetSummary
    ) -> AssetViewerFullResolutionState? {
        guard asset.mediaKind != .video else { return nil }
        if renderedImageMetadataByAssetID[asset.id]?.source == .original {
            return .loaded
        }
        if let error = fullResolutionLoadErrors[asset.id] {
            return .failed(error)
        }
        if fullResolutionRequestIDs[asset.id] != nil {
            return .loading
        }
        return .available
    }

    private func renderedImageMetadataForInfo(
        for asset: TimelineAssetSummary
    ) -> AssetViewerRenderedImageMetadata? {
        guard let metadata = renderedImageMetadataByAssetID[asset.id] else { return nil }
        guard metadata.source == .original,
              asset.livePhotoVideoID != nil
        else { return metadata }
        return metadata.includingMotion(byteCount: livePhotoMotionByteCounts[asset.id])
    }

    private func videoPlaybackMetadata(
        for asset: TimelineAssetSummary
    ) -> AssetViewerVideoPlaybackMetadata? {
        guard asset.id == videoPlaybackSession?.assetID,
              let metadata = videoPlaybackSession?.metadata
        else { return nil }
        let dynamicRange: AssetViewerVideoDynamicRange = switch metadata.dynamicRange {
        case .sdr: .sdr
        case .hdr: .hdr
        case .dolbyVision: .dolbyVision
        }
        return AssetViewerVideoPlaybackMetadata(
            fileSizeBytes: metadata.fileSizeBytes,
            pixelSize: metadata.pixelSize,
            frameRate: metadata.frameRate,
            videoCodec: metadata.videoCodec,
            videoBitrate: metadata.videoBitrate,
            audioCodec: metadata.audioCodec,
            dynamicRange: dynamicRange
        )
    }

    private func syncVideoPlaybackSession() {
        guard let selectedAsset = session.selectedAsset,
              selectedAsset.mediaKind == .video
        else {
            videoPlaybackSession?.close()
            videoPlaybackSession = nil
            videoFirstFrameReady = false
            videoControlsVisible = true
            videoRoutePickerPresented = false
            resumesVideoAfterCancelledDismissal = false
            return
        }
        guard videoPlaybackSession?.assetID != selectedAsset.id else { return }
        videoPlaybackSession?.close()
        videoFirstFrameReady = false
        videoControlsVisible = true
        videoRoutePickerPresented = false
        resumesVideoAfterCancelledDismissal = false
        videoPlaybackSession = VideoPlaybackSession(assetID: selectedAsset.id)
    }

    private func pauseVideoForDismissalIfNeeded() {
        guard !resumesVideoAfterCancelledDismissal,
              let videoPlaybackSession,
              videoPlaybackSession.isPlaybackIntended
        else { return }
        resumesVideoAfterCancelledDismissal = true
        videoPlaybackSession.pause()
    }

    private func resumeVideoAfterCancelledDismissalIfNeeded() {
        guard resumesVideoAfterCancelledDismissal,
              let videoPlaybackSession
        else { return }
        resumesVideoAfterCancelledDismissal = false
        Task { @MainActor in
            await videoPlaybackSession.play()
        }
    }

    private func requestFullResolution(for assetID: String) {
        fullResolutionLoadErrors.removeValue(forKey: assetID)
        fullResolutionRequestIDs[assetID, default: 0] += 1
    }

    private func mediaTapped() {
        guard !isMemoryViewer else { return }
        if showsInfo {
            setInfoVisible(false)
        } else {
            toggleChrome()
        }
    }

    private func videoReadyForDisplayChanged(_ isReady: Bool) {
        let resolved = ViewerVideoReadiness.resolved(
            current: videoFirstFrameReady,
            reported: isReady
        )
        guard resolved != videoFirstFrameReady else { return }
        withAnimation(chromeAnimation) {
            videoFirstFrameReady = resolved
            videoControlsVisible = resolved
            chromeVisible = showsInfo || !resolved
        }
    }

    private func videoControlVisibilityChanged(_: Bool) {
        guard !showsInfo, chromeVisible else { return }
        withAnimation(chromeAnimation) {
            chromeVisible = false
        }
    }

    private func videoRoutePresentationChanged(_ presented: Bool) {
        guard presented != videoRoutePickerPresented else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: presented ? 0.12 : 0.24)) {
            videoRoutePickerPresented = presented
        }
    }

    @ViewBuilder
    private func videoPreparationOverlay(
        session: VideoPlaybackSession,
        mediaRect: CGRect,
        showsMediaBackground: Bool
    ) -> some View {
        if showsMediaBackground {
            switch session.phase {
            case .preparing where !videoFirstFrameReady:
                RemmichLoadingView(label: "Preparing video", size: 48)
                    .padding(8)
                    .background(.regularMaterial, in: .rect(cornerRadius: DesignMetrics.defaultCornerRadius))
                    .position(x: mediaRect.midX, y: mediaRect.midY)
            case let .failed(failure):
                VStack(spacing: 10) {
                    Text(videoPlaybackFailureMessage(failure))
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                    if failure.allowsRetry {
                        Button("Retry") {
                            Task { @MainActor in
                                await session.retry(using: media)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("asset-viewer-video-retry")
                    }
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .frame(maxWidth: min(320, mediaRect.width - 48))
                .position(x: mediaRect.midX, y: mediaRect.midY)
            case .preparing, .playing, .paused, .seeking, .suspended:
                EmptyView()
            }
        }
    }

    private func videoPlaybackFailureMessage(_ failure: VideoPlaybackFailure) -> String {
        switch failure {
        case .authentication:
            "The connection is no longer authorized."
        case .unavailable:
            "This video is no longer available."
        case .network:
            "The video stream was interrupted."
        case .unsupportedMedia:
            "This video format cannot be played on this device."
        case .playbackServiceReset:
            "Video playback was interrupted by the system."
        case .invalidRange:
            "The server returned an invalid video range."
        case .audioSession:
            "Audio playback could not be started."
        case .firstFrameTimedOut:
            "The first video frame did not become ready."
        case .unknown:
            "This video is currently unavailable."
        }
    }

    private func setInfoVisible(_ visible: Bool) {
        guard visible != showsInfo else { return }
        withAnimation(infoAnimation) {
            chromeVisible = visible || !videoFirstFrameReady
            infoDragTranslation = 0
            showsInfo = visible
        }
    }

    private func settleInfoGesture(visible: Bool) {
        withAnimation(infoAnimation) {
            chromeVisible = visible || !videoFirstFrameReady
            infoDragTranslation = 0
            showsInfo = visible
        }
    }

    private var infoAnimation: Animation? {
        reduceMotion ? nil : .spring(duration: 0.38, bounce: 0.08)
    }

    private var chromeAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.28)
    }

    private func loadSelectedAssetDetail() async {
        let assetID = session.selectedAssetID
        await loadAssetDetail(assetID)
        guard !Task.isCancelled, session.selectedAssetID == assetID, showsInfo,
              let selectedIndex = session.selectedIndex
        else { return }

        let neighborIndices = [selectedIndex - 1, selectedIndex + 1]
            .filter(session.assets.indices.contains)
        for index in neighborIndices {
            await loadAssetDetail(session.assets[index].id)
            guard !Task.isCancelled, session.selectedAssetID == assetID, showsInfo else { return }
        }
    }

    private func preloadCachedAssetDetails(_ assetIDs: [String]) async {
        for assetID in assetIDs {
            guard !Task.isCancelled else { return }
            guard detailStates[assetID] == nil,
                  !cachedDetailMissAssetIDs.contains(assetID)
            else { continue }

            let cachedDetail = await assetDetails.cachedAssetDetail(id: assetID)
            guard !Task.isCancelled else { return }
            guard detailStates[assetID] == nil else { continue }
            if let cachedDetail {
                detailStates[assetID] = .loaded(cachedDetail)
            } else {
                cachedDetailMissAssetIDs.insert(assetID)
            }
        }
    }

    private func loadAssetDetail(_ assetID: String) async {
        guard !refreshedDetailAssetIDs.contains(assetID) else { return }
        let cachedDetail: AssetDetail?
        if case let .loaded(detail)? = detailStates[assetID] {
            cachedDetail = detail
        } else if cachedDetailMissAssetIDs.contains(assetID) {
            cachedDetail = nil
        } else {
            cachedDetail = await assetDetails.cachedAssetDetail(id: assetID)
            guard !Task.isCancelled else { return }
            if cachedDetail == nil {
                cachedDetailMissAssetIDs.insert(assetID)
            }
        }
        if let cachedDetail {
            if detailStates[assetID] != .loaded(cachedDetail) {
                detailStates[assetID] = .loaded(cachedDetail)
            }
        } else if detailStates[assetID] == nil {
            detailStates[assetID] = .loading
        }
        do {
            let detail = try await assetDetails.assetDetail(id: assetID)
            guard !Task.isCancelled else { return }
            if detailStates[assetID] != .loaded(detail) {
                detailStates[assetID] = .loaded(detail)
            }
            refreshedDetailAssetIDs.insert(assetID)
        } catch is CancellationError {
            if cachedDetail == nil, case .loading? = detailStates[assetID] {
                detailStates[assetID] = .idle
            }
            return
        } catch {
            guard !Task.isCancelled else {
                if cachedDetail == nil, case .loading? = detailStates[assetID] {
                    detailStates[assetID] = .idle
                }
                return
            }
            if cachedDetail == nil {
                detailStates[assetID] = .failed(error.localizedDescription)
            }
        }
    }

    private func detailState(for assetID: String) -> AssetViewerDetailState {
        detailStates[assetID] ?? .idle
    }

    private func retryDetail(for assetID: String) {
        guard assetID == session.selectedAssetID else { return }
        refreshedDetailAssetIDs.remove(assetID)
        detailStates[assetID] = .idle
        Task { await loadAssetDetail(assetID) }
    }
}

nonisolated enum AssetViewerMediaGeometry {
    static func animatesFitChanges(infoDragTranslation: CGFloat) -> Bool {
        infoDragTranslation == 0
    }

    static func mediaRect(
        viewportSize: CGSize,
        safeAreaInsets: UIEdgeInsets,
        infoProgress: CGFloat,
        topChromeHeight: CGFloat,
        shownInfoBottomInset: CGFloat
    ) -> CGRect {
        let progress = min(1, max(0, infoProgress))
        let leadingInset = safeAreaInsets.left * progress
        let trailingInset = safeAreaInsets.right * progress
        let topInset = (safeAreaInsets.top + topChromeHeight) * progress
        let bottomInset = (safeAreaInsets.bottom + shownInfoBottomInset) * progress
        return CGRect(
            x: leadingInset,
            y: topInset,
            width: max(1, viewportSize.width - leadingInset - trailingInset),
            height: max(1, viewportSize.height - topInset - bottomInset)
        )
    }

    static func landscapeVideoInfoRect(
        viewportSize: CGSize,
        safeAreaInsets: UIEdgeInsets,
        infoProgress: CGFloat,
        topChromeHeight: CGFloat
    ) -> CGRect {
        let progress = min(1, max(0, infoProgress))
        let leadingInset = safeAreaInsets.left * progress
        let trailingInset = safeAreaInsets.right * progress
        let topInset = (safeAreaInsets.top + topChromeHeight) * progress
        let bottomInset = safeAreaInsets.bottom * progress
        return CGRect(
            x: leadingInset,
            y: topInset,
            width: max(1, viewportSize.width - leadingInset - trailingInset),
            height: max(1, viewportSize.height - topInset - bottomInset)
        )
    }

    static func renderedPixelRect(pixelSize: CGSize, in boundingRect: CGRect) -> CGRect {
        guard pixelSize.width.isFinite,
              pixelSize.height.isFinite,
              pixelSize.width > 0,
              pixelSize.height > 0,
              boundingRect.width > 0,
              boundingRect.height > 0
        else { return .zero }
        let scale = min(
            boundingRect.width / pixelSize.width,
            boundingRect.height / pixelSize.height
        )
        let fittedSize = CGSize(
            width: pixelSize.width * scale,
            height: pixelSize.height * scale
        )
        return CGRect(
            x: boundingRect.midX - fittedSize.width / 2,
            y: boundingRect.midY - fittedSize.height / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }
}

nonisolated enum AssetViewerMemoryGeometry {
    static func openingTransform(
        from source: CGRect,
        to destination: CGRect,
        progress: CGFloat
    ) -> (scale: CGSize, translation: CGSize) {
        guard destination.width > 0, destination.height > 0 else {
            return (CGSize(width: 1, height: 1), .zero)
        }
        let progress = min(max(progress, 0), 1)
        let remainder = 1 - progress
        return (
            CGSize(
                width: 1 + (source.width / destination.width - 1) * remainder,
                height: 1 + (source.height / destination.height - 1) * remainder
            ),
            CGSize(
                width: (source.midX - destination.midX) * remainder,
                height: (source.midY - destination.midY) * remainder
            )
        )
    }

    static func panelRect(
        viewportSize: CGSize,
        safeAreaInsets: UIEdgeInsets,
        bottomNavigationTop: CGFloat,
        memoryRowBottom: CGFloat,
        isPad: Bool
    ) -> CGRect {
        let horizontalMargin: CGFloat = isPad ? 32 : 16
        let availableWidth = max(
            1,
            viewportSize.width
                - safeAreaInsets.left
                - safeAreaInsets.right
                - horizontalMargin * 2
        )
        let width = isPad ? min(976, availableWidth) : availableWidth
        let fallbackNavigationHeight: CGFloat = isPad
            ? 72
            : (viewportSize.width > viewportSize.height ? 64 : 84)
        let resolvedNavigationTop = bottomNavigationTop > safeAreaInsets.top
            ? min(bottomNavigationTop, viewportSize.height - safeAreaInsets.bottom)
            : viewportSize.height - fallbackNavigationHeight
        let contentTop = safeAreaInsets.top
        let contentBottom = max(contentTop + 1, resolvedNavigationTop)
        let contentHeight = contentBottom - contentTop
        let minimumPanelHeight = min(contentHeight, 324)
        let resolvedMemoryRowBottom = memoryRowBottom > contentTop
            ? min(memoryRowBottom, contentBottom)
            : contentTop
        let outerVerticalPadding: CGFloat = isPad ? 20 : 16
        let desiredTop = resolvedMemoryRowBottom + outerVerticalPadding
        let desiredBottom = contentBottom - outerVerticalPadding
        let desiredHeight = desiredBottom - desiredTop
        let height = desiredHeight >= minimumPanelHeight
            ? desiredHeight
            : minimumPanelHeight
        let y = desiredHeight >= minimumPanelHeight
            ? desiredTop
            : contentTop + (contentHeight - height) / 2
        return CGRect(
            x: (viewportSize.width - width) / 2,
            y: y,
            width: width,
            height: height
        )
    }

    static func mediaRect(
        viewportSize: CGSize,
        safeAreaInsets: UIEdgeInsets,
        bottomNavigationTop: CGFloat,
        memoryRowBottom: CGFloat,
        isPad: Bool
    ) -> CGRect {
        let panel = panelRect(
            viewportSize: viewportSize,
            safeAreaInsets: safeAreaInsets,
            bottomNavigationTop: bottomNavigationTop,
            memoryRowBottom: memoryRowBottom,
            isPad: isPad
        )
        let mediaInset: CGFloat = isPad ? 32 : 24
        let headerHeight: CGFloat = 80
        return CGRect(
            x: panel.minX + mediaInset,
            y: panel.minY + headerHeight,
            width: max(1, panel.width - mediaInset * 2),
            height: max(220, panel.height - headerHeight - mediaInset)
        )
    }
}

nonisolated enum AssetViewerDismissalGeometry {
    private static let maximumScaleReduction: CGFloat = 0.18

    static func dismissalDistance(
        translationHeight: CGFloat,
        allowsUpward: Bool
    ) -> CGFloat {
        allowsUpward ? abs(translationHeight) : max(0, translationHeight)
    }

    static func backgroundOpacity(
        translationHeight: CGFloat,
        viewportHeight: CGFloat
    ) -> CGFloat {
        let revealDistance = max(160, min(320, viewportHeight * 0.35))
        return 1 - min(1, max(0, (translationHeight - 16) / revealDistance))
    }

    static func progress(translationHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        let travel = max(160, min(320, viewportHeight * 0.35))
        return min(1, max(0, translationHeight) / travel)
    }

    static func scale(translationHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        1 - maximumScaleReduction * progress(
            translationHeight: translationHeight,
            viewportHeight: viewportHeight
        )
    }

    static func anchor(startLocation: CGPoint, viewportSize: CGSize) -> UnitPoint {
        guard viewportSize.width > 0,
              viewportSize.height > 0,
              startLocation != .zero
        else { return .center }
        return UnitPoint(
            x: min(1, max(0, startLocation.x / viewportSize.width)),
            y: min(1, max(0, startLocation.y / viewportSize.height))
        )
    }

    static func landingTransform(
        imageRect: CGRect,
        targetRect: CGRect,
        viewportSize: CGSize,
        anchor: UnitPoint,
        fillsTarget: Bool = false
    ) -> (scale: CGFloat, translation: CGSize) {
        guard imageRect.width > 0, imageRect.height > 0,
              targetRect.width > 0, targetRect.height > 0
        else { return (1, .zero) }
        let widthScale = targetRect.width / imageRect.width
        let heightScale = targetRect.height / imageRect.height
        let scale = min(1, max(0.04, fillsTarget
                ? max(widthScale, heightScale)
                : min(widthScale, heightScale)))
        let pivot = CGPoint(
            x: anchor.x * viewportSize.width,
            y: anchor.y * viewportSize.height
        )
        return (
            scale,
            CGSize(
                width: targetRect.midX - pivot.x - scale * (imageRect.midX - pivot.x),
                height: targetRect.midY - pivot.y - scale * (imageRect.midY - pivot.y)
            )
        )
    }

    static func sourceCropSize(
        imageRect: CGRect,
        targetRect: CGRect,
        landingScale: CGFloat
    ) -> CGSize {
        guard landingScale.isFinite, landingScale > 0,
              imageRect.width > 0, imageRect.height > 0,
              targetRect.width > 0, targetRect.height > 0
        else { return imageRect.size }
        return CGSize(
            width: min(imageRect.width, targetRect.width / landingScale),
            height: min(imageRect.height, targetRect.height / landingScale)
        )
    }

    static func croppedImageRect(
        _ imageRect: CGRect,
        targetSize: CGSize?,
        progress: CGFloat
    ) -> CGRect {
        guard let targetSize else { return imageRect }
        let amount = min(1, max(0, progress))
        let width = imageRect.width + (targetSize.width - imageRect.width) * amount
        let height = imageRect.height + (targetSize.height - imageRect.height) * amount
        return CGRect(
            x: imageRect.midX - width / 2,
            y: imageRect.midY - height / 2,
            width: width,
            height: height
        )
    }

    static func shouldComplete(
        translationHeight: CGFloat,
        predictedEndTranslationHeight: CGFloat
    ) -> Bool {
        translationHeight >= 18 || predictedEndTranslationHeight >= 60
    }
}

nonisolated enum AssetViewerVerticalDragRouting {
    static func resolve(
        lockedRoute: AssetViewerVerticalDragRoute?,
        translationHeight: CGFloat,
        startLocation: CGPoint,
        mediaRect: CGRect,
        showsInfo: Bool,
        allowsUpwardDismissal: Bool = false
    ) -> AssetViewerVerticalDragRoute {
        if let lockedRoute {
            return lockedRoute
        }
        guard translationHeight > 0
            || (allowsUpwardDismissal && translationHeight < 0)
        else { return .infoPanel }
        return !showsInfo || mediaRect.contains(startLocation)
            ? .viewerDismissal
            : .infoPanel
    }
}

nonisolated enum AssetViewerVerticalDragRoute: Equatable {
    case viewerDismissal
    case infoPanel
}

nonisolated enum AssetViewerMemoryInteractionGeometry {
    static func dismissalRects(
        viewportRect: CGRect,
        panelRect: CGRect,
        memoryRowFrame: CGRect?,
        bottomNavigationTop: CGFloat
    ) -> [CGRect] {
        let navigationTop = bottomNavigationTop > viewportRect.minY
            ? min(bottomNavigationTop, viewportRect.maxY)
            : viewportRect.maxY
        let clippedPanel = panelRect.intersection(viewportRect)
        guard !clippedPanel.isNull else { return [viewportRect] }

        var rects: [CGRect] = []
        let rowTop = memoryRowFrame.map { max(viewportRect.minY, $0.minY) }
        let rowBottom = memoryRowFrame.map { min(clippedPanel.minY, $0.maxY) }
        let upperEnd = rowTop ?? clippedPanel.minY
        appendRect(
            CGRect(
                x: viewportRect.minX,
                y: viewportRect.minY,
                width: viewportRect.width,
                height: upperEnd - viewportRect.minY
            ),
            to: &rects
        )
        if let rowBottom {
            appendRect(
                CGRect(
                    x: viewportRect.minX,
                    y: rowBottom,
                    width: viewportRect.width,
                    height: clippedPanel.minY - rowBottom
                ),
                to: &rects
            )
        }
        appendRect(
            CGRect(
                x: viewportRect.minX,
                y: clippedPanel.minY,
                width: clippedPanel.minX - viewportRect.minX,
                height: clippedPanel.height
            ),
            to: &rects
        )
        appendRect(
            CGRect(
                x: clippedPanel.maxX,
                y: clippedPanel.minY,
                width: viewportRect.maxX - clippedPanel.maxX,
                height: clippedPanel.height
            ),
            to: &rects
        )
        appendRect(
            CGRect(
                x: viewportRect.minX,
                y: clippedPanel.maxY,
                width: viewportRect.width,
                height: navigationTop - clippedPanel.maxY
            ),
            to: &rects
        )
        return rects
    }

    private static func appendRect(_ rect: CGRect, to rects: inout [CGRect]) {
        guard rect.width > 0.5, rect.height > 0.5 else { return }
        rects.append(rect)
    }
}

nonisolated struct AssetViewerInteractionShape: Shape {
    let rect: CGRect?

    func path(in bounds: CGRect) -> Path {
        Path(rect ?? bounds)
    }
}

nonisolated struct AssetViewerMemoryInteractionShape: Shape {
    let viewportRect: CGRect
    let panelRect: CGRect
    let memoryRowFrame: CGRect?
    let bottomNavigationTop: CGFloat

    func path(in _: CGRect) -> Path {
        var path = Path(panelRect)
        for rect in AssetViewerMemoryInteractionGeometry.dismissalRects(
            viewportRect: viewportRect,
            panelRect: panelRect,
            memoryRowFrame: memoryRowFrame,
            bottomNavigationTop: bottomNavigationTop
        ) {
            path.addRect(rect)
        }
        return path
    }
}

nonisolated struct AssetViewerTransitionClipShape: Shape {
    let target: CGRect
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in bounds: CGRect) -> Path {
        let amount = min(1, max(0, progress))
        return Path(CGRect(
            x: bounds.minX + (target.minX - bounds.minX) * amount,
            y: bounds.minY + (target.minY - bounds.minY) * amount,
            width: bounds.width + (target.width - bounds.width) * amount,
            height: bounds.height + (target.height - bounds.height) * amount
        ))
    }
}

private struct AssetViewerNativeDismissalSurface: UIViewRepresentable {
    let controller: AssetViewerNativeDismissalController

    func makeCoordinator() -> AssetViewerNativeDismissalController {
        controller
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isUserInteractionEnabled = false
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.attach(to: uiView)
    }

    static func dismantleUIView(
        _ uiView: UIView,
        coordinator: AssetViewerNativeDismissalController
    ) {
        coordinator.detach(from: uiView)
    }
}

@MainActor
private final class AssetViewerNativeDismissalController: NSObject {
    private weak var hostView: UIView?
    private let backdropView = UIView()
    private let contentView = UIView()
    private let imageView = UIImageView()
    private let maskLayer = CAShapeLayer()
    private var animator: UIViewPropertyAnimator?

    private(set) var isActive = false

    func attach(to hostView: UIView) {
        if self.hostView !== hostView {
            detachFromCurrentHost()
            self.hostView = hostView
            hostView.isHidden = true

            backdropView.backgroundColor = .systemBackground
            backdropView.isUserInteractionEnabled = false
            contentView.backgroundColor = .clear
            contentView.isUserInteractionEnabled = false
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.isUserInteractionEnabled = false
            contentView.layer.mask = maskLayer
            contentView.addSubview(imageView)
            hostView.addSubview(backdropView)
            hostView.addSubview(contentView)
        }
        guard !isActive else { return }
        backdropView.frame = hostView.bounds
        contentView.frame = hostView.bounds
        maskLayer.frame = contentView.bounds
    }

    func detach(from hostView: UIView) {
        guard self.hostView === hostView else { return }
        reset()
        detachFromCurrentHost()
    }

    func begin(
        image: UIImage,
        imageRect: CGRect,
        viewportSize: CGSize,
        anchor: UnitPoint,
        backdropColor: UIColor
    ) {
        guard let hostView else { return }
        stopAnimations()
        let viewportBounds = CGRect(origin: .zero, size: viewportSize)
        hostView.isHidden = false
        backdropView.frame = viewportBounds
        backdropView.backgroundColor = backdropColor
        backdropView.alpha = 1
        contentView.transform = .identity
        contentView.bounds = viewportBounds
        contentView.layer.anchorPoint = CGPoint(x: anchor.x, y: anchor.y)
        contentView.layer.position = CGPoint(
            x: viewportSize.width * anchor.x,
            y: viewportSize.height * anchor.y
        )
        imageView.image = image
        imageView.frame = imageRect
        imageView.alpha = 1
        maskLayer.frame = viewportBounds
        setMaskPath(rect: imageRect, cornerRadius: 0)
        isActive = true
    }

    func update(
        translation: CGSize,
        scale: CGFloat,
        backdropOpacity: CGFloat
    ) {
        guard isActive else { return }
        UIView.performWithoutAnimation {
            contentView.transform = CGAffineTransform(
                a: scale,
                b: 0,
                c: 0,
                d: scale,
                tx: translation.width,
                ty: translation.height
            )
            backdropView.alpha = backdropOpacity
        }
    }

    func complete(
        translation: CGSize,
        scale: CGFloat,
        maskRect: CGRect,
        cornerRadius: CGFloat,
        duration: TimeInterval
    ) {
        guard isActive else { return }
        stopAnimator()
        animateMask(
            to: maskRect,
            cornerRadius: cornerRadius,
            duration: min(0.14, duration)
        )
        let animator = UIViewPropertyAnimator(
            duration: duration,
            curve: .easeOut
        ) {
            self.contentView.transform = CGAffineTransform(
                a: scale,
                b: 0,
                c: 0,
                d: scale,
                tx: translation.width,
                ty: translation.height
            )
            self.backdropView.alpha = 0
        }
        self.animator = animator
        animator.startAnimation()
    }

    func cancel(
        duration: TimeInterval,
        completion: @escaping @MainActor () -> Void
    ) {
        guard isActive else {
            completion()
            return
        }
        stopAnimator()
        let animator = UIViewPropertyAnimator(
            duration: duration,
            dampingRatio: 0.9
        ) {
            self.contentView.transform = .identity
            self.backdropView.alpha = 1
        }
        self.animator = animator
        animator.addCompletion { [weak self] _ in
            guard let self else { return }
            self.animator = nil
            isActive = false
            completion()
        }
        animator.startAnimation()
    }

    func fadeImageOut(duration: TimeInterval) {
        guard isActive else { return }
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseInOut]
        ) {
            self.imageView.alpha = 0
        }
    }

    func reset() {
        stopAnimations()
        isActive = false
        imageView.image = nil
        imageView.alpha = 1
        contentView.transform = .identity
        contentView.layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        if let hostView {
            contentView.frame = hostView.bounds
            backdropView.frame = hostView.bounds
        }
        backdropView.alpha = 1
        hostView?.isHidden = true
    }

    private func animateMask(
        to rect: CGRect,
        cornerRadius: CGFloat,
        duration: TimeInterval
    ) {
        let finalPath = maskPath(rect: rect, cornerRadius: cornerRadius)
        let animation = CABasicAnimation(keyPath: "path")
        animation.fromValue = maskLayer.presentation()?.path ?? maskLayer.path
        animation.toValue = finalPath
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.path = finalPath
        CATransaction.commit()
        maskLayer.add(animation, forKey: "dismissal-crop")
    }

    private func setMaskPath(rect: CGRect, cornerRadius: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.path = maskPath(rect: rect, cornerRadius: cornerRadius)
        CATransaction.commit()
    }

    private func maskPath(rect: CGRect, cornerRadius: CGFloat) -> CGPath {
        UIBezierPath(
            roundedRect: rect,
            cornerRadius: max(0.001, cornerRadius)
        ).cgPath
    }

    private func stopAnimations() {
        stopAnimator()
        maskLayer.removeAllAnimations()
        imageView.layer.removeAllAnimations()
    }

    private func stopAnimator() {
        animator?.stopAnimation(true)
        animator = nil
    }

    private func detachFromCurrentHost() {
        backdropView.removeFromSuperview()
        contentView.removeFromSuperview()
        hostView = nil
    }
}

private struct AssetDetailLoadRequest: Hashable {
    let assetID: String
    let includesNeighbors: Bool
}

private struct AssetDetailCacheWindowRequest: Hashable {
    let assetIDs: [String]
}

nonisolated enum AssetViewerMemoryAutoRotation {
    static let duration: TimeInterval = 3

    static func isEnabled(
        assetCount: Int,
        reduceMotion: Bool,
        voiceOverEnabled: Bool
    ) -> Bool {
        assetCount > 1 && !reduceMotion && !voiceOverEnabled
    }

    static func elapsed(
        base: TimeInterval,
        startedAt: Date?,
        now: Date
    ) -> TimeInterval {
        let running = startedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
        return min(duration, max(0, base + running))
    }

    static func remaining(after elapsed: TimeInterval) -> TimeInterval {
        max(0, duration - min(duration, max(0, elapsed)))
    }

    static func progress(
        base: TimeInterval,
        startedAt: Date?,
        now: Date
    ) -> Double {
        elapsed(base: base, startedAt: startedAt, now: now) / duration
    }
}

nonisolated enum AssetViewerMemoryBoundaryNavigation {
    private static let minimumTranslation: CGFloat = 48

    static func offset(
        selectedIndex: Int,
        assetCount: Int,
        translation: CGSize,
        predictedEndTranslation: CGSize
    ) -> Int? {
        guard assetCount > 0,
              selectedIndex >= 0,
              selectedIndex < assetCount,
              abs(translation.width) > abs(translation.height) * 1.2
        else { return nil }

        let projectedWidth = abs(predictedEndTranslation.width) > abs(translation.width)
            ? predictedEndTranslation.width
            : translation.width
        if selectedIndex == assetCount - 1, projectedWidth <= -minimumTranslation {
            return 1
        }
        if selectedIndex == 0, projectedWidth >= minimumTranslation {
            return -1
        }
        return nil
    }
}

private struct AssetViewerMemoryProgress: View {
    let count: Int
    let selectedIndex: Int
    let autoElapsed: TimeInterval
    let autoStartedAt: Date?
    let autoRotationEnabled: Bool

    var body: some View {
        TimelineView(.animation(
            minimumInterval: 1.0 / 30.0,
            paused: autoStartedAt == nil
        )) { timeline in
            tracker(progress: currentProgress(at: timeline.date))
        }
        .frame(height: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Memory position")
        .accessibilityValue("\(selectedIndex + 1) of \(max(1, count))")
        .accessibilityIdentifier("memory-viewer-progress")
    }

    @ViewBuilder
    private func tracker(progress: Double) -> some View {
        if count <= 12 {
            GeometryReader { geometry in
                let segmentCount = max(1, count)
                let spacing: CGFloat = 3
                let segmentWidth = max(
                    1,
                    (geometry.size.width - spacing * CGFloat(segmentCount - 1))
                        / CGFloat(segmentCount)
                )
                HStack(alignment: .center, spacing: spacing) {
                    ForEach(0 ..< segmentCount, id: \.self) { index in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.primary.opacity(0.2))

                            Capsule()
                                .fill(Color.primary.opacity(index < selectedIndex ? 0.55 : 1))
                                .frame(
                                    width: segmentWidth * fillAmount(
                                        for: index,
                                        currentProgress: progress
                                    )
                                )
                        }
                        .frame(width: segmentWidth, height: index == selectedIndex ? 4 : 3)
                    }
                }
            }
        } else {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.2))

                    Capsule()
                        .fill(Color.primary)
                        .frame(
                            width: geometry.size.width
                                * CGFloat(Double(selectedIndex) + progress)
                                / CGFloat(max(1, count))
                        )
                }
            }
        }
    }

    private func currentProgress(at date: Date) -> Double {
        guard autoRotationEnabled else { return 1 }
        return AssetViewerMemoryAutoRotation.progress(
            base: autoElapsed,
            startedAt: autoStartedAt,
            now: date
        )
    }

    private func fillAmount(
        for index: Int,
        currentProgress: Double
    ) -> CGFloat {
        if index < selectedIndex {
            return 1
        }
        if index == selectedIndex {
            return CGFloat(currentProgress)
        }
        return 0
    }
}

private struct AssetViewerFitPage: View {
    let asset: TimelineAssetSummary
    let media: MediaLibraryController
    let isSelected: Bool
    let mediaRect: CGRect
    let pageSize: CGSize
    let animatesFitChanges: Bool
    let showsBackground: Bool
    let usesInsetStage: Bool
    let showsVideoPoster: Bool
    let targetPixels: MediaPixelSize
    let fullResolutionRequestID: Int?
    let renderedImageMetadataChanged: (AssetViewerRenderedImageMetadata) -> Void
    let fullResolutionLoadFailed: (String?) -> Void
    let zoomChanged: (Bool) -> Void
    let livePhotoPressChanged: (Bool) -> Void
    let toggleChrome: () -> Void

    var body: some View {
        ZStack {
            if asset.mediaKind == .video {
                Color.black
                    .frame(width: mediaRect.width, height: mediaRect.height)
                    .position(x: mediaRect.midX, y: mediaRect.midY)
                    .opacity(showsBackground ? 1 : 0)
            } else if !usesInsetStage {
                Color(uiColor: .systemBackground)
                    .opacity(showsBackground ? 1 : 0)
            }
            if asset.mediaKind == .video {
                ImmichThumbnail(
                    descriptor: .init(
                        assetID: asset.id,
                        updatedAt: asset.thumbnailRevision,
                        derivative: .preview,
                        targetPixels: targetPixels
                    ),
                    media: media,
                    contentMode: .fit,
                    showsBackground: false
                )
                .frame(width: mediaRect.width, height: mediaRect.height)
                .position(x: mediaRect.midX, y: mediaRect.midY)
                // The poster and AVKit surface fit independently during rotation.
                // Hide the poster beneath ready video, but keep it for return transitions.
                .opacity(showsVideoPoster ? 1 : 0)
            } else {
                ZoomableStillImageView(
                    asset: asset,
                    media: media,
                    isSelected: isSelected,
                    targetPixels: targetPixels,
                    fitRect: mediaRect,
                    animatesFitChanges: animatesFitChanges,
                    showsBackground: showsBackground && !usesInsetStage,
                    reportsRenderedImageMetadata: isSelected,
                    fullResolutionRequestID: fullResolutionRequestID,
                    renderedImageMetadataChanged: renderedImageMetadataChanged,
                    fullResolutionLoadFailed: fullResolutionLoadFailed,
                    zoomChanged: zoomChanged,
                    livePhotoPressChanged: livePhotoPressChanged,
                    toggleChrome: toggleChrome
                )
                .frame(width: pageSize.width, height: pageSize.height)
            }
        }
        .frame(width: pageSize.width, height: pageSize.height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(asset.mediaKind == .video ? "Video" : "Photo")
        .accessibilityIdentifier("asset-viewer-page-\(asset.id)")
    }
}

private struct AssetViewerFilmstrip: View {
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme

    @State private var hasPositionedSelection = false

    let assets: [TimelineAssetSummary]
    let selectedAssetID: String
    let media: MediaLibraryController
    let select: (String) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 4) {
                    ForEach(assets) { asset in
                        Button {
                            select(asset.id)
                        } label: {
                            ImmichThumbnail(
                                descriptor: .init(
                                    assetID: asset.id,
                                    updatedAt: asset.thumbnailRevision,
                                    derivative: .thumbnail,
                                    targetPixels: .init(
                                        width: Int(44 * displayScale),
                                        height: Int(44 * displayScale)
                                    )
                                ),
                                media: media,
                                contentMode: .fill
                            )
                            .frame(width: 40, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .stroke(
                                        asset.id == selectedAssetID ? selectionStroke : .clear,
                                        lineWidth: 2
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(TimelineCaptureDateFormatting.string(
                            from: asset.capturedAt,
                            dateStyle: .medium,
                            timeStyle: .short
                        ))
                        .accessibilityAddTraits(asset.id == selectedAssetID ? .isSelected : [])
                        .accessibilityIdentifier("asset-viewer-filmstrip-\(asset.id)")
                        .id(asset.id)
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .frame(height: 52)
            .task(id: positionRequest) {
                await Task.yield()
                guard !Task.isCancelled,
                      assets.contains(where: { $0.id == selectedAssetID })
                else { return }

                if hasPositionedSelection {
                    withAnimation(.snappy(duration: 0.2)) {
                        proxy.scrollTo(selectedAssetID, anchor: .center)
                    }
                } else {
                    proxy.scrollTo(selectedAssetID, anchor: .center)
                    hasPositionedSelection = true
                }
            }
        }
    }

    private var positionRequest: FilmstripPositionRequest {
        FilmstripPositionRequest(
            selectedAssetID: selectedAssetID,
            selectedIndex: assets.firstIndex { $0.id == selectedAssetID },
            assetCount: assets.count
        )
    }

    private var selectionStroke: Color {
        colorScheme == .dark ? .white : .black
    }
}

private struct FilmstripPositionRequest: Hashable {
    let selectedAssetID: String
    let selectedIndex: Int?
    let assetCount: Int
}

private struct AssetViewerStatusBarVisibilityModifier: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        if #available(iOS 27.0, *) {
            content.toolbarVisibility(hidden ? .hidden : .visible, for: .statusBar)
        } else {
            content.statusBarHidden(hidden)
        }
    }
}

extension View {
    @ViewBuilder
    func assetViewerTransitionSource(
        assetID: String,
        namespace: Namespace.ID?
    ) -> some View {
        if let namespace {
            matchedTransitionSource(id: assetID, in: namespace)
        } else {
            self
        }
    }
}
