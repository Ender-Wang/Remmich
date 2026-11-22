import SwiftUI
import UIKit

extension View {
    func cardNavigationSource(id: some Hashable, in namespace: Namespace.ID, cornerRadius: CGFloat = DesignMetrics.defaultCornerRadius) -> some View {
        matchedTransitionSource(id: id, in: namespace) { source in
            source.clipShape(.rect(cornerRadius: cornerRadius))
        }
    }

    func cardNavigationDestination(id: some Hashable, in namespace: Namespace.ID) -> some View {
        navigationTransition(.zoom(sourceID: id, in: namespace))
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
