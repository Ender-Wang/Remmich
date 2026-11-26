import Nuke
import NukeUI
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
private final class AlbumsOverviewState {
    var store: AlbumsStore?
    var windowTopInset: CGFloat?
    var hasRevealedOpeningContent = false
}

struct AppShellView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var exportScenePhase

    let session: AccountSession
    let profile: ConnectionProfile
    let activeRoute: ActiveConnectionRoute?
    let routeStatus: ConnectionRouteStatus
    let photos: PhotosTimelineStore
    let videos: PhotosTimelineStore
    let assetDetails: any AssetDetailReading
    let albumSource: any AlbumReading & TimelineReading
    let presentation: PhotosPresentationState
    let media: MediaLibraryController
    let libraryIndex: LibraryIndexController
    let saveProfile: (ConnectionProfileDraft) async -> ConnectionProfileSaveResult
    let signOut: (Bool) async -> Void
    var primaryContentLoadingChanged: ((Bool) -> Void)?
    var sessionController: AppSessionController?

    @State private var previewBrowsing = AccountBrowsingState()
    @State private var searchPath: [LibraryAssetCollection] = []
    @State private var timelineRotationState = TimelineRotationState()
    @State private var tabBarTop: CGFloat = 0
    @State private var compactPhotosTabs = false
    @State private var compactVideosTabs = false
    @State private var groupedMediaOwner: NativeTabDestination = .photos
    @State private var photosScrollRequest = 0
    @State private var videosScrollRequest = 0
    @State private var albumsScrollRequest = 0
    @State private var albumsOverview = AlbumsOverviewState()
    @State private var savedPhotos = SavedPhotosLibrary()
    @State private var libraryOpening = LibraryOpeningState()
    @State private var libraryDismissAccountRequest = 0
    @State private var libraryAccountPresented = false
    @State private var videoPresentation = PhotosPresentationState(
        store: UserDefaultsPresentationPreferencesStore(key: "video-presentation-preferences")
    )
    @State private var groupedScrollRequests: [NativeTabDestination: Int] = [:]
    @State private var photosRangeRequest: TimelineLibraryRangeRequest?
    @State private var videosRangeRequest: TimelineLibraryRangeRequest?
    @State private var rangeRequestGeneration = 0
    @State private var photosPath: [PhotosRangeRoute] = []
    @State private var videosPath: [PhotosRangeRoute] = []
    @State private var albumsPath = NavigationPath()
    @State private var albumAfterPathRecovery: AlbumSummary?
    @State private var libraryPath = NavigationPath()
    @State private var libraryNavigationRoot = CardNavigationRoot()
    @State private var libraryPushGeneration = 0
    @State private var libraryCardAfterPathRecovery: LibraryHubDestination?
    @State private var searchBlocksPageSwipe = false
    @State private var showsAccount = false
    @State private var legacyViewerPresented = false
    @State private var viewerPresentations = AssetViewerPresentationStore()
    @State private var photosContentLoading = true
    @State private var videosContentLoading = true

    private var browsing: AccountBrowsingState {
        sessionController?.browsing ?? previewBrowsing
    }

    private var tabSelectionState: NativeTabSelectionState {
        browsing.navigation
    }

    private var tabContentActivationState: NativeTabContentActivationState {
        browsing.activation
    }

    private var photosTimelineRuntime: TimelineSemanticRuntime {
        browsing.photos
    }

    private var videosTimelineRuntime: TimelineSemanticRuntime {
        browsing.videos
    }

    var body: some View {
        @Bindable var navigation = tabSelectionState
        // The native tab retains its hosting root across selections.
        let overviewState = albumsOverview
        let inventoryContext = downloadsInventoryContext
        let historyCoverID = inventoryContext == nil ? nil : media.exports.latestCompletedDownload?.id
        NativeAppTabShell(
            selection: $navigation.selection,
            tabBarTop: $tabBarTop,
            rotationState: timelineRotationState,
            contentActivationState: tabContentActivationState,
            preparedDestinations: tabContentActivationState.preparedDestinations,
            compactOwner: compactTabOwner,
            isViewerPresented: viewerPresented,
            pageSwipeEnabled: pageSwipeEnabled,
            albumSearchExpanded: { tabSelectionState.isAlbumSearchExpanded },
            pageInteractionChanged: { tabSelectionState.isPageInteractionActive = $0 },
            searchTapped: {
                searchPath.removeAll()
                tabSelectionState.searchFocusRequest = UUID()
            },
            photosScrollRequest: photosScrollRequest,
            videosScrollRequest: videosScrollRequest,
            albumsScrollRequest: albumsScrollRequest,
            groupedScrollRequests: groupedScrollRequests,
            groupedMediaOwner: groupedMediaOwner,
            timelineRangeRequestGeneration: rangeRequestGeneration,
            libraryContentRevision: .init(
                profile: profile,
                activeRoute: activeRoute,
                routeStatus: routeStatus
            ),
            photosRetapped: {
                photosScrollRequest &+= 1
                compactPhotosTabs = false
            },
            videosRetapped: {
                videosScrollRequest &+= 1
                compactVideosTabs = false
            },
            albumsRetapped: retapAlbums,
            libraryRetapped: retapLibrary,
            groupedTabRetapped: { destination in
                groupedScrollRequests[destination, default: 0] &+= 1
            },
            photos: AnyView(
                NativeTabContentGate(
                    destination: .photos,
                    title: "Photos",
                    activationState: tabContentActivationState
                ) {
                    NavigationStack {
                        PhotosView(
                            store: photos,
                            presentation: presentation,
                            media: media,
                            assetDetails: assetDetails,
                            navigationPath: $photosPath,
                            tabBarTop: $tabBarTop,
                            rotationState: timelineRotationState,
                            timelineRuntime: photosTimelineRuntime,
                            scrollToLatestRequest: photosScrollRequest,
                            requestedLibraryRange: photosRangeRequest,
                            requestedLibraryRangeHandled: { photosRangeRequest = nil },
                            compactChromeChanged: { compact in
                                compactPhotosTabs = compact
                                if compact, tabSelectionState.selection == .photos {
                                    groupedMediaOwner = .photos
                                }
                            },
                            viewerVisibilityChanged: setViewerPresented,
                            loadingVisibilityChanged: primaryContentLoadingChanged == nil ? nil : { photosContentLoading = $0 },
                            tabSelectionState: tabSelectionState,
                            tabDestination: .photos,
                            viewerPresentations: viewerPresentations,
                            showAccount: showAccount
                        )
                    }
                }
            ),
            videos: AnyView(
                NativeTabContentGate(
                    destination: .videos,
                    title: "Videos",
                    activationState: tabContentActivationState,
                    openingPlaceholder: AnyView(
                        TimelineOpeningSkeleton(layout: videoPresentation.preferences.assetLayout)
                    )
                ) {
                    NavigationStack {
                        PhotosView(
                            store: videos,
                            presentation: videoPresentation,
                            media: media,
                            assetDetails: assetDetails,
                            navigationPath: $videosPath,
                            tabBarTop: $tabBarTop,
                            rotationState: timelineRotationState,
                            timelineRuntime: videosTimelineRuntime,
                            scrollToLatestRequest: videosScrollRequest,
                            requestedLibraryRange: videosRangeRequest,
                            requestedLibraryRangeHandled: { videosRangeRequest = nil },
                            contentName: "Videos",
                            rootAccessibilityID: "videos-root",
                            compactChromeChanged: { compact in
                                compactVideosTabs = compact
                                if compact, tabSelectionState.selection == .videos {
                                    groupedMediaOwner = .videos
                                }
                            },
                            viewerVisibilityChanged: setViewerPresented,
                            loadingVisibilityChanged: primaryContentLoadingChanged == nil ? nil : { videosContentLoading = $0 },
                            tabSelectionState: tabSelectionState,
                            tabDestination: .videos,
                            viewerPresentations: viewerPresentations,
                            loadTimeline: {
                                if let sessionController {
                                    await sessionController.openVideosTimeline()
                                } else {
                                    await videos.load()
                                }
                            },
                            showAccount: showAccount
                        )
                    }
                }
            ),
            albums: AnyView(
                NativeTabContentGate(
                    destination: .albums,
                    title: "Albums",
                    activationState: tabContentActivationState,
                    openingPlaceholder: AnyView(AlbumsOpeningSkeleton())
                ) {
                    if let store = overviewState.store, let windowTopInset = overviewState.windowTopInset {
                        NavigationStack(path: $albumsPath) {
                            AlbumsView(store: store, source: albumSource, media: media, assetDetails: assetDetails,
                                       activeEndpoint: activeRoute?.endpoint,
                                       scrollToLatestRequest: albumsScrollRequest,
                                       browsing: browsing,
                                       persistence: sessionController?.libraryIndexStore, scope: MediaAccountScope(session: session),
                                       viewerPresentations: viewerPresentations,
                                       tabSelectionState: tabSelectionState, tabBarTop: $tabBarTop,
                                       navigationPath: $albumsPath,
                                       windowTopInset: windowTopInset,
                                       showsLoadingOverlay: primaryContentLoadingChanged == nil,
                                       openingContentReady: { overviewState.hasRevealedOpeningContent = true },
                                       openAlbum: openAlbum,
                                       showAccount: showAccount)
                        }
                    } else {
                        AlbumsOpeningSkeleton()
                    }
                }
            ),
            library: AnyView(
                NativeTabContentGate(
                    destination: .library,
                    title: "Library",
                    activationState: tabContentActivationState
                ) {
                    NavigationStack(path: $libraryPath) {
                        LibraryView(
                            collections: PreviewFixtures.collections,
                            exports: media.exports,
                            savedPhotos: savedPhotos,
                            media: media,
                            collectionSource: sessionController?.timeline,
                            assetDetails: assetDetails,
                            session: session,
                            profile: profile,
                            activeRoute: activeRoute,
                            routeStatus: routeStatus,
                            libraryIndex: libraryIndex,
                            saveProfile: saveProfile,
                            signOut: signOut,
                            dismissAccountRequest: $libraryDismissAccountRequest,
                            accountPresentationChanged: { libraryAccountPresented = $0 },
                            navigationPath: $libraryPath,
                            navigationRoot: libraryNavigationRoot,
                            openLibraryCard: openLibraryCard,
                            reconcileNavigationRoot: reconcileLibraryNavigationRoot,
                            sessionController: sessionController,
                            tabSelectionState: tabSelectionState,
                            viewerPresentations: viewerPresentations,
                            tabBarTop: $tabBarTop,
                            viewerVisibilityChanged: setViewerPresented,
                            opening: libraryOpening,
                            hubReadyForRotation: tabContentActivationState.isHydrated(.library)
                        )
                    }
                }
            ),
            years: AnyView(
                NativeTabContentGate(
                    destination: .years,
                    title: "Years",
                    activationState: tabContentActivationState
                ) {
                    PhotosGroupedTabView(
                        kind: .years,
                        isSelected: tabSelectionState.selection == .years,
                        scrollToLatestRequest: groupedScrollRequests[.years, default: 0],
                        tabBarTop: tabBarTop,
                        store: groupedMediaStore,
                        presentation: groupedMediaPresentation,
                        media: media,
                        assetDetails: assetDetails,
                        contentName: groupedMediaContentName,
                        rangePinched: pinchGroupedRange,
                        timelineRuntime: groupedTimelineRuntime,
                        returnToTimeline: returnGroupedTimelineToRoot,
                        viewerVisibilityChanged: setViewerPresented,
                        showAccount: showAccount
                    )
                    .id(groupedMediaOwner)
                }
            ),
            months: AnyView(
                NativeTabContentGate(
                    destination: .months,
                    title: "Months",
                    activationState: tabContentActivationState
                ) {
                    PhotosGroupedTabView(
                        kind: .months,
                        isSelected: tabSelectionState.selection == .months,
                        scrollToLatestRequest: groupedScrollRequests[.months, default: 0],
                        tabBarTop: tabBarTop,
                        store: groupedMediaStore,
                        presentation: groupedMediaPresentation,
                        media: media,
                        assetDetails: assetDetails,
                        contentName: groupedMediaContentName,
                        rangePinched: pinchGroupedRange,
                        timelineRuntime: groupedTimelineRuntime,
                        returnToTimeline: returnGroupedTimelineToRoot,
                        viewerVisibilityChanged: setViewerPresented,
                        showAccount: showAccount
                    )
                    .id(groupedMediaOwner)
                }
            ),
            weeks: AnyView(
                NativeTabContentGate(
                    destination: .weeks,
                    title: "Weeks",
                    activationState: tabContentActivationState
                ) {
                    PhotosGroupedTabView(
                        kind: .weeks,
                        isSelected: tabSelectionState.selection == .weeks,
                        scrollToLatestRequest: groupedScrollRequests[.weeks, default: 0],
                        tabBarTop: tabBarTop,
                        store: groupedMediaStore,
                        presentation: groupedMediaPresentation,
                        media: media,
                        assetDetails: assetDetails,
                        contentName: groupedMediaContentName,
                        rangePinched: pinchGroupedRange,
                        timelineRuntime: groupedTimelineRuntime,
                        returnToTimeline: returnGroupedTimelineToRoot,
                        viewerVisibilityChanged: setViewerPresented,
                        showAccount: showAccount
                    )
                    .id(groupedMediaOwner)
                }
            ),
            search: AnyView(
                NativeTabContentGate(
                    destination: .search,
                    title: "Search",
                    activationState: tabContentActivationState
                ) {
                    NavigationStack(path: $searchPath) {
                        if let sessionController, let store = sessionController.search {
                            SearchView(
                                sessionController: sessionController,
                                store: store,
                                media: media,
                                assetDetails: assetDetails,
                                viewerPresentations: viewerPresentations,
                                tabBarTop: $tabBarTop,
                                tabSelection: tabSelectionState,
                                libraryOpening: libraryOpening,
                                libraryCamera: libraryCameraMetadata,
                                editingChanged: { searchBlocksPageSwipe = $0 }
                            )
                        } else {
                            ContentUnavailableView("Search unavailable", systemImage: "magnifyingglass")
                        }
                    }
                }
            ),
            locations: sessionController?.locations
        )
        .nativeEdgeBackRoot()
        .ignoresSafeArea(.container, edges: .all)
        .background {
            TimelineWindowSafeAreaReader { inset in
                guard overviewState.windowTopInset != inset else { return }
                overviewState.windowTopInset = inset
            }
        }
        .environment(\.accountAvatarMedia, media)
        .onAppear { media.logShellPresented() }
        .onChange(of: media.scope, initial: true) { _, _ in media.exports.detailReader = assetDetails }
        .onChange(of: exportScenePhase, initial: true) { _, phase in
            media.exports.sceneActivityChanged(active: phase == .active)
            if phase == .active {
                Task { await media.exports.reconcile() }
            }
        }
        .onChange(of: isPrimaryContentLoading, initial: true) { _, loading in
            primaryContentLoadingChanged?(loading)
        }
        .overlay(alignment: .topLeading) {
            #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-ui-testing-range-library") {
                    Text(String(describing: tabBarTop))
                        .frame(width: 1, height: 1)
                        .opacity(0.01)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("timeline-test-tab-bar-top")
                }
            #endif
        }
        .overlay {
            if showsAccount {
                GeometryReader { geometry in
                    ZStack {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { showsAccount = false }
                        AccountSettingsView(
                            session: session,
                            profile: profile,
                            activeRoute: activeRoute,
                            routeStatus: routeStatus,
                            libraryIndex: libraryIndex,
                            saveProfile: saveProfile,
                            signOut: signOut,
                            sessionController: sessionController,
                            close: { showsAccount = false }
                        )
                        .nativeEdgeBackAction(active: true, priority: 200) { showsAccount = false }
                        .frame(
                            width: min(geometry.size.width - 32, 620),
                            height: UIDevice.current.userInterfaceIdiom == .pad
                                ? min(geometry.size.height - 40, 680)
                                : min(geometry.size.height * 0.8, 620)
                        )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .transition(reduceMotion ? .opacity : .move(edge: .bottom))
            }
        }
        .animation(.smooth(duration: 0.35), value: showsAccount)
        .accessibilityHidden(viewerPresentations.activeID != nil)
        .overlay {
            AssetViewerPresentationOverlay(presentations: viewerPresentations)
                .environment(\.assetViewerTimelineLocator, AssetViewerTimelineLocator(
                    canLocate: canLocateInPhotos, prepare: prepareViewerReturnToPhotos
                ))
        }
        .onChange(of: viewerPresented || !viewerPresentations.entries.isEmpty) { _, presented in
            libraryIndex.setTimelinePublicationDeferred(presented)
        }
        .task(id: sessionController?.search.map(ObjectIdentifier.init), priority: .utility) {
            await sessionController?.search?.preloadLanding()
        }
        .task(id: mayPreloadTimelineTabs) {
            guard let sessionController, mayPreloadTimelineTabs else { return }
            async let videoOpening: Void = prepareVideosOpening(using: sessionController)
            await prepareAlbumsOpening(in: overviewState, preloading: true)
            await videoOpening
        }
        .task(id: libraryCoverRequest) {
            guard libraryCoverRequest.isActive, let source = sessionController?.timeline, let window = openingWindow else { return }
            await libraryOpening.prepareCovers(source: source, media: media, viewport: .init(window: window), camera: libraryCameraMetadata)
            if !Task.isCancelled, libraryCoverRequest.endpoint != nil {
                libraryIndex.collections.start()
            }
        }
        .task(id: libraryPath.isEmpty && mayWarmLibraryCovers ? libraryIndex.collections.publicationRevision : nil) {
            guard libraryPath.isEmpty, libraryIndex.collections.publicationRevision > 0, mayWarmLibraryCovers,
                  let source = sessionController?.timeline, let window = openingWindow else { return }
            await libraryOpening.refreshIndexedCovers(revision: libraryIndex.collections.publicationRevision,
                                                      source: source, media: media, viewport: .init(window: window),
                                                      camera: libraryCameraMetadata)
        }
        .task(id: libraryIndex.collections.featureRevision) {
            guard libraryIndex.collections.featureRevision > 0, let source = sessionController?.timeline else { return }
            await libraryOpening.refreshIndexedPreferences(source: source)
        }
        .task(id: libraryCoverEndpoint == nil ? nil : libraryIndex.thumbnailWarmingLastUpdatedAt) {
            guard libraryCoverEndpoint != nil, libraryIndex.thumbnailWarmingLastUpdatedAt != nil,
                  let scale = openingWindow?.traitCollection.displayScale else { return }
            await libraryOpening.refreshIncompleteTakenCover(media: media, scale: scale)
        }
        .task(id: libraryPlacesCoverRequest) {
            guard let request = libraryPlacesCoverRequest, let sessionController, let scale = openingWindow?.traitCollection.displayScale else {
                libraryOpening.placesCover.stop()
                return
            }
            await libraryOpening.placesCover.prepare(store: sessionController.libraryIndexStore, scope: MediaAccountScope(session: session),
                                                     locations: sessionController.locations, dark: request.dark, scale: scale)
        }
        .task(id: libraryDestinationRequest) {
            guard libraryDestinationRequest.isActive else {
                libraryOpening.stopDestinationImages()
                return
            }
            guard let window = openingWindow else { return }
            let viewport = LibraryOpeningViewport(window: window)
            if let source = sessionController?.timeline {
                await libraryOpening.prepareDestinations(source: source, media: media, viewport: viewport, camera: libraryCameraMetadata)
            }
        }
        .onChange(of: libraryIndex.lastUpdatedAt) {
            guard libraryCoverEndpoint != nil else { return }
            libraryIndex.collections.start()
        }
        .onChange(of: mayWarmLibraryCovers, initial: true) { _, active in
            if active {
                savedPhotos.startObserving()
            } else {
                savedPhotos.stopObserving()
            }
        }
        .onDisappear { savedPhotos.stopObserving() }
        .task(id: inventoryContext) {
            guard let context = inventoryContext else { return }
            await prepareSavedPhotosInventory(context)
            if !Task.isCancelled, let item = savedPhotos.items.first, let scale = openingWindow?.traitCollection.displayScale {
                await savedPhotos.prepareCardCover(.init(item: item, pixels: LibraryCollectionCardMetrics.coverPixels(scale: scale)))
            }
        }
        .task(id: tabSelectionState.selection == .library ? inventoryContext : nil) {
            guard tabSelectionState.selection == .library, let context = inventoryContext, let window = openingWindow else { return }
            let viewport = LibraryOpeningViewport(window: window)
            libraryOpening.prepareHistoryRows(media: media, viewport: viewport)
            await prepareSavedPhotosInventory(context)
            guard !Task.isCancelled else { return }
            await libraryOpening.prepareDownloads(library: savedPhotos, scope: context.scope, viewport: viewport)
        }
        .task(id: historyCoverID) {
            guard let id = historyCoverID, let job = media.exports.latestCompletedDownload, job.id == id,
                  let context = inventoryContext, let scale = openingWindow?.traitCollection.displayScale else { return }
            await prepareSavedPhotosInventory(context)
            guard !Task.isCancelled else { return }
            await libraryOpening.prepareHistoryCover(job, savedPhotos: savedPhotos, media: media, scale: scale)
        }
        .task(id: tabSelectionState.selection) {
            guard tabSelectionState.selection == .albums else { return }
            await prepareAlbumsOpening(in: overviewState, preloading: false)
        }
        .task(id: albumsPath.count) {
            // The tab host retains its content. Observe the cleared path from the shell.
            guard albumsPath.isEmpty, let albumAfterPathRecovery else { return }
            await Task.yield()
            guard !Task.isCancelled, albumsPath.isEmpty, self.albumAfterPathRecovery == albumAfterPathRecovery else { return }
            self.albumAfterPathRecovery = nil
            guard tabSelectionState.canActivateContent(in: .albums) else { return }
            pushAlbum(albumAfterPathRecovery)
        }
        .task(id: libraryPath.count) {
            guard libraryPath.isEmpty else { return }
            libraryOpening.places.dismissSelectedPlace()
            guard let card = libraryCardAfterPathRecovery else { return }
            await Task.yield()
            guard !Task.isCancelled, libraryPath.isEmpty, libraryCardAfterPathRecovery == card else { return }
            libraryCardAfterPathRecovery = nil
            guard tabSelectionState.canActivateContent(in: .library) else { return }
            pushLibraryCard(card)
        }
        .onChange(of: tabSelectionState.selection) { previous, current in
            browsing.saveTab(current, groupedMediaOwner: groupedMediaOwner)
            if current != .search {
                tabSelectionState.searchFocusRequest = nil
            }
            if previous == .albums, current != .albums {
                albumAfterPathRecovery = nil
                media.cancelPrefetching()
            }
            if previous == .library, current != .library {
                libraryCardAfterPathRecovery = nil
            }
            if current == .library {
                reconcileLibraryNavigationRoot()
            }
            if current != .photos, current != .videos {
                media.resumeOpeningPhotosHydration()
            }
            guard current == .years || current == .months || current == .weeks else { return }
            if previous == .photos {
                photosTimelineRuntime.beginGrouping()
            } else if previous == .videos {
                videosTimelineRuntime.beginGrouping()
            }
        }
        .onDisappear {
            tabSelectionState.isPageInteractionActive = false
            viewerPresentations.removeAll()
        }
        .environment(\.assetLocations, sessionController?.locations)
    }

    private func retapAlbums() {
        albumAfterPathRecovery = nil
        if albumsPath.isEmpty {
            albumsScrollRequest &+= 1
        } else {
            withAnimation { albumsPath.removeLast() }
        }
    }

    private func retapLibrary() {
        libraryCardAfterPathRecovery = nil
        if libraryPath.isEmpty {
            libraryDismissAccountRequest &+= 1
        } else if !libraryOpening.places.dismissSelectedPlace() {
            withAnimation { libraryPath.removeLast() }
        }
    }

    private func openAlbum(_ album: AlbumSummary, listIsSettledRoot: Bool) {
        guard tabSelectionState.canActivateContent(in: .albums), albumAfterPathRecovery == nil else { return }
        if albumsPath.isEmpty {
            pushAlbum(album)
        } else if listIsSettledRoot {
            // An interrupted native zoom can leave the bound path ahead of the visible stack.
            albumAfterPathRecovery = album
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { albumsPath = NavigationPath() }
        }
    }

    private func pushAlbum(_ album: AlbumSummary) {
        withAnimation { albumsPath.append(album) }
    }

    private func openLibraryCard(_ card: LibraryHubDestination) {
        guard tabSelectionState.canActivateContent(in: .library), libraryCardAfterPathRecovery == nil else { return }
        if libraryPath.isEmpty {
            pushLibraryCard(card)
        } else if libraryNavigationRoot.isSettledRoot {
            libraryCardAfterPathRecovery = card
            clearLibraryNavigationPath()
        }
    }

    private func pushLibraryCard(_ card: LibraryHubDestination) {
        libraryOpening.places.dismissSelectedPlace()
        libraryPushGeneration &+= 1
        withAnimation { libraryPath.append(card) }
    }

    private func reconcileLibraryNavigationRoot() {
        guard !libraryPath.isEmpty, libraryCardAfterPathRecovery == nil else { return }
        let generation = libraryPushGeneration
        Task { @MainActor in
            if let transition = libraryNavigationRoot.transitionCoordinator,
               transition.animate(alongsideTransition: nil, completion: { _ in
                   Task { @MainActor in clearStaleLibraryPath(generation: generation) }
               })
            {
                return
            }
            clearStaleLibraryPath(generation: generation)
        }
    }

    private func clearStaleLibraryPath(generation: Int) {
        guard libraryPushGeneration == generation, tabSelectionState.selection == .library,
              !libraryPath.isEmpty, libraryCardAfterPathRecovery == nil, libraryNavigationRoot.isSettledRoot
        else { return }
        clearLibraryNavigationPath()
    }

    private func clearLibraryNavigationPath() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { libraryPath = NavigationPath() }
    }

    private func prepareVideosOpening(using sessionController: AppSessionController) async {
        await sessionController.prepareVideosOpening()
        guard !Task.isCancelled, !tabContentActivationState.isHydrated(.videos),
              videosTimelineRuntime.pendingBrowsingPosition == nil else { return }
        let limit = TimelineGridOrder.openingWindowLimit()
        let assets = videos.newestSemanticAssets(limit: limit)
        guard !assets.isEmpty else { return }
        let revision = videos.semanticContentRevision
        let window = openingWindow
        let viewport = window?.bounds.size ?? .zero
        let traits = window?.traitCollection
        let displayScale = traits?.displayScale ?? 1
        let isPhone = traits?.userInterfaceIdiom == .phone
        let dark = traits?.userInterfaceStyle == .dark
        let scale: TimelineSemanticScale = videoPresentation.preferences.assetLayout == .square ? .square : .natural
        let build = Task.detached(priority: .utility) {
            let catalog = TimelineSemanticCatalog(assets: assets)
            guard !Task.isCancelled else { return (catalog, [MediaRequestDescriptor]()) }
            let layout = TimelineSemanticProjection.complete(catalog: catalog, scale: scale, size: viewport, isPhone: isPhone, dark: dark)
            let requests = layout.items.reversed().filter { !$0.isHeader }.map { item in
                TimelineAssetThumbnail.thumbnailDescriptor(for: catalog.assets[item.nodeIndex],
                                                           points: max(item.frame.width, item.frame.height), scale: displayScale)
            }
            return (catalog, requests)
        }
        let (catalog, requests) = await withTaskCancellationHandler { await build.value } onCancel: { build.cancel() }
        guard !Task.isCancelled, media.scope == MediaAccountScope(session: session),
              !tabContentActivationState.isHydrated(.videos),
              revision == videos.semanticContentRevision || assets == videos.newestSemanticAssets(limit: limit) else { return }
        videosTimelineRuntime.preparedOpeningCatalog = catalog
        tabContentActivationState.prepare(.videos)
        await media.prefetchManagedThumbnails(requests)
    }

    private func prepareAlbumsOpening(in overviewState: AlbumsOverviewState, preloading: Bool) async {
        let overview = overviewState.store ?? AlbumsStore(reader: albumSource, persistence: sessionController?.libraryIndexStore,
                                                          scope: MediaAccountScope(session: session))
        if overviewState.store == nil {
            overviewState.store = overview
        }
        if preloading, !Task.isCancelled, !tabContentActivationState.isHydrated(.albums) {
            tabContentActivationState.prepare(.albums)
        }
        await overview.prepareOpening()
        guard !Task.isCancelled, preloading || tabSelectionState.selection == .albums,
              let window = openingWindow else { return }
        await overview.warmOpeningCovers(media: media, viewport: window.bounds.size, scale: window.traitCollection.displayScale)
    }

    private var openingWindow: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    }

    private struct LibraryDestinationRequest: Equatable {
        let isActive: Bool
        let endpoint: URL?
    }

    private struct LibraryPlacesCoverRequest: Equatable {
        let indexUpdatedAt: Date?
        let metadataUpdatedAt: Date?
        let endpoint: URL?
        let styles: AssetMapStyles?
        let dark: Bool
    }

    private var libraryPlacesCoverRequest: LibraryPlacesCoverRequest? {
        guard let sessionController, mayWarmLibraryCovers else { return nil }
        return .init(indexUpdatedAt: libraryIndex.lastUpdatedAt, metadataUpdatedAt: libraryIndex.thumbnailWarmingLastUpdatedAt,
                     endpoint: libraryReaderEndpoint, styles: sessionController.locations.mapStyles, dark: colorScheme == .dark)
    }

    private var libraryDestinationRequest: LibraryDestinationRequest {
        let active = exportScenePhase == .active && tabSelectionState.selection == .library
        return .init(isActive: active, endpoint: active ? libraryReaderEndpoint : nil)
    }

    private var libraryCoverRequest: LibraryDestinationRequest {
        let active = mayWarmLibraryCovers && (libraryReaderEndpoint != nil || sessionController?.foregroundResourcesReady == true)
        return .init(isActive: active, endpoint: active ? libraryReaderEndpoint : nil)
    }

    private var mayWarmLibraryCovers: Bool {
        exportScenePhase == .active && (media.hasShownStartupPhoto || photos.loadState == .empty || tabSelectionState.selection == .library)
    }

    private var libraryCameraMetadata: LibraryCameraMetadata? {
        sessionController.map { .init(store: $0.libraryIndexStore, scope: MediaAccountScope(session: session), details: $0.persistentAssetDetails) }
    }

    private var libraryCoverEndpoint: URL? {
        mayWarmLibraryCovers ? libraryReaderEndpoint : nil
    }

    private var libraryReaderEndpoint: URL? {
        // Route selection can be visible while the repository is still being configured.
        guard let selected = activeRoute?.endpoint, sessionController?.timelineEndpoint == selected else { return nil }
        return selected
    }

    private var downloadsInventoryContext: SavedPhotosContext? {
        guard mayWarmLibraryCovers, media.exports.ready || media.exports.message != nil else { return nil }
        return SavedPhotosContext(scope: MediaAccountScope(session: session), journal: media.exports.journal)
    }

    private func prepareSavedPhotosInventory(_ context: SavedPhotosContext) async {
        guard !Task.isCancelled else { return }
        savedPhotos.configure(context)
        await savedPhotos.loadIfNeeded(priority: .utility)
    }

    private func showAccount() {
        showsAccount = true
    }

    private func setViewerPresented(_ presented: Bool) {
        legacyViewerPresented = presented
    }

    private var viewerPresented: Bool {
        legacyViewerPresented || viewerPresentations.activeID != nil
    }

    private func canLocateInPhotos(_ asset: TimelineAssetSummary, origin: AssetViewerOrigin) -> Bool {
        guard media.savedPhotosLibrary == nil, asset.visibility == .timeline, !origin.isTrash,
              asset.mediaKind == .image || asset.mediaKind == .video,
              !photos.hiddenStackMemberIDs.contains(asset.id),
              asset.stack?.primaryAssetID.map({ $0 == asset.id }) ?? true
        else { return false }
        if case .timeline = origin {
            if tabSelectionState.selection == .photos, photosPath.isEmpty {
                return false
            }
            if tabSelectionState.selection == .videos, videosPath.isEmpty {
                return false
            }
        }
        return true
    }

    private func prepareViewerReturnToPhotos(
        _ asset: TimelineAssetSummary, willReveal: () -> Void
    ) async -> (() -> AssetViewerDismissalTarget?)? {
        guard let viewerID = viewerPresentations.activeID else { return nil }
        let scope = media.scope
        guard await photos.prepareViewerReturn(to: asset), !Task.isCancelled,
              media.scope == scope, viewerPresentations.activeID == viewerID
        else { return nil }

        let priorTab = tabSelectionState.selection
        let priorPath = photosPath
        let priorCompact = compactPhotosTabs
        willReveal()
        rangeRequestGeneration &+= 1
        photosRangeRequest = .init(range: .all, generation: rangeRequestGeneration)
        compactPhotosTabs = false
        tabSelectionState.selection = .photos

        // Wait for the root collection to install the prepared asset and its
        // cell geometry before handing the viewer's thumbnail ownership over.
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while clock.now < deadline, !Task.isCancelled,
              media.scope == scope, viewerPresentations.activeID == viewerID,
              tabSelectionState.selection == .photos
        {
            if photosRangeRequest == nil, photosPath.isEmpty, photosTimelineRuntime.revealForViewerReturn(asset) {
                viewerPresentations.moveReturnSource(for: viewerID, to: photosTimelineRuntime.viewerPresentationOwnerID)
                return { photosTimelineRuntime.dismissalTarget(assetID: asset.id, aspectRatio: asset.aspectRatio) }
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
        if media.scope == scope, viewerPresentations.activeID == viewerID,
           tabSelectionState.selection == .photos
        {
            photosRangeRequest = nil
            photosPath = priorPath
            compactPhotosTabs = priorCompact
            tabSelectionState.selection = priorTab
        }
        return nil
    }

    private func pinchGroupedRange(_ kind: PhotosGroupedTabKind, _ gesture: PhotosPinchGesture) {
        switch (kind, gesture.direction) {
        case (.years, .finer):
            tabSelectionState.selection = .months
        case (.months, .coarser):
            tabSelectionState.selection = .years
        case (.months, .finer):
            tabSelectionState.selection = .weeks
        case (.weeks, .coarser):
            tabSelectionState.selection = .months
        case (.weeks, .finer):
            rangeRequestGeneration &+= 1
            let request = TimelineLibraryRangeRequest(
                range: .day,
                generation: rangeRequestGeneration
            )
            if groupedMediaOwner == .videos {
                videosRangeRequest = request
                tabSelectionState.selection = .videos
            } else {
                photosRangeRequest = request
                tabSelectionState.selection = .photos
            }
        case (.years, .coarser):
            break
        }
    }

    private var groupedTimelineRuntime: TimelineSemanticRuntime {
        groupedMediaOwner == .videos ? videosTimelineRuntime : photosTimelineRuntime
    }

    private func returnGroupedTimelineToRoot() {
        groupedTimelineRuntime.prepareRootReturn()
        rangeRequestGeneration &+= 1
        let request = TimelineLibraryRangeRequest(range: .all, generation: rangeRequestGeneration)
        if groupedMediaOwner == .videos {
            videosRangeRequest = request
            tabSelectionState.selection = .videos
        } else {
            photosRangeRequest = request
            tabSelectionState.selection = .photos
        }
    }

    private var compactTabOwner: NativeTabDestination? {
        switch tabSelectionState.selection {
        case .photos: compactPhotosTabs ? .photos : nil
        case .videos: compactVideosTabs ? .videos : nil
        case .weeks, .months, .years: groupedMediaOwner
        default: nil
        }
    }

    private var pageSwipeEnabled: Bool {
        if tabSelectionState.selection == .search, searchBlocksPageSwipe {
            return false
        }
        let hasNavigationDestination: Bool = switch tabSelectionState.selection {
        case .photos: !photosPath.isEmpty
        case .videos: !videosPath.isEmpty
        case .albums: !albumsPath.isEmpty
        case .library: !libraryPath.isEmpty
        case .search: !searchPath.isEmpty
        case .weeks, .months, .years: false
        }
        return RootPageSwipePolicy.allowsPaging(
            viewerPresented: viewerPresented,
            hasNavigationDestination: hasNavigationDestination,
            librarySelected: tabSelectionState.selection == .library,
            libraryAccountPresented: libraryAccountPresented
        )
    }

    private var isPrimaryContentLoading: Bool {
        guard !viewerPresented, !showsAccount else { return false }
        switch tabSelectionState.selection {
        case .photos: return photosPath.isEmpty && photosContentLoading
        case .videos: return videosPath.isEmpty && videosContentLoading
        case .albums:
            return albumsPath.isEmpty && (!tabContentActivationState.isHydrated(.albums)
                || !albumsOverview.hasRevealedOpeningContent
                || (albumsOverview.store?.isWaitingForInitialContent ?? true))
        default: return false
        }
    }

    private var mayPreloadTimelineTabs: Bool {
        media.hasShownStartupPhoto || photos.loadState == .empty || tabSelectionState.selection != .photos
    }

    private var groupedMediaStore: PhotosTimelineStore {
        groupedMediaOwner == .videos ? videos : photos
    }

    private var groupedMediaPresentation: PhotosPresentationState {
        groupedMediaOwner == .videos ? videoPresentation : presentation
    }

    private var groupedMediaContentName: String {
        groupedMediaOwner == .videos ? "Videos" : "Photos"
    }
}

private struct NativeTabContentGate<Content: View>: View {
    let destination: NativeTabDestination
    let title: String
    let activationState: NativeTabContentActivationState
    var openingPlaceholder: AnyView?
    @ViewBuilder let content: () -> Content

    var body: some View {
        if activationState.isHydrated(destination) {
            content()
        } else {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()
                .overlay { openingPlaceholder }
                .accessibilityLabel("Loading \(title)")
        }
    }
}

struct AccountAvatarView: View {
    @Environment(\.accountAvatarMedia) private var media
    @Environment(\.displayScale) private var displayScale

    let size: CGFloat

    var body: some View {
        Group {
            if let media {
                LazyImage(request: media.profileImageRequest(targetPixels: Int(size * displayScale))) { state in
                    if let image = state.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "person.crop.circle")
                            .resizable()
                            .scaledToFit()
                    }
                }
                .pipeline(media.pipeline ?? .shared)
                .onDisappear(.cancel)
            } else {
                Image(systemName: "person.crop.circle")
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

struct AccountToolbarButton: ToolbarContent {
    let action: () -> Void
    var showsOnPhone = false

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        if showsOnPhone || UIDevice.current.userInterfaceIdiom == .pad {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: action) {
                    AccountAvatarView(size: 32)
                        .background(Circle().fill(.regularMaterial))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Account")
                .accessibilityIdentifier("account-button")
            }
        }
    }
}

extension EnvironmentValues {
    @Entry var accountAvatarMedia: MediaLibraryController? = nil
}

#Preview {
    let store = PhotosTimelineStore(reader: PreviewTimelineReader())
    AppShellView(
        session: .fixture,
        profile: .init(),
        activeRoute: nil,
        routeStatus: .waitingForNetwork,
        photos: store,
        videos: PhotosTimelineStore(reader: VideoTimelineReader(source: PreviewTimelineReader())),
        assetDetails: PreviewTimelineReader(),
        albumSource: PreviewAlbumReader(),
        presentation: .init(),
        media: .init(),
        libraryIndex: LibraryIndexController(source: PreviewTimelineReader()),
        saveProfile: { _ in .saved(profile: .init()) },
        signOut: { _ in }
    )
}
