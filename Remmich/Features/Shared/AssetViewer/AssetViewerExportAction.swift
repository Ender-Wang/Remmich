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

    /// Download is wired to Photos; Share remains a separate delivery.
    var isEnabled: Bool {
        self == .download
    }

    var unavailableHint: String {
        self == .download ? "Choose a quality and save to Photos" : "Coming in a later update"
    }
}
