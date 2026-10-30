import SwiftUI

enum AssetViewerDetailState: Equatable {
    case idle
    case loading
    case loaded(AssetDetail)
    case failed(String)
}

enum AssetViewerFullResolutionState: Equatable {
    case available
    case loading
    case failed(String)
    case loaded
}

nonisolated enum AssetViewerRenderedImageSource: Equatable, Sendable {
    case thumbnail
    case preview
    case fullSize
    case original

    var title: String {
        switch self {
        case .thumbnail:
            "Thumbnail"
        case .preview:
            "Preview"
        case .fullSize:
            "Full"
        case .original:
            "Original"
        }
    }
}

nonisolated struct AssetViewerRenderedImageMetadata: Equatable, Sendable {
    static let loadingDisplayText = "Loading details…"

    let source: AssetViewerRenderedImageSource
    let pixelSize: MediaPixelSize
    let fileSizeBytes: Int?
    let motionFileSizeBytes: Int?

    init(
        source: AssetViewerRenderedImageSource,
        pixelSize: MediaPixelSize,
        fileSizeBytes: Int?,
        motionFileSizeBytes: Int? = nil
    ) {
        self.source = source
        self.pixelSize = pixelSize
        self.fileSizeBytes = fileSizeBytes
        self.motionFileSizeBytes = motionFileSizeBytes
    }

    var displayText: String {
        let width = pixelSize.width.formatted()
        let height = pixelSize.height.formatted()
        var components = [source.title, "\(width) × \(height) px"]
        if let fileSizeBytes, fileSizeBytes > 0 {
            var totalBytes = fileSizeBytes
            var includesMotion = false
            if source == .original,
               let motionFileSizeBytes,
               motionFileSizeBytes > 0
            {
                totalBytes += motionFileSizeBytes
                includesMotion = true
            }
            var byteDescription = ByteCountFormatter.string(
                fromByteCount: Int64(totalBytes),
                countStyle: .file
            )
            if includesMotion {
                byteDescription += " incl. motion"
            }
            components.append(byteDescription)
        }
        return components.joined(separator: " · ")
    }

    func includingMotion(byteCount: Int?) -> Self {
        .init(
            source: source,
            pixelSize: pixelSize,
            fileSizeBytes: fileSizeBytes,
            motionFileSizeBytes: byteCount
        )
    }
}

nonisolated enum AssetViewerVideoDynamicRange: String, Equatable, Sendable {
    case sdr = "SDR"
    case hdr = "HDR"
    case dolbyVision = "DV"
}

nonisolated struct AssetViewerVideoPlaybackMetadata: Equatable, Sendable {
    let fileSizeBytes: Int?
    let pixelSize: MediaPixelSize
    let frameRate: Double?
    let videoCodec: String?
    let videoBitrate: Double?
    let audioCodec: String?
    let dynamicRange: AssetViewerVideoDynamicRange

    var fileDescription: String {
        guard let fileSizeBytes, fileSizeBytes > 0 else { return "Playback" }
        return "Playback · \(ByteCountFormatter.string(fromByteCount: Int64(fileSizeBytes), countStyle: .file))"
    }

    var displayText: String {
        var components = [
            "\(pixelSize.width.formatted()) × \(pixelSize.height.formatted()) px",
        ]
        if let frameRate, frameRate.isFinite, frameRate > 0 {
            components.append(Self.frameRateDescription(frameRate))
        }
        if let videoCodec, !videoCodec.isEmpty {
            components.append(videoCodec)
        }
        if let videoBitrate, videoBitrate > 0 {
            components.append(Self.bitrateDescription(videoBitrate))
        }
        if let audioCodec, !audioCodec.isEmpty {
            components.append(audioCodec)
        }
        return components.joined(separator: " · ")
    }

    private static func bitrateDescription(_ bitsPerSecond: Double) -> String {
        if bitsPerSecond >= 1_000_000 {
            return String(format: "%.1f Mbps", bitsPerSecond / 1_000_000)
        }
        return String(format: "%.0f kbps", bitsPerSecond / 1000)
    }

    private static func frameRateDescription(_ framesPerSecond: Double) -> String {
        let rounded = framesPerSecond.rounded()
        if abs(framesPerSecond - rounded) < 0.01 {
            return "\(Int(rounded)) fps"
        }
        return "\(framesPerSecond.formatted(.number.precision(.fractionLength(0 ... 2)))) fps"
    }
}

struct AssetViewerInfoView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let state: AssetViewerDetailState
    let renderedImageMetadata: AssetViewerRenderedImageMetadata?
    let videoPlaybackMetadata: AssetViewerVideoPlaybackMetadata?
    let fullResolutionState: AssetViewerFullResolutionState?
    let anchorsContentToBottom: Bool
    let contentHeightChanged: (CGFloat) -> Void
    let retry: () -> Void
    let loadFullResolution: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                Group {
                    switch state {
                    case .idle, .loading:
                        RemmichLoadingView(label: "Loading asset information")
                            .tint(.primary)
                            .frame(maxWidth: .infinity, minHeight: 220)
                    case let .loaded(detail):
                        details(detail)
                    case let .failed(message):
                        ContentUnavailableView {
                            Label("Information Unavailable", systemImage: "exclamationmark.circle")
                        } description: {
                            Text(message)
                        } actions: {
                            Button("Try Again", action: retry)
                                .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity, minHeight: 260)
                    }
                }
                .padding(.horizontal, 16)
                .background {
                    GeometryReader { contentGeometry in
                        Color.clear.preference(
                            key: AssetViewerInfoContentHeightKey.self,
                            value: contentGeometry.size.height
                        )
                    }
                }
                .frame(
                    minHeight: geometry.size.height,
                    alignment: anchorsContentToBottom ? .bottom : .top
                )
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .onPreferenceChange(AssetViewerInfoContentHeightKey.self, perform: contentHeightChanged)
        .background(Color(uiColor: .systemBackground))
        .foregroundStyle(.primary)
        .accessibilityIdentifier("asset-viewer-info-panel")
    }

    private func details(_ detail: AssetDetail) -> some View {
        VStack(spacing: 16) {
            if let description = detail.description?.trimmingCharacters(in: .whitespacesAndNewlines),
               !description.isEmpty
            {
                Text(description)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(infoSurface)
                    .clipShape(.rect(cornerRadius: DesignMetrics.defaultCornerRadius))
                    .accessibilityIdentifier("asset-viewer-description")
            }

            VStack(spacing: 0) {
                Text(TimelineCaptureDateFormatting.string(
                    from: detail.capturedAt,
                    dateStyle: .long,
                    timeStyle: .short
                ))
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)

                Divider().overlay(Color.primary.opacity(0.16))

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(detail.originalFileName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .layoutPriority(1)
                            if let videoPlaybackMetadata {
                                Text(videoPlaybackMetadata.fileDescription)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .transition(.opacity)
                                    .accessibilityIdentifier("asset-viewer-video-playback-file")
                            }
                            if let fullResolutionState {
                                fullResolutionButton(for: fullResolutionState)
                            }
                        }
                        renderedImageMetadataRow
                        if case let .failed(message)? = fullResolutionState {
                            Text(message)
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .accessibilityIdentifier("asset-viewer-full-resolution-error")
                        }
                    }
                    Spacer(minLength: 8)
                    Text(typeBadge(for: detail))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 28)
                        .background(Color.primary.opacity(0.1), in: Capsule())
                }
                .padding(16)

                let equipment = equipmentSummary(for: detail)
                if equipment.hasContent {
                    Divider().overlay(Color.primary.opacity(0.16))
                    VStack(spacing: 6) {
                        if let camera = equipment.camera {
                            Text(camera)
                                .foregroundStyle(.primary)
                                .accessibilityIdentifier("asset-viewer-camera")
                        }
                        if let lens = equipment.lens {
                            Text(lens)
                                .accessibilityIdentifier("asset-viewer-lens")
                        }
                        if let photo = equipment.photo {
                            Text(photo)
                                .accessibilityIdentifier("asset-viewer-photo-facts")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(16)
                }

                if !exposureFacts(for: detail).isEmpty {
                    Divider().overlay(Color.primary.opacity(0.16))
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 0) {
                            exposureFactViews(for: detail)
                        }
                        VStack(spacing: 10) {
                            exposureFactViews(for: detail)
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 8)
                }

                if let location = locationSummary(for: detail) {
                    Divider().overlay(Color.primary.opacity(0.16))
                    Label(location, systemImage: "location.fill")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(16)
                        .accessibilityIdentifier("asset-viewer-location")
                }
            }
            .background(infoSurface)
            .clipShape(.rect(cornerRadius: DesignMetrics.defaultCornerRadius))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("asset-viewer-metadata-card")
        }
    }

    private var renderedImageMetadataRow: some View {
        let displayText = videoPlaybackMetadata?.displayText
            ?? renderedImageMetadata?.displayText
            ?? AssetViewerRenderedImageMetadata.loadingDisplayText
        return ZStack(alignment: .leading) {
            Text(displayText)
                .id(displayText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .transition(.opacity)
                .accessibilityLabel(
                    renderedImageMetadata == nil
                        && videoPlaybackMetadata == nil
                        ? "Image details loading"
                        : displayText
                )
                .accessibilityIdentifier("asset-viewer-rendered-metadata")
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.18),
            value: displayText
        )
    }

    private func fullResolutionButton(
        for state: AssetViewerFullResolutionState
    ) -> some View {
        Button(action: loadFullResolution) {
            HStack(spacing: 4) {
                if state == .loading {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityHidden(true)
                }
                Text(fullResolutionButtonTitle(for: state))
                    .font(.subheadline.weight(.semibold))
            }
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .foregroundStyle(
            state == .loaded ? Color(uiColor: .tertiaryLabel) : Color.primary
        )
        .frame(minHeight: 44)
        .contentShape(.rect)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(state == .loading || state == .loaded)
        .accessibilityLabel(fullResolutionAccessibilityLabel(for: state))
        .accessibilityIdentifier("asset-viewer-load-original")
    }

    private func fullResolutionButtonTitle(
        for state: AssetViewerFullResolutionState
    ) -> String {
        switch state {
        case .loading:
            "Loading…"
        case .loaded:
            "Original Loaded"
        case .available, .failed:
            "Load Original"
        }
    }

    private func fullResolutionAccessibilityLabel(
        for state: AssetViewerFullResolutionState
    ) -> String {
        switch state {
        case .failed:
            "Retry loading original"
        case .loaded:
            "Original loaded"
        case .available, .loading:
            "Load original"
        }
    }

    private var infoSurface: some ShapeStyle {
        Color(uiColor: .secondarySystemBackground)
    }

    private func typeBadge(for detail: AssetDetail) -> String {
        if isVideo(detail) {
            return videoPlaybackMetadata?.dynamicRange.rawValue ?? "VIDEO"
        }
        if let mime = detail.originalMimeType,
           let subtype = mime.split(separator: "/").last
        {
            return subtype.uppercased()
        }
        let pathExtension = (detail.originalFileName as NSString).pathExtension
        return pathExtension.isEmpty ? "FILE" : pathExtension.uppercased()
    }

    private func equipmentSummary(for detail: AssetDetail) -> AssetViewerEquipmentSummary {
        let camera = [detail.cameraMake, detail.cameraModel]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let lens = detail.lensModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        var photoFacts: [String] = []
        if let width = detail.width, let height = detail.height, width > 0, height > 0 {
            if !isVideo(detail) {
                photoFacts.append(String(format: "%.1f MP", Double(width * height) / 1_000_000))
            }
            photoFacts.append("\(width.formatted()) × \(height.formatted()) px")
        }
        if let bytes = detail.fileSizeBytes, bytes > 0 {
            photoFacts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        return AssetViewerEquipmentSummary(
            camera: camera.isEmpty ? nil : camera,
            lens: lens?.isEmpty == false ? lens : nil,
            photo: photoFacts.isEmpty ? nil : photoFacts.joined(separator: " · ")
        )
    }

    private func isVideo(_ detail: AssetDetail) -> Bool {
        if detail.originalMimeType?.lowercased().hasPrefix("video/") == true {
            return true
        }
        let pathExtension = (detail.originalFileName as NSString).pathExtension.lowercased()
        return ["3gp", "avi", "m4v", "mkv", "mov", "mp4", "webm"].contains(pathExtension)
    }

    private func exposureFacts(for detail: AssetDetail) -> [(String, String)] {
        var values: [(String, String)] = []
        if let iso = detail.iso {
            values.append(("ISO", "\(iso)"))
        }
        if let focalLength = detail.focalLength {
            values.append(("Focal", String(format: "%.0f mm", focalLength)))
        }
        if let aperture = detail.aperture {
            values.append(("Aperture", String(format: "ƒ/%.1f", aperture)))
        }
        if let exposure = detail.exposureTime, !exposure.isEmpty {
            values.append(("Shutter", "\(exposure) s"))
        }
        return values
    }

    private func exposureFactViews(for detail: AssetDetail) -> some View {
        ForEach(Array(exposureFacts(for: detail).enumerated()), id: \.offset) { index, fact in
            VStack(spacing: 3) {
                Text(fact.0)
                    .font(.caption2)
                Text(fact.1)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            if index < exposureFacts(for: detail).count - 1 {
                Divider()
                    .overlay(Color.primary.opacity(0.16))
                    .frame(height: 28)
            }
        }
    }

    private func locationSummary(for detail: AssetDetail) -> String? {
        let values = [detail.city, detail.state, detail.country]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return values.isEmpty ? nil : values.removingDuplicates().joined(separator: ", ")
    }
}

private struct AssetViewerEquipmentSummary {
    let camera: String?
    let lens: String?
    let photo: String?

    var hasContent: Bool {
        camera != nil || lens != nil || photo != nil
    }
}

private struct AssetViewerInfoContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension Array where Element: Hashable {
    func removingDuplicates() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
