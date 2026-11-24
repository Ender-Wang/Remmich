import SwiftUI
import UIKit

/// Dismiss a native sheet from its dimmed backdrop without passing the tap through.
struct SheetOutsideTap: UIViewRepresentable {
    let dismiss: () -> Void
    var fittedHeight: CGFloat?
    var animatesHeight = true

    func makeUIView(context _: Context) -> SheetOutsideTapView {
        let view = SheetOutsideTapView(dismiss: dismiss)
        view.updateHeight(fittedHeight, animated: animatesHeight)
        return view
    }

    func updateUIView(_ view: SheetOutsideTapView, context _: Context) {
        view.dismiss = dismiss
        view.updateHeight(fittedHeight, animated: animatesHeight)
    }

    static func dismantleUIView(_ view: SheetOutsideTapView, coordinator _: ()) {
        view.detach()
    }
}

final class SheetOutsideTapView: UIView, UIGestureRecognizerDelegate {
    var dismiss: () -> Void
    private weak var attachedWindow: UIWindow?
    private weak var sizedSheet: UISheetPresentationController?
    private var requestedHeight: CGFloat?
    private var resolvedHeight: CGFloat = 0
    private var animatesHeight = true
    private static let fittedDetent = UISheetPresentationController.Detent.Identifier("fitted-content")
    private lazy var tap: UITapGestureRecognizer = {
        let gesture = UITapGestureRecognizer(target: self, action: #selector(tappedOutside))
        gesture.delegate = self
        gesture.cancelsTouchesInView = true
        return gesture
    }()

    init(dismiss: @escaping () -> Void) {
        self.dismiss = dismiss
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
        attachedWindow = window
        window.addGestureRecognizer(tap)
        applyHeight()
        applyHeightWhenAttached()
    }

    func updateHeight(_ height: CGFloat?, animated: Bool) {
        requestedHeight = height
        animatesHeight = animated
        applyHeightWhenAttached()
    }

    private func applyHeightWhenAttached() {
        guard window != nil, requestedHeight != nil else { return }
        Task { @MainActor [weak self] in
            self?.applyHeight()
        }
    }

    private func applyHeight() {
        guard attachedWindow != nil, let height = requestedHeight, let controller = sheet, !controller.isBeingDismissed,
              let presentation = controller.sheetPresentationController
        else { return }

        if sizedSheet !== presentation || presentation.detents.first?.identifier != Self.fittedDetent {
            sizedSheet = presentation
            resolvedHeight = height
            presentation.detents = [.custom(identifier: Self.fittedDetent) { [weak self] context in
                min(self?.resolvedHeight ?? height, context.maximumDetentValue)
            }]
            presentation.selectedDetentIdentifier = Self.fittedDetent
        } else if resolvedHeight != height {
            resolvedHeight = height
            if animatesHeight {
                presentation.animateChanges { presentation.invalidateDetents() }
            } else {
                UIView.performWithoutAnimation { presentation.invalidateDetents() }
            }
        }
    }

    func detach() {
        attachedWindow?.removeGestureRecognizer(tap)
        attachedWindow = nil
    }

    private var sheet: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController {
                var candidate: UIViewController? = controller
                while let parent = candidate {
                    if parent.presentingViewController != nil, parent.presentationController is UISheetPresentationController {
                        return parent
                    }
                    candidate = parent.parent
                }
            }
            responder = current.next
        }
        return nil
    }

    func gestureRecognizer(_: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let sheet, !sheet.isBeingDismissed, sheet.presentedViewController == nil,
              let view = sheet.presentationController?.presentedView,
              view.window === attachedWindow else { return false }
        return !view.bounds.contains(touch.location(in: view))
    }

    func gestureRecognizer(_: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func tappedOutside(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let sheet, !sheet.isBeingDismissed,
              sheet.presentedViewController == nil else { return }
        dismiss()
    }
}
