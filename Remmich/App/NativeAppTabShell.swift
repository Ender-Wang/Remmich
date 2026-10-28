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
final class NativeTabContentActivationState {
    private(set) var activeDestination: NativeTabDestination = .photos
    private(set) var hydratedDestinations: Set<NativeTabDestination> = [.photos]

    func activate(_ destination: NativeTabDestination) {
        activeDestination = destination
        hydratedDestinations.insert(destination)
    }

    func isHydrated(_ destination: NativeTabDestination) -> Bool {
        hydratedDestinations.contains(destination)
    }
}

@MainActor
@Observable
final class TimelineRotationState {
    private(set) var generation = 0
    private(set) var targetSize: CGSize?
    private(set) var isRotating = false
    private var visualHandoffEligibleDestinations = Set<NativeTabDestination>()
    var visualHandoffResolved: ((Int, Bool, String) -> Void)?

    func begin(to targetSize: CGSize) {
        generation &+= 1
        self.targetSize = targetSize
        isRotating = true
    }

    func complete() {
        isRotating = false
        targetSize = nil
    }

    func setVisualHandoffEligible(
        _ eligible: Bool,
        for destination: NativeTabDestination
    ) {
        if eligible {
            visualHandoffEligibleDestinations.insert(destination)
        } else {
            visualHandoffEligibleDestinations.remove(destination)
        }
    }

    func isVisualHandoffEligible(for destination: NativeTabDestination) -> Bool {
        visualHandoffEligibleDestinations.contains(destination)
    }

    func resolveVisualHandoff(
        generation: Int,
        verified: Bool,
        reason: String
    ) {
        guard generation == self.generation else { return }
        visualHandoffResolved?(generation, verified, reason)
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

enum NativeTabPageDirection: Equatable {
    case previous
    case next
}

@MainActor
enum NativeTabTransitionTrace {
    private static let signposter = OSSignposter(
        subsystem: "io.github.ender-wang.Remmich",
        category: "NativeTabs"
    )
    private static var startedAtByDestination: [NativeTabDestination: ContinuousClock.Instant] = [:]
    private static var intervalByDestination: [NativeTabDestination: OSSignpostIntervalState] = [:]

    static func begin(destination: NativeTabDestination) {
        if let interval = intervalByDestination.removeValue(forKey: destination) {
            signposter.endInterval("TabSelection", interval)
        }
        startedAtByDestination[destination] = .now
        intervalByDestination[destination] = signposter.beginInterval(
            "TabSelection",
            id: signposter.makeSignpostID(),
            "destination=\(String(describing: destination))"
        )
    }

    static func elapsedMilliseconds(for destination: NativeTabDestination) -> Int? {
        guard let startedAt = startedAtByDestination[destination] else { return nil }
        let components = startedAt.duration(to: .now).components
        return Int(components.seconds) * 1000
            + Int(components.attoseconds / 1_000_000_000_000_000)
    }

    static func end(destination: NativeTabDestination) {
        guard let interval = intervalByDestination.removeValue(forKey: destination) else { return }
        signposter.endInterval("TabSelection", interval)
    }
}

enum NativeTabLayout {
    static let primaryDestinations: [NativeTabDestination] = [
        .photos, .videos, .albums, .library, .search,
    ]

    static func destinations(compactOwner: NativeTabDestination?) -> [NativeTabDestination] {
        switch compactOwner {
        case .photos:
            [.photos, .weeks, .months, .years, .search]
        case .videos:
            [.videos, .weeks, .months, .years, .search]
        default:
            primaryDestinations
        }
    }

    static func adjacentDestination(
        from destination: NativeTabDestination,
        direction: NativeTabPageDirection,
        compactOwner: NativeTabDestination?
    ) -> NativeTabDestination? {
        let destinations = destinations(compactOwner: compactOwner)
        guard let index = destinations.firstIndex(of: destination) else { return nil }
        let adjacentIndex = direction == .next ? index + 1 : index - 1
        guard destinations.indices.contains(adjacentIndex) else { return nil }
        return destinations[adjacentIndex]
    }

    static func pageDirection(
        from source: NativeTabDestination,
        to destination: NativeTabDestination,
        compactOwner: NativeTabDestination?
    ) -> NativeTabPageDirection? {
        let destinations = destinations(compactOwner: compactOwner)
        guard let sourceIndex = destinations.firstIndex(of: source),
              let destinationIndex = destinations.firstIndex(of: destination),
              sourceIndex != destinationIndex
        else { return nil }
        return destinationIndex > sourceIndex ? .next : .previous
    }
}

enum NativeTabPageGesturePolicy {
    static func blocksRootPaging(startingAt touchedView: UIView?) -> Bool {
        var candidate = touchedView
        while let view = candidate {
            if let scrollView = view as? UIScrollView,
               scrollView.alwaysBounceHorizontal
               || scrollView.contentSize.width > scrollView.bounds.width + 1
            {
                return true
            }
            candidate = view.superview
        }
        return false
    }
}

/// One UIKit-owned tab bar on both devices. UIKit owns the Liquid Glass treatment
/// and animates the range tabs when either media timeline changes browsing mode.
nonisolated struct NativeLibraryContentRevision: Equatable {
    let profile: ConnectionProfile?
    let activeRoute: ActiveConnectionRoute?
    let routeStatus: ConnectionRouteStatus

    static let restoring = Self(
        profile: nil,
        activeRoute: nil,
        routeStatus: .waitingForNetwork
    )
}

struct NativeAppTabShell: UIViewControllerRepresentable {
    @Binding var selection: NativeTabDestination
    @Binding var tabBarTop: CGFloat
    let rotationState: TimelineRotationState
    let contentActivationState: NativeTabContentActivationState
    let compactOwner: NativeTabDestination?
    let isViewerPresented: Bool
    let pageSwipeEnabled: Bool
    let photosScrollRequest: Int
    let videosScrollRequest: Int
    let groupedScrollRequests: [NativeTabDestination: Int]
    let groupedMediaOwner: NativeTabDestination
    let libraryContentRevision: NativeLibraryContentRevision
    let photosRetapped: () -> Void
    let videosRetapped: () -> Void
    let libraryRetapped: () -> Void
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
        controller.bindRotationState(rotationState)
        controller.tabBarTopChanged = { [weak coordinator = context.coordinator] top in
            coordinator?.setTabBarTop(top)
        }
        controller.mode = .tabBar
        controller.delegate = context.coordinator
        context.coordinator.controller = controller
        context.coordinator.installPrimaryPageSwipeRecognizers(on: controller)
        context.coordinator.update(self, animated: false)
        return controller
    }

    func updateUIViewController(_: UITabBarController, context: Context) {
        context.coordinator.controller?.bindRotationState(rotationState)
        context.coordinator.update(self, animated: true)
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate, UITabBarControllerDelegate {
        private static let logger = Logger(
            subsystem: "io.github.ender-wang.Remmich",
            category: "NativeTabs"
        )

        fileprivate weak var controller: MeasuringTabBarController?
        private var parent: NativeAppTabShell
        private var installedTabs: [NativeTabDestination]?
        private var isUpdatingTabs = false
        private var didResolveLibrary = false
        private var tabBarInteractionBlockedByViewer = false
        private var didResolveVideos = false
        private var contentActivationGeneration = 0
        private var contentActivationTask: Task<Void, Never>?
        private var lastDestinationChange: (
            destination: NativeTabDestination,
            instant: ContinuousClock.Instant
        )?
        private var pendingPageDirection: NativeTabPageDirection?
        private var pageInteractionDirection: NativeTabPageDirection?
        private var pageInteractionController: UIPercentDrivenInteractiveTransition?
        private var pageInteractionDestination: NativeTabDestination?
        private weak var pageInteractionPreviousTab: UITab?

        private lazy var pagePanRecognizer: UIPanGestureRecognizer = {
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(primaryPagePanned(_:)))
            recognizer.cancelsTouchesInView = true
            recognizer.maximumNumberOfTouches = 1
            recognizer.delegate = self
            return recognizer
        }()

        private lazy var photosController = tabHostingController(
            rootView: parent.photos,
            destination: .photos,
            ignoresContainerSafeArea: true
        )
        private lazy var videosController = tabHostingController(
            rootView: parent.videos,
            destination: .videos,
            ignoresContainerSafeArea: true
        )
        private lazy var albumsController = tabHostingController(
            rootView: parent.albums,
            destination: .albums
        )
        private lazy var libraryController = tabHostingController(
            rootView: parent.library,
            destination: .library
        )
        private lazy var yearsController = tabHostingController(
            rootView: parent.years,
            destination: .years,
            ignoresContainerSafeArea: true
        )
        private lazy var monthsController = tabHostingController(
            rootView: parent.months,
            destination: .months,
            ignoresContainerSafeArea: true
        )
        private lazy var weeksController = tabHostingController(
            rootView: parent.weeks,
            destination: .weeks,
            ignoresContainerSafeArea: true
        )
        private lazy var searchController = tabHostingController(
            rootView: parent.search,
            destination: .search
        )

        private func tabHostingController(
            rootView: AnyView,
            destination: NativeTabDestination,
            ignoresContainerSafeArea: Bool = false
        ) -> TabContentHostingController {
            let controller = TabContentHostingController(rootView: rootView)
            if ignoresContainerSafeArea {
                controller.safeAreaRegions = .keyboard
            }
            controller.didAppear = { [weak self] in
                self?.scheduleContentActivation(destination)
            }
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
        ) { [weak self] _ in
            guard let self else { return UIViewController() }
            didResolveLibrary = true
            return libraryController
        }

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

        deinit {
            contentActivationTask?.cancel()
        }

        func installPrimaryPageSwipeRecognizers(on controller: UITabBarController) {
            controller.view.addGestureRecognizer(pagePanRecognizer)
        }

        private func scheduleContentActivation(_ destination: NativeTabDestination) {
            guard !parent.contentActivationState.isHydrated(destination) else { return }
            contentActivationGeneration &+= 1
            let generation = contentActivationGeneration
            contentActivationTask?.cancel()
            contentActivationTask = Task { @MainActor [weak self] in
                guard let self,
                      !Task.isCancelled,
                      generation == contentActivationGeneration,
                      parent.selection == destination,
                      controller?.selectedTab === tab(for: destination)
                else { return }

                // Let UIKit commit the tab selection before the destination's
                // SwiftUI hierarchy is mounted. This is a scheduler boundary,
                // not a timed delay: tab navigation remains the control plane,
                // while timeline hydration follows on the next available turn.
                await Task.yield()
                guard !Task.isCancelled,
                      generation == contentActivationGeneration,
                      parent.selection == destination,
                      controller?.selectedTab === tab(for: destination)
                else { return }

                parent.contentActivationState.activate(destination)
                contentActivationTask = nil
                Self.logger.info(
                    "Native tab content activated destination=\(String(describing: destination), privacy: .public)"
                )
            }
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
            if didResolveLibrary,
               previous.libraryContentRevision != next.libraryContentRevision
            {
                libraryController.rootView = next.library
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
            if tabBarInteractionBlockedByViewer != next.isViewerPresented {
                tabBarInteractionBlockedByViewer = next.isViewerPresented
                setTabBarInteractionBlocked(next.isViewerPresented, in: controller)
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
            if pageInteractionController == nil,
               controller.selectedTab !== intendedTab
            {
                controller.selectedTab = intendedTab
            }
            resolveVideoTab(in: controller)
        }

        private func resolveVideoTab(in controller: UITabBarController) {
            guard !didResolveVideos,
                  parent.selection != .videos,
                  installedTabs?.contains(.videos) == true
            else { return }

            let bounds = controller.view.bounds
            guard bounds.width > 0, bounds.height > 0,
                  let controllerToWarm = videosTab.viewController
            else { return }

            // Resolve through UITab before the tab bar becomes interactive. Accessing the lazy
            // controller directly does not populate UITab's provider cache, so UIKit would still
            // perform first-time controller resolution on the user's first Videos tap.
            let startedAt = ContinuousClock.now
            controllerToWarm.loadViewIfNeeded()
            controllerToWarm.view.frame = bounds
            controllerToWarm.view.setNeedsLayout()
            controllerToWarm.view.layoutIfNeeded()
            didResolveVideos = true
            let components = startedAt.duration(to: .now).components
            let elapsedMilliseconds = Int(components.seconds) * 1000
                + Int(components.attoseconds / 1_000_000_000_000_000)
            Self.logger.info(
                "Videos tab controller resolved size=\(Int(bounds.width))x\(Int(bounds.height)) elapsedMs=\(elapsedMilliseconds)"
            )
        }

        private func setTabBarInteractionBlocked(
            _ blocked: Bool,
            in controller: UITabBarController
        ) {
            let tabBar = controller.tabBar
            // The full-screen viewer covers the timeline and its tab bar. Keep both
            // drawn underneath so dismissal does not reveal a newly fading-in bar.
            tabBar.isHidden = false
            tabBar.alpha = 1
            tabBar.isUserInteractionEnabled = !blocked
            tabBar.accessibilityElementsHidden = blocked
        }

        func tabBarController(_: UITabBarController, didSelectTab selectedTab: UITab, previousTab: UITab?) {
            guard !isUpdatingTabs, let destination = destination(for: selectedTab) else { return }
            defer {
                if pageInteractionController == nil {
                    pendingPageDirection = nil
                }
            }
            publishSelection(
                destination: destination,
                selectedTab: selectedTab,
                previousTab: previousTab
            )
        }

        func tabBarController(
            _ tabBarController: UITabBarController,
            shouldSelectTab tab: UITab
        ) -> Bool {
            guard !isUpdatingTabs,
                  pageInteractionController == nil,
                  parent.pageSwipeEnabled,
                  !parent.isViewerPresented,
                  !UIAccessibility.isReduceMotionEnabled,
                  let selectedTab = tabBarController.selectedTab,
                  selectedTab !== tab,
                  let source = destination(for: selectedTab),
                  let destination = destination(for: tab)
            else { return true }

            pendingPageDirection = NativeTabLayout.pageDirection(
                from: source,
                to: destination,
                compactOwner: parent.compactOwner
            )
            return true
        }

        @objc private func primaryPagePanned(_ recognizer: UIPanGestureRecognizer) {
            guard let controller else { return }

            switch recognizer.state {
            case .began:
                beginPageInteraction(using: recognizer, in: controller)
            case .changed:
                updatePageInteraction(using: recognizer, in: controller)
            case .ended:
                completePageInteraction(using: recognizer, in: controller)
            case .cancelled, .failed:
                cancelPageInteraction(in: controller)
            default:
                break
            }
        }

        private func beginPageInteraction(
            using recognizer: UIPanGestureRecognizer,
            in controller: UITabBarController
        ) {
            guard pageInteractionController == nil,
                  let previousTab = controller.selectedTab
            else { return }

            let velocity = recognizer.velocity(in: controller.view)
            let direction: NativeTabPageDirection = velocity.x < 0 ? .next : .previous
            guard let destination = NativeTabLayout.adjacentDestination(
                from: parent.selection,
                direction: direction,
                compactOwner: parent.compactOwner
            ) else { return }

            let interaction = UIPercentDrivenInteractiveTransition()
            interaction.completionCurve = .easeOut
            interaction.completionSpeed = 1
            pageInteractionController = interaction
            pageInteractionDirection = direction
            pageInteractionDestination = destination
            pageInteractionPreviousTab = previousTab
            pendingPageDirection = direction
            isUpdatingTabs = true
            controller.selectedTab = tab(for: destination)
            isUpdatingTabs = false

            guard controller.transitionCoordinator != nil else {
                clearPageInteraction()
                return
            }
        }

        private func updatePageInteraction(
            using recognizer: UIPanGestureRecognizer,
            in controller: UITabBarController
        ) {
            guard let interaction = pageInteractionController else { return }
            interaction.update(pageInteractionProgress(using: recognizer, in: controller))
        }

        private func completePageInteraction(
            using recognizer: UIPanGestureRecognizer,
            in controller: UITabBarController
        ) {
            guard let interaction = pageInteractionController else { return }
            let progress = pageInteractionProgress(using: recognizer, in: controller)
            let velocity = recognizer.velocity(in: controller.view).x
            let advancesInTransitionDirection: Bool = switch pageInteractionDirection {
            case .next:
                velocity < -420
            case .previous:
                velocity > 420
            case nil:
                false
            }

            if progress >= 0.35 || advancesInTransitionDirection {
                finishPageInteraction(interaction, in: controller)
            } else {
                cancelPageInteraction(in: controller)
            }
        }

        private func finishPageInteraction(
            _ interaction: UIPercentDrivenInteractiveTransition,
            in controller: UITabBarController
        ) {
            guard let destination = pageInteractionDestination,
                  let previousTab = pageInteractionPreviousTab
            else {
                interaction.cancel()
                clearPageInteraction()
                return
            }

            let selectedTab = tab(for: destination)
            interaction.finish()
            completePageInteractionTransition(in: controller) { [weak self] cancelled in
                guard let self else { return }
                if cancelled {
                    restorePageInteractionPreviousTab(previousTab, in: controller)
                    if let previousDestination = self.destination(for: previousTab) {
                        parent.selection = previousDestination
                    }
                } else {
                    publishSelection(
                        destination: destination,
                        selectedTab: selectedTab,
                        previousTab: previousTab
                    )
                    scheduleContentActivation(destination)
                }
                clearPageInteraction()
            }
        }

        private func cancelPageInteraction(in controller: UITabBarController) {
            guard let interaction = pageInteractionController else { return }
            let previousTab = pageInteractionPreviousTab
            interaction.cancel()
            completePageInteractionTransition(in: controller) { [weak self] _ in
                guard let self else { return }
                if let previousTab {
                    restorePageInteractionPreviousTab(previousTab, in: controller)
                }
                clearPageInteraction()
            }
        }

        private func completePageInteractionTransition(
            in controller: UITabBarController,
            completion: @escaping (Bool) -> Void
        ) {
            guard let coordinator = controller.transitionCoordinator else {
                completion(false)
                return
            }
            coordinator.animate(alongsideTransition: nil) { context in
                let wasCancelled = context.isCancelled
                Task { @MainActor in
                    completion(wasCancelled)
                }
            }
        }

        private func restorePageInteractionPreviousTab(
            _ previousTab: UITab,
            in controller: UITabBarController
        ) {
            guard controller.selectedTab !== previousTab else { return }
            isUpdatingTabs = true
            controller.selectedTab = previousTab
            isUpdatingTabs = false
        }

        private func clearPageInteraction() {
            pendingPageDirection = nil
            pageInteractionDirection = nil
            pageInteractionController = nil
            pageInteractionDestination = nil
            pageInteractionPreviousTab = nil
        }

        private func pageInteractionProgress(
            using recognizer: UIPanGestureRecognizer,
            in controller: UITabBarController
        ) -> CGFloat {
            let width = max(controller.view.bounds.width, 1)
            return min(max(abs(recognizer.translation(in: controller.view).x) / width, 0), 1)
        }

        private func publishSelection(
            destination: NativeTabDestination,
            selectedTab: UITab,
            previousTab: UITab?
        ) {
            controller?.discardRotationVisualHandoff(reason: "tab-selection")
            let isReselection = selectedTab === previousTab
            if isReselection,
               let lastDestinationChange,
               lastDestinationChange.destination == destination,
               lastDestinationChange.instant.duration(to: .now) < .milliseconds(320)
            {
                Self.logger.info(
                    "Native tab duplicate selection suppressed destination=\(String(describing: destination), privacy: .public)"
                )
                return
            }
            if !isReselection {
                lastDestinationChange = (destination, .now)
            }
            NativeTabTransitionTrace.begin(destination: destination)
            let selectedController = selectedTab.viewController
            Self.logger.info(
                "Native tab selected destination=\(String(describing: destination), privacy: .public) resolved=\(selectedController != nil) loaded=\(selectedController?.isViewLoaded == true) attached=\(selectedController?.viewIfLoaded?.window != nil)"
            )
            if selectedTab === photosTab, previousTab === photosTab {
                parent.photosRetapped()
            } else if selectedTab === videosTab, previousTab === videosTab {
                parent.videosRetapped()
            } else if selectedTab === libraryTab, previousTab === libraryTab {
                parent.libraryRetapped()
            } else if selectedTab === previousTab,
                      destination == .weeks || destination == .months || destination == .years
            {
                parent.groupedTabRetapped(destination)
            } else {
                parent.selection = destination
            }

            let transitionDuration = controller?.transitionCoordinator?.transitionDuration ?? 0
            Self.logger.info(
                "Native tab visual selection published destination=\(String(describing: destination), privacy: .public) elapsedMs=\(NativeTabTransitionTrace.elapsedMilliseconds(for: destination) ?? -1) transitionDurationMs=\(Int(transitionDuration * 1000))"
            )
            if let transitionCoordinator = controller?.transitionCoordinator {
                transitionCoordinator.animate(alongsideTransition: nil) { _ in
                    Task { @MainActor in
                        NativeTabTransitionTrace.end(destination: destination)
                        Self.logger.info(
                            "Native tab transition completed destination=\(String(describing: destination), privacy: .public) elapsedMs=\(NativeTabTransitionTrace.elapsedMilliseconds(for: destination) ?? -1)"
                        )
                    }
                }
            } else {
                Task { @MainActor in
                    await Task.yield()
                    NativeTabTransitionTrace.end(destination: destination)
                    Self.logger.info(
                        "Native tab next run loop destination=\(String(describing: destination), privacy: .public) elapsedMs=\(NativeTabTransitionTrace.elapsedMilliseconds(for: destination) ?? -1)"
                    )
                }
            }
        }

        func gestureRecognizer(
            _: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            guard parent.pageSwipeEnabled,
                  !parent.isViewerPresented
            else { return false }

            return !NativeTabPageGesturePolicy.blocksRootPaging(startingAt: touch.view)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === pagePanRecognizer,
                  parent.pageSwipeEnabled,
                  !parent.isViewerPresented,
                  !UIAccessibility.isReduceMotionEnabled,
                  pageInteractionController == nil,
                  let controller
            else { return false }

            let velocity = pagePanRecognizer.velocity(in: controller.view)
            guard abs(velocity.x) > abs(velocity.y) * 1.2,
                  abs(velocity.x) > 80
            else { return false }

            let direction: NativeTabPageDirection = velocity.x < 0 ? .next : .previous
            if direction == .previous,
               pagePanRecognizer.location(in: controller.view).x < 32
            {
                return false
            }
            return NativeTabLayout.adjacentDestination(
                from: parent.selection,
                direction: direction,
                compactOwner: parent.compactOwner
            ) != nil
        }

        func gestureRecognizer(
            _: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func tabBarController(
            _: UITabBarController,
            animationControllerForTransitionFrom _: UIViewController,
            to _: UIViewController
        ) -> (any UIViewControllerAnimatedTransitioning)? {
            guard let direction = pendingPageDirection else { return nil }
            pendingPageDirection = nil
            return NativeTabPageAnimator(direction: direction)
        }

        func tabBarController(
            _: UITabBarController,
            interactionControllerFor _: any UIViewControllerAnimatedTransitioning
        ) -> (any UIViewControllerInteractiveTransitioning)? {
            pageInteractionController
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

private final class NativeTabPageAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    let direction: NativeTabPageDirection
    private var propertyAnimator: UIViewPropertyAnimator?

    init(direction: NativeTabPageDirection) {
        self.direction = direction
    }

    func transitionDuration(using _: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
        0.36
    }

    func animateTransition(using transitionContext: any UIViewControllerContextTransitioning) {
        interruptibleAnimator(using: transitionContext).startAnimation()
    }

    func interruptibleAnimator(
        using transitionContext: any UIViewControllerContextTransitioning
    ) -> any UIViewImplicitlyAnimating {
        if let propertyAnimator {
            return propertyAnimator
        }

        guard let fromView = transitionContext.view(forKey: .from),
              let toView = transitionContext.view(forKey: .to),
              let toController = transitionContext.viewController(forKey: .to)
        else {
            transitionContext.completeTransition(false)
            return UIViewPropertyAnimator(duration: 0, curve: .linear)
        }

        let container = transitionContext.containerView
        let width = container.bounds.width
        let travel = direction == .next ? width : -width
        toView.frame = transitionContext.finalFrame(for: toController)
        toView.transform = CGAffineTransform(translationX: travel, y: 0)
        container.addSubview(toView)

        let animator = UIViewPropertyAnimator(
            duration: transitionDuration(using: transitionContext),
            curve: .easeInOut
        ) {
            fromView.transform = CGAffineTransform(translationX: -travel, y: 0)
            toView.transform = .identity
        }
        animator.addCompletion { [weak self] _ in
            fromView.transform = .identity
            toView.transform = .identity
            transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            self?.propertyAnimator = nil
        }
        propertyAnimator = animator
        return animator
    }
}

@MainActor
private final class TabContentHostingController: UIHostingController<AnyView> {
    var didAppear: (() -> Void)?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        didAppear?()
    }
}

@MainActor
private final class MeasuringTabBarController: UITabBarController {
    private static let logger = Logger(
        subsystem: "io.github.ender-wang.Remmich",
        category: "TimelineRotation"
    )

    var tabBarTopChanged: ((CGFloat) -> Void)?
    private weak var rotationState: TimelineRotationState?
    private var rotationGeneration = 0
    private var rotationStartedAt: ContinuousClock.Instant?
    private var rotationTargetSize: CGSize?
    private var lastLoggedLayoutSize: CGSize?
    private var rotationVisualSnapshot: UIView?
    private var rotationVisualGeneration: Int?
    private var rotationVisualResolvedGeneration: Int?
    private var rotationVisualCompletedGeneration: Int?
    private var rotationVisualResolutionReason: String?

    func bindRotationState(_ state: TimelineRotationState) {
        guard rotationState !== state else { return }
        rotationState = state
        state.visualHandoffResolved = { [weak self] generation, verified, reason in
            self?.resolveRotationVisualHandoff(
                generation: generation,
                verified: verified,
                reason: reason
            )
        }
    }

    override func viewWillTransition(
        to size: CGSize,
        with coordinator: any UIViewControllerTransitionCoordinator
    ) {
        rotationGeneration += 1
        let generation = rotationGeneration
        let visualSnapshot = captureRotationVisualSnapshotIfEligible()
        rotationStartedAt = .now
        rotationTargetSize = size
        lastLoggedLayoutSize = nil
        rotationState?.begin(to: size)
        installRotationVisualSnapshot(
            visualSnapshot,
            generation: generation
        )
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
        updateRotationVisualSnapshotFrame()
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
        rotationVisualCompletedGeneration = generation
        if cancelled {
            rotationVisualResolvedGeneration = generation
            rotationVisualResolutionReason = "host-cancelled"
        }
        releaseRotationVisualHandoffIfReady(generation: generation)
        rotationStartedAt = nil
        rotationTargetSize = nil
        lastLoggedLayoutSize = nil
    }

    func discardRotationVisualHandoff(reason: String) {
        guard let snapshot = rotationVisualSnapshot else { return }
        let generation = rotationVisualGeneration ?? -1
        snapshot.layer.removeAllAnimations()
        snapshot.removeFromSuperview()
        resetRotationVisualHandoff()
        Self.logger.info(
            "Rotation visual snapshot released generation=\(generation) reason=\(reason, privacy: .public) immediate=true"
        )
    }

    private func captureRotationVisualSnapshotIfEligible() -> UIView? {
        guard let rotationState,
              let destination = selectedTimelineDestination,
              rotationState.isVisualHandoffEligible(for: destination),
              let contentView = selectedViewController?.viewIfLoaded,
              contentView.window != nil,
              !contentView.bounds.isEmpty
        else { return nil }

        return contentView.snapshotView(afterScreenUpdates: false)
    }

    private func installRotationVisualSnapshot(
        _ candidate: UIView?,
        generation: Int
    ) {
        rotationVisualResolvedGeneration = nil
        rotationVisualCompletedGeneration = nil
        rotationVisualResolutionReason = nil

        if let snapshot = rotationVisualSnapshot {
            snapshot.layer.removeAllAnimations()
            snapshot.alpha = 1
            rotationVisualGeneration = generation
            Self.logger.info(
                "Rotation visual snapshot captured generation=\(generation) inherited=true frame=\(Self.describe(snapshot.frame), privacy: .public)"
            )
            return
        }
        guard let candidate,
              let contentView = selectedViewController?.viewIfLoaded
        else {
            rotationVisualGeneration = nil
            return
        }

        candidate.isUserInteractionEnabled = false
        candidate.accessibilityElementsHidden = true
        candidate.frame = contentView.convert(contentView.bounds, to: view)
        candidate.clipsToBounds = true
        view.insertSubview(candidate, belowSubview: tabBar)
        rotationVisualSnapshot = candidate
        rotationVisualGeneration = generation
        Self.logger.info(
            "Rotation visual snapshot captured generation=\(generation) inherited=false frame=\(Self.describe(candidate.frame), privacy: .public)"
        )
    }

    private func updateRotationVisualSnapshotFrame() {
        guard let snapshot = rotationVisualSnapshot,
              let contentView = selectedViewController?.viewIfLoaded,
              contentView.window != nil
        else { return }
        snapshot.frame = contentView.convert(contentView.bounds, to: view)
    }

    private func resolveRotationVisualHandoff(
        generation: Int,
        verified: Bool,
        reason: String
    ) {
        guard rotationVisualGeneration == generation else { return }
        rotationVisualResolvedGeneration = generation
        rotationVisualResolutionReason = reason
        let hostCompleted = rotationVisualCompletedGeneration == generation
        Self.logger.info(
            "Rotation visual destination ready generation=\(generation) verified=\(verified) reason=\(reason, privacy: .public) hostCompleted=\(hostCompleted)"
        )
        releaseRotationVisualHandoffIfReady(generation: generation)
    }

    private func releaseRotationVisualHandoffIfReady(generation: Int) {
        guard rotationVisualGeneration == generation,
              rotationVisualResolvedGeneration == generation,
              rotationVisualCompletedGeneration == generation,
              let snapshot = rotationVisualSnapshot
        else { return }

        let reason = rotationVisualResolutionReason ?? "resolved"
        let duration = UIAccessibility.isReduceMotionEnabled ? 0 : 0.12
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseOut, .allowUserInteraction]
        ) {
            snapshot.alpha = 0
        } completion: { [weak self, weak snapshot] _ in
            guard self?.rotationVisualGeneration == generation else { return }
            snapshot?.removeFromSuperview()
            self?.resetRotationVisualHandoff()
        }
        Self.logger.info(
            "Rotation visual snapshot released generation=\(generation) reason=\(reason, privacy: .public) immediate=false"
        )
    }

    private func resetRotationVisualHandoff() {
        rotationVisualSnapshot = nil
        rotationVisualGeneration = nil
        rotationVisualResolvedGeneration = nil
        rotationVisualCompletedGeneration = nil
        rotationVisualResolutionReason = nil
    }

    private var selectedTimelineDestination: NativeTabDestination? {
        switch selectedTab?.identifier {
        case "photos": .photos
        case "videos": .videos
        default: nil
        }
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
