import Combine
import SwiftUI
import Testing
import UIKit
@testable import Remmich

@Suite("Scoped initial viewport and viewer transitions", .serialized)
@MainActor
struct ScopedDayTransitionTests {
    @Test(arguments: [1, 5, 80], [false, true])
    func newestDayAssetRemainsVisibleThroughCover(assetCount: Int, landscape: Bool) async throws {
        try await checkViewport(range: "day", assetCount: assetCount, landscape: landscape)
    }

    @Test(arguments: ["week", "month", "year"], [false, true])
    func groupedRangesStartAtNewestAndDoNotJumpWhenOpening(range: String, landscape: Bool) async throws {
        try await checkViewport(range: range, assetCount: 80, landscape: landscape)
    }

    private func checkViewport(range: String, assetCount: Int, landscape: Bool) async throws {
        for _ in 0 ..< 100 {
            if UIApplication.shared.connectedScenes.contains(where: { $0 is UIWindowScene }) {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: landscape ? CGSize(width: 874, height: 402) : CGSize(width: 402, height: 874))
        defer { window.isHidden = true }
        let runtime = ScopedAssetTransitionRuntime()
        let state = DayCoverState()
        let bucket = TimelineBucketID(rawValue: "2026-10-01")
        let date = try #require(bucket.displayDate).addingTimeInterval(14 * 86400 + 12 * 3600)
        let scope: PhotosRangeRoute = switch range {
        case "week":
            try .week(bucket, #require(TimelineWeekID(day: TimelineCaptureDay(capturedAt: date))), .bucket)
        case "month": .month(bucket)
        case "year": .year(2026)
        default: .day(bucket, TimelineCaptureDay(capturedAt: date))
        }
        let assets = (0 ..< assetCount).map { index in
            TimelineAssetSummary(id: "day-\(index)", ownerID: "owner", capturedAt: date.addingTimeInterval(-Double(index) * (range == "day" ? 1 : 1800)), uploadedAt: date,
                                 localOffsetHours: 0, mediaKind: .image, durationMilliseconds: nil,
                                 aspectRatio: 0.5, isFavorite: false, visibility: .timeline,
                                 livePhotoVideoID: nil, stack: nil, projectionType: nil,
                                 thumbhash: nil, thumbnailRevision: date)
        }
        let store = PhotosTimelineStore(reader: PreviewTimelineReader())
        store.bootstrap(.init(generation: 1, summaries: [.init(id: bucket, assetCount: assetCount)],
                              assetsByBucket: [bucket: assets], groupedCatalogs: .init(), isComplete: true))
        let host = UIHostingController(rootView: DayCoverFixture(runtime: runtime, state: state,
                                                                 scope: scope, store: store, tabBarTop: window.bounds.height - 84))
        host.safeAreaRegions = .keyboard
        let tabs = UITabBarController()
        tabs.viewControllers = [host]
        window.rootViewController = tabs
        window.isHidden = false
        tabs.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        // IDs are deliberately not chronological; timestamps identify the latest asset.
        let initial = try #require(runtime.target(assetID: "day-0", scope: scope))
        if assetCount == 80 {
            #expect(runtime.target(assetID: "day-79", scope: scope) == nil)
        }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { state.presented = true }
        try await Task.sleep(for: .milliseconds(500))
        _ = try #require(host.presentedViewController)
        let covered = try #require(runtime.target(assetID: "day-0", scope: scope))
        #expect(covered.imageFrame == initial.imageFrame)
        state.presented = false
        try await Task.sleep(for: .milliseconds(500))
        let returned = try #require(runtime.target(assetID: "day-0", scope: scope))
        #expect(returned.imageFrame == initial.imageFrame)
    }
}

@MainActor
private final class DayCoverState: ObservableObject {
    @Published var presented = false
}

private struct DayCoverFixture: View {
    let runtime: ScopedAssetTransitionRuntime
    @ObservedObject var state: DayCoverState
    let scope: PhotosRangeRoute
    let store: PhotosTimelineStore
    let tabBarTop: CGFloat

    var body: some View {
        NavigationStack(path: .constant([scope])) {
            Color.clear
                .navigationDestination(for: PhotosRangeRoute.self) { route in
                    PhotosRangeAssetsView(route: route, store: store, media: MediaLibraryController(),
                                          tabBarTop: tabBarTop, assetLayout: .naturalAspect)
                        .navigationTitle(route.navigationTitle)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbarBackground(.visible, for: .navigationBar)
                        .environment(\.scopedAssetTransitionContext, .init(runtime: runtime, scope: scope))
                }
                .fullScreenCover(isPresented: $state.presented) {
                    Color.black.ignoresSafeArea().presentationBackground(.clear)
                        .toolbar(.hidden, for: .navigationBar)
                }
        }
    }
}
