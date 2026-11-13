import CoreGraphics

nonisolated enum HorizontalPageSwipePolicy {
    static func canBegin(velocityX: CGFloat, velocityY: CGFloat) -> Bool {
        abs(velocityX) > abs(velocityY) * 1.2 && abs(velocityX) > 80
    }

    static func progress(distance: CGFloat, width: CGFloat) -> CGFloat {
        min(max(distance / max(width, 1), 0), 1)
    }

    static func shouldFinish(progress: CGFloat, forwardVelocity: CGFloat) -> Bool {
        progress >= 0.35 || forwardVelocity > 420
    }
}
