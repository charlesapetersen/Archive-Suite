import AppKit
import SwiftUI

/// Keep a separate undo step for each edit to the live file-name filter instead of the standard
/// cell's single editing-session undo, which made the whole query disappear on the first ⌘Z.
struct FilenameFilterField: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> FilenameFilterTextField {
        let field = FilenameFilterTextField()
        field.bezelStyle = .roundedBezel
        field.isBezeled = true
        field.drawsBackground = true
        field.controlSize = .large
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .large))
        field.placeholderString = "Filter file name…"
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel("Filter file name")
        field.setAccessibilityIdentifier("ar.filter.name")
        updateNSView(field, context: context)
        return field
    }

    func updateNSView(_ field: FilenameFilterTextField, context: Context) {
        field.onChange = { text = $0 }
        field.synchronize(text)
    }
}

final class FilenameFilterTextField: NSTextField {
    var onChange: ((String) -> Void)?

    override class var cellClass: AnyClass? {
        get { FilenameFilterCell.self }
        set { }
    }

    func synchronize(_ text: String) {
        // A binding echo or a debounce/list refresh must not replace the field editor's text:
        // assigning stringValue during typing discards its undo history and caret position.
        if stringValue != text {
            (cell as? FilenameFilterCell)?.editor.undoManager?.removeAllActions()
            stringValue = text
        }
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        onChange?(stringValue)
    }
}

/// NSTextField's shared editor uses NSCellUndoManager, which keeps one editing-session undo.
/// A private native editor gives this live filter a normal text undo stack, isolated from other fields.
private final class FilenameFilterCell: NSTextFieldCell {
    let editor = FilenameFilterEditor()

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        editor.isFieldEditor = true
        editor.allowsUndo = true
        return editor
    }
}

private final class FilenameFilterEditor: NSTextView {
    private lazy var history = FilenameFilterUndoManager(editor: self)
    override var undoManager: UndoManager? { history }

    override func didChangeText() {
        super.didChangeText()
        // AppKit finishes registering typing after this callback. Break coalescing on the next
        // turn, keeping marked text and the input method's own composition behavior intact.
        if !hasMarkedText() {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.hasMarkedText() else { return }
                self.breakUndoCoalescing()
            }
        }
    }
}

private final class FilenameFilterUndoManager: UndoManager {
    private weak var editor: NSTextView?

    init(editor: NSTextView) {
        self.editor = editor
        super.init()
    }

    // TextUndoGuard invokes the manager directly. Native text undo changes the storage without
    // the field-editor change notification, so publish the resulting filter through its normal path.
    override func undo() {
        super.undo()
        editor?.didChangeText()
    }

    override func redo() {
        super.redo()
        editor?.didChangeText()
    }
}
