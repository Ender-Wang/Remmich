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

    /// Export implementation is a separate feature; both presentations stay disabled.
    var isEnabled: Bool {
        false
    }

    var unavailableHint: String {
        "Coming in a later update"
    }
}
