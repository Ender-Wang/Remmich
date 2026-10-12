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
    let presentation: PhotosPresentationState
    let media: MediaLibraryController
    let saveProfile: (ConnectionProfileDraft) async -> ConnectionProfileSaveResult
    let signOut: () async -> Void

    @State private var selection: NativeTabDestination = .photos
    @State private var tabBarTop: CGFloat = 0
    @State private var compactPhotosTabs = false
    @State private var compactVideosTabs = false
    @State private var groupedMediaOwner: NativeTabDestination = .photos
    @State private var photosScrollRequest = 0
    @State private var videosScrollRequest = 0
    @State private var videoPresentation = PhotosPresentationState(
        store: UserDefaultsPresentationPreferencesStore(key: "video-presentation-preferences")
    )
    @State private var groupedScrollRequests: [NativeTabDestination: Int] = [:]
    @State private var photosPath: [PhotosRangeRoute] = []
    @State private var videosPath: [PhotosRangeRoute] = []
    @State private var albumsPath = NavigationPath()
    @State private var libraryPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var showsAccount = false

    var body: some View {
        NativeAppTabShell(
            selection: $selection,
            tabBarTop: $tabBarTop,
            compactOwner: compactTabOwner,
            photosRetapped: {
                photosScrollRequest &+= 1
                compactPhotosTabs = false
            },
            videosRetapped: {
                videosScrollRequest &+= 1
                compactVideosTabs = false
            },
            groupedTabRetapped: { destination in
                groupedScrollRequests[destination, default: 0] &+= 1
            },
            photos: AnyView(
                NavigationStack {
                    PhotosView(
                        store: photos,
                        presentation: presentation,
                        media: media,
                        navigationPath: $photosPath,
                        scrollToLatestRequest: photosScrollRequest,
                        tabBarTop: tabBarTop,
                        compactChromeChanged: { compact in
                            compactPhotosTabs = compact
                            if compact, selection == .photos {
                                groupedMediaOwner = .photos
                            }
                        },
                        showAccount: showAccount
                    )
                }
            ),
            videos: AnyView(
                NavigationStack {
                    PhotosView(
                        store: videos,
                        presentation: videoPresentation,
                        media: media,
                        navigationPath: $videosPath,
                        scrollToLatestRequest: videosScrollRequest,
                        tabBarTop: tabBarTop,
                        contentName: "Videos",
                        rootAccessibilityID: "videos-root",
                        compactChromeChanged: { compact in
                            compactVideosTabs = compact
                            if compact, selection == .videos {
                                groupedMediaOwner = .videos
                            }
                        },
                        showAccount: showAccount
                    )
                }
            ),
            albums: AnyView(
                NavigationStack(path: $albumsPath) {
                    AlbumsView(albums: PreviewFixtures.albums, showAccount: showAccount)
                }
            ),
            library: AnyView(
                NavigationStack(path: $libraryPath) {
                    LibraryView(collections: PreviewFixtures.collections, showAccount: showAccount)
                }
            ),
            years: AnyView(
                PhotosGroupedTabView(
                    kind: .years,
                    isSelected: selection == .years,
                    scrollToLatestRequest: groupedScrollRequests[.years, default: 0],
                    tabBarTop: tabBarTop,
                    store: groupedMediaStore,
                    media: media,
                    dayIconSystemImage: groupedDayIconSystemImage,
                    showAccount: showAccount
                )
                .id(groupedMediaOwner)
            ),
            months: AnyView(
                PhotosGroupedTabView(
                    kind: .months,
                    isSelected: selection == .months,
                    scrollToLatestRequest: groupedScrollRequests[.months, default: 0],
                    tabBarTop: tabBarTop,
                    store: groupedMediaStore,
                    media: media,
                    dayIconSystemImage: groupedDayIconSystemImage,
                    showAccount: showAccount
                )
                .id(groupedMediaOwner)
            ),
            weeks: AnyView(
                PhotosGroupedTabView(
                    kind: .weeks,
                    isSelected: selection == .weeks,
                    scrollToLatestRequest: groupedScrollRequests[.weeks, default: 0],
                    tabBarTop: tabBarTop,
                    store: groupedMediaStore,
                    media: media,
                    dayIconSystemImage: groupedDayIconSystemImage,
                    showAccount: showAccount
                )
                .id(groupedMediaOwner)
            ),
            search: AnyView(
                NavigationStack(path: $searchPath) {
                    SearchView(assets: PreviewFixtures.assets, showAccount: showAccount)
                }
            )
        )
        .ignoresSafeArea(.container, edges: .all)
        .environment(\.accountAvatarMedia, media)
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

    private var compactTabOwner: NativeTabDestination? {
        switch selection {
        case .photos: compactPhotosTabs ? .photos : nil
        case .videos: compactVideosTabs ? .videos : nil
        case .weeks, .months, .years: groupedMediaOwner
        default: nil
        }
    }

    private var groupedMediaStore: PhotosTimelineStore {
        groupedMediaOwner == .videos ? videos : photos
    }

    private var groupedDayIconSystemImage: String {
        timelineDayIconSystemImage(contentName: groupedMediaOwner == .videos ? "Videos" : "Photos")
    }
}

struct AccountToolbarButton: ToolbarContent {
    @Environment(\.accountAvatarMedia) private var media
    @Environment(\.displayScale) private var displayScale

    let action: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: action) {
                Group {
                    if let media {
                        LazyImage(request: media.profileImageRequest(targetPixels: Int(32 * displayScale))) { state in
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
                .frame(width: 32, height: 32)
                .clipShape(Circle())
                .background(Circle().fill(.regularMaterial))
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Account")
            .accessibilityIdentifier("account-button")
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
        presentation: .init(),
        media: .init(),
        saveProfile: { _ in .saved(profile: .init()) },
        signOut: {}
    )
}
