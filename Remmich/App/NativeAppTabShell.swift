import Observation
import OSLog
import SwiftUI
import UIKit

@MainActor
@Observable
final class NativeTabSelectionState {
    var selection: NativeTabDestination = .photos
}

@MainActor
@Observable
final class TimelineRotationState {
    private(set) var generation = 0
    private(set) var targetSize: CGSize?
    private(set) var isRotating = false

    func begin(to targetSize: CGSize) {
        generation &+= 1
        self.targetSize = targetSize
        isRotating = true
    }

    func complete() {
        isRotating = false
    }
}

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
    let rotationState: TimelineRotationState
    let compactOwner: NativeTabDestination?
    let isViewerPresented: Bool
    let photosScrollRequest: Int
    let videosScrollRequest: Int
    let groupedScrollRequests: [NativeTabDestination: Int]
    let groupedMediaOwner: NativeTabDestination
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
        controller.rotationState = rotationState
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
        context.coordinator.controller?.rotationState = rotationState
        context.coordinator.update(self, animated: true)
    }

    @MainActor
    final class Coordinator: NSObject, UITabBarControllerDelegate {
        fileprivate weak var controller: MeasuringTabBarController?
        private var parent: NativeAppTabShell
        private var installedTabs: [NativeTabDestination]?
        private var isUpdatingTabs = false
        private var tabBarShouldBeHidden = false

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
            let previous = parent
            parent = next

            let mediaLayoutChanged = previous.tabBarTop != next.tabBarTop
            if previous.photosScrollRequest != next.photosScrollRequest {
                photosController.rootView = next.photos
            }
            if previous.videosScrollRequest != next.videosScrollRequest {
                videosController.rootView = next.videos
            }
            if mediaLayoutChanged
                || previous.groupedScrollRequests != next.groupedScrollRequests
                || previous.groupedMediaOwner != next.groupedMediaOwner
            {
                yearsController.rootView = next.years
                monthsController.rootView = next.months
                weeksController.rootView = next.weeks
            }

            guard let controller else { return }
            if tabBarShouldBeHidden != next.isViewerPresented {
                tabBarShouldBeHidden = next.isViewerPresented
                setTabBarHidden(next.isViewerPresented, in: controller, animated: animated)
            }
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

        private func setTabBarHidden(
            _ hidden: Bool,
            in controller: UITabBarController,
            animated: Bool
        ) {
            let tabBar = controller.tabBar
            let currentAlpha = CGFloat(tabBar.layer.presentation()?.opacity ?? Float(tabBar.alpha))
            tabBar.layer.removeAllAnimations()
            tabBar.alpha = currentAlpha

            guard animated, !UIAccessibility.isReduceMotionEnabled else {
                tabBar.isHidden = hidden
                tabBar.alpha = 1
                controller.view.setNeedsLayout()
                return
            }

            tabBar.isHidden = false
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()

            UIView.animate(
                withDuration: 0.28,
                delay: 0,
                options: [.beginFromCurrentState, .curveEaseInOut, .allowUserInteraction]
            ) {
                tabBar.alpha = hidden ? 0 : 1
            } completion: { [weak self, weak controller] finished in
                guard finished, let self, let controller,
                      tabBarShouldBeHidden == hidden
                else { return }
                controller.tabBar.isHidden = hidden
                controller.tabBar.alpha = 1
                controller.view.setNeedsLayout()
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
    private static let logger = Logger(
        subsystem: "io.github.ender-wang.Remmich",
        category: "TimelineRotation"
    )

    var tabBarTopChanged: ((CGFloat) -> Void)?
    var rotationState: TimelineRotationState?
    private var rotationGeneration = 0
    private var rotationStartedAt: ContinuousClock.Instant?
    private var rotationTargetSize: CGSize?
    private var lastLoggedLayoutSize: CGSize?

    override func viewWillTransition(
        to size: CGSize,
        with coordinator: any UIViewControllerTransitionCoordinator
    ) {
        rotationGeneration += 1
        let generation = rotationGeneration
        rotationStartedAt = .now
        rotationTargetSize = size
        lastLoggedLayoutSize = nil
        rotationState?.begin(to: size)
        let currentSize = view.bounds.size
        Self.logger.info(
            "Host rotation began generation=\(generation) current=\(Self.describe(currentSize), privacy: .public) target=\(Self.describe(size), privacy: .public) durationMs=\(Int(coordinator.transitionDuration * 1000))"
        )
        coordinator.animate(alongsideTransition: nil) { [weak self] context in
            self?.completeRotation(generation: generation, cancelled: context.isCancelled)
        }
        super.viewWillTransition(to: size, with: coordinator)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        tabBar.layoutIfNeeded()
        tabBarTopChanged?(visibleTop(of: tabBar) ?? tabBar.frame.minY)
        guard let target = rotationTargetSize,
              lastLoggedLayoutSize != view.bounds.size
        else { return }
        lastLoggedLayoutSize = view.bounds.size
        let elapsed = rotationStartedAt.map { Self.elapsedMilliseconds(since: $0) } ?? -1
        let generation = rotationGeneration
        let bounds = view.bounds.size
        let tabBarFrame = tabBar.frame
        Self.logger.info(
            "Host rotation layout generation=\(generation) bounds=\(Self.describe(bounds), privacy: .public) target=\(Self.describe(target), privacy: .public) tabBar=\(Self.describe(tabBarFrame), privacy: .public) elapsedMs=\(elapsed)"
        )
    }

    private func completeRotation(generation: Int, cancelled: Bool) {
        let elapsed = rotationStartedAt.map { Self.elapsedMilliseconds(since: $0) } ?? -1
        let bounds = view.bounds.size
        Self.logger.info(
            "Host rotation completed generation=\(generation) cancelled=\(cancelled) bounds=\(Self.describe(bounds), privacy: .public) elapsedMs=\(elapsed)"
        )
        guard generation == rotationGeneration else { return }
        rotationState?.complete()
        rotationStartedAt = nil
        rotationTargetSize = nil
        lastLoggedLayoutSize = nil
    }

    private nonisolated static func elapsedMilliseconds(
        since start: ContinuousClock.Instant
    ) -> Int {
        let components = start.duration(to: .now).components
        return Int(components.seconds) * 1000
            + Int(components.attoseconds / 1_000_000_000_000_000)
    }

    private nonisolated static func describe(_ size: CGSize) -> String {
        "\(Int(size.width))x\(Int(size.height))"
    }

    private nonisolated static func describe(_ rect: CGRect) -> String {
        "x=\(Int(rect.minX)) y=\(Int(rect.minY)) w=\(Int(rect.width)) h=\(Int(rect.height))"
    }

    private func visibleTop(of root: UIView) -> CGFloat? {
        guard !root.isHidden, root.alpha > 0.01, !root.bounds.isEmpty else { return nil }

        var top = root.convert(root.bounds, to: view).minY
        for subview in root.subviews {
            if let subviewTop = visibleTop(of: subview) {
                top = min(top, subviewTop)
            }
        }
        return top
    }
}
