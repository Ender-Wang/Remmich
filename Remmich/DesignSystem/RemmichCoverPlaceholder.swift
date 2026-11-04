import SwiftUI
import UIKit

/// Static, transparent artwork shared by native pinch tiles and hosted cards.
/// Cache the three icon variants instead of running a logo animation per card.
@MainActor
enum RemmichCoverPlaceholder {
    struct Caption {
        let title: String
        let count: Int
        let isFeatured: Bool
    }

    static let opacity = 0.55
    static let fadeDuration = 0.18
    private static let maximumSide: CGFloat = 64
    private static var images: [RemmichAppIcon: UIImage] = [:]

    static func side(in size: CGSize) -> CGFloat {
        min(maximumSide, max(0, min(size.width, size.height) * 0.5))
    }

    static func frame(in size: CGSize, caption: Caption?, traits: UITraitCollection) -> CGRect {
        var available = size
        if let caption {
            let padding: CGFloat = caption.isFeatured ? 16 : 8
            let width = max(1, size.width - padding * 2)
            let titleSize = UIFont.preferredFont(forTextStyle: caption.isFeatured ? .title3 : .caption1,
                                                 compatibleWith: traits).pointSize
            let titleFont = UIFont.systemFont(ofSize: titleSize, weight: .semibold)
            let countFont = UIFont.preferredFont(forTextStyle: caption.isFeatured ? .subheadline : .caption2,
                                                 compatibleWith: traits)
            let titleHeight = min(titleFont.lineHeight * 2, (caption.title as NSString).boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin,
                attributes: [.font: titleFont], context: nil
            ).height)
            let countHeight = ("\(caption.count.formatted()) items" as NSString).boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin,
                attributes: [.font: countFont], context: nil
            ).height
            available.height = max(0, size.height - ceil(titleHeight) - ceil(countHeight) - 2 - padding * 2)
        }
        let side = side(in: available)
        return CGRect(x: (size.width - side) / 2, y: (available.height - side) / 2, width: side, height: side)
    }

    static func image(for icon: RemmichAppIcon) -> UIImage? {
        if let image = images[icon] {
            return image
        }
        guard let artwork = RemmichBrandArtwork.load(icon) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: maximumSide, height: maximumSide), format: format)
        let image = renderer.image { context in
            context.cgContext.scaleBy(x: maximumSide / 1024, y: maximumSide / 1024)
            for tile in artwork.tiles {
                for layer in tile.layers {
                    UIImage(named: layer.image)?.draw(in: tile.frame, blendMode: layer.multiply ? .multiply : .normal, alpha: 1)
                }
            }
        }
        images[icon] = image
        return image
    }
}

final class RemmichCoverPlaceholderView: UIView {
    let logoView = UIImageView()
    var sourceCaption: RemmichCoverPlaceholder.Caption?
    var caption: RemmichCoverPlaceholder.Caption?
    var progress: CGFloat = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        logoView.contentMode = .scaleAspectFit
        logoView.alpha = RemmichCoverPlaceholder.opacity
        logoView.accessibilityIdentifier = "semantic-cover-loading-logo"
        addSubview(logoView)
        updateImage()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateImage() {
        logoView.image = RemmichCoverPlaceholder.image(for: AppIconController.shared.selectedIcon ?? .spiral)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let start = RemmichCoverPlaceholder.frame(in: bounds.size, caption: sourceCaption, traits: traitCollection)
        let end = RemmichCoverPlaceholder.frame(in: bounds.size, caption: caption, traits: traitCollection)
        logoView.frame = CGRect(x: start.minX + (end.minX - start.minX) * progress,
                                y: start.minY + (end.minY - start.minY) * progress,
                                width: start.width + (end.width - start.width) * progress,
                                height: start.height + (end.height - start.height) * progress)
    }
}

struct RemmichCoverLoadingView: UIViewRepresentable {
    let caption: RemmichCoverPlaceholder.Caption

    func makeUIView(context _: Context) -> RemmichCoverPlaceholderView {
        RemmichCoverPlaceholderView(frame: .zero)
    }

    func updateUIView(_ view: RemmichCoverPlaceholderView, context _: Context) {
        view.caption = caption
        view.updateImage()
        view.setNeedsLayout()
    }
}
