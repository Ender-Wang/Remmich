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
    private var destinationSize = CGSize.zero
    private var sampledSize = CGSize.zero

    func anchor(in albumIDs: [String]) -> AlbumReflowAnchor? {
        guard frame.height > 0, visibleHeight > 0 else { return nil }
        // Albums reserves only a top scroll-content margin. The remaining
        // container is bottom-aligned within the ScrollView's measured frame.
        let height = min(frame.height, visibleHeight)
        let visible = CGRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
        let candidates = albumIDs.compactMap { id -> (id: String, frame: CGRect)? in
            guard let item = items[id], item.height > 0, item.intersects(visible) else { return nil }
            return (id, item)
        }
        let fullyVisible = candidates.filter { $0.frame.minY >= visible.minY && $0.frame.maxY <= visible.maxY }
        let pool = fullyVisible.isEmpty ? candidates : fullyVisible
        guard let item = pool.min(by: {
            let left = abs($0.frame.midY - visible.midY)
            let right = abs($1.frame.midY - visible.midY)
            return left == right ? $0.id < $1.id : left < right
        }) else { return nil }
        // Native scroll anchoring aligns the same fractional point of the
        // item and viewport. Solve that equation at the current position.
        let space = visible.height - item.frame.height
        let unitY = space > 0.5 ? min(1, max(0, (item.frame.minY - visible.minY) / space)) : 0.5
        return AlbumReflowAnchor(albumID: item.id, unitY: unitY, itemFrame: item.frame, viewportFrame: visible)
    }

    func reset() {
        cancelMotion()
        frame = .zero
        visibleHeight = 0
        items = [:]
    }

    func beginMotion(anchor: AlbumReflowAnchor?, destinationSize: CGSize, generation: Int) {
        motionAnchor = anchor
        motionGeneration = generation
        self.destinationSize = destinationSize
        sampledSize = anchor?.itemFrame.size ?? .zero
        if close(sampledSize, destinationSize, tolerance: 0.01) {
            motionAnchor = nil
        }
    }

    /// Consume before requesting a native scroll. Position-only callbacks do
    /// not advance the plan, and the final size is applied once before release.
    func consumeMotionSample(albumID: String, size: CGSize, generation: Int) -> AlbumReflowAnchor? {
        guard generation == motionGeneration, let anchor = motionAnchor, anchor.albumID == albumID else { return nil }
        let finished = close(size, destinationSize, tolerance: 0.25)
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
