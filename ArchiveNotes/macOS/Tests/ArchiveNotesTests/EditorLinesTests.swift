import Testing
import AppKit
@testable import ArchiveNotes

/// W40.fix-notes-editor-lines — Return, Backspace and the list toggles in the styled editor, typed through the
/// real `EditorTextView` and checked across a reselect: the note's Markdown is saved, parsed back into the editor
/// (what selecting the note again does, `MarkdownEditorView.updateNSView`) and typed into again. Owner session
/// notes-1, rows 8 and 10: Return would not add a second blank line, Backspace would not delete a line break, and
/// Bulleted List showed nothing.
@Suite("EditorLinesTests — W40.fix-notes-editor-lines")
@MainActor
struct EditorLinesTests {

    private func editor(_ markdown: String) throws -> (EditorTextView, NSTextStorage) {
        let tv = EditorTextView()
        let storage = try #require(tv.textStorage)
        storage.setAttributedString(MarkdownBridge.parse(markdown: markdown))
        tv.setSelectedRange(NSRange(location: storage.length, length: 0))
        return (tv, storage)
    }

    private func type(_ tv: EditorTextView, _ text: String) {
        tv.insertText(text, replacementRange: tv.selectedRange())
    }

    /// Save and select the note again: the editor holds what the saved Markdown reads back as, caret at the end.
    @discardableResult
    private func reselect(_ tv: EditorTextView, _ storage: NSTextStorage) -> String {
        let saved = MarkdownBridge.serialize(storage)
        tv.replaceStyledDocument(with: MarkdownBridge.parse(markdown: saved))
        tv.setSelectedRange(NSRange(location: storage.length, length: 0))
        return saved
    }

    private func caret(_ tv: EditorTextView, at location: Int) {
        tv.setSelectedRange(NSRange(location: location, length: 0))
    }

    // MARK: - Return

    /// The owner's row 8: Return pressed on the empty last line did nothing. Reading the paragraph's kind at the
    /// end of the text raised, and AppKit swallowed it.
    @Test func returnOnTheEmptyLastLineAddsALine() throws {
        let (tv, storage) = try editor("A")
        tv.insertNewline(nil)
        tv.insertNewline(nil)
        tv.insertNewline(nil)
        #expect(storage.string == "A\n\n\n")
        type(tv, "B")
        #expect(storage.string == "A\n\n\nB")
    }

    /// Every count of Returns comes back after a reselect as it was typed, and the save settles.
    @Test func returnsAreKeptAcrossAReselect() throws {
        for count in 1...5 {
            let (tv, storage) = try editor("A")
            for _ in 0..<count { tv.insertNewline(nil) }
            type(tv, "B")
            let typed = storage.string
            let saved = reselect(tv, storage)
            #expect(storage.string == typed, "\(count) Returns: reopened \(storage.string.debugDescription), saved \(saved.debugDescription)")
            #expect(MarkdownBridge.serialize(storage) == saved, "\(count) Returns: a reopened note must save the same")
        }
    }

    @Test func oneReturnIsALineBreakAndTwoAParagraph() throws {
        var (tv, storage) = try editor("A")
        tv.insertNewline(nil); type(tv, "B")
        #expect(MarkdownBridge.serialize(storage) == "A\\\nB")
        (tv, storage) = try editor("A")
        tv.insertNewline(nil); tv.insertNewline(nil); type(tv, "B")
        #expect(MarkdownBridge.serialize(storage) == "A\n\nB")
        (tv, storage) = try editor("A")
        tv.insertNewline(nil); tv.insertNewline(nil); tv.insertNewline(nil); type(tv, "B")
        #expect(MarkdownBridge.serialize(storage) == "A\n\n\\\nB")
    }

    /// Type, reselect, type again, reselect: the owner's sequence, with Returns added after the reload.
    @Test func typeReselectTypeAgain() throws {
        let (tv, storage) = try editor("First paragraph.")
        tv.insertNewline(nil); tv.insertNewline(nil)
        type(tv, "Second.")
        reselect(tv, storage)
        #expect(storage.string == "First paragraph.\n\nSecond.")
        // A blank line more between the two, then more lines at the end.
        caret(tv, at: ("First paragraph." as NSString).length)
        tv.insertNewline(nil)
        caret(tv, at: storage.length)
        tv.insertNewline(nil); tv.insertNewline(nil); tv.insertNewline(nil)
        type(tv, "Third.")
        let expected = "First paragraph.\n\n\nSecond.\n\n\nThird."
        #expect(storage.string == expected)
        reselect(tv, storage)
        #expect(storage.string == expected, "reopened \(storage.string.debugDescription)")
        reselect(tv, storage)
        #expect(storage.string == expected)
    }

    // MARK: - Backspace

    /// The owner's row 8: Backspace on the empty last line did nothing.
    @Test func backspaceOnTheEmptyLastLineDeletesTheLineBreak() throws {
        let (tv, storage) = try editor("A")
        tv.insertNewline(nil); tv.insertNewline(nil)
        tv.deleteBackward(nil)
        #expect(storage.string == "A\n")
        tv.deleteBackward(nil)
        #expect(storage.string == "A")
    }

    /// A blank line read from the file, deleted with Backspace, stays deleted after a reselect; a second
    /// Backspace joins the lines.
    @Test func backspaceDeletesABlankLineForGood() throws {
        let (tv, storage) = try editor("A\n\nB")
        #expect(storage.string == "A\n\nB")
        caret(tv, at: 3)
        tv.deleteBackward(nil)
        #expect(storage.string == "A\nB")
        let saved = reselect(tv, storage)
        #expect(saved == "A\\\nB")
        #expect(storage.string == "A\nB", "the deleted blank line came back: \(storage.string.debugDescription)")
        caret(tv, at: 2)
        tv.deleteBackward(nil)
        #expect(storage.string == "AB")
        #expect(reselect(tv, storage) == "AB")
        #expect(storage.string == "AB")
    }

    /// A line of text after a heading: Return at the heading's end starts text, it is shown and kept one line
    /// below, and Backspace joins it to the heading for good.
    @Test func returnAndBackspaceAfterAHeading() throws {
        let (tv, storage) = try editor("# Title")
        tv.insertNewline(nil)
        type(tv, "Body")
        #expect(MarkdownBridge.serialize(storage) == "# Title\n\nBody")
        reselect(tv, storage)
        #expect(storage.string == "Title\nBody")
        caret(tv, at: 6)
        tv.deleteBackward(nil)
        #expect(reselect(tv, storage) == "# TitleBody")
        #expect(storage.string == "TitleBody")
    }

    /// The same in the middle of a note: Return at a heading's end, or a list item's, opens a line between it and
    /// what follows, and that line is kept.
    @Test func returnBetweenBlocksInTheMiddleOfANote() throws {
        var (tv, storage) = try editor("# Title\n\nBody")
        caret(tv, at: 5)
        tv.insertNewline(nil); type(tv, "New")
        #expect(storage.string == "Title\nNew\nBody")
        #expect(reselect(tv, storage) == "# Title\n\nNew\\\nBody")
        #expect(storage.string == "Title\nNew\nBody")
        (tv, storage) = try editor("- a\n\nBody")
        caret(tv, at: 1)
        tv.insertNewline(nil); type(tv, "b")
        #expect(reselect(tv, storage) == "- a\n- b\n\nBody")
        #expect(storage.string == "a\nb\nBody")
    }

    // MARK: - Lists

    /// The owner's row 10: Bulleted List on an empty last line made nothing, and the next keystroke was text.
    @Test func bulletedListOnTheEmptyLastLine() throws {
        let (tv, storage) = try editor("A")
        tv.insertNewline(nil); tv.insertNewline(nil)
        EditorFormatting.toggleUnorderedList(tv, fontSize: 14)
        #expect(ListMarkers.trailingMarker(in: storage, typingAttributes: tv.typingAttributes,
                                           caret: tv.selectedRange())?.text == "•")
        #expect(EditorFormatting.currentState(for: tv).blockKind == .listItem(ordered: false, depth: 0, ordinal: 1))
        type(tv, "one")
        tv.insertNewline(nil)
        type(tv, "two")
        #expect(MarkdownBridge.serialize(storage) == "A\n\n- one\n- two")
        reselect(tv, storage)
        #expect(ListMarkers.markers(in: storage, range: NSRange(location: 0, length: storage.length)).map(\.text) == ["•", "•"])
    }

    @Test func bulletedListInAnEmptyNote() throws {
        let (tv, storage) = try editor("")
        EditorFormatting.toggleUnorderedList(tv, fontSize: 14)
        type(tv, "x")
        #expect(MarkdownBridge.serialize(storage) == "- x")
    }

    /// The toggle on a line with text, through `FormattingContext` (what ⇧⌘U, the menu and the toolbar call).
    @Test func bulletedListOnALineWithText() throws {
        let (tv, storage) = try editor("A\n\nB")
        let context = FormattingContext()
        context.textView = tv
        caret(tv, at: storage.length)
        context.toggleUnorderedList()
        #expect(MarkdownBridge.serialize(storage) == "A\n\n- B")
        #expect(ListMarkers.markers(in: storage, range: NSRange(location: 0, length: storage.length))
            == [ListMarkers.Marker(location: 3, text: "•", depth: 0)])
        context.toggleUnorderedList()
        #expect(MarkdownBridge.serialize(storage) == "A\n\nB")
        #expect(ListMarkers.markers(in: storage, range: NSRange(location: 0, length: storage.length)).isEmpty)
    }

    /// Return on an empty item leaves the list; what follows is text, one line below, after a reselect too.
    @Test func leavingAListWithReturn() throws {
        let (tv, storage) = try editor("- a")
        tv.insertNewline(nil); type(tv, "b")
        tv.insertNewline(nil); tv.insertNewline(nil)
        #expect(ListMarkers.trailingMarker(in: storage, typingAttributes: tv.typingAttributes,
                                           caret: tv.selectedRange()) == nil)
        type(tv, "after")
        let saved = reselect(tv, storage)
        #expect(saved == "- a\n- b\n\nafter")
        #expect(storage.string == "a\nb\nafter")
        // Backspace at the start of "after" joins it to the item above, and it stays there.
        caret(tv, at: 4)
        tv.deleteBackward(nil)
        #expect(reselect(tv, storage) == "- a\n- bafter")
    }

    @Test func numberedMarkersCountFromTheFirst() throws {
        let (tv, storage) = try editor("3. a\n4. b")
        #expect(ListMarkers.markers(in: storage, range: NSRange(location: 0, length: storage.length)).map(\.text)
            == ["3.", "4."])
        tv.insertNewline(nil)
        #expect(ListMarkers.trailingMarker(in: storage, typingAttributes: tv.typingAttributes,
                                           caret: tv.selectedRange())?.text == "5.")
        type(tv, "c")
        // Mid-list: the scan starts at the list's first item.
        #expect(ListMarkers.markers(in: storage, range: NSRange(location: 4, length: 0)).map(\.text) == ["5."])
        #expect(MarkdownBridge.serialize(storage) == "3. a\n4. b\n5. c")
    }

    @Test func nestedMarkers() throws {
        let (_, storage) = try editor("- a\n    - b\n- c")
        #expect(ListMarkers.markers(in: storage, range: NSRange(location: 0, length: storage.length)).map(\.text)
            == ["•", "◦", "•"])
    }

    // MARK: - From the Tier-2 review

    /// After a hard break a line is still inside the paragraph, where `--` underlines it as a heading and `<div>`
    /// starts an HTML block; both are escaped, and read back as typed.
    @Test func blockSyntaxAfterOneReturnIsText() throws {
        for (line, written) in [("--", "\\--"), ("-", "\\-"), ("==", "\\=="), ("<div>x", "\\<div>x"), ("<!-- c", "\\<!-- c")] {
            let (tv, storage) = try editor("a")
            tv.insertNewline(nil); type(tv, line)
            let saved = reselect(tv, storage)
            #expect(saved == "a\\\n" + written, "\(line.debugDescription): saved \(saved.debugDescription)")
            #expect(storage.string == "a\n" + line, "\(line.debugDescription): reopened \(storage.string.debugDescription)")
        }
    }

    /// Beside raw HTML read from the file a typed Return stays a paragraph break: a hard break there would be the
    /// HTML's text, or be cut off by it.
    @Test func returnBesideRawHTMLIsAParagraphBreak() throws {
        let (tv, storage) = try editor("<div>\nx\n</div>")
        tv.insertNewline(nil); type(tv, "after")
        #expect(MarkdownBridge.serialize(storage) == "<div>\nx\n</div>\n\nafter")
        // Raw HTML is written as it is, with no backslash added on each save.
        let html = "<!-- a_b *c* [d] \\e -->\n\nz"
        #expect(MarkdownBridge.serialize(MarkdownBridge.parse(markdown: html)) == html)
    }

    /// Return at the start of the text after an image keeps the image's paragraph apart and adds the line.
    @Test func returnAfterAnImageLine() throws {
        let (tv, storage) = try editor("![](x.png)\n\nText")
        let before = storage.string
        caret(tv, at: (before as NSString).length - 4)
        tv.insertNewline(nil)
        let typed = storage.string
        let saved = reselect(tv, storage)
        #expect(saved.hasSuffix("\n\n\\\nText") && saved.hasPrefix("![](x.png)\n"), "saved \(saved.debugDescription)")
        #expect(storage.string == typed)
        #expect(MarkdownBridge.serialize(storage) == saved, "the reopened note must save the same")
    }

    /// Deleting a chip leaves the text around it a paragraph apart, not two.
    @Test func deletingAChipKeepsOneParagraphBreak() throws {
        let (tv, storage) = try editor("Intro.\n<!-- block: freeform -->\nBody.")
        let chip = (storage.string as NSString).range(of: "\u{FFFC}")
        #expect(chip.location != NSNotFound)
        storage.deleteCharacters(in: chip)
        #expect(reselect(tv, storage) == "Intro.\n\nBody.")
    }

    /// Two headings of one level next to each other stay two headings, and a heading split by Return is two.
    @Test func adjacentHeadingsStayHeadings() throws {
        var (tv, storage) = try editor("# A\n# B")
        #expect(MarkdownBridge.serialize(storage) == "# A\n# B")
        (tv, storage) = try editor("## OneTwo")
        caret(tv, at: 3)
        tv.insertNewline(nil)
        #expect(reselect(tv, storage) == "## One\n## Two")
    }

    /// Undo after Backspace joined a line to a list item gives the line back its own kind, and it saves so.
    @Test func undoAfterAJoinRestoresTheLine() throws {
        let (tv, storage) = try editor("- a\n\nBody")
        caret(tv, at: 2)
        tv.deleteBackward(nil)
        #expect(MarkdownBridge.serialize(storage) == "- aBody")
        tv.undoManager?.undo()
        #expect(storage.string == "a\nBody")
        #expect(MarkdownBridge.serialize(storage) == "- a\n\nBody", "got \(MarkdownBridge.serialize(storage).debugDescription)")
    }

    /// Undo after Bulleted List takes the list away again.
    @Test func undoAfterBulletedList() throws {
        let (tv, storage) = try editor("A")
        EditorFormatting.toggleUnorderedList(tv, fontSize: 14)
        #expect(MarkdownBridge.serialize(storage) == "- A")
        tv.undoManager?.undo()
        #expect(MarkdownBridge.serialize(storage) == "A")
    }

    /// Backspace on the line after a code block deletes the blank line without making the text code.
    @Test func backspaceAfterACodeBlock() throws {
        let (tv, storage) = try editor("```\nx\n```\n\nBody")
        caret(tv, at: storage.length - 4)
        tv.deleteBackward(nil)
        let saved = MarkdownBridge.serialize(storage)
        #expect(saved.hasSuffix("```\n\nBody") || saved.hasSuffix("```\nBody"), "got \(saved.debugDescription)")
    }

    /// Tab and Shift-Tab on an empty last list line indent and outdent what is typed there.
    @Test func tabOnTheEmptyLastListLine() throws {
        let (tv, storage) = try editor("- a")
        tv.insertNewline(nil)
        tv.insertTab(nil)
        type(tv, "b")
        #expect(MarkdownBridge.serialize(storage) == "- a\n    - b")
    }
}
