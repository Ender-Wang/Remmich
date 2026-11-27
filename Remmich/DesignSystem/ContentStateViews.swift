import SwiftUI
import UIKit

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

struct TimelineOpeningSkeleton: View {
    @Environment(\.colorScheme) private var colorScheme
    let layout: PhotosAssetLayout

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let isPhone = UIDevice.current.userInterfaceIdiom == .phone
            let natural = layout == .naturalAspect
            let spacing: CGFloat = natural ? 8 : 2
            let columns = TimelineGridOrder.timelineColumnCount(
                availableSize: size, isPhone: isPhone, usesLargerTiles: true, spacing: spacing
            )
            let inset = TimelineGridMetrics.horizontalInset(
                naturalAspectProgress: natural ? 1 : 0, isPhone: isPhone, squareInset: 2, isDarkMode: colorScheme == .dark
            )
            let width = TimelineGridMetrics.itemWidth(rowWidth: size.width, columns: columns, spacing: spacing, horizontalInset: inset)
            let height = max(1, (size.width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
            let bottom = TimelineRangeGridLayout.minimumBottomNavigationHeight(isPhone: isPhone, viewportSize: size)
            let rows = max(1, min(14, Int(max(0, size.height - bottom) / (height + spacing))))
            VStack(alignment: .leading, spacing: spacing) {
                ForEach(0 ..< rows, id: \.self) { row in
                    if row.isMultiple(of: 4) {
                        Capsule().fill(.quaternary).frame(width: 92, height: 12)
                            .padding(.leading, 8)
                            .frame(height: 34)
                    }
                    HStack(spacing: spacing) {
                        ForEach(0 ..< columns, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: natural ? 8 : 0)
                                .fill(.quaternary)
                                .frame(width: width, height: height)
                        }
                    }
                }
            }
            .padding(.horizontal, inset)
            .padding(.bottom, bottom + 16)
            .frame(width: size.width, height: size.height, alignment: .bottomLeading)
            .clipped()
        }
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
