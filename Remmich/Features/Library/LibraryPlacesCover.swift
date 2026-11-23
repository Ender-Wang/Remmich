import MapLibre
import Observation
import UIKit

@MainActor @Observable
final class LibraryPlacesCover {
    private(set) var image: UIImage?
    private(set) var hasGeotags: Bool?
    @ObservationIgnored private var snapshotter: MLNMapSnapshotter?
    @ObservationIgnored private var pending: Request?
    @ObservationIgnored private var rendered: Request?
    @ObservationIgnored private var snapshotID: UUID?

    private struct Request: Equatable {
        let scope: MediaAccountScope
        let coordinates: [PlaceCoordinate]
        let style: URL
        let scale: CGFloat
    }

    func prepare(store: SQLiteLibraryIndexStore, scope: MediaAccountScope, locations: AssetLocationStore, dark: Bool, scale: CGFloat) async {
        guard let coordinates = try? await store.libraryPlacesCoverCoordinates(scope: scope), !Task.isCancelled else { return }
        hasGeotags = !coordinates.isEmpty
        guard !coordinates.isEmpty else {
            stop()
            rendered = nil
            image = nil
            return
        }
        try? await locations.loadMapStyles()
        guard !Task.isCancelled, let styles = locations.mapStyles else { return }
        guard styles.enabled else {
            stop()
            rendered = nil
            image = nil
            return
        }
        let request = Request(scope: scope, coordinates: coordinates, style: dark ? styles.dark : styles.light, scale: scale)
        guard request != pending else { return }
        stop()
        guard request != rendered, let bounds = LibraryPlacesMapBounds.fitting(coordinates, minimumSpan: 0.12, paddingFraction: 0.14) else { return }

        // A zoom-zero world is 512 points tall. Fit it inside the cover's 4:3 viewport.
        let width: CGFloat = 704
        let size = CGSize(width: width, height: width / LibraryCollectionCardMetrics.aspectRatio)
        let camera = MLNMapCamera(lookingAtCenter: CLLocationCoordinate2D(latitude: 0, longitude: 0), altitude: 1, pitch: 0, heading: 0)
        let options = MLNMapSnapshotOptions(styleURL: request.style, camera: camera, size: size)
        options.coordinateBounds = bounds
        options.scale = max(1, LibraryCollectionCardMetrics.maximumWidth * scale / width)
        options.showsLogo = false
        let renderer = MLNMapSnapshotter(options: options)
        let id = UUID()
        snapshotID = id
        snapshotter = renderer
        pending = request
        startRendering(renderer, coordinates: coordinates, size: size, id: id, request: request)
    }

    private func startRendering(_ renderer: MLNMapSnapshotter, coordinates: [PlaceCoordinate], size: CGSize, id: UUID, request: Request) {
        renderer.start(overlayHandler: { @Sendable overlay in
            Self.drawHeatmap(coordinates, on: overlay, size: size)
        }, completionHandler: { [weak self] snapshot, _ in
            // MapLibre delivers completion on the main queue. Keep its snapshot in the callback.
            let image = snapshot?.image
            MainActor.assumeIsolated {
                guard let self, self.snapshotID == id else { return }
                self.snapshotter = nil
                self.snapshotID = nil
                self.pending = nil
                if let image {
                    self.rendered = request
                    self.image = image
                }
            }
        })
    }

    func stop() {
        snapshotID = nil
        pending = nil
        snapshotter?.cancel()
        snapshotter = nil
    }

    private nonisolated static func drawHeatmap(_ coordinates: [PlaceCoordinate], on overlay: MLNMapSnapshotOverlay, size: CGSize) {
        let context = overlay.context
        let coverToMapScale = size.width / LibraryCollectionCardMetrics.maximumWidth
        let coverSize = CGSize(width: size.width / coverToMapScale, height: size.height / coverToMapScale)
        let bounds = CGRect(origin: .zero, size: coverSize).insetBy(dx: -18, dy: -18)
        let cell: CGFloat = 8
        let columns = Int(ceil(coverSize.width / cell)) + 6
        var counts: [Int: Int] = [:]
        for coordinate in coordinates {
            let mapped = overlay.point(for: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude))
            let point = CGPoint(x: mapped.x / coverToMapScale, y: mapped.y / coverToMapScale)
            guard bounds.contains(point) else { continue }
            let x = Int(floor(point.x / cell)) + 3
            let y = Int(floor(point.y / cell)) + 3
            counts[y * columns + x, default: 0] += 1
        }
        context.saveGState()
        defer { context.restoreGState() }
        context.scaleBy(x: coverToMapScale, y: coverToMapScale)
        let maximum = Double(counts.values.max() ?? 1)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        for (key, count) in counts.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }) {
            let point = CGPoint(x: (CGFloat(key % columns - 3) + 0.5) * cell, y: (CGFloat(key / columns - 3) + 0.5) * cell)
            let strength = log1p(Double(count)) / log1p(maximum)
            let colors = [CGColor(red: 1, green: 0.7 - 0.52 * strength, blue: 0.13, alpha: 0.35 + 0.4 * strength),
                          CGColor(red: 1, green: 0.56, blue: 0.04, alpha: 0.22),
                          CGColor(red: 1, green: 0.56, blue: 0.04, alpha: 0)]
            guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: [0, 0.55, 1]) else { continue }
            context.drawRadialGradient(gradient, startCenter: point, startRadius: 0, endCenter: point,
                                       endRadius: 12 + 9 * strength, options: [])
        }
    }
}
