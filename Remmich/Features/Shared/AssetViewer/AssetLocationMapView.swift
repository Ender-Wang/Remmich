import CoreLocation
import Foundation
import ImmichAPI
import MapLibre
import OSLog
import SwiftUI

/// All placement and clipping use viewer-root coordinates, independently of the
/// horizontally moving pager pages. The map itself never changes UIKit hosts.
nonisolated struct AssetMapViewportGeometry: Equatable {
    static let mapHeight: CGFloat = 240
    let mapFrame: CGRect
    let maskFrame: CGRect
    let isVisible: Bool
    let isFullyVisible: Bool

    init(mapTop: CGFloat, viewport: CGRect, contentWidth: CGFloat, bottomInset: CGFloat) {
        mapFrame = CGRect(x: viewport.minX + 16, y: mapTop,
                          width: max(0, contentWidth - 32), height: Self.mapHeight)
        let clipped = mapFrame.intersection(viewport)
        isVisible = !clipped.isNull && !clipped.isEmpty
        maskFrame = isVisible ? clipped.offsetBy(dx: -mapFrame.minX, dy: -mapFrame.minY) : .zero
        let interactiveViewport = CGRect(x: viewport.minX, y: viewport.minY,
                                         width: viewport.width, height: max(0, viewport.height - bottomInset))
        isFullyVisible = isVisible && interactiveViewport.insetBy(dx: -1, dy: -1).contains(mapFrame)
    }
}

/// Reserves space inside each Info scroll view without owning a native map.
struct AssetLocationMapSlot: View {
    let isSelected: Bool
    let positionChanged: (CGFloat) -> Void
    @State private var top: CGFloat?

    var body: some View {
        Color.clear
            .frame(height: AssetMapViewportGeometry.mapHeight)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { value in
                top = value
                if isSelected {
                    positionChanged(value)
                }
            }
            .onChange(of: isSelected) { _, selected in
                if selected, let top {
                    positionChanged(top)
                }
            }
    }
}

struct AssetLocationMapView: View {
    static let height = AssetMapViewportGeometry.mapHeight
    @Environment(\.assetLocations) private var locations
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let coordinate: PlaceCoordinate
    let place: PlaceLocation?
    let visible: Bool
    let fullyVisible: Bool
    @Binding var failed: Bool
    @State private var retry = 0
    @State private var hasEnteredViewport = false

    private var coordinateText: String {
        "\(coordinate.latitude.formatted(.number.precision(.fractionLength(5)))), \(coordinate.longitude.formatted(.number.precision(.fractionLength(5))))"
    }

    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            if visible || hasEnteredViewport, !failed, let styles = locations?.mapStyles, styles.enabled {
                NativeAssetMap(coordinate: coordinate,
                               styleURL: colorScheme == .dark ? styles.dark : styles.light,
                               language: place?.language ?? .english,
                               interactive: visible && fullyVisible,
                               animatesCamera: !reduceMotion,
                               title: place?.title ?? "Photo location",
                               loadFailed: { [failure = $failed] in failure.wrappedValue = true })
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
        .task(id: "\(visible)|\(locations?.mapEndpoint?.absoluteString ?? "")|\(retry)") {
            guard visible, let locations else { return }
            hasEnteredViewport = true
            failed = false
            do { try await locations.loadMapStyles() }
            catch {
                if !Task.isCancelled, locations.mapStyles == nil {
                    failed = true
                }
            }
        }
        .accessibilityIdentifier("asset-viewer-map")
    }
}

private struct NativeAssetMap: UIViewRepresentable {
    let coordinate: PlaceCoordinate
    let styleURL: URL
    let language: PlaceLanguage
    let interactive: Bool
    let animatesCamera: Bool
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
                let firstPosition = coordinate == nil
                recordLifecycle("coordinate-updated")
                coordinate = value.coordinate
                pin.coordinate = CLLocationCoordinate2D(latitude: value.coordinate.latitude, longitude: value.coordinate.longitude)
                if view.annotations?.isEmpty != false {
                    view.addAnnotation(pin)
                }
                view.setCenter(pin.coordinate, zoomLevel: firstPosition ? 13 : view.zoomLevel,
                               animated: !firstPosition && value.animatesCamera)
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
                let keys = language == .english ? ["name:en", "name", "pgf:name"] : ["name", "pgf:name", "name:en"]
                let expression: [Any] = ["coalesce"] + keys.map { ["get", $0] as Any }
                layer.text = NSExpression(mglJSONObject: expression)
            }
        }
    }
}
