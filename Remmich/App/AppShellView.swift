import Nuke
import NukeUI
import SwiftUI
import UIKit

struct AppShellView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let session: AccountSession
    let profile: ConnectionProfile
    let activeRoute: ActiveConnectionRoute?
    let routeStatus: ConnectionRouteStatus
    let photos: PhotosTimelineStore
    let videos: PhotosTimelineStore
    let assetDetails: any AssetDetailReading
    let presentation: PhotosPresentationState
    let media: MediaLibraryController
    let libraryIndex: LibraryIndexController
    let saveProfile: (ConnectionProfileDraft) async -> ConnectionProfileSaveResult
    let signOut: (Bool) async -> Void

    @State private var tabSelectionState = NativeTabSelectionState()
    @State private var tabContentActivationState = NativeTabContentActivationState()
    @State private var timelineRotationState = TimelineRotationState()
    @State private var tabBarTop: CGFloat = 0
    @State private var compactPhotosTabs = false
    @State private var compactVideosTabs = false
    @State private var groupedMediaOwner: NativeTabDestination = .photos
    @State private var photosScrollRequest = 0
    @State private var videosScrollRequest = 0
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
    @State private var libraryPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var showsAccount = false
    @State private var viewerPresented = false

    var body: some View {
        @Bindable var navigation = tabSelectionState
        NativeAppTabShell(
            selection: $navigation.selection,
            tabBarTop: $tabBarTop,
            rotationState: timelineRotationState,
            contentActivationState: tabContentActivationState,
            compactOwner: compactTabOwner,
            isViewerPresented: viewerPresented,
            pageSwipeEnabled: pageSwipeEnabled,
            photosScrollRequest: photosScrollRequest,
            videosScrollRequest: videosScrollRequest,
            groupedScrollRequests: groupedScrollRequests,
            groupedMediaOwner: groupedMediaOwner,
            photosRetapped: {
                photosScrollRequest &+= 1
                compactPhotosTabs = false
            },
            videosRetapped: {
                videosScrollRequest &+= 1
                compactVideosTabs = false
            },
            libraryRetapped: {
                libraryDismissAccountRequest &+= 1
            },
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
                            tabSelectionState: tabSelectionState,
                            tabDestination: .photos,
                            showAccount: showAccount
                        )
                    }
                }
            ),
            videos: AnyView(
                NativeTabContentGate(
                    destination: .videos,
                    title: "Videos",
                    activationState: tabContentActivationState
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
                            tabSelectionState: tabSelectionState,
                            tabDestination: .videos,
                            showAccount: showAccount
                        )
                    }
                }
            ),
            albums: AnyView(
                NativeTabContentGate(
                    destination: .albums,
                    title: "Albums",
                    activationState: tabContentActivationState
                ) {
                    NavigationStack(path: $albumsPath) {
                        AlbumsView(albums: PreviewFixtures.albums, showAccount: showAccount)
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
                            session: session,
                            profile: profile,
                            activeRoute: activeRoute,
                            routeStatus: routeStatus,
                            libraryIndex: libraryIndex,
                            saveProfile: saveProfile,
                            signOut: signOut,
                            dismissAccountRequest: $libraryDismissAccountRequest,
                            accountPresentationChanged: { libraryAccountPresented = $0 }
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
                        SearchView(assets: PreviewFixtures.assets, showAccount: showAccount)
                    }
                }
            )
        )
        .ignoresSafeArea(.container, edges: .all)
        .environment(\.accountAvatarMedia, media)
        .onAppear { media.logShellPresented() }
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
                            close: { showsAccount = false }
                        )
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
    }

    private func showAccount() {
        showsAccount = true
    }

    private func setViewerPresented(_ presented: Bool) {
        viewerPresented = presented
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

    private var compactTabOwner: NativeTabDestination? {
        switch tabSelectionState.selection {
        case .photos: compactPhotosTabs ? .photos : nil
        case .videos: compactVideosTabs ? .videos : nil
        case .weeks, .months, .years: groupedMediaOwner
        default: nil
        }
    }

    private var pageSwipeEnabled: Bool {
        guard !viewerPresented,
              !libraryAccountPresented
        else { return false }

        switch tabSelectionState.selection {
        case .photos: return photosPath.isEmpty
        case .videos: return videosPath.isEmpty
        case .albums: return albumsPath.isEmpty
        case .library: return libraryPath.isEmpty
        case .search: return searchPath.isEmpty
        case .weeks, .months, .years: return true
        }
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
    @ViewBuilder let content: () -> Content

    var body: some View {
        if activationState.isHydrated(destination) {
            content()
        } else {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()
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
        presentation: .init(),
        media: .init(),
        libraryIndex: LibraryIndexController(source: PreviewTimelineReader()),
        saveProfile: { _ in .saved(profile: .init()) },
        signOut: { _ in }
    )
}
