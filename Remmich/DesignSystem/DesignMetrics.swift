import CoreGraphics
import SwiftUI

nonisolated enum DesignMetrics {
    static let defaultCornerRadius: CGFloat = 18
    static let compactCornerRadius = defaultCornerRadius / 2
    // The artwork includes transparent margins; match the profile's visible logo and layout slot.
    static let brandLogoCanvasSize: CGFloat = 120
    static let brandLogoSlotSize: CGFloat = 92
}

struct MainTabHeaderMetrics: DynamicProperty {
    static let controlSize: CGFloat = 44
    static let segmentedControlMaximumWidth: CGFloat = 360
    static let horizontalPadding: CGFloat = 16
    static let topPadding: CGFloat = 3
    static let bottomPadding: CGFloat = 8

    @ScaledMetric(relativeTo: .body) private var textHeight: CGFloat = 24

    var rowHeight: CGFloat {
        max(Self.controlSize, textHeight + 12)
    }

    var controlTopPadding: CGFloat {
        Self.topPadding + (rowHeight - Self.controlSize) / 2
    }

    var height: CGFloat {
        Self.topPadding + rowHeight + Self.bottomPadding
    }
}
