import SwiftUI
import Testing
import UIKit
@testable import Remmich

@Suite("Video opening background", .serialized)
@MainActor
struct VideoOpeningBackgroundTests {
    @Test func portraitPlayerStageIsBlackBeforeAVKitMounts() throws {
        let size = CGSize(width: 240, height: 400)
        let image = try render(size: size, videoRect: CGRect(x: 20, y: 100, width: 200, height: 200))

        let player = try pixel(in: image, x: 120, y: 200)
        let page = try pixel(in: image, x: 10, y: 10)
        #expect(player.red < 5 && player.green < 5 && player.blue < 5, "Player RGB: \(player)")
        #expect(page.red > 250 && page.green > 250 && page.blue > 250)
    }

    @Test func landscapePlayerFillsItsAreaAndLeavesInfoThemed() throws {
        let size = CGSize(width: 400, height: 240)
        let image = try render(size: size, videoRect: CGRect(x: 0, y: 0, width: 180, height: 240))

        let player = try pixel(in: image, x: 80, y: 120)
        let info = try pixel(in: image, x: 300, y: 120)
        #expect(player.red < 5 && player.green < 5 && player.blue < 5)
        #expect(info.red > 250 && info.green > 250 && info.blue > 250)
    }

    @Test func photoPageKeepsItsThemeBackground() throws {
        let image = try render(size: CGSize(width: 240, height: 400), videoRect: nil)
        let page = try pixel(in: image, x: 120, y: 200)
        #expect(page.red > 250 && page.green > 250 && page.blue > 250)
    }

    @Test func openingFadeCompositesTheBlackStageWithTheThemedPage() throws {
        let image = try render(size: CGSize(width: 240, height: 400),
                               videoRect: CGRect(x: 20, y: 100, width: 200, height: 200), opacity: 0.5)
        let player = try pixel(in: image, x: 120, y: 200)
        let page = try pixel(in: image, x: 10, y: 10)
        // The green source page must blend with black inside the video stage,
        // while the surrounding themed white backdrop blends independently.
        #expect(player.red < 5 && player.blue < 5)
        #expect(player.green > 80 && player.green < 220)
        #expect(page.red > 80 && page.blue > 80)
    }

    private func render(size: CGSize, videoRect: CGRect?, opacity: Double = 1) throws -> CGImage {
        let renderer = ImageRenderer(content: AssetViewerBackdrop(videoRect: videoRect)
            .frame(width: size.width, height: size.height)
            .opacity(opacity)
            .background(Color(red: 0, green: 1, blue: 0))
            .environment(\.colorScheme, .light))
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(size)
        return try #require(renderer.uiImage?.cgImage)
    }

    private func pixel(in image: CGImage, x: Int, y: Int) throws -> RGB {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(
            data: &bytes, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let index = (y * image.width + x) * 4
        return RGB(red: bytes[index], green: bytes[index + 1], blue: bytes[index + 2])
    }

    private struct RGB: CustomStringConvertible {
        let red: UInt8
        let green: UInt8
        let blue: UInt8

        var description: String {
            "\(red),\(green),\(blue)"
        }
    }
}
