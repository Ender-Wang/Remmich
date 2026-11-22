import SwiftUI

nonisolated enum LibraryCollectionCardMetrics {
    static let minimumWidth: CGFloat = 150
    static let maximumWidth: CGFloat = 260
    static let spacing: CGFloat = 14
    static let aspectRatio: CGFloat = 4 / 3

    static func coverPixels(scale: CGFloat) -> CGSize {
        let width = min(1024, max(1, (maximumWidth * scale).rounded(.up)))
        return CGSize(width: width, height: (width / aspectRatio).rounded(.up))
    }

    static func coverDescriptor(_ cover: LibraryCoverAsset, scale: CGFloat) -> MediaRequestDescriptor {
        let pixels = coverPixels(scale: scale)
        return .init(assetID: cover.id, updatedAt: cover.revision, derivative: .thumbnail,
                     targetPixels: .init(width: Int(pixels.width), height: Int(pixels.height)))
    }
}

/// One geometry and footer contract for every Library destination. Data loading
/// and navigation stay with the caller; a cover is just presentation content.
struct LibraryCollectionCard<Cover: View>: View {
    enum Appearance { case photographic, glass }

    let title: String
    var count: Int?
    var detail = ""
    let symbol: String
    let appearance: Appearance
    @ViewBuilder let cover: Cover

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if appearance == .glass {
                Color.clear.glassEffect(.regular, in: .rect(cornerRadius: DesignMetrics.defaultCornerRadius))
            }
            cover
            if appearance == .photographic {
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
            }
            Group {
                if detail.isEmpty {
                    HStack(alignment: .center, spacing: 4) {
                        titleLabel
                            .fixedSize(horizontal: false, vertical: true)
                            .layoutPriority(1)
                        Spacer(minLength: 0)
                        if let count, count > 0 {
                            LibraryCountBadgeLayout {
                                Text(count.formatted()).font(.caption.monospacedDigit())
                                    .foregroundStyle(appearance == .photographic ? Color.white : Color.primary)
                                    .fixedSize()
                                    .padding(.horizontal, count < 10 ? 0 : 6)
                                    .padding(.vertical, 3)
                            }
                            .glassEffect(.regular, in: .capsule)
                        }
                    }
                } else {
                    detailFooter
                }
            }
            .foregroundStyle(appearance == .glass ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
            .padding(12)
        }
        .aspectRatio(LibraryCollectionCardMetrics.aspectRatio, contentMode: .fit)
        .clipShape(.rect(cornerRadius: DesignMetrics.defaultCornerRadius))
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle)
    }

    private var detailFooter: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                titleLabel.fixedSize()
                Spacer(minLength: 0)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize()
            }
            VStack(alignment: .leading, spacing: 4) {
                titleLabel
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var titleLabel: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.headline)
    }

    private var accessibilityTitle: String {
        if let count {
            return count == 0 ? "\(title), empty" : "\(title), \(count.formatted())"
        }
        return detail.isEmpty ? title : "\(title), \(detail)"
    }
}

private struct LibraryCountBadgeLayout: Layout {
    func sizeThatFits(proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        return CGSize(width: max(size.width, size.height), height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: .unspecified)
    }
}

nonisolated struct LibraryCoverAsset: Identifiable, Equatable, Sendable {
    let id: String
    let revision: Date

    init(id: String, revision: Date) {
        self.id = id
        self.revision = revision
    }

    init(_ asset: TimelineAssetSummary) {
        self.init(id: asset.id, revision: asset.thumbnailRevision)
    }
}

struct LibraryAssetCover: View {
    @Environment(\.displayScale) private var scale
    let assetID: String
    let revision: Date
    let media: MediaLibraryController
    var savedPhoto: SavedPhoto?
    var preparedImage: UIImage?
    @State private var savedImage: (request: SavedPhotosLibrary.CardCoverRequest, image: UIImage)?

    var body: some View {
        let pixels = LibraryCollectionCardMetrics.coverPixels(scale: scale)
        let request = savedPhoto.map { SavedPhotosLibrary.CardCoverRequest(item: $0, pixels: pixels) }
        Group {
            if let image = preparedImage ?? (savedImage?.request == request ? savedImage?.image : nil) {
                GeometryReader { geometry in
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
            } else {
                ImmichThumbnail(descriptor: LibraryCollectionCardMetrics.coverDescriptor(.init(id: assetID, revision: revision), scale: scale),
                                media: media)
            }
        }
        .task(id: request) {
            guard preparedImage == nil, let savedPhoto, let request, savedImage?.request != request,
                  let image = try? await SavedPhotosLibrary.image(savedPhoto, pixels: pixels), !Task.isCancelled else { return }
            savedImage = (request, image)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
