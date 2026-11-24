import SwiftUI
import UIKit

@MainActor
final class SearchInputFocus {
    weak var field: UITextField?
    private var pending = false

    func request() {
        pending = true
        activateIfAttached()
    }

    func activateIfAttached() {
        guard pending, let field, field.window != nil else { return }
        pending = false
        field.becomeFirstResponder()
    }

    func dismiss() {
        pending = false
        field?.resignFirstResponder()
    }
}

struct SearchTextField: UIViewRepresentable {
    @Binding var text: String
    let prompt: String
    let focus: SearchInputFocus
    let editingChanged: (Bool) -> Void
    let submit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextField {
        let field = WindowAwareTextField()
        field.focus = focus
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.returnKeyType = .search
        field.autocorrectionType = .no
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.accessibilityIdentifier = "search-query"
        field.accessibilityLabel = "Search query"
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        focus.field = field
        return field
    }

    private final class WindowAwareTextField: UITextField {
        weak var focus: SearchInputFocus?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            Task { @MainActor [weak self] in
                self?.focus?.activateIfAttached()
            }
        }
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.markedTextRange == nil, field.text != text {
            field.text = text
        }
        field.placeholder = prompt
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: SearchTextField

        init(parent: SearchTextField) {
            self.parent = parent
        }

        @objc func textChanged(_ field: UITextField) {
            guard field.markedTextRange == nil else { return }
            parent.text = field.text ?? ""
        }

        func textFieldDidBeginEditing(_: UITextField) {
            parent.editingChanged(true)
        }

        func textFieldDidEndEditing(_ field: UITextField) {
            textChanged(field)
            parent.editingChanged(false)
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            guard field.markedTextRange == nil else { return true }
            textChanged(field)
            field.resignFirstResponder()
            parent.submit()
            return false
        }
    }
}

struct SearchScanButton: UIViewRepresentable {
    let focus: SearchInputFocus
    let unavailable: () -> Void

    func makeUIView(context _: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "text.viewfinder"), for: .normal)
        button.tintColor = .label
        button.accessibilityLabel = "Scan Text"
        button.accessibilityIdentifier = "search-scan"
        button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(children: [UIAction(title: "Scan Text", image: UIImage(systemName: "text.viewfinder")) { [weak focus] _ in
            guard let field = focus?.field, field.window != nil else { return }
            let wasEditing = field.isFirstResponder
            if !wasEditing, !field.becomeFirstResponder() {
                unavailable()
                return
            }
            Task { @MainActor [weak field] in
                guard let field, field.isFirstResponder else { return }
                guard field.canPerformAction(#selector(UIResponder.captureTextFromCamera(_:)), withSender: nil) else {
                    if !wasEditing {
                        field.resignFirstResponder()
                    }
                    unavailable()
                    return
                }
                field.captureTextFromCamera(nil)
            }
        }])
        return button
    }

    func updateUIView(_: UIButton, context _: Context) {}
}
