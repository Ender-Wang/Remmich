import SwiftUI
import UIKit

/// Read geometry at the transition boundary. Weak UIKit probes avoid publishing
/// every cell frame through SwiftUI while a scoped grid scrolls or lays out.
@MainActor
final class ScopedAssetTransitionRuntime {
    private nonisolated struct Key: Hashable {
        let scope: PhotosRangeRoute
        let assetID: String
    }

    private struct Source {
        weak var view: UIView?
        let aspectRatio: Double
        let naturalAspectProgress: CGFloat
        let revision: Int
    }

    private var sources: [Key: [ObjectIdentifier: Source]] = [:]
    private var sourceKeys: [ObjectIdentifier: Key] = [:]
    private final class ImageReference {
        weak var image: UIImage?
        let revision: Date

        init(image: UIImage, revision: Date) {
            self.image = image
            self.revision = revision
        }
    }

    private var images: [Key: ImageReference] = [:]
    private var revision = 0

    func register(_ view: UIView, scope: PhotosRangeRoute, assetID: String,
                  aspectRatio: Double, naturalAspectProgress: CGFloat)
    {
        let identity = ObjectIdentifier(view)
        let key = Key(scope: scope, assetID: assetID)
        if sourceKeys[identity] != key {
            unregister(view)
        }
        revision &+= 1
        sourceKeys[identity] = key
        sources[key, default: [:]][identity] = Source(
            view: view, aspectRatio: aspectRatio,
            naturalAspectProgress: naturalAspectProgress, revision: revision
        )
    }

    func unregister(_ view: UIView) {
        let identity = ObjectIdentifier(view)
        guard let key = sourceKeys.removeValue(forKey: identity) else { return }
        sources[key]?.removeValue(forKey: identity)
        if sources[key]?.isEmpty == true {
            sources.removeValue(forKey: key)
            images.removeValue(forKey: key)
        }
    }

    func imageLoaded(_ image: UIImage, asset: TimelineAssetSummary, scope: PhotosRangeRoute) {
        images[Key(scope: scope, assetID: asset.id)] = ImageReference(image: image, revision: asset.thumbnailRevision)
    }

    func transitionImage(for asset: TimelineAssetSummary, scope: PhotosRangeRoute) -> UIImage? {
        guard target(assetID: asset.id, scope: scope) != nil,
              let entry = images[Key(scope: scope, assetID: asset.id)], entry.revision == asset.thumbnailRevision
        else { return nil }
        return entry.image
    }

    func target(assetID: String, scope: PhotosRangeRoute) -> AssetViewerDismissalTarget? {
        let candidates = sources[Key(scope: scope, assetID: assetID), default: [:]].values.sorted {
            $0.revision > $1.revision
        }
        for source in candidates {
            guard let view = source.view, let window = view.window,
                  !window.isHidden, view.bounds.width > 0, view.bounds.height > 0
            else { continue }
            let progress = min(1, max(0, source.naturalAspectProgress))
            let image = TimelineThumbnailGeometry.renderedImageRect(
                in: view.bounds.size, aspectRatio: source.aspectRatio, naturalAspectProgress: progress
            ).offsetBy(dx: view.bounds.minX, dy: view.bounds.minY)
            let frame = view.convert(image, to: nil)
            var visible = frame.intersection(window.convert(window.bounds, to: nil))
            var ancestor: UIView? = view
            while let current = ancestor {
                if current.isHidden {
                    visible = .null; break
                }
                if current.clipsToBounds {
                    visible = visible.intersection(current.convert(current.bounds, to: nil))
                }
                ancestor = current.superview
            }
            guard !visible.isNull, !visible.isEmpty else { continue }
            // Opacity is deliberately not a visibility test: the source is
            // hidden while the returning image lands on that exact geometry.
            return AssetViewerDismissalTarget(
                imageFrame: frame, cornerRadius: DesignMetrics.compactCornerRadius * progress,
                fillsFrame: progress < 0.5
            )
        }
        return nil
    }
}

nonisolated struct ScopedAssetTransitionContext: Sendable {
    let runtime: ScopedAssetTransitionRuntime
    let scope: PhotosRangeRoute
}

extension EnvironmentValues {
    @Entry var scopedAssetTransitionContext: ScopedAssetTransitionContext?
}

struct ScopedAssetTransitionProbe: UIViewRepresentable {
    let context: ScopedAssetTransitionContext
    let assetID: String
    let aspectRatio: Double
    let naturalAspectProgress: CGFloat

    func makeUIView(context _: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        register(view)
        return view
    }

    func updateUIView(_ view: UIView, context _: Context) {
        register(view)
    }

    func makeCoordinator() -> ScopedAssetTransitionRuntime {
        context.runtime
    }

    static func dismantleUIView(_ view: UIView, coordinator: ScopedAssetTransitionRuntime) {
        coordinator.unregister(view)
    }

    private func register(_ view: UIView) {
        context.runtime.register(view, scope: context.scope, assetID: assetID,
                                 aspectRatio: aspectRatio, naturalAspectProgress: naturalAspectProgress)
    }
}
