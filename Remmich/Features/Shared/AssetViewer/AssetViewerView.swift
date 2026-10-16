import SwiftUI

struct AssetViewerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    let route: AssetViewerRoute
    let media: MediaLibraryController
    let namespace: Namespace.ID
    let visibilityChanged: (Bool) -> Void

    @State private var session: AssetViewerSession

    init(
        route: AssetViewerRoute,
        store: PhotosTimelineStore,
        media: MediaLibraryController,
        namespace: Namespace.ID,
        visibilityChanged: @escaping (Bool) -> Void
    ) {
        self.route = route
        self.media = media
        self.namespace = namespace
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
                pages(size: geometry.size)
                chrome
            }
        }
        .foregroundStyle(.white)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .navigationBarBackButtonHidden(true)
        .navigationTransition(.zoom(sourceID: route.selectedAsset.id, in: namespace))
        .ignoresSafeArea()
        .task { await session.start() }
        .onAppear { visibilityChanged(true) }
        .onDisappear { visibilityChanged(false) }
        .accessibilityIdentifier("asset-viewer")
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
                    targetPixels: .init(
                        width: Int(max(1, size.width * displayScale)),
                        height: Int(max(1, size.height * displayScale))
                    )
                )
                .tag(asset.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    private var chrome: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: dismiss.callAsFunction) {
                    Image(systemName: "chevron.backward")
                        .font(.headline.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background(.regularMaterial, in: Circle())
                }
                .accessibilityLabel("Back")
                .accessibilityIdentifier("asset-viewer-back")

                Spacer()

                if let selectedIndex = session.selectedIndex {
                    Text("\(selectedIndex + 1) of \(session.assets.count)")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .frame(height: 44)
                        .background(.regularMaterial, in: Capsule())
                        .accessibilityIdentifier("asset-viewer-position")
                }
            }
            .padding(.horizontal, 16)
            .safeAreaPadding(.top, 8)

            Spacer()

            AssetViewerFilmstrip(
                assets: session.assets,
                selectedAssetID: session.selectedAssetID,
                media: media,
                select: { assetID in
                    Task { await session.select(assetID) }
                }
            )
            .safeAreaPadding(.bottom, 12)
        }
    }
}

private struct AssetViewerFitPage: View {
    let asset: TimelineAssetSummary
    let media: MediaLibraryController
    let targetPixels: MediaPixelSize

    var body: some View {
        ZStack {
            Color.black
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if asset.mediaKind == .video {
                Label("Video playback is added in the next viewer step", systemImage: "play.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 72)
                    .frame(maxHeight: .infinity, alignment: .bottom)
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
