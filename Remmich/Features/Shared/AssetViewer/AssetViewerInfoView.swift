import SwiftUI

enum AssetViewerDetailState: Equatable {
    case idle
    case loading
    case loaded(AssetDetail)
    case failed(String)
}

struct AssetViewerInfoView: View {
    let state: AssetViewerDetailState
    let bottomClearance: CGFloat
    let retry: () -> Void
    let dismiss: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                Group {
                    switch state {
                    case .idle, .loading:
                        ProgressView("Loading information…")
                            .tint(.white)
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
                .padding(.top, 16)
                .padding(.bottom, bottomClearance)
                .frame(minHeight: geometry.size.height, alignment: .bottom)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(.black)
        .foregroundStyle(.white)
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
                Text(detail.capturedAt.formatted(date: .long, time: .shortened))
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)

                Divider().overlay(.white.opacity(0.16))

                HStack(spacing: 12) {
                    Text(detail.originalFileName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(typeBadge(for: detail))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 28)
                        .background(.white.opacity(0.1), in: Capsule())
                }
                .padding(16)

                if let summary = equipmentSummary(for: detail) {
                    Divider().overlay(.white.opacity(0.16))
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(16)
                }

                if !exposureFacts(for: detail).isEmpty {
                    Divider().overlay(.white.opacity(0.16))
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
                    Divider().overlay(.white.opacity(0.16))
                    Label(location, systemImage: "location.fill")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .accessibilityIdentifier("asset-viewer-location")
                }
            }
            .background(infoSurface)
            .clipShape(.rect(cornerRadius: DesignMetrics.defaultCornerRadius))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("asset-viewer-metadata-card")
        }
        .simultaneousGesture(dismissGesture)
    }

    private var infoSurface: some ShapeStyle {
        Color(uiColor: .secondarySystemBackground)
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard value.translation.height >= 24,
                      value.translation.height > abs(value.translation.width) * 1.2
                else { return }
                dismiss()
            }
    }

    private func typeBadge(for detail: AssetDetail) -> String {
        if let mime = detail.originalMimeType,
           let subtype = mime.split(separator: "/").last
        {
            return subtype.uppercased()
        }
        let pathExtension = (detail.originalFileName as NSString).pathExtension
        return pathExtension.isEmpty ? "FILE" : pathExtension.uppercased()
    }

    private func equipmentSummary(for detail: AssetDetail) -> String? {
        var values: [String] = []
        let camera = [detail.cameraMake, detail.cameraModel]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !camera.isEmpty {
            values.append(camera)
        }
        if let lens = detail.lensModel, !lens.isEmpty {
            values.append(lens)
        }
        if let width = detail.width, let height = detail.height, width > 0, height > 0 {
            values.append(String(format: "%.1f MP", Double(width * height) / 1_000_000))
        }
        if let bytes = detail.fileSizeBytes, bytes > 0 {
            values.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        return values.isEmpty ? nil : values.joined(separator: " · ")
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
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            if index < exposureFacts(for: detail).count - 1 {
                Divider()
                    .overlay(.white.opacity(0.16))
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

private extension Array where Element: Hashable {
    func removingDuplicates() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
