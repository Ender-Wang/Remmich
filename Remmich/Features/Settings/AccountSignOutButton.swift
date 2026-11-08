import SwiftUI

/// Keep the source rectangle on the actual button, before any row-wide frame.
/// SwiftUI content avoids the native alert's conflicting minimum-width layout.
struct AccountSignOutButton<Label: View>: View {
    let action: (Bool) -> Void
    @ViewBuilder let label: () -> Label
    @State private var isPresented = false

    var body: some View {
        Button(role: .destructive) { isPresented = true } label: { label() }
            .popover(isPresented: $isPresented, attachmentAnchor: .rect(.bounds),
                     content: AccountSignOutPresentation.content(confirmation))
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sign Out").font(.headline).accessibilityAddTraits(.isHeader)
            Text("Keeping local data lets this account resume without rebuilding its index and cached thumbnails.")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            choice("Sign Out and Keep Local Data", deleteData: false)
            choice("Sign Out and Delete Local Data", deleteData: true)
            Button("Cancel") { isPresented = false }
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .foregroundStyle(.primary)
        .padding(20)
        .frame(width: 320)
        .presentationCompactAdaptation(.popover)
    }

    private func choice(_ title: String, deleteData: Bool) -> some View {
        Button(role: deleteData ? .destructive : nil) {
            isPresented = false
            action(deleteData)
        } label: {
            Text(title).font(.subheadline.weight(.semibold))
                .foregroundStyle(deleteData ? Color.red : Color.primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
    }
}

nonisolated enum AccountSignOutPresentation {
    /// SwiftUI can invoke this factory on AsyncRenderer during popover teardown.
    /// Build the view/actions on MainActor first; this closure only returns the value.
    static func content<Content>(_ content: Content) -> () -> Content {
        { content }
    }
}
