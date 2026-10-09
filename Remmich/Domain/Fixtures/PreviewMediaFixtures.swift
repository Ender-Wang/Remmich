import Foundation
import UIKit

/// Local image data for deterministic UI automation; never used by a normal signed-in session.
@MainActor
enum PreviewMediaFixtures {
    private static var images: [String: Data] = [:]

    static func data(for id: String) -> Data {
        if let data = images[id] {
            return data
        }
        let index = Int(id.split(separator: "-").last ?? "0") ?? 0
        let size = index.isMultiple(of: 2) ? CGSize(width: 400, height: 200) : CGSize(width: 200, height: 400)
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
        images[id] = data
        return data
    }
}
