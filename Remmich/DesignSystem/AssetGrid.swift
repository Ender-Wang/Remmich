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
        .accessibilityIdentifier(horizontalSizeClass == .regular ? "asset-grid-regular" : "asset-grid-compact")
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

struct TimelineAssetGrid: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let assets: [TimelineAssetSummary]
    let media: MediaLibraryController
    var visibilityChanged: (String, MediaRequestDescriptor?) -> Void = { _, _ in }

    private var columns: [GridItem] {
        let minimum: CGFloat = horizontalSizeClass == .regular ? 120 : 88
        return [GridItem(.adaptive(minimum: minimum, maximum: 180), spacing: 2)]
    }

    var body: some View {
        VStack(spacing: 0) {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(assets) { asset in
                    TimelineAssetThumbnail(
                        asset: asset,
                        media: media,
                        visibilityChanged: visibilityChanged
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Photo grid")
        .accessibilityIdentifier(horizontalSizeClass == .regular ? "asset-grid-regular" : "asset-grid-compact")
    }
}

private struct TimelineAssetThumbnail: View {
    @Environment(\.displayScale) private var displayScale
    let asset: TimelineAssetSummary
    let media: MediaLibraryController
    let visibilityChanged: (String, MediaRequestDescriptor?) -> Void

    var body: some View {
        GeometryReader { proxy in
            let pixels = max(1, Int((proxy.size.width * displayScale).rounded(.up)))
            let descriptor = MediaRequestDescriptor(
                assetID: asset.id,
                updatedAt: asset.thumbnailRevision,
                derivative: .thumbnail,
                targetPixels: .init(width: pixels, height: pixels)
            )
            ImmichThumbnail(
                descriptor: descriptor,
                media: media,
                didLoad: { media.retainTimelineThumbnail($0, descriptor: descriptor) }
            )
            .frame(width: proxy.size.width, height: proxy.size.height)
            .overlay(alignment: .topTrailing) {
                if asset.isFavorite {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.white)
                        .padding(7)
                        .shadow(radius: 2)
                }
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 5) {
                    if asset.livePhotoVideoID != nil {
                        Image(systemName: "livephoto")
                    }
                    if asset.projectionType != nil {
                        Image(systemName: "view.360")
                    }
                    if let stack = asset.stack, stack.assetCount > 1 {
                        Label("\(stack.assetCount)", systemImage: "square.stack.3d.up.fill")
                    }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(6)
                .shadow(radius: 3)
            }
            .overlay(alignment: .bottomTrailing) {
                if asset.mediaKind == .video {
                    Label(Self.duration(asset.durationMilliseconds), systemImage: "play.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(6)
                        .shadow(radius: 3)
                }
            }
            .onAppear { visibilityChanged(asset.id, descriptor) }
            .onDisappear { visibilityChanged(asset.id, nil) }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("asset-\(asset.id)")
    }

    private var accessibilityLabel: String {
        var values = [asset.capturedAt.formatted(date: .abbreviated, time: .shortened)]
        values.append(asset.mediaKind == .video ? "Video" : "Photo")
        if asset.isFavorite {
            values.append("Favorite")
        }
        if asset.livePhotoVideoID != nil {
            values.append("Live Photo")
        }
        if let stack = asset.stack {
            values.append("Stack of \(stack.assetCount)")
        }
        return values.joined(separator: ", ")
    }

    private static func duration(_ milliseconds: Int?) -> String {
        guard let milliseconds else { return "" }
        let seconds = max(0, milliseconds / 1000)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
