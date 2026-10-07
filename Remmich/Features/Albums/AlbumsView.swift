import SwiftUI

enum AlbumScope: String, CaseIterable, Identifiable {
    case all = "All"
    case shared = "Shared"

    var id: Self {
        self
    }
}

struct AlbumsView: View {
    let albums: [FixtureAlbum]
    let showAccount: () -> Void
    @State private var scope: AlbumScope = .all
    @State private var query = ""

    private let columns = [GridItem(.adaptive(minimum: 155, maximum: 240), spacing: 14)]

    private var filteredAlbums: [FixtureAlbum] {
        albums.filter { album in
            (scope == .all || album.isShared) &&
                (query.isEmpty || album.title.localizedStandardContains(query))
        }
    }

    var body: some View {
        ScrollView {
            if filteredAlbums.isEmpty {
                EmptyStateView(
                    title: query.isEmpty ? "No Shared Albums" : "No Results",
                    message: query.isEmpty ? "Shared albums will appear here." : "Try a different album name.",
                    systemImage: "rectangle.stack"
                )
                .containerRelativeFrame(.vertical)
            } else {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(filteredAlbums) { album in
                        NavigationLink(value: album) {
                            AlbumCard(album: album)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
        }
        .safeAreaInset(edge: .top) {
            Picker("Album scope", selection: $scope) {
                ForEach(AlbumScope.allCases) { value in
                    Text(value.rawValue).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .searchable(text: $query, prompt: "Albums")
        .toolbar { AccountToolbarButton(action: showAccount) }
        .navigationDestination(for: FixtureAlbum.self) { album in
            AlbumDetailView(album: album)
        }
        .navigationDestination(for: FixtureAsset.self) { asset in
            FixtureAssetDetailView(asset: asset)
        }
        .accessibilityIdentifier("albums-root")
    }
}

private struct AlbumCard: View {
    let album: FixtureAlbum

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FixtureArtwork(palette: album.cover?.palette ?? .coast)
                .aspectRatio(4 / 3, contentMode: .fill)
                .clipShape(.rect(cornerRadius: 16))
                .overlay(alignment: .topTrailing) {
                    if album.isShared {
                        Image(systemName: "person.2.fill")
                            .foregroundStyle(.white)
                            .padding(10)
                            .shadow(radius: 3)
                    }
                }
            Text(album.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(album.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("album-\(album.id)")
    }
}

private struct AlbumDetailView: View {
    let album: FixtureAlbum

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(album.subtitle).foregroundStyle(.secondary)
                    if album.isShared {
                        Label("Shared", systemImage: "person.2")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)
                AssetGrid(assets: album.assets)
            }
        }
        .navigationTitle(album.title)
    }
}

#Preview {
    NavigationStack { AlbumsView(albums: PreviewFixtures.albums, showAccount: {}) }
}

#Preview("Long Titles · Dark") {
    NavigationStack {
        AlbumsView(
            albums: [
                FixtureAlbum(
                    id: "long-title",
                    title: "A very long album title that must adapt gracefully",
                    subtitle: "Shared by someone with a long display name",
                    isShared: true,
                    assets: Array(PreviewFixtures.assets.prefix(6))
                ),
            ],
            showAccount: {}
        )
    }
    .preferredColorScheme(.dark)
}
