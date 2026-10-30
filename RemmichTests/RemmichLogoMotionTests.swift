import CoreGraphics
import Foundation
import Testing
@testable import Remmich

struct RemmichLogoMotionTests {
    @Test func generatedArtworkPreservesAllThreeFiveCardCompositions() throws {
        #if SWIFT_PACKAGE
            let bundle = Bundle.module
        #else
            let bundle = Bundle.main
        #endif
        let url = try #require(bundle.url(forResource: "RemmichBrandArtwork", withExtension: "json"))
        let scenes = try JSONDecoder().decode([String: RemmichBrandArtwork].self, from: Data(contentsOf: url))
        #expect(Set(scenes.keys) == Set(RemmichAppIcon.allCases.map(\.rawValue)))
        for artwork in scenes.values {
            #expect(artwork.tiles.count == 5)
            #expect(Set(artwork.tiles.map(\.id)) == ["red", "amber", "green", "blue", "pink"])
            for tile in artwork.tiles {
                #expect(tile.bounds.count == 4 && tile.anchor.count == 2)
                #expect(tile.frame.width > tile.width * 0.5 && tile.frame.height > tile.height * 0.5)
                #expect(tile.layers.count == 3)
                #expect(tile.layers.filter(\.multiply).count == 1)
            }
        }
        let mosaic = try #require(scenes["Mosaic"])
        #expect(mosaic.tiles[0].width == 428 && mosaic.tiles[0].height == 428)
        #expect(mosaic.tiles[2].width == 200 && mosaic.tiles[2].height == 428)
    }

    @Test func breatheKeepsEachInwardAnchorFixedWhileEnlargingTheCard() {
        let artwork = Self.mosaic
        for index in artwork.tiles.indices {
            let tile = artwork.tiles[index]
            let point = CGPoint(x: tile.anchor[0], y: tile.anchor[1])
            let transform = RemmichLogoMotion.transform(icon: .spaced, artwork: artwork,
                                                        tile: index, elapsed: 1.6, shuffle: [])
            let transformed = point.applying(transform)
            #expect(abs(transformed.x - point.x) < 0.000001)
            #expect(abs(transformed.y - point.y) < 0.000001)
            #expect(abs(transform.a - 1.2) < 0.000001)
            #expect(transform.b == 0 && transform.c == 0)
        }
    }

    @Test func mosaicMovesAtConstantSpeedThenHoldsACompleteArrangement() {
        let timeline = MosaicShuffleTimeline(artwork: Self.mosaic)
        var offset = 0.0
        for step in timeline.steps {
            for index in step.start.indices {
                let start = step.start[index], end = step.end[index]
                let distance = hypot(end.x - start.x, end.y - start.y)
                guard distance > 0 else { continue }
                let travel = distance / MosaicShuffleTimeline.speed
                let delay = step.travel - travel
                let first = timeline.positions(at: offset + delay + travel * 0.25)[index]
                let second = timeline.positions(at: offset + delay + travel * 0.75)[index]
                let measured = hypot(second.x - first.x, second.y - first.y) / (travel * 0.5)
                #expect(abs(measured - 100) < 0.000001)
            }
            let settled = timeline.positions(at: offset + step.travel + 0.1)
            let resting = timeline.positions(at: offset + step.travel + 0.6)
            #expect(settled == step.end)
            #expect(resting == step.end)
            offset += step.travel + MosaicShuffleTimeline.settle
        }
        #expect(timeline.positions(at: 0) == timeline.positions(at: timeline.duration))
    }

    @Test func mosaicTransformsOnlyTranslateAndKeepTheOriginalSizes() {
        let artwork = Self.mosaic
        let timeline = MosaicShuffleTimeline(artwork: artwork)
        let positions = timeline.positions(at: 2)
        for index in artwork.tiles.indices {
            let transform = RemmichLogoMotion.transform(icon: .mosaic, artwork: artwork,
                                                        tile: index, elapsed: 2, shuffle: positions)
            #expect(transform.a == 1 && transform.d == 1 && transform.b == 0 && transform.c == 0)
        }
        #expect(artwork.tiles[0].width == 428 && artwork.tiles[0].height == 428)
        #expect(artwork.tiles[2].width == 200 && artwork.tiles[2].height == 428)
    }

    private static var mosaic: RemmichBrandArtwork {
        let sizes: [(String, Double, Double, Double, Double)] = [
            ("red", 428, 428, 398, 398), ("amber", 200, 200, 740, 284),
            ("green", 200, 428, 740, 626), ("pink", 200, 200, 284, 740),
            ("blue", 200, 200, 512, 740),
        ]
        return RemmichBrandArtwork(transform: [1, 0, 0, 1, 0, 0], tiles: sizes.map { id, width, height, x, y in
            .init(id: id, bounds: [x - width / 2, y - height / 2, width, height],
                  anchor: [x, y], width: width, height: height, center: [x, y], layers: [])
        })
    }
}
