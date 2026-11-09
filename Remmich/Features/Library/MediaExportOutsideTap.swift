import SwiftUI
import UIKit

/// Observe the dimmed area without enabling UIKit's sheet drag dismissal.
struct MediaExportOutsideTap: UIViewRepresentable {
    let dismiss: () -> Void

    func makeUIView(context _: Context) -> MediaExportOutsideTapView {
        MediaExportOutsideTapView(dismiss: dismiss)
    }

    func updateUIView(_ view: MediaExportOutsideTapView, context _: Context) {
        view.dismiss = dismiss
    }

    static func dismantleUIView(_ view: MediaExportOutsideTapView, coordinator _: ()) {
        view.detach()
    }
}

final class MediaExportOutsideTapView: UIView, UIGestureRecognizerDelegate {
    var dismiss: () -> Void
    private weak var attachedWindow: UIWindow?
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
