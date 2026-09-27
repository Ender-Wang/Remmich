import SwiftUI

struct LibraryView: View {
    let collections: [FixtureCollection]
    let showAccount: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 14)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(collections) { collection in
                    NavigationLink(value: collection) {
                        CollectionCard(collection: collection)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationTitle("Library")
        .toolbar { AccountToolbarButton(action: showAccount) }
        .navigationDestination(for: FixtureCollection.self) { collection in
            CollectionDetailView(collection: collection)
        }
        .navigationDestination(for: FixtureAsset.self) { asset in
            FixtureAssetDetailView(asset: asset)
        }
        .accessibilityIdentifier("library-root")
    }
}

private struct CollectionCard: View {
    let collection: FixtureCollection

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            FixtureArtwork(palette: collection.palette, systemImage: collection.kind.systemImage)
            LinearGradient(colors: [.clear, .black.opacity(0.62)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 3) {
                Text(collection.title).font(.headline)
                Text(collection.subtitle).font(.caption)
            }
            .foregroundStyle(.white)
            .padding(12)
        }
        .aspectRatio(4 / 3, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 18))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("collection-\(collection.id)")
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
    NavigationStack { LibraryView(collections: PreviewFixtures.collections, showAccount: {}) }
}
