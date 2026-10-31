import SwiftUI

enum FixtureContentState: Equatable {
    case loaded
    case loading
    case empty
    case failed
}

struct LoadingStateView: View {
    var isLoading = true
    var label = "Loading library"
    var detail: String?

    var body: some View {
        GeometryReader { geometry in
            // A newly mounted hosting controller can propose zero bounds before
            // UIKit lays it out. Do not fade in a logo centered on that origin.
            let hasLayout = geometry.size.width > 0 && geometry.size.height > 0
            RemmichLoadingOverlay(isLoading: isLoading && hasLayout, label: label, detail: detail)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
        }
        .accessibilityIdentifier("loading-state")
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
            .accessibilityIdentifier("empty-state")
    }
}

struct ErrorStateView: View {
    var title = "Couldn’t Load Library"
    var retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.icloud")
        } description: {
            Text("Check the server connection and try again.")
        } actions: {
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .accessibilityIdentifier("error-state")
    }
}
