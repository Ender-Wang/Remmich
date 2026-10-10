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
    let presentation: PhotosPresentationState
    let media: MediaLibraryController
    let saveProfile: (ConnectionProfileDraft) async -> ConnectionProfileSaveResult
    let signOut: () async -> Void

    @State private var selection: AppDestination = .photos
    @State private var photosScrollRequest = 0
    @State private var photosPath: [PhotosRangeRoute] = []
    @State private var albumsPath = NavigationPath()
    @State private var libraryPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var showsAccount = false

    var body: some View {
        TabView(selection: Binding(
            get: { selection },
            set: { destination in
                if destination == .photos, selection == .photos {
                    photosScrollRequest &+= 1
                }
                selection = destination
            }
        )) {
            Tab(AppDestination.photos.title, systemImage: AppDestination.photos.systemImage, value: .photos) {
                NavigationStack {
                    PhotosView(
                        store: photos,
                        presentation: presentation,
                        media: media,
                        navigationPath: $photosPath,
                        scrollToLatestRequest: photosScrollRequest,
                        showAccount: showAccount
                    )
                }
            }

            Tab(AppDestination.albums.title, systemImage: AppDestination.albums.systemImage, value: .albums) {
                NavigationStack(path: $albumsPath) {
                    AlbumsView(albums: PreviewFixtures.albums, showAccount: showAccount)
                }
            }

            Tab(AppDestination.library.title, systemImage: AppDestination.library.systemImage, value: .library) {
                NavigationStack(path: $libraryPath) {
                    LibraryView(collections: PreviewFixtures.collections, showAccount: showAccount)
                }
            }

            Tab(value: .search, role: .search) {
                NavigationStack(path: $searchPath) {
                    SearchView(assets: PreviewFixtures.assets, showAccount: showAccount)
                }
            }
        }
        .tabViewStyle(.tabBarOnly)
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
        presentation: .init(),
        media: .init(),
        saveProfile: { _ in .saved(profile: .init()) },
        signOut: {}
    )
}
