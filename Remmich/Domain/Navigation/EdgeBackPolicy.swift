import Foundation

nonisolated enum EdgeBackPolicy {
    static func canBegin(velocityX: Double, velocityY: Double) -> Bool {
        velocityX > 0 && abs(velocityX) > abs(velocityY) * 1.2
    }

    static func progress(translationX: Double, width: Double) -> Double {
        guard width.isFinite, width > 0, translationX.isFinite else { return 0 }
        return min(1, max(0, translationX / width))
    }

    static func shouldFinish(progress: Double, inwardVelocity: Double, cancelled: Bool) -> Bool {
        guard !cancelled, inwardVelocity > -150 else { return false }
        return progress >= 0.33 || (progress >= 0.05 && inwardVelocity >= 700)
    }
}
