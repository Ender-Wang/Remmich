import SwiftUI

struct AssetGrid: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let assets: [FixtureAsset]

    private var columns: [GridItem] {
        let minimum: CGFloat = horizontalSizeClass == .regular ? 120 : 88
        return [GridItem(.adaptive(minimum: minimum, maximum: 180), spacing: 2)]
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(assets) { asset in
                NavigationLink(value: asset) {
                    AssetThumbnail(asset: asset)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct AssetThumbnail: View {
    let asset: FixtureAsset

    var body: some View {
        FixtureArtwork(palette: asset.palette)
            .aspectRatio(1, contentMode: .fill)
            .overlay(alignment: .topTrailing) {
                if asset.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(7)
                        .shadow(radius: 2)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let systemImage = asset.kind.systemImage {
                    Label(asset.duration ?? "", systemImage: systemImage)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .labelStyle(.titleAndIcon)
                        .padding(6)
                        .shadow(radius: 3)
                }
            }
            .contentShape(.rect)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(asset.title), \(asset.kind.accessibilityDescription)")
            .accessibilityIdentifier("asset-\(asset.id)")
    }
}

struct AssetSectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.headline)
            Spacer()
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}
