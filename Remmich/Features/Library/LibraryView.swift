import SwiftUI

struct LibraryView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

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
    @Namespace private var libraryCardTransition

    private let avatarSize: CGFloat = 44
    private let avatarImageSize: CGFloat = 32
    private let horizontalPadding: CGFloat = 16
    private let verticalPadding: CGFloat = 8
    private let panelAvatarInset: CGFloat = 12

    var body: some View {
        let preferences = opening.preferences
        GeometryReader { geometry in
            let cardAreaWidth = geometry.size.width - horizontalPadding * 2
            let cardLayout = LibraryCardRows(availableWidth: cardAreaWidth)
            let collapsedAvatarTrailingPadding = horizontalPadding + max(0, cardAreaWidth - cardLayout.rowWidth)
            ZStack(alignment: .topTrailing) {
                LibraryHubScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        LibraryHubCardLayout {
                            if let exports, !exports.ready || !exports.jobs.isEmpty {
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
                                if preferences?.memoriesEnabled == true, !opening.memories.isConfirmedEmpty {
                                    LibraryMemoriesCard(source: collectionSource, media: media, assetDetails: assetDetails,
                                                        context: collectionNavigation, catalog: opening.memories,
                                                        rotationEnabled: hubReadyForRotation && !accountContentMounted && navigationPath.isEmpty
                                                            && (tabSelectionState?.canActivateContent(in: .library) ?? true))
                                }
                                if preferences?.peopleEnabled == true, !opening.people.isConfirmedEmpty {
                                    LibraryDirectoryCard(directory: .people, source: collectionSource, media: media,
                                                         assetDetails: assetDetails, context: collectionNavigation, store: opening.people)
                                }
                                if !opening.places.isConfirmedEmpty || opening.placesCover.hasGeotags != false {
                                    LibraryDirectoryCard(directory: .places, source: collectionSource, media: media,
                                                         assetDetails: assetDetails, context: collectionNavigation, store: opening.places,
                                                         heatmap: opening.placesCover.image, placesMapSource: sessionController.map {
                                                             LibraryPlacesMapSource(store: $0.libraryIndexStore,
                                                                                    scope: MediaAccountScope(session: session), index: libraryIndex)
                                                         })
                                }
                                if preferences?.sharedLinksEnabled == true, opening.links.links?.isEmpty != true {
                                    LibrarySharedLinksCard(source: collectionSource, media: media, assetDetails: assetDetails,
                                                           context: collectionNavigation, store: opening.links)
                                }
                                if !opening.partners.isConfirmedEmpty {
                                    LibraryDirectoryCard(directory: .partners, source: collectionSource, media: media,
                                                         assetDetails: assetDetails, context: collectionNavigation, store: opening.partners)
                                }
                                if preferences?.foldersEnabled == true, opening.folders.tree?.children(of: nil).isEmpty != true {
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
                    .padding(.top, geometry.safeAreaInsets.top + avatarTopPadding + avatarSize + 8)
                    .padding(.bottom, geometry.safeAreaInsets.bottom + 16)
                    .frame(width: geometry.size.width)
                    .environment(\.libraryHubNavigation, LibraryHubNavigation(namespace: libraryCardTransition, open: openLibraryCard))
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
                    accountGlassBackground(in: geometry, collapsedTrailingPadding: collapsedAvatarTrailingPadding)
                }
                .allowsHitTesting(false)
                .zIndex(1)

                if accountContentMounted {
                    accountPanelContent(in: geometry, collapsedTrailingPadding: collapsedAvatarTrailingPadding)
                        .contentShape(Rectangle())
                        .zIndex(2)
                }

                accountButton(trailingPadding: interpolated(from: collapsedAvatarTrailingPadding, to: expandedAvatarTrailingPadding))
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
        }
        .navigationDestination(for: LibraryNestedCardDestination.self) { destination in
            destination.makeView()
                .nativeEdgeBack(canBegin: false, priority: 25) { _ in }
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
        case .ready: savedPhotos.limited || !savedPhotos.items.isEmpty
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
        if opening.previews[collection]?.isEmpty != true {
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

    private func accountButton(trailingPadding: CGFloat) -> some View {
        Button {
            setAccountPresented(!accountPresented)
        } label: {
            AccountAvatarView(size: avatarImageSize)
                .frame(width: avatarSize, height: avatarSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.top, avatarTopPadding)
        .padding(.trailing, trailingPadding)
        .accessibilityLabel(accountPresented ? "Close Account Settings" : "Account")
        .accessibilityIdentifier(accountPresented ? "account-collapse-button" : "account-button")
        .accessibilityValue(accountPresented ? "Expanded" : "Collapsed")
    }

    private func accountGlassBackground(in geometry: GeometryProxy, collapsedTrailingPadding: CGFloat) -> some View {
        let width = interpolated(from: avatarSize, to: panelWidth(in: geometry))
        let height = interpolated(from: avatarSize, to: panelHeight(in: geometry))
        let cornerRadius = interpolated(from: avatarSize / 2, to: 32)
        let animatedTopPadding = interpolated(from: avatarTopPadding, to: verticalPadding)
        let animatedTrailingPadding = interpolated(from: collapsedTrailingPadding, to: horizontalPadding)

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

    private func accountPanelContent(in geometry: GeometryProxy, collapsedTrailingPadding: CGFloat) -> some View {
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
            collapsedHorizontalInset: collapsedTrailingPadding - horizontalPadding,
            collapsedVerticalInset: panelAvatarInset
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
        verticalPadding + panelAvatarInset
    }

    private var expandedAvatarTrailingPadding: CGFloat {
        horizontalPadding + panelAvatarInset
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
