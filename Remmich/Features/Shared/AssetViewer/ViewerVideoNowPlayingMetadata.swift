import AVFoundation
import UIKit

/// Static presentation metadata; AVKit continues to own timing and remote controls.
nonisolated enum ViewerVideoNowPlayingMetadata {
    static func title(filename: String?, caption: String?) -> String {
        let caption = caption?.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let filename = filename?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = caption ?? (filename?.isEmpty == false ? filename : nil) ?? "Video"
        return "Remmich · \(name.prefix(200))"
    }

    @MainActor static func items(title: String, artwork: Data?) -> [AVMetadataItem] {
        let titleItem = AVMutableMetadataItem()
        titleItem.identifier = .commonIdentifierTitle
        titleItem.value = title as NSString
        titleItem.extendedLanguageTag = "und"
        var items: [AVMetadataItem] = [titleItem]
        if let artwork {
            let artworkItem = AVMutableMetadataItem()
            artworkItem.identifier = .commonIdentifierArtwork
            artworkItem.value = artwork as NSData
            artworkItem.dataType = kCMMetadataBaseDataType_JPEG as String
            artworkItem.extendedLanguageTag = "und"
            items.append(artworkItem)
        }
        return items
    }

    @MainActor static func artwork(from image: UIImage) -> Data? {
        guard image.size.width.isFinite, image.size.height.isFinite,
              image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(1, 512 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.85) { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
