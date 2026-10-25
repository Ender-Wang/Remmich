import Foundation
import UIKit

/// Local image data for deterministic UI automation; never used by a normal signed-in session.
@MainActor
enum PreviewMediaFixtures {
    private static var images: [String: Data] = [:]
    private static var videoURL: URL?

    static func data(
        for id: String,
        derivative: MediaDerivative = .thumbnail
    ) -> Data {
        let cacheKey = "\(id)|\(derivative.rawValue)"
        if let data = images[cacheKey] {
            return data
        }
        let index = Int(id.split(separator: "-").last ?? "0") ?? 0
        let shortEdge: CGFloat = switch derivative {
        case .thumbnail:
            200
        case .preview, .videoPlayback:
            300
        case .fullSize:
            600
        case .original:
            800
        }
        let size = index.isMultiple(of: 2)
            ? CGSize(width: shortEdge * 2, height: shortEdge)
            : CGSize(width: shortEdge, height: shortEdge * 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let data = UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor(hue: CGFloat(index % 8) / 8, saturation: 0.7, brightness: 0.8, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            context.fill(CGRect(x: size.width / 2 - 20, y: size.height / 2 - 20, width: 40, height: 40))
            UIColor.black.setStroke()
            context.cgContext.stroke(CGRect(x: size.width / 2 - 30, y: size.height / 2 - 30, width: 60, height: 60))
        }
        images[cacheKey] = data
        return data
    }

    static func videoFileURL() throws -> URL {
        if let videoURL {
            return videoURL
        }
        let encoded = "AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAMMbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAAPoAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAjd0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAAPoAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAABAAAAAQAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAD6AAAAAAABAAAAAAGvbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAABAAAAAEABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABWm1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAARpzdGJsAAAAtnN0c2QAAAAAAAAAAQAAAKZhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAABAAEABIAAAASAAAAAAAAAABFExhdmM2My4xLjEwMiBsaWJ4MjY0AAAAAAAAAAAAAAAAGP//AAAALGF2Y0MBQsAK/+EAFWdCwAraewEQAAADABAAAAMAgPEiagEABGjOD8gAAAAQcGFzcAAAAAEAAAABAAAAFGJ0cnQAAAAAAABMoAAAAAAAAAAYc3R0cwAAAAAAAAABAAAAAQAAEAAAAAAcc3RzYwAAAAAAAAABAAAAAQAAAAEAAAABAAAAFHN0c3oAAAAAAAACZQAAAAEAAAAUc3RjbwAAAAAAAAABAAADPAAAAGF1ZHRhAAAAWW1ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAG1kaXJhcHBsAAAAAAAAAAAAAAAALGlsc3QAAAAkqXRvbwAAABxkYXRhAAAAAQAAAABMYXZmNjMuMS4xMDIAAAAIZnJlZQAAAm1tZGF0AAACUwYF//9P3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NSByMzIyMiBiMzU2MDVhIC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4ub3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTAgcmVmPTEgZGVibG9jaz0wOjA6MCBhbmFseXNlPTA6MCBtZT1kaWEgc3VibWU9MCBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0wIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MCA4eDhkY3Q9MCBjcW09MCBkZWFkem9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3FwX29mZnNldD0wIHRocmVhZHM9MSBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTAgd2VpZ2h0cD0wIGtleWludD0yNTAga2V5aW50X21pbj00IHNjZW5lY3V0PTAgaW50cmFfcmVmcmVzaD0wIHJjPWNyZiBtYnRyZWU9MCBjcmY9MjMuMCBxY29tcD0wLjYwIHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBhcT0wAIAAAAAKZYiEOiYoAAkC4A=="
        guard let data = Data(base64Encoded: encoded) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "RemmichUITestFixtures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "video.mp4")
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
        }
        videoURL = url
        return url
    }
}
