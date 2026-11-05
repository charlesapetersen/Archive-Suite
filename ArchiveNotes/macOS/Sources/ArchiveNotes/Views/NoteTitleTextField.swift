import AppKit

/// A table title is a label until an explicit Rename gesture. Commit captures the item identity in
/// the cell's closure, never a row number that could change under sorting. Escape is a true no-write.
@MainActor
final class NoteTitleTextField: NSTextField, NSTextFieldDelegate {
    var noteTitle = ""
    /// The completion reports whether the model durably accepted this edit. A failed save restores
    /// the original display, but only while this recycled cell still represents the same item.
    var onCommit: ((String, @escaping @MainActor (Bool) -> Void) -> Void)?
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    var itemID: UUID?
    private var originalDisplay = NSAttributedString()
    private(set) var isRenaming = false
    private var cancelled = false
    private var renameID = UUID()
    private var renamingItemID: UUID?
    /// The detail header's title starts an edit on a click; a list cell waits for Return, a double-click
    /// or Rename… (a click there selects the row).
    var beginsOnClick = false

    func beginRename() {
        guard !isRenaming else { return }
        originalDisplay = attributedStringValue
        renameID = UUID()
        renamingItemID = itemID
        isRenaming = true
        cancelled = false
        onBegin?()
        stringValue = noteTitle // no replicated-item glyph or “Untitled” placeholder in the draft
        isEditable = true
        isSelectable = true
        delegate = self
        selectText(nil)
    }

    override func mouseDown(with event: NSEvent) {
        if beginsOnClick && !isRenaming { beginRename(); return }
        super.mouseDown(with: event)
    }

    override func accessibilityPerformPress() -> Bool {
        guard beginsOnClick, !isRenaming else { return super.accessibilityPerformPress() }
        beginRename()
        return true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            cancelled = true
            returnKeyboardToList()
            finishRename()
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            returnKeyboardToList()
            finishRename()
            return true
        }
        return false
    }

    /// The cell view refuses first responder, so handing it the keyboard left it with the window and the
    /// list looked deselected; the table takes it, and arrow keys and Return go on working there.
    private func returnKeyboardToList() {
        var view = superview
        while let candidate = view, !(candidate is NSTableView) { view = candidate.superview }
        window?.makeFirstResponder(view ?? superview)
    }

    func controlTextDidEndEditing(_ notification: Notification) { finishRename() }

    private func finishRename() {
        guard isRenaming else { return }
        let title = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        isRenaming = false
        isEditable = false
        isSelectable = false
        if cancelled || title.isEmpty || title == noteTitle {
            attributedStringValue = originalDisplay
        } else {
            let savedDisplay = originalDisplay
            let editID = renameID
            let editItemID = renamingItemID
            guard let onCommit else {
                attributedStringValue = savedDisplay
                onEnd?()
                return
            }
            onCommit(title) { [weak self] saved in
                guard let self, !self.isRenaming, self.renameID == editID,
                      self.itemID == editItemID else { return }
                if !saved { self.attributedStringValue = savedDisplay }
            }
        }
        onEnd?()
    }
}
