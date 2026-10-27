import Nuke
import SwiftUI
import UIKit

nonisolated enum TimelineCoverAnimation {
    static let zoomScale = 1.1
    static let zoomDuration = 6.0
    static let fadeDuration = 3.0
    static let overlapStep = 1.5
    static let initialHold = 3.0
    static let cycleDuration = initialHold + overlapStep * 2
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
            .overlay(alignment: .bottom) {
                if asset.kind == .video, let duration = asset.duration {
                    Text(duration)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.bottom, 3)
                        .shadow(radius: 3)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if asset.kind == .livePhoto {
                    Image(systemName: "livephoto")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding([.leading, .bottom], 3)
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
    var transitionNamespace: Namespace.ID?
    var assetSelected: (TimelineAssetSummary) -> Void = { _ in }

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
                viewportChanged: viewportChanged,
                transitionNamespace: transitionNamespace,
                assetSelected: assetSelected
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
    var transitionNamespace: Namespace.ID?
    var assetSelected: (TimelineAssetSummary) -> Void = { _ in }

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
                                viewportChanged: viewportChanged,
                                transitionNamespace: transitionNamespace,
                                assetSelected: assetSelected
                            )
                            .aspectRatio(1, contentMode: .fit)
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
    static func timelineColumnCount(
        availableSize: CGSize,
        minimumLandscapeColumnWidth: CGFloat,
        spacing: CGFloat = 2
    ) -> Int {
        if availableSize.width < availableSize.height {
            return 5
        }
        return columnCount(
            availableWidth: availableSize.width,
            minimumColumnWidth: minimumLandscapeColumnWidth,
            spacing: spacing
        )
    }

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

nonisolated enum TimelineGridMetrics {
    static func edgeInset(isPhone: Bool) -> CGFloat {
        isPhone ? 12 : 20
    }

    static func horizontalInset(
        naturalAspectProgress: CGFloat,
        isPhone: Bool,
        squareInset: CGFloat,
        isDarkMode: Bool = false
    ) -> CGFloat {
        guard !isDarkMode else { return 0 }
        let progress = min(1, max(0, naturalAspectProgress))
        return squareInset + (edgeInset(isPhone: isPhone) - squareInset) * progress
    }

    static func itemWidth(
        rowWidth: CGFloat,
        columns: Int,
        spacing: CGFloat,
        horizontalInset: CGFloat
    ) -> CGFloat {
        let columns = max(1, columns)
        let availableWidth = rowWidth
            - horizontalInset * 2
            - CGFloat(columns - 1) * spacing
        return max(1, availableWidth / CGFloat(columns))
    }
}

nonisolated struct TimelineAssetFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(
        value: inout [String: CGRect],
        nextValue: () -> [String: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

nonisolated struct TimelineDeterministicLayout {
    static let headerHeight: CGFloat = 36
    static let bottomSpacerID = "timeline-bottom-spacer"
    static let bottomSpacing: CGFloat = 12

    struct AssetRowTarget: Equatable {
        let rowID: String
        let rowHeight: CGFloat
        let bucketID: TimelineBucketID
    }

    struct Key: Equatable {
        let width: CGFloat
        let minimumColumnWidth: CGFloat
        let spacing: CGFloat
        let fixedColumnCount: Int?
        let sectionRevisions: [String]
    }

    struct Row: Identifiable {
        enum Content {
            case header(TimelineDayGroup)
            case assets([TimelineAssetSummary?])
            case placeholder(TimelineSection)
        }

        let id: String
        let bucketID: TimelineBucketID
        let content: Content
        let offset: CGFloat
        let height: CGFloat
        let assetHeight: CGFloat
    }

    static let empty = TimelineDeterministicLayout(
        key: .init(
            width: 0,
            minimumColumnWidth: 0,
            spacing: 0,
            fixedColumnCount: nil,
            sectionRevisions: []
        ),
        columns: 1,
        itemSide: 0,
        rows: [],
        assetRowTargets: [:],
        totalHeight: 0,
        buildMilliseconds: 0
    )

    let key: Key
    let columns: Int
    let itemSide: CGFloat
    let rows: [Row]
    let assetRowTargets: [String: AssetRowTarget]
    let totalHeight: CGFloat
    let buildMilliseconds: Int

    static func build(
        sections: [TimelineSection],
        key: Key
    ) -> TimelineDeterministicLayout {
        guard key.width > 0 else { return .empty }
        let startedAt = ContinuousClock.now
        let columns = key.fixedColumnCount.map { max(1, $0) }
            ?? TimelineGridOrder.columnCount(
                availableWidth: key.width,
                minimumColumnWidth: key.minimumColumnWidth,
                spacing: key.spacing
            )
        let itemSide = max(1, (key.width - CGFloat(columns - 1) * key.spacing) / CGFloat(columns))
        var rows: [Row] = []
        var assetRowTargets: [String: AssetRowTarget] = [:]
        assetRowTargets.reserveCapacity(sections.reduce(0) { $0 + $1.assets.count })
        rows.reserveCapacity(sections.reduce(0) { result, section in
            result + Int(ceil(Double(section.assets.count) / Double(columns))) + 31
        })
        var offset: CGFloat = 0

        for section in sections.reversed() {
            if section.assets.isEmpty {
                let height: CGFloat = 124
                rows.append(Row(
                    id: "placeholder-\(section.id.rawValue)",
                    bucketID: section.id,
                    content: .placeholder(section),
                    offset: offset,
                    height: height,
                    assetHeight: 0
                ))
                offset += height
                continue
            }
            for group in section.dayGroups.reversed() {
                rows.append(Row(
                    id: "header-\(section.id.rawValue)-\(group.id.id)",
                    bucketID: section.id,
                    content: .header(group),
                    offset: offset,
                    height: headerHeight,
                    assetHeight: 0
                ))
                offset += headerHeight

                let slots = TimelineGridOrder.displaySlots(
                    itemCount: group.assets.count,
                    columns: columns
                ).map { index in index.map { group.assets[$0] } }
                let rowCount = Int(ceil(Double(slots.count) / Double(columns)))
                for rowIndex in 0 ..< rowCount {
                    let start = rowIndex * columns
                    let end = min(start + columns, slots.count)
                    let rowSlots = Array(slots[start ..< end])
                    let hasFollowingAssetRow = rowIndex + 1 < rowCount
                    let height = itemSide + (hasFollowingAssetRow ? key.spacing : 0)
                    let nonempty = rowSlots.compactMap(\.self)
                    let rowID = "row-\(section.id.rawValue)-\(group.id.id)-\(rowIndex)"
                    for asset in nonempty {
                        assetRowTargets[asset.id] = AssetRowTarget(
                            rowID: rowID,
                            rowHeight: height,
                            bucketID: section.id
                        )
                    }
                    rows.append(Row(
                        id: rowID,
                        bucketID: section.id,
                        content: .assets(rowSlots),
                        offset: offset,
                        height: height,
                        assetHeight: itemSide
                    ))
                    offset += height
                }
            }
        }

        return TimelineDeterministicLayout(
            key: key,
            columns: columns,
            itemSide: itemSide,
            rows: rows,
            assetRowTargets: assetRowTargets,
            totalHeight: offset,
            buildMilliseconds: elapsedMilliseconds(since: startedAt)
        )
    }

    func rowTarget(of assetID: String) -> AssetRowTarget? {
        assetRowTargets[assetID]
    }

    private static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
        let components = start.duration(to: .now).components
        return Int(components.seconds) * 1000
            + Int(components.attoseconds / 1_000_000_000_000_000)
    }
}

@MainActor
final class TimelineDeterministicLayoutCache {
    private(set) var current = TimelineDeterministicLayout.empty
    private(set) var previous = TimelineDeterministicLayout.empty

    func resolve(
        sections: [TimelineSection],
        key: TimelineDeterministicLayout.Key
    ) -> TimelineDeterministicLayout {
        guard current.key != key else { return current }
        previous = current
        current = TimelineDeterministicLayout.build(sections: sections, key: key)
        return current
    }
}

struct TimelineDeterministicAssetRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let assets: [TimelineAssetSummary?]
    let media: MediaLibraryController
    let itemSide: CGFloat
    let spacing: CGFloat
    let assetLayout: PhotosAssetLayout
    var naturalAspectProgress: CGFloat?
    var requestSide: CGFloat?
    let visibilityChanged: (String, MediaRequestDescriptor?) -> Void
    let viewportChanged: (TimelineAssetSummary, Bool) -> Void
    let transitionNamespace: Namespace.ID?
    let assetSelected: (TimelineAssetSummary) -> Void
    let frameCoordinateSpaceName: String
    var priority: ImageRequest.Priority = .normal
    var hiddenLivePhotoBadgeAssetID: String?
    var hiddenReturningThumbnailAssetID: String?

    var body: some View {
        let progress = min(1, max(0, naturalAspectProgress ?? (assetLayout == .naturalAspect ? 1 : 0)))
        let horizontalInset = TimelineGridMetrics.horizontalInset(
            naturalAspectProgress: progress,
            isPhone: UIDevice.current.userInterfaceIdiom == .phone,
            squareInset: spacing,
            isDarkMode: colorScheme == .dark
        )
        let rowWidth = itemSide * CGFloat(assets.count)
            + spacing * CGFloat(max(0, assets.count - 1))
        let itemWidth = TimelineGridMetrics.itemWidth(
            rowWidth: rowWidth,
            columns: assets.count,
            spacing: spacing,
            horizontalInset: horizontalInset
        )

        HStack(spacing: spacing) {
            ForEach(Array(assets.enumerated()), id: \.offset) { _, asset in
                if let asset {
                    TimelineAssetThumbnail(
                        asset: asset,
                        media: media,
                        assetLayout: assetLayout,
                        naturalAspectProgress: progress,
                        requestSide: requestSide,
                        visibilityChanged: visibilityChanged,
                        viewportChanged: viewportChanged,
                        transitionNamespace: transitionNamespace,
                        assetSelected: assetSelected,
                        priority: priority,
                        hiddenLivePhotoBadgeAssetID: hiddenLivePhotoBadgeAssetID,
                        hiddenReturningThumbnailAssetID: hiddenReturningThumbnailAssetID
                    )
                    .frame(width: itemWidth, height: itemSide)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: TimelineAssetFramePreferenceKey.self,
                                value: [
                                    asset.id: geometry.frame(
                                        in: .named(frameCoordinateSpaceName)
                                    ),
                                ]
                            )
                        }
                    }
                } else {
                    Color.clear
                        .frame(width: itemWidth, height: itemSide)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, horizontalInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TimelineAssetThumbnail: View {
    @Environment(\.displayScale) private var displayScale
    let asset: TimelineAssetSummary
    let media: MediaLibraryController
    let assetLayout: PhotosAssetLayout
    var naturalAspectProgress: CGFloat?
    var requestSide: CGFloat?
    let visibilityChanged: (String, MediaRequestDescriptor?) -> Void
    let viewportChanged: (TimelineAssetSummary, Bool) -> Void
    let transitionNamespace: Namespace.ID?
    let assetSelected: (TimelineAssetSummary) -> Void
    var priority: ImageRequest.Priority = .normal
    var placeholderImage: UIImage?
    var imageLoaded: (UIImage) -> Void = { _ in }
    var hiddenLivePhotoBadgeAssetID: String?
    var hiddenReturningThumbnailAssetID: String?

    private var resolvedNaturalAspectProgress: CGFloat {
        naturalAspectProgress
            .map { min(1, max(0, $0)) }
            ?? (assetLayout == .naturalAspect ? 1 : 0)
    }

    var body: some View {
        Button {
            assetSelected(asset)
        } label: {
            GeometryReader { proxy in
                let requestPoints = requestSide ?? max(proxy.size.width, proxy.size.height)
                let requestPixels = Self.targetPixels(for: requestPoints, scale: displayScale)
                let progress = resolvedNaturalAspectProgress
                let descriptor = MediaRequestDescriptor(
                    assetID: asset.id,
                    updatedAt: asset.thumbnailRevision,
                    derivative: .thumbnail,
                    targetPixels: .init(width: requestPixels, height: requestPixels)
                )
                ImmichThumbnail(
                    descriptor: descriptor,
                    media: media,
                    contentMode: .fit,
                    showsBackground: true,
                    backgroundOpacity: 1 - Double(progress),
                    imageCornerRadius: DesignMetrics.compactCornerRadius * progress,
                    imageScale: TimelineThumbnailGeometry.imageScale(
                        aspectRatio: asset.aspectRatio,
                        containerAspectRatio: proxy.size.width / max(1, proxy.size.height),
                        naturalAspectProgress: progress
                    ),
                    priority: priority,
                    placeholderImage: placeholderImage,
                    didLoad: {
                        media.retainTimelineThumbnail(
                            $0.container,
                            descriptor: descriptor,
                            cacheType: $0.cacheType
                        )
                        imageLoaded($0.image)
                    }
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
                .overlay {
                    if asset.livePhotoVideoID != nil
                        || asset.projectionType != nil
                        || (asset.stack?.assetCount ?? 0) > 1
                    {
                        GeometryReader { overlayGeometry in
                            let thumbnailRect = TimelineThumbnailGeometry.renderedImageRect(
                                in: overlayGeometry.size,
                                aspectRatio: asset.aspectRatio,
                                naturalAspectProgress: progress
                            )
                            TimelineAssetBadgeOverlay(
                                asset: asset,
                                hiddenLivePhotoBadgeAssetID: hiddenLivePhotoBadgeAssetID
                            )
                            .frame(
                                width: thumbnailRect.width,
                                height: thumbnailRect.height,
                                alignment: .bottomLeading
                            )
                            .position(x: thumbnailRect.midX, y: thumbnailRect.midY)
                        }
                    }
                }
                .overlay {
                    if asset.mediaKind == .video {
                        GeometryReader { overlayGeometry in
                            let thumbnailRect = TimelineThumbnailGeometry.renderedImageRect(
                                in: overlayGeometry.size,
                                aspectRatio: asset.aspectRatio,
                                naturalAspectProgress: progress
                            )
                            Text(Self.duration(asset.durationMilliseconds))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.bottom, 3)
                                .frame(
                                    width: thumbnailRect.width,
                                    height: thumbnailRect.height,
                                    alignment: .bottom
                                )
                                .position(x: thumbnailRect.midX, y: thumbnailRect.midY)
                                .shadow(radius: 3)
                        }
                    }
                }
                .onAppear { visibilityChanged(asset.id, descriptor) }
                .onDisappear { visibilityChanged(asset.id, nil) }
                .onScrollVisibilityChange(threshold: 0.5) { visible in
                    viewportChanged(asset, visible)
                }
            }
            .opacity(hiddenReturningThumbnailAssetID == asset.id ? 0 : 1)
        }
        .buttonStyle(.plain)
        .assetViewerTransitionSource(assetID: asset.id, namespace: transitionNamespace)
        .clipped()
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("asset-\(asset.id)")
        .id(asset.id)
    }

    private var accessibilityLabel: String {
        var values = [TimelineCaptureDateFormatting.string(
            from: asset.capturedAt,
            dateStyle: .medium,
            timeStyle: .short
        )]
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

struct TimelineAssetBadgeOverlay: View {
    let asset: TimelineAssetSummary
    var hiddenLivePhotoBadgeAssetID: String?

    static func isVisible(for asset: TimelineAssetSummary) -> Bool {
        asset.livePhotoVideoID != nil
            || asset.projectionType != nil
            || (asset.stack?.assetCount ?? 0) > 1
    }

    var body: some View {
        HStack(spacing: 5) {
            if asset.livePhotoVideoID != nil {
                Image(systemName: "livephoto")
                    .opacity(hiddenLivePhotoBadgeAssetID == asset.id ? 0 : 1)
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
        .padding([.leading, .bottom], 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .shadow(radius: 3)
        .allowsHitTesting(false)
    }
}

nonisolated enum TimelineThumbnailGeometry {
    static func renderedImageRect(
        in containerSize: CGSize,
        aspectRatio: Double,
        fillsContainer: Bool
    ) -> CGRect {
        renderedImageRect(
            in: containerSize,
            aspectRatio: aspectRatio,
            naturalAspectProgress: fillsContainer ? 0 : 1
        )
    }

    static func renderedImageRect(
        in containerSize: CGSize,
        aspectRatio: Double,
        naturalAspectProgress: CGFloat
    ) -> CGRect {
        let container = CGRect(origin: .zero, size: containerSize)
        guard containerSize.width > 0,
              containerSize.height > 0,
              aspectRatio.isFinite,
              aspectRatio > 0
        else { return container }

        let ratio = CGFloat(aspectRatio)
        let containerRatio = containerSize.width / containerSize.height
        let fitted: CGRect
        if ratio > containerRatio {
            let height = containerSize.width / ratio
            fitted = CGRect(
                x: 0,
                y: (containerSize.height - height) / 2,
                width: containerSize.width,
                height: height
            )
        } else {
            let width = containerSize.height * ratio
            fitted = CGRect(
                x: (containerSize.width - width) / 2,
                y: 0,
                width: width,
                height: containerSize.height
            )
        }
        let progress = min(1, max(0, naturalAspectProgress))
        let coverScale = max(
            container.width / fitted.width,
            container.height / fitted.height
        )
        let scale = coverScale + (1 - coverScale) * progress
        let scaledSize = CGSize(
            width: fitted.width * scale,
            height: fitted.height * scale
        )
        let scaled = CGRect(
            x: container.midX - scaledSize.width / 2,
            y: container.midY - scaledSize.height / 2,
            width: scaledSize.width,
            height: scaledSize.height
        )
        return scaled.intersection(container)
    }

    static func imageScale(
        aspectRatio: Double,
        containerAspectRatio: CGFloat = 1,
        naturalAspectProgress: CGFloat
    ) -> CGFloat {
        guard aspectRatio.isFinite,
              aspectRatio > 0,
              containerAspectRatio.isFinite,
              containerAspectRatio > 0
        else { return 1 }
        let ratio = CGFloat(aspectRatio)
        let coverScale = max(
            ratio / containerAspectRatio,
            containerAspectRatio / ratio
        )
        let progress = min(1, max(0, naturalAspectProgress))
        return coverScale + (1 - coverScale) * progress
    }
}
