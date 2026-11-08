import CoreLocation
import Foundation
import ImmichAPI
import MapLibre
import SwiftUI
import UIKit

nonisolated enum AssetMapCoordinateFormatting {
    static func string(_ coordinate: PlaceCoordinate) -> String {
        String(format: "%.5f, %.5f", locale: Locale(identifier: "en_US_POSIX"),
               coordinate.latitude, coordinate.longitude)
    }
}

/// Visibility affects gestures only. The Info page owns the map's lifetime.
nonisolated struct AssetMapViewport: Equatable {
    let visible: Bool
    let fullyVisible: Bool

    init(frame: CGRect, size: CGSize, bottomInset: CGFloat) {
        let viewport = CGRect(origin: .zero, size: size)
        let intersection = viewport.intersection(frame)
        visible = !intersection.isNull && !intersection.isEmpty
        let interactiveViewport = CGRect(x: 0, y: 0, width: size.width,
                                         height: max(0, size.height - bottomInset))
        fullyVisible = visible && interactiveViewport.insetBy(dx: -1, dy: -1).contains(frame)
    }
}

struct AssetLocationMapView: View {
    static let height: CGFloat = 240
    @Environment(\.assetLocations) private var locations
    @Environment(\.colorScheme) private var colorScheme
    let coordinate: PlaceCoordinate
    let place: PlaceLocation?
    let viewportSize: CGSize
    let isSelected: Bool
    let interactionEnabled: Bool
    var interactionBottomInset: CGFloat = 0
    var interactionRegionChanged: (CGRect?) -> Void = { _ in }
    @State private var position = MapPosition(scroll: .zero, global: .zero)
    @State private var failed = false
    @State private var retry = 0

    private var viewport: AssetMapViewport {
        AssetMapViewport(frame: position.scroll, size: viewportSize, bottomInset: interactionBottomInset)
    }

    private var interactionFrame: CGRect? {
        interactionEnabled && viewport.fullyVisible && !failed && locations?.mapStyles?.enabled == true
            ? position.global : nil
    }

    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            // Keep the renderer mounted for exactly as long as this Info page.
            // Neither paging selection nor vertical visibility replaces it.
            if !failed, let styles = locations?.mapStyles, styles.enabled {
                NativeAssetMap(coordinate: coordinate,
                               styleURL: colorScheme == .dark ? styles.dark : styles.light,
                               language: place?.language ?? .english,
                               interactive: interactionFrame != nil,
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
            if failed || locations?.mapStyles?.enabled != true {
                Text(AssetMapCoordinateFormatting.string(coordinate))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .padding(.horizontal, 8)
                    .frame(height: 23)
                    .padding(.bottom, 8)
                    .allowsHitTesting(false)
            }
        }
        .clipShape(.rect(cornerRadius: DesignMetrics.defaultCornerRadius))
        .onGeometryChange(for: MapPosition.self) {
            MapPosition(scroll: $0.frame(in: .named("asset-info-scroll")), global: $0.frame(in: .global))
        } action: { position = $0 }
        .onChange(of: interactionFrame, initial: true) { _, frame in interactionRegionChanged(frame) }
        .onDisappear { interactionRegionChanged(nil) }
        .task(id: "\(isSelected)|\(locations?.mapEndpoint?.absoluteString ?? "")|\(retry)") {
            // Validate the shared style once through the selected Info page.
            // Neighbor pages can render the same cached configuration.
            guard isSelected, let locations else { return }
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
        let label = context.coordinator.coordinateLabel
        view.addSubview(label)
        let center = label.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        center.priority = .init(999)
        NSLayoutConstraint.activate([
            center,
            label.centerYAnchor.constraint(equalTo: view.attributionButton.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.logoView.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.attributionButton.leadingAnchor, constant: -6),
        ])
        context.coordinator.update(view, value: self)
        return view
    }

    func updateUIView(_ view: MLNMapView, context: Context) {
        context.coordinator.update(view, value: self)
    }

    static func dismantleUIView(_ view: MLNMapView, coordinator: Coordinator) {
        view.delegate = nil
        coordinator.loadFailed = nil
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        let coordinateLabel: UILabel = {
            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(for: .systemFont(ofSize: 11, weight: .bold))
            label.adjustsFontForContentSizeCategory = true
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.65
            label.textColor = .label
            label.textAlignment = .center
            label.backgroundColor = .clear
            label.isUserInteractionEnabled = false
            label.accessibilityLabel = "GPS coordinates"
            return label
        }()

        private var coordinate: PlaceCoordinate?
        private var language: PlaceLanguage = .english
        private var originals: [String: NSExpression] = [:]
        private let pin = MLNPointAnnotation()
        var loadFailed: (() -> Void)?

        func update(_ view: MLNMapView, value: NativeAssetMap) {
            loadFailed = value.loadFailed
            if view.styleURL != value.styleURL {
                originals = [:]
                view.styleURL = value.styleURL
            }
            view.isScrollEnabled = value.interactive
            view.isZoomEnabled = value.interactive
            if coordinate != value.coordinate {
                coordinate = value.coordinate
                coordinateLabel.text = AssetMapCoordinateFormatting.string(value.coordinate)
                coordinateLabel.accessibilityValue = coordinateLabel.text
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
