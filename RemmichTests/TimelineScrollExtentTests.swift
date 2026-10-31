import CoreGraphics
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Remmich

@Suite("Timeline scroll extent", .serialized)
struct TimelineScrollExtentTests {
    @Test(arguments: TimelineSemanticScale.allCases)
    func fullExtentAndSharedFramesSurviveWindowChanges(scale: TimelineSemanticScale) {
        let catalog = makeCatalog(count: 3200, separateDays: true)
        for size in [CGSize(width: 402, height: 874), CGSize(width: 874, height: 402)] {
            let full = TimelineSemanticProjection.complete(catalog: catalog, scale: scale, size: size, isPhone: true, dark: true)
            let first = TimelineSemanticProjection.build(catalog: catalog, scale: scale, focusAssetIndex: 0, size: size, isPhone: true, dark: true)
            let middle = TimelineSemanticProjection.build(catalog: catalog, scale: scale, focusAssetIndex: 1600, size: size, isPhone: true, dark: true)
            let last = TimelineSemanticProjection.build(catalog: catalog, scale: scale, focusAssetIndex: 3199, size: size, isPhone: true, dark: true)
            for window in [first, middle, last] {
                #expect(window.height == full.height)
                #expect(window.items.count <= full.items.count)
                let reference = Dictionary(uniqueKeysWithValues: full.items.map { ($0.id, $0.frame) })
                #expect(window.items.allSatisfy { reference[$0.id] == $0.frame })
            }
            #expect(first.nodeRange.lowerBound == 0)
            #expect(last.nodeRange.upperBound == catalog.count(at: scale))
        }
    }

    @Test func fullLibraryMeasurementKeepsCellWindowBounded() {
        let catalog = makeCatalog(count: 27000, separateDays: false)
        let size = CGSize(width: 402, height: 874)
        let full = TimelineSemanticProjection.complete(catalog: catalog, scale: .natural, size: size, isPhone: true, dark: true)
        let window = full.window(catalog: catalog, focusAssetIndex: 13500, size: size, isPhone: true)
        #expect(window.items.count < 400)
        #expect(window.height == full.height)
        #expect(window.height > 100 * size.height)
    }

    @Test func scopedGridAndPartialMosaicExtentsMatchTheirRows() {
        #expect(abs(TimelineGridOrder.contentHeight(itemCount: 7, columns: 5, width: 402, spacing: 2) - 159.6) < 0.001)
        #expect(TimelineGridOrder.contentHeight(itemCount: 0, columns: 5, width: 402, spacing: 2) == 0)
        let portrait = TimelineRangeMosaicPlanner.blocks(keys: (0 ..< 7).map(String.init))
        let landscape = TimelineRangeMosaicPlanner.blocks(keys: (0 ..< 14).map(String.init), layout: .landscape)
        #expect(abs(TimelineRangeMosaicPlanner.contentHeight(portrait, width: 370) - (370 + 370 / 3 + 8)) < 0.001)
        #expect(abs(TimelineRangeMosaicPlanner.contentHeight(landscape, width: 370) - (370 + 370 / 4 + 8)) < 0.001)
    }

    @Test @MainActor func nativeScrollExtentSurvivesDistantIndicatorJumps() async throws {
        let catalog = makeCatalog(count: 3200, separateDays: true)
        for scale in [TimelineSemanticScale.square, .natural, .day] {
            let controller = TimelineSemanticCollectionController()
            defer { controller.stop() }
            controller.update(TimelineSemanticCollectionView(
                catalog: catalog, revision: 1, scale: scale,
                media: MediaLibraryController(), namespace: nil, bottomClearance: 96,
                runtime: TimelineSemanticRuntime(), latestRequest: 0, isActive: true,
                hiddenThumbnailID: nil, hiddenLivePhotoID: nil,
                selectAsset: { _, _ in }, selectGroup: { _, _ in }, scaleChanged: { _ in },
                scrolled: { _, _, _ in }, visibleAssetsChanged: { _, _, _ in }, refresh: {}
            ))
            controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            let collection = try #require(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
            let height = collection.contentSize.height
            #expect(collection.numberOfItems(inSection: 0) < 500)
            for fraction in [0.4, 0.05, 0.8] {
                let destination = (height - collection.bounds.height + collection.contentInset.bottom) * fraction
                collection.contentOffset.y = destination
                controller.scrollViewDidScroll(collection)
                for _ in 0 ..< 10 {
                    await Task.yield()
                }
                collection.layoutIfNeeded()
                #expect(abs(collection.contentSize.height - height) < 0.01)
                #expect(abs(collection.contentOffset.y - destination) < 1)
                #expect(!collection.indexPathsForVisibleItems.isEmpty)
                #expect(collection.numberOfItems(inSection: 0) < 1200)
            }
        }
    }

    @Test @MainActor func lazySwiftUIGridsKeepTheirMeasuredScrollExtent() async throws {
        let assets = makeCatalog(count: 700, separateDays: false).assets
        let media = MediaLibraryController()
        var appeared = Set<String>()
        let summaries = (0 ..< 121).map { index in
            TimelineBucketSummary(id: TimelineBucketID(rawValue: String(
                format: "%04d-%02d-01", 2020 + index / 12, index % 12 + 1
            )), assetCount: 1)
        }
        let store = PhotosTimelineStore(reader: PreviewTimelineReader(mode: .empty))
        let roots = [AnyView(ScrollView {
            TimelineAssetGrid(assets: assets, media: media, availableWidth: 402, visibilityChanged: { id, request in
                if request != nil {
                    appeared.insert(id)
                }
            })
        }), AnyView(PhotosMonthsView(summaries: summaries, store: store, media: media))]
        // App-hosted logic tests can start before scene connection. Yield to
        // UIKit's launch lifecycle before installing a visible SwiftUI host.
        for _ in 0 ..< 100 {
            if UIApplication.shared.connectedScenes.contains(where: { $0 is UIWindowScene }) {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for root in roots {
            let host = UIHostingController(rootView: root.environment(\.horizontalSizeClass, .compact).ignoresSafeArea())
            host.safeAreaRegions = []
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true }
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(120))
            let scroll = try #require(findScrollView(in: host.view))
            let height = scroll.contentSize.height
            #expect(height > scroll.bounds.height * 6)
            for fraction in [0.05, 0.5, 0.95] {
                scroll.setContentOffset(CGPoint(x: 0, y: (height - scroll.bounds.height) * fraction), animated: false)
                host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
                #expect(abs(scroll.contentSize.height - height) < 1)
            }
        }
        // Measuring the full extent must not realize every thumbnail.
        #expect(!appeared.isEmpty)
        #expect(appeared.count < assets.count / 2)
    }

    @MainActor private func findScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView {
            return scroll
        }
        for child in view.subviews {
            if let scroll = findScrollView(in: child) {
                return scroll
            }
        }
        return nil
    }

    private func makeCatalog(count: Int, separateDays: Bool) -> TimelineSemanticCatalog {
        let start = Date(timeIntervalSince1970: 1_577_836_800)
        return TimelineSemanticCatalog(assets: (0 ..< count).map { index in
            let date = start.addingTimeInterval(separateDays ? Double(index) * 86400 : 0)
            return TimelineAssetSummary(
                id: String(format: "%06d", index), ownerID: "owner", capturedAt: date, uploadedAt: start,
                localOffsetHours: 0, mediaKind: .image, durationMilliseconds: nil, aspectRatio: 1,
                isFavorite: false, visibility: .timeline, livePhotoVideoID: nil, stack: nil,
                projectionType: nil, thumbhash: nil, thumbnailRevision: start
            )
        })
    }
}
