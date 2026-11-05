import AVFoundation
import AVKit
import Testing
import UIKit
@testable import Remmich

struct ViewerVideoNowPlayingMetadataTests {
    @Test func titleUsesCaptionThenFilenameWithoutExposingAssetIDs() {
        #expect(ViewerVideoNowPlayingMetadata.title(filename: "IMG_1234.MOV", caption: "\n  Lake sunset  \nMore detail") == "Remmich · Lake sunset")
        #expect(ViewerVideoNowPlayingMetadata.title(filename: "  IMG_1234.MOV  ", caption: " \n ") == "Remmich · IMG_1234.MOV")
        #expect(ViewerVideoNowPlayingMetadata.title(filename: nil, caption: nil) == "Remmich · Video")
        #expect(ViewerVideoNowPlayingMetadata.title(filename: " ", caption: " ") == "Remmich · Video")
    }

    @Test @MainActor func metadataUsesNativeTitleAndTypedArtwork() throws {
        let data = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let items = ViewerVideoNowPlayingMetadata.items(title: "Remmich · IMG_1234.MOV", artwork: data)
        let title = try #require(items.first { $0.identifier == .commonIdentifierTitle })
        let artwork = try #require(items.first { $0.identifier == .commonIdentifierArtwork })
        #expect(title.stringValue == "Remmich · IMG_1234.MOV")
        #expect(title.extendedLanguageTag == "und")
        #expect(artwork.dataValue == data)
        #expect(artwork.dataType == kCMMetadataBaseDataType_JPEG as String)
        #expect(ViewerVideoNowPlayingMetadata.items(title: "Remmich · Video", artwork: nil).count == 1)
    }

    @Test @MainActor func artworkIsBoundedAndPreservesThePosterAspectRatio() throws {
        let image = poster(size: CGSize(width: 1200, height: 600))
        let data = try #require(ViewerVideoNowPlayingMetadata.artwork(from: image))
        let decoded = try #require(UIImage(data: data)?.cgImage)
        #expect(decoded.width == 512)
        #expect(decoded.height == 256)
        #expect(ViewerVideoNowPlayingMetadata.artwork(from: UIImage()) == nil)
    }

    @Test @MainActor func presentationUpdatesRetainPlayerItemArtworkAndPausedIntent() throws {
        let session = VideoPlaybackSession(assetID: "video")
        let player = session.player
        let item = AVPlayerItem(asset: AVMutableComposition())
        player.replaceCurrentItem(with: item)
        defer { session.close() }
        let image = poster(size: CGSize(width: 100, height: 60))

        // Shared preview sessions have no opt-in metadata, even with artwork.
        session.updateNowPlayingArtwork(image)
        #expect(item.externalMetadata.isEmpty)
        session.updateNowPlayingTitle(filename: "IMG_1234.MOV", caption: nil)
        session.updateNowPlayingArtwork(image)
        let artwork = try #require(item.externalMetadata.first { $0.identifier == .commonIdentifierArtwork }?.dataValue)
        session.pause()
        session.updateNowPlayingTitle(filename: "IMG_1234.MOV", caption: "Lake sunset")
        session.updateNowPlayingArtwork(poster(size: CGSize(width: 20, height: 20)), onlyIfMissing: true)

        #expect(session.player === player)
        #expect(player.currentItem === item)
        #expect(!session.isPlaybackIntended)
        #expect(item.externalMetadata.first { $0.identifier == .commonIdentifierTitle }?.stringValue == "Remmich · Lake sunset")
        #expect(item.externalMetadata.first { $0.identifier == .commonIdentifierArtwork }?.dataValue == artwork)

        session.close()
        session.updateNowPlayingTitle(filename: "Late response.mov", caption: nil)
        session.updateNowPlayingArtwork(image)
        #expect(player.currentItem == nil)
        #expect(item.externalMetadata.first { $0.identifier == .commonIdentifierTitle }?.stringValue == "Remmich · Lake sunset")
    }

    @MainActor private func poster(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}
