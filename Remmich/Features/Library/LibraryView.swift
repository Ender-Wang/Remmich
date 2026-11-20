import SwiftUI

struct LibraryView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    let collections: [FixtureCollection]
    var exports: MediaExportController?
    let savedPhotos: SavedPhotosLibrary
    var media: MediaLibraryController?
    var collectionSource: ImmichTimelineRepository?
    var assetDetails: (any AssetDetailReading)?
    let session: AccountSession
    let profile: ConnectionProfile
    let activeRoute: ActiveConnectionRoute?
    let routeStatus: ConnectionRouteStatus
    let libraryIndex: LibraryIndexController
    let saveProfile: (ConnectionProfileDraft) async -> ConnectionProfileSaveResult
    let signOut: (Bool) async -> Void
    @Binding var dismissAccountRequest: Int
    let accountPresentationChanged: (Bool) -> Void
    var sessionController: AppSessionController?
    var tabSelectionState: NativeTabSelectionState?
    var viewerPresentations: AssetViewerPresentationStore?
    var tabBarTop: Binding<CGFloat> = .constant(0)
    var viewerVisibilityChanged: (Bool) -> Void = { _ in }

    @State private var accountPresented = false
    @State private var accountContentMounted = false
    @State private var accountExpansion: CGFloat = 0
    @State private var photosObserver = UUID()
    @State private var foldersEnabled = false
    @State private var cardDestination: LibraryHubDestination?

    private let avatarSize: CGFloat = 44
    private let avatarImageSize: CGFloat = 32
    private let horizontalPadding: CGFloat = 16
    private let verticalPadding: CGFloat = 8
    private let panelHeaderHorizontalInset: CGFloat = 24
    private let panelHeaderVerticalInset: CGFloat = 12

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                LibraryHubScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        LibraryHubCardLayout {
                            if let exports {
                                LibraryHubLink {
                                    DownloadsView(exports: exports)
                                        .libraryNavigationChrome()
                                } label: {
                                    LibraryCollectionCard(title: "Downloads History",
                                                          detail: exports.activeCount > 0 ? "\(exports.activeCount) active" : "Save activity",
                                                          symbol: "clock.arrow.circlepath", appearance: .glass) { EmptyView() }
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("library-download-history")
                            }
                            LibraryHubLink {
                                SavedPhotosView(library: savedPhotos, scope: MediaAccountScope(session: session),
                                                tabSelectionState: tabSelectionState, viewerPresentations: viewerPresentations,
                                                tabBarTop: tabBarTop)
                            } label: {
                                LibraryCollectionCard(title: "Downloads", detail: savedPhotos.summary,
                                                      symbol: "arrow.down.circle", appearance: savedPhotos.items.isEmpty ? .glass : .photographic)
                                {
                                    if let photo = savedPhotos.items.first {
                                        SavedPhotoThumbnail(library: savedPhotos, item: photo)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("library-downloads")
                            if let collectionSource, let media, let assetDetails {
                                collectionCard(.recentlyTaken, source: collectionSource, media: media, assetDetails: assetDetails)
                                collectionCard(.recentlyAdded, source: collectionSource, media: media, assetDetails: assetDetails)
                                collectionCard(.favorites, source: collectionSource, media: media, assetDetails: assetDetails)
                                LibraryMemoriesCard(source: collectionSource, media: media, assetDetails: assetDetails,
                                                    context: collectionNavigation)
                                LibraryDirectoryCard(directory: .people, source: collectionSource, media: media,
                                                     assetDetails: assetDetails, context: collectionNavigation)
                                LibraryDirectoryCard(directory: .places, source: collectionSource, media: media,
                                                     assetDetails: assetDetails, context: collectionNavigation)
                                LibrarySharedLinksCard(source: collectionSource, media: media, assetDetails: assetDetails,
                                                       context: collectionNavigation)
                                LibraryDirectoryCard(directory: .partners, source: collectionSource, media: media,
                                                     assetDetails: assetDetails, context: collectionNavigation)
                                if foldersEnabled {
                                    LibraryFoldersCard(source: collectionSource, media: media, assetDetails: assetDetails,
                                                       context: collectionNavigation)
                                }
                                collectionCard(.archive, source: collectionSource, media: media, assetDetails: assetDetails)
                                collectionCard(.trash, source: collectionSource, media: media, assetDetails: assetDetails)
                            }
                            ForEach(visibleFixtureCollections) { collection in
                                LibraryHubLink {
                                    CollectionDetailView(collection: collection)
                                        .libraryNavigationChrome()
                                } label: {
                                    LibraryCollectionCard(title: collection.title, detail: collection.subtitle,
                                                          symbol: collection.kind.systemImage, appearance: .photographic)
                                    {
                                        FixtureArtwork(palette: collection.palette)
                                    }
                                    .accessibilityIdentifier("collection-\(collection.id)")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, geometry.safeAreaInsets.top + avatarTopPadding + avatarSize + 8)
                    .padding(.bottom, geometry.safeAreaInsets.bottom + 16)
                    .frame(width: geometry.size.width)
                    .environment(\.libraryHubDestination, $cardDestination)
                }
                .ignoresSafeArea(.container, edges: [.top, .bottom])

                HStack {
                    Text("Library").font(.largeTitle.bold())
                    Spacer(minLength: avatarSize + 16)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, horizontalPadding)
                .padding(.top, avatarTopPadding)
                .padding(.bottom, 8)
                .background {
                    LibraryTitleBackdrop()
                        .ignoresSafeArea(.container, edges: [.top, .horizontal])
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)

                if accountContentMounted {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { setAccountPresented(false) }
                }

                GlassEffectContainer(spacing: 40) {
                    accountGlassBackground(in: geometry)
                }
                .allowsHitTesting(false)
                .zIndex(1)

                if accountContentMounted {
                    accountPanelContent(in: geometry)
                        .contentShape(Rectangle())
                        .zIndex(2)
                }

                accountButton
                    .zIndex(3)
            }
        }
        .nativeEdgeBack(active: accountContentMounted, canBegin: accountPresented && accountExpansion == 1, priority: 200) { event in
            switch event.phase {
            case .began: break
            case .changed:
                guard !reduceMotion else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { accountExpansion = 1 - event.progress }
            case .ended:
                if event.completed {
                    setAccountPresented(false)
                } else {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) { accountExpansion = 1 }
                }
            }
        }
        .navigationTitle("Library")
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $cardDestination) { destination in
            destination.view
        }
        .navigationDestination(for: FixtureAsset.self) { asset in
            FixtureAssetDetailView(asset: asset)
        }
        .onChange(of: dismissAccountRequest) {
            guard accountPresented || accountContentMounted else { return }
            setAccountPresented(false)
        }
        .task(id: photosContext) {
            savedPhotos.configure(photosContext)
            await savedPhotos.refresh(reuseInFlight: true)
        }
        .task(id: folderPreferenceEndpoint) {
            guard folderPreferenceEndpoint != nil, let collectionSource else { return }
            let enabled = await (try? collectionSource.libraryFoldersEnabled()) == true
            guard !Task.isCancelled else { return }
            foldersEnabled = enabled
        }
        .onAppear { savedPhotos.observe(owner: photosObserver) }
        .onDisappear { savedPhotos.stopObserving(owner: photosObserver) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await savedPhotos.refresh() }
            }
        }
    }

    private var photosContext: SavedPhotosContext {
        SavedPhotosContext(scope: MediaAccountScope(session: session), journal: exports?.journal)
    }

    private var folderPreferenceEndpoint: URL? {
        scenePhase == .active ? collectionNavigation.activeEndpoint : nil
    }

    private var visibleFixtureCollections: [FixtureCollection] {
        collectionSource == nil ? collections : []
    }

    private var collectionNavigation: LibraryCollectionNavigation {
        .init(activeEndpoint: tabSelectionState?.selection == .library ? activeRoute?.endpoint : nil,
              tabBarTop: tabBarTop, tabSelectionState: tabSelectionState, viewerPresentations: viewerPresentations,
              viewerVisibilityChanged: viewerVisibilityChanged)
    }

    private func collectionCard(_ collection: LibraryAssetCollection, source: ImmichTimelineRepository,
                                media: MediaLibraryController, assetDetails: any AssetDetailReading) -> some View
    {
        LibraryHubLink {
            LibraryCollectionTimeline(title: collection.rawValue, source: source, query: collection.query,
                                      separatesMedia: collection.separatesMedia, media: media, assetDetails: assetDetails,
                                      tabSelectionState: tabSelectionState, viewerPresentations: viewerPresentations, tabBarTop: tabBarTop)
        } label: {
            LibraryAssetCollectionCard(collection: collection, source: source, media: media,
                                       activeEndpoint: activeRoute?.endpoint, isActive: tabSelectionState?.selection == .library)
        }
        .buttonStyle(.plain)
    }

    private var accountButton: some View {
        Button {
            setAccountPresented(!accountPresented)
        } label: {
            AccountAvatarView(size: avatarImageSize)
                .frame(width: avatarSize, height: avatarSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.top, avatarTopPadding)
        .padding(.trailing, avatarTrailingPadding)
        .accessibilityLabel(accountPresented ? "Close Account Settings" : "Account")
        .accessibilityIdentifier(accountPresented ? "account-collapse-button" : "account-button")
        .accessibilityValue(accountPresented ? "Expanded" : "Collapsed")
    }

    private func accountGlassBackground(in geometry: GeometryProxy) -> some View {
        let width = interpolated(from: avatarSize, to: panelWidth(in: geometry))
        let height = interpolated(from: avatarSize, to: panelHeight(in: geometry))
        let cornerRadius = interpolated(from: avatarSize / 2, to: 32)
        let animatedTopPadding = interpolated(from: avatarTopPadding, to: verticalPadding)
        let animatedTrailingPadding = interpolated(from: avatarTrailingPadding, to: horizontalPadding)

        return Color.clear
            .frame(width: width, height: height)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.regularMaterial)
                    .opacity(accountExpansion)
            }
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            .padding(.top, animatedTopPadding)
            .padding(.trailing, animatedTrailingPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    private func accountPanelContent(in geometry: GeometryProxy) -> some View {
        let width = panelWidth(in: geometry)
        let height = panelHeight(in: geometry)

        return AccountSettingsView(
            session: session,
            profile: profile,
            activeRoute: activeRoute,
            routeStatus: routeStatus,
            libraryIndex: libraryIndex,
            saveProfile: saveProfile,
            signOut: signOut,
            sessionController: sessionController,
            close: { setAccountPresented(false) },
            showsCloseControl: false,
            drawsGlassBackground: false
        )
        .frame(width: width, height: height)
        .modifier(AccountPanelReveal(
            progress: accountExpansion,
            collapsedSize: avatarSize,
            expandedWidth: width,
            expandedHeight: height,
            collapsedHorizontalInset: avatarControlHorizontalInset,
            collapsedVerticalInset: panelHeaderVerticalInset
        ))
        .padding(.top, verticalPadding)
        .padding(.trailing, horizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    private func panelWidth(in geometry: GeometryProxy) -> CGFloat {
        let available = max(avatarSize, geometry.size.width - horizontalPadding * 2)
        return geometry.size.width > geometry.size.height && geometry.size.height < 440 ? available : min(available, 620)
    }

    private func panelHeight(in geometry: GeometryProxy) -> CGFloat {
        max(avatarSize, geometry.size.height - verticalPadding * 2)
    }

    private var avatarTopPadding: CGFloat {
        verticalPadding + panelHeaderVerticalInset
    }

    private var avatarTrailingPadding: CGFloat {
        horizontalPadding + avatarControlHorizontalInset
    }

    private var avatarControlHorizontalInset: CGFloat {
        panelHeaderHorizontalInset - (avatarSize - avatarImageSize) / 2
    }

    private func interpolated(from start: CGFloat, to end: CGFloat) -> CGFloat {
        start + (end - start) * accountExpansion
    }

    private func setAccountPresented(_ presented: Bool) {
        accountPresentationChanged(presented)
        if reduceMotion {
            accountPresented = presented
            accountContentMounted = presented
            accountExpansion = presented ? 1 : 0
        } else if presented {
            accountContentMounted = true
            accountPresented = true
            withAnimation(.snappy(duration: 0.30, extraBounce: 0.14)) {
                accountExpansion = 1
            }
        } else {
            accountPresented = false
            withAnimation(.snappy(duration: 0.24, extraBounce: 0.08), completionCriteria: .logicallyComplete) {
                accountExpansion = 0
            } completion: {
                if !accountPresented {
                    accountContentMounted = false
                }
            }
        }
    }
}

struct LibraryTitleBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineMemoryGradientBackdrop(visible: true, extended: true, reduceMotion: reduceMotion)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension View {
    func libraryNavigationChrome() -> some View {
        navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .overlay(alignment: .top) {
                GeometryReader { safe in
                    let safeTop = safe.frame(in: .global).minY
                    GeometryReader { full in
                        let topInset = max(0, safeTop - full.frame(in: .global).minY)
                        LibraryTitleBackdrop()
                            .frame(height: topInset + 32)
                    }
                    .ignoresSafeArea(.container, edges: [.top, .horizontal])
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }
}

private struct AccountPanelReveal: AnimatableModifier {
    var progress: CGFloat
    let collapsedSize: CGFloat
    let expandedWidth: CGFloat
    let expandedHeight: CGFloat
    let collapsedHorizontalInset: CGFloat
    let collapsedVerticalInset: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let width = collapsedSize + (expandedWidth - collapsedSize) * progress
        let height = collapsedSize + (expandedHeight - collapsedSize) * progress
        let cornerRadius = collapsedSize / 2 + (32 - collapsedSize / 2) * progress
        let contentOpacity = min(max((progress - 0.12) / 0.5, 0), 1)
        let remainingHorizontalInset = collapsedHorizontalInset * (1 - progress)
        let remainingVerticalInset = collapsedVerticalInset * (1 - progress)

        content
            .opacity(contentOpacity)
            .mask(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .frame(width: width, height: height)
                    .offset(x: -remainingHorizontalInset, y: remainingVerticalInset)
            }
    }
}

private struct CollectionDetailView: View {
    let collection: FixtureCollection

    var body: some View {
        ScrollView {
            AssetGrid(assets: collection.assets)
        }
        .navigationTitle(collection.title)
    }
}

#Preview {
    NavigationStack {
        LibraryView(
            collections: PreviewFixtures.collections,
            savedPhotos: SavedPhotosLibrary(),
            session: .fixture,
            profile: .init(),
            activeRoute: .init(kind: .fallback, endpoint: URL(string: "https://immich.example/api")!),
            routeStatus: .connected,
            libraryIndex: LibraryIndexController(source: PreviewTimelineReader()),
            saveProfile: { _ in .saved(profile: .init()) },
            signOut: { _ in },
            dismissAccountRequest: .constant(0),
            accountPresentationChanged: { _ in }
        )
    }
}
