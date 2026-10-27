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
    let visibleAssetsChanged: ([TimelineAssetSummary]) -> Void
    let refresh: () async -> Void

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

    override func prepareForReuse() {
        super.prepareForReuse()
        contentConfiguration = nil
        coverAssetID = nil
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

    private struct TransitionItem {
        let view: UIView
        let start: CGRect
        let end: CGRect
        let incoming: Bool
        let disappears: Bool
        let startRadius: CGFloat
        let endRadius: CGFloat
    }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collection.backgroundColor = .clear
        collection.contentInsetAdjustmentBehavior = .never
        collection.alwaysBounceVertical = true
        collection.dataSource = self
        collection.delegate = self
        collection.register(TimelineSemanticCollectionCell.self, forCellWithReuseIdentifier: "semantic")
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
        let focus = focusedItem(at: CGPoint(x: collection.bounds.midX, y: collection.bounds.midY))
        let focusY = focus.map { $0.frame.midY - collection.contentOffset.y }
        let wasAtLatest = isAtLatest
        collection.frame = view.bounds
        guard changed else { return }
        cancelTracking()
        finishPresentation()
        lastSize = view.bounds.size
        guard let catalog else { return }
        let asset = focus.map(representativeIndex) ?? max(0, catalog.assets.count - 1)
        let next = makeProjection(scale: scale, focus: asset)
        install(next, focusing: asset, viewportY: focusY, latest: focus == nil || wasAtLatest)
    }

    private func rebuildForAppearance() {
        guard catalog != nil, lastSize.width > 0 else { return }
        interrupted()
        let focus = focusedItem(at: CGPoint(x: collection.bounds.midX, y: collection.bounds.midY))
        let asset = focus.map(representativeIndex) ?? 0
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
        isInstalling = false
        if needsCatalog || needsScale || projection == nil {
            representativeAssets = [:]
            if lastSize.width > 0 {
                let focus = oldFocusID.flatMap { value.catalog.assetIndexes[$0] } ?? max(0, value.catalog.assets.count - 1)
                install(makeProjection(scale: scale, focus: focus), focusing: focus, viewportY: focusY, latest: latest && !needsScale)
            }
        } else if insetChanged, latest {
            collection.contentOffset.y = max(-collection.contentInset.top, layout.height - collection.bounds.height + collection.contentInset.bottom)
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
    }

    private func offset(for next: TimelineSemanticProjection, focus: Int, viewportY: CGFloat?, latest: Bool) -> CGFloat {
        let height = max(next.height, collection.bounds.height - collection.contentInset.bottom)
        let maximum = max(0, height - collection.bounds.height + collection.contentInset.bottom)
        guard !latest, let item = next.items.first(where: { !$0.isHeader && $0.assetRange.contains(focus) }) else { return maximum }
        return min(maximum, max(0, item.frame.midY - (viewportY ?? collection.bounds.height / 2)))
    }

    private func install(_ next: TimelineSemanticProjection, focusing focus: Int, viewportY: CGFloat?, latest: Bool) {
        isInstalling = true
        projection = next
        scale = next.scale
        layout.frames = next.items.map(\.frame)
        layout.height = max(next.height, collection.bounds.height - collection.contentInset.bottom)
        let y = offset(for: next, focus: focus, viewportY: viewportY, latest: latest)
        UIView.performWithoutAnimation {
            layout.invalidateLayout()
            collection.reloadData()
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
        let assetIndex = representativeIndex(item)
        let asset = catalog.assets[assetIndex]
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
            cell.contentConfiguration = UIHostingConfiguration {
                PhotosRangeCard(title: group.route.navigationTitle, count: group.assets.count,
                                systemImage: "calendar", assets: covers, media: input.media,
                                motion: motion, externallyVisible: input.isActive,
                                onCoverChanged: { [weak cell] in cell?.coverAssetID = $0 })
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

    func collectionView(_: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard gesture == nil, animator == nil, let input, let catalog, let projection,
              projection.items.indices.contains(indexPath.item), !scale.isAssets else { return }
        let item = projection.items[indexPath.item]
        let cell = collection.cellForItem(at: indexPath) as? TimelineSemanticCollectionCell
        input.selectGroup(catalog.groups[scale]![item.nodeIndex].route, cell?.coverAssetID)
    }

    private func representativeIndex(_ item: TimelineSemanticProjection.Item) -> Int {
        if let preferred = representativeAssets[item.id], item.assetRange.contains(preferred) {
            return preferred
        }
        if let catalog, let projection,
           let index = projection.items.firstIndex(where: { $0.id == item.id }),
           let cell = collection.cellForItem(at: IndexPath(item: index, section: 0)) as? TimelineSemanticCollectionCell,
           let id = cell.coverAssetID, let assetIndex = catalog.assetIndexes[id], item.assetRange.contains(assetIndex)
        {
            return assetIndex
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
        targetOffset = offset(for: next, focus: focusAssetIndex, viewportY: pinchCentroid.y, latest: false)
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let surface = UIView(frame: view.bounds)
        surface.isUserInteractionEnabled = false
        surface.clipsToBounds = true
        view.addSubview(surface)
        transitionSurface = surface
        let visible = source.items.enumerated().filter { !$0.element.isHeader && $0.element.frame.intersects(collection.bounds) }
        var represented = Set<String>()
        var targetRepresentatives: [String: Int] = [:]
        for destination in next.items where !destination.isHeader {
            let candidates = visible.filter { $0.element.assetRange.overlaps(destination.assetRange) }
            let selected = candidates.min {
                distance($0.element.frame, offset: collection.contentOffset.y) < distance($1.element.frame, offset: collection.contentOffset.y)
            }
            if let selected {
                let representative = representativeIndex(selected.element)
                targetRepresentatives[destination.id] = destination.assetRange.contains(representative)
                    ? representative : destination.assetRange.lowerBound
            }
        }
        for (index, sourceItem) in visible {
            let representative = representativeIndex(sourceItem)
            let destinations = next.items.filter { !$0.isHeader && $0.assetRange.overlaps(sourceItem.assetRange) }
            let destination = destinations.first { $0.assetRange.contains(representative) } ?? destinations.first
            guard let destination, let cell = collection.cellForItem(at: IndexPath(item: index, section: 0)) else { continue }
            let keepsCover = targetRepresentatives[destination.id] == representative && represented.insert(destination.id).inserted
            let asset = catalog.assets[representative]
            let start = imageRect(item: sourceItem, scale: scale, asset: asset).offsetBy(dx: 0, dy: -collection.contentOffset.y)
            let end = imageRect(item: destination, scale: nextScale, asset: asset).offsetBy(dx: 0, dy: -targetOffset)
            let image = cachedImage(asset: asset, frame: sourceItem.frame)
            let snapshot: UIView
            if let image {
                let imageView = UIImageView(image: image)
                imageView.contentMode = .scaleAspectFill
                snapshot = imageView
            } else {
                snapshot = cell.snapshotView(afterScreenUpdates: false) ?? UIView()
            }
            addTransition(snapshot, start: start, end: end, incoming: false, disappears: !keepsCover,
                          startRadius: radius(scale), endRadius: radius(nextScale), to: surface)
        }
        // Refinement and week/month overlap can create multiple target covers
        // from one visible source. Add each unrepresented target exactly once.
        for destination in next.items where !destination.isHeader {
            let end = destination.frame.offsetBy(dx: 0, dy: -targetOffset)
            guard end.intersects(view.bounds), !represented.contains(destination.id),
                  let sourceItem = visible.first(where: { $0.element.assetRange.overlaps(destination.assetRange) })?.element
            else { continue }
            let representative = targetRepresentatives[destination.id] ?? destination.assetRange.lowerBound
            let asset = catalog.assets[representative]
            let imageView = UIImageView(image: cachedImage(asset: asset, frame: destination.frame))
            imageView.contentMode = .scaleAspectFill
            imageView.backgroundColor = .tertiarySystemFill
            let start = imageRect(item: sourceItem, scale: scale, asset: asset).offsetBy(dx: 0, dy: -collection.contentOffset.y)
            addTransition(imageView, start: start, end: imageRect(item: destination, scale: nextScale, asset: asset).offsetBy(dx: 0, dy: -targetOffset),
                          incoming: true, disappears: false, startRadius: radius(scale), endRadius: radius(nextScale), to: surface)
        }
        representativeAssets.merge(targetRepresentatives, uniquingKeysWith: { _, new in new })
        collection.alpha = 0
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
            item.view.alpha = item.incoming ? min(1, progress * 2) : item.disappears ? max(0, 1 - progress * 1.5) : 1
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
        transitionSurface?.removeFromSuperview()
        transitionSurface = nil
        transitionItems = []
        target = nil
        collection?.alpha = 1
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
            UIAccessibility.post(notification: .layoutChanged, argument: collection)
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
        publishViewport()
        expandWindowIfNeeded()
    }

    func scrollViewDidEndDecelerating(_: UIScrollView) {
        publishViewport()
    }

    private func publishViewport() {
        guard let input, input.isActive, let catalog, let projection, collection != nil,
              gesture == nil, animator == nil, !isInstalling else { return }
        let indexes = projection.items.filter { !$0.isHeader && $0.frame.intersects(collection.bounds) }.map(representativeIndex)
        let assets = indexes.map { catalog.assets[$0] }
        let ids = Set(assets.map(\.id))
        guard ids != lastVisibleIDs else { return }
        lastVisibleIDs = ids
        input.visibleAssetsChanged(assets)
    }

    private func expandWindowIfNeeded() {
        guard !isExpanding, let projection, let catalog, let focus = focusedItem(at: CGPoint(x: collection.bounds.midX, y: collection.bounds.midY)) else { return }
        let older = collection.contentOffset.y < collection.bounds.height
        let newer = layout.height - collection.bounds.maxY < collection.bounds.height
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
