import SwiftUI

struct AssetViewerView: View {
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let route: AssetViewerRoute
    let media: MediaLibraryController
    let assetDetails: any AssetDetailReading
    let namespace: Namespace.ID
    let close: () -> Void
    let visibilityChanged: (Bool) -> Void

    @State private var session: AssetViewerSession
    @State private var zoomedAssetID: String?
    @State private var chromeVisible = true
    @State private var showsInfo = false
    @State private var detailStates: [String: AssetViewerDetailState] = [:]
    @State private var cachedDetailMissAssetIDs: Set<String> = []
    @State private var refreshedDetailAssetIDs: Set<String> = []
    @State private var previewMetadataByAssetID: [String: AssetViewerPreviewMetadata] = [:]
    @State private var renderedImageMetadataByAssetID: [String: AssetViewerRenderedImageMetadata] = [:]
    @State private var presentedImageStatusAssetIDs: Set<String> = []
    @State private var visibleImageStatusAssetID: String?
    @State private var imageStatusDismissTask: Task<Void, Never>?
    @State private var neighborLoadTask: Task<Void, Never>?
    @State private var infoContentHeight: CGFloat = 220
    @State private var infoDragTranslation: CGFloat = 0
    @State private var viewerPreviewTargetPixels: MediaPixelSize?
    @State private var pagerPosition: String?
    @State private var pagerWindowCenterID: String
    @State private var pagerPhase: ScrollPhase = .idle
    @State private var pagerSelectionTask: Task<Void, Never>?
    @State private var isDismissing = false

    private let controlHitSize: CGFloat = 44
    private let controlVisualSize: CGFloat = 44
    private let topChromeHeight: CGFloat = 60
    private let bottomActionsHeight: CGFloat = 56
    private let filmstripHeight: CGFloat = 52
    private let filmstripActionsGap: CGFloat = 16
    private let mediaFilmstripGap: CGFloat = 12
    private let infoGap: CGFloat = 12
    private let pagerWindowRadius = 3

    private var bottomChromeHeight: CGFloat {
        mediaFilmstripGap + filmstripHeight + filmstripActionsGap + controlHitSize
    }

    init(
        route: AssetViewerRoute,
        store: PhotosTimelineStore,
        media: MediaLibraryController,
        assetDetails: any AssetDetailReading,
        namespace: Namespace.ID,
        close: @escaping () -> Void,
        visibilityChanged: @escaping (Bool) -> Void
    ) {
        self.route = route
        self.media = media
        self.assetDetails = assetDetails
        self.namespace = namespace
        self.close = close
        self.visibilityChanged = visibilityChanged
        _session = State(initialValue: AssetViewerSession(
            route: route,
            bucketIDs: store.bucketSummaries.map(\.id),
            loadBucket: { bucketID in
                await store.rangeCoverAssets(in: bucketID)
            }
        ))
        _pagerPosition = State(initialValue: route.selectedAsset.id)
        _pagerWindowCenterID = State(initialValue: route.selectedAsset.id)
    }

    var body: some View {
        GeometryReader { safeGeometry in
            GeometryReader { fullGeometry in
                let infoProgress = infoPresentationProgress
                let safeFrame = safeGeometry.frame(in: .global)
                let fullFrame = fullGeometry.frame(in: .global)
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
                let layoutProgress = chromeVisible ? 1 : infoProgress
                let topInset = chromeVisible
                    ? safeInsets.top + topChromeHeight
                    : (safeInsets.top + topChromeHeight) * infoProgress
                let shownInfoBottomInset = bottomActionsHeight + infoGap
                let bottomInset = chromeVisible
                    ? safeInsets.bottom + interpolated(
                        from: bottomChromeHeight,
                        to: shownInfoBottomInset,
                        progress: infoProgress
                    )
                    : (safeInsets.bottom + shownInfoBottomInset) * infoProgress
                let viewerRect = CGRect(
                    x: safeInsets.leading * layoutProgress,
                    y: topInset,
                    width: max(
                        1,
                        fullGeometry.size.width
                            - (safeInsets.leading + safeInsets.trailing) * layoutProgress
                    ),
                    height: max(1, fullGeometry.size.height - topInset - bottomInset)
                )
                ZStack {
                    Color(uiColor: .systemBackground)
                    viewerContent(
                        pageSize: fullGeometry.size,
                        viewerRect: viewerRect,
                        requestSize: fullGeometry.size,
                        isLandscape: fullGeometry.size.width > fullGeometry.size.height,
                        infoProgress: infoProgress
                    )
                    chrome(infoProgress: infoProgress)
                        .frame(width: safeRect.width, height: safeRect.height)
                        .position(x: safeRect.midX, y: safeRect.midY)
                        .zIndex(1)
                        .opacity(chromeVisible ? 1 : infoProgress)
                        .allowsHitTesting(chromeVisible || showsInfo)
                        .accessibilityHidden(!chromeVisible && !showsInfo)
                }
                .simultaneousGesture(
                    verticalViewerGesture(
                        viewportSize: fullRect.size,
                        contentSize: viewerRect.size,
                        topInset: viewerRect.minY
                    )
                )
                .task(id: previewTargetPixels) {
                    viewerPreviewTargetPixels = previewTargetPixels
                    updateViewerPrefetch()
                }
            }
            .ignoresSafeArea(.container, edges: .all)
        }
        .foregroundStyle(.primary)
        .statusBarHidden(!chromeVisible && !showsInfo)
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .navigationTransition(.zoom(sourceID: route.selectedAsset.id, in: namespace))
        .task {
            await session.start()
            updateViewerPrefetch()
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
            zoomedAssetID = nil
            hideRenderedImageStatus()
            updateViewerPrefetch()
            if pagerPosition != newAssetID {
                pagerPosition = newAssetID
            }
            if !pagerWindowAssets.contains(where: { $0.id == newAssetID }) {
                pagerWindowCenterID = newAssetID
            }
            presentRenderedImageStatusIfNeeded(for: newAssetID)
        }
        .onAppear { visibilityChanged(true) }
        .onDisappear {
            neighborLoadTask?.cancel()
            pagerSelectionTask?.cancel()
            imageStatusDismissTask?.cancel()
            media.cancelViewerPrefetching()
            visibilityChanged(false)
        }
    }

    private func viewerContent(
        pageSize: CGSize,
        viewerRect: CGRect,
        requestSize: CGSize,
        isLandscape: Bool,
        infoProgress: CGFloat
    ) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(pagerWindowAssets) { asset in
                    viewerPage(
                        asset: asset,
                        pageSize: pageSize,
                        viewerRect: viewerRect,
                        requestSize: requestSize,
                        isLandscape: isLandscape,
                        infoProgress: infoProgress
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
        .scrollDisabled(zoomedAssetID == session.selectedAssetID)
        .onChange(of: pagerPosition) { _, assetID in
            schedulePagerSelectionSync(assetID)
        }
        .onScrollPhaseChange { _, phase in
            pagerPhase = phase
            if phase == .idle {
                schedulePagerSelectionSync(pagerPosition)
            } else {
                pagerSelectionTask?.cancel()
            }
        }
    }

    @ViewBuilder
    private func viewerPage(
        asset: TimelineAssetSummary,
        pageSize: CGSize,
        viewerRect: CGRect,
        requestSize: CGSize,
        isLandscape: Bool,
        infoProgress: CGFloat
    ) -> some View {
        if isLandscape {
            let targetInfoWidth = viewerRect.width / 2
            let infoWidth = targetInfoWidth * infoProgress
            let mediaRect = CGRect(
                x: viewerRect.minX,
                y: viewerRect.minY,
                width: viewerRect.width - infoWidth,
                height: viewerRect.height
            )
            ZStack {
                mediaPage(
                    asset: asset,
                    requestSize: requestSize,
                    mediaRect: mediaRect,
                    animatesFitChanges: !showsInfo && infoProgress == 0
                )
                .frame(width: pageSize.width, height: pageSize.height)

                ZStack(alignment: .leading) {
                    AssetViewerInfoView(
                        state: detailState(for: asset.id),
                        previewMetadata: previewMetadataByAssetID[asset.id],
                        anchorsContentToBottom: true,
                        contentHeightChanged: { updateInfoContentHeight($0, for: asset.id) },
                        retry: { retryDetail(for: asset.id) }
                    )
                    .frame(width: targetInfoWidth)
                }
                .frame(width: infoWidth, height: viewerRect.height, alignment: .leading)
                .clipped()
                .position(x: viewerRect.maxX - infoWidth / 2, y: viewerRect.midY)
                .accessibilityHidden(
                    infoProgress < 0.5 || asset.id != session.selectedAssetID
                )
            }
            .frame(width: pageSize.width, height: pageSize.height)
            .animation(infoAnimation, value: showsInfo)
            .accessibilityIdentifier(infoProgress > 0.5 ? "asset-viewer-landscape-split" : "asset-viewer-landscape")
        } else {
            let maxInfoHeight = max(0, viewerRect.height - 220 - infoGap)
            let targetInfoHeight = min(maxInfoHeight, infoContentHeight)
            let infoHeight = targetInfoHeight * infoProgress
            let gap = infoGap * infoProgress
            let mediaHeight = max(220, viewerRect.height - infoHeight - gap)
            let mediaRect = CGRect(
                x: viewerRect.minX,
                y: viewerRect.minY,
                width: viewerRect.width,
                height: mediaHeight
            )
            ZStack {
                mediaPage(
                    asset: asset,
                    requestSize: requestSize,
                    mediaRect: mediaRect,
                    animatesFitChanges: !showsInfo && infoProgress == 0
                )
                .frame(width: pageSize.width, height: pageSize.height)

                ZStack(alignment: .top) {
                    AssetViewerInfoView(
                        state: detailState(for: asset.id),
                        previewMetadata: previewMetadataByAssetID[asset.id],
                        anchorsContentToBottom: false,
                        contentHeightChanged: { updateInfoContentHeight($0, for: asset.id) },
                        retry: { retryDetail(for: asset.id) }
                    )
                    .frame(height: targetInfoHeight)
                }
                .frame(width: viewerRect.width, height: infoHeight, alignment: .top)
                .clipped()
                .position(
                    x: viewerRect.midX,
                    y: mediaRect.maxY + gap + infoHeight / 2
                )
                .accessibilityHidden(
                    infoProgress < 0.5 || asset.id != session.selectedAssetID
                )
            }
            .frame(width: pageSize.width, height: pageSize.height)
            .animation(infoAnimation, value: showsInfo)
            .animation(infoAnimation, value: infoContentHeight)
        }
    }

    private func mediaPage(
        asset: TimelineAssetSummary,
        requestSize: CGSize,
        mediaRect: CGRect,
        animatesFitChanges: Bool
    ) -> some View {
        ZStack {
            AssetViewerFitPage(
                asset: asset,
                media: media,
                isSelected: asset.id == session.selectedAssetID,
                dismissesInfo: showsInfo,
                mediaRect: mediaRect,
                pageSize: requestSize,
                animatesFitChanges: animatesFitChanges,
                targetPixels: .init(
                    width: Int(max(1, requestSize.width * displayScale)),
                    height: Int(max(1, requestSize.height * displayScale))
                ),
                previewMetadataChanged: { metadata in
                    previewMetadataByAssetID[asset.id] = metadata
                },
                renderedImageMetadataChanged: { metadata in
                    renderedImageMetadataByAssetID[asset.id] = metadata
                    presentRenderedImageStatusIfNeeded(for: asset.id)
                },
                resumePosition: { session.playbackPosition(for: asset.id) },
                savePosition: { session.setPlaybackPosition($0, for: asset.id) },
                zoomChanged: { isZoomed in
                    guard asset.id == session.selectedAssetID else { return }
                    zoomedAssetID = isZoomed ? asset.id : nil
                    guard isZoomed, chromeVisible, !showsInfo else { return }
                    hideRenderedImageStatus()
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                        chromeVisible = false
                    }
                },
                toggleChrome: mediaTapped
            )

            if asset.mediaKind != .video,
               asset.id == session.selectedAssetID,
               let metadata = renderedImageMetadataByAssetID[asset.id]
            {
                GeometryReader { geometry in
                    let statusPosition = renderedImageStatusPosition(
                        metadata: metadata,
                        containerSize: geometry.size
                    )
                    let revealEdge = min(
                        renderedImageBottom(metadata: metadata, containerSize: geometry.size),
                        statusPosition.y - 18
                    )
                    ZStack {
                        if !chromeVisible,
                           !showsInfo,
                           visibleImageStatusAssetID == asset.id
                        {
                            renderedImageStatus(metadata)
                                .position(statusPosition)
                                .transition(.offset(y: -44))
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .mask {
                        Rectangle()
                            .frame(
                                width: geometry.size.width,
                                height: max(0, geometry.size.height - revealEdge)
                            )
                            .position(
                                x: geometry.size.width / 2,
                                y: revealEdge + (geometry.size.height - revealEdge) / 2
                            )
                    }
                }
                .allowsHitTesting(false)
            }
        }
    }

    private func renderedImageStatus(_ metadata: AssetViewerRenderedImageMetadata) -> some View {
        Label(metadata.displayText, systemImage: metadata.source.systemImage)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .glassEffect(.regular, in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(metadata.displayText)
            .accessibilityIdentifier("asset-viewer-image-quality")
    }

    private func renderedImageStatusPosition(
        metadata: AssetViewerRenderedImageMetadata,
        containerSize: CGSize
    ) -> CGPoint {
        let imageBottom = renderedImageBottom(metadata: metadata, containerSize: containerSize)
        return CGPoint(
            x: containerSize.width / 2,
            y: min(imageBottom + 24, containerSize.height - 52)
        )
    }

    private func renderedImageBottom(
        metadata: AssetViewerRenderedImageMetadata,
        containerSize: CGSize
    ) -> CGFloat {
        let imageWidth = CGFloat(metadata.pixelSize.width)
        let imageHeight = CGFloat(metadata.pixelSize.height)
        let scale = min(
            containerSize.width / max(1, imageWidth),
            containerSize.height / max(1, imageHeight)
        )
        let fittedHeight = imageHeight * scale
        return (containerSize.height + fittedHeight) / 2
    }

    private func chrome(infoProgress: CGFloat) -> some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ZStack {
                    HStack {
                        glassCircleButton(
                            systemImage: "chevron.backward",
                            label: "Back",
                            identifier: "asset-viewer-back",
                            action: beginDismissal
                        )

                        Spacer()
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
                AssetViewerFilmstrip(
                    assets: session.assets,
                    selectedAssetID: session.selectedAssetID,
                    media: media,
                    select: { assetID in
                        pagerPosition = assetID
                    }
                )
                .opacity(1 - infoProgress)
                .allowsHitTesting(infoProgress < 0.5)
                .accessibilityHidden(infoProgress >= 0.5)

                bottomActions
                    .padding(.horizontal, 16)
            }
        }
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
        contentSize: CGSize,
        topInset: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard !reduceMotion,
                      zoomedAssetID == nil,
                      abs(value.translation.height) > abs(value.translation.width) * 1.2
                else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    infoDragTranslation = showsInfo
                        ? max(0, value.translation.height)
                        : min(0, value.translation.height)
                }
            }
            .onEnded { value in
                guard zoomedAssetID == nil else {
                    settleInfoGesture(visible: showsInfo)
                    return
                }
                let isVertical = abs(value.translation.height) > abs(value.translation.width) * 1.2
                let crossesThreshold = abs(value.translation.height) >= 36
                guard isVertical, crossesThreshold else {
                    settleInfoGesture(visible: showsInfo)
                    return
                }

                if value.translation.height < 0 {
                    settleInfoGesture(visible: true)
                } else if !showsInfo || isOutsideViewerContent(
                    value.startLocation,
                    viewportSize: viewportSize,
                    contentSize: contentSize,
                    topInset: topInset
                ) {
                    infoDragTranslation = 0
                    beginDismissal()
                } else {
                    settleInfoGesture(visible: false)
                }
            }
    }

    private func beginDismissal() {
        guard !isDismissing else { return }
        isDismissing = true
        visibilityChanged(false)
        Task { @MainActor in
            await Task.yield()
            close()
        }
    }

    private func isOutsideViewerContent(
        _ location: CGPoint,
        viewportSize _: CGSize,
        contentSize: CGSize,
        topInset: CGFloat
    ) -> Bool {
        location.y < topInset || location.y > topInset + contentSize.height
    }

    private var infoPresentationProgress: CGFloat {
        guard !reduceMotion else { return showsInfo ? 1 : 0 }
        let revealDistance: CGFloat = 160
        let progress = showsInfo
            ? 1 - max(0, infoDragTranslation) / revealDistance
            : max(0, -infoDragTranslation) / revealDistance
        return min(1, max(0, progress))
    }

    private func interpolated(from start: CGFloat, to end: CGFloat, progress: CGFloat) -> CGFloat {
        start + (end - start) * progress
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
        guard assetID == session.selectedAssetID else { return }
        let measuredHeight = ceil(height)
        guard measuredHeight > 0, abs(measuredHeight - infoContentHeight) >= 1 else { return }
        infoContentHeight = measuredHeight
    }

    private func toggleChrome() {
        guard !showsInfo else { return }
        let revealsStatus = chromeVisible
        withAnimation(mediaFrameAnimation) {
            chromeVisible.toggle()
        }
        if revealsStatus {
            presentRenderedImageStatusIfNeeded(for: session.selectedAssetID)
        } else {
            hideRenderedImageStatus()
        }
    }

    private func mediaTapped() {
        if showsInfo {
            setInfoVisible(false)
        } else {
            toggleChrome()
        }
    }

    private func setInfoVisible(_ visible: Bool) {
        guard visible != showsInfo else { return }
        hideRenderedImageStatus()
        withAnimation(infoAnimation) {
            chromeVisible = true
            infoDragTranslation = 0
            showsInfo = visible
        }
    }

    private func settleInfoGesture(visible: Bool) {
        if visible {
            chromeVisible = true
        }
        withAnimation(infoAnimation) {
            infoDragTranslation = 0
            showsInfo = visible
        }
    }

    private var infoAnimation: Animation? {
        reduceMotion ? nil : .spring(duration: 0.38, bounce: 0.08)
    }

    private var mediaFrameAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.28)
    }

    private var renderedImageStatusEntranceAnimation: Animation? {
        reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.06)
    }

    private var renderedImageStatusExitAnimation: Animation? {
        reduceMotion ? nil : .easeIn(duration: 0.22)
    }

    private func presentRenderedImageStatusIfNeeded(for assetID: String) {
        guard !chromeVisible,
              !showsInfo,
              session.selectedAssetID == assetID,
              session.selectedAsset?.mediaKind != .video,
              renderedImageMetadataByAssetID[assetID] != nil,
              !presentedImageStatusAssetIDs.contains(assetID)
        else { return }

        imageStatusDismissTask?.cancel()
        presentedImageStatusAssetIDs.insert(assetID)
        withAnimation(renderedImageStatusEntranceAnimation) {
            visibleImageStatusAssetID = assetID
        }
        imageStatusDismissTask = Task { @MainActor in
            if !reduceMotion {
                try? await Task.sleep(for: .milliseconds(280))
            }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, visibleImageStatusAssetID == assetID else { return }
            withAnimation(renderedImageStatusExitAnimation) {
                visibleImageStatusAssetID = nil
            }
        }
    }

    private func hideRenderedImageStatus() {
        imageStatusDismissTask?.cancel()
        imageStatusDismissTask = nil
        guard visibleImageStatusAssetID != nil else { return }
        withAnimation(renderedImageStatusExitAnimation) {
            visibleImageStatusAssetID = nil
        }
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

private struct AssetDetailLoadRequest: Hashable {
    let assetID: String
    let includesNeighbors: Bool
}

private struct AssetDetailCacheWindowRequest: Hashable {
    let assetIDs: [String]
}

private struct AssetViewerFitPage: View {
    let asset: TimelineAssetSummary
    let media: MediaLibraryController
    let isSelected: Bool
    let dismissesInfo: Bool
    let mediaRect: CGRect
    let pageSize: CGSize
    let animatesFitChanges: Bool
    let targetPixels: MediaPixelSize
    let previewMetadataChanged: (AssetViewerPreviewMetadata) -> Void
    let renderedImageMetadataChanged: (AssetViewerRenderedImageMetadata) -> Void
    let resumePosition: () -> Double
    let savePosition: (Double) -> Void
    let zoomChanged: (Bool) -> Void
    let toggleChrome: () -> Void

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            if asset.mediaKind == .video {
                NativeVideoPlayerView(
                    asset: asset,
                    media: media,
                    targetPixels: targetPixels,
                    isSelected: isSelected,
                    resumePosition: resumePosition,
                    savePosition: savePosition
                )
                .frame(width: mediaRect.width, height: mediaRect.height)
                .position(x: mediaRect.midX, y: mediaRect.midY)
            } else {
                ZoomableStillImageView(
                    asset: asset,
                    media: media,
                    targetPixels: targetPixels,
                    fitRect: mediaRect,
                    animatesFitChanges: animatesFitChanges,
                    reportsPreviewMetadata: isSelected && dismissesInfo,
                    reportsRenderedImageMetadata: isSelected,
                    previewMetadataChanged: previewMetadataChanged,
                    renderedImageMetadataChanged: renderedImageMetadataChanged,
                    zoomChanged: zoomChanged,
                    toggleChrome: toggleChrome
                )
                .frame(width: pageSize.width, height: pageSize.height)
            }
            if dismissesInfo {
                Color.clear
                    .contentShape(.rect)
                    .frame(width: mediaRect.width, height: mediaRect.height)
                    .position(x: mediaRect.midX, y: mediaRect.midY)
                    .onTapGesture(perform: toggleChrome)
                    .accessibilityHidden(true)
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
