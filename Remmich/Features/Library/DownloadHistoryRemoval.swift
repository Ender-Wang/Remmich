import SwiftUI
import UIKit

/// A full-height trailing reveal, clipped with the row's section corners.
struct DownloadHistoryRemoval: ViewModifier {
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let enabled: Bool
    let isFirst: Bool
    let isLast: Bool
    let confirm: () -> Void
    let remove: () -> Void
    @State private var rowWidth: CGFloat = 0
    @State private var reveal: CGFloat = 0
    @State private var dragStart: CGFloat = 0
    private let actionWidth: CGFloat = 96

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .offset(x: reveal * direction)
            .background(alignment: .trailing) {
                if enabled, reveal > 0 {
                    Button {
                        settle(0)
                        confirm()
                    } label: {
                        Text("Remove")
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .frame(width: max(actionWidth, reveal))
                            .frame(maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(width: reveal, alignment: .trailing)
                    .background(.red)
                    .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: isLast ? 18 : 0,
                                                      topTrailingRadius: isFirst ? 18 : 0))
                    .transition(.identity)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
            .gesture(DownloadHistoryPan(enabled: enabled, direction: direction, revealed: reveal > 0) { phase, translation in
                switch phase {
                case .began:
                    dragStart = reveal
                case .changed:
                    reveal = min(rowWidth, max(0, dragStart + translation.x * direction))
                case .ended:
                    if DownloadHistorySwipePolicy.commits(translation: translation, width: rowWidth,
                                                          direction: direction, revealed: dragStart > 0)
                    {
                        remove()
                    } else {
                        settle(reveal >= actionWidth / 2 ? actionWidth : 0)
                    }
                default:
                    settle(dragStart > 0 ? actionWidth : 0)
                }
            })
            .accessibilityActions {
                if enabled {
                    Button("Remove", action: confirm)
                }
            }
            .onChange(of: enabled) { _, enabled in
                if !enabled {
                    reveal = 0; dragStart = 0
                }
            }
            .onDisappear { reveal = 0 }
    }

    private var direction: CGFloat {
        layoutDirection == .leftToRight ? -1 : 1
    }

    private func settle(_ value: CGFloat) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) { reveal = value }
    }
}

private struct DownloadHistoryPan: UIGestureRecognizerRepresentable {
    let enabled: Bool
    let direction: CGFloat
    let revealed: Bool
    let update: (UIGestureRecognizer.State, CGPoint) -> Void

    func makeCoordinator(converter _: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(direction: direction, revealed: revealed)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.isEnabled = enabled
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ pan: UIPanGestureRecognizer, context: Context) {
        if pan.isEnabled != enabled {
            pan.isEnabled = enabled
        }
        context.coordinator.direction = direction
        context.coordinator.revealed = revealed
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context _: Context) {
        update(pan.state, pan.translation(in: pan.view?.window))
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var direction: CGFloat
        var revealed: Bool
        init(direction: CGFloat, revealed: Bool) {
            self.direction = direction
            self.revealed = revealed
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view?.window)
            return (revealed || velocity.x * direction > 0) && abs(velocity.x) > abs(velocity.y) * 1.5
        }

        func gestureRecognizer(_: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

nonisolated enum DownloadHistorySwipePolicy {
    static func commits(translation: CGPoint, width: CGFloat, direction: CGFloat, revealed: Bool = false) -> Bool {
        // A second drag starts from an already shifted row.
        width > 0 && translation.x * direction >= max(revealed ? 120 : 180, width * (revealed ? 0.45 : 0.75))
            && abs(translation.x) > abs(translation.y) * 1.5
    }
}
