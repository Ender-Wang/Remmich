import CoreGraphics

nonisolated enum DesignMetrics {
    static let defaultCornerRadius: CGFloat = 18
    static let compactCornerRadius = defaultCornerRadius / 2
    // The artwork includes transparent margins; match the profile's visible logo and layout slot.
    static let brandLogoCanvasSize: CGFloat = 120
    static let brandLogoSlotSize: CGFloat = 92
}
