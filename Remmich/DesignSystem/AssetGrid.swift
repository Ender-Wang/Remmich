import SwiftUI

extension EnvironmentValues {
    @Entry var photosPinchItemScale: CGFloat = 1
}

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
    let availableWidth: CGFloat
    var visibilityChanged: (String, MediaRequestDescriptor?) -> Void = { _, _ in }
    var viewportChanged: (TimelineAssetSummary, Bool) -> Void = { _, _ in }

    private var minimumColumnWidth: CGFloat {
        horizontalSizeClass == .regular ? 120 : 88
    }

    private var columnCount: Int {
        TimelineGridOrder.columnCount(availableWidth: availableWidth, minimumColumnWidth: minimumColumnWidth)
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 0), spacing: 2), count: columnCount)
    }

    private var displaySlots: [TimelineGridDisplaySlot] {
        TimelineGridOrder.displaySlots(itemCount: assets.count, columns: columnCount)
            .enumerated()
            .map { offset, index in
                if let index {
                    let asset = assets[index]
                    return .init(id: "asset-\(asset.id)", asset: asset)
                }
                return .init(id: "gap-\(offset)", asset: nil)
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            if availableWidth > 0 {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(displaySlots) { slot in
                        if let asset = slot.asset {
                            TimelineAssetThumbnail(
                                asset: asset,
                                media: media,
                                visibilityChanged: visibilityChanged,
                                viewportChanged: viewportChanged
                            )
                        } else {
                            Color.clear
                                .aspectRatio(1, contentMode: .fit)
                                .accessibilityHidden(true)
                        }
                    }
                }
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Photo grid")
        .accessibilityIdentifier(horizontalSizeClass == .regular ? "asset-grid-regular" : "asset-grid-compact")
    }
}

private struct TimelineGridDisplaySlot: Identifiable {
    let id: String
    let asset: TimelineAssetSummary?
}

nonisolated enum TimelineGridOrder {
    static func columnCount(availableWidth: CGFloat, minimumColumnWidth: CGFloat) -> Int {
        max(1, Int((availableWidth + 2) / (minimumColumnWidth + 2)))
    }

    static func displaySlots(itemCount: Int, columns: Int) -> [Int?] {
        guard itemCount > 0 else { return [] }
        let columns = max(1, columns)
        let rows = stride(from: 0, to: itemCount, by: columns)
            .map { start in start ..< min(start + columns, itemCount) }
        return rows.reversed().flatMap { row in
            row.map(Optional.some) + Array(repeating: nil, count: columns - row.count)
        }
    }
}

private struct TimelineAssetThumbnail: View {
    @Environment(\.displayScale) private var displayScale
    @Environment(\.photosPinchItemScale) private var photosPinchItemScale
    let asset: TimelineAssetSummary
    let media: MediaLibraryController
    let visibilityChanged: (String, MediaRequestDescriptor?) -> Void
    let viewportChanged: (TimelineAssetSummary, Bool) -> Void

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
            .onScrollVisibilityChange(threshold: 0.5) { visible in
                viewportChanged(asset, visible)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .scaleEffect(photosPinchItemScale, anchor: .center)
        .clipped()
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("asset-\(asset.id)")
        .id(asset.id)
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
