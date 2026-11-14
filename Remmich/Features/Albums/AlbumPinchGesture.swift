import Observation
import SwiftUI
import UIKit

/// Logarithmic spacing gives reciprocal inward/outward pinches the same path.
/// A mode is selected only on release, so every intermediate step is reversible.
nonisolated struct AlbumPinchSession {
    let startsAsList: Bool
    let initialProgress: CGFloat
    private(set) var progress: CGFloat

    init(startsAsList: Bool, progress: CGFloat? = nil) {
        self.startsAsList = startsAsList
        let initial = progress.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil } ?? (startsAsList ? 1 : 0)
        initialProgress = initial
        self.progress = initial
    }

    mutating func update(magnification: CGFloat) -> CGFloat? {
        guard magnification.isFinite, magnification > 0 else { return nil }
        let next = min(1, max(0, initialProgress - log(magnification) / log(1.35)))
        guard next != progress else { return nil }
        progress = next
        return next
    }

    func destination(cancelled: Bool) -> Bool {
        cancelled ? startsAsList : progress >= 0.5
    }
}

@MainActor
@Observable
final class AlbumPinchInteraction {
    private(set) var isActive = false
    @ObservationIgnored private(set) var blocksAlbumActivation = false
    @ObservationIgnored private var session: AlbumPinchSession?
    @ObservationIgnored private var anchor: AlbumReflowAnchor?

    func begin(showsList: Bool, anchor: AlbumReflowAnchor, progress: CGFloat? = nil) {
        guard !isActive else { return }
        session = AlbumPinchSession(startsAsList: showsList, progress: progress)
        self.anchor = anchor
        blocksAlbumActivation = true
        isActive = true
    }

    func update(magnification: CGFloat) -> CGFloat? {
        guard isActive else { return nil }
        return session?.update(magnification: magnification)
    }

    @discardableResult
    func end(cancelled: Bool = false) -> (list: Bool, anchor: AlbumReflowAnchor, progress: CGFloat)? {
        guard isActive, let session, let anchor else { return nil }
        let list = session.destination(cancelled: cancelled)
        self.session = nil
        self.anchor = nil
        isActive = false
        return (list, anchor, session.progress)
    }

    func prepareForNewInput() {
        guard !isActive, blocksAlbumActivation else { return }
        // Pinch completion is not the end of the enclosing touch sequence.
        // Keep its remaining finger's Button action blocked until fresh input.
        blocksAlbumActivation = false
    }
}

/// Attach directly to discovery, without an overlay intercepting album taps.
struct AlbumPinchGesture: UIGestureRecognizerRepresentable {
    let enabled: Bool
    let canBegin: (CGPoint) -> Bool
    let canReceive: (CGPoint) -> Bool
    let newInputBegan: () -> Void
    let update: (UIGestureRecognizer.State, CGFloat, CGPoint) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(converter: converter, canBegin: canBegin, canReceive: canReceive, newInputBegan: newInputBegan)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPinchGestureRecognizer {
        let pinch = UIPinchGestureRecognizer()
        pinch.cancelsTouchesInView = true
        pinch.isEnabled = enabled
        pinch.delegate = context.coordinator
        return pinch
    }

    func updateUIGestureRecognizer(_ pinch: UIPinchGestureRecognizer, context: Context) {
        context.coordinator.converter = context.converter
        context.coordinator.canBegin = canBegin
        context.coordinator.canReceive = canReceive
        context.coordinator.newInputBegan = newInputBegan
        if pinch.isEnabled != enabled {
            pinch.isEnabled = enabled
        }
    }

    func handleUIGestureRecognizerAction(_ pinch: UIPinchGestureRecognizer, context: Context) {
        update(pinch.state, pinch.scale, context.converter.location(in: .global))
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var converter: CoordinateSpaceConverter
        var canBegin: (CGPoint) -> Bool
        var canReceive: (CGPoint) -> Bool
        var newInputBegan: () -> Void

        init(converter: CoordinateSpaceConverter, canBegin: @escaping (CGPoint) -> Bool, canReceive: @escaping (CGPoint) -> Bool,
             newInputBegan: @escaping () -> Void)
        {
            self.converter = converter
            self.canBegin = canBegin
            self.canReceive = canReceive
            self.newInputBegan = newInputBegan
        }

        func gestureRecognizer(_: UIGestureRecognizer, shouldReceive event: UIEvent) -> Bool {
            // This runs before shouldReceive touch/press. A lone newly-down
            // finger starts a fresh sequence; a finger added while a pinching
            // finger is still resting must not re-enable album activation.
            if let touches = event.allTouches, touches.count == 1, touches.first?.phase == .began {
                newInputBegan()
            } else if let presses = event as? UIPressesEvent, presses.allPresses.contains(where: { $0.phase == .began }) {
                newInputBegan()
            }
            return true
        }

        func gestureRecognizer(_: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // Check each finger, not just their centroid. UIKit's nil view gives
            // window coordinates; the converter maps those to SwiftUI's space.
            let point = converter.convert(globalPoint: touch.location(in: nil), to: .global)
            return canReceive(point)
        }

        func gestureRecognizerShouldBegin(_: UIGestureRecognizer) -> Bool {
            canBegin(converter.location(in: .global))
        }

        func gestureRecognizer(_: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer) -> Bool {
            // SwiftUI's responder recognizer begins on the first album touch,
            // before a two-finger pinch can recognize. Restricting cooperation
            // to pans lets that responder fail the pinch before shouldBegin.
            // Use UIKit's public coexistence contract without private type tests.
            // Eligibility, active-pinch tap guards and scroll suspension still
            // control which album actions may run; page pans allow one touch.
            true
        }
    }
}
