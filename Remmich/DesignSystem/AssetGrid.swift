import SwiftUI

nonisolated enum TimelineCoverAnimation {
    static let zoomScale = 1.1
    static let zoomDuration = 6.0
    static let fadeDuration = 3.0
    static let overlapStep = 1.5
    static let initialHold = 3.0
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

struct TimelineDayAssetSection: View {
    let group: TimelineDayGroup
    let media: MediaLibraryController
    let availableWidth: CGFloat
    var assetLayout: PhotosAssetLayout = .square
    var accessibilityIdentifierPrefix = "timeline-day"
    var visibilityChanged: (String, MediaRequestDescriptor?) -> Void = { _, _ in }
    var viewportChanged: (TimelineAssetSummary, Bool) -> Void = { _, _ in }

    var body: some View {
        VStack(spacing: 0) {
            AssetSectionHeader(
                title: title,
                subtitle: group.assets.count.formatted() + " items"
            )
            TimelineAssetGrid(
                assets: group.assets,
                media: media,
                availableWidth: availableWidth,
                assetLayout: assetLayout,
                visibilityChanged: visibilityChanged,
                viewportChanged: viewportChanged
            )
        }
        .id(group.id.id)
        .accessibilityIdentifier("\(accessibilityIdentifierPrefix)-\(group.id.id)")
    }

    private var title: String {
        guard let date = group.id.displayDate else { return group.id.id }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

struct TimelineAssetGrid: View {
    private static let compactSpacing: CGFloat = 2
    private static let phoneNaturalAspectRowSpacing: CGFloat = 12
    private static let padNaturalAspectRowSpacing: CGFloat = 24

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let assets: [TimelineAssetSummary]
    let media: MediaLibraryController
    let availableWidth: CGFloat
    var assetLayout: PhotosAssetLayout = .square
    var visibilityChanged: (String, MediaRequestDescriptor?) -> Void = { _, _ in }
    var viewportChanged: (TimelineAssetSummary, Bool) -> Void = { _, _ in }

    private var minimumColumnWidth: CGFloat {
        horizontalSizeClass == .regular ? 120 : 88
    }

    private var columnCount: Int {
        TimelineGridOrder.columnCount(
            availableWidth: availableWidth,
            minimumColumnWidth: minimumColumnWidth,
            spacing: itemSpacing
        )
    }

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 0), spacing: itemSpacing),
            count: columnCount
        )
    }

    private var itemSpacing: CGFloat {
        guard assetLayout == .naturalAspect else { return Self.compactSpacing }
        return UIDevice.current.userInterfaceIdiom == .pad
            ? Self.padNaturalAspectRowSpacing
            : Self.phoneNaturalAspectRowSpacing
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
                LazyVGrid(columns: columns, spacing: itemSpacing) {
                    ForEach(displaySlots) { slot in
                        if let asset = slot.asset {
                            TimelineAssetThumbnail(
                                asset: asset,
                                media: media,
                                assetLayout: assetLayout,
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
    static func columnCount(
        availableWidth: CGFloat,
        minimumColumnWidth: CGFloat,
        spacing: CGFloat = 2
    ) -> Int {
        max(1, Int((availableWidth + spacing) / (minimumColumnWidth + spacing)))
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
    let asset: TimelineAssetSummary
    let media: MediaLibraryController
    let assetLayout: PhotosAssetLayout
    let visibilityChanged: (String, MediaRequestDescriptor?) -> Void
    let viewportChanged: (TimelineAssetSummary, Bool) -> Void

    var body: some View {
        GeometryReader { proxy in
            let widthPixels = Self.targetPixels(for: proxy.size.width, scale: displayScale)
            let heightPixels = Self.targetPixels(for: proxy.size.height, scale: displayScale)
            let descriptor = MediaRequestDescriptor(
                assetID: asset.id,
                updatedAt: asset.thumbnailRevision,
                derivative: .thumbnail,
                targetPixels: .init(width: widthPixels, height: heightPixels)
            )
            ImmichThumbnail(
                descriptor: descriptor,
                media: media,
                contentMode: assetLayout == .square ? .fill : .fit,
                showsBackground: assetLayout == .square,
                imageCornerRadius: assetLayout == .naturalAspect
                    ? DesignMetrics.compactCornerRadius
                    : 0,
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

    private static func targetPixels(for points: CGFloat, scale: CGFloat) -> Int {
        min(2048, max(1, Int((points * scale).rounded(.up))))
    }
}
