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
    @State private var detailState = AssetViewerDetailState.idle

    private let controlHitSize: CGFloat = 44
    private let controlVisualSize: CGFloat = 44

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
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                viewerContent(size: geometry.size)
                chrome
                    .opacity(chromeVisible ? 1 : 0)
                    .allowsHitTesting(chromeVisible)
                    .accessibilityHidden(!chromeVisible)
                    .animation(.easeInOut(duration: 0.2), value: chromeVisible)
            }
            .simultaneousGesture(infoRevealGesture)
        }
        .foregroundStyle(.white)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .navigationBarBackButtonHidden(true)
        .navigationTransition(.zoom(sourceID: route.selectedAsset.id, in: namespace))
        .task {
            await session.start()
            updateViewerPrefetch()
        }
        .task(id: showsInfo ? session.selectedAssetID : nil) {
            guard showsInfo else { return }
            await loadSelectedAssetDetail()
        }
        .onChange(of: session.selectedAssetID) { _, _ in
            zoomedAssetID = nil
            chromeVisible = true
            detailState = .idle
            updateViewerPrefetch()
        }
        .onAppear { visibilityChanged(true) }
        .onDisappear {
            media.cancelViewerPrefetching()
            visibilityChanged(false)
        }
    }

    @ViewBuilder
    private func viewerContent(size: CGSize) -> some View {
        let isLandscape = size.width > size.height
        if isLandscape {
            let mediaWidth = showsInfo ? size.width / 2 : size.width
            HStack(spacing: 0) {
                pages(size: .init(width: mediaWidth, height: size.height))
                    .frame(width: mediaWidth)

                if showsInfo {
                    AssetViewerInfoView(
                        state: detailState,
                        bottomClearance: 76,
                        retry: retryDetail,
                        dismiss: { setInfoVisible(false) }
                    )
                    .frame(width: size.width / 2)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(infoAnimation, value: showsInfo)
            .accessibilityIdentifier(showsInfo ? "asset-viewer-landscape-split" : "asset-viewer-landscape")
        } else {
            let mediaHeight = showsInfo ? max(220, size.height * 0.43) : size.height
            VStack(spacing: 0) {
                pages(size: .init(width: size.width, height: mediaHeight))
                    .frame(height: mediaHeight)

                if showsInfo {
                    AssetViewerInfoView(
                        state: detailState,
                        bottomClearance: 76,
                        retry: retryDetail,
                        dismiss: { setInfoVisible(false) }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .animation(infoAnimation, value: showsInfo)
        }
    }

    private func pages(size: CGSize) -> some View {
        TabView(selection: Binding(
            get: { session.selectedAssetID },
            set: { assetID in
                Task { await session.select(assetID) }
            }
        )) {
            ForEach(session.assets) { asset in
                AssetViewerFitPage(
                    asset: asset,
                    media: media,
                    isSelected: asset.id == session.selectedAssetID,
                    dismissesInfo: showsInfo,
                    targetPixels: .init(
                        width: Int(max(1, size.width * displayScale)),
                        height: Int(max(1, size.height * displayScale))
                    ),
                    resumePosition: { session.playbackPosition(for: asset.id) },
                    savePosition: { session.setPlaybackPosition($0, for: asset.id) },
                    zoomChanged: { isZoomed in
                        zoomedAssetID = isZoomed ? asset.id : nil
                    },
                    toggleChrome: mediaTapped
                )
                .tag(asset.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .scrollDisabled(zoomedAssetID == session.selectedAssetID)
    }

    private var chrome: some View {
        VStack(spacing: 0) {
            HStack {
                glassCircleButton(
                    systemImage: "chevron.backward",
                    label: "Back",
                    identifier: "asset-viewer-back",
                    action: close
                )

                Spacer()

                if let selectedIndex = session.selectedIndex {
                    Text("\(selectedIndex + 1) of \(session.assets.count)")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .frame(height: controlVisualSize)
                        .glassEffect(.regular, in: Capsule())
                        .frame(height: controlHitSize)
                        .accessibilityIdentifier("asset-viewer-position")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer()

            VStack(spacing: 16) {
                if !showsInfo {
                    AssetViewerFilmstrip(
                        assets: session.assets,
                        selectedAssetID: session.selectedAssetID,
                        media: media,
                        select: { assetID in
                            Task { await session.select(assetID) }
                        }
                    )
                    .transition(.opacity)
                }

                bottomActions
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
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

                ZStack {
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
                }
                .background {
                    Color.clear
                        .frame(height: controlVisualSize)
                        .glassEffect(.regular, in: Capsule())
                }

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

    private var infoRevealGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                guard zoomedAssetID == nil,
                      abs(value.translation.height) > abs(value.translation.width) * 1.2,
                      abs(value.translation.height) >= 36
                else { return }
                setInfoVisible(value.translation.height < 0)
            }
    }

    private func updateViewerPrefetch() {
        guard let selectedIndex = session.selectedIndex else {
            media.cancelViewerPrefetching()
            return
        }
        let lower = max(0, selectedIndex - 1)
        let upper = min(session.assets.count, selectedIndex + 2)
        let descriptors = session.assets[lower ..< upper]
            .filter { $0.id != session.selectedAssetID }
            .map {
                MediaRequestDescriptor(
                    assetID: $0.id,
                    updatedAt: $0.thumbnailRevision,
                    derivative: .preview,
                    targetPixels: nil
                )
            }
        media.updateViewerPrefetch(descriptors)
    }

    private func toggleChrome() {
        guard !showsInfo else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
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
        chromeVisible = true
        withAnimation(infoAnimation) {
            showsInfo = visible
        }
    }

    private var infoAnimation: Animation? {
        reduceMotion ? nil : .spring(duration: 0.38, bounce: 0.08)
    }

    private func loadSelectedAssetDetail() async {
        let assetID = session.selectedAssetID
        detailState = .loading
        do {
            let detail = try await assetDetails.assetDetail(id: assetID)
            guard !Task.isCancelled, session.selectedAssetID == assetID, showsInfo else { return }
            detailState = .loaded(detail)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, session.selectedAssetID == assetID, showsInfo else { return }
            detailState = .failed(error.localizedDescription)
        }
    }

    private func retryDetail() {
        detailState = .idle
        Task { await loadSelectedAssetDetail() }
    }
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
            Color.black
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
                    isSelected: isSelected,
                    zoomChanged: zoomChanged,
                    toggleChrome: toggleChrome
                )
            }
            if dismissesInfo {
                Color.clear
                    .contentShape(.rect)
                    .onTapGesture(perform: toggleChrome)
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 12)
                            .onChanged { value in
                                guard value.translation.height >= 24,
                                      value.translation.height > abs(value.translation.width) * 1.2
                                else { return }
                                toggleChrome()
                            }
                    )
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
                                    .stroke(asset.id == selectedAssetID ? .white : .clear, lineWidth: 2)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(asset.capturedAt.formatted(date: .abbreviated, time: .shortened))
                        .accessibilityAddTraits(asset.id == selectedAssetID ? .isSelected : [])
                        .accessibilityIdentifier("asset-viewer-filmstrip-\(asset.id)")
                        .id(asset.id)
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .frame(height: 52)
            .background(.black.opacity(0.78))
            .onChange(of: selectedAssetID, initial: true) { _, selectedAssetID in
                withAnimation(.snappy(duration: 0.2)) {
                    proxy.scrollTo(selectedAssetID, anchor: .center)
                }
            }
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
