import SwiftUI
import UIKit

nonisolated struct LibraryHubDestination: Hashable {
    let id: UUID
    let makeView: @MainActor () -> AnyView

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct LibraryHubNavigation {
    let namespace: Namespace.ID
    let open: (LibraryHubDestination) -> Void
}

extension EnvironmentValues {
    @Entry var libraryHubNavigation: LibraryHubNavigation?
}

/// Observe the native return so the Library path can be reconciled when its grid is visible.
struct LibraryCardNavigation: UIViewControllerRepresentable {
    let didDisappear: () -> Void

    func makeUIViewController(context _: Context) -> Observer {
        let observer = Observer()
        observer.didDisappear = didDisappear
        return observer
    }

    func updateUIViewController(_ observer: Observer, context _: Context) {
        observer.didDisappear = didDisappear
    }

    final class Observer: UIViewController {
        var didDisappear: (() -> Void)?

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            didDisappear?()
        }
    }
}
