import CoreLocation
import Foundation
import ImmichAPI
import MapLibre
import Observation
import OSLog
import SwiftUI
import UIKit

/// All placement and clipping use viewer-root coordinates, independently of the
/// horizontally moving pager pages. The map itself never changes UIKit hosts.
nonisolated struct AssetMapViewportGeometry: Equatable {
    static let mapHeight: CGFloat = 240
    let mapFrame: CGRect
    let maskFrame: CGRect
    let isVisible: Bool
    let isFullyVisible: Bool

    init(mapTop: CGFloat, viewport: CGRect, contentWidth: CGFloat, bottomInset: CGFloat, mapLeft: CGFloat? = nil) {
        mapFrame = CGRect(x: mapLeft ?? viewport.minX + 16, y: mapTop,
                          width: max(0, contentWidth - 32), height: Self.mapHeight)
        let clipped = mapFrame.intersection(viewport)
        isVisible = !clipped.isNull && !clipped.isEmpty
        maskFrame = isVisible ? clipped.offsetBy(dx: -mapFrame.minX, dy: -mapFrame.minY) : .zero
        let interactiveViewport = CGRect(x: viewport.minX, y: viewport.minY,
                                         width: viewport.width, height: max(0, viewport.height - bottomInset))
        isFullyVisible = isVisible && interactiveViewport.insetBy(dx: -1, dy: -1).contains(mapFrame)
    }
}

nonisolated struct AssetMapSlotLayout: Equatable {
    let frame: CGRect
    let viewport: CGRect
}

nonisolated enum AssetMapPagingTarget {
    static func resolve(preferredID: String, outgoingID: String?, slots: [String: AssetMapSlotLayout],
                        coordinateIDs: Set<String>, viewport: CGRect) -> String
    {
        guard let outgoingID else { return preferredID }
        // Select the incoming card as soon as it enters, rather than waiting for
        // the pager's committed selection. Reversing direction uses the same rule.
        return slots.filter { id, slot in
            id != outgoingID && coordinateIDs.contains(id)
                && slot.viewport.intersection(viewport).width > 1
        }.max { lhs, rhs in
            lhs.value.viewport.intersection(viewport).width < rhs.value.viewport.intersection(viewport).width
        }?.key ?? outgoingID
    }
}

/// Geometry changes are observed by the map overlay, not the entire asset viewer.
@MainActor @Observable final class AssetMapPresentation {
    var slots: [String: AssetMapSlotLayout] = [:]
    private(set) var snapshot: UIView?
    private(set) var outgoingID: String?
    private(set) var outgoingCoordinate: PlaceCoordinate?
    @ObservationIgnored weak var nativeMap: MLNMapView?
    @ObservationIgnored var liveID: String?
    @ObservationIgnored var liveCoordinate: PlaceCoordinate?
    @ObservationIgnored var liveVisible = false
    @ObservationIgnored private(set) var outgoingCamera: MLNMapCamera?
    @ObservationIgnored private var restoreCamera: (id: String, camera: MLNMapCamera)?

    func beginPaging() {
        guard outgoingID == nil, let nativeMap, nativeMap.window != nil,
              liveVisible, let liveID,
              let snapshot = nativeMap.snapshotView(afterScreenUpdates: false) else { return }
        outgoingCamera = nativeMap.camera
        outgoingCoordinate = liveCoordinate
        outgoingID = liveID
        snapshot.isUserInteractionEnabled = false
        self.snapshot = snapshot
    }

    func endPaging(finalID: String? = nil) {
        if finalID == outgoingID, let outgoingID, let outgoingCamera {
            restoreCamera = (outgoingID, outgoingCamera)
        }
        snapshot = nil
        outgoingID = nil
        outgoingCoordinate = nil
        outgoingCamera = nil
    }

    func takeRestoredCamera(for id: String) -> MLNMapCamera? {
        guard restoreCamera?.id == id else { return nil }
        defer { restoreCamera = nil }
        return restoreCamera?.camera
    }

    func reset() {
        endPaging()
        restoreCamera = nil
        slots = [:]
        nativeMap = nil
        liveID = nil
        liveCoordinate = nil
        liveVisible = false
    }
}

/// Reserves space inside each Info scroll view without owning a native map.
struct AssetLocationMapSlot: View {
    let viewportSize: CGSize
    let positionChanged: (AssetMapSlotLayout?) -> Void

    var body: some View {
        Color.clear
            .frame(height: AssetMapViewportGeometry.mapHeight)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onGeometryChange(for: AssetMapSlotLayout.self) { geometry in
                let frame = geometry.frame(in: .global)
                let local = geometry.frame(in: .named("asset-info-scroll"))
                return AssetMapSlotLayout(frame: frame,
                                          viewport: CGRect(x: frame.minX - local.minX, y: frame.minY - local.minY,
                                                           width: viewportSize.width, height: viewportSize.height))
            } action: { positionChanged($0) }
            .onDisappear { positionChanged(nil) }
    }
}

/// One native map stays mounted while its frame follows the incoming Info page.
/// A single outgoing snapshot supplies the second visible card during paging.
struct AssetLocationMapOverlay: View {
    let presentation: AssetMapPresentation
    let assetID: String
    let coordinates: [String: PlaceCoordinate]
    let fallbackCoordinate: PlaceCoordinate?
    let place: PlaceLocation?
    let origin: CGPoint
    let viewport: CGRect
    let bottomInset: CGFloat
    let contentWidth: CGFloat
    let interactive: Bool
    @Binding var failed: Bool
    let interactionChanged: (CGRect?) -> Void
    @Environment(\.assetLocations) private var locations
    @State private var resolvedPlace: PlaceLocation?
    @State private var resolvedAssetID: String?
    @State private var resolvedRevision: Int?

    private func geometry(for id: String) -> AssetMapViewportGeometry? {
        guard let slot = presentation.slots[id] else { return nil }
        let clippedViewport = slot.viewport.offsetBy(dx: -origin.x, dy: -origin.y).intersection(viewport)
        return AssetMapViewportGeometry(mapTop: slot.frame.minY - origin.y, viewport: clippedViewport,
                                        contentWidth: slot.frame.width + 32, bottomInset: bottomInset, mapLeft: slot.frame.minX - origin.x)
    }

    var body: some View {
        let targetID = AssetMapPagingTarget.resolve(preferredID: assetID, outgoingID: presentation.outgoingID,
                                                    slots: presentation.slots, coordinateIDs: Set(coordinates.keys),
                                                    viewport: viewport.offsetBy(dx: origin.x, dy: origin.y))
        let coordinate = coordinates[targetID]
        let liveGeometry = geometry(for: targetID)
        let visible = coordinate != nil && liveGeometry?.isVisible == true
        let canInteract = interactive && visible && liveGeometry?.isFullyVisible == true
        let interactionFrame = canInteract && !failed && locations?.mapStyles?.enabled == true
            ? liveGeometry?.mapFrame.offsetBy(dx: origin.x, dy: origin.y) : nil
        ZStack {
            // A missing-GPS page hides the map without destroying its renderer.
            if let coordinate = coordinate ?? fallbackCoordinate {
                AssetLocationMapView(coordinate: coordinate,
                                     place: resolvedAssetID == targetID && resolvedRevision == locations?.revision ? resolvedPlace : (targetID == assetID ? place : nil),
                                     visible: visible, fullyVisible: canInteract, failed: $failed,
                                     presentation: presentation, assetID: targetID)
                    .frame(width: liveGeometry?.mapFrame.width ?? max(0, contentWidth - 32), height: AssetLocationMapView.height)
                    .mapPlacement(liveGeometry)
                    .opacity(visible ? 1 : 0)
                    .allowsHitTesting(canInteract)
                    .accessibilityHidden(!visible)
            }
            if let id = presentation.outgoingID, let snapshot = presentation.snapshot,
               let geometry = geometry(for: id), geometry.isVisible,
               let coordinate = presentation.outgoingCoordinate
            {
                AssetMapSnapshotView(snapshot: snapshot)
                    .frame(width: geometry.mapFrame.width, height: geometry.mapFrame.height)
                    .overlay(alignment: .bottom) { AssetMapCoordinateLabel(coordinate: coordinate) }
                    .clipShape(.rect(cornerRadius: DesignMetrics.defaultCornerRadius))
                    .mapPlacement(geometry)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: interactionFrame, initial: true) { _, frame in interactionChanged(frame) }
        .task(id: "\(targetID)|\(coordinate?.latitude.description ?? "")|\(coordinate?.longitude.description ?? "")|\(locations?.revision ?? 0)") {
            resolvedPlace = nil
            resolvedAssetID = nil
            guard let coordinate, let locations else { return }
            let revision = locations.revision
            let result = try? await locations.resolve(coordinate)
            guard !Task.isCancelled else { return }
            resolvedPlace = result
            resolvedAssetID = targetID
            resolvedRevision = revision
        }
    }
}

private extension View {
    func mapPlacement(_ geometry: AssetMapViewportGeometry?) -> some View {
        mask(alignment: .topLeading) {
            Rectangle()
                .frame(width: geometry?.maskFrame.width ?? 0, height: geometry?.maskFrame.height ?? 0)
                .offset(x: geometry?.maskFrame.minX ?? 0, y: geometry?.maskFrame.minY ?? 0)
        }
        .position(x: geometry?.mapFrame.midX ?? 0, y: geometry?.mapFrame.midY ?? 0)
    }
}

private struct AssetMapSnapshotView: UIViewRepresentable {
    let snapshot: UIView
    func makeUIView(context _: Context) -> UIView {
        UIView()
    }

    func updateUIView(_ view: UIView, context _: Context) {
        if snapshot.superview !== view {
            view.subviews.forEach { $0.removeFromSuperview() }
            snapshot.frame = view.bounds
            snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(snapshot)
        }
    }
}

private struct AssetMapCoordinateLabel: View {
    let coordinate: PlaceCoordinate
    var body: some View {
        Text("\(coordinate.latitude.formatted(.number.precision(.fractionLength(5)))), \(coordinate.longitude.formatted(.number.precision(.fractionLength(5))))")
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 28)
            .allowsHitTesting(false)
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
    let presentation: AssetMapPresentation
    let assetID: String
    @State private var retry = 0
    @State private var hasEnteredViewport = false

    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            if visible || hasEnteredViewport, !failed, let styles = locations?.mapStyles, styles.enabled {
                NativeAssetMap(coordinate: coordinate,
                               styleURL: colorScheme == .dark ? styles.dark : styles.light,
                               language: place?.language ?? .english,
                               interactive: visible && fullyVisible,
                               visible: visible,
                               animatesCamera: !reduceMotion,
                               title: place?.title ?? "Photo location",
                               presentation: presentation, assetID: assetID,
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
            AssetMapCoordinateLabel(coordinate: coordinate)
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
    let visible: Bool
    let animatesCamera: Bool
    let title: String
    let presentation: AssetMapPresentation
    let assetID: String
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
            let restoredCamera = value.presentation.takeRestoredCamera(for: value.assetID)
            value.presentation.nativeMap = view
            value.presentation.liveID = value.assetID
            value.presentation.liveCoordinate = value.coordinate
            value.presentation.liveVisible = value.visible
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
                if let camera = restoredCamera ?? (value.presentation.outgoingID == value.assetID ? value.presentation.outgoingCamera : nil) {
                    view.setCamera(camera, animated: false)
                } else {
                    view.setCenter(pin.coordinate, zoomLevel: firstPosition ? 13 : view.zoomLevel,
                                   animated: !firstPosition && value.animatesCamera)
                }
            } else if let restoredCamera {
                view.setCamera(restoredCamera, animated: false)
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
