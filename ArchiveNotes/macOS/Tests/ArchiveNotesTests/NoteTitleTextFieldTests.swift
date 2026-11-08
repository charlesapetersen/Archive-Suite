import AppKit
import Testing
@testable import ArchiveNotes

@Suite("Inline note title editing")
@MainActor
struct NoteTitleTextFieldTests {
    @Test("Escape, blank, unchanged, and rejected titles do not leave a draft; Return trims and commits once")
    func commitAndCancel() {
        let field = NoteTitleTextField(labelWithString: "⧉ Original")
        field.noteTitle = "Original"
        var commits: [String] = []
        field.onCommit = { title, completion in commits.append(title); completion(true) }
        let editor = NSTextView()
        field.beginRename()
        #expect(field.stringValue == "Original", "display glyph is never part of the title draft")
        field.stringValue = "Cancelled"
        field.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(field.stringValue == "⧉ Original" && commits.isEmpty)
        for title in [" \n ", "Original"] {
            field.beginRename()
            field.stringValue = title
            field.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            field.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
            #expect(commits.isEmpty)
        }
        field.beginRename()
        field.stringValue = "  New Title  "
        field.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        field.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        #expect(commits == ["New Title"])
        #expect(!field.isRenaming && !field.isEditable)

        field.stringValue = "Original"
        field.onCommit = { title, completion in commits.append(title); completion(false) }
        field.beginRename()
        field.stringValue = "Cannot Save"
        field.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        field.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        #expect(field.stringValue == "Original")
        #expect(commits == ["New Title", "Cannot Save"])
    }

    @Test("The header's title starts an edit on press; a list cell's does not")
    func headerTitleBeginsOnPress() {
        let header = NoteTitleTextField(labelWithString: "Original")
        header.noteTitle = "Original"
        header.beginsOnClick = true
        #expect(header.accessibilityPerformPress())
        #expect(header.isRenaming && header.isEditable)

        let cell = NoteTitleTextField(labelWithString: "Original")
        _ = cell.accessibilityPerformPress()
        #expect(!cell.isRenaming && !cell.isEditable)
    }
}
