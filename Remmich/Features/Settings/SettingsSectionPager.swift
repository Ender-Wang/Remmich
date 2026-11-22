import SwiftUI
import UIKit

/// The shared segmented layout for Index and Cache & Storage.
struct SettingsSectionPager<Context: View, Page: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: Int
    let title: String
    let labels: [String]
    let enabled: Bool
    let context: Context
    let page: (Int) -> Page
    @State private var origin: Int?
    @State private var offset: CGFloat = 0
    @State private var width: CGFloat = 1
    @State private var heights: [Int: CGFloat] = [:]

    init(_ title: String, labels: [String], selection: Binding<Int>, enabled: Bool,
         @ViewBuilder context: () -> Context, @ViewBuilder page: @escaping (Int) -> Page)
    {
        self.title = title
        self.labels = labels
        _selection = selection
        self.enabled = enabled
        self.context = context()
        self.page = page
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker(title, selection: Binding(get: { selection }, set: select)) {
                ForEach(labels.indices, id: \.self) { index in Text(labels[index]).tag(index) }
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
        let direction: CGFloat = selection == 0 ? -1 : selection == labels.count - 1 ? 1 : 0
        return ZStack(alignment: .topLeading) {
            ForEach(labels.indices, id: \.self) { index in
                page(index)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights[index] = $0 }
                    .clipped()
                    .offset(x: CGFloat(index - selection) * width + offset)
                    .allowsHitTesting(selection == index && origin == nil)
                    .accessibilityHidden(selection != index)
            }
        }
        .frame(height: heights[selection], alignment: .top)
        .frame(maxWidth: .infinity)
        .clipped()
        .contentShape(.rect)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = max(1, $0) }
        .gesture(IndexSectionPan(enabled: enabled && !reduceMotion, direction: direction, update: pan))
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
            let lower: CGFloat = origin == labels.count - 1 ? 0 : -width
            let upper: CGFloat = origin == 0 ? 0 : width
            offset = min(upper, max(lower, translation.x))
        case .ended:
            guard let origin else { return }
            let direction: CGFloat = (offset == 0 ? velocity.x : offset) < 0 ? -1 : 1
            let progress = HorizontalPageSwipePolicy.progress(distance: translation.x * direction, width: width)
            let finish = HorizontalPageSwipePolicy.shouldFinish(progress: progress, forwardVelocity: velocity.x * direction)
            let destination = origin - Int(direction)
            select(finish && labels.indices.contains(destination) ? destination : origin)
        case .cancelled, .failed:
            guard origin != nil else { return }
            select(selection)
        default: break
        }
    }
}
