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

/// An opening drag owns the hero until both the opening spring and any
/// cancelled drag have settled. A later drag invalidates an earlier cancel.
nonisolated struct AssetViewerOpeningDrag {
    private(set) var isActive = false
    private(set) var isCancelling = false
    private(set) var openingHasSettled = false
    private(set) var translation: CGSize = .zero
    private(set) var generation = 0

    mutating func update(_ translation: CGSize) {
        generation += 1
        isActive = true
        isCancelling = false
        self.translation = CGSize(width: translation.width, height: max(0, translation.height))
    }

    mutating func openingSettled() -> Bool {
        openingHasSettled = true
        return !isActive
    }

    mutating func beginCancellation() -> Int? {
        guard isActive, !isCancelling else { return nil }
        isCancelling = true
        translation = .zero
        return generation
    }

    mutating func finishCancellation(generation: Int) -> Bool {
        guard self.generation == generation, isCancelling else { return false }
        isActive = false
        isCancelling = false
        return openingHasSettled
    }

    mutating func beginReturn() {
        generation += 1
        isCancelling = false
        translation = .zero
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
