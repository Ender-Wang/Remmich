import SwiftUI
import UIKit

struct NativeSegmentedControl<Choice: CaseIterable & Equatable & RawRepresentable>: UIViewRepresentable where Choice.RawValue == String {
    @Binding var selection: Choice
    let accessibilityIdentifier: String

    func makeUIView(context: Context) -> UISegmentedControl {
        let control = UISegmentedControl(items: Choice.allCases.map(\.rawValue))
        control.accessibilityIdentifier = accessibilityIdentifier
        control.addAction(UIAction { [weak control, weak coordinator = context.coordinator] _ in
            if let control {
                coordinator?.select(on: control)
            }
        }, for: .valueChanged)
        return control
    }

    func updateUIView(_ control: UISegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.updateSelection(on: control)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISegmentedControl, context _: Context) -> CGSize? {
        let intrinsic = uiView.intrinsicContentSize
        return CGSize(width: proposal.width ?? intrinsic.width, height: proposal.height ?? intrinsic.height)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    final class Coordinator {
        private let choices = Array(Choice.allCases)
        var selection: Binding<Choice>

        init(selection: Binding<Choice>) {
            self.selection = selection
        }

        func select(on control: UISegmentedControl) {
            let index = control.selectedSegmentIndex
            guard choices.indices.contains(index) else { return }
            selection.wrappedValue = choices[index]
            // A page transition can reject another selection until it settles.
            updateSelection(on: control)
        }

        func updateSelection(on control: UISegmentedControl) {
            control.selectedSegmentIndex = choices.firstIndex(of: selection.wrappedValue) ?? UISegmentedControl.noSegment
        }
    }
}
