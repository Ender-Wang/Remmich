import SwiftUI

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

nonisolated struct TimelineDeterministicLayout {
    static let headerHeight: CGFloat = 36

    struct Key: Equatable {
        let width: CGFloat
        let minimumColumnWidth: CGFloat
        let spacing: CGFloat
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
        let anchorAssetID: String?
    }

    static let empty = TimelineDeterministicLayout(
        key: .init(width: 0, minimumColumnWidth: 0, spacing: 0, sectionRevisions: []),
        columns: 1,
        itemSide: 0,
        rows: [],
        assetVerticalCenters: [:],
        totalHeight: 0,
        buildMilliseconds: 0
    )

    let key: Key
    let columns: Int
    let itemSide: CGFloat
    let rows: [Row]
    let assetVerticalCenters: [String: CGFloat]
    let totalHeight: CGFloat
    let buildMilliseconds: Int

    static func build(
        sections: [TimelineSection],
        key: Key
    ) -> TimelineDeterministicLayout {
        guard key.width > 0 else { return .empty }
        let startedAt = ContinuousClock.now
        let columns = TimelineGridOrder.columnCount(
            availableWidth: key.width,
            minimumColumnWidth: key.minimumColumnWidth,
            spacing: key.spacing
        )
        let itemSide = max(1, (key.width - CGFloat(columns - 1) * key.spacing) / CGFloat(columns))
        var rows: [Row] = []
        var assetVerticalCenters: [String: CGFloat] = [:]
        assetVerticalCenters.reserveCapacity(sections.reduce(0) { $0 + $1.assets.count })
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
                    assetHeight: 0,
                    anchorAssetID: nil
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
                    assetHeight: 0,
                    anchorAssetID: nil
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
                    let rowCenter = offset + itemSide / 2
                    for asset in nonempty {
                        assetVerticalCenters[asset.id] = rowCenter
                    }
                    rows.append(Row(
                        id: "row-\(section.id.rawValue)-\(group.id.id)-\(rowIndex)",
                        bucketID: section.id,
                        content: .assets(rowSlots),
                        offset: offset,
                        height: height,
                        assetHeight: itemSide,
                        anchorAssetID: nonempty.isEmpty ? nil : nonempty[nonempty.count / 2].id
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
            assetVerticalCenters: assetVerticalCenters,
            totalHeight: offset,
            buildMilliseconds: elapsedMilliseconds(since: startedAt)
        )
    }

    func verticalCenter(of assetID: String) -> CGFloat? {
        assetVerticalCenters[assetID]
    }

    func rows(intersecting range: ClosedRange<CGFloat>) -> ArraySlice<Row> {
        guard !rows.isEmpty else { return [] }
        let lowerBound = max(0, range.lowerBound)
        let upperBound = min(totalHeight, range.upperBound)

        var lower = 0
        var upper = rows.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if rows[middle].offset + rows[middle].height < lowerBound {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let first = lower

        lower = first
        upper = rows.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if rows[middle].offset <= upperBound {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return rows[first ..< lower]
    }

    func assetNearest(verticalOffset: CGFloat) -> String? {
        guard !rows.isEmpty else { return nil }
        let target = min(max(0, verticalOffset), totalHeight)
        var lower = 0
        var upper = rows.count - 1
        while lower < upper {
            let middle = (lower + upper) / 2
            if rows[middle].offset + rows[middle].height < target {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        if let assetID = rows[lower].anchorAssetID {
            return assetID
        }
        for distance in 1 ..< rows.count {
            let after = lower + distance
            if after < rows.count, let assetID = rows[after].anchorAssetID {
                return assetID
            }
            let before = lower - distance
            if before >= 0, let assetID = rows[before].anchorAssetID {
                return assetID
            }
        }
        return nil
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
    let assets: [TimelineAssetSummary?]
    let media: MediaLibraryController
    let itemSide: CGFloat
    let spacing: CGFloat
    let assetLayout: PhotosAssetLayout
    let visibilityChanged: (String, MediaRequestDescriptor?) -> Void
    let viewportChanged: (TimelineAssetSummary, Bool) -> Void
    let transitionNamespace: Namespace.ID?
    let assetSelected: (TimelineAssetSummary) -> Void

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(Array(assets.enumerated()), id: \.offset) { _, asset in
                if let asset {
                    TimelineAssetThumbnail(
                        asset: asset,
                        media: media,
                        assetLayout: assetLayout,
                        visibilityChanged: visibilityChanged,
                        viewportChanged: viewportChanged,
                        transitionNamespace: transitionNamespace,
                        assetSelected: assetSelected
                    )
                    .frame(width: itemSide, height: itemSide)
                } else {
                    Color.clear
                        .frame(width: itemSide, height: itemSide)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TimelineAssetThumbnail: View {
    @Environment(\.displayScale) private var displayScale
    let asset: TimelineAssetSummary
    let media: MediaLibraryController
    let assetLayout: PhotosAssetLayout
    let visibilityChanged: (String, MediaRequestDescriptor?) -> Void
    let viewportChanged: (TimelineAssetSummary, Bool) -> Void
    let transitionNamespace: Namespace.ID?
    let assetSelected: (TimelineAssetSummary) -> Void

    var body: some View {
        Button {
            assetSelected(asset)
        } label: {
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
        }
        .buttonStyle(.plain)
        .assetViewerTransitionSource(assetID: asset.id, namespace: transitionNamespace)
        .aspectRatio(1, contentMode: .fit)
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
