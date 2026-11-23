import SwiftUI
import UIKit

nonisolated struct LibraryCardRows {
    let columns: Int
    let itemWidth: CGFloat

    var rowWidth: CGFloat {
        CGFloat(columns) * itemWidth + CGFloat(columns - 1) * LibraryCollectionCardMetrics.spacing
    }

    init(width: CGFloat, preferredColumns: Int?) {
        self.init(availableWidth: width - 32, preferredColumns: preferredColumns)
    }

    init(availableWidth: CGFloat, preferredColumns: Int? = nil) {
        let spacing = LibraryCollectionCardMetrics.spacing
        let available = max(1, availableWidth)
        columns = preferredColumns ?? max(1, Int((available + spacing) / (LibraryCollectionCardMetrics.minimumWidth + spacing)))
        itemWidth = min(LibraryCollectionCardMetrics.maximumWidth, max(1, (available - spacing * CGFloat(columns - 1)) / CGFloat(columns)))
    }

    func rows<Item>(_ newestFirst: [Item]) -> [ArraySlice<Item>] {
        stride(from: 0, to: newestFirst.count, by: columns).reversed().map { start in
            newestFirst[start ..< min(start + columns, newestFirst.count)]
        }
    }

    func openingCount(viewportHeight: CGFloat, rowHeight: CGFloat) -> Int {
        let rowStride = max(1, rowHeight + LibraryCollectionCardMetrics.spacing)
        let rows = Int(ceil(max(1, viewportHeight) / rowStride))
        return max(1, rows * TimelineGridOrder.openingScreenCount * columns)
    }

    func identifiedRows<Item: Identifiable>(_ newestFirst: [Item]) -> [LibraryCardRow<Item>] {
        rows(newestFirst).compactMap { items in
            items.first.map { LibraryCardRow(id: $0.id, items: items) }
        }
    }
}

/// Keep the hub's fixed set of cards mounted during scroll view rubber-banding.
struct LibraryHubCardLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let proposedWidth = proposal.width ?? LibraryCollectionCardMetrics.minimumWidth
        let width = proposedWidth.isFinite ? proposedWidth : LibraryCollectionCardMetrics.minimumWidth
        let layout = LibraryCardRows(availableWidth: width)
        let rowCount = (subviews.count + layout.columns - 1) / layout.columns
        let rowHeight = layout.itemWidth / LibraryCollectionCardMetrics.aspectRatio
        return CGSize(width: width, height: CGFloat(rowCount) * rowHeight
            + CGFloat(max(0, rowCount - 1)) * LibraryCollectionCardMetrics.spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let layout = LibraryCardRows(availableWidth: bounds.width)
        let rowHeight = layout.itemWidth / LibraryCollectionCardMetrics.aspectRatio
        let spacing = LibraryCollectionCardMetrics.spacing
        let cardSize = ProposedViewSize(width: layout.itemWidth, height: rowHeight)

        for (index, card) in subviews.enumerated() {
            let column = index % layout.columns
            let row = index / layout.columns
            let origin = CGPoint(x: bounds.minX + CGFloat(column) * (layout.itemWidth + spacing),
                                 y: bounds.minY + CGFloat(row) * (rowHeight + spacing))
            card.place(at: origin, anchor: .topLeading, proposal: cardSize)
        }
    }
}

nonisolated struct LibraryCardRow<Item: Identifiable>: Identifiable {
    let id: Item.ID
    let items: ArraySlice<Item>
}

struct LibraryCardScroll<Content: View>: View {
    let initialRowID: String
    let alignment: UnitPoint
    let viewportHeight: CGFloat
    let oldestRowID: String?
    let oldestItemID: String?
    let loadOlder: (() async -> Void)?
    @ViewBuilder let content: () -> Content

    @State private var position: ScrollPosition
    @State private var openingEdge = LibraryCardOpeningEdge()
    @State private var visibleRows: Set<String> = []
    @State private var reachedInitialRow = false

    init(initialRowID: String, viewportHeight: CGFloat, alignment: UnitPoint = .bottom, oldestRowID: String? = nil,
         oldestItemID: String? = nil, loadOlder: (() async -> Void)? = nil, @ViewBuilder content: @escaping () -> Content)
    {
        self.initialRowID = initialRowID
        self.viewportHeight = viewportHeight
        self.alignment = alignment
        self.oldestRowID = oldestRowID
        self.oldestItemID = oldestItemID
        self.loadOlder = loadOlder
        self.content = content
        _position = State(initialValue: alignment == .bottom
            ? ScrollPosition(idType: String.self)
            : ScrollPosition(id: initialRowID, anchor: alignment))
    }

    var body: some View {
        ScrollView {
            content()
                // Give short catalogs actual layout space above the newest row.
                // A bottom alignment role creates a changing synthetic top inset.
                .frame(minHeight: alignment == .bottom ? viewportHeight : nil, alignment: alignment == .bottom ? .bottom : .top)
                .background {
                    if alignment == .bottom {
                        LibraryCardScrollAnchor(openingEdge: openingEdge)
                    }
                }
        }
        .defaultScrollAnchor(alignment, for: .initialOffset)
        .scrollPosition($position, anchor: alignment)
        .onScrollGeometryChange(for: LibraryCardOpeningGeometry.self) { geometry in
            LibraryCardOpeningGeometry(geometry)
        } action: { _, _ in
            if alignment == .bottom {
                openingEdge.scheduleLatestAlignment()
            }
        }
        .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.15) { ids in
            guard loadOlder != nil else { return }
            let rows = Set(ids)
            if visibleRows != rows {
                visibleRows = rows
            }
            if !reachedInitialRow, rows.contains(initialRowID) {
                reachedInitialRow = true
            }
        }
        .onChange(of: pagingID) { _, id in
            guard id != nil, let loadOlder else { return }
            // Once requested, finish the page if the user scrolls away.
            Task { await loadOlder() }
        }
        .onScrollPhaseChange { _, phase in
            if phase == .interacting || phase == .animating {
                openingEdge.release()
            }
        }
    }

    private var pagingID: String? {
        guard reachedInitialRow, let oldestRowID, visibleRows.contains(oldestRowID) else { return nil }
        return oldestItemID
    }
}

private struct LibraryCardScrollAnchor: UIViewRepresentable {
    let openingEdge: LibraryCardOpeningEdge

    func makeUIView(context _: Context) -> LibraryCardScrollAnchorView {
        let view = LibraryCardScrollAnchorView()
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.openingEdge = openingEdge
        openingEdge.anchor = view
        return view
    }

    func updateUIView(_ view: LibraryCardScrollAnchorView, context _: Context) {
        view.openingEdge = openingEdge
        openingEdge.anchor = view
    }
}

private final class LibraryCardScrollAnchorView: UIView {
    weak var openingEdge: LibraryCardOpeningEdge?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            openingEdge?.scheduleLatestAlignment()
        }
    }
}

nonisolated enum LibraryCardScrollOffset {
    static func latest(contentHeight: CGFloat, boundsHeight: CGFloat, topInset: CGFloat, bottomInset: CGFloat) -> CGFloat {
        max(-topInset, contentHeight - boundsHeight + bottomInset)
    }
}

@MainActor
private final class LibraryCardOpeningEdge {
    weak var anchor: UIView?
    private var released = false
    private var alignmentScheduled = false

    func scheduleLatestAlignment() {
        guard !released, !alignmentScheduled else { return }
        alignmentScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            alignmentScheduled = false
            keepLatestVisible()
        }
    }

    private func keepLatestVisible() {
        guard !released, let anchor, anchor.window != nil else { return }
        var ancestor = anchor.superview
        while let view = ancestor, !(view is UIScrollView) {
            ancestor = view.superview
        }
        guard let scroll = ancestor as? UIScrollView, scroll.bounds.height > 0, scroll.contentSize.height > 0 else { return }
        if scroll.isDragging || scroll.isDecelerating {
            release()
        }
        guard !released, !scroll.isTracking else { return }
        let insets = scroll.adjustedContentInset
        let offset = scroll.contentOffset
        let y = LibraryCardScrollOffset.latest(contentHeight: scroll.contentSize.height, boundsHeight: scroll.bounds.height,
                                               topInset: insets.top, bottomInset: insets.bottom)
        guard abs(y - offset.y) > 0.5 else { return }
        scroll.setContentOffset(CGPoint(x: offset.x, y: y), animated: false)
    }

    func release() {
        released = true
    }
}

private nonisolated struct LibraryCardOpeningGeometry: Equatable {
    let contentHeight: CGFloat
    let width: CGFloat
    let height: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat

    init(_ geometry: ScrollGeometry) {
        contentHeight = geometry.contentSize.height.rounded()
        width = geometry.containerSize.width.rounded()
        height = geometry.containerSize.height.rounded()
        topInset = geometry.contentInsets.top.rounded()
        bottomInset = geometry.contentInsets.bottom.rounded()
    }
}
