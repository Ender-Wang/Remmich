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
                let viewerInsets = EdgeInsets(
                    top: viewerRect.minY,
                    leading: viewerRect.minX,
                    bottom: max(0, fullGeometry.size.height - viewerRect.maxY),
                    trailing: max(0, fullGeometry.size.width - viewerRect.maxX)
                )

                ZStack {
                    Color(uiColor: .systemBackground)
                    viewerContent(
                        contentSize: viewerRect.size,
                        contentInsets: viewerInsets,
                        requestSize: fullGeometry.size,
                        isLandscape: fullGeometry.size.width > fullGeometry.size.height,
                        infoProgress: infoProgress
                    )
                    chrome(infoProgress: infoProgress)
                        .frame(width: safeRect.width, height: safeRect.height)
                        .position(x: safeRect.midX, y: safeRect.midY)
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
        .onChange(of: session.selectedAssetID) { _, newAssetID in
            zoomedAssetID = nil
            updateViewerPrefetch()
            if pagerPosition != newAssetID {
                pagerPosition = newAssetID
            }
            if !pagerWindowAssets.contains(where: { $0.id == newAssetID }) {
                pagerWindowCenterID = newAssetID
            }
        }
        .onAppear { visibilityChanged(true) }
        .onDisappear {
            neighborLoadTask?.cancel()
            pagerSelectionTask?.cancel()
            media.cancelViewerPrefetching()
            visibilityChanged(false)
        }
    }

    private func viewerContent(
        contentSize: CGSize,
        contentInsets: EdgeInsets,
        requestSize: CGSize,
        isLandscape: Bool,
        infoProgress: CGFloat
    ) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(pagerWindowAssets) { asset in
                    viewerPage(
                        asset: asset,
                        size: contentSize,
                        requestSize: requestSize,
                        isLandscape: isLandscape,
                        infoProgress: infoProgress
                    )
                    .frame(width: contentSize.width, height: contentSize.height)
                    .clipped()
                    .padding(contentInsets)
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
        size: CGSize,
        requestSize: CGSize,
        isLandscape: Bool,
        infoProgress: CGFloat
    ) -> some View {
        if isLandscape {
            let targetInfoWidth = size.width / 2
            let infoWidth = targetInfoWidth * infoProgress
            let mediaWidth = size.width - infoWidth
            HStack(spacing: 0) {
                mediaPage(asset: asset, requestSize: requestSize)
                    .frame(width: mediaWidth, height: size.height)

                ZStack(alignment: .leading) {
                    AssetViewerInfoView(
                        state: detailState(for: asset.id),
                        anchorsContentToBottom: true,
                        contentHeightChanged: { updateInfoContentHeight($0, for: asset.id) },
                        retry: { retryDetail(for: asset.id) }
                    )
                    .frame(width: targetInfoWidth)
                }
                .frame(width: infoWidth, height: size.height, alignment: .leading)
                .clipped()
                .accessibilityHidden(
                    infoProgress < 0.5 || asset.id != session.selectedAssetID
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(infoAnimation, value: showsInfo)
            .accessibilityIdentifier(infoProgress > 0.5 ? "asset-viewer-landscape-split" : "asset-viewer-landscape")
        } else {
            let maxInfoHeight = max(0, size.height - 220 - infoGap)
            let targetInfoHeight = min(maxInfoHeight, infoContentHeight)
            let infoHeight = targetInfoHeight * infoProgress
            let gap = infoGap * infoProgress
            let mediaHeight = max(220, size.height - infoHeight - gap)
            VStack(spacing: gap) {
                mediaPage(asset: asset, requestSize: requestSize)
                    .frame(height: mediaHeight)

                ZStack(alignment: .top) {
                    AssetViewerInfoView(
                        state: detailState(for: asset.id),
                        anchorsContentToBottom: false,
                        contentHeightChanged: { updateInfoContentHeight($0, for: asset.id) },
                        retry: { retryDetail(for: asset.id) }
                    )
                    .frame(height: targetInfoHeight)
                }
                .frame(height: infoHeight, alignment: .top)
                .clipped()
                .accessibilityHidden(
                    infoProgress < 0.5 || asset.id != session.selectedAssetID
                )
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .animation(infoAnimation, value: showsInfo)
            .animation(infoAnimation, value: infoContentHeight)
        }
    }

    private func mediaPage(
        asset: TimelineAssetSummary,
        requestSize: CGSize
    ) -> some View {
        AssetViewerFitPage(
            asset: asset,
            media: media,
            isSelected: asset.id == session.selectedAssetID,
            dismissesInfo: showsInfo,
            targetPixels: .init(
                width: Int(max(1, requestSize.width * displayScale)),
                height: Int(max(1, requestSize.height * displayScale))
            ),
            resumePosition: { session.playbackPosition(for: asset.id) },
            savePosition: { session.setPlaybackPosition($0, for: asset.id) },
            zoomChanged: { isZoomed in
                guard asset.id == session.selectedAssetID else { return }
                zoomedAssetID = isZoomed ? asset.id : nil
            },
            toggleChrome: mediaTapped
        )
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

                        if let selectedIndex = session.selectedIndex {
                            Text("\(selectedIndex + 1)/\(session.assets.count)")
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .padding(.horizontal, 14)
                                .frame(height: controlVisualSize)
                                .glassEffect(.regular, in: Capsule())
                                .frame(height: controlHitSize)
                                .accessibilityLabel(
                                    "Asset \(selectedIndex + 1) of \(session.assets.count)"
                                )
                                .accessibilityIdentifier("asset-viewer-position")
                        }
                    }

                    if let selectedAsset = session.selectedAsset {
                        assetContextHeader(for: selectedAsset)
                            .frame(
                                maxWidth: min(240, max(120, geometry.size.width - 200))
                            )
                            .accessibilityIdentifier("asset-viewer-context")
                    }
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

    private func assetContextHeader(for asset: TimelineAssetSummary) -> some View {
        let location = selectedAssetLocation
        let capturedAt = selectedAssetDetail?.capturedAt ?? asset.capturedAt
        return VStack(spacing: 0) {
            if let location {
                Text(location)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Text(TimelineCaptureDateFormatting.string(
                from: capturedAt,
                dateStyle: .medium,
                timeStyle: .short
            ))
            .font(location == nil ? .subheadline.weight(.semibold) : .caption)
            .foregroundStyle(location == nil ? .primary : .secondary)
            .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(height: controlVisualSize)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private var selectedAssetDetail: AssetDetail? {
        guard case let .loaded(detail)? = detailStates[session.selectedAssetID] else {
            return nil
        }
        return detail
    }

    private var selectedAssetLocation: String? {
        let location = [
            selectedAssetDetail?.city,
            selectedAssetDetail?.state,
            selectedAssetDetail?.country,
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .first?
        .split(separator: ",", maxSplits: 1)
        .first?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        return location?.isEmpty == false ? location : nil
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
                  pagerPhase == .idle,
                  pagerPosition == assetID
            else { return }
            guard session.selectImmediately(assetID) else { return }
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
        withAnimation(mediaFrameAnimation) {
            chromeVisible.toggle()
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

    private func loadAssetDetail(_ assetID: String) async {
        if case .loaded? = detailStates[assetID] {
            return
        }
        detailStates[assetID] = .loading
        do {
            let detail = try await assetDetails.assetDetail(id: assetID)
            guard !Task.isCancelled else { return }
            detailStates[assetID] = .loaded(detail)
        } catch is CancellationError {
            if case .loading? = detailStates[assetID] {
                detailStates[assetID] = .idle
            }
            return
        } catch {
            guard !Task.isCancelled else {
                if case .loading? = detailStates[assetID] {
                    detailStates[assetID] = .idle
                }
                return
            }
            detailStates[assetID] = .failed(error.localizedDescription)
        }
    }

    private func detailState(for assetID: String) -> AssetViewerDetailState {
        detailStates[assetID] ?? .idle
    }

    private func retryDetail(for assetID: String) {
        guard assetID == session.selectedAssetID else { return }
        detailStates[assetID] = .idle
        Task { await loadAssetDetail(assetID) }
    }
}

private struct AssetDetailLoadRequest: Hashable {
    let assetID: String
    let includesNeighbors: Bool
}

private struct AssetViewerFitPage: View {
    let asset: TimelineAssetSummary
    let media: MediaLibraryController
    let isSelected: Bool
    let dismissesInfo: Bool
    let targetPixels: MediaPixelSize
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
            } else {
                ZoomableStillImageView(
                    asset: asset,
                    media: media,
                    targetPixels: targetPixels,
                    zoomChanged: zoomChanged,
                    toggleChrome: toggleChrome
                )
            }
            if dismissesInfo {
                Color.clear
                    .contentShape(.rect)
                    .onTapGesture(perform: toggleChrome)
                    .accessibilityHidden(true)
            }
        }
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
