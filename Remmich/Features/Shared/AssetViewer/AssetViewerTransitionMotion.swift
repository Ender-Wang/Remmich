import OSLog
import SwiftUI
import UIKit

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

/// Temporary, non-observable timing capture: logging must not invalidate the
/// animated view or introduce an additional SwiftUI transaction.
@MainActor
final class AssetViewerGestureDiagnostics {
    private let context: String
    #if DEBUG
        private static let logger = Logger(subsystem: "io.github.ender-wang.Remmich", category: "ViewerGesture")
        private static var returnTouchDeadline: TimeInterval = 0
        private let startedAt = Date.timeIntervalSinceReferenceDate
        private var dragDecisions: Set<String> = []
    #endif

    init(context: String) {
        self.context = context
    }

    func record(_ event: String, assetID: String, details: String = "") {
        #if DEBUG
            let source = context
            let elapsed = Int((Date.timeIntervalSinceReferenceDate - startedAt) * 1000)
            Self.logger.debug("Viewer gesture diagnostic context=\(source, privacy: .public) event=\(event, privacy: .public) asset=\(String(assetID.prefix(8)), privacy: .public) elapsedMs=\(elapsed) \(details, privacy: .public)")
        #endif
    }

    func dragChanged(assetID: String, decision: String, translation: CGSize) {
        #if DEBUG
            guard dragDecisions.insert(decision).inserted else { return }
            record("drag-changed", assetID: assetID,
                   details: "decision=\(decision) dx=\(Int(translation.width)) dy=\(Int(translation.height))")
        #endif
    }

    func dragEnded(assetID: String, decision: String, translation: CGSize, predictedEnd: CGSize) {
        #if DEBUG
            record("drag-ended", assetID: assetID,
                   details: "decision=\(decision) dx=\(Int(translation.width)) dy=\(Int(translation.height)) predictedY=\(Int(predictedEnd.height))")
            dragDecisions.removeAll()
        #endif
    }

    static func traceReturn(_ event: String, assetID: String = "", details: String = "", beginsReturn: Bool = false) {
        #if DEBUG
            let now = ProcessInfo.processInfo.systemUptime
            if beginsReturn {
                returnTouchDeadline = now + 3
            }
            logger.debug("Viewer return diagnostic event=\(event, privacy: .public) asset=\(String(assetID.prefix(8)), privacy: .public) uptimeMs=\(Int(now * 1000)) \(details, privacy: .public)")
        #endif
    }

    #if DEBUG
        static var isTracingReturnTouches: Bool {
            ProcessInfo.processInfo.systemUptime < returnTouchDeadline
        }
    #endif
}

#if DEBUG
    /// Observes touch routing without recognizing, delaying, or cancelling a
    /// gesture. The delegate always rejects the probe's own recognizer.
    struct AssetViewerReturnTouchProbe: UIViewRepresentable {
        let active: Bool
        let describe: (UITouch) -> String

        func makeUIView(context _: Context) -> Receiver {
            Receiver()
        }

        func updateUIView(_ view: Receiver, context _: Context) {
            view.active = active
            view.describe = describe
        }

        static func dismantleUIView(_ view: Receiver, coordinator _: ()) {
            view.detach()
        }

        final class Receiver: UIView, UIGestureRecognizerDelegate {
            var active = false
            var describe: (UITouch) -> String = { _ in "" }
            private let observer = UITapGestureRecognizer()

            override init(frame: CGRect) {
                super.init(frame: frame)
                isUserInteractionEnabled = false
                observer.delegate = self
                observer.cancelsTouchesInView = false
                observer.delaysTouchesBegan = false
                observer.delaysTouchesEnded = false
            }

            @available(*, unavailable)
            required init?(coder _: NSCoder) {
                fatalError("init(coder:) has not been implemented")
            }

            override func didMoveToWindow() {
                super.didMoveToWindow()
                detach()
                window?.addGestureRecognizer(observer)
            }

            func detach() {
                observer.view?.removeGestureRecognizer(observer)
            }

            func gestureRecognizer(_: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
                if active, AssetViewerGestureDiagnostics.isTracingReturnTouches {
                    var view = touch.view
                    var ancestry: [String] = []
                    while let current = view, ancestry.count < 6 {
                        ancestry.append(String(describing: type(of: current)))
                        view = current.superview
                    }
                    AssetViewerGestureDiagnostics.traceReturn("touch-began", details: "hit=\(ancestry.joined(separator: ">")) \(describe(touch))")
                }
                return false
            }
        }
    }
#endif

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
