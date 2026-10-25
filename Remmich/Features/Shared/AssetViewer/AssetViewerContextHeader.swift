import SwiftUI

nonisolated struct AssetViewerContextPresentation: Equatable, Sendable {
    let assetID: String
    let capturedAt: Date
    let location: String?

    init(asset: TimelineAssetSummary, detail: AssetDetail?) {
        assetID = asset.id
        capturedAt = detail?.capturedAt ?? asset.capturedAt
        location = Self.normalizedLocation(from: detail)
    }

    private static func normalizedLocation(from detail: AssetDetail?) -> String? {
        let location = [detail?.city, detail?.state, detail?.country]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .first?
            .split(separator: ",", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return location?.isEmpty == false ? location : nil
    }
}

struct AssetViewerContextHeader: View, Equatable {
    let presentation: AssetViewerContextPresentation?
    let height: CGFloat

    var body: some View {
        let date = presentation.map {
            TimelineCaptureDateFormatting.string(
                from: $0.capturedAt,
                dateStyle: .medium,
                timeStyle: .short
            )
        } ?? " "
        let location = presentation?.location
        let hasLocation = location != nil

        ZStack {
            Color.clear
                .glassEffect(.regular, in: Capsule())
                .accessibilityHidden(true)

            ZStack {
                Text(date)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .opacity(hasLocation ? 0 : 1)
                    .accessibilityHidden(hasLocation)

                VStack(spacing: 0) {
                    Text(location ?? " ")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text(date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .opacity(hasLocation ? 1 : 0)
                .accessibilityHidden(!hasLocation)
            }
            .padding(.horizontal, 14)
        }
        .frame(height: height)
        .transaction { transaction in
            transaction.animation = nil
        }
        .accessibilityElement(children: .combine)
        .accessibilityHidden(presentation == nil)
    }
}
