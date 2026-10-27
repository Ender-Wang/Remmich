import Combine
import Nuke
import OSLog
import SwiftUI
import UIKit

/// Session-owned bridge. Geometry is read on demand for viewer dismissal and
/// never published through SwiftUI for each pinch/scroll frame.
@MainActor
final class TimelineSemanticRuntime {
    weak var controller: TimelineSemanticCollectionController?

    func dismissalTarget(assetID: String, aspectRatio: Double) -> AssetViewerDismissalTarget? {
        controller?.dismissalTarget(assetID: assetID, aspectRatio: aspectRatio)
    }

    func changeScale(coarser: Bool) {
        controller?.changeScale(coarser: coarser)
    }
}

struct TimelineSemanticCollectionView: UIViewControllerRepresentable {
    let catalog: TimelineSemanticCatalog
    let revision: UInt64
    let scale: TimelineSemanticScale
    let media: MediaLibraryController
    let namespace: Namespace.ID?
    let bottomClearance: CGFloat
    var topClearance: CGFloat = 0
    let runtime: TimelineSemanticRuntime
    let latestRequest: Int
    let isActive: Bool
    let hiddenThumbnailID: String?
    let hiddenLivePhotoID: String?
    let selectAsset: (TimelineAssetSummary, [TimelineAssetSummary]) -> Void
    let selectGroup: (PhotosRangeRoute, String?) -> Void
    let scaleChanged: (TimelineSemanticScale) -> Void
    var transitionScaleChanged: (TimelineSemanticScale) -> Void = { _ in }
    let scrolled: (CGFloat, CGFloat, Bool) -> Void
    let visibleAssetsChanged: ([TimelineAssetSummary], MediaPixelSize, TimelineSemanticScale) -> Void
    let refresh: () async -> Void
    var loadOlder: () async -> Void = {}
    var focusChanged: (TimelineAssetSummary) -> Void = { _ in }

    func makeUIViewController(context _: Context) -> TimelineSemanticCollectionController {
        let controller = TimelineSemanticCollectionController()
        runtime.controller = controller
        controller.update(self)
        return controller
    }

    func updateUIViewController(_ controller: TimelineSemanticCollectionController, context _: Context) {
        runtime.controller = controller
        controller.update(self)
    }

    static func dismantleUIViewController(_ controller: TimelineSemanticCollectionController, coordinator _: ()) {
        controller.stop()
    }
}

private final class TimelineSemanticCollectionLayout: UICollectionViewLayout {
    var frames: [CGRect] = []
    var height: CGFloat = 0

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0, height: height)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        frames.indices.compactMap { index in
            frames[index].intersects(rect) ? layoutAttributesForItem(at: IndexPath(item: index, section: 0)) : nil
        }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.section == 0, frames.indices.contains(indexPath.item),
              let collectionView, collectionView.numberOfSections > 0,
              indexPath.item < collectionView.numberOfItems(inSection: 0) else { return nil }
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = frames[indexPath.item]
        return attributes
    }
}

@MainActor
private final class TimelineSemanticCoverVisibility: ObservableObject {
    @Published var isVisible = false
}

private struct TimelineSemanticObservedVisibility<Content: View>: View {
    @ObservedObject var visibility: TimelineSemanticCoverVisibility
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
        content(visibility.isVisible)
    }
}

final class TimelineSemanticCollectionCell: UICollectionViewCell {
    fileprivate let coverVisibility = TimelineSemanticCoverVisibility()
    var coverAssetID: String?
    var coverImage: UIImage?
    var coverImageAssetID: String?
    var nodeID: String?
    private var hostingController: UIHostingController<AnyView>?
    private(set) var hasHostedContent = false

    func setHostedContent(_ content: some View, parent: UIViewController) {
        clipsToBounds = true
        contentView.clipsToBounds = true
        let root = AnyView(content)
        if let hostingController {
            hostingController.rootView = root
        } else {
            let controller = UIHostingController(rootView: root)
            controller.safeAreaRegions = []
            controller.view.backgroundColor = .clear
            controller.view.clipsToBounds = true
            controller.view.frame = contentView.bounds
            controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            parent.addChild(controller)
            contentView.addSubview(controller.view)
            controller.didMove(toParent: parent)
            hostingController = controller
        }
        hasHostedContent = true
    }

    func clearHostedContent() {
        guard hasHostedContent else { return }
        hostingController?.rootView = AnyView(EmptyView())
        coverVisibility.isVisible = false
        hasHostedContent = false
    }

    var hostedSafeAreaRegions: SafeAreaRegions? {
        hostingController?.safeAreaRegions
    }

    var hostedViewFrame: CGRect? {
        hostingController?.view.frame
    }

    var hostedViewClipsToBounds: Bool {
        hostingController?.view.clipsToBounds == true
    }

    /// Geometry belongs to the deterministic collection layout. SwiftUI's
    /// hosted GeometryReader must not self-size cells during scrolling.
    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        layoutAttributes
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        hostingController?.view.frame = contentView.bounds
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        clearHostedContent()
        coverAssetID = nil
        coverImage = nil
        coverImageAssetID = nil
        nodeID = nil
        isAccessibilityElement = false
        accessibilityLabel = nil
        accessibilityIdentifier = nil
        accessibilityTraits = []
        alpha = 1
    }

    isolated deinit {
        hostingController?.willMove(toParent: nil)
        hostingController?.view.removeFromSuperview()
        hostingController?.removeFromParent()
    }
}

nonisolated enum TimelineSemanticTransitionPolicy {
    static let sourceLimit = 64
    static let sourceOverscan: CGFloat = 0.15
    static let warmLimit = 64

    static func sourceIndexes(
        items: [TimelineSemanticProjection.Item],
        viewport: CGRect,
        focus: CGPoint
    ) -> [Int] {
        let area = viewport.insetBy(dx: 0, dy: -viewport.height * sourceOverscan)
        let candidates = items.enumerated().filter {
            !$0.element.isHeader && $0.element.frame.intersects(area)
        }
        let visible = candidates.filter { $0.element.frame.intersects(viewport) }
        let visibleIndexes = Set(visible.map(\.offset))
        let overscan = candidates.filter { !visibleIndexes.contains($0.offset) }.sorted {
            hypot($0.element.frame.midX - focus.x, $0.element.frame.midY - focus.y)
                < hypot($1.element.frame.midX - focus.x, $1.element.frame.midY - focus.y)
        }
        return Array((visible + overscan).prefix(max(sourceLimit, visible.count)).map(\.offset))
    }

    static func warmIndexes(
        items: [TimelineSemanticProjection.Item],
        area: CGRect,
        focus: CGPoint
    ) -> [Int] {
        items.enumerated().filter {
            !$0.element.isHeader && $0.element.frame.intersects(area)
        }.sorted {
            hypot($0.element.frame.midX - focus.x, $0.element.frame.midY - focus.y)
                < hypot($1.element.frame.midX - focus.x, $1.element.frame.midY - focus.y)
        }.prefix(warmLimit).map(\.offset)
    }
}

@MainActor
final class TimelineSemanticCollectionController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate, UIGestureRecognizerDelegate {
    private static let signposter = OSSignposter(subsystem: "io.github.ender-wang.Remmich", category: "SemanticZoom")
    private var input: TimelineSemanticCollectionView?
    private var deferredInput: TimelineSemanticCollectionView?
    private var catalog: TimelineSemanticCatalog?
    private var revision: UInt64?
    private var scale: TimelineSemanticScale = .square
    private var projection: TimelineSemanticProjection?
    private let layout = TimelineSemanticCollectionLayout()
    private var collection: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var lastSize = CGSize.zero
    private var lastOffset: CGFloat = 0
    private var lastLatestRequest = 0
    private var lastVisibleIDs = Set<String>()
    private var gesture: TimelineSemanticZoomGesture?
    private var pinchCentroid = CGPoint.zero
    private var target: TimelineSemanticProjection?
    private var focusAssetIndex = 0
    private var targetOffset: CGFloat = 0
    private var animator: UIViewPropertyAnimator?
    private var transitionSurface: UIView?
    private var transitionItems: [TransitionItem] = []
    private var transitionHostingControllers: [UIViewController] = []
    private var transitionHostingControllerPool: [UIHostingController<AnyView>] = []
    private var transitionHostingControllerCursor = 0
    private var transitionChromeControllers: [TransitionChromeKey: UIHostingController<AnyView>] = [:]
    private var transitionChromeKeysInUse = Set<TransitionChromeKey>()
    private var transitionChromeWarmTask: Task<Void, Never>?
    private var transitionChromeWarmGeneration: UInt64 = 0
    private var windowExpansionTask: Task<Void, Never>?
    private var olderExpansionRearmOffset: CGFloat?
    private var newerExpansionRearmOffset: CGFloat?
    private var handoffImages: [String: UIImage] = [:]
    private var representativeAssets: [String: Int] = [:]
    private var isInstalling = false
    private(set) var installationCount = 0
    private var isExpanding = false
    private var hiddenThumbnailID: String?
    private var hiddenLivePhotoID: String?
    private var loadOlderTask: Task<Void, Never>?
    private var viewportTask: Task<Void, Never>?
    private var transitionWarmTask: Task<Void, Never>?
    private var itemIndexes: [String: Int] = [:]
    private var lastPublishedTarget: MediaPixelSize?
    private var lastPublishedScale: TimelineSemanticScale?
    private var transitionPrefetcher: ImagePrefetcher?
    private var warmPipeline: ImagePipeline?
    private var warmedRequests: [MediaRequestDescriptor: ImageRequest] = [:]
    private var localTransitionTasks: [Task<Void, Never>] = []
    private var isPresentationCrossfading = false

    private struct TransitionItem {
        let view: UIView
        let start: CGRect
        let end: CGRect
        let incoming: Bool
        let disappears: Bool
        let startRadius: CGFloat
        let endRadius: CGFloat
        var isChrome = false
        var usesLayerTransform = false
    }

    private struct TransitionChromeKey: Hashable {
        let role: String
        let identity: String
        let signature: String
        let widthPixels: Int
        let heightPixels: Int
        let interfaceStyle: Int
        let contentSizeCategory: String
    }

    private struct TransitionChromePlan {
        let key: TransitionChromeKey
        let content: AnyView
        let size: CGSize
    }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collection.backgroundColor = .clear
        collection.contentInsetAdjustmentBehavior = .never
        collection.automaticallyAdjustsScrollIndicatorInsets = false
        collection.alwaysBounceVertical = true
        collection.delegate = self
        collection.register(TimelineSemanticCollectionCell.self, forCellWithReuseIdentifier: "semantic")
        dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collection) { [weak self] collection, path, _ in
            self?.collectionView(collection, cellForItemAt: path)
        }
        view.addSubview(collection)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self
        pinch.name = "timeline-semantic-pinch"
        pinch.cancelsTouchesInView = true
        collection.addGestureRecognizer(pinch)
        collection.panGestureRecognizer.maximumNumberOfTouches = 1
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(self, action: #selector(refreshRequested), for: .valueChanged)
        collection.refreshControl = refreshControl
        collection.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Show Fewer Items", target: self, selector: #selector(coarsen)),
            UIAccessibilityCustomAction(name: "Show More Items", target: self, selector: #selector(refine)),
        ]
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: TimelineSemanticCollectionController, _: UITraitCollection) in
            controller.rebuildForAppearance()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(receivedMemoryWarning), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.width > 0, view.bounds.height > 0 else { return }
        let changed = lastSize != view.bounds.size
        guard changed else { return }
        let focus = focusedItem(at: CGPoint(x: collection.bounds.midX, y: collection.bounds.midY))
        let focusY = focus.map { $0.frame.midY - collection.contentOffset.y }
        let sourceHeight = max(1, collection.bounds.height)
        let wasAtLatest = isAtLatest
        let wasAtTop = collection.contentOffset.y <= -collection.contentInset.top + 1
        collection.frame = view.bounds
        gesture = nil
        completePresentationCleanup()
        lastSize = view.bounds.size
        guard let catalog else { return }
        let asset = focus.map(representativeIndex) ?? max(0, catalog.assets.count - 1)
        let next = makeProjection(scale: scale, focus: asset)
        install(next, focusing: asset, viewportY: focusY.map { $0 / sourceHeight * view.bounds.height },
                latest: focus == nil || wasAtLatest, alignTop: wasAtTop && !wasAtLatest)
        if catalog.assets.isEmpty {
            loadOlderIfNeeded()
        }
    }

    private func rebuildForAppearance() {
        guard catalog != nil, lastSize.width > 0 else { return }
        interrupted()
        let focus = focusedItem(at: CGPoint(x: collection.bounds.midX, y: collection.bounds.midY))
        let asset = focus.map(representativeIndex) ?? max(0, catalog!.assets.count - 1)
        let wasAtTop = collection.contentOffset.y <= -collection.contentInset.top + 1
        install(makeProjection(scale: scale, focus: asset), focusing: asset,
                viewportY: focus.map { $0.frame.midY - collection.contentOffset.y },
                latest: isAtLatest, alignTop: wasAtTop && !isAtLatest)
    }

    func update(_ value: TimelineSemanticCollectionView) {
        loadViewIfNeeded()
        if gesture != nil || animator != nil {
            deferredInput = value
            if !value.isActive {
                interrupted()
            }
            return
        }
        let previous = input
        input = value
        if let previous, revision == value.revision, scale == value.scale,
           previous.isActive == value.isActive, previous.latestRequest == value.latestRequest,
           previous.hiddenThumbnailID == value.hiddenThumbnailID, previous.hiddenLivePhotoID == value.hiddenLivePhotoID,
           abs(previous.bottomClearance - value.bottomClearance) < 0.5,
           abs(previous.topClearance - value.topClearance) < 0.5,
           previous.media === value.media
        {
            return
        }
        collection.isUserInteractionEnabled = value.isActive
        collection.accessibilityElementsHidden = !value.isActive
        let oldFocus = focusedItem(at: CGPoint(x: collection.bounds.midX, y: collection.bounds.midY))
        let oldFocusID = oldFocus.flatMap { item in catalog.map { $0.assets[representativeIndex(item)].id } }
        let focusY = oldFocus.map { $0.frame.midY - collection.contentOffset.y }
        let latest = projection == nil || isAtLatest
        let wasAtTop = collection.contentOffset.y <= -collection.contentInset.top + 1
        let needsCatalog = revision != value.revision
        catalog = value.catalog
        revision = value.revision
        let needsScale = scale != value.scale
        scale = value.scale
        let bottomInsetChanged = abs(collection.contentInset.bottom - value.bottomClearance) > 0.5
        let topInsetChanged = abs(collection.contentInset.top - value.topClearance) > 0.5
        let latestRequested = value.latestRequest != lastLatestRequest
        lastLatestRequest = value.latestRequest
        let jumpToLatest = latestRequested && value.isActive
        let oldOffsetY = collection.contentOffset.y
        isInstalling = true
        collection.contentInset = UIEdgeInsets(top: value.topClearance, left: 0, bottom: value.bottomClearance, right: 0)
        collection.verticalScrollIndicatorInsets = UIEdgeInsets(
            top: value.topClearance + TimelineSemanticProjection.topPadding,
            left: 0,
            bottom: value.bottomClearance + TimelineSemanticProjection.bottomPadding,
            right: 0
        )
        if topInsetChanged && !bottomInsetChanged {
            collection.contentOffset.y = wasAtTop && !latest ? -value.topClearance : oldOffsetY
            lastOffset = collection.contentOffset.y
        }
        isInstalling = false
        let projectionMissing = projection == nil
        if needsCatalog || needsScale {
            representativeAssets = [:]
        }
        // A latest request can arrive in the same SwiftUI transaction as a new
        // catalog. Build its final destination once instead of installing the
        // old focus and immediately replacing it with the newest window.
        if jumpToLatest {
            if lastSize.width > 0 {
                let focus = max(0, value.catalog.assets.count - 1)
                install(makeProjection(scale: scale, focus: focus), focusing: focus, viewportY: nil, latest: true,
                        refreshContents: needsCatalog)
            }
        } else if needsCatalog || needsScale || projectionMissing || bottomInsetChanged {
            let focus = oldFocusID.flatMap { value.catalog.assetIndexes[$0] } ?? max(0, value.catalog.assets.count - 1)
            if lastSize.width > 0 {
                install(makeProjection(scale: scale, focus: focus, range: needsCatalog || needsScale || projectionMissing ? nil : projection?.nodeRange),
                        focusing: focus, viewportY: focusY, latest: latest && !needsScale,
                        refreshContents: needsCatalog, alignTop: wasAtTop && !latest && !needsScale)
            }
        }
        if hiddenThumbnailID != value.hiddenThumbnailID || hiddenLivePhotoID != value.hiddenLivePhotoID {
            hiddenThumbnailID = value.hiddenThumbnailID
            hiddenLivePhotoID = value.hiddenLivePhotoID
            for path in collection.indexPathsForVisibleItems {
                configure(path)
            }
        }
        if previous?.isActive != value.isActive {
            for path in collection.indexPathsForVisibleItems {
                configure(path)
            }
            if value.isActive {
                publishViewport()
            }
        }
        if topInsetChanged, !bottomInsetChanged {
            publishViewport()
        }
    }

    private var isAtLatest: Bool {
        guard let projection, let catalog else { return true }
        return projection.nodeRange.upperBound == catalog.count(at: scale)
            && layout.height - collection.contentOffset.y - collection.bounds.height + collection.contentInset.bottom < 24
    }

    private func makeProjection(scale: TimelineSemanticScale, focus: Int, range: Range<Int>? = nil) -> TimelineSemanticProjection {
        let interval = Self.signposter.beginInterval("ProjectionBuild", id: Self.signposter.makeSignpostID())
        defer { Self.signposter.endInterval("ProjectionBuild", interval) }
        return TimelineSemanticProjection.build(catalog: catalog!, scale: scale, focusAssetIndex: focus, size: lastSize,
                                                isPhone: traitCollection.userInterfaceIdiom == .phone,
                                                dark: traitCollection.userInterfaceStyle == .dark, requestedRange: range)
            .bottomAligned(minimumHeight: max(0, collection.bounds.height - collection.contentInset.bottom))
    }

    private func offset(for next: TimelineSemanticProjection, focus: Int, viewportY: CGFloat?, latest: Bool) -> CGFloat {
        let height = max(next.height, collection.bounds.height - collection.contentInset.bottom)
        let maximum = max(0, height - collection.bounds.height + collection.contentInset.bottom)
        guard !latest, let item = next.items.first(where: { !$0.isHeader && $0.assetRange.contains(focus) }) else { return maximum }
        return min(maximum, max(-collection.contentInset.top, item.frame.midY - (viewportY ?? collection.bounds.height / 2)))
    }

    private func install(_ next: TimelineSemanticProjection, focusing focus: Int, viewportY: CGFloat?, latest: Bool,
                         refreshContents: Bool = false, alignTop: Bool = false)
    {
        installationCount += 1
        let interval = Self.signposter.beginInterval("CollectionInstall", id: Self.signposter.makeSignpostID())
        defer { Self.signposter.endInterval("CollectionInstall", interval) }
        isInstalling = true
        let oldScale = projection?.scale
        let replaceScaleBehindTransition = oldScale != nil && oldScale != next.scale && transitionSurface != nil
        let oldIDs = Set(dataSource.snapshot().itemIdentifiers)
        if oldScale != next.scale || refreshContents {
            olderExpansionRearmOffset = nil
            newerExpansionRearmOffset = nil
        }
        projection = next
        itemIndexes = Dictionary(uniqueKeysWithValues: next.items.enumerated().map { ($0.element.id, $0.offset) })
        scale = next.scale
        layout.frames = next.items.map(\.frame)
        layout.height = max(next.height, collection.bounds.height - collection.contentInset.bottom)
        let y = alignTop ? -collection.contentInset.top : offset(for: next, focus: focus, viewportY: viewportY, latest: latest)
        UIView.performWithoutAnimation {
            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0])
            let ids = next.items.map(\.id)
            snapshot.appendItems(ids)
            let applyInterval = Self.signposter.beginInterval("SnapshotApply", id: Self.signposter.makeSignpostID())
            if replaceScaleBehindTransition {
                // The transition surface already owns the visible pixels. A
                // full scale change replaces its item identities, so avoid
                // diffable batch rebasing of cells that cannot be reused.
                dataSource.applySnapshotUsingReloadData(snapshot)
            } else {
                dataSource.apply(snapshot, animatingDifferences: false)
            }
            Self.signposter.endInterval("SnapshotApply", applyInterval)
            let layoutInterval = Self.signposter.beginInterval("CollectionLayout", id: Self.signposter.makeSignpostID())
            layout.invalidateLayout()
            collection.contentOffset = CGPoint(x: 0, y: y)
            collection.layoutIfNeeded()
            Self.signposter.endInterval("CollectionLayout", layoutInterval)
            if !replaceScaleBehindTransition, oldScale != next.scale || refreshContents {
                let configureInterval = Self.signposter.beginInterval("VisibleCellConfigure", id: Self.signposter.makeSignpostID())
                for path in collection.indexPathsForVisibleItems {
                    if let id = dataSource.itemIdentifier(for: path), oldIDs.contains(id) {
                        configure(path)
                    }
                }
                Self.signposter.endInterval("VisibleCellConfigure", configureInterval)
            }
        }
        lastOffset = y
        isInstalling = false
        let viewportInterval = Self.signposter.beginInterval("ViewportPublish", id: Self.signposter.makeSignpostID())
        publishViewport()
        Self.signposter.endInterval("ViewportPublish", viewportInterval)
    }

    func collectionView(_: UICollectionView, numberOfItemsInSection _: Int) -> Int {
        projection?.items.count ?? 0
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "semantic", for: indexPath)
        configure(indexPath, cell: cell as? TimelineSemanticCollectionCell)
        return cell
    }

    private func configure(_ path: IndexPath, cell supplied: TimelineSemanticCollectionCell? = nil) {
        guard let input, let catalog, let projection, projection.items.indices.contains(path.item),
              let cell = supplied ?? collection.cellForItem(at: path) as? TimelineSemanticCollectionCell else { return }
        let item = projection.items[path.item]
        if cell.nodeID != item.id {
            cell.coverImage = nil
            cell.coverImageAssetID = nil
        }
        cell.contentView.isUserInteractionEnabled = true
        cell.clipsToBounds = true
        cell.contentView.clipsToBounds = true
        cell.isAccessibilityElement = false
        cell.accessibilityIdentifier = nil
        cell.accessibilityLabel = nil
        cell.accessibilityTraits = []
        cell.nodeID = item.id
        let assetIndex = representativeIndex(item)
        let asset = catalog.assets[assetIndex]
        let coversVisible = input.isActive && gesture == nil && transitionSurface == nil
        if cell.coverVisibility.isVisible != coversVisible {
            cell.coverVisibility.isVisible = coversVisible
        }
        cell.alpha = transitionSurface == nil || isPresentationCrossfading ? 1 : 0
        if item.isHeader {
            let date = catalog.assets[item.assetRange.lowerBound].capturedAt
            cell.setHostedContent(
                AssetSectionHeader(title: TimelineCaptureDateFormatting.string(from: date, dateStyle: .long, timeStyle: .none),
                                   subtitle: "\(item.assetRange.count.formatted()) items"),
                parent: self
            )
        } else if scale.isAssets {
            cell.coverAssetID = asset.id
            cell.setHostedContent(
                TimelineAssetThumbnail(asset: asset, media: input.media,
                                       assetLayout: projection.scale == .square ? .square : .naturalAspect,
                                       requestSide: max(item.frame.width, item.frame.height),
                                       visibilityChanged: { _, _ in }, viewportChanged: { _, _ in },
                                       transitionNamespace: input.namespace,
                                       assetSelected: { [weak self] selected in
                                           guard self?.gesture == nil, self?.animator == nil else { return }
                                           input.selectAsset(selected, Array(catalog.assets[max(0, assetIndex - 80) ..< min(catalog.assets.count, assetIndex + 81)].reversed()))
                                       },
                                       placeholderImage: handoffImages[item.id],
                                       imageLoaded: { [weak cell] image in
                                           guard cell?.nodeID == item.id, cell?.coverAssetID == asset.id else { return }
                                           cell?.coverImage = image
                                           cell?.coverImageAssetID = asset.id
                                       },
                                       hiddenLivePhotoBadgeAssetID: input.hiddenLivePhotoID,
                                       hiddenReturningThumbnailAssetID: input.hiddenThumbnailID),
                parent: self
            )
        } else {
            let group = catalog.groups[scale]![item.nodeIndex]
            let coverCount = min(TimelineGroupedCatalogEntry.coverLimit, item.assetRange.count)
            var covers = (0 ..< coverCount).map { slot in
                catalog.assets[item.assetRange.lowerBound + slot * (item.assetRange.count - 1) / max(1, coverCount - 1)]
            }
            covers.removeAll { $0.id == asset.id }
            covers.insert(asset, at: 0)
            let motion = TimelineRangeCoverMotion(
                rotates: !(scale == .day && item.isFeatured),
                durationScale: item.isFeatured && scale != .day ? 1.5 : 1,
                initialDelay: Double(TimelineRangeMosaicPlanner.stableSeed(item.id) % 1000) / 1000 * TimelineCoverAnimation.cycleDuration
            )
            cell.coverAssetID = asset.id
            let contentID = "\(item.id):\(revision ?? 0)"
            let placeholderImage = handoffImages[item.id]
            let coverVisibility = cell.coverVisibility
            cell.setHostedContent(
                TimelineSemanticObservedVisibility(visibility: coverVisibility) { [weak cell] visible in
                    PhotosRangeCard(title: group.route.navigationTitle, count: group.assets.count,
                                    systemImage: "calendar", assets: covers, media: input.media,
                                    motion: motion, externallyVisible: visible,
                                    placeholderImage: placeholderImage,
                                    imageLoaded: { [weak cell] assetID, image in
                                        guard cell?.nodeID == item.id, cell?.coverAssetID == assetID else { return }
                                        cell?.coverImage = image
                                        cell?.coverImageAssetID = assetID
                                    },
                                    onCoverChanged: { [weak cell] assetID in
                                        guard cell?.nodeID == item.id else { return }
                                        if cell?.coverAssetID != assetID {
                                            cell?.coverImage = nil
                                            cell?.coverImageAssetID = nil
                                        }
                                        cell?.coverAssetID = assetID
                                    })
                                    .id(contentID)
                },
                parent: self
            )
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = "\(group.route.navigationTitle), \(group.assets.count) items"
            cell.accessibilityTraits = .button
        }
    }

    func collectionView(_: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt _: IndexPath) {
        // Cancel hosted thumbnail/slideshow tasks immediately when virtualized out.
        (cell as? TimelineSemanticCollectionCell)?.clearHostedContent()
    }

    func collectionView(_: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        if (cell as? TimelineSemanticCollectionCell)?.hasHostedContent == false {
            configure(indexPath, cell: cell as? TimelineSemanticCollectionCell)
        }
    }

    func collectionView(_: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard gesture == nil, animator == nil, let input, let catalog, let projection,
              projection.items.indices.contains(indexPath.item), !scale.isAssets else { return }
        let item = projection.items[indexPath.item]
        guard !item.isHeader else { return }
        let cell = collection.cellForItem(at: indexPath) as? TimelineSemanticCollectionCell
        input.selectGroup(catalog.groups[scale]![item.nodeIndex].route, cell?.coverAssetID)
    }

    private func representativeIndex(_ item: TimelineSemanticProjection.Item) -> Int {
        if let catalog, let index = itemIndexes[item.id],
           let cell = collection.cellForItem(at: IndexPath(item: index, section: 0)) as? TimelineSemanticCollectionCell,
           let id = cell.coverAssetID, let assetIndex = catalog.assetIndexes[id], item.assetRange.contains(assetIndex)
        {
            return assetIndex
        }
        if let preferred = representativeAssets[item.id], item.assetRange.contains(preferred) {
            return preferred
        }
        return item.assetRange.upperBound - 1
    }

    private func focusedItem(at point: CGPoint) -> TimelineSemanticProjection.Item? {
        projection?.items.filter { !$0.isHeader && $0.frame.intersects(collection.bounds) }.min {
            hypot($0.frame.midX - point.x, $0.frame.midY - point.y) < hypot($1.frame.midX - point.x, $1.frame.midY - point.y)
        }
    }

    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            finishPresentation()
            cancelTransitionWarmup()
            guard input?.isActive == true, let focused = focusedItem(at: recognizer.location(in: collection)) else { return }
            focusAssetIndex = representativeIndex(focused)
            pinchCentroid = recognizer.location(in: view)
            gesture = TimelineSemanticZoomGesture()
            collection.setContentOffset(collection.contentOffset, animated: false)
            collection.panGestureRecognizer.isEnabled = false
        case .changed:
            guard gesture != nil else { return }
            gesture?.update(magnification: recognizer.scale)
            if target == nil, let coarser = gesture?.coarser, let next = scale.adjacent(coarser: coarser) {
                prepareTransition(to: next)
            }
            renderProgress(gesture?.progress ?? 0)
        case .ended:
            guard let gesture else { return }
            settle(commit: gesture.commits(magnification: recognizer.scale) && target != nil)
        case .cancelled, .failed:
            cancelTracking()
        default: break
        }
    }

    private func prepareTransition(to nextScale: TimelineSemanticScale) {
        guard let source = projection, let catalog else { return }
        let next = makeProjection(scale: nextScale, focus: focusAssetIndex)
        guard !next.items.isEmpty else { return }
        target = next
        input?.transitionScaleChanged(nextScale)
        targetOffset = offset(for: next, focus: focusAssetIndex, viewportY: pinchCentroid.y, latest: false)
        collection.panGestureRecognizer.isEnabled = false
        handoffImages = [:]
        cancelTransitionChromeWarmup()
        transitionHostingControllerCursor = 0
        transitionChromeKeysInUse = []
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let surface = UIView(frame: view.bounds)
        surface.isUserInteractionEnabled = false
        surface.clipsToBounds = true
        view.addSubview(surface)
        transitionSurface = surface

        // Include a bounded apron around the source, and every tile that can
        // appear in the destination viewport. Target coverage is unconditional:
        // a neighboring period can arrive even without a visible source member.
        let sourceIndexes = TimelineSemanticTransitionPolicy.sourceIndexes(
            items: source.items,
            viewport: collection.bounds,
            focus: CGPoint(x: pinchCentroid.x, y: collection.contentOffset.y + pinchCentroid.y)
        )
        let sources = sourceIndexes.map { (offset: $0, element: source.items[$0]) }
        let targetArea = CGRect(x: 0, y: targetOffset, width: view.bounds.width, height: view.bounds.height)
            .insetBy(dx: 0, dy: -view.bounds.height * 0.25)
        let destinations = next.items.filter { !$0.isHeader && $0.frame.intersects(targetArea) }
        var selectedSources: [String: String] = [:]
        var targetRepresentatives: [String: Int] = [:]
        for destination in destinations {
            let selected = sources.filter { $0.element.assetRange.overlaps(destination.assetRange) }.min {
                distance($0.element.frame, offset: collection.contentOffset.y)
                    < distance($1.element.frame, offset: collection.contentOffset.y)
            }
            if let selected {
                selectedSources[destination.id] = selected.element.id
                let representative = representativeIndex(selected.element)
                targetRepresentatives[destination.id] = destination.assetRange.contains(representative)
                    ? representative : destination.assetRange.lowerBound
            } else {
                targetRepresentatives[destination.id] = destination.assetRange.lowerBound
            }
        }

        var represented = Set<String>()
        var snapshotsContainingChrome = Set<String>()
        for (index, item) in sources {
            let representative = representativeIndex(item)
            guard let destination = destinations.first(where: { $0.assetRange.contains(representative) }) else { continue }
            let asset = catalog.assets[representative]
            let start = imageRect(item: item, scale: scale, asset: asset).offsetBy(dx: 0, dy: -collection.contentOffset.y)
            let end = imageRect(item: destination, scale: nextScale, asset: asset).offsetBy(dx: 0, dy: -targetOffset)
            let sourceCell = collection.cellForItem(at: IndexPath(item: index, section: 0)) as? TimelineSemanticCollectionCell
            let image = sourceCell?.coverImageAssetID == asset.id
                ? sourceCell?.coverImage
                : cachedImage(asset: asset, frame: item.frame)
            let snapshot: UIView
            if let image {
                let imageView = UIImageView(image: image)
                imageView.contentMode = .scaleAspectFill
                snapshot = imageView
            } else if let cell = collection.cellForItem(at: IndexPath(item: index, section: 0)),
                      let captured = cell.resizableSnapshotView(
                          from: imageRect(item: item, scale: scale, asset: asset).offsetBy(dx: -item.frame.minX, dy: -item.frame.minY),
                          afterScreenUpdates: false, withCapInsets: .zero
                      )
            {
                snapshot = captured
                if !scale.isAssets {
                    snapshotsContainingChrome.insert(item.id)
                }
            } else {
                continue
            }
            let keepsCover = selectedSources[destination.id] == item.id
                && targetRepresentatives[destination.id] == representative
                && represented.insert(destination.id).inserted
            if keepsCover {
                snapshot.accessibilityIdentifier = "semantic-zoom-target:\(destination.id)"
                if let image {
                    handoffImages[destination.id] = image
                }
            }
            addTransition(snapshot, start: start, end: end, incoming: false, disappears: !keepsCover,
                          startRadius: radius(scale), endRadius: radius(nextScale), to: surface)
        }

        for destination in destinations where !represented.contains(destination.id) {
            let representative = targetRepresentatives[destination.id]!
            let asset = catalog.assets[representative]
            let end = imageRect(item: destination, scale: nextScale, asset: asset).offsetBy(dx: 0, dy: -targetOffset)
            let sourceItem = sources.first(where: { $0.element.assetRange.overlaps(destination.assetRange) })?.element
            let start: CGRect
            if let sourceItem {
                start = imageRect(item: sourceItem, scale: scale, asset: asset).offsetBy(dx: 0, dy: -collection.contentOffset.y)
            } else {
                let side = min(end.width, end.height)
                start = CGRect(x: end.midX - side / 2,
                               y: end.midY < view.bounds.midY ? -side : view.bounds.height,
                               width: side, height: side)
            }
            let cached = cachedImage(asset: asset, frame: destination.frame)
            if let cached {
                handoffImages[destination.id] = cached
            }
            let imageView = UIImageView(image: cached)
            imageView.contentMode = .scaleAspectFill
            imageView.backgroundColor = .tertiarySystemFill
            imageView.accessibilityIdentifier = "semantic-zoom-target:\(destination.id)"
            if imageView.image == nil {
                loadLocalTransitionImage(into: imageView, destinationID: destination.id, asset: asset,
                                         frame: destination.frame, scale: nextScale, surface: surface)
            }
            addTransition(imageView, start: start, end: end, incoming: true, disappears: false,
                          startRadius: radius(scale), endRadius: radius(nextScale), to: surface)
        }
        representativeAssets.merge(targetRepresentatives, uniquingKeysWith: { _, new in new })
        let assetLayoutOnly = scale.isAssets && nextScale.isAssets
        var carriedHeaderIDs = Set<String>()
        let sourceChromeArea = CGRect(x: 0, y: collection.contentOffset.y,
                                      width: collection.bounds.width, height: collection.bounds.height)
        for sourceItem in source.items where sourceItem.frame.intersects(sourceChromeArea)
            && (sourceItem.isHeader || !scale.isAssets)
            && !snapshotsContainingChrome.contains(sourceItem.id)
        {
            let start = sourceItem.frame.offsetBy(dx: 0, dy: -collection.contentOffset.y)
            let matchingHeader = assetLayoutOnly && sourceItem.isHeader
                ? next.items.first(where: { $0.isHeader && $0.id == sourceItem.id }) : nil
            let end = if let matchingHeader {
                matchingHeader.frame.offsetBy(dx: 0, dy: -targetOffset)
            } else if assetLayoutOnly, sourceItem.isHeader {
                start
            } else {
                destinations.first(where: { $0.assetRange.overlaps(sourceItem.assetRange) })
                    .map { $0.frame.offsetBy(dx: 0, dy: -targetOffset) } ?? start
            }
            guard let plan = transitionChromePlan(for: sourceItem, scale: scale, catalog: catalog) else { continue }
            let chrome = transitionChromeView(plan)
            if sourceItem.isHeader {
                chrome.accessibilityIdentifier = "semantic-zoom-header:\(sourceItem.id)"
            }
            if matchingHeader != nil {
                carriedHeaderIDs.insert(sourceItem.id)
            }
            addTransition(chrome, start: start, end: end, incoming: false, disappears: matchingHeader == nil,
                          startRadius: 0, endRadius: 0, to: surface, hosted: true)
            transitionItems[transitionItems.count - 1].isChrome = true
        }
        for destination in next.items where destination.frame.intersects(targetArea) && (destination.isHeader || !nextScale.isAssets) {
            if assetLayoutOnly && destination.isHeader && carriedHeaderIDs.contains(destination.id) {
                continue
            }
            let end = destination.frame.offsetBy(dx: 0, dy: -targetOffset)
            guard let plan = transitionChromePlan(for: destination, scale: nextScale, catalog: catalog) else { continue }
            let chrome = transitionChromeView(plan)
            if destination.isHeader {
                chrome.accessibilityIdentifier = "semantic-zoom-header:\(destination.id)"
            }
            let start = assetLayoutOnly && destination.isHeader ? end : end.offsetBy(dx: 0, dy: 12)
            addTransition(chrome, start: start, end: end, incoming: true, disappears: false,
                          startRadius: 0, endRadius: 0, to: surface, hosted: true)
            transitionItems[transitionItems.count - 1].isChrome = true
        }
        if nextScale.isAssets {
            for destination in destinations {
                let representative = targetRepresentatives[destination.id]!
                let asset = catalog.assets[representative]
                guard TimelineAssetBadgeOverlay.isVisible(for: asset) else { continue }
                let end = imageRect(item: destination, scale: nextScale, asset: asset)
                    .offsetBy(dx: 0, dy: -targetOffset)
                let sourceItem = sources.first { $0.element.assetRange.contains(representative) }?.element
                let start = sourceItem.map {
                    imageRect(item: $0, scale: scale, asset: asset)
                        .offsetBy(dx: 0, dy: -collection.contentOffset.y)
                } ?? end.offsetBy(dx: 0, dy: 12)
                let badge = transitionChromeView(badgeTransitionChromePlan(asset: asset, size: end.size))
                addTransition(badge, start: start, end: end,
                              incoming: !scale.isAssets || sourceItem == nil, disappears: false,
                              startRadius: 0, endRadius: 0, to: surface, hosted: true)
            }
        } else if scale.isAssets {
            for (_, sourceItem) in sources {
                let representative = representativeIndex(sourceItem)
                let asset = catalog.assets[representative]
                guard TimelineAssetBadgeOverlay.isVisible(for: asset),
                      let destination = destinations.first(where: { $0.assetRange.contains(representative) })
                else { continue }
                let start = imageRect(item: sourceItem, scale: scale, asset: asset)
                    .offsetBy(dx: 0, dy: -collection.contentOffset.y)
                let end = imageRect(item: destination, scale: nextScale, asset: asset)
                    .offsetBy(dx: 0, dy: -targetOffset)
                let badge = transitionChromeView(badgeTransitionChromePlan(asset: asset, size: start.size))
                addTransition(badge, start: start, end: end, incoming: false, disappears: true,
                              startRadius: 0, endRadius: 0, to: surface, hosted: true)
            }
        }
        for cell in collection.visibleCells {
            cell.alpha = 0
        }
        if !scale.isAssets {
            for path in collection.indexPathsForVisibleItems {
                configure(path)
            }
        }
    }

    private func cachedImage(asset: TimelineAssetSummary, frame: CGRect) -> UIImage? {
        guard let media = input?.media else { return nil }
        let side = min(2048, max(1, Int((max(frame.width, frame.height) * traitCollection.displayScale).rounded(.up))))
        for pixels in [side, 900] {
            let descriptor = MediaRequestDescriptor(assetID: asset.id, updatedAt: asset.thumbnailRevision,
                                                    derivative: .thumbnail, targetPixels: .init(width: pixels, height: pixels))
            if let request = media.imageRequest(for: descriptor), let image = media.pipeline?.cache.cachedImage(for: request, caches: [.memory])?.image {
                return image
            }
        }
        return nil
    }

    private func loadLocalTransitionImage(into imageView: UIImageView, destinationID: String,
                                          asset: TimelineAssetSummary, frame: CGRect,
                                          scale: TimelineSemanticScale, surface: UIView)
    {
        guard let media = input?.media, let pipeline = media.pipeline else { return }
        let descriptor = thumbnailDescriptor(asset: asset, frame: frame, scale: scale)
        guard let pixels = descriptor.targetPixels,
              media.viewerThumbnailFallbackRequest(for: asset, targetPixels: pixels) != nil,
              let request = media.imageRequest(for: descriptor) else { return }
        // Only an already-managed local file may be decoded for the apron.
        // No server request or decode completion gates the gesture or commit.
        let imageTask = pipeline.imageTask(with: request)
        let task = Task { @MainActor [weak self, weak imageView, weak surface] in
            let response = try? await withTaskCancellationHandler { try await imageTask.response } onCancel: { imageTask.cancel() }
            guard !Task.isCancelled, let self, let surface, transitionSurface === surface,
                  let imageView, let response else { return }
            media.retainTimelineThumbnail(response.container, descriptor: descriptor, cacheType: response.cacheType)
            handoffImages[destinationID] = response.image
            if let index = itemIndexes[destinationID],
               let cell = collection.cellForItem(at: IndexPath(item: index, section: 0)) as? TimelineSemanticCollectionCell
            {
                configure(IndexPath(item: index, section: 0), cell: cell)
            }
            UIView.transition(with: imageView, duration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.12,
                              options: [.transitionCrossDissolve, .allowUserInteraction])
            {
                imageView.image = response.image
            }
        }
        localTransitionTasks.append(task)
    }

    private func imageRect(item: TimelineSemanticProjection.Item, scale: TimelineSemanticScale, asset: TimelineAssetSummary) -> CGRect {
        guard scale == .natural else { return item.frame }
        return TimelineThumbnailGeometry.renderedImageRect(in: item.frame.size, aspectRatio: asset.aspectRatio, naturalAspectProgress: 1)
            .offsetBy(dx: item.frame.minX, dy: item.frame.minY)
    }

    private func radius(_ scale: TimelineSemanticScale) -> CGFloat {
        scale == .square ? 0 : scale == .natural ? DesignMetrics.compactCornerRadius : DesignMetrics.defaultCornerRadius
    }

    private func distance(_ frame: CGRect, offset: CGFloat) -> CGFloat {
        hypot(frame.midX - pinchCentroid.x, frame.midY - offset - pinchCentroid.y)
    }

    private func addTransition(_ snapshot: UIView, start: CGRect, end: CGRect, incoming: Bool, disappears: Bool,
                               startRadius: CGFloat, endRadius: CGFloat, to surface: UIView, hosted: Bool = false)
    {
        if hosted {
            snapshot.layer.setAffineTransform(.identity)
        }
        snapshot.frame = hosted ? end : start
        if hosted {
            snapshot.layer.setAffineTransform(Self.transitionTransform(from: end, to: start))
        }
        snapshot.clipsToBounds = true
        snapshot.layer.cornerRadius = startRadius
        snapshot.alpha = incoming ? 0 : 1
        surface.addSubview(snapshot)
        transitionItems.append(TransitionItem(view: snapshot, start: start, end: end, incoming: incoming,
                                              disappears: disappears, startRadius: startRadius, endRadius: endRadius,
                                              usesLayerTransform: hosted))
    }

    static func transitionTransform(from base: CGRect, to target: CGRect) -> CGAffineTransform {
        CGAffineTransform(a: target.width / max(1, base.width), b: 0,
                          c: 0, d: target.height / max(1, base.height),
                          tx: target.midX - base.midX, ty: target.midY - base.midY)
    }

    private func transitionChromeView(_ plan: TransitionChromePlan) -> UIView {
        if let controller = transitionChromeControllers[plan.key],
           transitionChromeKeysInUse.insert(plan.key).inserted
        {
            controller.view.layer.setAffineTransform(.identity)
            controller.view.frame = CGRect(origin: .zero, size: plan.size)
            controller.view.accessibilityIdentifier = nil
            transitionHostingControllers.append(controller)
            return controller.view
        }

        let controller: UIHostingController<AnyView>
        if transitionHostingControllerPool.indices.contains(transitionHostingControllerCursor) {
            controller = transitionHostingControllerPool[transitionHostingControllerCursor]
            controller.rootView = plan.content
        } else {
            controller = UIHostingController(rootView: plan.content)
            controller.safeAreaRegions = []
            controller.view.backgroundColor = .clear
            transitionHostingControllerPool.append(controller)
        }
        transitionHostingControllerCursor += 1
        controller.safeAreaRegions = []
        controller.view.backgroundColor = .clear
        controller.view.layer.setAffineTransform(.identity)
        controller.view.frame = CGRect(origin: .zero, size: plan.size)
        controller.view.accessibilityIdentifier = nil
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        transitionHostingControllers.append(controller)
        return controller.view
    }

    private func transitionChromePlan(
        for item: TimelineSemanticProjection.Item,
        scale: TimelineSemanticScale,
        catalog: TimelineSemanticCatalog
    ) -> TransitionChromePlan? {
        if item.isHeader {
            let title = TimelineCaptureDateFormatting.string(
                from: catalog.assets[item.assetRange.lowerBound].capturedAt,
                dateStyle: .long,
                timeStyle: .none
            )
            let subtitle = "\(item.assetRange.count.formatted()) items"
            return makeTransitionChromePlan(
                role: "header",
                identity: "\(scale.rawValue):\(item.id)",
                signature: "\(title)|\(subtitle)",
                size: item.frame.size,
                content: AssetSectionHeader(title: title, subtitle: subtitle)
            )
        }

        if !scale.isAssets {
            guard let groups = catalog.groups[scale], groups.indices.contains(item.nodeIndex) else { return nil }
            let group = groups[item.nodeIndex]
            let title = group.route.navigationTitle
            let count = group.assets.count
            return makeTransitionChromePlan(
                role: "group",
                identity: "\(scale.rawValue):\(item.id)",
                signature: "\(title)|\(count)|\(item.isFeatured)",
                size: item.frame.size,
                content: PhotosRangeCardChrome(title: title, count: count, isFeatured: item.isFeatured)
            )
        }

        guard catalog.assets.indices.contains(item.assetRange.lowerBound) else { return nil }
        let asset = catalog.assets[item.assetRange.lowerBound]
        guard TimelineAssetBadgeOverlay.isVisible(for: asset) else { return nil }
        return badgeTransitionChromePlan(
            asset: asset,
            size: imageRect(item: item, scale: scale, asset: asset).size
        )
    }

    private func badgeTransitionChromePlan(asset: TimelineAssetSummary, size: CGSize) -> TransitionChromePlan {
        makeTransitionChromePlan(
            role: "badge",
            identity: asset.id,
            signature: "\(asset.livePhotoVideoID != nil)|\(asset.projectionType ?? "")|\(asset.stack?.assetCount ?? 0)|\(input?.hiddenLivePhotoID == asset.id)",
            size: size,
            content: TimelineAssetBadgeOverlay(
                asset: asset,
                hiddenLivePhotoBadgeAssetID: input?.hiddenLivePhotoID
            )
        )
    }

    private func makeTransitionChromePlan(
        role: String,
        identity: String,
        signature: String,
        size: CGSize,
        content: some View
    ) -> TransitionChromePlan {
        let displayScale = traitCollection.displayScale
        let colorScheme: ColorScheme = traitCollection.userInterfaceStyle == .dark ? .dark : .light
        let key = TransitionChromeKey(
            role: role,
            identity: identity,
            signature: signature,
            widthPixels: max(1, Int((size.width * displayScale).rounded())),
            heightPixels: max(1, Int((size.height * displayScale).rounded())),
            interfaceStyle: traitCollection.userInterfaceStyle.rawValue,
            contentSizeCategory: traitCollection.preferredContentSizeCategory.rawValue
        )
        return TransitionChromePlan(
            key: key,
            content: AnyView(content.environment(\.colorScheme, colorScheme)),
            size: size
        )
    }

    private func renderProgress(_ progress: CGFloat) {
        for item in transitionItems {
            let frame = CGRect(x: mix(item.start.minX, item.end.minX, progress), y: mix(item.start.minY, item.end.minY, progress),
                               width: mix(item.start.width, item.end.width, progress), height: mix(item.start.height, item.end.height, progress))
            if item.usesLayerTransform {
                item.view.layer.setAffineTransform(Self.transitionTransform(from: item.end, to: frame))
            } else {
                item.view.frame = frame
            }
            item.view.layer.cornerRadius = mix(item.startRadius, item.endRadius, progress)
            item.view.alpha = if item.isChrome {
                item.incoming ? progress : item.disappears ? 1 - progress : 1
            } else {
                item.incoming ? min(1, progress * 2) : item.disappears ? max(0, 1 - progress * 1.5) : 1
            }
        }
    }

    private func mix(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }

    private func settle(commit: Bool) {
        let progress = gesture?.progress ?? 0
        gesture = nil
        if commit, let target {
            install(target, focusing: focusAssetIndex, viewportY: pinchCentroid.y, latest: false)
            input?.scaleChanged(target.scale)
        }
        guard !UIAccessibility.isReduceMotionEnabled, transitionSurface != nil else { finishPresentation(); return }
        let duration = 0.16 + Double(commit ? 1 - progress : progress) * 0.18
        let animator = UIViewPropertyAnimator(duration: duration, dampingRatio: 1) { [weak self] in
            self?.renderProgress(commit ? 1 : 0)
        }
        self.animator = animator
        animator.addCompletion { [weak self] _ in self?.finishPresentation() }
        animator.startAnimation()
    }

    private func cancelTracking() {
        guard gesture != nil else { return }
        gesture = nil
        finishPresentation()
    }

    private func finishPresentation() {
        guard !isPresentationCrossfading else { return }
        animator?.stopAnimation(true)
        animator = nil
        guard let surface = transitionSurface else {
            completePresentationCleanup()
            return
        }
        collection?.alpha = 1
        collection?.visibleCells.forEach { $0.alpha = 1 }
        guard !UIAccessibility.isReduceMotionEnabled else {
            completePresentationCleanup(surface: surface)
            return
        }
        isPresentationCrossfading = true
        let fade = UIViewPropertyAnimator(duration: 0.18, curve: .easeOut) {
            surface.alpha = 0
        }
        animator = fade
        fade.addCompletion { [weak self, weak surface] _ in
            guard let self, let surface, transitionSurface === surface else { return }
            completePresentationCleanup(surface: surface)
        }
        fade.startAnimation()
    }

    private func completePresentationCleanup(surface: UIView? = nil) {
        if let surface, transitionSurface !== surface {
            return
        }
        animator?.stopAnimation(true)
        animator = nil
        isPresentationCrossfading = false
        localTransitionTasks.forEach { $0.cancel() }
        localTransitionTasks = []
        transitionSurface?.removeFromSuperview()
        transitionSurface = nil
        if collection != nil, !scale.isAssets {
            for cell in collection.visibleCells.compactMap({ $0 as? TimelineSemanticCollectionCell }) {
                let isVisible = input?.isActive == true
                if cell.coverVisibility.isVisible != isVisible {
                    cell.coverVisibility.isVisible = isVisible
                }
            }
        }
        transitionItems = []
        transitionHostingControllers = []
        transitionChromeKeysInUse = []
        target = nil
        input?.transitionScaleChanged(scale)
        collection?.alpha = 1
        collection?.panGestureRecognizer.isEnabled = true
        collection?.visibleCells.forEach { $0.alpha = 1 }
        handoffImages = [:]
        if let deferred = deferredInput {
            deferredInput = nil
            update(deferred)
        }
        publishViewport()
    }

    @objc private func interrupted() {
        gesture = nil
        cancelTransitionWarmup()
        windowExpansionTask?.cancel()
        windowExpansionTask = nil
        completePresentationCleanup()
    }

    func stop() {
        interrupted()
        windowExpansionTask?.cancel()
        windowExpansionTask = nil
        loadOlderTask?.cancel()
        loadOlderTask = nil
        viewportTask?.cancel()
        viewportTask = nil
        cancelTransitionChromeWarmup(resetCache: true)
        transitionPrefetcher?.stopPrefetching()
        transitionPrefetcher = nil
        warmedRequests = [:]
        warmPipeline = nil
        transitionHostingControllers = []
        transitionHostingControllerPool = []
        transitionHostingControllerCursor = 0
        deferredInput = nil
        input = nil
        collection?.visibleCells.forEach { ($0 as? TimelineSemanticCollectionCell)?.clearHostedContent() }
    }

    func changeScale(coarser: Bool) {
        guard gesture == nil, let next = scale.adjacent(coarser: coarser),
              let focused = focusedItem(at: CGPoint(x: collection.bounds.midX, y: collection.bounds.midY)) else { return }
        finishPresentation()
        focusAssetIndex = representativeIndex(focused)
        pinchCentroid = CGPoint(x: collection.bounds.width / 2, y: focused.frame.midY - collection.contentOffset.y)
        prepareTransition(to: next)
        settle(commit: true)
        if UIAccessibility.isVoiceOverRunning {
            let index = projection?.items.firstIndex { !$0.isHeader && $0.assetRange.contains(focusAssetIndex) }
            let cell = index.flatMap { collection.cellForItem(at: IndexPath(item: $0, section: 0)) }
            UIAccessibility.post(notification: .layoutChanged, argument: cell ?? collection)
        }
    }

    @objc private func coarsen() -> Bool {
        changeScale(coarser: true); return true
    }

    @objc private func refine() -> Bool {
        changeScale(coarser: false); return true
    }

    @objc private func refreshRequested() {
        guard let input else { return }
        Task { [weak self] in
            await input.refresh()
            self?.collection.refreshControl?.endRefreshing()
        }
    }

    func scrollViewWillBeginDragging(_: UIScrollView) {
        guard input?.isActive == true, gesture == nil, animator == nil else { return }
        cancelTransitionWarmup()
        olderExpansionRearmOffset = nil
        newerExpansionRearmOffset = nil
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isInstalling, gesture == nil, animator == nil, input?.isActive == true else { return }
        let gap = isAtLatest ? 0 : max(25, layout.height - scrollView.contentOffset.y - scrollView.bounds.height + scrollView.contentInset.bottom)
        input?.scrolled(scrollView.contentOffset.y - lastOffset, gap, scrollView.isDragging || scrollView.isDecelerating)
        lastOffset = scrollView.contentOffset.y
        scheduleViewportPublication()
        scheduleWindowExpansion()
    }

    func scrollViewDidEndDecelerating(_: UIScrollView) {
        viewportTask?.cancel()
        viewportTask = nil
        publishViewport()
        loadOlderIfNeeded()
    }

    func scrollViewDidEndDragging(_: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            viewportTask?.cancel()
            viewportTask = nil
            publishViewport(); loadOlderIfNeeded()
        }
    }

    private func loadOlderIfNeeded() {
        guard loadOlderTask == nil, gesture == nil, animator == nil,
              projection?.nodeRange.lowerBound == 0,
              collection.contentOffset.y < collection.bounds.height,
              let input, input.isActive else { return }
        loadOlderTask = Task { [weak self] in
            await input.loadOlder()
            self?.loadOlderTask = nil
        }
    }

    private func publishViewport() {
        guard let input, input.isActive, let catalog, let projection, collection != nil,
              gesture == nil, animator == nil, transitionSurface == nil, !isInstalling else { return }
        let visibleItems = collection.indexPathsForVisibleItems.compactMap { path -> TimelineSemanticProjection.Item? in
            guard projection.items.indices.contains(path.item) else { return nil }
            let item = projection.items[path.item]
            return item.isHeader ? nil : item
        }
        let indexes = visibleItems.map(representativeIndex)
        let assets = indexes.map { catalog.assets[$0] }
        let ids = Set(assets.map(\.id))
        if !collection.isDragging, !collection.isDecelerating,
           let item = focusedItem(at: CGPoint(x: collection.bounds.midX, y: collection.bounds.midY))
        {
            input.focusChanged(catalog.assets[representativeIndex(item)])
        }
        let side = scale.isAssets
            ? visibleItems.map { max($0.frame.width, $0.frame.height) }.max().map { min(2048, max(1, Int(($0 * traitCollection.displayScale).rounded(.up)))) } ?? 1
            : 900
        let target = MediaPixelSize(width: side, height: side)
        if !collection.isDragging, !collection.isDecelerating {
            scheduleTransitionWarmup()
        }
        guard ids != lastVisibleIDs || target != lastPublishedTarget || scale != lastPublishedScale else { return }
        lastVisibleIDs = ids
        lastPublishedTarget = target
        lastPublishedScale = scale
        input.visibleAssetsChanged(assets, target, scale)
    }

    private func scheduleTransitionWarmup() {
        guard transitionWarmTask == nil else { return }
        transitionWarmTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(70))
            } catch {
                return
            }
            guard let self else { return }
            transitionWarmTask = nil
            guard !Task.isCancelled, gesture == nil, animator == nil, transitionSurface == nil,
                  !collection.isDragging, !collection.isDecelerating, input?.isActive == true else { return }
            let interval = Self.signposter.beginInterval("TransitionWarmup", id: Self.signposter.makeSignpostID())
            warmTransitionNeighborhood()
            Self.signposter.endInterval("TransitionWarmup", interval)
        }
    }

    private func cancelTransitionWarmup() {
        transitionWarmTask?.cancel()
        transitionWarmTask = nil
    }

    private func warmTransitionNeighborhood() {
        guard let input, let catalog, let projection, let pipeline = input.media.pipeline,
              let focused = focusedItem(at: CGPoint(x: collection.bounds.midX, y: collection.bounds.midY)) else { return }
        if warmPipeline !== pipeline {
            transitionPrefetcher?.stopPrefetching()
            transitionPrefetcher = ImagePrefetcher(pipeline: pipeline, destination: .memoryCache, maxConcurrentRequestCount: 2)
            warmPipeline = pipeline
            warmedRequests = [:]
        }
        var descriptors: [MediaRequestDescriptor] = []
        var chromePlans = projection.items.filter { $0.frame.intersects(collection.bounds) }.compactMap {
            transitionChromePlan(for: $0, scale: scale, catalog: catalog)
        }
        let adjacentDirections = scale.isAssets ? [true, false] : [false, true]
        for coarser in adjacentDirections {
            guard let nextScale = scale.adjacent(coarser: coarser) else { continue }
            let focus = representativeIndex(focused)
            let next = makeProjection(scale: nextScale, focus: focus)
            let y = offset(for: next, focus: focus, viewportY: focused.frame.midY - collection.contentOffset.y, latest: false)
            let rect = CGRect(origin: CGPoint(x: 0, y: y), size: collection.bounds.size)
            let area = rect.insetBy(dx: 0, dy: -rect.height * 0.25)
            chromePlans += next.items.filter { $0.frame.intersects(area) }.compactMap {
                transitionChromePlan(for: $0, scale: nextScale, catalog: catalog)
            }
            let warmIndexes = TimelineSemanticTransitionPolicy.warmIndexes(
                items: next.items,
                area: area,
                focus: CGPoint(x: area.midX, y: rect.midY)
            )
            descriptors += warmIndexes.map { index in
                let item = next.items[index]
                let asset = catalog.assets[item.assetRange.contains(focus) ? focus : item.assetRange.lowerBound]
                return thumbnailDescriptor(asset: asset, frame: item.frame, scale: nextScale)
            }
        }
        let sourceArea = collection.bounds.insetBy(dx: 0, dy: -collection.bounds.height)
        descriptors += projection.items.filter { !$0.isHeader && $0.frame.intersects(sourceArea) }
            .sorted { abs($0.frame.midY - collection.bounds.midY) < abs($1.frame.midY - collection.bounds.midY) }
            .prefix(24).map { item -> MediaRequestDescriptor in
                let asset = catalog.assets[representativeIndex(item)]
                return thumbnailDescriptor(asset: asset, frame: item.frame, scale: scale)
            }
        var seenDescriptors = Set<MediaRequestDescriptor>()
        let orderedDescriptors = descriptors.filter { seenDescriptors.insert($0).inserted }
        let desired = Set(orderedDescriptors)
        let removed = warmedRequests.filter { !desired.contains($0.key) }.map(\.value)
        transitionPrefetcher?.stopPrefetching(with: removed)
        warmedRequests = warmedRequests.filter { desired.contains($0.key) }
        let additions = orderedDescriptors.compactMap { descriptor -> (MediaRequestDescriptor, ImageRequest)? in
            guard warmedRequests[descriptor] == nil else { return nil }
            return input.media.imageRequest(for: descriptor, priority: .low).map { (descriptor, $0) }
        }
        for (descriptor, request) in additions {
            warmedRequests[descriptor] = request
        }
        transitionPrefetcher?.startPrefetching(with: additions.map(\.1))
        scheduleTransitionChromeWarmup(plans: chromePlans)
    }

    private func scheduleTransitionChromeWarmup(plans: [TransitionChromePlan]) {
        var seen = Set<TransitionChromeKey>()
        let desiredPlans = plans.filter { seen.insert($0.key).inserted }
        let boundedPlans = Array(desiredPlans.prefix(TimelineSemanticTransitionPolicy.warmLimit))
        let desiredKeys = Set(boundedPlans.map(\.key))
        transitionChromeControllers = transitionChromeControllers.filter { desiredKeys.contains($0.key) }

        cancelTransitionChromeWarmup()
        let missingPlans = boundedPlans.filter { transitionChromeControllers[$0.key] == nil }
        guard !missingPlans.isEmpty, gesture == nil, transitionSurface == nil else { return }

        transitionChromeWarmGeneration &+= 1
        let generation = transitionChromeWarmGeneration
        transitionChromeWarmTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for plan in missingPlans {
                guard !Task.isCancelled, gesture == nil, transitionSurface == nil else { break }
                let controller = UIHostingController(rootView: plan.content)
                controller.safeAreaRegions = []
                controller.view.backgroundColor = .clear
                controller.view.frame = CGRect(origin: .zero, size: plan.size)
                controller.view.setNeedsLayout()
                controller.view.layoutIfNeeded()
                transitionChromeControllers[plan.key] = controller
                try? await Task.sleep(for: .milliseconds(4))
            }
            if transitionChromeWarmGeneration == generation {
                transitionChromeWarmTask = nil
            }
        }
    }

    private func cancelTransitionChromeWarmup(resetCache: Bool = false) {
        transitionChromeWarmGeneration &+= 1
        transitionChromeWarmTask?.cancel()
        transitionChromeWarmTask = nil
        if resetCache {
            transitionChromeControllers = [:]
            transitionChromeKeysInUse = []
        }
    }

    @objc private func receivedMemoryWarning() {
        interrupted()
        cancelTransitionChromeWarmup(resetCache: true)
        transitionHostingControllers = []
        transitionHostingControllerPool = []
        transitionHostingControllerCursor = 0
    }

    private func thumbnailDescriptor(asset: TimelineAssetSummary, frame: CGRect, scale: TimelineSemanticScale) -> MediaRequestDescriptor {
        let side = scale.isAssets ? min(2048, max(1, Int((max(frame.width, frame.height) * traitCollection.displayScale).rounded(.up)))) : 900
        return MediaRequestDescriptor(assetID: asset.id, updatedAt: asset.thumbnailRevision, derivative: .thumbnail,
                                      targetPixels: .init(width: side, height: side))
    }

    private func scheduleViewportPublication() {
        guard viewportTask == nil else { return }
        viewportTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            viewportTask = nil
            publishViewport()
        }
    }

    private func scheduleWindowExpansion() {
        guard windowExpansionTask == nil else { return }
        windowExpansionTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            windowExpansionTask = nil
            guard gesture == nil, animator == nil, input?.isActive == true else { return }
            expandWindowIfNeeded()
        }
    }

    private func expandWindowIfNeeded() {
        guard !isExpanding, let projection, let catalog else { return }
        let older = collection.contentOffset.y < collection.bounds.height
        let newer = layout.height - collection.bounds.maxY < collection.bounds.height
        let expandOlder = older && projection.nodeRange.lowerBound > 0
            && olderExpansionRearmOffset.map { collection.contentOffset.y <= $0 } != false
        let expandNewer = newer && projection.nodeRange.upperBound < catalog.count(at: scale)
            && newerExpansionRearmOffset.map { collection.contentOffset.y >= $0 } != false
        guard expandOlder || expandNewer,
              let focus = focusedItem(at: CGPoint(x: collection.bounds.midX, y: collection.bounds.midY)) else { return }
        var lower = expandOlder ? max(0, projection.nodeRange.lowerBound - (scale.isAssets ? 180 : 26)) : projection.nodeRange.lowerBound
        var upper = expandNewer ? min(catalog.count(at: scale), projection.nodeRange.upperBound + (scale.isAssets ? 180 : 26)) : projection.nodeRange.upperBound
        guard lower != projection.nodeRange.lowerBound || upper != projection.nodeRange.upperBound else { return }
        let limit = scale.isAssets ? 1080 : 156
        if upper - lower > limit {
            if expandOlder {
                upper = lower + limit
            } else {
                lower = upper - limit
            }
        }
        isExpanding = true
        let representative = representativeIndex(focus)
        let viewportY = focus.frame.midY - collection.contentOffset.y
        let next = makeProjection(scale: scale, focus: representative, range: lower ..< upper)
        install(next, focusing: representative, viewportY: viewportY, latest: false)
        let rearmDistance = collection.bounds.height * 0.5
        if expandOlder {
            olderExpansionRearmOffset = collection.contentOffset.y - rearmDistance
        }
        if expandNewer {
            newerExpansionRearmOffset = collection.contentOffset.y + rearmDistance
        }
        isExpanding = false
    }

    func dismissalTarget(assetID: String, aspectRatio: Double) -> AssetViewerDismissalTarget? {
        guard scale.isAssets, let projection, let item = projection.items.first(where: { $0.id == assetID }),
              item.frame.intersects(collection.bounds) else { return nil }
        let fitted = scale == .natural
            ? TimelineThumbnailGeometry.renderedImageRect(in: item.frame.size, aspectRatio: aspectRatio, naturalAspectProgress: 1)
            : CGRect(origin: .zero, size: item.frame.size)
        let frame = collection.convert(fitted.offsetBy(dx: item.frame.minX, dy: item.frame.minY), to: nil)
        return AssetViewerDismissalTarget(imageFrame: frame, cornerRadius: radius(scale), fillsFrame: scale == .square)
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        let active = input?.isActive == true
        let hasFocus = focusedItem(at: recognizer.location(in: collection)) != nil
        return active && hasFocus
    }

    func gestureRecognizer(_: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer) -> Bool {
        // UIKit/SwiftUI ancestor recognizers must not veto the two-finger path.
        // Our one-finger pan is explicitly suspended once the pinch begins.
        true
    }
}
