import SwiftUI
import UIKit

/// Reject vertical intent before recognition so the enclosing ScrollView owns it.
struct IndexSectionPan: UIGestureRecognizerRepresentable {
    let enabled: Bool
    let direction: CGFloat
    let update: (UIGestureRecognizer.State, CGPoint, CGPoint) -> Void

    func makeCoordinator(converter _: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(direction: direction)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        pan.isEnabled = enabled
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ pan: UIPanGestureRecognizer, context: Context) {
        context.coordinator.direction = direction
        if pan.isEnabled != enabled {
            pan.isEnabled = enabled
        }
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context _: Context) {
        update(pan.state, pan.translation(in: pan.view?.window), pan.velocity(in: pan.view?.window))
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var direction: CGFloat
        var startLocation: CGPoint = .zero

        init(direction: CGFloat) {
            self.direction = direction
        }

        func gestureRecognizer(_: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var target = touch.view
            while let view = target {
                if view is UISwitch || view is UISlider {
                    return false
                }
                target = view.superview
            }
            startLocation = touch.location(in: touch.window)
            return true
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view?.window)
            return (startLocation.x >= 32 || velocity.x < 0)
                && HorizontalPageSwipePolicy.canBegin(velocityX: velocity.x, velocityY: velocity.y)
                && velocity.x * direction > 0
        }

        func gestureRecognizer(_: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
