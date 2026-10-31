import SwiftUI
import UIKit

struct NativeEdgeBackEvent {
    enum Phase { case began, changed, ended }
    let phase: Phase
    let progress: CGFloat
    let completed: Bool
}

extension View {
    func nativeEdgeBackRoot() -> some View {
        background(NativeEdgeBackAnchor(active: false, canBegin: false, priority: 0, event: { _ in }))
    }

    func nativeEdgeBack(active: Bool = true, canBegin: Bool = true, priority: Int,
                        event: @escaping (NativeEdgeBackEvent) -> Void) -> some View
    {
        background(NativeEdgeBackAnchor(active: active, canBegin: canBegin, priority: priority, event: event))
    }

    func nativeEdgeBackAction(active: Bool, canBegin: Bool = true, priority: Int = 100, action: @escaping () -> Void) -> some View {
        modifier(NativeEdgeBackActionModifier(active: active, canBegin: canBegin, priority: priority, action: action))
    }
}

private struct NativeEdgeBackActionModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let active: Bool
    let canBegin: Bool
    let priority: Int
    let action: () -> Void
    @State private var progress: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(x: reduceMotion ? 0 : progress * 100)
            .opacity(1 - progress * 0.2)
            .nativeEdgeBack(active: active, canBegin: canBegin, priority: priority) { event in
                switch event.phase {
                case .began:
                    break
                case .changed:
                    progress = event.progress
                case .ended:
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) {
                        progress = 0
                        if event.completed {
                            action()
                        }
                    }
                }
            }
    }
}

private struct NativeEdgeBackAnchor: UIViewRepresentable {
    let active: Bool
    let canBegin: Bool
    let priority: Int
    let event: (NativeEdgeBackEvent) -> Void

    func makeUIView(context _: Context) -> NativeEdgeBackReceiver {
        NativeEdgeBackReceiver()
    }

    func updateUIView(_ view: NativeEdgeBackReceiver, context _: Context) {
        view.active = active
        view.canBegin = canBegin
        view.priority = priority
        view.event = event
    }

    static func dismantleUIView(_ view: NativeEdgeBackReceiver, coordinator _: ()) {
        view.detach()
    }
}

private final class NativeEdgeBackReceiver: UIView {
    var active = false
    var canBegin = true
    var priority = 0
    var event: (NativeEdgeBackEvent) -> Void = { _ in }
    weak var router: NativeEdgeBackRouter?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        detach()
        guard let window else { return }
        let router = NativeEdgeBackRouter.router(for: window)
        router.receivers.add(self)
        self.router = router
    }

    func detach() {
        router?.remove(self)
        router = nil
    }
}

@MainActor
private final class NativeEdgeBackRouter: NSObject, UIGestureRecognizerDelegate {
    private static let routers = NSMapTable<UIWindow, NativeEdgeBackRouter>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    static func router(for window: UIWindow) -> NativeEdgeBackRouter {
        if let router = routers.object(forKey: window) {
            return router
        }
        let router = NativeEdgeBackRouter(window: window)
        routers.setObject(router, forKey: window)
        return router
    }

    let receivers = NSHashTable<NativeEdgeBackReceiver>.weakObjects()
    private weak var window: UIWindow?
    private weak var target: NativeEdgeBackReceiver?
    private var navigation: NativeEdgeBackNavigationTransition?
    private weak var pendingNavigationController: UINavigationController?
    private var active = false
    private var recognizers: [UIScreenEdgePanGestureRecognizer] = []

    private init(window: UIWindow) {
        self.window = window
        super.init()
        let recognizer = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(panned(_:)))
        recognizer.edges = .left
        recognizer.delegate = self
        recognizer.maximumNumberOfTouches = 1
        recognizer.name = "RemmichEdgeBackLeft"
        window.addGestureRecognizer(recognizer)
        recognizers.append(recognizer)
        NotificationCenter.default.addObserver(self, selector: #selector(cancel), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(cancel), name: UIDevice.orientationDidChangeNotification, object: nil)
    }

    func remove(_ receiver: NativeEdgeBackReceiver) {
        if target === receiver {
            let event = receiver.event
            target = nil
            cancel()
            // Detachment can happen during SwiftUI reconciliation. Finish state
            // cancellation after that update, rather than mutating it in dismantle.
            Task { @MainActor in
                event(.init(phase: .ended, progress: 0, completed: false))
            }
        }
        receivers.remove(receiver)
        if receivers.allObjects.isEmpty {
            cancel()
        }
    }

    private func presentedRoot() -> UIViewController? {
        guard var root = window?.rootViewController else { return nil }
        while let presented = root.presentedViewController, !presented.isBeingDismissed {
            root = presented
        }
        return root
    }

    private func visible(_ view: UIView) -> Bool {
        guard let window, view.window === window,
              view.convert(view.bounds, to: window).intersects(window.bounds)
        else { return false }
        var candidate: UIView? = view
        while let current = candidate {
            if current.isHidden || current.alpha < 0.01 {
                return false
            }
            candidate = current.superview
        }
        guard let root = presentedRoot(), root.isViewLoaded else { return false }
        return view.isDescendant(of: root.view)
    }

    private func receiver() -> NativeEdgeBackReceiver? {
        receivers.allObjects.filter { $0.active && visible($0) }.max {
            if $0.priority != $1.priority {
                return $0.priority < $1.priority
            }
            return depth($0) < depth($1)
        }
    }

    private func depth(_ view: UIView) -> Int {
        var result = 0
        var current = view.superview
        while let parent = current {
            result += 1; current = parent.superview
        }
        return result
    }

    private func navigationController(in controller: UIViewController?) -> UINavigationController? {
        guard let controller, controller.isViewLoaded, visible(controller.view) else { return nil }
        if let presented = controller.presentedViewController, !presented.isBeingDismissed {
            return navigationController(in: presented)
        }
        if let tabs = controller as? UITabBarController {
            return navigationController(in: tabs.selectedViewController)
        }
        if let nav = controller as? UINavigationController {
            return navigationController(in: nav.visibleViewController) ?? (nav.viewControllers.count > 1 ? nav : nil)
        }
        for child in controller.children.reversed() {
            if let nav = navigationController(in: child) {
                return nav
            }
        }
        return nil
    }

    func gestureRecognizer(_: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view {
            if current is UISlider || current is UITextField || current is UITextView || current is UISwitch {
                return false
            }
            view = current.superview
        }
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard !active, navigation == nil, !receivers.allObjects.isEmpty, let pan = gestureRecognizer as? UIScreenEdgePanGestureRecognizer, let window,
              !(presentedRoot() is UIAlertController), !(presentedRoot() is UIActivityViewController)
        else { return false }
        target = nil
        pendingNavigationController = nil
        let velocity = pan.velocity(in: window)
        guard EdgeBackPolicy.canBegin(velocityX: velocity.x, velocityY: velocity.y) else { return false }
        if let receiver = receiver() {
            guard receiver.canBegin else { return false }
            target = receiver
            return true
        }
        guard receivers.allObjects.contains(where: { visible($0) }),
              let nav = navigationController(in: presentedRoot()), nav.transitionCoordinator == nil
        else { return false }
        // Leave the standard left-edge pop to UIKit. Supply the same interaction only
        // when a hidden/custom navigation bar has disabled that system gesture.
        let nativeLeft = UIView.userInterfaceLayoutDirection(for: nav.view.semanticContentAttribute) != .rightToLeft
        if nativeLeft, !nav.isNavigationBarHidden,
           nav.topViewController?.navigationItem.hidesBackButton != true,
           nav.interactivePopGestureRecognizer?.isEnabled == true
        {
            return false
        }
        pendingNavigationController = nav
        return true
    }

    func gestureRecognizer(_: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool
    {
        !recognizers.contains(where: { $0 === otherGestureRecognizer })
            && !(otherGestureRecognizer is UITapGestureRecognizer)
            && !(otherGestureRecognizer is UILongPressGestureRecognizer)
            && !(otherGestureRecognizer is UIPinchGestureRecognizer)
    }

    @objc private func panned(_ recognizer: UIScreenEdgePanGestureRecognizer) {
        guard let window else { cancel(); return }
        let translation = recognizer.translation(in: window)
        let progress = EdgeBackPolicy.progress(translationX: translation.x, width: window.bounds.width)
        switch recognizer.state {
        case .began:
            active = true
            if let nav = pendingNavigationController {
                pendingNavigationController = nil
                let transition = NativeEdgeBackNavigationTransition(navigationController: nav)
                transition.finished = { [weak self, weak transition] in
                    guard self?.navigation === transition else { return }
                    self?.navigation = nil
                }
                navigation = transition
                if !transition.begin() {
                    navigation = nil; active = false
                }
            } else {
                target?.event(.init(phase: .began, progress: 0, completed: false))
            }
        case .changed:
            guard active else { return }
            navigation?.update(progress)
            target?.event(.init(phase: .changed, progress: progress, completed: false))
        case .ended, .cancelled, .failed:
            guard active else { return }
            let finish = EdgeBackPolicy.shouldFinish(progress: progress,
                                                     inwardVelocity: recognizer.velocity(in: window).x,
                                                     cancelled: recognizer.state != .ended)
            end(completed: finish, progress: progress)
        default: break
        }
    }

    private func end(completed: Bool, progress: CGFloat) {
        active = false
        let target = target
        self.target = nil
        navigation?.end(completed: completed)
        target?.event(.init(phase: .ended, progress: progress, completed: completed))
    }

    @objc private func cancel() {
        pendingNavigationController = nil
        if active {
            end(completed: false, progress: 0)
        }
        navigation?.end(completed: false)
        for recognizer in recognizers {
            recognizer.isEnabled = false; recognizer.isEnabled = true
        }
    }
}

@MainActor
private final class NativeEdgeBackNavigationTransition: NSObject, UINavigationControllerDelegate {
    private weak var navigationController: UINavigationController?
    private var previousDelegate: (any UINavigationControllerDelegate)?
    private let interaction = UIPercentDrivenInteractiveTransition()
    private let animator = NativeEdgeBackPopAnimator()
    private var hasEnded = false
    var finished: (() -> Void)?

    init(navigationController: UINavigationController) {
        self.navigationController = navigationController
    }

    func begin() -> Bool {
        guard let nav = navigationController, nav.viewControllers.count > 1, nav.transitionCoordinator == nil else { return false }
        previousDelegate = nav.delegate
        nav.delegate = self
        interaction.completionCurve = .easeOut
        guard nav.popViewController(animated: true) != nil else { restore(); return false }
        nav.transitionCoordinator?.animate(alongsideTransition: nil) { [weak self] _ in
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.restore()
            }
        }
        return true
    }

    func update(_ progress: CGFloat) {
        interaction.update(progress)
    }

    func end(completed: Bool) {
        guard !hasEnded else { return }
        hasEnded = true
        if completed {
            interaction.finish()
        } else {
            interaction.cancel()
        }
    }

    func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
        previousDelegate?.navigationController?(navigationController, willShow: viewController, animated: animated)
    }

    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        previousDelegate?.navigationController?(navigationController, didShow: viewController, animated: animated)
        restore()
    }

    private func restore() {
        if let nav = navigationController, nav.delegate === self {
            nav.delegate = previousDelegate
        }
        previousDelegate = nil
        let completion = finished
        finished = nil
        completion?()
    }

    func navigationController(_ navigationController: UINavigationController,
                              animationControllerFor operation: UINavigationController.Operation,
                              from fromVC: UIViewController, to toVC: UIViewController) -> (any UIViewControllerAnimatedTransitioning)?
    {
        if operation == .pop {
            return animator
        }
        return previousDelegate?.navigationController?(navigationController, animationControllerFor: operation, from: fromVC, to: toVC)
    }

    func navigationController(_ navigationController: UINavigationController,
                              interactionControllerFor animationController: any UIViewControllerAnimatedTransitioning) -> (any UIViewControllerInteractiveTransitioning)?
    {
        if animationController === animator {
            return interaction
        }
        return previousDelegate?.navigationController?(navigationController, interactionControllerFor: animationController)
    }

    func navigationControllerSupportedInterfaceOrientations(_ navigationController: UINavigationController) -> UIInterfaceOrientationMask {
        previousDelegate?.navigationControllerSupportedInterfaceOrientations?(navigationController)
            ?? navigationController.visibleViewController?.supportedInterfaceOrientations ?? .all
    }

    func navigationControllerPreferredInterfaceOrientationForPresentation(_ navigationController: UINavigationController) -> UIInterfaceOrientation {
        previousDelegate?.navigationControllerPreferredInterfaceOrientationForPresentation?(navigationController)
            ?? navigationController.visibleViewController?.preferredInterfaceOrientationForPresentation ?? .portrait
    }
}

@MainActor
private final class NativeEdgeBackPopAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private var animator: UIViewPropertyAnimator?
    func transitionDuration(using _: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
        0.32
    }

    func animateTransition(using transitionContext: any UIViewControllerContextTransitioning) {
        interruptibleAnimator(using: transitionContext).startAnimation()
    }

    func interruptibleAnimator(using context: any UIViewControllerContextTransitioning) -> any UIViewImplicitlyAnimating {
        if let animator {
            return animator
        }
        guard let from = context.view(forKey: .from), let to = context.view(forKey: .to),
              let toController = context.viewController(forKey: .to)
        else { context.completeTransition(false); return UIViewPropertyAnimator(duration: 0, curve: .linear) }
        let container = context.containerView
        let fromFrame = from.frame
        let toFrame = context.finalFrame(for: toController)
        container.insertSubview(to, belowSubview: from)
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        to.frame = reduceMotion ? toFrame : toFrame.offsetBy(dx: -container.bounds.width * 0.3, dy: 0)
        to.alpha = reduceMotion ? 0 : 1
        let animator = UIViewPropertyAnimator(duration: 0.32, curve: .easeOut) {
            to.frame = toFrame
            to.alpha = 1
            if reduceMotion {
                from.alpha = 0
            } else {
                from.frame = fromFrame.offsetBy(dx: container.bounds.width, dy: 0)
            }
        }
        animator.addCompletion { _ in
            from.frame = fromFrame
            from.alpha = 1
            to.frame = toFrame
            to.alpha = 1
            context.completeTransition(!context.transitionWasCancelled)
        }
        self.animator = animator
        return animator
    }

    func animationEnded(_: Bool) {
        animator = nil
    }
}
