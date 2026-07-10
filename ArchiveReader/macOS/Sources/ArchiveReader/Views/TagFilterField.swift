import SwiftUI
import AppKit

/// A tag-filter entry field with native autocomplete. Wraps `NSComboBox` for inline completion
/// (type "Jer" → "Jerry Brown") plus a dropdown of existing tags. Committing (Return, or picking a
/// row) calls `onAdd` with the chosen/typed tag and clears the field. Read-only over the tag set —
/// it never writes anything; it only feeds the in-memory `LibraryFilter`.
struct TagFilterField: NSViewRepresentable {
    var placeholder: String
    var suggestions: [String]
    var focusToken: Int = 0        // bump to request keyboard focus (⌘L)
    var onAdd: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onAdd: onAdd) }

    func makeNSView(context: Context) -> NSComboBox {
        let cb = NSComboBox()
        cb.completes = true                 // inline autocomplete as you type
        cb.hasVerticalScroller = true
        cb.numberOfVisibleItems = 10
        cb.placeholderString = placeholder
        cb.delegate = context.coordinator
        cb.target = context.coordinator
        cb.action = #selector(Coordinator.commit(_:))   // fires on Return
        cb.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        cb.controlSize = .regular
        return cb
    }

    func updateNSView(_ cb: NSComboBox, context: Context) {
        context.coordinator.onAdd = onAdd
        if context.coordinator.items != suggestions {   // refresh completions only when they change
            context.coordinator.items = suggestions
            cb.removeAllItems()
            cb.addItems(withObjectValues: suggestions)
        }
        cb.placeholderString = placeholder
        if focusToken != context.coordinator.lastFocusToken {   // ⌘L requested focus
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async { [weak cb] in cb?.window?.makeFirstResponder(cb) }
        }
    }

    @MainActor final class Coordinator: NSObject, NSComboBoxDelegate {
        var onAdd: (String) -> Void
        var items: [String] = []
        var lastFocusToken = 0
        init(onAdd: @escaping (String) -> Void) { self.onAdd = onAdd }

        @objc func commit(_ sender: NSComboBox) {
            let v = sender.stringValue.trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty else { return }
            onAdd(v)
            sender.stringValue = ""
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            // Only commit on a deliberate MOUSE pick from the dropdown. This notification ALSO fires while
            // arrow-browsing the list; committing then would add a filter and clear the field on every
            // keystroke. Keyboard navigation commits instead via commit(_:) (the Return action selector).
            guard let e = NSApp.currentEvent, e.type == .leftMouseUp || e.type == .leftMouseDown else { return }
            guard let cb = notification.object as? NSComboBox else { return }
            let idx = cb.indexOfSelectedItem
            guard idx >= 0, idx < items.count else { return }
            let picked = items[idx]
            // Defer so the pick registers before we clear the field.
            DispatchQueue.main.async { [weak cb] in self.onAdd(picked); cb?.stringValue = "" }
        }
    }
}
