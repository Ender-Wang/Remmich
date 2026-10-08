import SwiftUI
import UIKit

struct AppShellView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let session: AccountSession
    let profile: ConnectionProfile
    let activeRoute: ActiveConnectionRoute?
    let routeStatus: ConnectionRouteStatus
    let photos: PhotosTimelineStore
    let media: MediaLibraryController
    let saveProfile: (ConnectionProfileDraft) async -> ConnectionProfileSaveResult
    let signOut: () async -> Void

    @State private var selection: AppDestination = .photos
    @State private var photosPath = NavigationPath()
    @State private var albumsPath = NavigationPath()
    @State private var libraryPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var showsAccount = false

    var body: some View {
        TabView(selection: $selection) {
            Tab(AppDestination.photos.title, systemImage: AppDestination.photos.systemImage, value: .photos) {
                NavigationStack(path: $photosPath) {
                    PhotosView(store: photos, media: media, showAccount: showAccount)
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
        .tabViewStyle(.sidebarAdaptable)
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
    let action: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: action) {
                Label("Account", systemImage: "person.crop.circle")
            }
            .accessibilityIdentifier("account-button")
        }
    }
}

#Preview {
    let store = PhotosTimelineStore(reader: PreviewTimelineReader())
    AppShellView(
        session: .fixture,
        profile: .init(),
        activeRoute: nil,
        routeStatus: .waitingForNetwork,
        photos: store,
        media: .init(),
        saveProfile: { _ in .saved(profile: .init()) },
        signOut: {}
    )
}
