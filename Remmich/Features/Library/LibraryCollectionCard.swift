import SwiftUI

nonisolated enum LibraryCollectionCardMetrics {
    static let minimumWidth: CGFloat = 150
    static let maximumWidth: CGFloat = 260
    static let spacing: CGFloat = 14
}

/// One geometry and footer contract for every Library destination. Data loading
/// and navigation stay with the caller; a cover is just presentation content.
struct LibraryCollectionCard<Cover: View>: View {
    enum Appearance { case photographic, glass }

    let title: String
    let detail: String
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
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(title, systemImage: symbol).font(.headline).fixedSize()
                    Spacer(minLength: 0)
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Label(title, systemImage: symbol).font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(appearance == .glass ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
            .padding(12)
        }
        .aspectRatio(4 / 3, contentMode: .fit)
        .clipShape(.rect(cornerRadius: DesignMetrics.defaultCornerRadius))
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(detail)")
    }
}
