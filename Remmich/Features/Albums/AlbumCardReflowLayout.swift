import SwiftUI

/// The cover has one identity. Both label representations keep their endpoint
/// proposals while their shared center moves, avoiding mid-motion text reflow.
nonisolated struct AlbumCardReflowLayout: Layout {
    var progress: CGFloat
    let coverWidth: CGFloat
    let listWidth: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard subviews.count == 4 else { return .zero }
        let endpoints = endpoints(subviews)
        return CGSize(width: mix(coverWidth, listWidth),
                      height: mix(coverWidth * 0.75 + 8 + endpoints.cardLabels.height, endpoints.listHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        guard subviews.count == 4 else { return }
        let endpoints = endpoints(subviews)
        let coverSize = CGSize(width: mix(coverWidth, 72), height: mix(coverWidth * 0.75, 72))
        let coverY = mix(0, (endpoints.listHeight - 72) / 2)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + coverY), anchor: .topLeading,
                          proposal: ProposedViewSize(coverSize))

        let cardCenter = CGPoint(x: coverWidth / 2, y: coverWidth * 0.75 + 8 + endpoints.cardLabels.height / 2)
        let listCenter = CGPoint(x: 72 + 12 + endpoints.listLabels.width / 2, y: endpoints.listHeight / 2)
        let labelCenter = CGPoint(x: bounds.minX + mix(cardCenter.x, listCenter.x),
                                  y: bounds.minY + mix(cardCenter.y, listCenter.y))
        // Fixed endpoint widths are essential: changing a Text proposal each
        // frame would reintroduce discrete line-break jumps during the blend.
        subviews[1].place(at: labelCenter, anchor: .center, proposal: ProposedViewSize(endpoints.cardLabels))
        subviews[2].place(at: labelCenter, anchor: .center, proposal: ProposedViewSize(endpoints.listLabels))
        let chevronCenter = CGPoint(x: bounds.minX + mix(coverWidth, listWidth) - endpoints.chevron.width / 2,
                                    y: bounds.minY + mix(cardCenter.y, endpoints.listHeight / 2))
        subviews[3].place(at: chevronCenter, anchor: .center, proposal: ProposedViewSize(endpoints.chevron))
    }

    private func endpoints(_ subviews: Subviews) -> (cardLabels: CGSize, listLabels: CGSize, chevron: CGSize, listHeight: CGFloat) {
        let chevron = subviews[3].sizeThatFits(.unspecified)
        let labelWidth = max(1, listWidth - 72 - 24 - chevron.width)
        let card = subviews[1].sizeThatFits(ProposedViewSize(width: coverWidth, height: nil))
        let list = subviews[2].sizeThatFits(ProposedViewSize(width: labelWidth, height: nil))
        return (CGSize(width: coverWidth, height: card.height), CGSize(width: labelWidth, height: list.height),
                chevron, max(72, list.height))
    }

    private func mix(_ start: CGFloat, _ end: CGFloat) -> CGFloat {
        start + (end - start) * min(1, max(0, progress))
    }
}
