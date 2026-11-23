import CoreLocation
import MapLibre
import SwiftUI

struct LibraryPlacesMapSource {
    let store: SQLiteLibraryIndexStore
    let scope: MediaAccountScope
    let index: LibraryIndexController

    struct Revision: Equatable {
        let scope: MediaAccountScope
        let indexDate: Date?
        let metadataDate: Date?
    }

    var revision: Revision {
        .init(scope: scope, indexDate: index.lastUpdatedAt, metadataDate: index.thumbnailWarmingLastUpdatedAt)
    }
}

struct LibraryPlacesMap: View {
    @Environment(\.assetLocations) private var locations
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let source: LibraryPlacesMapSource?
    let place: TimelinePlace?
    @State private var snapshot: LibraryPlacesMapSnapshot?
    @State private var failed = false

    private var styleURL: URL? {
        guard let styles = locations?.mapStyles, styles.enabled else { return nil }
        return colorScheme == .dark ? styles.dark : styles.light
    }

    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            if let styleURL {
                NativeLibraryPlacesMap(styleURL: styleURL, snapshot: snapshot, place: place, animated: !reduceMotion,
                                       didLoadStyle: { failed = false }, didFail: { failed = true })
            }
            if failed || locations?.mapStyles?.enabled == false {
                Text("Map Unavailable")
                    .font(.caption)
                    .padding(8)
                    .background(.regularMaterial, in: .capsule)
                    .allowsHitTesting(false)
            } else if styleURL == nil {
                ProgressView().accessibilityLabel("Loading map")
                    .allowsHitTesting(false)
            } else if let snapshot, let place, snapshot.coordinates[place]?.isEmpty != false {
                Text("No cached locations for this place")
                    .font(.caption)
                    .padding(8)
                    .background(.regularMaterial, in: .capsule)
                    .allowsHitTesting(false)
            }
        }
        .clipped()
        .task(id: source?.revision) {
            guard let source, let coordinates = try? await source.store.libraryPlacesMapCoordinates(scope: source.scope),
                  !Task.isCancelled else { return }
            snapshot = .init(coordinates: coordinates)
        }
        .task(id: locations?.mapEndpoint) {
            do {
                try await locations?.loadMapStyles()
            } catch {
                if !Task.isCancelled, styleURL == nil {
                    failed = true
                }
            }
        }
        .onChange(of: styleURL) { failed = false }
        .accessibilityIdentifier("library-places-heatmap")
    }
}

private struct LibraryPlacesMapSnapshot {
    let id = UUID()
    let coordinates: [TimelinePlace?: [PlaceCoordinate]]
}

private struct NativeLibraryPlacesMap: UIViewRepresentable {
    let styleURL: URL
    let snapshot: LibraryPlacesMapSnapshot?
    let place: TimelinePlace?
    let animated: Bool
    let didLoadStyle: () -> Void
    let didFail: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MLNMapView {
        let view = MLNMapView(frame: .zero, styleURL: styleURL)
        view.delegate = context.coordinator
        view.automaticallyAdjustsContentInset = false
        view.isScrollEnabled = true
        view.isZoomEnabled = true
        view.isPitchEnabled = false
        view.isRotateEnabled = false
        view.accessibilityLabel = "Places heatmap"
        context.coordinator.update(view, value: self)
        return view
    }

    func updateUIView(_ view: MLNMapView, context: Context) {
        context.coordinator.update(view, value: self)
    }

    static func dismantleUIView(_ view: MLNMapView, coordinator _: Coordinator) {
        view.delegate = nil
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        private var value: NativeLibraryPlacesMap?
        private var source: MLNShapeSource?
        private var overviewHeat: MLNHeatmapStyleLayer?
        private var placeHeat: MLNHeatmapStyleLayer?
        private var installedSnapshotID: UUID?
        private var positioned = false
        private var displayedPlace: TimelinePlace?
        private var displayedPlaceHasCoordinates = false
        private var overviewCamera: MLNMapCamera?
        private var cameraGeneration = 0

        func update(_ view: MLNMapView, value: NativeLibraryPlacesMap) {
            self.value = value
            if view.styleURL != value.styleURL {
                source = nil
                view.styleURL = value.styleURL
            }
            updateContent(in: view)
        }

        func mapView(_ view: MLNMapView, didFinishLoading style: MLNStyle) {
            let source = MLNShapeSource(identifier: "remmich-places", shape: nil, options: nil)
            let overview = Self.heatmap("remmich-places-overview", source: source, radiusStops: [0, 8, 22, 52])
            let detail = Self.heatmap("remmich-places-detail", source: source, radiusStops: [0, 2, 4, 4, 8, 7, 12, 12, 16, 18])
            detail.heatmapOpacity = NSExpression(forConstantValue: 0)
            style.addSource(source)
            for layer in [overview, detail] {
                if let labels = style.layers.first(where: { $0 is MLNSymbolStyleLayer }) {
                    style.insertLayer(layer, below: labels)
                } else {
                    style.addLayer(layer)
                }
            }
            self.source = source
            overviewHeat = overview
            placeHeat = detail
            installedSnapshotID = nil
            updateContent(in: view, forceLayers: true)
            Task { @MainActor [weak self] in self?.value?.didLoadStyle() }
        }

        func mapViewDidFinishRenderingMap(_ view: MLNMapView, fullyRendered _: Bool) {
            updateContent(in: view)
        }

        func mapViewDidFailLoadingMap(_: MLNMapView, withError _: Error) {
            Task { @MainActor [weak self] in self?.value?.didFail() }
        }

        private func updateContent(in view: MLNMapView, forceLayers: Bool = false) {
            guard let value, let snapshot = value.snapshot, let source, view.bounds.width > 1, view.bounds.height > 1 else { return }
            let dataChanged = installedSnapshotID != snapshot.id
            if dataChanged {
                installedSnapshotID = snapshot.id
                let features = snapshot.coordinates.compactMap { place, points -> MLNPointCollectionFeature? in
                    guard !points.isEmpty else { return nil }
                    var coordinates = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                    let feature = MLNPointCollectionFeature(coordinates: &coordinates, count: UInt(coordinates.count))
                    feature?.attributes = ["place": place?.directoryID ?? ""]
                    return feature
                }
                source.shape = MLNShapeCollectionFeature(shapes: features)
            }

            let selectionChanged = displayedPlace != value.place
            let selectedPoints = value.place.flatMap { snapshot.coordinates[$0] } ?? []
            let gainedCoordinates = !displayedPlaceHasCoordinates && !selectedPoints.isEmpty
            let duration: TimeInterval = positioned && value.animated && (selectionChanged || gainedCoordinates) ? 0.42 : 0
            if forceLayers || dataChanged || selectionChanged {
                if let place = value.place {
                    placeHeat?.predicate = NSPredicate(format: "%K == %@", "place", place.directoryID)
                }
                let transition = MLNTransition(duration: duration, delay: 0)
                overviewHeat?.heatmapOpacityTransition = transition
                placeHeat?.heatmapOpacityTransition = transition
                overviewHeat?.heatmapOpacity = NSExpression(forConstantValue: value.place == nil ? 0.72 : 0)
                placeHeat?.heatmapOpacity = NSExpression(forConstantValue: value.place == nil ? 0 : 0.72)
            }

            guard !positioned || selectionChanged || gainedCoordinates else { return }
            if positioned, displayedPlace == nil, value.place != nil, overviewCamera == nil {
                overviewCamera = view.camera
            }
            displayedPlace = value.place
            displayedPlaceHasCoordinates = !selectedPoints.isEmpty
            let camera: MLNMapCamera?
            if value.place != nil {
                if overviewCamera == nil {
                    overviewCamera = Self.camera(for: snapshot.coordinates.values.joined(), in: view, minimumSpan: 0.06)
                }
                camera = Self.camera(for: selectedPoints, in: view, minimumSpan: 0.012)
            } else {
                camera = overviewCamera ?? Self.camera(for: snapshot.coordinates.values.joined(), in: view, minimumSpan: 0.06)
            }
            if let camera {
                positioned = true
                cameraGeneration &+= 1
                let generation = cameraGeneration
                view.setCamera(camera, withDuration: duration, animationTimingFunction: CAMediaTimingFunction(name: .easeInEaseOut)) { [weak self] in
                    guard let self, generation == cameraGeneration, displayedPlace == nil else { return }
                    overviewCamera = nil
                }
            }
        }

        private static func heatmap(_ id: String, source: MLNShapeSource, radiusStops: [Int]) -> MLNHeatmapStyleLayer {
            let layer = MLNHeatmapStyleLayer(identifier: id, source: source)
            let radiusExpression: [Any] = ["interpolate", ["linear"], ["zoom"]]
            layer.heatmapRadius = NSExpression(mglJSONObject: radiusExpression + radiusStops)
            layer.heatmapIntensity = NSExpression(mglJSONObject: [
                "interpolate", ["linear"], ["zoom"], 0, 0.12, 5, 0.20, 9, 0.45, 14, 0.75,
            ] as [Any])
            layer.heatmapColor = NSExpression(mglJSONObject: [
                "interpolate", ["linear"], ["heatmap-density"],
                0, "rgba(255, 170, 25, 0)", 0.12, "rgba(255, 170, 25, 0.28)",
                0.45, "rgba(255, 112, 22, 0.49)", 1, "rgba(227, 64, 30, 0.72)",
            ] as [Any])
            return layer
        }

        private static func camera(for points: some Sequence<PlaceCoordinate>, in view: MLNMapView, minimumSpan: Double) -> MLNMapCamera? {
            guard let bounds = LibraryPlacesMapBounds.fitting(points, minimumSpan: minimumSpan) else { return nil }
            return view.cameraThatFitsCoordinateBounds(bounds, edgePadding: .init(top: min(view.bounds.height * 0.4, 100),
                                                                                  left: 26, bottom: 24, right: 26))
        }
    }
}

nonisolated enum LibraryPlacesMapBounds {
    static func fitting(_ points: some Sequence<PlaceCoordinate>, minimumSpan: Double, paddingFraction: Double = 0) -> MLNCoordinateBounds? {
        var south = Double.infinity
        var north = -Double.infinity
        var west = Double.infinity
        var east = -Double.infinity
        var shiftedWest = Double.infinity
        var shiftedEast = -Double.infinity
        for point in points {
            south = min(south, point.latitude)
            north = max(north, point.latitude)
            west = min(west, point.longitude)
            east = max(east, point.longitude)
            let shifted = point.longitude < 0 ? point.longitude + 360 : point.longitude
            shiftedWest = min(shiftedWest, shifted)
            shiftedEast = max(shiftedEast, shifted)
        }
        guard south.isFinite else { return nil }
        if shiftedEast - shiftedWest < east - west {
            west = shiftedWest
            east = shiftedEast
        }
        let latitudeSpan = north - south
        let longitudeSpan = east - west
        let latitudePadding = max((minimumSpan - latitudeSpan) / 2, latitudeSpan * paddingFraction)
        let longitudePadding = min(max((minimumSpan - longitudeSpan) / 2, longitudeSpan * paddingFraction), (360 - longitudeSpan) / 2)
        let mercatorLatitudeLimit = 85.05112878
        return MLNCoordinateBounds(
            sw: .init(latitude: max(-mercatorLatitudeLimit, south - latitudePadding), longitude: west - longitudePadding),
            ne: .init(latitude: min(mercatorLatitudeLimit, north + latitudePadding), longitude: east + longitudePadding)
        )
    }
}
