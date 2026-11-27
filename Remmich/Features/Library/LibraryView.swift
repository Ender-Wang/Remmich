import SwiftUI

struct LibraryView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @Environment(\.layoutDirection) private var layoutDirection

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
    @Binding var navigationPath: NavigationPath
    let navigationRoot: CardNavigationRoot
    let openLibraryCard: (LibraryHubDestination) -> Void
    var reconcileNavigationRoot: () -> Void = {}
    var sessionController: AppSessionController?
    var tabSelectionState: NativeTabSelectionState?
    var viewerPresentations: AssetViewerPresentationStore?
    var tabBarTop: Binding<CGFloat> = .constant(0)
    var viewerVisibilityChanged: (Bool) -> Void = { _ in }
    var opening = LibraryOpeningState()
    var hubReadyForRotation = true

    @State private var accountPresented = false
    @State private var accountContentMounted = false
    @State private var accountExpansion: CGFloat = 0
    @State private var accountContentHeight: CGFloat?
    @Namespace private var libraryCardTransition

    private var headerMetrics = MainTabHeaderMetrics()
    private let avatarSize = MainTabHeaderMetrics.controlSize
    private let avatarImageSize: CGFloat = 32
    private let horizontalPadding = MainTabHeaderMetrics.horizontalPadding
    private let accountPanelVerticalPadding: CGFloat = 8
    private let panelAvatarInset: CGFloat = 12

    private var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    var body: some View {
        let preferences = opening.preferences
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                LibraryHubScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        LibraryHubCardLayout(isPad: isPad) {
                            if let exports, !exports.jobs.isEmpty {
                                let newest = exports.latestCompletedDownload
                                LibraryHubLink {
                                    DownloadsView(exports: exports)
                                } label: {
                                    LibraryCollectionCard(title: "Save History",
                                                          count: exports.ready ? exports.jobs.count : nil,
                                                          symbol: "clock.arrow.circlepath",
                                                          appearance: newest == nil || media == nil ? .glass : .photographic)
                                    {
                                        if let newest, let media {
                                            let saved = exports.journal.receipts.first { $0.key == newest.key }
                                                .flatMap { savedPhotos.item(photosID: $0.photosID) }
                                            LibraryAssetCover(assetID: newest.assetID, revision: newest.revision, media: media, savedPhoto: saved,
                                                              preparedImage: opening.historyImage(for: newest, photo: saved, scale: displayScale))
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("library-download-history")
                            }
                            if showsOnDeviceCard {
                                onDeviceLink
                            }
                            if let collectionSource, let media, let assetDetails {
                                collectionCard(.recentlyTaken, source: collectionSource, media: media, assetDetails: assetDetails)
                                collectionCard(.recentlyAdded, source: collectionSource, media: media, assetDetails: assetDetails)
                                collectionCard(.favorites, source: collectionSource, media: media, assetDetails: assetDetails)
                                if preferences?.memoriesEnabled == true, opening.memories.hasContent {
                                    LibraryMemoriesCard(source: collectionSource, media: media, assetDetails: assetDetails,
                                                        context: collectionNavigation, catalog: opening.memories,
                                                        rotationEnabled: hubReadyForRotation && !accountContentMounted && navigationPath.isEmpty
                                                            && (tabSelectionState?.canActivateContent(in: .library) ?? true))
                                }
                                if preferences?.peopleEnabled == true, opening.people.hasContent {
                                    LibraryDirectoryCard(directory: .people, source: collectionSource, media: media,
                                                         assetDetails: assetDetails, context: collectionNavigation, store: opening.people)
                                }
                                if opening.places.hasContent || opening.placesCover.hasGeotags == true {
                                    LibraryDirectoryCard(directory: .places, source: collectionSource, media: media,
                                                         assetDetails: assetDetails, context: collectionNavigation, store: opening.places,
                                                         heatmap: opening.placesCover.image, placesMapSource: sessionController.map {
                                                             LibraryPlacesMapSource(store: $0.libraryIndexStore,
                                                                                    scope: MediaAccountScope(session: session), index: libraryIndex)
                                                         })
                                }
                                if preferences?.sharedLinksEnabled == true, opening.links.links?.isEmpty == false {
                                    LibrarySharedLinksCard(source: collectionSource, media: media, assetDetails: assetDetails,
                                                           context: collectionNavigation, store: opening.links)
                                }
                                if opening.partners.hasContent {
                                    LibraryDirectoryCard(directory: .partners, source: collectionSource, media: media,
                                                         assetDetails: assetDetails, context: collectionNavigation, store: opening.partners)
                                }
                                if preferences?.foldersEnabled == true, opening.folders.tree?.children(of: nil).isEmpty == false {
                                    LibraryFoldersCard(source: collectionSource, media: media, assetDetails: assetDetails,
                                                       context: collectionNavigation, store: opening.folders)
                                }
                                collectionCard(.archive, source: collectionSource, media: media, assetDetails: assetDetails)
                                collectionCard(.trash, source: collectionSource, media: media, assetDetails: assetDetails)
                            }
                            ForEach(visibleFixtureCollections) { collection in
                                LibraryHubLink {
                                    CollectionDetailView(collection: collection)
                                        .libraryPageHeader(collection.title)
                                } label: {
                                    LibraryCollectionCard(title: collection.title,
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
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, geometry.safeAreaInsets.top + headerMetrics.height + (isPad ? 12 : 0))
                    .padding(.bottom, geometry.safeAreaInsets.bottom + 16)
                    .frame(width: geometry.size.width)
                    .environment(\.libraryHubNavigation, LibraryHubNavigation(namespace: libraryCardTransition, open: openLibraryCard))
                    .environment(\.thumbnailRevealsActive, tabSelectionState?.canRevealThumbnails(in: .library) ?? true)
                }
                .ignoresSafeArea(.container, edges: [.top, .bottom])

                RemmichLogoView(
                    icon: AppIconController.shared.selectedIcon ?? .spiral,
                    isAnimating: navigationPath.isEmpty && (tabSelectionState?.selection ?? .library) == .library,
                    preservesAnimationPoseWhenPaused: true
                )
                .frame(width: headerLogoCanvasSize, height: headerLogoCanvasSize)
                .frame(width: avatarSize, height: avatarSize)
                .frame(height: headerMetrics.rowHeight)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Library")
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, horizontalPadding)
                .padding(.top, MainTabHeaderMetrics.topPadding)
                .padding(.bottom, MainTabHeaderMetrics.bottomPadding)
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
                        .ignoresSafeArea(.container)
                        .accessibilityHidden(true)
                }

                GlassEffectContainer(spacing: 40) {
                    accountGlassBackground(in: geometry)
                }
                .allowsHitTesting(false)
                .zIndex(1)

                if accountContentMounted {
                    accountPanelContent(in: geometry)
                        .zIndex(2)
                }
            }
            .overlayPreferenceValue(ProfileLandscapeAvatarSlot.self) { slot in
                GeometryReader { proxy in
                    accountButton(landscapeSlot: slot.map { proxy[$0] }, width: proxy.size.width)
                }
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
        .background {
            CardNavigationRootAnchor(root: navigationRoot, didAppear: reconcileNavigationRoot)
                .allowsHitTesting(false)
        }
        .navigationDestination(for: LibraryHubDestination.self) { card in
            card.makeView()
                .background {
                    LibraryCardNavigation(didDisappear: reconcileNavigationRoot)
                        .allowsHitTesting(false)
                }
                .nativeEdgeBack(canBegin: false, priority: 25) { _ in }
                .cardNavigationDestination(id: card.id, in: libraryCardTransition)
                .cardNavigationBack(path: $navigationPath)
        }
        .navigationDestination(for: LibraryNestedCardDestination.self) { destination in
            destination.makeView()
                .nativeEdgeBack(canBegin: false, priority: 25) { _ in }
                .cardNavigationBack(path: $navigationPath)
        }
        .navigationDestination(for: FixtureAsset.self) { asset in
            FixtureAssetDetailView(asset: asset)
                .toolbar(.visible, for: .navigationBar)
        }
        .onChange(of: dismissAccountRequest) {
            guard accountPresented || accountContentMounted else { return }
            setAccountPresented(false)
        }
    }

    private var showsOnDeviceCard: Bool {
        switch savedPhotos.state {
        case .missing: false
        case .loading, .ready: savedPhotos.limited || !savedPhotos.items.isEmpty
        default: true
        }
    }

    private var onDeviceLink: some View {
        LibraryHubLink {
            SavedPhotosView(library: savedPhotos, tabSelectionState: tabSelectionState, viewerPresentations: viewerPresentations,
                            tabBarTop: tabBarTop,
                            preparedTimelines: opening.downloadTimelines(library: savedPhotos, scope: MediaAccountScope(session: session)))
        } label: {
            onDeviceCard
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library-downloads")
    }

    private var onDeviceCard: some View {
        LibraryCollectionCard(title: "On Device", count: savedPhotos.state == .ready ? savedPhotos.items.count : nil,
                              symbol: "arrow.down.circle", appearance: savedPhotos.items.isEmpty ? .glass : .photographic)
        {
            if let photo = savedPhotos.items.first {
                SavedPhotoThumbnail(library: savedPhotos, item: photo)
            }
        }
    }

    private var visibleFixtureCollections: [FixtureCollection] {
        collectionSource == nil ? collections.filter { !$0.assets.isEmpty } : []
    }

    private var collectionNavigation: LibraryCollectionNavigation {
        .init(tabBarTop: tabBarTop, tabSelectionState: tabSelectionState, viewerPresentations: viewerPresentations,
              viewerVisibilityChanged: viewerVisibilityChanged)
    }

    @ViewBuilder private func collectionCard(_ collection: LibraryAssetCollection, source: ImmichTimelineRepository,
                                             media: MediaLibraryController, assetDetails: any AssetDetailReading) -> some View
    {
        if opening.previews[collection]?.isEmpty == false {
            LibraryHubLink {
                let camera = sessionController.map {
                    LibraryCameraMetadata(store: $0.libraryIndexStore, scope: MediaAccountScope(session: session), details: $0.persistentAssetDetails)
                }
                let prepared = opening.collection(collection, source: source, camera: camera)
                LibraryCollectionTimeline(title: collection.rawValue, source: source, query: collection.query,
                                          separatesMedia: collection.separatesMedia, media: media, assetDetails: assetDetails,
                                          tabSelectionState: tabSelectionState, viewerPresentations: viewerPresentations,
                                          tabBarTop: tabBarTop, opening: prepared, libraryIndex: collection == .recentlyTaken ? libraryIndex : nil)
            } label: {
                LibraryAssetCollectionCard(collection: collection, media: media, opening: opening)
            }
            .buttonStyle(.plain)
        }
    }

    private func accountButton(landscapeSlot: CGRect?, width: CGFloat) -> some View {
        let expandedTop = landscapeSlot?.minY ?? accountPanelVerticalPadding + panelAvatarInset
        let expandedTrailing = landscapeSlot.map {
            let slotTrailing = layoutDirection == .leftToRight ? width - $0.maxX : $0.minX
            return slotTrailing - (avatarSize - avatarImageSize) / 2
        } ?? horizontalPadding + panelAvatarInset

        return Button {
            setAccountPresented(!accountPresented)
        } label: {
            AccountAvatarView(size: avatarImageSize)
                .frame(width: avatarSize, height: avatarSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.top, interpolated(from: headerMetrics.controlTopPadding, to: expandedTop))
        .padding(.trailing, interpolated(from: horizontalPadding, to: expandedTrailing))
        .accessibilityLabel(accountPresented ? "Close Account Settings" : "Account")
        .accessibilityIdentifier(accountPresented ? "account-collapse-button" : "account-button")
        .accessibilityValue(accountPresented ? "Expanded" : "Collapsed")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    private func accountGlassBackground(in geometry: GeometryProxy) -> some View {
        let width = interpolated(from: avatarSize, to: panelWidth(in: geometry))
        let height = interpolated(from: avatarSize, to: panelHeight(in: geometry))
        let cornerRadius = interpolated(from: avatarSize / 2, to: 32)
        let animatedTopPadding = interpolated(from: headerMetrics.controlTopPadding, to: accountPanelVerticalPadding)

        return Color.clear
            .frame(width: width, height: height)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.regularMaterial)
                    .opacity(accountExpansion)
            }
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            .padding(.top, animatedTopPadding)
            .padding(.trailing, horizontalPadding)
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
            drawsGlassBackground: false,
            fitsHomeContent: isPad,
            preferredHeightChanged: { height in
                guard accountContentHeight != height else { return }
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
                    accountContentHeight = height
                }
            }
        )
        .frame(width: width, height: height)
        .contentShape(.rect(cornerRadius: 32))
        .modifier(AccountPanelReveal(
            progress: accountExpansion,
            collapsedSize: avatarSize,
            expandedWidth: width,
            expandedHeight: height,
            collapsedVerticalInset: headerMetrics.controlTopPadding - accountPanelVerticalPadding
        ))
        .padding(.top, accountPanelVerticalPadding)
        .padding(.trailing, horizontalPadding)
    }

    private func panelWidth(in geometry: GeometryProxy) -> CGFloat {
        let available = max(avatarSize, geometry.size.width - horizontalPadding * 2)
        if isPad {
            return min(available, 520)
        }
        return geometry.size.width > geometry.size.height && geometry.size.height < 440 ? available : min(available, 620)
    }

    private func panelHeight(in geometry: GeometryProxy) -> CGFloat {
        let available = max(avatarSize, geometry.size.height - accountPanelVerticalPadding * 2)
        return isPad ? min(available, accountContentHeight ?? 600) : available
    }

    private var headerLogoCanvasSize: CGFloat {
        avatarSize * DesignMetrics.brandLogoCanvasSize / DesignMetrics.brandLogoSlotSize
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

private struct AccountPanelReveal: AnimatableModifier {
    var progress: CGFloat
    let collapsedSize: CGFloat
    let expandedWidth: CGFloat
    let expandedHeight: CGFloat
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
        let remainingVerticalInset = collapsedVerticalInset * (1 - progress)

        content
            .opacity(contentOpacity)
            .mask(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .frame(width: width, height: height)
                    .offset(y: remainingVerticalInset)
            }
    }
}

private struct CollectionDetailView: View {
    let collection: FixtureCollection

    var body: some View {
        ScrollView {
            AssetGrid(assets: collection.assets)
        }
    }
}

#Preview {
    @Previewable @State var savedPhotos = SavedPhotosLibrary()
    @Previewable @State var navigationPath = NavigationPath()
    @Previewable @State var navigationRoot = CardNavigationRoot()
    NavigationStack(path: $navigationPath) {
        LibraryView(
            collections: PreviewFixtures.collections,
            savedPhotos: savedPhotos,
            session: .fixture,
            profile: .init(),
            activeRoute: .init(kind: .fallback, endpoint: URL(string: "https://immich.example/api")!),
            routeStatus: .connected,
            libraryIndex: LibraryIndexController(source: PreviewTimelineReader()),
            saveProfile: { _ in .saved(profile: .init()) },
            signOut: { _ in },
            dismissAccountRequest: .constant(0),
            accountPresentationChanged: { _ in },
            navigationPath: $navigationPath,
            navigationRoot: navigationRoot,
            openLibraryCard: { card in
                guard navigationPath.isEmpty else { return }
                withAnimation { navigationPath.append(card) }
            }
        )
    }
    .task {
        savedPhotos.configure(.init(scope: MediaAccountScope(session: .fixture), journal: nil))
        savedPhotos.startObserving()
        await savedPhotos.loadIfNeeded()
    }
    .onDisappear { savedPhotos.stopObserving() }
}
