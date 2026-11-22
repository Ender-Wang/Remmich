import SwiftUI
import UIKit

extension EnvironmentValues {
    @Entry var libraryCardTitleMotion: LibraryCardTitleMotion?
}

/// The card and navigation bar can belong to different hosting controllers.
/// Use their UIKit label bounds to fly the title alongside the native zoom.
@MainActor
final class LibraryCardTitleMotion {
    private weak var card: LibraryCardTitleLabel?
    private weak var header: LibraryCardTitleLabel?
    private weak var sourceController: UIViewController?
    private weak var window: UIWindow?
    private var openingCard: LabelSnapshot?
    private var windowSize: CGSize?
    private var flight: UIView?
    private var animator: UIViewPropertyAnimator?
    private var animationGeneration = 0
    private var coordinatingOpening = false
    private var waitingForHeader = false
    private var hasPresented = false
    private var registeredNavigation = false

    func register(_ label: LibraryCardTitleLabel) {
        guard label.window != nil else { return }
        switch label.endpoint {
        case .card: card = label
        case .header: header = label
        }
        updateVisibility()
    }

    func prepareOpen() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        captureCard()
        guard openingCard != nil else { return }
        waitingForHeader = true
    }

    private func captureCard() {
        guard let card, card.motion === self, let window = card.window, !card.bounds.isEmpty else { return }
        self.window = window
        windowSize = window.bounds.size
        openingCard = LabelSnapshot(card, in: window)
        var responder: UIResponder? = card
        while let current = responder {
            if let controller = current as? UIViewController, let navigation = controller.navigationController,
               let page = navigation.viewControllers.first(where: { page in
                   page.isViewLoaded && card.isDescendant(of: page.view)
               })
            {
                sourceController = page
                break
            }
            responder = current.next
        }
    }

    func navigationWillAppear(_ coordinator: (any UIViewControllerTransitionCoordinator)?) {
        guard !hasPresented else { return }
        hasPresented = true
        if openingCard == nil {
            prepareOpen()
        }
        if let coordinator, coordinator.transitionDuration > 0, let window, let openingCard {
            coordinateOpening(coordinator, from: openingCard, in: window)
        } else {
            headerDidLayout()
        }
    }

    private func coordinateOpening(
        _ coordinator: any UIViewControllerTransitionCoordinator,
        from start: LabelSnapshot,
        in window: UIWindow
    ) {
        stopTitleAnimation()
        coordinatingOpening = true
        waitingForHeader = true
        let generation = animationGeneration
        let accepted = coordinator.animateAlongsideTransition(in: window, animation: { [weak self, weak window] _ in
            guard let self, let window, animationGeneration == generation else { return }
            sourceController?.navigationController?.navigationBar.layoutIfNeeded()
            guard let end = snapshot(header, in: window) else {
                coordinatingOpening = false
                headerDidLayout()
                return
            }
            waitingForHeader = false
            move(flight ?? begin(start, in: window), to: end)
        }, completion: { [weak self] context in
            guard let self, animationGeneration == generation, coordinatingOpening else { return }
            if context.isCancelled {
                hasPresented = false
                openingCard = nil
            }
            finish()
        })
        if !accepted {
            coordinatingOpening = false
            waitingForHeader = true
            headerDidLayout()
        }
    }

    func navigationWillDisappear(_ coordinator: (any UIViewControllerTransitionCoordinator)?, isPopping: Bool) {
        guard !registeredNavigation, !UIAccessibility.isReduceMotionEnabled else { return }
        guard let coordinator else {
            if isPopping {
                closeLocal()
                hasPresented = false
                openingCard = nil
            }
            return
        }
        guard let destination = coordinator.viewController(forKey: .to),
              destination === sourceController || card.map({ destination.isViewLoaded && $0.isDescendant(of: destination.view) }) == true,
              let window, let start = snapshot(header, in: window),
              let end = returnSnapshot(in: window) else { return }
        waitingForHeader = false
        stopTitleAnimation()
        let movingTitle = flight ?? begin(start, in: window)
        registeredNavigation = true
        let accepted = coordinator.animateAlongsideTransition(in: window, animation: { [weak self] _ in
            guard let self, flight === movingTitle else { return }
            move(movingTitle, to: end)
        }, completion: { [weak self] context in
            guard let self, registeredNavigation else { return }
            registeredNavigation = false
            if !context.isCancelled {
                hasPresented = false
                openingCard = nil
            }
            finish()
        })
        if !accepted {
            registeredNavigation = false
            closeLocal()
        }
    }

    func headerDidLayout() {
        guard waitingForHeader, !coordinatingOpening, let window, let openingCard, snapshot(header, in: window) != nil else { return }
        waitingForHeader = false
        stopTitleAnimation()
        let generation = animationGeneration
        // The title can be laid out in a SwiftUI transaction with animations disabled.
        // Start the movement on the main actor after this layout pass has returned.
        Task { @MainActor [weak self, weak window] in
            guard let self, let window, animationGeneration == generation,
                  let end = snapshot(header, in: window) else { return }
            animateTitle(flight ?? begin(openingCard, in: window), to: end)
        }
    }

    func closeLocal() {
        let renderedFrame = flight?.layer.presentation()?.frame
        waitingForHeader = false
        stopTitleAnimation()
        guard !UIAccessibility.isReduceMotionEnabled, let window, let end = returnSnapshot(in: window) else {
            finish()
            return
        }
        // When the native zoom reverses before the push completes, the presentation
        // layer can already be at the source even though its model frame is in the header.
        if let renderedFrame, let source = snapshot(card, in: window),
           source.frame.insetBy(dx: -0.5, dy: -0.5).contains(renderedFrame),
           renderedFrame.insetBy(dx: -0.5, dy: -0.5).contains(source.frame),
           end.frame.insetBy(dx: -0.5, dy: -0.5).contains(renderedFrame)
        {
            finish()
            return
        }
        if let flight {
            animateTitle(flight, to: end)
        } else if let start = snapshot(header, in: window) {
            animateTitle(begin(start, in: window), to: end)
        }
    }

    private func returnSnapshot(in window: UIWindow) -> LabelSnapshot? {
        // Live card frames can still carry the zoom transform or the directory's
        // hidden layout. The opening frame was measured in the resting layout.
        windowSize == window.bounds.size ? openingCard : nil
    }

    private func snapshot(_ label: LibraryCardTitleLabel?, in window: UIWindow) -> LabelSnapshot? {
        guard let label, label.motion === self, label.window === window, !label.bounds.isEmpty else { return nil }
        return LabelSnapshot(label, in: window)
    }

    private func begin(_ start: LabelSnapshot, in window: UIWindow) -> UIView {
        let view = UIView(frame: start.frame)
        view.addSubview(start.label(in: view.bounds))
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        UIView.performWithoutAnimation {
            window.addSubview(view)
            flight = view
            updateVisibility()
        }
        return view
    }

    private func move(_ view: UIView, to end: LabelSnapshot) {
        let previous = view.subviews
        let label = end.label(in: view.bounds)
        label.alpha = 0
        view.addSubview(label)
        view.frame = end.frame
        for old in previous {
            old.alpha = 0
        }
        label.alpha = 1
    }

    private func animateTitle(_ view: UIView, to end: LabelSnapshot) {
        let generation = animationGeneration
        let animator = UIViewPropertyAnimator(duration: 0.35, curve: .easeInOut) { [weak self, weak view] in
            guard let view else { return }
            self?.move(view, to: end)
        }
        animator.addCompletion { [weak self, weak view] _ in
            guard let self, animationGeneration == generation, flight === view else { return }
            finish()
        }
        self.animator = animator
        animator.startAnimation()
    }

    private func stopTitleAnimation() {
        animationGeneration &+= 1
        coordinatingOpening = false
        if let animator, animator.state == .active {
            animator.stopAnimation(false)
            animator.finishAnimation(at: .current)
        }
        animator = nil
    }

    private func finish() {
        stopTitleAnimation()
        waitingForHeader = false
        flight?.removeFromSuperview()
        flight = nil
        updateVisibility()
    }

    private func updateVisibility() {
        for label in [card, header] where label?.motion === self {
            label?.alpha = flight == nil ? 1 : 0
        }
    }

    private struct LabelSnapshot {
        let frame: CGRect
        let text: String?
        let font: UIFont
        let color: UIColor
        let alignment: NSTextAlignment
        let lineCount: Int
        let lineBreakMode: NSLineBreakMode

        init(_ label: UILabel, in window: UIWindow) {
            frame = label.convert(label.bounds, to: window)
            text = label.text
            font = label.font
            color = label.textColor.resolvedColor(with: label.traitCollection)
            alignment = label.textAlignment
            lineCount = label.numberOfLines
            lineBreakMode = label.lineBreakMode
        }

        func label(in frame: CGRect) -> UILabel {
            let label = UILabel(frame: frame)
            label.text = text
            label.font = font
            label.textColor = color
            label.textAlignment = alignment
            label.numberOfLines = lineCount
            label.lineBreakMode = lineBreakMode
            label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            return label
        }
    }
}

struct LibraryCardTitle: View {
    @Environment(\.libraryCardTitleMotion) private var motion
    let title: String
    var endpoint: LibraryCardTitleLabel.Endpoint = .card
    var textStyle: UIFont.TextStyle = .headline
    var color: UIColor = .label
    var centered = false
    var lineLimit = 0

    var body: some View {
        let text = Text(title)
            .font(textStyle == .caption1 ? .caption : .headline)
            .lineLimit(lineLimit == 0 ? nil : lineLimit)
            .multilineTextAlignment(centered ? .center : .leading)
        if let motion {
            // Let SwiftUI's text line-breaking determine the layout. The UIKit
            // label only draws inside the space already assigned to the text.
            text.hidden()
                .overlay {
                    NativeTitle(title: self, motion: motion)
                }
        } else {
            text
        }
    }

    private struct NativeTitle: UIViewRepresentable {
        let title: LibraryCardTitle
        let motion: LibraryCardTitleMotion

        func makeUIView(context _: Context) -> LibraryCardTitleLabel {
            let label = LibraryCardTitleLabel()
            label.adjustsFontForContentSizeCategory = true
            return label
        }

        func updateUIView(_ label: LibraryCardTitleLabel, context _: Context) {
            label.text = title.title
            label.font = .preferredFont(forTextStyle: title.textStyle, compatibleWith: label.traitCollection)
            label.textColor = title.color
            label.textAlignment = title.centered ? .center : .natural
            label.numberOfLines = title.lineLimit
            label.lineBreakMode = title.lineLimit == 1 ? .byTruncatingTail : .byWordWrapping
            label.motion = motion
            label.endpoint = title.endpoint
            motion.register(label)
            label.setNeedsLayout()
        }

        func sizeThatFits(_ proposal: ProposedViewSize, uiView: LibraryCardTitleLabel, context _: Context) -> CGSize? {
            proposal.replacingUnspecifiedDimensions(by: uiView.intrinsicContentSize)
        }
    }
}

final class LibraryCardTitleLabel: UILabel {
    enum Endpoint { case card, header }

    weak var motion: LibraryCardTitleMotion?
    var endpoint: Endpoint = .card

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            motion?.register(self)
            if endpoint == .header {
                setNeedsLayout()
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if endpoint == .header {
            motion?.headerDidLayout()
        }
    }
}

struct LibraryNavigationBackdrop: UIViewControllerRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let motion: LibraryCardTitleMotion?

    func makeUIViewController(context _: Context) -> Observer {
        Observer(motion: motion, reduceMotion: reduceMotion)
    }

    func updateUIViewController(_ controller: Observer, context _: Context) {
        controller.motion = motion
        controller.reduceMotion = reduceMotion
    }

    final class Observer: UIViewController {
        var motion: LibraryCardTitleMotion?
        var reduceMotion: Bool
        private var backdropRequested = false

        init(motion: LibraryCardTitleMotion?, reduceMotion: Bool) {
            self.motion = motion
            self.reduceMotion = reduceMotion
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func loadView() {
            if motion != nil {
                // The Library header is part of the source during the zoom.
                // Keep this view for title callbacks without adding a second blur.
                view = UIView()
                return
            }
            let backdrop = TimelineMemoryGradientBackdropView()
            backdrop.setBlurVisible(false)
            view = backdrop
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            motion?.navigationWillAppear(transitionCoordinator)
            updateAppearance(visible: true)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            let isPopping = sequence(first: self as UIViewController, next: { $0.parent })
                .contains(where: \.isMovingFromParent)
            motion?.navigationWillDisappear(transitionCoordinator, isPopping: isPopping)
            updateAppearance(visible: false)
        }

        private func updateAppearance(visible: Bool) {
            guard let backdrop = view as? TimelineMemoryGradientBackdropView else { return }
            backdropRequested = visible
            guard !reduceMotion else {
                backdrop.setBlurVisible(visible)
                return
            }
            if let coordinator = transitionCoordinator, coordinator.transitionDuration > 0,
               coordinator.animate(alongsideTransition: { [weak backdrop] _ in
                   backdrop?.setBlurVisible(visible)
               }, completion: { [weak backdrop] context in
                   if context.isCancelled {
                       backdrop?.setBlurVisible(!visible)
                   }
               })
            {
                return
            }
            Task { @MainActor [weak self, weak backdrop] in
                guard self?.backdropRequested == visible, let backdrop else { return }
                UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) {
                    backdrop.setBlurVisible(visible)
                }
            }
        }
    }
}
