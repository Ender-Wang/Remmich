import SwiftUI

struct AppShellView: View {
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
                    PhotosView(showAccount: showAccount)
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
        .sheet(isPresented: $showsAccount) {
            AccountSettingsView()
        }
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
    AppShellView()
}
