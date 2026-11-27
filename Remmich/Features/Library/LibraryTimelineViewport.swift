import SwiftUI
import UIKit

struct LibraryTimelineViewport<Header: View, Timeline: View>: View {
    @Environment(\.layoutDirection) private var layoutDirection
    @ViewBuilder let timeline: (EdgeInsets) -> Timeline
    @ViewBuilder let header: () -> Header
    @State private var headerHeight: CGFloat = 0

    var body: some View {
        GeometryReader { safe in
            let safeFrame = safe.frame(in: .global)
            ZStack(alignment: .top) {
                GeometryReader { full in
                    let fullFrame = full.frame(in: .global)
                    let left = max(0, safeFrame.minX - fullFrame.minX)
                    let right = max(0, fullFrame.maxX - safeFrame.maxX)
                    let clearance = EdgeInsets(top: max(0, safeFrame.minY - fullFrame.minY) + headerHeight,
                                               leading: layoutDirection == .leftToRight ? left : right,
                                               bottom: max(0, fullFrame.maxY - safeFrame.maxY),
                                               trailing: layoutDirection == .leftToRight ? right : left)
                    timeline(clearance)
                }
                .ignoresSafeArea(.container, edges: .all)
                header()
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        if abs(headerHeight - height) > 0.5 {
                            headerHeight = height
                        }
                    }
            }
        }
    }
}

struct LibraryTimelineMediaSelector: View {
    @Binding var selection: SavedPhotosMedia
    let accessibilityIdentifier: String

    var body: some View {
        NativeSegmentedControl(selection: $selection, accessibilityIdentifier: accessibilityIdentifier)
            .frame(height: MainTabHeaderMetrics.controlSize)
            .frame(maxWidth: MainTabHeaderMetrics.segmentedControlMaximumWidth)
            .glassEffect(.regular, in: .capsule)
            .fixedSize(horizontal: UIDevice.current.userInterfaceIdiom == .phone, vertical: false)
    }
}
