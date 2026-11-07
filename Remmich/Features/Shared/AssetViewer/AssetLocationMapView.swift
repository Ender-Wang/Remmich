import CoreLocation
import Foundation
import ImmichAPI
import MapLibre
import OSLog
import SwiftUI

struct AssetLocationMapView: View {
    static let height: CGFloat = 240
    @Environment(\.assetLocations) private var locations
    @Environment(\.colorScheme) private var colorScheme
    let coordinate: PlaceCoordinate
    let place: PlaceLocation?
    let viewportHeight: CGFloat
    var interactionBottomInset: CGFloat = 0
    var interactionRegionChanged: (CGRect?) -> Void = { _ in }
    @State private var frame: CGRect = .zero
    @State private var globalFrame: CGRect = .zero
    @State private var failed = false
    @State private var retry = 0
    @State private var hasEnteredViewport = false

    private var visible: Bool {
        frame.maxY > 0 && frame.minY < viewportHeight
    }

    private var fullyVisible: Bool {
        frame.minY >= -1 && frame.maxY <= viewportHeight - interactionBottomInset + 1
    }

    private var nativeMapActive: Bool {
        visible && !failed && locations?.mapStyles?.enabled == true
    }

    private var coordinateText: String {
        "\(coordinate.latitude.formatted(.number.precision(.fractionLength(5)))), \(coordinate.longitude.formatted(.number.precision(.fractionLength(5))))"
    }

    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            // Retain the selected Info card's map after its first reveal. A
            // scroll/resize across the viewport edge must not recreate it.
            if visible || hasEnteredViewport, !failed, let styles = locations?.mapStyles, styles.enabled {
                NativeAssetMap(coordinate: coordinate,
                               styleURL: colorScheme == .dark ? styles.dark : styles.light,
                               language: place?.language ?? .english,
                               interactive: fullyVisible,
                               title: place?.title ?? "Photo location",
                               loadFailed: { failed = true })
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "map")
                    Text(failed ? "Map Unavailable" : "Asset Location").font(.subheadline)
                    if failed {
                        Button("Try Again") { retry &+= 1 }
                    }
                }
            }
        }
        .frame(height: Self.height)
        .overlay(alignment: .bottom) {
            Text(coordinateText)
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 28)
                .allowsHitTesting(false)
        }
        .clipShape(.rect(cornerRadius: DesignMetrics.defaultCornerRadius))
        .onGeometryChange(for: MapPosition.self) {
            MapPosition(scroll: $0.frame(in: .named("asset-info-scroll")), global: $0.frame(in: .global))
        } action: { position in
            frame = position.scroll
            globalFrame = position.global
            interactionRegionChanged(nativeMapActive && fullyVisible ? position.global : nil)
        }
        .onChange(of: nativeMapActive) { _, active in
            interactionRegionChanged(active && fullyVisible ? globalFrame : nil)
        }
        .onDisappear { interactionRegionChanged(nil) }
        .task(id: "\(visible)|\(locations?.mapEndpoint?.absoluteString ?? "")|\(retry)") {
            guard visible, let locations else { return }
            hasEnteredViewport = true
            failed = false
            do {
                try await locations.loadMapStyles()
            } catch {
                if !Task.isCancelled, locations.mapStyles == nil {
                    failed = true
                }
            }
        }
        .accessibilityIdentifier("asset-viewer-map")
    }
}

private nonisolated struct MapPosition: Equatable {
    let scroll: CGRect
    let global: CGRect
}

private struct NativeAssetMap: UIViewRepresentable {
    let coordinate: PlaceCoordinate
    let styleURL: URL
    let language: PlaceLanguage
    let interactive: Bool
    let title: String
    let loadFailed: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MLNMapView {
        let view = MLNMapView(frame: .zero, styleURL: styleURL)
        view.delegate = context.coordinator
        view.showsUserLocation = false
        view.isRotateEnabled = false
        view.isPitchEnabled = false
        context.coordinator.update(view, value: self)
        context.coordinator.recordLifecycle("created")
        return view
    }

    func updateUIView(_ view: MLNMapView, context: Context) {
        context.coordinator.update(view, value: self)
    }

    static func dismantleUIView(_ view: MLNMapView, coordinator: Coordinator) {
        coordinator.recordLifecycle("removed")
        view.delegate = nil
        coordinator.loadFailed = nil
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        #if DEBUG
            private let diagnosticID = String(UUID().uuidString.prefix(8))
            private static let logger = Logger(subsystem: "io.github.ender-wang.Remmich", category: "AssetMapLifecycle")
        #endif
        private var coordinate: PlaceCoordinate?
        private var language: PlaceLanguage = .english
        private var originals: [String: NSExpression] = [:]
        private let pin = MLNPointAnnotation()
        var loadFailed: (() -> Void)?

        func recordLifecycle(_ event: String) {
            #if DEBUG
                let id = diagnosticID
                Self.logger.debug("Asset map lifecycle id=\(id, privacy: .public) event=\(event, privacy: .public)")
            #endif
        }

        func update(_ view: MLNMapView, value: NativeAssetMap) {
            loadFailed = value.loadFailed
            if view.styleURL != value.styleURL {
                recordLifecycle("style-requested")
                originals = [:]
                view.styleURL = value.styleURL
            }
            view.isScrollEnabled = value.interactive
            view.isZoomEnabled = value.interactive
            if coordinate != value.coordinate {
                coordinate = value.coordinate
                pin.coordinate = CLLocationCoordinate2D(latitude: value.coordinate.latitude, longitude: value.coordinate.longitude)
                if view.annotations?.isEmpty != false {
                    view.addAnnotation(pin)
                }
                view.setCenter(pin.coordinate, zoomLevel: 13, animated: false)
            }
            pin.title = value.title
            if language != value.language {
                language = value.language
                if let style = view.style {
                    localize(style)
                }
            }
        }

        func mapView(_: MLNMapView, didFinishLoading style: MLNStyle) {
            recordLifecycle("style-loaded")
            originals = [:]
            localize(style)
        }

        func mapViewDidFailLoadingMap(_: MLNMapView, withError _: Error) {
            Task { @MainActor [weak self] in self?.loadFailed?() }
        }

        private func localize(_ style: MLNStyle) {
            for case let layer as MLNSymbolStyleLayer in style.layers {
                guard let text = originals[layer.identifier] ?? layer.text,
                      String(describing: text.mgl_jsonExpressionObject).contains("name") else { continue }
                originals[layer.identifier] = text
                // Keep the server's source, fonts, colors, and non-name labels.
                let keys = language == .english ? ["name:en", "name", "pgf:name"] : ["name", "pgf:name", "name:en"]
                let expression: [Any] = ["coalesce"] + keys.map { ["get", $0] as Any }
                layer.text = NSExpression(mglJSONObject: expression)
            }
        }
    }
}
