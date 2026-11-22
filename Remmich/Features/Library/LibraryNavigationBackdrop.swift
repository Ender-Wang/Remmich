import SwiftUI
import UIKit

struct LibraryNavigationBackdrop: UIViewControllerRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeUIViewController(context _: Context) -> Observer {
        Observer(reduceMotion: reduceMotion)
    }

    func updateUIViewController(_ controller: Observer, context _: Context) {
        controller.reduceMotion = reduceMotion
    }

    final class Observer: UIViewController {
        var reduceMotion: Bool
        private var backdropRequested = false

        init(reduceMotion: Bool) {
            self.reduceMotion = reduceMotion
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func loadView() {
            let backdrop = TimelineMemoryGradientBackdropView()
            backdrop.setBlurVisible(false)
            view = backdrop
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            updateAppearance(visible: true)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
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
