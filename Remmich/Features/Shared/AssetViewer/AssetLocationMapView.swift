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
    let mapSession: AssetMapSession
    let isCurrent: () -> Bool
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
        let expectedNamespace = locations?.namespace
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
                               mapSession: mapSession,
                               namespace: locations?.namespace,
                               canAttach: { isCurrent() && locations?.namespace == expectedNamespace },
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
    let mapSession: AssetMapSession
    let namespace: String?
    let canAttach: () -> Bool
    let loadFailed: () -> Void

    func makeCoordinator() -> AssetMapSession {
        mapSession
    }

    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        context.coordinator.attach(to: host, value: self)
        return host
    }

    func updateUIView(_ host: UIView, context: Context) {
        context.coordinator.attach(to: host, value: self)
    }

    static func dismantleUIView(_ host: UIView, coordinator: AssetMapSession) {
        coordinator.detach(from: host)
    }
}

/// One renderer for the open viewer's Info panel. Pager pages own only lightweight
/// hosts; a late teardown from the outgoing page cannot detach the incoming map.
@MainActor
final class AssetMapSession: NSObject, MLNMapViewDelegate {
    private var retainedMap: MLNMapView?
    private weak var host: UIView?
    private var namespace: String?
    #if DEBUG
        private var diagnosticID = ""
        private static let logger = Logger(subsystem: "io.github.ender-wang.Remmich", category: "AssetMapLifecycle")
    #endif
    private var coordinate: PlaceCoordinate?
    private var language: PlaceLanguage = .english
    private var originals: [String: NSExpression] = [:]
    private let pin = MLNPointAnnotation()
    var loadFailed: (() -> Void)?

    fileprivate func attach(to host: UIView, value: NativeAssetMap) {
        guard value.canAttach() else {
            detach(from: host)
            return
        }
        if namespace != value.namespace {
            reset()
            namespace = value.namespace
        }
        let view: MLNMapView
        if let retainedMap {
            view = retainedMap
        } else {
            view = MLNMapView(frame: .zero, styleURL: value.styleURL)
            view.delegate = self
            view.showsUserLocation = false
            view.isRotateEnabled = false
            view.isPitchEnabled = false
            retainedMap = view
            #if DEBUG
                diagnosticID = String(UUID().uuidString.prefix(8))
            #endif
            recordLifecycle("created")
        }
        if self.host !== host {
            view.removeFromSuperview()
            host.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                view.topAnchor.constraint(equalTo: host.topAnchor),
                view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
            self.host = host
            recordLifecycle("host-attached")
        }
        update(view, value: value)
    }

    fileprivate func detach(from host: UIView) {
        guard self.host === host else { return }
        retainedMap?.removeFromSuperview()
        self.host = nil
        loadFailed = nil
        recordLifecycle("host-detached")
    }

    func reset() {
        if let retainedMap {
            retainedMap.delegate = nil
            retainedMap.removeFromSuperview()
            recordLifecycle("removed")
        }
        retainedMap = nil
        host = nil
        loadFailed = nil
        namespace = nil
        coordinate = nil
        language = .english
        originals = [:]
    }

    func recordLifecycle(_ event: String) {
        #if DEBUG
            let id = diagnosticID
            Self.logger.debug("Asset map lifecycle id=\(id, privacy: .public) event=\(event, privacy: .public)")
        #endif
    }

    private func update(_ view: MLNMapView, value: NativeAssetMap) {
        loadFailed = value.loadFailed
        if view.styleURL != value.styleURL {
            recordLifecycle("style-requested")
            originals = [:]
            view.styleURL = value.styleURL
        }
        view.isScrollEnabled = value.interactive
        view.isZoomEnabled = value.interactive
        if coordinate != value.coordinate {
            recordLifecycle("coordinate-updated")
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

    func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
        guard retainedMap === mapView else { return }
        recordLifecycle("style-loaded")
        originals = [:]
        localize(style)
    }

    func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError _: Error) {
        Task { @MainActor [weak self, weak mapView] in
            guard let self, let mapView, retainedMap === mapView, host != nil else { return }
            let reportFailure = loadFailed
            reset()
            reportFailure?()
        }
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
