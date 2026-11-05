import AppKit

/// ⌘Z belongs to a focused text field first (W40.fix-reader-undo-focus; suspect S-001).
///
/// Tags ▸ Undo Tag Change carries ⌘Z, and a menu key equivalent is matched before the field editor ever
/// sees the key, so with the caret in the file-name filter, the OCR search, the find field or a tag token
/// field, ⌘Z re-wrote Finder tags on the last-edited files and left the typing (owner session reader-1,
/// rows 32 and 37). A local key-down monitor runs before menu matching: while an editable text view has
/// the key window's keyboard, a bare ⌘Z undoes that text and is consumed. Undo Tag Change is then reached
/// only from the list or the document panes, or by choosing it from the menu with the mouse.
@MainActor
enum TextUndoGuard {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            nonisolated(unsafe) let event = event   // local monitors run on the main thread
            return MainActor.assumeIsolated { undoText(for: event) } ? nil : event
        }
    }

    /// Undo the typing `event` belongs to, if it is a text field's ⌘Z; true when the event was consumed.
    private static func undoText(for event: NSEvent) -> Bool {
        guard let text = editingTextView(for: event, in: NSApp.keyWindow) else { return false }
        // The text's own undo, or nothing: ⌘Z with no typing to undo must still not fall through to the tag undo.
        if let undo = text.undoManager, undo.canUndo { undo.undo() } else { NSSound.beep() }
        return true
    }

    /// The editable text view that should take `event` as its own undo, or nil when the event is not a
    /// bare ⌘Z or no text has the keyboard (the list, a PDF pane, nothing at all).
    static func editingTextView(for event: NSEvent, in window: NSWindow?) -> NSTextView? {
        guard event.type == .keyDown,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]) == .command,
              event.charactersIgnoringModifiers?.lowercased() == "z",
              let text = window?.firstResponder as? NSTextView, text.isEditable else { return nil }
        return text
    }
}
