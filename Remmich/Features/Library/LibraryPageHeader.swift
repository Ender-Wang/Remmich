import SwiftUI

/// This header travels with the detail page during the native card zoom.
struct LibraryPageHeader<Trailing: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let backLabel: String
    let back: (() -> Void)?
    let trailing: Trailing

    init(title: String, backLabel: String = "Back", back: (() -> Void)? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.backLabel = backLabel
        self.back = back
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                if let back {
                    back()
                } else {
                    dismiss()
                }
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel(backLabel)

            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)

            Color.clear.frame(width: 44, height: 44)
                .overlay { trailing }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

extension View {
    func libraryPageHeader(_ title: String, backLabel: String = "Back", back: (() -> Void)? = nil) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            LibraryPageHeader(title: title, backLabel: backLabel, back: back) { EmptyView() }
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}
