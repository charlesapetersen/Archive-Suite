import AppKit

/// A table title is a label until an explicit Rename gesture. Commit captures the item identity in
/// the cell's closure, never a row number that could change under sorting. Escape is a true no-write.
/// The list's Date cell is one too (W40.notes-detail-layout): `noteTitle` is then the date as typed, and an
/// emptied field commits, since it clears the date.
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
    /// Only a text-change notification supplies a draft. AppKit can reset the control's value
    /// while handing its shared field editor back; that is never a request to clear a date.
    private var editedText: String?
    /// The detail header's title starts an edit on a click; a list cell waits for Return, a double-click
    /// or Rename… (a click there selects the row).
    var beginsOnClick = false
    /// Whether an emptied field commits (the Date cell, which it clears) rather than putting the text back (a title).
    var commitsEmpty = false

    func beginRename() {
        guard !isRenaming else { return }
        originalDisplay = attributedStringValue
        renameID = UUID()
        renamingItemID = itemID
        isRenaming = true
        cancelled = false
        editedText = nil
        onBegin?()
        stringValue = noteTitle // no replicated-item glyph or “Untitled” placeholder in the draft
        isEditable = true
        isSelectable = true
        delegate = self
        selectText(nil)
    }

    /// A field taken away mid-edit (the header when the detail empties, a cell scrolled out) ends the edit
    /// first, so the draft is saved like a click elsewhere rather than dropped.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, isRenaming, let window, let editor = currentEditor(),
           window.firstResponder === editor {
            window.makeFirstResponder(nil)
        }
        super.viewWillMove(toWindow: newWindow)
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

    func controlTextDidChange(_ notification: Notification) {
        guard isRenaming else { return }
        editedText = currentEditor()?.string ?? stringValue
    }

    private func finishRename() {
        guard isRenaming else { return }
        let title = (editedText ?? noteTitle).trimmingCharacters(in: .whitespacesAndNewlines)
        isRenaming = false
        isEditable = false
        isSelectable = false
        if cancelled || editedText == nil || (title.isEmpty && !commitsEmpty) || title == noteTitle {
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
