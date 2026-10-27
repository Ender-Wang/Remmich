import CoreGraphics
import Foundation

nonisolated enum TimelineSemanticScale: Int, CaseIterable, Sendable {
    case square, natural, day, week, month, year

    var isAssets: Bool {
        rawValue < Self.day.rawValue
    }

    func adjacent(coarser: Bool) -> Self? {
        Self(rawValue: rawValue + (coarser ? 1 : -1))
    }
}

/// Metadata is indexed once outside the gesture. Every group owns a range in
/// chronological assets; overlap comes from ranges, never from a bucket owner.
final nonisolated class TimelineSemanticCatalog: Sendable {
    struct Group: Sendable {
        let id: String
        let date: Date
        let assets: Range<Int>
        let route: PhotosRangeRoute
    }

    let assets: [TimelineAssetSummary]
    let assetIndexes: [String: Int]
    let groups: [TimelineSemanticScale: [Group]]
    let standardMosaicBlocks: [TimelineSemanticScale: [TimelineRangeMosaicBlockPlan]]
    let landscapeMosaicBlocks: [TimelineSemanticScale: [TimelineRangeMosaicBlockPlan]]

    init(assets source: [TimelineAssetSummary]) {
        var seen = Set<String>()
        assets = source.filter { seen.insert($0.id).inserted }.sorted {
            $0.capturedAt == $1.capturedAt ? $0.id < $1.id : $0.capturedAt < $1.capturedAt
        }
        assetIndexes = Dictionary(uniqueKeysWithValues: assets.enumerated().map { ($0.element.id, $0.offset) })
        var projections: [TimelineSemanticScale: [Group]] = [:]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        for scale in [TimelineSemanticScale.day, .week, .month, .year] {
            if Task.isCancelled {
                break
            }
            var result: [Group] = []
            var lower = 0
            while lower < assets.count {
                if Task.isCancelled {
                    break
                }
                let date = assets[lower].capturedAt
                let interval = calendar.dateInterval(of: scale == .day ? .day : scale == .week ? .weekOfYear : scale == .month ? .month : .year, for: date)!
                // ISO week identity is authoritative, independently of locale.
                let day = TimelineCaptureDay(capturedAt: date)
                let week = TimelineWeekID(day: day)!
                let start = scale == .week ? week.startDate : interval.start
                let end = scale == .week ? start.addingTimeInterval(7 * 86400) : interval.end
                var upper = lower + 1
                while upper < assets.count, assets[upper].capturedAt < end {
                    upper += 1
                }
                let month = calendar.dateComponents([.year, .month], from: date)
                let bucket = TimelineBucketID(rawValue: String(format: "%04d-%02d-01", month.year!, month.month!))
                let route: PhotosRangeRoute
                let id: String
                switch scale {
                case .day:
                    id = "day:\(day.id)"
                    route = .day(bucket, day)
                case .week:
                    id = "week:\(week.id)"
                    // Route ownership is only for existing scoped navigation.
                    let last = calendar.dateComponents([.year, .month], from: end.addingTimeInterval(-1))
                    let owner = TimelineBucketID(rawValue: String(format: "%04d-%02d-01", last.year!, last.month!))
                    route = .week(owner, week, .library)
                case .month:
                    id = "month:\(bucket.rawValue)"
                    route = .month(bucket)
                default:
                    id = "year:\(month.year!)"
                    route = .year(month.year!)
                }
                result.append(Group(id: id, date: start, assets: lower ..< upper, route: route))
                lower = upper
            }
            projections[scale] = result
        }
        groups = projections
        standardMosaicBlocks = projections.mapValues { groups in
            TimelineRangeMosaicPlanner.blocks(keys: groups.map(\.id), layout: .standard)
        }
        landscapeMosaicBlocks = projections.mapValues { groups in
            TimelineRangeMosaicPlanner.blocks(keys: groups.map(\.id), layout: .landscape)
        }
    }

    func mosaicBlocks(at scale: TimelineSemanticScale, layout: TimelineRangeMosaicLayout) -> [TimelineRangeMosaicBlockPlan] {
        switch layout {
        case .standard: standardMosaicBlocks[scale, default: []]
        case .landscape: landscapeMosaicBlocks[scale, default: []]
        }
    }

    func index(containing assetIndex: Int, scale: TimelineSemanticScale) -> Int? {
        if scale.isAssets {
            return assets.indices.contains(assetIndex) ? assetIndex : nil
        }
        let nodes = groups[scale, default: []]
        var low = 0
        var high = nodes.count
        while low < high {
            let middle = (low + high) / 2
            if nodes[middle].assets.upperBound <= assetIndex {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return nodes.indices.contains(low) && nodes[low].assets.contains(assetIndex) ? low : nil
    }

    func count(at scale: TimelineSemanticScale) -> Int {
        scale.isAssets ? assets.count : groups[scale, default: []].count
    }

    func membership(at index: Int, scale: TimelineSemanticScale) -> Range<Int> {
        scale.isAssets ? index ..< index + 1 : groups[scale]![index].assets
    }

    func overlapping(_ range: Range<Int>, scale: TimelineSemanticScale) -> Range<Int>? {
        guard !range.isEmpty,
              let first = index(containing: range.lowerBound, scale: scale),
              let last = index(containing: range.upperBound - 1, scale: scale)
        else { return nil }
        return first ..< last + 1
    }
}

nonisolated struct TimelineSemanticProjection: Sendable {
    struct Item: Sendable {
        let id: String
        let nodeIndex: Int
        let assetRange: Range<Int>
        let frame: CGRect
        let isHeader: Bool
        let isFeatured: Bool
    }

    let scale: TimelineSemanticScale
    let nodeRange: Range<Int>
    let items: [Item]
    let height: CGFloat

    func bottomAligned(minimumHeight: CGFloat) -> Self {
        let padding = max(0, minimumHeight - height)
        guard padding > 0 else { return self }
        return Self(scale: scale, nodeRange: nodeRange, items: items.map {
            Item(id: $0.id, nodeIndex: $0.nodeIndex, assetRange: $0.assetRange,
                 frame: $0.frame.offsetBy(dx: 0, dy: padding), isHeader: $0.isHeader, isFeatured: $0.isFeatured)
        }, height: height + padding)
    }

    /// Only the requested local window is laid out. No global content Y exists.
    static func build(
        catalog: TimelineSemanticCatalog,
        scale: TimelineSemanticScale,
        focusAssetIndex: Int,
        size: CGSize,
        isPhone: Bool,
        dark: Bool,
        requestedRange: Range<Int>? = nil
    ) -> Self {
        let count = catalog.count(at: scale)
        guard count > 0, size.width > 0 else {
            return Self(scale: scale, nodeRange: 0 ..< 0, items: [], height: 0)
        }
        let focus = catalog.index(containing: focusAssetIndex, scale: scale) ?? count - 1
        let radius = scale.isAssets ? 180 : 26
        var range = requestedRange ?? max(0, focus - radius) ..< min(count, focus + radius + 1)
        var items: [Item] = []
        var y: CGFloat = 12
        if scale.isAssets {
            let columns = TimelineGridOrder.timelineColumnCount(
                availableSize: size,
                minimumLandscapeColumnWidth: isPhone ? 88 : 120,
                spacing: 2
            )
            // Align window boundaries to complete rows of the real day, so
            // adding either continuation cannot rearrange existing columns.
            let firstDay = catalog.groups[.day]![catalog.index(containing: range.lowerBound, scale: .day)!]
            let lastDay = catalog.groups[.day]![catalog.index(containing: range.upperBound - 1, scale: .day)!]
            let lowerRows = (firstDay.assets.upperBound - range.lowerBound + columns - 1) / columns
            let upperRows = (lastDay.assets.upperBound - range.upperBound) / columns
            range = max(firstDay.assets.lowerBound, firstDay.assets.upperBound - lowerRows * columns)
                ..< min(lastDay.assets.upperBound, lastDay.assets.upperBound - upperRows * columns)
            let baseSide = (size.width - CGFloat(columns - 1) * 2) / CGFloat(columns)
            let progress: CGFloat = scale == .natural ? 1 : 0
            let inset = TimelineGridMetrics.horizontalInset(
                naturalAspectProgress: progress, isPhone: isPhone, squareInset: 2, isDarkMode: dark
            )
            let side = TimelineGridMetrics.itemWidth(rowWidth: size.width, columns: columns, spacing: 2, horizontalInset: inset)
            var lower = range.lowerBound
            while lower < range.upperBound {
                let dayIndex = catalog.index(containing: lower, scale: .day)!
                let day = catalog.groups[.day]![dayIndex]
                let upper = min(range.upperBound, day.assets.upperBound)
                items.append(Item(id: "header:\(day.id)", nodeIndex: lower, assetRange: day.assets,
                                  frame: CGRect(x: 0, y: y, width: size.width, height: 36), isHeader: true, isFeatured: false))
                y += 36
                let slots = TimelineGridOrder.displaySlots(itemCount: upper - lower, columns: columns)
                for rowStart in stride(from: 0, to: slots.count, by: columns) {
                    for column in 0 ..< columns {
                        guard rowStart + column < slots.count,
                              let reverse = slots[rowStart + column] else { continue }
                        let index = upper - 1 - reverse
                        items.append(Item(id: catalog.assets[index].id, nodeIndex: index, assetRange: index ..< index + 1,
                                          frame: CGRect(x: inset + CGFloat(column) * (side + 2), y: y, width: side, height: baseSide),
                                          isHeader: false, isFeatured: false))
                    }
                    y += baseSide + 2
                }
                lower = upper
            }
        } else {
            let nodes = catalog.groups[scale]!
            let layout = TimelineRangeMosaicLayout.resolved(viewportSize: size)
            let inset = TimelineRangeGridLayout.edgeInset(isPhone: isPhone)
            let spacing = TimelineRangeMosaicPlanner.spacing
            let side = (size.width - inset * 2 - CGFloat(layout.columns - 1) * spacing) / CGFloat(layout.columns)
            // Build membership plans only; geometry is calculated for intersecting blocks.
            let plans = catalog.mosaicBlocks(at: scale, layout: layout)
            let selected = plans.filter { $0.range.overlaps(range) }
            for block in selected {
                for placement in block.placements {
                    let index = block.range.lowerBound + placement.itemIndex
                    let frame = CGRect(
                        x: inset + CGFloat(placement.column) * (side + spacing),
                        y: y + CGFloat(placement.row) * (side + spacing),
                        width: CGFloat(placement.columnSpan) * side + CGFloat(placement.columnSpan - 1) * spacing,
                        height: CGFloat(placement.rowSpan) * side + CGFloat(placement.rowSpan - 1) * spacing
                    )
                    items.append(Item(id: nodes[index].id, nodeIndex: index, assetRange: nodes[index].assets,
                                      frame: frame, isHeader: false, isFeatured: placement.isFeatured))
                }
                let rows = block.placements.map { $0.row + $0.rowSpan }.max() ?? 1
                y += CGFloat(rows) * (side + spacing)
            }
            let actual = selected.first!.range.lowerBound ..< selected.last!.range.upperBound
            return Self(scale: scale, nodeRange: actual, items: items, height: y + 12)
        }
        return Self(scale: scale, nodeRange: range, items: items, height: y + 12)
    }
}

/// Pure gesture state: reversing progress cannot commit a scale until release.
nonisolated struct TimelineSemanticZoomGesture {
    private(set) var coarser: Bool?
    private(set) var progress: CGFloat = 0

    mutating func update(magnification: CGFloat) {
        guard magnification.isFinite, magnification > 0 else { return }
        if coarser == nil {
            if magnification < 0.97 {
                coarser = true
            }
            if magnification > 1.03 {
                coarser = false
            }
        }
        guard let coarser else { return }
        progress = min(1, max(0, coarser ? (1 - magnification) / 0.4 : (magnification - 1) / 0.5))
    }

    func commits(magnification: CGFloat) -> Bool {
        guard let coarser else { return false }
        return coarser ? magnification <= 0.78 : magnification >= 1.28
    }
}
