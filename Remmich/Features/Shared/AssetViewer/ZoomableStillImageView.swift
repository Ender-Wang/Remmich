import Nuke
import SwiftUI
import UIKit

struct ZoomableStillImageView: View {
    let asset: TimelineAssetSummary
    let media: MediaLibraryController
    let targetPixels: MediaPixelSize
    let isSelected: Bool
    let zoomChanged: (Bool) -> Void
    let toggleChrome: () -> Void

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)

            if let image {
                ZoomableImageScrollView(
                    image: image,
                    assetID: asset.id,
                    zoomChanged: zoomChanged,
                    toggleChrome: toggleChrome
                )
            } else if failed {
                ContentUnavailableView(
                    "Unable to Load Photo",
                    systemImage: "photo.badge.exclamationmark"
                )
                .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .tint(.primary)
            }
        }
        .task(id: loadID) {
            await loadProgressively()
        }
        .onDisappear { zoomChanged(false) }
        .accessibilityIdentifier("asset-viewer-still-\(asset.id)")
    }

    private var loadID: String {
        "\(asset.id)|\(targetPixels.width)x\(targetPixels.height)|\(isSelected)"
    }

    private func loadProgressively() async {
        failed = false
        do {
            if image == nil {
                image = try await load(.preview)
            }
            guard isSelected, !Task.isCancelled else { return }
            image = try await load(.fullSize)
        } catch is CancellationError {
            return
        } catch {
            failed = image == nil
        }
    }

    private func load(_ derivative: MediaDerivative) async throws -> UIImage {
        let requestPixels = if derivative == .fullSize {
            MediaPixelSize(
                width: min(6144, targetPixels.width * 3),
                height: min(6144, targetPixels.height * 3)
            )
        } else {
            targetPixels
        }
        guard let pipeline = media.pipeline,
              let request = media.imageRequest(for: .init(
                  assetID: asset.id,
                  updatedAt: asset.thumbnailRevision,
                  derivative: derivative,
                  targetPixels: requestPixels
              ))
        else {
            throw AssetViewerImageError.unavailable
        }
        return try await pipeline.image(for: request)
    }
}

private enum AssetViewerImageError: Error {
    case unavailable
}

private struct ZoomableImageScrollView: UIViewRepresentable {
    let image: UIImage
    let assetID: String
    let zoomChanged: (Bool) -> Void
    let toggleChrome: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(zoomChanged: zoomChanged, toggleChrome: toggleChrome)
    }

    func makeUIView(context: Context) -> ViewerZoomScrollView {
        let scrollView = ViewerZoomScrollView()
        scrollView.backgroundColor = .systemBackground
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.decelerationRate = .fast
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.accessibilityLabel = "Zoomable photo"
        scrollView.accessibilityIdentifier = "asset-viewer-zoom-\(assetID)"

        let imageView = context.coordinator.imageView
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .systemBackground
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)
        scrollView.zoomTarget = imageView

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSingleTap(_:))
        )
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)
        context.coordinator.scrollView = scrollView
        scrollView.accessibilityCustomActions = context.coordinator.accessibilityActions
        return scrollView
    }

    func updateUIView(_ scrollView: ViewerZoomScrollView, context: Context) {
        context.coordinator.zoomChanged = zoomChanged
        context.coordinator.toggleChrome = toggleChrome
        if context.coordinator.assetID != assetID {
            context.coordinator.assetID = assetID
            scrollView.setZoomScale(1, animated: false)
            zoomChanged(false)
        }
        if context.coordinator.imageView.image !== image {
            context.coordinator.imageView.image = image
        }
        scrollView.setNeedsLayout()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()
        weak var scrollView: UIScrollView?
        var assetID: String?
        var zoomChanged: (Bool) -> Void
        var toggleChrome: () -> Void

        init(
            zoomChanged: @escaping (Bool) -> Void,
            toggleChrome: @escaping () -> Void
        ) {
            self.zoomChanged = zoomChanged
            self.toggleChrome = toggleChrome
        }

        var accessibilityActions: [UIAccessibilityCustomAction] {
            [
                UIAccessibilityCustomAction(name: "Zoom In", target: self, selector: #selector(zoomIn)),
                UIAccessibilityCustomAction(name: "Zoom Out", target: self, selector: #selector(zoomOut)),
                UIAccessibilityCustomAction(name: "Reset Zoom", target: self, selector: #selector(resetZoom)),
            ]
        }

        func viewForZooming(in _: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerImage(in: scrollView)
            zoomChanged(scrollView.zoomScale > scrollView.minimumZoomScale + 0.01)
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
                return
            }

            let targetScale = min(2.5, scrollView.maximumZoomScale)
            let point = recognizer.location(in: imageView)
            let width = scrollView.bounds.width / targetScale
            let height = scrollView.bounds.height / targetScale
            scrollView.zoom(
                to: CGRect(
                    x: point.x - width / 2,
                    y: point.y - height / 2,
                    width: width,
                    height: height
                ),
                animated: true
            )
        }

        @objc func handleSingleTap(_: UITapGestureRecognizer) {
            guard let scrollView,
                  scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01
            else { return }
            toggleChrome()
        }

        @objc private func zoomIn() -> Bool {
            guard let scrollView else { return false }
            scrollView.setZoomScale(min(scrollView.zoomScale * 1.5, scrollView.maximumZoomScale), animated: true)
            return true
        }

        @objc private func zoomOut() -> Bool {
            guard let scrollView else { return false }
            scrollView.setZoomScale(max(scrollView.zoomScale / 1.5, scrollView.minimumZoomScale), animated: true)
            return true
        }

        @objc private func resetZoom() -> Bool {
            guard let scrollView else { return false }
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            return true
        }

        private func centerImage(in scrollView: UIScrollView) {
            let horizontal = max(0, (scrollView.bounds.width - imageView.frame.width) / 2)
            let vertical = max(0, (scrollView.bounds.height - imageView.frame.height) / 2)
            imageView.center = CGPoint(
                x: scrollView.contentSize.width / 2 + horizontal,
                y: scrollView.contentSize.height / 2 + vertical
            )
        }
    }
}

private final class ViewerZoomScrollView: UIScrollView {
    weak var zoomTarget: UIView?

    override func layoutSubviews() {
        let normalizedCenter = contentSize.width > 0 && contentSize.height > 0
            ? CGPoint(
                x: (contentOffset.x + bounds.width / 2) / contentSize.width,
                y: (contentOffset.y + bounds.height / 2) / contentSize.height
            )
            : CGPoint(x: 0.5, y: 0.5)
        let previousSize = zoomTarget?.bounds.size

        super.layoutSubviews()

        guard let zoomTarget, bounds.width > 0, bounds.height > 0 else { return }
        if previousSize != bounds.size {
            zoomTarget.frame = bounds
            contentSize = zoomTarget.frame.size
            if zoomScale > minimumZoomScale + 0.01 {
                contentOffset = CGPoint(
                    x: normalizedCenter.x * contentSize.width - bounds.width / 2,
                    y: normalizedCenter.y * contentSize.height - bounds.height / 2
                )
            }
        }
    }
}
