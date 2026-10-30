import CoreGraphics
import Foundation

nonisolated struct RemmichBrandArtwork: Decodable, Sendable {
    struct Layer: Decodable, Sendable {
        let image: String
        let multiply: Bool
    }

    struct Tile: Decodable, Sendable {
        let id: String
        let bounds: [Double]
        let anchor: [Double]
        let width: Double
        let height: Double
        let center: [Double]
        let layers: [Layer]

        var frame: CGRect {
            CGRect(x: bounds[0], y: bounds[1], width: bounds[2], height: bounds[3])
        }
    }

    let transform: [Double]
    let tiles: [Tile]

    private static let catalog: [String: Self] = {
        guard let url = Bundle.main.url(forResource: "RemmichBrandArtwork", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let artwork = try? JSONDecoder().decode([String: Self].self, from: data)
        else { return [:] }
        return artwork
    }()

    static func load(_ icon: RemmichAppIcon) -> Self? {
        catalog[icon.rawValue]
    }

    func translation(x: Double, y: Double) -> CGAffineTransform {
        CGAffineTransform(translationX: transform[0] * x + transform[2] * y,
                          y: transform[1] * x + transform[3] * y)
    }
}

nonisolated struct MosaicShuffleTimeline {
    struct Step {
        let start: [CGPoint]
        let end: [CGPoint]
        let travel: TimeInterval
    }

    static let speed = 100.0
    static let settle = 0.650
    let steps: [Step]
    let duration: TimeInterval

    init(artwork: RemmichBrandArtwork) {
        let smalls = artwork.tiles.indices.filter { artwork.tiles[$0].width == 200 && artwork.tiles[$0].height == 200 }
        let corners = [(0, 0, 2, 1), (0, 1, 2, 0), (1, 1, 0, 0), (1, 0, 0, 1)]
        let positions: [[CGPoint]] = (0 ... 12).map { step in
            let (largeX, largeY, verticalX, verticalY) = corners[step % 4]
            let slots = (0 ..< 3).flatMap { row in
                (0 ..< 3).compactMap { column -> CGPoint? in
                    let occupied = (column >= largeX && column < largeX + 2 && row >= largeY && row < largeY + 2)
                        || (column == verticalX && row >= verticalY && row < verticalY + 2)
                    return occupied ? nil : CGPoint(x: 284 + column * 228, y: 284 + row * 228)
                }
            }
            return artwork.tiles.indices.map { index in
                let tile = artwork.tiles[index]
                let target: CGPoint = if let small = smalls.firstIndex(of: index) {
                    slots[(small + step) % 3]
                } else if tile.id == "red" {
                    CGPoint(x: 398 + largeX * 228, y: 398 + largeY * 228)
                } else {
                    CGPoint(x: 284 + verticalX * 228, y: 398 + verticalY * 228)
                }
                return CGPoint(x: target.x - tile.center[0], y: target.y - tile.center[1])
            }
        }
        steps = (1 ... 12).map { index in
            let start = positions[index - 1], end = positions[index]
            let distance = zip(start, end).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 0
            return Step(start: start, end: end, travel: distance / Self.speed)
        }
        duration = steps.reduce(0) { $0 + $1.travel + Self.settle }
    }

    func positions(at elapsed: TimeInterval) -> [CGPoint] {
        guard duration > 0 else { return [] }
        var time = max(0, elapsed).truncatingRemainder(dividingBy: duration)
        for step in steps {
            if time < step.travel + Self.settle {
                return zip(step.start, step.end).map { start, end in
                    let travel = hypot(end.x - start.x, end.y - start.y) / Self.speed
                    let progress = travel == 0 ? 1 : min(1, max(0, (time - (step.travel - travel)) / travel))
                    return CGPoint(x: start.x + (end.x - start.x) * progress, y: start.y + (end.y - start.y) * progress)
                }
            }
            time -= step.travel + Self.settle
        }
        return steps.last?.end ?? []
    }
}

nonisolated enum RemmichLogoMotion {
    static func transform(icon: RemmichAppIcon, artwork: RemmichBrandArtwork, tile: Int,
                          elapsed: TimeInterval, shuffle: [CGPoint]) -> CGAffineTransform
    {
        switch icon {
        case .spiral:
            let phase = max(0, elapsed - Double(tile) * 0.110).truncatingRemainder(dividingBy: 3.2) / 3.2
            let amount = phase < 0.28 ? 1 - smooth(phase / 0.28) : phase < 0.83 ? 0 : smooth((phase - 0.83) / 0.17)
            let angle = Double(tile) * 72 * .pi / 180
            return artwork.translation(x: sin(angle) * 46 * amount, y: -cos(angle) * 46 * amount)
        case .spaced:
            let anchor = artwork.tiles[tile].anchor
            let scale = 1 + 0.2 * (0.5 - 0.5 * cos(elapsed * 2 * .pi / 3.2))
            return CGAffineTransform(translationX: anchor[0], y: anchor[1])
                .scaledBy(x: scale, y: scale).translatedBy(x: -anchor[0], y: -anchor[1])
        case .mosaic:
            guard shuffle.indices.contains(tile) else { return .identity }
            return artwork.translation(x: shuffle[tile].x, y: shuffle[tile].y)
        }
    }

    private static func smooth(_ value: Double) -> Double {
        0.5 - 0.5 * cos(value * .pi)
    }
}
