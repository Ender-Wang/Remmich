import SwiftUI

struct SearchView: View {
    let assets: [FixtureAsset]
    let showAccount: () -> Void
    @State private var query = ""
    @State private var selectedKind: FixtureMediaKind?

    private var results: [FixtureAsset] {
        assets.filter { asset in
            (selectedKind == nil || asset.kind == selectedKind) &&
                (query.isEmpty || asset.title.localizedStandardContains(query) || asset.location.localizedStandardContains(query))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScrollView(.horizontal) {
                    HStack {
                        SearchFilterButton(title: "All", selected: selectedKind == nil) { selectedKind = nil }
                        SearchFilterButton(title: "Photos", selected: selectedKind == .photo) { selectedKind = .photo }
                        SearchFilterButton(title: "Videos", selected: selectedKind == .video) { selectedKind = .video }
                        SearchFilterButton(title: "Live Photos", selected: selectedKind == .livePhoto) { selectedKind = .livePhoto }
                    }
                    .padding(.horizontal)
                }
                .scrollIndicators(.hidden)

                if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .frame(maxWidth: .infinity)
                } else {
                    Text(query.isEmpty ? "Explore" : "Results")
                        .font(.title2.bold())
                        .padding(.horizontal)
                    AssetGrid(assets: results)
                }
            }
            .padding(.top, 8)
        }
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Photos, places, and more")
        .toolbar { AccountToolbarButton(action: showAccount) }
        .navigationDestination(for: FixtureAsset.self) { asset in
            FixtureAssetDetailView(asset: asset)
        }
        .accessibilityIdentifier("search-root")
    }
}

private struct SearchFilterButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .tint(selected ? .accentColor : .secondary)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

#Preview {
    NavigationStack { SearchView(assets: PreviewFixtures.assets, showAccount: {}) }
}
