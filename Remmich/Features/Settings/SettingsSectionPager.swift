import SwiftUI
import UIKit

/// The shared two-section layout for Index and Cache & Storage.
struct SettingsSectionPager<Context: View, First: View, Second: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: Int
    let title: String
    let labels: (String, String)
    let enabled: Bool
    let context: Context
    let first: First
    let second: Second
    @State private var origin: Int?
    @State private var offset: CGFloat = 0
    @State private var width: CGFloat = 1
    @State private var firstHeight: CGFloat = 0
    @State private var secondHeight: CGFloat = 0

    init(_ title: String, labels: (String, String), selection: Binding<Int>, enabled: Bool,
         @ViewBuilder context: () -> Context, @ViewBuilder first: () -> First, @ViewBuilder second: () -> Second)
    {
        self.title = title
        self.labels = labels
        _selection = selection
        self.enabled = enabled
        self.context = context()
        self.first = first()
        self.second = second()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker(title, selection: Binding(get: { selection }, set: select)) {
                Text(labels.0).tag(0)
                Text(labels.1).tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.bottom, 20)
            context.padding(.bottom, 16)
            pages
        }
        .onChange(of: enabled) {
            _, enabled in if !enabled {
                select(selection)
            }
        }
    }

    private var pages: some View {
        let height = selection == 0 ? firstHeight : secondHeight
        return ZStack(alignment: .topLeading) {
            first
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { firstHeight = $0 }
                .offset(x: (selection == 0 ? 0 : -width) + offset)
                .allowsHitTesting(selection == 0 && origin == nil)
                .accessibilityHidden(selection != 0)
            second
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { secondHeight = $0 }
                .offset(x: (selection == 1 ? 0 : width) + offset)
                .allowsHitTesting(selection == 1 && origin == nil)
                .accessibilityHidden(selection != 1)
        }
        .frame(height: height > 0 ? height : nil, alignment: .top)
        .frame(maxWidth: .infinity)
        .clipped()
        .contentShape(.rect)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = max(1, $0) }
        .gesture(IndexSectionPan(enabled: enabled && !reduceMotion, direction: selection == 0 ? -1 : 1, update: pan))
    }

    private func select(_ section: Int) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
            selection = section
            origin = nil
            offset = 0
        }
    }

    private func pan(_ state: UIGestureRecognizer.State, translation: CGPoint, velocity: CGPoint) {
        switch state {
        case .began:
            origin = selection
        case .changed:
            guard let origin else { return }
            offset = origin == 0 ? max(-width, min(0, translation.x)) : min(width, max(0, translation.x))
        case .ended:
            guard let origin else { return }
            let direction: CGFloat = origin == 0 ? -1 : 1
            let progress = HorizontalPageSwipePolicy.progress(distance: translation.x * direction, width: width)
            let finish = HorizontalPageSwipePolicy.shouldFinish(progress: progress, forwardVelocity: velocity.x * direction)
            select(finish ? 1 - origin : origin)
        case .cancelled, .failed:
            guard origin != nil else { return }
            select(selection)
        default: break
        }
    }
}
