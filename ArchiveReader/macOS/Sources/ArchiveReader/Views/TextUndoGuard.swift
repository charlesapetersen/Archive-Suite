import AppKit

/// ⌘Z belongs to a focused text field first (W40.fix-reader-undo-focus; suspect S-001).
///
/// Tags ▸ Undo Tag Change carries ⌘Z, and a menu key equivalent is matched before the field editor ever
/// sees the key, so with the caret in the file-name filter, the OCR search, the find field or a tag token
/// field, ⌘Z re-wrote Finder tags on the last-edited files and left the typing (owner session reader-1,
/// rows 32 and 37). A local key-down monitor runs before menu matching: while an editable text view has
/// the key window's keyboard, a bare ⌘Z undoes that text and is consumed. Undo Tag Change is then reached
/// only from the list or the document panes, or by choosing it from the menu with the mouse.
/// ⇧⌘Z and Redo Tag Change are guarded the same way (W40.fix-reader-redo).
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

    /// Undo (⌘Z) or redo (⇧⌘Z) the typing `event` belongs to, if it is a text field's; true when the
    /// event was consumed.
    private static func undoText(for event: NSEvent) -> Bool {
        guard let text = editingTextView(for: event, in: NSApp.keyWindow) else { return false }
        let redo = isRedo(event)
        // The text's own undo, or nothing: ⌘Z with no typing to undo must still not fall through to the tag undo.
        // Not mid-composition (the input method owns the marked text), and not in text that keeps no undo of
        // its own, whose `undoManager` is the window's and could hold someone else's actions.
        if text.allowsUndo, !text.hasMarkedText(), let undo = text.undoManager, redo ? undo.canRedo : undo.canUndo {
            if redo { undo.redo() } else { undo.undo() }
        } else {
            NSSound.beep()
        }
        return true
    }

    /// The editable text view that should take `event` as its own undo or redo, or nil when the event is
    /// not a bare ⌘Z or ⇧⌘Z or no text has the keyboard (the list, a PDF pane, nothing at all).
    static func editingTextView(for event: NSEvent, in window: NSWindow?) -> NSTextView? {
        guard event.type == .keyDown,
              modifiers(event) == .command || isRedo(event),
              // Either reading: a "… – QWERTY ⌘" layout gives the menu's "z" only with ⌘ applied.
              event.charactersIgnoringModifiers?.lowercased() == "z" || event.characters?.lowercased() == "z",
              let text = window?.firstResponder as? NSTextView, text.isEditable else { return nil }
        return text
    }

    private static func modifiers(_ event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
    }

    private static func isRedo(_ event: NSEvent) -> Bool { modifiers(event) == [.command, .shift] }
}
