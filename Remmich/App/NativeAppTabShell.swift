import SwiftUI
import UIKit

enum NativeTabDestination: Hashable {
    case photos
    case videos
    case albums
    case library
    case years
    case months
    case weeks
    case search
}

enum NativeTabLayout {
    static func destinations(compactOwner: NativeTabDestination?) -> [NativeTabDestination] {
        switch compactOwner {
        case .photos:
            [.photos, .weeks, .months, .years, .search]
        case .videos:
            [.videos, .weeks, .months, .years, .search]
        default:
            [.photos, .videos, .albums, .library, .search]
        }
    }
}

/// One UIKit-owned tab bar on both devices. UIKit owns the Liquid Glass treatment
/// and animates the range tabs when either media timeline changes browsing mode.
struct NativeAppTabShell: UIViewControllerRepresentable {
    @Binding var selection: NativeTabDestination
    @Binding var tabBarTop: CGFloat
    let compactOwner: NativeTabDestination?
    let photosRetapped: () -> Void
    let videosRetapped: () -> Void
    let groupedTabRetapped: (NativeTabDestination) -> Void
    let photos: AnyView
    let videos: AnyView
    let albums: AnyView
    let library: AnyView
    let years: AnyView
    let months: AnyView
    let weeks: AnyView
    let search: AnyView

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UITabBarController {
        let controller = MeasuringTabBarController()
        controller.tabBarTopChanged = { [weak coordinator = context.coordinator] top in
            coordinator?.setTabBarTop(top)
        }
        controller.mode = .tabBar
        controller.delegate = context.coordinator
        context.coordinator.controller = controller
        context.coordinator.update(self, animated: false)
        return controller
    }

    func updateUIViewController(_: UITabBarController, context: Context) {
        context.coordinator.update(self, animated: true)
    }

    @MainActor
    final class Coordinator: NSObject, UITabBarControllerDelegate {
        weak var controller: UITabBarController?
        private var parent: NativeAppTabShell
        private var installedTabs: [NativeTabDestination]?
        private var isUpdatingTabs = false

        private lazy var photosController = mediaHostingController(rootView: parent.photos)
        private lazy var videosController = mediaHostingController(rootView: parent.videos)
        private lazy var albumsController = UIHostingController(rootView: parent.albums)
        private lazy var libraryController = UIHostingController(rootView: parent.library)
        private lazy var yearsController = mediaHostingController(rootView: parent.years)
        private lazy var monthsController = mediaHostingController(rootView: parent.months)
        private lazy var weeksController = mediaHostingController(rootView: parent.weeks)
        private lazy var searchController = UIHostingController(rootView: parent.search)

        private func mediaHostingController(rootView: AnyView) -> UIHostingController<AnyView> {
            let controller = UIHostingController(rootView: rootView)
            controller.safeAreaRegions = .keyboard
            return controller
        }

        private lazy var photosTab = UITab(
            title: "Photos", image: UIImage(systemName: "photo.on.rectangle.angled"), identifier: "photos"
        ) { [weak self] _ in self?.photosController ?? UIViewController() }

        private lazy var videosTab = UITab(
            title: "Videos", image: UIImage(systemName: "play.rectangle"), identifier: "videos"
        ) { [weak self] _ in self?.videosController ?? UIViewController() }

        private lazy var albumsTab = UITab(
            title: "Albums", image: UIImage(systemName: "rectangle.stack"), identifier: "albums"
        ) { [weak self] _ in self?.albumsController ?? UIViewController() }

        private lazy var libraryTab = UITab(
            title: "Library", image: UIImage(systemName: "square.grid.2x2"), identifier: "library"
        ) { [weak self] _ in self?.libraryController ?? UIViewController() }

        private lazy var yearsTab = UITab(
            title: "Years", image: UIImage(systemName: "calendar.circle"), identifier: "years"
        ) { [weak self] _ in self?.yearsController ?? UIViewController() }

        private lazy var monthsTab = UITab(
            title: "Months", image: UIImage(systemName: "calendar"), identifier: "months"
        ) { [weak self] _ in self?.monthsController ?? UIViewController() }

        private lazy var weeksTab = UITab(
            title: "Weeks", image: UIImage(systemName: "7.circle"), identifier: "weeks"
        ) { [weak self] _ in self?.weeksController ?? UIViewController() }

        private lazy var searchTab = UISearchTab { [weak self] _ in
            self?.searchController ?? UIViewController()
        }

        init(_ parent: NativeAppTabShell) {
            self.parent = parent
        }

        func setTabBarTop(_ top: CGFloat) {
            guard abs(parent.tabBarTop - top) > 0.5 else { return }
            Task { @MainActor [weak self] in
                self?.parent.tabBarTop = top
            }
        }

        func update(_ next: NativeAppTabShell, animated: Bool) {
            parent = next
            photosController.rootView = next.photos
            videosController.rootView = next.videos
            albumsController.rootView = next.albums
            libraryController.rootView = next.library
            yearsController.rootView = next.years
            monthsController.rootView = next.months
            weeksController.rootView = next.weeks
            searchController.rootView = next.search

            guard let controller else { return }
            isUpdatingTabs = true
            defer { isUpdatingTabs = false }
            let destinations = NativeTabLayout.destinations(compactOwner: next.compactOwner)
            if installedTabs != destinations {
                installedTabs = destinations
                controller.setTabs(
                    destinations.map(tab(for:)),
                    animated: animated
                )
            }
            let intendedTab = tab(for: next.selection)
            if controller.selectedTab !== intendedTab {
                controller.selectedTab = intendedTab
            }
        }

        func tabBarController(_: UITabBarController, didSelectTab selectedTab: UITab, previousTab: UITab?) {
            guard !isUpdatingTabs, let destination = destination(for: selectedTab) else { return }
            if selectedTab === photosTab, previousTab === photosTab {
                parent.photosRetapped()
            } else if selectedTab === videosTab, previousTab === videosTab {
                parent.videosRetapped()
            } else if selectedTab === previousTab,
                      destination == .weeks || destination == .months || destination == .years
            {
                parent.groupedTabRetapped(destination)
            } else {
                parent.selection = destination
            }
        }

        private func tab(for destination: NativeTabDestination) -> UITab {
            switch destination {
            case .photos: photosTab
            case .videos: videosTab
            case .albums: albumsTab
            case .library: libraryTab
            case .years: yearsTab
            case .months: monthsTab
            case .weeks: weeksTab
            case .search: searchTab
            }
        }

        private func destination(for tab: UITab) -> NativeTabDestination? {
            if tab === photosTab {
                return .photos
            }
            if tab === videosTab {
                return .videos
            }
            if tab === albumsTab {
                return .albums
            }
            if tab === libraryTab {
                return .library
            }
            if tab === yearsTab {
                return .years
            }
            if tab === monthsTab {
                return .months
            }
            if tab === weeksTab {
                return .weeks
            }
            if tab === searchTab {
                return .search
            }
            return nil
        }
    }
}

@MainActor
private final class MeasuringTabBarController: UITabBarController {
    var tabBarTopChanged: ((CGFloat) -> Void)?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        tabBarTopChanged?(tabBar.frame.minY)
    }
}
