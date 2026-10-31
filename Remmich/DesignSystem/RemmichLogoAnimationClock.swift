import Foundation

/// One clock owns the logo's phase. Repeated appearance and playback callbacks are idempotent.
nonisolated struct RemmichLogoAnimationClock {
    private var compositionID: String?
    private var accumulated: TimeInterval = 0
    private var resumedAt: TimeInterval?

    mutating func update(compositionID: String, isRunning: Bool, at now: TimeInterval) {
        if self.compositionID != compositionID {
            self.compositionID = compositionID
            accumulated = 0
            resumedAt = nil
        }
        if isRunning {
            if resumedAt == nil {
                resumedAt = now
            }
        } else if let start = resumedAt {
            accumulated += max(0, now - start)
            resumedAt = nil
        }
    }

    func elapsed(compositionID: String, at now: TimeInterval) -> TimeInterval {
        guard self.compositionID == compositionID else { return 0 }
        return accumulated + (resumedAt.map { max(0, now - $0) } ?? 0)
    }
}
