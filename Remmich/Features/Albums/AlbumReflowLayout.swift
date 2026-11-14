import SwiftUI

/// Both modes use exact rectangles in one stable album identity tree.
/// The scroll extent follows the same progress as the item rectangles.
nonisolated struct AlbumReflowMetrics: Equatable {
    let width: CGFloat
    let columns: Int
    let coverWidth: CGFloat
    let labelHeight: CGFloat

    var cardHeight: CGFloat {
        coverWidth * 0.75 + 8 + labelHeight
    }

    var listHeight: CGFloat {
        max(72, labelHeight)
    }

    func itemSize(progress: CGFloat) -> CGSize {
        CGSize(width: interpolate(coverWidth, width, progress), height: interpolate(cardHeight, listHeight, progress))
    }

    /// Read the current presentation from the same item-size samples that drive
    /// native anchoring, so a second pinch can interrupt a settling transition.
    func progress(for size: CGSize) -> CGFloat? {
        let span = listHeight - cardHeight
        guard size.height.isFinite, abs(span) > 0.5 else { return nil }
        return min(1, max(0, (size.height - cardHeight) / span))
    }

    func height(count: Int, list: Bool) -> CGFloat {
        guard count > 0 else { return 0 }
        let rows = list ? count : (count + columns - 1) / columns
        return CGFloat(rows) * (list ? listHeight : cardHeight) + CGFloat(rows - 1) * (list ? 12 : 20)
    }

    func height(count: Int, progress: CGFloat) -> CGFloat {
        interpolate(height(count: count, list: false), height(count: count, list: true), progress)
    }

    func frame(at index: Int, count: Int, list: Bool) -> CGRect {
        if list {
            return CGRect(x: 0, y: CGFloat(index) * (listHeight + 12), width: width, height: listHeight)
        }
        let row = index / columns
        let rowCount = min(columns, count - row * columns)
        // Match gridOrder without changing the ForEach order between modes.
        let column = rowCount - 1 - index % columns
        return CGRect(x: CGFloat(column) * (coverWidth + 16), y: CGFloat(row) * (cardHeight + 20),
                      width: coverWidth, height: cardHeight)
    }

    func frame(at index: Int, count: Int, progress: CGFloat) -> CGRect {
        let card = frame(at: index, count: count, list: false)
        let list = frame(at: index, count: count, list: true)
        return CGRect(x: interpolate(card.minX, list.minX, progress), y: interpolate(card.minY, list.minY, progress),
                      width: interpolate(card.width, list.width, progress), height: interpolate(card.height, list.height, progress))
    }

    private func interpolate(_ start: CGFloat, _ end: CGFloat, _ progress: CGFloat) -> CGFloat {
        start + (end - start) * min(1, max(0, progress))
    }
}

nonisolated struct AlbumReflowLayout: Layout {
    var progress: CGFloat
    let metrics: AlbumReflowMetrics

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        CGSize(width: metrics.width, height: metrics.height(count: subviews.count, progress: progress))
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        for index in subviews.indices {
            let frame = metrics.frame(at: index, count: subviews.count, progress: progress)
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                  anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}

/// Register the grid-local transaction completion once per request without
/// publishing state from the transaction observer.
@MainActor
final class AlbumReflowCompletion {
    private var registeredGeneration = 0

    func claim(_ generation: Int) -> Bool {
        guard generation > registeredGeneration else { return false }
        registeredGeneration = generation
        return true
    }
}

nonisolated struct AlbumReflowAnchor: Equatable {
    let albumID: String
    let unitY: CGFloat
    let itemFrame: CGRect
    let viewportFrame: CGRect
    var focus: AlbumReflowFocus?

    func alignment(for height: CGFloat) -> CGFloat {
        guard let focus, height.isFinite, height > 0 else { return unitY }
        let space = viewportFrame.height - height
        guard space > 0.5 else { return 0.5 }
        // A native ID scroll aligns the same fraction of the item and viewport.
        // Vary that fraction to hold the original point inside the pinched album
        // under its viewport location as the album's height changes.
        // UnitPoint supports positions outside 0...1. Keep those fractions for
        // partially visible albums; the scroll view owns actual range clamping.
        return (focus.viewportUnitY * viewportFrame.height - focus.itemUnitY * height) / space
    }
}

nonisolated struct AlbumReflowFocus: Equatable {
    let viewportUnitY: CGFloat
    let itemUnitY: CGFloat
}

nonisolated struct AlbumReflowItemGeometry: Equatable {
    let frame: CGRect
    let size: CGSize
}

/// Current viewport context, shared across modes rather than saved per mode.
/// Geometry writes do not invalidate SwiftUI's view graph.
@MainActor
final class AlbumReflowViewport {
    var frame = CGRect.zero
    var visibleHeight: CGFloat = 0
    var items: [String: CGRect] = [:]
    private var motionAnchor: AlbumReflowAnchor?
    private var motionGeneration = 0
    private var destinationSize: CGSize?
    private var sampledSize = CGSize.zero

    var usableFrame: CGRect {
        guard frame.height > 0, visibleHeight > 0 else { return .zero }
        // Albums reserves only a top scroll-content margin. The remaining
        // container is bottom-aligned within the ScrollView's measured frame.
        let height = min(frame.height, visibleHeight)
        return CGRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
    }

    func anchor(in albumIDs: [String], at point: CGPoint? = nil) -> AlbumReflowAnchor? {
        let visible = usableFrame
        guard !visible.isEmpty else { return nil }
        if let point {
            guard point.x.isFinite, point.y.isFinite, visible.contains(point) else { return nil }
        }
        let candidates = albumIDs.compactMap { id -> (id: String, frame: CGRect)? in
            guard let item = items[id], item.height > 0, item.intersects(visible) else { return nil }
            return (id, item)
        }
        let fullyVisible = candidates.filter { $0.frame.minY >= visible.minY && $0.frame.maxY <= visible.maxY }
        let pool = point != nil || fullyVisible.isEmpty ? candidates : fullyVisible
        guard let item = pool.min(by: {
            if let point {
                let left = distance(from: point, to: $0.frame)
                let right = distance(from: point, to: $1.frame)
                return left == right ? $0.id < $1.id : left < right
            }
            let left = abs($0.frame.midY - visible.midY)
            let right = abs($1.frame.midY - visible.midY)
            return left == right ? $0.id < $1.id : left < right
        }) else { return nil }
        // Native scroll anchoring aligns the same fractional point of the
        // item and viewport. Solve that equation at the current position.
        let space = visible.height - item.frame.height
        let unitY = space > 0.5 ? min(1, max(0, (item.frame.minY - visible.minY) / space)) : 0.5
        let focus = point.map { point in
            // In a grid gap, use the nearest edge of the selected album. This
            // keeps the first alignment request from moving an existing item.
            let y = min(item.frame.maxY, max(item.frame.minY, point.y))
            return AlbumReflowFocus(viewportUnitY: (y - visible.minY) / visible.height,
                                    itemUnitY: (y - item.frame.minY) / item.frame.height)
        }
        return AlbumReflowAnchor(albumID: item.id, unitY: unitY, itemFrame: item.frame, viewportFrame: visible, focus: focus)
    }

    private func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let x = max(0, max(rect.minX - point.x, point.x - rect.maxX))
        let y = max(0, max(rect.minY - point.y, point.y - rect.maxY))
        return x * x + y * y
    }

    func reset() {
        cancelMotion()
        frame = .zero
        visibleHeight = 0
        items = [:]
    }

    func beginMotion(anchor: AlbumReflowAnchor?, destinationSize: CGSize?, generation: Int) {
        motionAnchor = anchor
        motionGeneration = generation
        self.destinationSize = destinationSize
        sampledSize = anchor?.itemFrame.size ?? .zero
        if let destinationSize, close(sampledSize, destinationSize, tolerance: 0.01) {
            motionAnchor = nil
        }
    }

    func finishInteractiveMotion(destinationSize: CGSize, generation: Int) {
        guard generation >= motionGeneration else { return }
        motionGeneration = generation
        self.destinationSize = destinationSize
        if close(sampledSize, destinationSize, tolerance: 0.25) {
            motionAnchor = nil
        }
    }

    /// Consume before requesting a native scroll. Position-only callbacks do
    /// not advance the plan, and the final size is applied once before release.
    func consumeMotionSample(albumID: String, size: CGSize, generation: Int) -> AlbumReflowAnchor? {
        guard generation == motionGeneration, let anchor = motionAnchor, anchor.albumID == albumID else { return nil }
        // Interactive motion has no destination until release. Reaching an
        // endpoint must keep the anchor alive for a reversal in the same pinch.
        let finished = destinationSize.map { close(size, $0, tolerance: 0.25) } ?? false
        guard finished || !close(size, sampledSize, tolerance: 0.01) else { return nil }
        sampledSize = size
        if finished {
            motionAnchor = nil
        }
        return anchor
    }

    func cancelMotion() {
        motionAnchor = nil
    }

    private func close(_ lhs: CGSize, _ rhs: CGSize, tolerance: CGFloat) -> Bool {
        abs(lhs.width - rhs.width) < tolerance && abs(lhs.height - rhs.height) < tolerance
    }
}
