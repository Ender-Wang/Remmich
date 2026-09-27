import SwiftUI

struct PhotosView: View {
    let state: FixtureContentState
    let sections: [FixtureAssetSection]
    let memories: [FixtureMemory]
    let showAccount: () -> Void

    init(
        state: FixtureContentState = .loaded,
        sections: [FixtureAssetSection] = PreviewFixtures.photoSections,
        memories: [FixtureMemory] = PreviewFixtures.memories,
        showAccount: @escaping () -> Void
    ) {
        self.state = state
        self.sections = sections
        self.memories = memories
        self.showAccount = showAccount
    }

    var body: some View {
        Group {
            switch state {
            case .loaded:
                if sections.isEmpty {
                    EmptyStateView(
                        title: "No Photos",
                        message: "Photos from your Immich library will appear here.",
                        systemImage: "photo.on.rectangle"
                    )
                } else {
                    timeline
                }
            case .loading:
                LoadingStateView()
            case .empty:
                EmptyStateView(
                    title: "No Photos",
                    message: "Photos from your Immich library will appear here.",
                    systemImage: "photo.on.rectangle"
                )
            case .failed:
                ErrorStateView {}
            }
        }
        .navigationTitle("Photos")
        .toolbar { AccountToolbarButton(action: showAccount) }
        .navigationDestination(for: FixtureAsset.self) { asset in
            FixtureAssetDetailView(asset: asset)
        }
        .accessibilityIdentifier("photos-root")
    }

    private var timeline: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if !memories.isEmpty {
                    memoryLane
                        .padding(.bottom, 12)
                }

                ForEach(sections) { section in
                    AssetSectionHeader(title: section.title, subtitle: section.subtitle)
                    AssetGrid(assets: section.assets)
                }
            }
        }
    }

    private var memoryLane: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 12) {
                ForEach(memories) { memory in
                    NavigationLink(value: memory.asset) {
                        ZStack(alignment: .bottomLeading) {
                            FixtureArtwork(palette: memory.asset.palette)
                            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(memory.title).font(.headline)
                                Text(memory.subtitle).font(.caption)
                            }
                            .foregroundStyle(.white)
                            .padding(12)
                        }
                        .frame(width: 190, height: 120)
                        .clipShape(.rect(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
        .scrollIndicators(.hidden)
    }
}

#Preview("Loaded") {
    NavigationStack { PhotosView(showAccount: {}) }
}

#Preview("Empty") {
    NavigationStack { PhotosView(state: .empty, showAccount: {}) }
}

#Preview("Error") {
    NavigationStack { PhotosView(state: .failed, showAccount: {}) }
}

#Preview("Large Text") {
    NavigationStack { PhotosView(showAccount: {}) }
        .environment(\.dynamicTypeSize, .accessibility3)
}
