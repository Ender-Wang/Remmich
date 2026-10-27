import CoreGraphics
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Remmich

@Suite("Timeline semantic zoom", .serialized)
struct TimelineSemanticZoomTests {
    @Test func memoryLaneUsesTheLargestAvailableTopSafeArea() {
        #expect(TimelineMemoryLaneSafeArea.topInset(proposed: 0, window: 62) == 62)
        #expect(TimelineMemoryLaneSafeArea.topInset(proposed: 59, window: 0) == 59)
        #expect(TimelineMemoryLaneSafeArea.topInset(proposed: 24, window: 59) == 59)
    }

    @Test func transitionCoverageKeepsVisibleSourcesAndBoundsOverscanWork() {
        let catalog = TimelineSemanticCatalog(assets: (0 ..< 900).map {
            asset(String(format: "%04d", $0), "2027-01-01T12:00:00Z")
        })
        let projection = TimelineSemanticProjection.build(
            catalog: catalog,
            scale: .natural,
            focusAssetIndex: 450,
            size: CGSize(width: 402, height: 874),
            isPhone: true,
            dark: true
        )
        let viewport = CGRect(x: 0, y: projection.height / 2 - 437, width: 402, height: 874)
        let indexes = TimelineSemanticTransitionPolicy.sourceIndexes(
            items: projection.items,
            viewport: viewport,
            focus: CGPoint(x: viewport.midX, y: viewport.midY)
        )
        let visible = Set(projection.items.indices.filter {
            !projection.items[$0].isHeader && projection.items[$0].frame.intersects(viewport)
        })
        #expect(visible.isSubset(of: Set(indexes)))
        #expect(indexes.count <= max(TimelineSemanticTransitionPolicy.sourceLimit, visible.count))
        let warmIndexes = TimelineSemanticTransitionPolicy.warmIndexes(
            items: projection.items,
            area: viewport.insetBy(dx: 0, dy: -viewport.height * 0.25),
            focus: CGPoint(x: viewport.midX, y: viewport.midY)
        )
        #expect(visible.isSubset(of: Set(warmIndexes)))
        #expect(warmIndexes.count <= TimelineSemanticTransitionPolicy.warmLimit)
    }

    @Test @MainActor func hostedTransitionMovesWithoutRelayingOutItsContent() {
        let destination = CGRect(x: 42, y: 170, width: 280, height: 190)
        let source = CGRect(x: 155, y: 610, width: 90, height: 130)
        let hostedView = UIView(frame: destination)

        hostedView.layer.setAffineTransform(TimelineSemanticCollectionController.transitionTransform(from: destination, to: source))
        #expect(hostedView.bounds.size == destination.size)
        #expect(abs(hostedView.frame.minX - source.minX) < 0.01)
        #expect(abs(hostedView.frame.minY - source.minY) < 0.01)
        #expect(abs(hostedView.frame.width - source.width) < 0.01)
        #expect(abs(hostedView.frame.height - source.height) < 0.01)

        hostedView.layer.setAffineTransform(TimelineSemanticCollectionController.transitionTransform(from: destination, to: destination))
        #expect(hostedView.frame == destination)
        #expect(hostedView.bounds.size == destination.size)
    }

    @Test func groupedResidencyDoesNotExpandRepresentativesIntoTimelinePages() {
        let visible = (0 ..< 140).map { asset("visible-\($0)", "2027-01-01T12:00:00Z") }
        let plan = TimelineSemanticResidencyPolicy.groupedPlan(visibleAssets: visible + visible.prefix(8))
        #expect(plan.newestAssets.isEmpty)
        #expect(plan.prefetchAssets.isEmpty)
        #expect(plan.viewportAssets.count == TimelineSemanticResidencyPolicy.groupedAssetLimit)
        #expect(Set(plan.viewportAssets.map(\.id)).count == plan.viewportAssets.count)
    }

    @Test @MainActor func hostedCellNeutralizesSystemBarsAtTheHostingBoundary() async throws {
        var measured = CGSize.zero
        let size = CGSize(width: 74, height: 122)
        let parent = UIViewController()
        let cell = TimelineSemanticCollectionCell(frame: CGRect(origin: .zero, size: size))
        cell.setHostedContent(
            GeometryReader { _ in
                Color.clear.onGeometryChange(for: CGSize.self) { $0.size } action: { measured = $0 }
            },
            parent: parent
        )
        parent.additionalSafeAreaInsets = UIEdgeInsets(top: 40, left: 0, bottom: 45, right: 0)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = parent
        parent.view.addSubview(cell)
        window.isHidden = false
        defer { window.isHidden = true }
        parent.view.setNeedsLayout()
        parent.view.layoutIfNeeded()
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        #expect(cell.hostedSafeAreaRegions == [])
        #expect(cell.hostedViewFrame == cell.contentView.bounds)
        #expect(cell.clipsToBounds)
        #expect(cell.contentView.clipsToBounds)
        #expect(cell.hostedViewClipsToBounds)
        #expect(measured == size)
    }

    @Test @MainActor func hostedAssetKeepsItsTapPathAlongsideNativePinch() throws {
        let catalog = TimelineSemanticCatalog(assets: (0 ..< 60).map { asset(String(format: "%03d", $0), "2027-01-01T12:00:00Z") })
        let controller = TimelineSemanticCollectionController()
        var selected: [String] = []
        var committed: [TimelineSemanticScale] = []
        controller.update(TimelineSemanticCollectionView(
            catalog: catalog, revision: 1, scale: .natural, media: MediaLibraryController(), namespace: nil,
            bottomClearance: 96, runtime: TimelineSemanticRuntime(), latestRequest: 0, isActive: true,
            hiddenThumbnailID: nil, hiddenLivePhotoID: nil,
            selectAsset: { asset, _ in selected.append(asset.id) }, selectGroup: { _, _ in },
            scaleChanged: { committed.append($0) }, scrolled: { _, _, _ in }, visibleAssetsChanged: { _, _, _ in }, refresh: {}
        ))
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        let collection = try #require(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
        let source = try #require(collection.dataSource as? UICollectionViewDiffableDataSource<Int, String>)
        let path = try #require(collection.indexPathsForVisibleItems.first { source.itemIdentifier(for: $0)?.hasPrefix("header:") == false })
        let cell = try #require(collection.cellForItem(at: path))
        #expect(cell.contentView.isUserInteractionEnabled)
        #expect(cell.contentConfiguration == nil)
        let hostedCell = try #require(cell as? TimelineSemanticCollectionCell)
        #expect(hostedCell.hasHostedContent)
        #expect(hostedCell.hostedSafeAreaRegions == [])
        controller.collectionView(collection, didSelectItemAt: path)
        // Asset selection remains owned by the hosted SwiftUI Button. The
        // collection delegate must not create a duplicate presentation.
        #expect(selected.isEmpty)
        let nativePinch = try #require(collection.gestureRecognizers?.first { $0.name == "timeline-semantic-pinch" })
        #expect(controller.gestureRecognizer(nativePinch, shouldRecognizeSimultaneouslyWith: collection.panGestureRecognizer))
        let pinch = SemanticTestPinch()
        pinch.point = CGPoint(x: collection.bounds.midX, y: collection.bounds.midY)
        pinch.testState = .began
        controller.perform(NSSelectorFromString("pinched:"), with: pinch)
        pinch.testState = .changed
        pinch.scale = 0.65
        controller.perform(NSSelectorFromString("pinched:"), with: pinch)
        pinch.testState = .ended
        controller.perform(NSSelectorFromString("pinched:"), with: pinch)
        #expect(committed == [.day])
        controller.stop()
    }

    @Test func crossMonthWeekOverlapsBothMonthsWithoutDuplicatingAssets() throws {
        let catalog = TimelineSemanticCatalog(assets: [asset("dec", "2026-12-31T12:00:00Z"), asset("jan", "2027-01-01T12:00:00Z")])
        let week = try #require(catalog.groups[.week]?.first)
        #expect(catalog.groups[.week]?.count == 1)
        #expect(week.assets == 0 ..< 2)
        #expect(catalog.overlapping(week.assets, scale: .month) == 0 ..< 2)
        #expect(try catalog.index(containing: #require(catalog.assetIndexes["dec"]), scale: .month) == 0)
        #expect(try catalog.index(containing: #require(catalog.assetIndexes["jan"]), scale: .month) == 1)
    }

    @Test func reversingBeforeReleaseDoesNotCommit() {
        var gesture = TimelineSemanticZoomGesture()
        gesture.update(magnification: 0.6)
        #expect(gesture.progress == 1)
        gesture.update(magnification: 0.99)
        #expect(gesture.progress < 0.03)
        #expect(!gesture.commits(magnification: 0.99))
        gesture.update(magnification: 1.5)
        #expect(gesture.coarser == true)
        #expect(gesture.progress == 0)
        #expect(!gesture.commits(magnification: 1.5))
    }

    @Test func gestureRetainsDeliberateThresholds() {
        var inward = TimelineSemanticZoomGesture()
        inward.update(magnification: 0.9)
        #expect(!inward.commits(magnification: 0.79))
        #expect(inward.commits(magnification: 0.78))
        var outward = TimelineSemanticZoomGesture()
        outward.update(magnification: 1.1)
        #expect(!outward.commits(magnification: 1.27))
        #expect(outward.commits(magnification: 1.28))
        #expect(TimelineSemanticScale.square.adjacent(coarser: false) == nil)
        #expect(TimelineSemanticScale.year.adjacent(coarser: true) == nil)
    }

    @Test func localProjectionIncludesFocusAndLeavesContinuationAtBothEnds() {
        let start = date("2020-01-01T12:00:00Z")
        let assets = (0 ..< 1200).map { i in
            var item = asset("asset-\(i)", "2020-01-01T12:00:00Z")
            item = TimelineAssetSummary(id: item.id, ownerID: item.ownerID,
                                        capturedAt: start.addingTimeInterval(Double(i) * 86400), uploadedAt: start,
                                        localOffsetHours: 0, mediaKind: .image, durationMilliseconds: nil, aspectRatio: 1,
                                        isFavorite: false, visibility: .timeline, livePhotoVideoID: nil,
                                        stack: nil, projectionType: nil, thumbhash: nil, thumbnailRevision: start)
            return item
        }
        let catalog = TimelineSemanticCatalog(assets: assets)
        for scale in [TimelineSemanticScale.natural, .day, .week] {
            let projection = TimelineSemanticProjection.build(catalog: catalog, scale: scale, focusAssetIndex: 600,
                                                              size: CGSize(width: 402, height: 874), isPhone: true, dark: true)
            #expect(projection.nodeRange.lowerBound > 0)
            #expect(projection.nodeRange.upperBound < catalog.count(at: scale))
            #expect(projection.items.contains { !$0.isHeader && $0.assetRange.contains(600) })
            #expect(projection.items.allSatisfy { $0.frame.minX >= 0 && $0.frame.maxX <= 402.5 })
        }
    }

    @Test func assetRowsKeepNewestOnLeftAtBottom() {
        let catalog = TimelineSemanticCatalog(assets: (0 ..< 7).map { asset("\($0)", "2027-01-01T12:00:00Z") })
        let projection = TimelineSemanticProjection.build(catalog: catalog, scale: .square, focusAssetIndex: 6,
                                                          size: CGSize(width: 402, height: 874), isPhone: true, dark: true)
        let frames = projection.items.filter { !$0.isHeader }.sorted {
            $0.frame.minY == $1.frame.minY ? $0.frame.minX < $1.frame.minX : $0.frame.minY > $1.frame.minY
        }
        #expect(frames.first?.id == "6")
        #expect(frames[1].id == "5")
    }

    @Test func growingWindowPreservesCellColumnsAndRelativeFrames() throws {
        let catalog = TimelineSemanticCatalog(assets: (0 ..< 900).map { asset(String(format: "%04d", $0), "2027-01-01T12:00:00Z") })
        for scale in [TimelineSemanticScale.square, .natural] {
            let initial = TimelineSemanticProjection.build(catalog: catalog, scale: scale, focusAssetIndex: 450,
                                                           size: CGSize(width: 402, height: 874), isPhone: true, dark: true,
                                                           requestedRange: 333 ..< 567)
            let expanded = TimelineSemanticProjection.build(catalog: catalog, scale: scale, focusAssetIndex: 450,
                                                            size: CGSize(width: 402, height: 874), isPhone: true, dark: true,
                                                            requestedRange: 155 ..< 740)
            let original = initial.items.filter { !$0.isHeader }
            let frames = Dictionary(uniqueKeysWithValues: expanded.items.filter { !$0.isHeader }.map { ($0.id, $0.frame) })
            let reference = try #require(original.first)
            let delta = try #require(frames[reference.id]).minY - reference.frame.minY
            for item in original {
                let frame = try #require(frames[item.id])
                #expect(frame.minX == item.frame.minX)
                #expect(abs(frame.minY - item.frame.minY - delta) < 0.01)
            }
        }
    }

    @Test @MainActor func collectionStagesTargetAndAppliesBottomClearanceOnce() throws {
        let catalog = TimelineSemanticCatalog(assets: (0 ..< 60).map { asset(String(format: "%03d", $0), "2027-01-01T12:00:00Z") })
        let controller = TimelineSemanticCollectionController()
        var committed: [TimelineSemanticScale] = []
        var reportedTargets: [MediaPixelSize] = []
        var reportedScales: [TimelineSemanticScale] = []
        var focusedAssets: [String] = []
        let input = TimelineSemanticCollectionView(
            catalog: catalog, revision: 1, scale: .natural, media: MediaLibraryController(), namespace: nil,
            bottomClearance: 96, runtime: TimelineSemanticRuntime(), latestRequest: 0, isActive: true,
            hiddenThumbnailID: nil, hiddenLivePhotoID: nil, selectAsset: { _, _ in }, selectGroup: { _, _ in },
            scaleChanged: { committed.append($0) }, scrolled: { _, _, _ in },
            visibleAssetsChanged: { _, pixels, scale in
                reportedTargets.append(pixels)
                reportedScales.append(scale)
            }, refresh: {},
            focusChanged: { focusedAssets.append($0.id) }
        )
        controller.update(input)
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        let collection = try #require(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
        #expect(collection.contentInset.bottom == 96)
        #expect(!focusedAssets.isEmpty)
        let assetPath = try #require(collection.indexPathsForVisibleItems.first {
            (collection.dataSource as? UICollectionViewDiffableDataSource<Int, String>)?.itemIdentifier(for: $0)?.hasPrefix("header:") == false
        })
        let assetCell = try #require(collection.cellForItem(at: assetPath))
        let pixels = Int((max(assetCell.bounds.width, assetCell.bounds.height) * controller.traitCollection.displayScale).rounded(.up))
        #expect(reportedTargets.last == MediaPixelSize(width: pixels, height: pixels))
        let attributes = try #require(collection.collectionViewLayout.layoutAttributesForItem(at: assetPath))
        #expect(assetCell.preferredLayoutAttributesFitting(attributes).frame == attributes.frame)
        controller.collectionView(collection, didEndDisplaying: assetCell, forItemAt: assetPath)
        #expect((assetCell as? TimelineSemanticCollectionCell)?.hasHostedContent == false)
        controller.collectionView(collection, willDisplay: assetCell, forItemAt: assetPath)
        #expect((assetCell as? TimelineSemanticCollectionCell)?.hasHostedContent == true)
        #expect(abs(collection.contentSize.height - collection.contentOffset.y - collection.bounds.height + 96) < 0.5)
        controller.changeScale(coarser: true)
        #expect(committed == [.day])
        // The staged destination must not publish a viewport and start thumbnail
        // work while its image is still moving or crossfading into the collection.
        #expect(reportedScales.last == .natural)
        #expect(collection.numberOfItems(inSection: 0) == 1)
        let card = try #require(collection.collectionViewLayout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)))
        let clearance = collection.bounds.height - 96 - card.frame.maxY
        #expect(clearance >= 12 && clearance <= 24)
        // Rotation interrupts an in-flight settle without a hidden destination
        // or a dependency on the shell's retired scroll-settlement callback.
        controller.view.frame = CGRect(x: 0, y: 0, width: 874, height: 402)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        #expect(committed == [.day])
        #expect(reportedScales.last == .day)
        controller.stop()
        #expect(collection.alpha == 1)
        #expect(controller.view.subviews.count == 1)
    }

    @Test @MainActor func nativeWindowGrowthPreservesVisibleFramesAndCells() async throws {
        let catalog = TimelineSemanticCatalog(assets: (0 ..< 900).map { asset(String(format: "%04d", $0), "2027-01-01T12:00:00Z") })
        let controller = TimelineSemanticCollectionController()
        controller.update(TimelineSemanticCollectionView(
            catalog: catalog, revision: 1, scale: .natural, media: MediaLibraryController(), namespace: nil,
            bottomClearance: 96, runtime: TimelineSemanticRuntime(), latestRequest: 0, isActive: true,
            hiddenThumbnailID: nil, hiddenLivePhotoID: nil, selectAsset: { _, _ in }, selectGroup: { _, _ in },
            scaleChanged: { _ in }, scrolled: { _, _, _ in }, visibleAssetsChanged: { _, _, _ in }, refresh: {}
        ))
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        let collection = try #require(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
        let dataSource = try #require(collection.dataSource as? UICollectionViewDiffableDataSource<Int, String>)
        collection.delegate = nil
        collection.contentOffset.y = 300
        collection.layoutIfNeeded()
        let before = Dictionary(uniqueKeysWithValues: collection.indexPathsForVisibleItems.compactMap { path -> (String, (CGRect, UICollectionViewCell))? in
            guard let id = dataSource.itemIdentifier(for: path), !id.hasPrefix("header:"),
                  let cell = collection.cellForItem(at: path) else { return nil }
            return (id, (cell.frame.offsetBy(dx: 0, dy: -collection.contentOffset.y), cell))
        })
        #expect(!before.isEmpty)
        let initialCount = collection.numberOfItems(inSection: 0)
        collection.delegate = controller
        controller.scrollViewDidScroll(collection)
        try await Task.sleep(for: .milliseconds(10))
        collection.layoutIfNeeded()
        var compared = 0
        for path in collection.indexPathsForVisibleItems {
            guard let id = dataSource.itemIdentifier(for: path), let old = before[id],
                  let cell = collection.cellForItem(at: path) else { continue }
            let frame = cell.frame.offsetBy(dx: 0, dy: -collection.contentOffset.y)
            compared += 1
            #expect(abs(frame.minY - old.0.minY) < 0.5)
            #expect(frame.minX == old.0.minX)
            #expect(cell === old.1)
        }
        #expect(compared == before.count)
        let expandedCount = collection.numberOfItems(inSection: 0)
        #expect(expandedCount > initialCount)
        controller.scrollViewDidScroll(collection)
        try await Task.sleep(for: .milliseconds(10))
        #expect(collection.numberOfItems(inSection: 0) == expandedCount)
        controller.stop()
    }

    @Test @MainActor func latestJumpWithCatalogRefreshInstallsOnlyFinalWindow() throws {
        let media = MediaLibraryController()
        let controller = TimelineSemanticCollectionController()
        func input(count: Int, revision: UInt64, latestRequest: Int) -> TimelineSemanticCollectionView {
            TimelineSemanticCollectionView(
                catalog: TimelineSemanticCatalog(assets: (0 ..< count).map {
                    asset(String(format: "%03d", $0), "2027-01-01T12:00:00Z")
                }),
                revision: revision, scale: .natural, media: media, namespace: nil,
                bottomClearance: 96, runtime: TimelineSemanticRuntime(), latestRequest: latestRequest, isActive: true,
                hiddenThumbnailID: nil, hiddenLivePhotoID: nil, selectAsset: { _, _ in }, selectGroup: { _, _ in },
                scaleChanged: { _ in }, scrolled: { _, _, _ in }, visibleAssetsChanged: { _, _, _ in }, refresh: {}
            )
        }
        controller.update(input(count: 60, revision: 1, latestRequest: 0))
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        let before = controller.installationCount

        controller.update(input(count: 90, revision: 2, latestRequest: 1))

        let collection = try #require(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
        #expect(controller.installationCount == before + 1)
        #expect(abs(collection.contentSize.height - collection.contentOffset.y - collection.bounds.height + 96) < 0.5)
        controller.stop()
    }

    private func date(_ value: String) -> Date {
        try! Date(value, strategy: .iso8601)
    }

    @Test @MainActor func zoomCoversEveryIncomingViewportTileWithoutVisibleSourceMembership() throws {
        let start = date("2026-01-01T12:00:00Z")
        let assets = (0 ..< 180).map { i in
            let base = asset("day-\(i)", "2026-01-01T12:00:00Z")
            return TimelineAssetSummary(id: base.id, ownerID: base.ownerID,
                                        capturedAt: start.addingTimeInterval(Double(i) * 86400), uploadedAt: start,
                                        localOffsetHours: 0, mediaKind: .image, durationMilliseconds: nil, aspectRatio: 1,
                                        isFavorite: false, visibility: .timeline, livePhotoVideoID: nil, stack: nil,
                                        projectionType: nil, thumbhash: nil, thumbnailRevision: start)
        }
        let controller = TimelineSemanticCollectionController()
        controller.update(TimelineSemanticCollectionView(
            catalog: TimelineSemanticCatalog(assets: assets), revision: 1, scale: .day, media: MediaLibraryController(), namespace: nil,
            bottomClearance: 96, runtime: TimelineSemanticRuntime(), latestRequest: 0, isActive: true,
            hiddenThumbnailID: nil, hiddenLivePhotoID: nil, selectAsset: { _, _ in }, selectGroup: { _, _ in },
            scaleChanged: { _ in }, scrolled: { _, _, _ in }, visibleAssetsChanged: { _, _, _ in }, refresh: {}
        ))
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        controller.changeScale(coarser: true)
        let collection = try #require(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
        let dataSource = try #require(collection.dataSource as? UICollectionViewDiffableDataSource<Int, String>)
        let visibleIDs = Set(collection.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) })
        let surface = try #require(controller.view.subviews.first { $0 !== collection })
        let covered = Set(surface.subviews.compactMap { view -> String? in
            guard let id = view.accessibilityIdentifier, id.hasPrefix("semantic-zoom-target:") else { return nil }
            return String(id.dropFirst("semantic-zoom-target:".count))
        })
        #expect(visibleIDs.count > 1)
        #expect(visibleIDs.isSubset(of: covered))
        controller.stop()
    }

    @Test @MainActor func historyLoadingFillsGapsBeforeAnOlderLoadedIsland() async {
        let buckets = (1 ... 7).reversed().map { TimelineBucketSummary(id: .init(rawValue: String(format: "2027-%02d-01", $0)), assetCount: 1) }
        let reader = SemanticHistoryReader(buckets: buckets, emptyIDs: [])
        let store = PhotosTimelineStore(reader: reader)
        await store.load()
        await store.loadBucket(buckets[1].id)
        await store.loadBucket(buckets[4].id)
        #expect(store.sectionsByID[buckets[2].id]?.assets.isEmpty == true)
        await store.loadOlderSemanticPage()
        #expect(store.sectionsByID[buckets[2].id]?.loadState == .loaded)
        #expect(store.sectionsByID[buckets[2].id]?.assets.isEmpty == false)
    }

    @Test @MainActor func emptyNewestPeriodsAdvanceToDisplayableHistory() async {
        let buckets = ["2027-03-01", "2027-02-01", "2027-01-01"].map { TimelineBucketSummary(id: .init(rawValue: $0), assetCount: 1) }
        let reader = SemanticHistoryReader(buckets: buckets, emptyIDs: Set(buckets.prefix(2).map(\.id)))
        let store = PhotosTimelineStore(reader: reader)
        await store.load()
        await store.loadOlderSemanticPage()
        #expect(store.semanticAssetsSnapshot().count == 1)
        #expect(store.sectionsByID[buckets[2].id]?.loadState == .loaded)
        #expect(!store.hasUnloadedSemanticBuckets)
    }

    @Test @MainActor func entirelyFilteredHistoryFinishesWithAnExplicitEmptyState() async {
        let buckets = ["2027-03-01", "2027-02-01", "2027-01-01"].map { TimelineBucketSummary(id: .init(rawValue: $0), assetCount: 1) }
        let reader = SemanticHistoryReader(buckets: buckets, emptyIDs: Set(buckets.map(\.id)))
        let store = PhotosTimelineStore(reader: reader)
        await store.load()
        await store.loadOlderSemanticPage()
        #expect(store.semanticAssetsSnapshot().isEmpty)
        #expect(store.semanticHistoryState == .empty)
        #expect(!store.hasUnloadedSemanticBuckets)
    }

    @Test func semanticWeeksMatchTheExistingCrossMonthCatalog() throws {
        let december = TimelineBucketSummary(id: .init(rawValue: "2026-12-01"), assetCount: 1)
        let january = TimelineBucketSummary(id: .init(rawValue: "2027-01-01"), assetCount: 2)
        let decAssets = [asset("dec-31", "2026-12-31T12:00:00Z")]
        let janAssets = [asset("jan-4", "2027-01-04T12:00:00Z"), asset("jan-1", "2027-01-01T12:00:00Z")]
        let old = TimelineRangeCatalog.libraryWeeks(endingIn: january.id,
                                                    current: .init(summary: january, assets: janAssets, loadState: .loaded, contentRevision: 1),
                                                    previous: .init(summary: december, assets: decAssets, loadState: .loaded, contentRevision: 1), hasNextMonth: false)
        let semantic = TimelineSemanticCatalog(assets: decAssets + janAssets)
        let groups = try #require(semantic.groups[.week])
        #expect(groups.map(\.assets.count) == old.map(\.assetCount))
        #expect(groups.map(\.id) == old.map { "week:\($0.id.id)" })
    }

    private func asset(_ id: String, _ timestamp: String) -> TimelineAssetSummary {
        TimelineAssetSummary(id: id, ownerID: "owner", capturedAt: date(timestamp), uploadedAt: date(timestamp),
                             localOffsetHours: 0, mediaKind: .image, durationMilliseconds: nil, aspectRatio: 1.5,
                             isFavorite: false, visibility: .timeline, livePhotoVideoID: nil, stack: nil,
                             projectionType: nil, thumbhash: nil, thumbnailRevision: date(timestamp))
    }
}

@MainActor
private final class SemanticTestPinch: UIPinchGestureRecognizer {
    var testState: UIGestureRecognizer.State = .possible
    var point = CGPoint.zero

    override var state: UIGestureRecognizer.State {
        get { testState }
        set { testState = newValue }
    }

    override func location(in _: UIView?) -> CGPoint {
        point
    }
}

private actor SemanticHistoryReader: TimelineReading {
    let buckets: [TimelineBucketSummary]
    let emptyIDs: Set<TimelineBucketID>

    init(buckets: [TimelineBucketSummary], emptyIDs: Set<TimelineBucketID>) {
        self.buckets = buckets
        self.emptyIDs = emptyIDs
    }

    func bucketSummaries(query _: TimelineQuery) async throws -> [TimelineBucketSummary] {
        buckets
    }

    func assets(in bucketID: TimelineBucketID, query _: TimelineQuery) async throws -> [TimelineAssetSummary] {
        if emptyIDs.contains(bucketID) {
            return []
        }
        let date = bucketID.displayDate!
        return [.init(id: bucketID.rawValue, ownerID: "owner", capturedAt: date, uploadedAt: date,
                      localOffsetHours: 0, mediaKind: .image, durationMilliseconds: nil, aspectRatio: 1,
                      isFavorite: false, visibility: .timeline, livePhotoVideoID: nil, stack: nil,
                      projectionType: nil, thumbhash: nil, thumbnailRevision: date)]
    }

    func memories() async throws -> [TimelineMemorySummary] {
        []
    }
}
