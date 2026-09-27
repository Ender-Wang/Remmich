import SwiftUI

enum FixtureContentState: Equatable {
    case loaded
    case loading
    case empty
    case failed
}

struct LoadingStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading your library…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    var retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn’t Load Library", systemImage: "exclamationmark.icloud")
        } description: {
            Text("Check the server connection and try again.")
        } actions: {
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .accessibilityIdentifier("error-state")
    }
}
