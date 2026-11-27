import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

extension View {
    func cardNavigationSource(id: some Hashable, in namespace: Namespace.ID, cornerRadius: CGFloat = DesignMetrics.defaultCornerRadius) -> some View {
        matchedTransitionSource(id: id, in: namespace) { source in
            source.clipShape(.rect(cornerRadius: cornerRadius))
        }
    }

    func cardNavigationDestination(id: some Hashable, in namespace: Namespace.ID) -> some View {
        background(CardPinchBoundary())
            .navigationTransition(.zoom(sourceID: id, in: namespace))
    }

    func cardNavigationBack(path: Binding<NavigationPath>) -> some View {
        environment(\.cardBackAction, CardNavigationBackAction(path: path))
    }
}

struct CardNavigationBackAction {
    let path: Binding<NavigationPath>

    func callAsFunction() {
        guard !path.wrappedValue.isEmpty else { return }
        withAnimation { path.wrappedValue.removeLast() }
    }
}

extension EnvironmentValues {
    @Entry var cardBackAction: CardNavigationBackAction?
}

private struct CardPinchBoundary: UIViewRepresentable {
    func makeUIView(context _: Context) -> Anchor {
        Anchor()
    }

    func updateUIView(_: Anchor, context _: Context) {}

    static func dismantleUIView(_ view: Anchor, coordinator _: ()) {
        view.detach()
    }

    final class Anchor: UIView {
        private let pinch = CardZoomPinchGuard()

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            guard let window else { return }
            pinch.anchor = self
            window.addGestureRecognizer(pinch)
        }

        func detach() {
            pinch.restoreDismissal()
            pinch.view?.removeGestureRecognizer(pinch)
            pinch.anchor = nil
        }
    }
}

private final class CardZoomPinchGuard: UIGestureRecognizer {
    weak var anchor: UIView?
    private var suppressed: [UIGestureRecognizer] = []

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func canPrevent(_: UIGestureRecognizer) -> Bool {
        false
    }

    override func canBePrevented(by _: UIGestureRecognizer) -> Bool {
        false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        suppressDismissal(in: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        if suppressed.isEmpty {
            suppressDismissal(in: event)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        finishIfReleased(event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        finishIfReleased(event)
    }

    override func reset() {
        super.reset()
        restoreDismissal()
    }

    func restoreDismissal() {
        for recognizer in suppressed {
            recognizer.isEnabled = true
        }
        suppressed.removeAll()
    }

    private func suppressDismissal(in event: UIEvent) {
        guard let anchor, anchor.window === view else { return }
        let touches = liveTouches(event)
        guard touches.count >= 2 else { return }
        // The device trace found this UIKit recognizer on the touches before
        // the interactive zoom began. The scroll and swipe recognizers are separate.
        let transforms = touches.flatMap { $0.gestureRecognizers ?? [] }.filter {
            String(describing: type(of: $0)) == "_UITransformGestureRecognizer"
        }
        for recognizer in transforms where recognizer.isEnabled {
            guard let host = recognizer.view, anchor.isDescendant(of: host) else { continue }
            if !suppressed.contains(where: { $0 === recognizer }) {
                suppressed.append(recognizer)
            }
            recognizer.isEnabled = false
        }
    }

    private func finishIfReleased(_ event: UIEvent) {
        if liveTouches(event).isEmpty {
            restoreDismissal()
            state = .failed
        }
    }

    private func liveTouches(_ event: UIEvent) -> [UITouch] {
        (event.allTouches ?? []).filter { $0.window === view && $0.phase != .ended && $0.phase != .cancelled }
    }
}

/// UIKit can already be back at the list while SwiftUI still holds a detail in its bound path.
final class CardNavigationRoot {
    weak var anchor: UIViewController?

    var transitionCoordinator: (any UIViewControllerTransitionCoordinator)? {
        anchor?.navigationController?.transitionCoordinator
    }

    var isSettledRoot: Bool {
        guard let anchor, let view = anchor.viewIfLoaded, view.window != nil,
              let navigation = anchor.navigationController, navigation.transitionCoordinator == nil,
              navigation.viewControllers.count == 1, let controller = navigation.viewControllers.first,
              navigation.visibleViewController === controller, let root = controller.viewIfLoaded
        else { return false }
        return view.isDescendant(of: root)
    }
}

struct CardNavigationRootAnchor: UIViewControllerRepresentable {
    let root: CardNavigationRoot
    var didAppear: (() -> Void)?

    func makeUIViewController(context _: Context) -> Observer {
        let controller = Observer()
        controller.didAppear = didAppear
        root.anchor = controller
        return controller
    }

    func updateUIViewController(_ controller: Observer, context _: Context) {
        root.anchor = controller
        controller.didAppear = didAppear
    }

    final class Observer: UIViewController {
        var didAppear: (() -> Void)?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            didAppear?()
        }
    }
}
