import SwiftUI

/// Shared motion for timeline asset expansion and its return to the source cell.
nonisolated enum AssetViewerTransitionMotion {
    static let openingDuration: TimeInterval = 0.30
    static let openingBounce = 0.18
    static let returnDuration: TimeInterval = 0.24
    static let returnBounce = 0.0

    static var opening: Animation {
        .spring(duration: openingDuration, bounce: openingBounce)
    }

    static var returning: Animation {
        .spring(duration: returnDuration, bounce: returnBounce)
    }

    static var reducedMotion: Animation {
        .easeOut(duration: 0.15)
    }
}

/// Clamp rendered spring samples, rather than only the model endpoints.
struct AssetViewerTransitionOpacity: AnimatableModifier {
    var value: Double

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    func body(content: Content) -> some View {
        content.opacity(min(1, max(0, value)))
    }
}
