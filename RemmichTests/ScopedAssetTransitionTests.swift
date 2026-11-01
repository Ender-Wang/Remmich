import Combine
import SwiftUI
import Testing
import UIKit
@testable import Remmich

@Suite("Scoped asset transition geometry", .serialized)
@MainActor
struct ScopedAssetTransitionTests {
    @Test func measuredTargetTracksScrollingAndTheSelectedAssetsAspectRatio() async throws {
        let window = try await makeWindow()
        defer { window.isHidden = true }
        let root = try #require(window.rootViewController)
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 80, width: 402, height: 600))
        scroll.contentSize = CGSize(width: 402, height: 1800)
        scroll.clipsToBounds = true
        root.view.addSubview(scroll)
        let source = UIView(frame: CGRect(x: 50, y: 700, width: 90, height: 120))
        let other = UIView(frame: CGRect(x: 200, y: 900, width: 90, height: 120))
        scroll.addSubview(source)
        scroll.addSubview(other)
        scroll.contentOffset.y = 600
        let runtime = ScopedAssetTransitionRuntime()
        runtime.register(source, scope: .year(2026), assetID: "first", aspectRatio: 1.5, naturalAspectProgress: 1)
        runtime.register(other, scope: .year(2026), assetID: "second", aspectRatio: 0.5, naturalAspectProgress: 1)

        let initial = try #require(runtime.target(assetID: "first", scope: .year(2026)))
        #expect(initial.imageFrame == source.convert(CGRect(x: 0, y: 30, width: 90, height: 60), to: nil))
        #expect(!initial.fillsFrame)
        scroll.contentOffset.y = 650
        let moved = try #require(runtime.target(assetID: "first", scope: .year(2026)))
        #expect(abs(moved.imageFrame.minY - initial.imageFrame.minY + 50) < 0.01)
        let selected = try #require(runtime.target(assetID: "second", scope: .year(2026)))
        #expect(selected.imageFrame == other.convert(CGRect(x: 15, y: 0, width: 60, height: 120), to: nil))
    }

    @Test func sourceLookupRejectsOffscreenDetachedAndDifferentScopeEntries() async throws {
        let window = try await makeWindow()
        defer { window.isHidden = true }
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 100, width: 300, height: 300))
        scroll.contentSize = CGSize(width: 300, height: 1800)
        scroll.clipsToBounds = true
        window.rootViewController?.view.addSubview(scroll)
        let source = UIView(frame: CGRect(x: 20, y: 600, width: 90, height: 90))
        scroll.addSubview(source)
        let runtime = ScopedAssetTransitionRuntime()
        runtime.register(source, scope: .year(2026), assetID: "same", aspectRatio: 0.5, naturalAspectProgress: 0)
        #expect(runtime.target(assetID: "same", scope: .year(2026)) == nil)
        scroll.contentOffset.y = 500
        let visible = try #require(runtime.target(assetID: "same", scope: .year(2026)))
        #expect(visible.fillsFrame)
        #expect(visible.imageFrame.size == source.bounds.size)
        #expect(runtime.target(assetID: "same", scope: .year(2025)) == nil)
        source.removeFromSuperview()
        #expect(runtime.target(assetID: "same", scope: .year(2026)) == nil)
    }

    @Test func unregisteringOldCellDoesNotRemoveItsReplacementAndOpacityDoesNotLoseTheTarget() async throws {
        let window = try await makeWindow()
        defer { window.isHidden = true }
        let root = try #require(window.rootViewController)
        let old = UIView(frame: CGRect(x: 20, y: 150, width: 90, height: 90))
        let replacement = UIView(frame: CGRect(x: 160, y: 200, width: 90, height: 90))
        root.view.addSubview(old)
        root.view.addSubview(replacement)
        let runtime = ScopedAssetTransitionRuntime()
        runtime.register(old, scope: .year(2026), assetID: "asset", aspectRatio: 1, naturalAspectProgress: 0)
        runtime.register(replacement, scope: .year(2026), assetID: "asset", aspectRatio: 1, naturalAspectProgress: 0)
        runtime.unregister(old)
        replacement.alpha = 0

        let target = try #require(runtime.target(assetID: "asset", scope: .year(2026)))
        #expect(target.imageFrame == replacement.convert(replacement.bounds, to: nil))
        runtime.unregister(replacement)
        #expect(runtime.target(assetID: "asset", scope: .year(2026)) == nil)
    }

    @Test func swiftUICellProbeRemainsUsableWhileTransparentFullScreenViewerIsPresented() async throws {
        let window = try await makeWindow()
        defer { window.isHidden = true }
        let runtime = ScopedAssetTransitionRuntime()
        let state = CoverState()
        let host = UIHostingController(rootView: ScopedSourceFixture(runtime: runtime, state: state))
        host.safeAreaRegions = []
        window.rootViewController = host
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(120))
        let initial = try #require(runtime.target(assetID: "fixture", scope: .year(2026)))

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { state.presented = true }
        try await Task.sleep(for: .milliseconds(120))
        _ = try #require(host.presentedViewController)
        let covered = try #require(runtime.target(assetID: "fixture", scope: .year(2026)))
        #expect(covered.imageFrame == initial.imageFrame)
        state.presented = false
    }

    @Test func sourcePixelsAreScopedRevisionCheckedAndNotRetainedByTheRegistry() async throws {
        let window = try await makeWindow()
        defer { window.isHidden = true }
        let view = UIView(frame: CGRect(x: 20, y: 150, width: 90, height: 90))
        window.rootViewController?.view.addSubview(view)
        let runtime = ScopedAssetTransitionRuntime()
        let asset = sourceAsset()
        runtime.register(view, scope: .year(2026), assetID: asset.id, aspectRatio: 1, naturalAspectProgress: 0)
        autoreleasepool {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
            }
            runtime.imageLoaded(image, asset: asset, scope: .year(2026))
            #expect(runtime.transitionImage(for: asset, scope: .year(2026)) === image)
            #expect(runtime.transitionImage(for: asset, scope: .year(2025)) == nil)
            #expect(runtime.transitionImage(for: sourceAsset(revision: .distantFuture), scope: .year(2026)) == nil)
        }
        #expect(runtime.transitionImage(for: asset, scope: .year(2026)) == nil)
    }

    @Test func stillViewerDisplaysSourcePixelsWithoutWaitingForAnImagePipeline() async throws {
        let window = try await makeWindow()
        defer { window.isHidden = true }
        let source = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        let viewer = ZoomableStillImageView(
            asset: sourceAsset(), media: MediaLibraryController(), isSelected: true, sourceImage: source,
            targetPixels: .init(width: 400, height: 400), fitRect: CGRect(x: 0, y: 0, width: 200, height: 200),
            animatesFitChanges: false, showsBackground: false, reportsRenderedImageMetadata: true,
            fullResolutionRequestID: nil, renderedImageMetadataChanged: { _ in }, fullResolutionLoadFailed: { _ in },
            zoomChanged: { _ in }, livePhotoPressChanged: { _ in }, toggleChrome: {}
        )
        let host = UIHostingController(rootView: viewer.frame(width: 200, height: 200))
        window.rootViewController = host
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(120))
        func containsSourceImage(_ view: UIView) -> Bool {
            (view as? UIImageView)?.image === source || view.subviews.contains(where: containsSourceImage)
        }
        #expect(containsSourceImage(host.view))
    }

    private func sourceAsset(revision: Date = .distantPast) -> TimelineAssetSummary {
        TimelineAssetSummary(id: "source", ownerID: "owner", capturedAt: .distantPast, uploadedAt: .distantPast,
                             localOffsetHours: 0, mediaKind: .image, durationMilliseconds: nil, aspectRatio: 1,
                             isFavorite: false, visibility: .timeline, livePhotoVideoID: nil, stack: nil,
                             projectionType: nil, thumbhash: nil, thumbnailRevision: revision)
    }

    private func makeWindow() async throws -> UIWindow {
        for _ in 0 ..< 100 {
            if UIApplication.shared.connectedScenes.contains(where: { $0 is UIWindowScene }) {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = UIViewController()
        window.isHidden = false
        window.rootViewController?.view.layoutIfNeeded()
        return window
    }
}

@MainActor
private final class CoverState: ObservableObject {
    @Published var presented = false
}

private struct ScopedSourceFixture: View {
    let runtime: ScopedAssetTransitionRuntime
    @ObservedObject var state: CoverState

    private var asset: TimelineAssetSummary {
        TimelineAssetSummary(id: "fixture", ownerID: "owner", capturedAt: .distantPast, uploadedAt: .distantPast,
                             localOffsetHours: 0, mediaKind: .image, durationMilliseconds: nil, aspectRatio: 1.5,
                             isFavorite: false, visibility: .timeline, livePhotoVideoID: nil, stack: nil,
                             projectionType: nil, thumbhash: nil, thumbnailRevision: .distantPast)
    }

    var body: some View {
        ScrollView {
            TimelineAssetThumbnail(asset: asset, media: MediaLibraryController(), assetLayout: .naturalAspect,
                                   visibilityChanged: { _, _ in }, viewportChanged: { _, _ in },
                                   transitionNamespace: nil, assetSelected: { _ in })
                .frame(width: 90, height: 120)
                .padding(.top, 100)
            Color.clear.frame(height: 1000)
        }
        .environment(\.scopedAssetTransitionContext, ScopedAssetTransitionContext(runtime: runtime, scope: .year(2026)))
        .fullScreenCover(isPresented: $state.presented) {
            Color.black.ignoresSafeArea().presentationBackground(.clear)
        }
    }
}
