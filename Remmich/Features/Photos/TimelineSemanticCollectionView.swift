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
    let runtime: TimelineSemanticRuntime
    let latestRequest: Int
    let isActive: Bool
    let hiddenThumbnailID: String?
    let hiddenLivePhotoID: String?
    let selectAsset: (TimelineAssetSummary, [TimelineAssetSummary]) -> Void
    let selectGroup: (PhotosRangeRoute, String?) -> Void
    let scaleChanged: (TimelineSemanticScale) -> Void
    let scrolled: (CGFloat, CGFloat, Bool) -> Void
    let visibleAssetsChanged: ([TimelineAssetSummary], MediaPixelSize) -> Void
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
        guard frames.indices.contains(indexPath.item) else { return nil }
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = frames[indexPath.item]
        return attributes
    }
}

private final class TimelineSemanticCollectionCell: UICollectionViewCell {
    var coverAssetID: String?
    var nodeID: String?

    /// Geometry belongs to the deterministic collection layout. SwiftUI's
    /// hosted GeometryReader must not self-size cells during scrolling.
    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        layoutAttributes
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        contentConfiguration = nil
        coverAssetID = nil
        nodeID = nil
        isAccessibilityElement = false
        accessibilityLabel = nil
        accessibilityTraits = []
        alpha = 1
    }
}

@MainActor
final class TimelineSemanticCollectionController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate, UIGestureRecognizerDelegate {
    private static let logger = Logger(subsystem: "io.github.ender-wang.Remmich", category: "SemanticZoom")
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
    private var representativeAssets: [String: Int] = [:]
    private var isInstalling = false
    private var isExpanding = false
    private var hiddenThumbnailID: String?
    private var hiddenLivePhotoID: String?
    private var loadOlderTask: Task<Void, Never>?
    private var viewportTask: Task<Void, Never>?
    private var itemIndexes: [String: Int] = [:]
    private var lastPublishedTarget: MediaPixelSize?
    private var transitionPrefetcher: ImagePrefetcher?
    private var warmPipeline: ImagePipeline?
    private var warmedRequests: [MediaRequestDescriptor: ImageRequest] = [:]
    private var localTransitionTasks: [Task<Void, Never>] = []

    private struct TransitionItem {
        let view: UIView
        let start: CGRect
        let end: CGRect
        let incoming: Bool
        let disappears: Bool
        let startRadius: CGFloat
        let endRadius: CGFloat
        var isChrome = false
    }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collection.backgroundColor = .clear
        collection.contentInsetAdjustmentBehavior = .never
        collection.alwaysBounceVertical = true
        collection.delegate = self
        collection.register(TimelineSemanticCollectionCell.self, forCellWithReuseIdentifier: "semantic")
        dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collection) { [weak self] collection, path, _ in
            self?.collectionView(collection, cellForItemAt: path)
        }
        view.addSubview(collection)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self
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
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
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
        collection.frame = view.bounds
        cancelTracking()
        finishPresentation()
        lastSize = view.bounds.size
        guard let catalog else { return }
        let asset = focus.map(representativeIndex) ?? max(0, catalog.assets.count - 1)
        let next = makeProjection(scale: scale, focus: asset)
        install(next, focusing: asset, viewportY: focusY.map { $0 / sourceHeight * view.bounds.height }, latest: focus == nil || wasAtLatest)
        if catalog.assets.isEmpty {
            loadOlderIfNeeded()
        }
    }

    private func rebuildForAppearance() {
        guard catalog != nil, lastSize.width > 0 else { return }
        interrupted()
        let focus = focusedItem(at: CGPoint(x: collection.bounds.midX, y: collection.bounds.midY))
        let asset = focus.map(representativeIndex) ?? max(0, catalog!.assets.count - 1)
        install(makeProjection(scale: scale, focus: asset), focusing: asset,
                viewportY: focus.map { $0.frame.midY - collection.contentOffset.y }, latest: isAtLatest)
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
        let needsCatalog = revision != value.revision
        catalog = value.catalog
        revision = value.revision
        let needsScale = scale != value.scale
        scale = value.scale
        let insetChanged = abs(collection.contentInset.bottom - value.bottomClearance) > 0.5
        isInstalling = true
        collection.contentInset.bottom = value.bottomClearance
        collection.verticalScrollIndicatorInsets.bottom = value.bottomClearance
        isInstalling = false
        if needsCatalog || needsScale || projection == nil {
            representativeAssets = [:]
            if lastSize.width > 0 {
                let focus = oldFocusID.flatMap { value.catalog.assetIndexes[$0] } ?? max(0, value.catalog.assets.count - 1)
                install(makeProjection(scale: scale, focus: focus), focusing: focus, viewportY: focusY, latest: latest && !needsScale,
                        refreshContents: needsCatalog)
            }
        } else if insetChanged {
            let focus = oldFocusID.flatMap { value.catalog.assetIndexes[$0] } ?? max(0, value.catalog.assets.count - 1)
            install(makeProjection(scale: scale, focus: focus, range: projection?.nodeRange), focusing: focus, viewportY: focusY, latest: latest)
        }
        if value.latestRequest != lastLatestRequest {
            lastLatestRequest = value.latestRequest
            if value.isActive {
                let focus = max(0, value.catalog.assets.count - 1)
                install(makeProjection(scale: scale, focus: focus), focusing: focus, viewportY: nil, latest: true)
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
    }

    private var isAtLatest: Bool {
        guard let projection, let catalog else { return true }
        return projection.nodeRange.upperBound == catalog.count(at: scale)
            && layout.height - collection.contentOffset.y - collection.bounds.height + collection.contentInset.bottom < 24
    }

    private func makeProjection(scale: TimelineSemanticScale, focus: Int, range: Range<Int>? = nil) -> TimelineSemanticProjection {
        TimelineSemanticProjection.build(catalog: catalog!, scale: scale, focusAssetIndex: focus, size: lastSize,
                                         isPhone: traitCollection.userInterfaceIdiom == .phone,
                                         dark: traitCollection.userInterfaceStyle == .dark, requestedRange: range)
            .bottomAligned(minimumHeight: max(0, collection.bounds.height - collection.contentInset.bottom))
    }

    private func offset(for next: TimelineSemanticProjection, focus: Int, viewportY: CGFloat?, latest: Bool) -> CGFloat {
        let height = max(next.height, collection.bounds.height - collection.contentInset.bottom)
        let maximum = max(0, height - collection.bounds.height + collection.contentInset.bottom)
        guard !latest, let item = next.items.first(where: { !$0.isHeader && $0.assetRange.contains(focus) }) else { return maximum }
        return min(maximum, max(0, item.frame.midY - (viewportY ?? collection.bounds.height / 2)))
    }

    private func install(_ next: TimelineSemanticProjection, focusing focus: Int, viewportY: CGFloat?, latest: Bool,
                         refreshContents: Bool = false)
    {
        isInstalling = true
        let oldScale = projection?.scale
        let oldIDs = Set(dataSource.snapshot().itemIdentifiers)
        projection = next
        itemIndexes = Dictionary(uniqueKeysWithValues: next.items.enumerated().map { ($0.element.id, $0.offset) })
        scale = next.scale
        layout.frames = next.items.map(\.frame)
        layout.height = max(next.height, collection.bounds.height - collection.contentInset.bottom)
        let y = offset(for: next, focus: focus, viewportY: viewportY, latest: latest)
        UIView.performWithoutAnimation {
            layout.invalidateLayout()
            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0])
            let ids = next.items.map(\.id)
            snapshot.appendItems(ids)
            if oldScale != next.scale || refreshContents {
                snapshot.reconfigureItems(ids.filter { oldIDs.contains($0) })
            }
            dataSource.apply(snapshot, animatingDifferences: false)
            collection.contentOffset = CGPoint(x: 0, y: y)
            collection.layoutIfNeeded()
        }
        lastOffset = y
        isInstalling = false
        publishViewport()
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
        cell.nodeID = item.id
        let assetIndex = representativeIndex(item)
        let asset = catalog.assets[assetIndex]
        let coversVisible = input.isActive && gesture == nil && transitionSurface == nil
        cell.alpha = transitionSurface == nil ? 1 : 0
        if item.isHeader {
            let date = catalog.assets[item.assetRange.lowerBound].capturedAt
            cell.contentConfiguration = UIHostingConfiguration {
                AssetSectionHeader(title: TimelineCaptureDateFormatting.string(from: date, dateStyle: .long, timeStyle: .none),
                                   subtitle: "\(item.assetRange.count.formatted()) items")
            }.margins(.all, 0)
        } else if scale.isAssets {
            cell.coverAssetID = asset.id
            cell.contentConfiguration = UIHostingConfiguration {
                TimelineAssetThumbnail(asset: asset, media: input.media,
                                       assetLayout: projection.scale == .square ? .square : .naturalAspect,
                                       requestSide: max(item.frame.width, item.frame.height),
                                       visibilityChanged: { _, _ in }, viewportChanged: { _, _ in },
                                       transitionNamespace: input.namespace,
                                       assetSelected: { [weak self] selected in
                                           guard self?.gesture == nil, self?.animator == nil else { return }
                                           input.selectAsset(selected, Array(catalog.assets[max(0, assetIndex - 80) ..< min(catalog.assets.count, assetIndex + 81)].reversed()))
                                       },
                                       hiddenLivePhotoBadgeAssetID: input.hiddenLivePhotoID,
                                       hiddenReturningThumbnailAssetID: input.hiddenThumbnailID)
            }.margins(.all, 0)
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
            cell.contentConfiguration = UIHostingConfiguration {
                PhotosRangeCard(title: group.route.navigationTitle, count: group.assets.count,
                                systemImage: "calendar", assets: covers, media: input.media,
                                motion: motion, externallyVisible: coversVisible,
                                onCoverChanged: { [weak cell] assetID in
                                    guard cell?.nodeID == item.id else { return }
                                    cell?.coverAssetID = assetID
                                })
                                .id(contentID)
            }.margins(.all, 0)
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = "\(group.route.navigationTitle), \(group.assets.count) items"
            cell.accessibilityTraits = .button
        }
    }

    func collectionView(_: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt _: IndexPath) {
        // Cancel hosted thumbnail/slideshow tasks immediately when virtualized out.
        cell.contentConfiguration = nil
    }

    func collectionView(_: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        if cell.contentConfiguration == nil {
            configure(indexPath, cell: cell as? TimelineSemanticCollectionCell)
        }
    }

    func collectionView(_: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard gesture == nil, animator == nil, let input, let catalog, let projection,
              projection.items.indices.contains(indexPath.item), !scale.isAssets else { return }
        let item = projection.items[indexPath.item]
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
        let started = ContinuousClock.now
        let next = makeProjection(scale: nextScale, focus: focusAssetIndex)
        guard !next.items.isEmpty else { return }
        target = next
        targetOffset = offset(for: next, focus: focusAssetIndex, viewportY: pinchCentroid.y, latest: false)
        collection.panGestureRecognizer.isEnabled = false
        transitionPrefetcher?.stopPrefetching()
        warmedRequests = [:]
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let surface = UIView(frame: view.bounds)
        surface.isUserInteractionEnabled = false
        surface.clipsToBounds = true
        view.addSubview(surface)
        transitionSurface = surface

        // Include a bounded apron around the source, and every tile that can
        // appear in the destination viewport. Target coverage is unconditional:
        // a neighboring period can arrive even without a visible source member.
        let apron = collection.bounds.insetBy(dx: 0, dy: -collection.bounds.height * 0.75)
        let sources = source.items.enumerated().filter { !$0.element.isHeader && $0.element.frame.intersects(apron) }
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
        for (index, item) in sources {
            let representative = representativeIndex(item)
            guard let destination = destinations.first(where: { $0.assetRange.contains(representative) }) else { continue }
            let asset = catalog.assets[representative]
            let start = imageRect(item: item, scale: scale, asset: asset).offsetBy(dx: 0, dy: -collection.contentOffset.y)
            let end = imageRect(item: destination, scale: nextScale, asset: asset).offsetBy(dx: 0, dy: -targetOffset)
            let image = cachedImage(asset: asset, frame: item.frame)
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
            } else {
                continue
            }
            let keepsCover = selectedSources[destination.id] == item.id
                && targetRepresentatives[destination.id] == representative
                && represented.insert(destination.id).inserted
            if keepsCover {
                snapshot.accessibilityIdentifier = "semantic-zoom-target:\(destination.id)"
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
            let imageView = UIImageView(image: cachedImage(asset: asset, frame: destination.frame))
            imageView.contentMode = .scaleAspectFill
            imageView.backgroundColor = .tertiarySystemFill
            imageView.accessibilityIdentifier = "semantic-zoom-target:\(destination.id)"
            if imageView.image == nil {
                loadLocalTransitionImage(into: imageView, asset: asset, frame: destination.frame, scale: nextScale, surface: surface)
            }
            addTransition(imageView, start: start, end: end, incoming: true, disappears: false,
                          startRadius: radius(scale), endRadius: radius(nextScale), to: surface)
        }
        representativeAssets.merge(targetRepresentatives, uniquingKeysWith: { _, new in new })
        for destination in next.items where destination.frame.intersects(targetArea) && (destination.isHeader || !nextScale.isAssets) {
            let end = destination.frame.offsetBy(dx: 0, dy: -targetOffset)
            let chrome = UIView(frame: end)
            let inset: CGFloat = destination.isHeader ? 16 : 8
            let label = UILabel(frame: CGRect(x: inset, y: destination.isHeader ? 0 : max(0, end.height - 52),
                                              width: max(1, end.width - inset * 2), height: destination.isHeader ? 36 : 44))
            label.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
            label.numberOfLines = destination.isHeader ? 1 : 2
            label.font = .preferredFont(forTextStyle: destination.isHeader || destination.isFeatured ? .headline : .caption1)
            label.textColor = destination.isHeader ? .label : .white
            if destination.isHeader {
                label.text = TimelineCaptureDateFormatting.string(from: catalog.assets[destination.assetRange.lowerBound].capturedAt,
                                                                  dateStyle: .long, timeStyle: .none)
            } else {
                label.layer.shadowColor = UIColor.black.cgColor
                label.layer.shadowOpacity = 0.8
                label.layer.shadowRadius = 3
                let group = catalog.groups[nextScale]![destination.nodeIndex]
                label.text = "\(group.route.navigationTitle)\n\(group.assets.count.formatted()) items"
            }
            chrome.addSubview(label)
            addTransition(chrome, start: end.offsetBy(dx: 0, dy: 12), end: end, incoming: true, disappears: false,
                          startRadius: 0, endRadius: 0, to: surface)
            transitionItems[transitionItems.count - 1].isChrome = true
        }
        for cell in collection.visibleCells {
            cell.alpha = 0
        }
        if !scale.isAssets {
            for path in collection.indexPathsForVisibleItems {
                configure(path)
            }
        }
        let duration = started.duration(to: .now).components
        let layerCount = transitionItems.count
        Self.logger.info("Semantic transition prepared sourceItems=\(sources.count) targetItems=\(destinations.count) layers=\(layerCount) elapsedMs=\(duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000)")
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

    private func loadLocalTransitionImage(into imageView: UIImageView, asset: TimelineAssetSummary, frame: CGRect,
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
                               startRadius: CGFloat, endRadius: CGFloat, to surface: UIView)
    {
        snapshot.frame = start
        snapshot.clipsToBounds = true
        snapshot.layer.cornerRadius = startRadius
        snapshot.alpha = incoming ? 0 : 1
        surface.addSubview(snapshot)
        transitionItems.append(TransitionItem(view: snapshot, start: start, end: end, incoming: incoming,
                                              disappears: disappears, startRadius: startRadius, endRadius: endRadius))
    }

    private func renderProgress(_ progress: CGFloat) {
        for item in transitionItems {
            item.view.frame = CGRect(x: mix(item.start.minX, item.end.minX, progress), y: mix(item.start.minY, item.end.minY, progress),
                                     width: mix(item.start.width, item.end.width, progress), height: mix(item.start.height, item.end.height, progress))
            item.view.layer.cornerRadius = mix(item.startRadius, item.endRadius, progress)
            item.view.alpha = item.isChrome ? max(0, min(1, (progress - 0.65) / 0.35))
                : item.incoming ? min(1, progress * 2) : item.disappears ? max(0, 1 - progress * 1.5) : 1
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
            Self.logger.info("Semantic zoom committed scale=\(String(describing: target.scale), privacy: .public) items=\(target.items.count)")
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
        animator?.stopAnimation(true)
        animator = nil
        localTransitionTasks.forEach { $0.cancel() }
        localTransitionTasks = []
        transitionSurface?.removeFromSuperview()
        transitionSurface = nil
        transitionItems = []
        target = nil
        collection?.alpha = 1
        collection?.panGestureRecognizer.isEnabled = true
        collection?.visibleCells.forEach { $0.alpha = 1 }
        if collection != nil, !scale.isAssets {
            for path in collection.indexPathsForVisibleItems {
                configure(path)
            }
        }
        if let deferred = deferredInput {
            deferredInput = nil
            update(deferred)
        }
        publishViewport()
    }

    @objc private func interrupted() {
        cancelTracking(); finishPresentation()
    }

    func stop() {
        interrupted()
        loadOlderTask?.cancel()
        loadOlderTask = nil
        viewportTask?.cancel()
        viewportTask = nil
        transitionPrefetcher?.stopPrefetching()
        transitionPrefetcher = nil
        warmedRequests = [:]
        warmPipeline = nil
        deferredInput = nil
        input = nil
        collection?.visibleCells.forEach { $0.contentConfiguration = nil }
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

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isInstalling, gesture == nil, animator == nil, input?.isActive == true else { return }
        let gap = isAtLatest ? 0 : max(25, layout.height - scrollView.contentOffset.y - scrollView.bounds.height + scrollView.contentInset.bottom)
        input?.scrolled(scrollView.contentOffset.y - lastOffset, gap, scrollView.isDragging || scrollView.isDecelerating)
        lastOffset = scrollView.contentOffset.y
        scheduleViewportPublication()
        expandWindowIfNeeded()
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
              gesture == nil, animator == nil, !isInstalling else { return }
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
            warmTransitionNeighborhood()
        }
        guard ids != lastVisibleIDs || target != lastPublishedTarget else { return }
        lastVisibleIDs = ids
        lastPublishedTarget = target
        input.visibleAssetsChanged(assets, target)
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
        let area = collection.bounds.insetBy(dx: 0, dy: -collection.bounds.height)
        var descriptors = projection.items.filter { !$0.isHeader && $0.frame.intersects(area) }
            .sorted { abs($0.frame.midY - collection.bounds.midY) < abs($1.frame.midY - collection.bounds.midY) }
            .prefix(24).map { item -> MediaRequestDescriptor in
                let asset = catalog.assets[representativeIndex(item)]
                return thumbnailDescriptor(asset: asset, frame: item.frame, scale: scale)
            }
        for coarser in [true, false] {
            guard let nextScale = scale.adjacent(coarser: coarser) else { continue }
            let focus = representativeIndex(focused)
            let next = makeProjection(scale: nextScale, focus: focus)
            let y = offset(for: next, focus: focus, viewportY: focused.frame.midY - collection.contentOffset.y, latest: false)
            let rect = CGRect(origin: CGPoint(x: 0, y: y), size: collection.bounds.size)
            descriptors += next.items.filter { !$0.isHeader && $0.frame.intersects(rect) }.prefix(6).map { item in
                let asset = catalog.assets[item.assetRange.contains(focus) ? focus : item.assetRange.lowerBound]
                return thumbnailDescriptor(asset: asset, frame: item.frame, scale: nextScale)
            }
        }
        let desired = Set(descriptors)
        let removed = warmedRequests.filter { !desired.contains($0.key) }.map(\.value)
        transitionPrefetcher?.stopPrefetching(with: removed)
        warmedRequests = warmedRequests.filter { desired.contains($0.key) }
        let additions = desired.subtracting(warmedRequests.keys).compactMap { descriptor -> (MediaRequestDescriptor, ImageRequest)? in
            input.media.imageRequest(for: descriptor, priority: .low).map { (descriptor, $0) }
        }
        for (descriptor, request) in additions {
            warmedRequests[descriptor] = request
        }
        transitionPrefetcher?.startPrefetching(with: additions.map(\.1))
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

    private func expandWindowIfNeeded() {
        guard !isExpanding, let projection, let catalog else { return }
        let older = collection.contentOffset.y < collection.bounds.height
        let newer = layout.height - collection.bounds.maxY < collection.bounds.height
        guard (older && projection.nodeRange.lowerBound > 0) || (newer && projection.nodeRange.upperBound < catalog.count(at: scale)),
              let focus = focusedItem(at: CGPoint(x: collection.bounds.midX, y: collection.bounds.midY)) else { return }
        var lower = older ? max(0, projection.nodeRange.lowerBound - (scale.isAssets ? 180 : 26)) : projection.nodeRange.lowerBound
        var upper = newer ? min(catalog.count(at: scale), projection.nodeRange.upperBound + (scale.isAssets ? 180 : 26)) : projection.nodeRange.upperBound
        guard lower != projection.nodeRange.lowerBound || upper != projection.nodeRange.upperBound else { return }
        let limit = scale.isAssets ? 1080 : 156
        if upper - lower > limit {
            if older {
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

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        !(gestureRecognizer is UIPinchGestureRecognizer || otherGestureRecognizer is UIPinchGestureRecognizer)
    }
}
