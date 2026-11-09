import SwiftUI
import UIKit

/// History rows own horizontal content swipes. Navigation keeps its edge pan.
struct DownloadHistoryNavigationBoundary: UIViewControllerRepresentable {
    func makeUIViewController(context _: Context) -> DownloadHistoryNavigationController {
        DownloadHistoryNavigationController()
    }

    func updateUIViewController(_ controller: DownloadHistoryNavigationController, context _: Context) {
        controller.restrictContentPop()
    }

    static func dismantleUIViewController(_ controller: DownloadHistoryNavigationController, coordinator _: ()) {
        controller.restoreContentPop()
    }
}

final class DownloadHistoryNavigationController: UIViewController {
    private weak var contentPop: UIGestureRecognizer?
    private var wasEnabled = false
    private var visible = false

    override func loadView() {
        view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        visible = true
        restrictContentPop()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        restrictContentPop()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        visible = false
        restoreContentPop()
    }

    func restrictContentPop() {
        guard visible, let gesture = navigationController?.interactiveContentPopGestureRecognizer else { return }
        if contentPop !== gesture {
            restoreContentPop()
            contentPop = gesture
            wasEnabled = gesture.isEnabled
        }
        gesture.isEnabled = false
    }

    func restoreContentPop() {
        contentPop?.isEnabled = wasEnabled
        contentPop = nil
    }
}
