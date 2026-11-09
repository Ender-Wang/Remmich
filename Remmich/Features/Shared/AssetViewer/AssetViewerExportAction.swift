/// Shared labels and availability for the viewer and preview export controls.
nonisolated enum AssetViewerExportAction: String {
    case share
    case download

    var title: String {
        switch self {
        case .share: "Share"
        case .download: "Download"
        }
    }

    var systemImage: String {
        switch self {
        case .share: "square.and.arrow.up"
        case .download: "square.and.arrow.down"
        }
    }

    /// Availability additionally depends on a real displayed resource.
    var isEnabled: Bool {
        true
    }

    var unavailableHint: String {
        self == .download ? "Choose a quality and save to Photos" : "Share the displayed resolution"
    }
}
