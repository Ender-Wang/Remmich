import SwiftUI
#if DEBUG
    import OSLog
#endif

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

#if DEBUG
    /// Temporary read-only capture of source movement during return/handoff.
    /// No timers, observed state, or per-frame view invalidation.
    @MainActor
    enum AssetReturnSourceDiagnostics {
        private final class Capture {
            let kind: String
            let initial: CGRect?
            let current: () -> AssetViewerDismissalTarget?
            let appliedOffset: () -> CGSize
            let began = ProcessInfo.processInfo.systemUptime
            var stage = "returning"
            var moves = 0
            var applied = 0

            init(kind: String, target: AssetViewerDismissalTarget?,
                 current: @escaping () -> AssetViewerDismissalTarget?,
                 appliedOffset: @escaping () -> CGSize)
            {
                self.kind = kind
                initial = target?.imageFrame
                self.current = current
                self.appliedOffset = appliedOffset
            }
        }

        private static let logger = Logger(subsystem: "io.github.ender-wang.Remmich", category: "ReturnSource")
        private static var captures: [UUID: Capture] = [:]

        static func begin(id: UUID, kind: String, target: AssetViewerDismissalTarget?,
                          current: @escaping () -> AssetViewerDismissalTarget?,
                          appliedOffset: @escaping () -> CGSize = { .zero })
        {
            captures[id] = Capture(kind: kind, target: target, current: current, appliedOffset: appliedOffset)
            sample(id: id, event: "begin")
        }

        static func sourceMoved(context: String, userScrolling: Bool) {
            for (id, capture) in captures {
                capture.moves += 1
                if capture.moves <= 4 {
                    sample(id: id, event: "source-moved", details: "context=\(context) userScroll=\(userScrolling)")
                }
            }
        }

        static func previewApplied(id: UUID, queuedAt: TimeInterval) {
            guard let capture = captures[id] else { return }
            capture.applied += 1
            if capture.applied <= 4 {
                let lag = Int((ProcessInfo.processInfo.systemUptime - queuedAt) * 1000)
                sample(id: id, event: "preview-offset-applied", details: "queueMs=\(lag)")
            }
        }

        static func handoff(id: UUID) {
            guard let capture = captures[id] else { return }
            capture.stage = "handoff"
            sample(id: id, event: "landed")
        }

        static func end(id: UUID) {
            sample(id: id, event: "removed")
            captures.removeValue(forKey: id)
        }

        private static func sample(id: UUID, event: String, details: String = "") {
            guard let capture = captures[id] else { return }
            let current = capture.current()?.imageFrame
            let initial = capture.initial
            let shift = initial.flatMap { initial in
                current.map { CGSize(width: $0.midX - initial.midX, height: $0.midY - initial.midY) }
            }
            let applied = capture.appliedOffset()
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - capture.began) * 1000)
            let report = "id=\(id.uuidString.prefix(8)) kind=\(capture.kind) event=\(event) stage=\(capture.stage) elapsedMs=\(elapsed) sourceVisible=\(current != nil) sourceShift=\(shift.map { "\(Int($0.width)),\(Int($0.height))" } ?? "unavailable") appliedOffset=\(Int(applied.width)),\(Int(applied.height)) moves=\(capture.moves) applied=\(capture.applied) \(details)"
            logger.debug("Return source diagnostic \(report, privacy: .public)")
        }
    }
#endif
