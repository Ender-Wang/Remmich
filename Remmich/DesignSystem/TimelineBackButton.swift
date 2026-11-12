import SwiftUI
import UIKit

/// Toolbar content must own its recognizers; a toolbar Button's primary action
/// can otherwise run without SwiftUI's attached long-press gesture recognizing.
/// Its toolbar item must hide the shared background: this view owns its glass.
struct TimelineBackButton: View {
    let identifier: String
    let back: () -> Void
    let returnToTimeline: () -> Void

    var body: some View {
        Image(systemName: "chevron.backward")
            .font(.title3.weight(.semibold))
            .frame(width: 44, height: 44)
            .overlay {
                TimelineBackGestureSurface(back: back, returnToTimeline: returnToTimeline)
            }
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Back")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier(identifier)
            .accessibilityAction { back() }
            .accessibilityAction(named: "Return to Timeline", returnToTimeline)
    }
}

struct TimelineBackGestureSurface: UIViewRepresentable {
    let back: () -> Void
    let returnToTimeline: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(back: back, returnToTimeline: returnToTimeline)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.held(_:)))
        hold.minimumPressDuration = 0.35
        hold.name = "timeline-back-long-press"
        hold.cancelsTouchesInView = true
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.name = "timeline-back-tap"
        tap.cancelsTouchesInView = true
        tap.require(toFail: hold)
        view.addGestureRecognizer(hold)
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_: UIView, context: Context) {
        context.coordinator.back = back
        context.coordinator.returnToTimeline = returnToTimeline
    }

    @MainActor
    final class Coordinator: NSObject {
        var back: () -> Void
        var returnToTimeline: () -> Void

        init(back: @escaping () -> Void, returnToTimeline: @escaping () -> Void) {
            self.back = back
            self.returnToTimeline = returnToTimeline
        }

        @objc func tapped(_ recognizer: UIGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            back()
        }

        @objc func held(_ recognizer: UIGestureRecognizer) {
            guard recognizer.state == .began else { return }
            returnToTimeline()
        }
    }
}
