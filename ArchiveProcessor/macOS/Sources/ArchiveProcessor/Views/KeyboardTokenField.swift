import SwiftUI
import AppKit

/// A single-line, AppKit-backed text field that surfaces the keystrokes a keyboard-driven
/// autocomplete token entry needs — arrow up/down, Tab, Return, Backspace-on-empty, and Escape —
/// which a plain SwiftUI `TextField` can't intercept on macOS. The owning view keeps the suggestion
/// list + highlighted index and decides what each keystroke does. Text edits flow back via `text`.
struct KeyboardTokenField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var onMoveUp: () -> Void = {}
    var onMoveDown: () -> Void = {}
    /// Tab pressed. Return `true` if consumed (a suggestion/typed tag was committed); return `false`
    /// to let focus move on to the next control.
    var onTab: () -> Bool = { false }
    /// Return pressed. Handle it (commit a tag, or save) and return `true` to consume the event.
    var onReturn: () -> Bool = { false }
    /// Backspace pressed while the field is empty. Return `true` if consumed (e.g. removed a chip).
    var onDeleteWhenEmpty: () -> Bool = { false }
    var onEscape: () -> Void = {}
    var focusOnAppear: Bool = false

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField()
        tf.delegate = context.coordinator
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = .systemFont(ofSize: NSFont.systemFontSize)
        tf.lineBreakMode = .byTruncatingTail
        tf.cell?.wraps = false
        tf.cell?.isScrollable = true
        tf.placeholderString = placeholder
        tf.stringValue = text
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return tf
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text { nsView.stringValue = text }
        nsView.placeholderString = placeholder
        if focusOnAppear && !context.coordinator.didFocus {
            context.coordinator.didFocus = true
            DispatchQueue.main.async { [weak nsView] in
                nsView?.window?.makeFirstResponder(nsView)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: KeyboardTokenField
        var didFocus = false
        init(_ parent: KeyboardTokenField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            parent.text = tf.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMoveUp(); return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMoveDown(); return true
            case #selector(NSResponder.insertTab(_:)):
                return parent.onTab()          // true = consumed; false = allow focus to advance
            case #selector(NSResponder.insertNewline(_:)):
                return parent.onReturn()       // handled in-closure; true consumes the Return
            case #selector(NSResponder.deleteBackward(_:)):
                if control.stringValue.isEmpty { return parent.onDeleteWhenEmpty() }
                return false                   // non-empty: normal character deletion
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape(); return true
            default:
                return false
            }
        }
    }
}
