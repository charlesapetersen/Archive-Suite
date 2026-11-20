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
        // The empty line typed above the list is kept (W49.notes-keep-blank-lines; the editor shows one).
        #expect(MarkdownBridge.serialize(storage) == "A\\\n&nbsp;\n\n- one\n- two")
        reselect(tv, storage)
        #expect(ListMarkers.markers(in: storage, range: NSRange(location: 0, length: storage.length)).map(\.text) == ["•", "•"])
    }

    @Test func bulletedListInAnEmptyNote() throws {
        let (tv, storage) = try editor("")
        EditorFormatting.toggleUnorderedList(tv, fontSize: 14)
        type(tv, "x")
        #expect(MarkdownBridge.serialize(storage) == "- x")
    }

    /// The toggle on a line with text, through `FormattingContext` (what ⌥⌘U, the menu and the toolbar call).
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
        _ = expectKept(tv, storage, "one Return after an HTML block")   // W49.notes-lines-after-html: it read back as two
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

    /// Backspace that deletes a blank line typed after a code block joins nothing, so the text keeps its kind.
    @Test func backspaceAfterACodeBlock() throws {
        let (tv, storage) = try editor("```\nx\n```\n\nBody")
        caret(tv, at: 2)
        tv.insertNewline(nil)
        #expect(storage.string == "x\n\nBody")
        tv.deleteBackward(nil)
        #expect(storage.string == "x\nBody")
        #expect(MarkdownBridge.serialize(storage) == "```\nx\n```\n\nBody", "got \(MarkdownBridge.serialize(storage).debugDescription)")
    }

    /// A code block is one newline from the text after it, as other blocks are, and Backspace there joins the text
    /// into the block, for good.
    @Test func codeBlockBoundaryIsOneNewline() throws {
        let (tv, storage) = try editor("```\nx\n```\n\nBody")
        #expect(storage.string == "x\nBody")
        #expect(MarkdownBridge.serialize(storage) == "```\nx\n```\n\nBody")
        caret(tv, at: 2)
        tv.deleteBackward(nil)
        #expect(reselect(tv, storage) == "```\nxBody\n```")
    }

    /// Return at the start of a heading moves it down a line; the line left above is text, not an empty heading.
    @Test func returnAtTheStartOfAHeading() throws {
        let (tv, storage) = try editor("Intro\n\n# Title")
        caret(tv, at: 6)
        tv.insertNewline(nil)
        let saved = MarkdownBridge.serialize(storage)
        #expect(!saved.contains("# \n") && !saved.hasSuffix("# "), "got \(saved.debugDescription)")
        #expect(saved.hasSuffix("\n# Title"), "got \(saved.debugDescription)")
    }

    // MARK: - W49.notes-keep-blank-lines (owner call 20: keep what I type)

    /// Type, save, reselect: the same lines, and a reopened note saves the same.
    private func expectKept(_ tv: EditorTextView, _ storage: NSTextStorage, _ label: String,
                            sourceLocation: SourceLocation = #_sourceLocation) -> String {
        let typed = storage.string
        let saved = reselect(tv, storage)
        #expect(storage.string == typed, "\(label): reopened \(storage.string.debugDescription), saved \(saved.debugDescription)",
                sourceLocation: sourceLocation)
        #expect(MarkdownBridge.serialize(storage) == saved, "\(label): a reopened note must save the same",
                sourceLocation: sourceLocation)
        return saved
    }

    /// Case 1: blank lines typed at the end of text, right before a heading, list, quote or code block.
    @Test func blankLinesBeforeABlockAreKept() throws {
        for (block, written) in [("# T", "# T"), ("- x", "- x"), ("> q", "> q"), ("```\nc\n```", "```\nc\n```")] {
            for count in 1...3 {
                let (tv, storage) = try editor("A\n\n" + block)
                caret(tv, at: 1)
                for _ in 0..<count { tv.insertNewline(nil) }
                #expect(storage.string.hasPrefix("A" + String(repeating: "\n", count: count + 1)), "\(block): typed \(storage.string.debugDescription)")
                let saved = expectKept(tv, storage, "\(block) after \(count) Returns")
                #expect(saved == "A" + String(repeating: "\\\n", count: count) + "&nbsp;\n\n" + written, "\(block): saved \(saved.debugDescription)")
            }
        }
    }

    /// Case 1, typed into a new note: text, Returns, then a list toggled on and typed into.
    @Test func blankLinesTypedBeforeAToggledList() throws {
        let (tv, storage) = try editor("A")
        tv.insertNewline(nil); tv.insertNewline(nil); tv.insertNewline(nil)
        EditorFormatting.toggleUnorderedList(tv, fontSize: 14)
        type(tv, "x")
        #expect(storage.string == "A\n\n\nx")
        #expect(expectKept(tv, storage, "toggled list") == "A\\\n\\\n&nbsp;\n\n- x")
    }

    /// Case 1, an empty line alone between two blocks, after a heading.
    @Test func anEmptyLineBetweenTwoBlocksIsKept() throws {
        let (tv, storage) = try editor("# H\n\n- x")
        caret(tv, at: 1)
        tv.insertNewline(nil); tv.insertNewline(nil)
        #expect(storage.string == "H\n\n\nx")
        #expect(expectKept(tv, storage, "heading, empty lines, list") == "# H\n\n\\\n&nbsp;\n\n- x")
    }

    /// Case 2: an empty line between two list items is an empty item, kept.
    @Test func anEmptyListItemIsKept() throws {
        for (list, written) in [("- a\n- b", "- a\n- &nbsp;\n- b"), ("1. a\n2. b", "1. a\n2. &nbsp;\n3. b")] {
            let (tv, storage) = try editor(list)
            caret(tv, at: 1)
            tv.insertNewline(nil)
            #expect(storage.string == "a\n\nb")
            #expect(expectKept(tv, storage, list) == written)
            #expect(ListMarkers.markers(in: storage, range: NSRange(location: 0, length: storage.length)).count == 3)
        }
    }

    /// Case 3: a list toggled on an empty last line stays when the caret moves away before anything is typed,
    /// and after a reselect; typing there later is an item.
    @Test func aListToggledOnTheEmptyLastLineIsKept() throws {
        let (tv, storage) = try editor("A")
        tv.insertNewline(nil); tv.insertNewline(nil)
        EditorFormatting.toggleUnorderedList(tv, fontSize: 14)
        caret(tv, at: 0)
        #expect(ListMarkers.trailingMarker(in: storage, typingAttributes: tv.typingAttributes, caret: tv.selectedRange())?.text == "•")
        #expect(MarkdownBridge.serialize(storage) == "A\\\n&nbsp;\n\n- &nbsp;")
        caret(tv, at: storage.length)
        #expect(EditorFormatting.currentState(for: tv).blockKind == .listItem(ordered: false, depth: 0, ordinal: 1))
        caret(tv, at: 0)
        #expect(expectKept(tv, storage, "toggled, caret moved") == "A\\\n&nbsp;\n\n- &nbsp;")
        #expect(ListMarkers.trailingMarker(in: storage, typingAttributes: tv.typingAttributes, caret: tv.selectedRange())?.text == "•")
        type(tv, "x")   // the caret is at the end after a reselect
        #expect(MarkdownBridge.serialize(storage) == "A\\\n&nbsp;\n\n- x")
        // Toggled off again, it is a plain empty line, kept as one at the end of the note (W49.notes-keep-trailing-lines).
        let (tv2, storage2) = try editor("A")
        tv2.insertNewline(nil); tv2.insertNewline(nil)
        EditorFormatting.toggleUnorderedList(tv2, fontSize: 14)
        EditorFormatting.toggleUnorderedList(tv2, fontSize: 14)
        #expect(MarkdownBridge.serialize(storage2) == "A\\\n\\\n&nbsp;")
    }

    /// Case 3, after Return in a list: the empty item at the end is kept, and Return on it still leaves the list.
    @Test func anEmptyLastItemAfterReturnIsKept() throws {
        let (tv, storage) = try editor("- a")
        tv.insertNewline(nil)
        #expect(expectKept(tv, storage, "Return after an item") == "- a\n- &nbsp;")
        tv.insertNewline(nil)
        #expect(ListMarkers.trailingMarker(in: storage, typingAttributes: tv.typingAttributes, caret: tv.selectedRange()) == nil)
        #expect(MarkdownBridge.serialize(storage) == "- a")
    }

    /// Case 4: a file with several blank lines between a heading and its text, or between any two blocks, shows
    /// each one past the first as an empty line, and saves as the editor writes typed ones.
    @Test func severalBlankLinesInAFileAreShown() throws {
        let cases: [(String, String, String)] = [
            ("# H\n\n\n\nText", "H\n\n\nText", "# H\n\n\\\n\\\nText"),
            ("A\n\n\n\nB", "A\n\n\n\nB", "A\n\n\\\n\\\nB"),
            ("A\n\n\n# T", "A\n\nT", "A\\\n&nbsp;\n\n# T"),
            ("# H\n\n\n- x", "H\n\nx", "# H\n\n&nbsp;\n\n- x"),
            ("```\nc\n```\n\n\nText", "c\n\nText", "```\nc\n```\n\n\\\nText"),
        ]
        for (file, shown, saved) in cases {
            let (tv, storage) = try editor(file)
            #expect(storage.string == shown, "\(file.debugDescription): shown \(storage.string.debugDescription)")
            #expect(expectKept(tv, storage, file.debugDescription) == saved)
        }
        // Blank lines a list or two quotes hold, and those in a code block, are theirs, as before.
        for (file, shown) in [("- a\n\n\n- b", "a\nb"), ("```\nc\n\n\nd\n```", "c\n\n\nd\n")] {
            let (_, storage) = try editor(file)
            #expect(storage.string == shown, "\(file.debugDescription): shown \(storage.string.debugDescription)")
        }
    }

    /// The marker is text where it is not alone on a line, and typed `&nbsp;` is text.
    @Test func theMarkerOnlyMeansAnEmptyLine() throws {
        for (file, shown) in [("```\n&nbsp;\n```", "&nbsp;\n"), ("a &nbsp; b", "a \u{00A0} b"), ("`&nbsp;`", "&nbsp;")] {
            let (_, storage) = try editor(file)
            #expect(storage.string == shown, "\(file.debugDescription): shown \(storage.string.debugDescription)")
        }
        let (tv, storage) = try editor("A")
        tv.insertNewline(nil); tv.insertNewline(nil)
        type(tv, "&nbsp; and &amp;")
        #expect(expectKept(tv, storage, "typed entities") == "A\n\n\\&nbsp; and \\&amp;")
    }

    /// From the Tier-2 review: no `&nbsp;` read back stays as a character, where nothing follows it too (the end of the
    /// note, a chip below).
    @Test func noStrayMarkerWhereNothingFollows() throws {
        let chip = "<!-- block: freeform -->\nBody."
        func expectNoStrayCharacter(_ storage: NSTextStorage, _ label: String) {
            #expect(!storage.string.contains("\u{00A0}"), "\(label): \(storage.string.debugDescription)")
        }
        // Return after text above a chip, and after a list item above a chip.
        for file in ["A\n" + chip, "- a\n" + chip] {
            let (tv, storage) = try editor(file)
            caret(tv, at: 1)
            tv.insertNewline(nil)
            let saved = reselect(tv, storage)
            expectNoStrayCharacter(storage, file)
            #expect(MarkdownBridge.serialize(storage) == saved, "\(file.debugDescription): saved \(saved.debugDescription)")
        }
        // Return after text, then the block below deleted: the empty lines are at the end, and kept.
        let (tv, storage) = try editor("A\n\n# T")
        caret(tv, at: 1)
        tv.insertNewline(nil)
        storage.deleteCharacters(in: NSRange(location: storage.length - 1, length: 1))
        #expect(storage.string == "A\n\n")
        #expect(expectKept(tv, storage, "block deleted") == "A\\\n\\\n&nbsp;")
        expectNoStrayCharacter(storage, "block deleted")
        // Read from such places, the marker is not kept as a character.
        for file in ["A\\\n&nbsp;", "A\\\n&nbsp;\n" + chip, "- a\n- &nbsp;\n" + chip] {
            let (_, storage) = try editor(file)
            expectNoStrayCharacter(storage, file)
        }
    }

    // MARK: - W49.notes-keep-trailing-lines (owner call 20: keep what I type)

    /// Returns typed at the very end of a note are kept: written as breaks ending in an `&nbsp;` line, whose marker is
    /// deleted on reading and leaves the newlines.
    @Test func returnsAtTheEndOfANoteAreKept() throws {
        for count in 1...3 {
            let (tv, storage) = try editor("A")
            for _ in 0..<count { tv.insertNewline(nil) }
            #expect(storage.string == "A" + String(repeating: "\n", count: count))
            let saved = expectKept(tv, storage, "\(count) Returns at the end")
            #expect(saved == "A" + String(repeating: "\\\n", count: count) + "&nbsp;", "saved \(saved.debugDescription)")
            // Typing after a reopen goes on the last line, as it would have before the save.
            type(tv, "B")
            #expect(storage.string == "A" + String(repeating: "\n", count: count) + "B")
            _ = expectKept(tv, storage, "\(count) Returns, then text")
        }
        // In an empty note, and after a heading, a list left with Return, a quote and a code block.
        // (In a code block, Returns are the code's own lines, kept as its text.)
        for (file, label) in [("", "empty note"), ("# H", "heading"), ("- a", "list"), ("> q", "quote"),
                              ("Some <u>underlined</u>", "underline"), ("Some <mark>marked</mark>", "highlight")] {
            let (tv, storage) = try editor(file)
            tv.insertNewline(nil); tv.insertNewline(nil)
            if file == "- a" { tv.insertNewline(nil) }   // the second Return made an empty item; this one leaves the list
            let typed = storage.string
            let saved = expectKept(tv, storage, label)
            #expect(saved.hasSuffix("&nbsp;"), "\(label): saved \(saved.debugDescription) for \(typed.debugDescription)")
            #expect(!storage.string.contains("\u{00A0}"), "\(label): \(storage.string.debugDescription)")
        }
    }

    /// Returns typed just above a chip are kept, and agree with the newline `endLine` puts before the chip.
    @Test func returnsAboveAChipAreKept() throws {
        let chip = "<!-- block: freeform -->\nBody."
        for count in 1...3 {
            let (tv, storage) = try editor("A\n" + chip)
            caret(tv, at: 1)
            for _ in 0..<count { tv.insertNewline(nil) }
            let saved = expectKept(tv, storage, "\(count) Returns above a chip")
            #expect(saved == "A" + String(repeating: "\\\n", count: count) + "&nbsp;\n" + chip, "saved \(saved.debugDescription)")
            // Text typed on the last of those lines is a line of its own.
            caret(tv, at: (storage.string as NSString).range(of: "\u{FFFC}").location - 1)
            type(tv, "B")
            let withText = expectKept(tv, storage, "\(count) Returns above a chip, then text")
            #expect(withText.hasPrefix("A") && withText.hasSuffix("B\n" + chip), "saved \(withText.debugDescription)")
        }
        // Above a chip after a list item, and at the end of a chip's own text.
        for (file, at) in [("- a\n" + chip, 1), ("Intro\n" + chip, nil)] {
            let (tv, storage) = try editor(file)
            caret(tv, at: at ?? storage.length)
            tv.insertNewline(nil); tv.insertNewline(nil)
            _ = expectKept(tv, storage, file.debugDescription)
            #expect(!storage.string.contains("\u{00A0}"), "\(file.debugDescription): \(storage.string.debugDescription)")
        }
    }

    /// From the Tier-2 review: after an image's line (a chip's text opens with its thumbnail), Returns typed after the
    /// text are kept too, at the end of the note and above the next chip.
    @Test func returnsAfterTextBelowAnImageAreKept() throws {
        let chip = "<!-- block: freeform -->\nBody."
        for file in ["![](x.png)\n\nText", "![](x.png)\n\nText\n" + chip] {
            let (tv, storage) = try editor(file)
            let text = (storage.string as NSString).range(of: "Text")
            caret(tv, at: NSMaxRange(text))
            tv.insertNewline(nil); tv.insertNewline(nil)
            let saved = expectKept(tv, storage, file.debugDescription)
            #expect(saved.hasPrefix("![](x.png)\n\nText\\\n"), "\(file.debugDescription): saved \(saved.debugDescription)")
            #expect(!storage.string.contains("\u{00A0}"), "\(file.debugDescription): \(storage.string.debugDescription)")
        }
    }

    /// A quote's empty last lines are kept as text's are: at the end of the note, before another block and above a
    /// chip.
    @Test func emptyQuoteLinesAreKept() throws {
        for (file, at, written) in [("> q", 3, "> q\\\n> \\\n> &nbsp;"),
                                    ("> q\n\n# H", 1, "> q\\\n> \\\n> &nbsp;\n\n# H"),
                                    ("> q\n<!-- block: freeform -->\nBody.", 1, "> q\\\n> \\\n> &nbsp;\n<!-- block: freeform -->\nBody.")] {
            let (tv, storage) = try editor(file)
            caret(tv, at: min(at, storage.length))
            tv.insertNewline(nil); tv.insertNewline(nil)
            let saved = expectKept(tv, storage, file.debugDescription)
            #expect(saved == written, "\(file.debugDescription): saved \(saved.debugDescription)")
            #expect(!storage.string.contains("\u{00A0}"), "\(file.debugDescription): \(storage.string.debugDescription)")
        }
    }

    /// From the Tier-2 review: the kept kind of the empty last line goes once text is typed there, so deleting that
    /// text later does not bring back a list the operator turned off.
    @Test func theKeptKindGoesOnceTheLineHasText() throws {
        let (tv, storage) = try editor("A")
        tv.insertNewline(nil); tv.insertNewline(nil)
        EditorFormatting.toggleUnorderedList(tv, fontSize: 14)
        type(tv, "x")
        tv.setSelectedRange(NSRange(location: storage.length - 1, length: 1))
        EditorFormatting.toggleUnorderedList(tv, fontSize: 14)
        tv.deleteBackward(nil)
        #expect(storage.string == "A\n\n")
        #expect(MarkdownBridge.serialize(storage) == "A\\\n\\\n&nbsp;")
        #expect(ListMarkers.trailingMarker(in: storage, typingAttributes: tv.typingAttributes, caret: NSRange(location: 0, length: 0)) == nil)
    }

    /// From the Tier-2 review: a line with no text run of its own (a link reference definition) is not a blank line.
    /// CRLF lines are counted as lines.
    @Test func linesWithoutARunAreNotBlankLines() throws {
        for (file, shown) in [("See [x]\n\n[x]: http://a\n\n\nNext", "See x\n\nNext"),
                              ("A\r\n\r\n\r\n\r\nB", "A\n\n\n\nB")] {
            let (_, storage) = try editor(file)
            #expect(storage.string == shown, "\(file.debugDescription): shown \(storage.string.debugDescription)")
        }
    }

    // MARK: - W49.notes-lines-after-html (owner call 20: keep what I type)

    /// Returns typed after an HTML block read from the file are kept: at the end of the note, before a block, above a
    /// chip, before text and in a quote. The blank line that ends the block is the first of them.
    @Test func returnsAfterAnHTMLBlockAreKept() throws {
        let html = "<div>\nx\n</div>"
        let chip = "<!-- block: freeform -->\nBody."
        for count in 1...3 {
            let breaks = "\n\n" + String(repeating: "\\\n", count: count - 1)
            for (file, written) in [(html, html + breaks + "&nbsp;"),
                                    (html + "\n\n# H", html + breaks + "&nbsp;\n\n# H"),
                                    (html + "\n" + chip, html + breaks + "&nbsp;\n" + chip),
                                    (html + "\n\nafter", html + breaks + "\\\nafter"),
                                    ("> <div>x</div>", "> <div>x</div>\n>\n" + String(repeating: "> \\\n", count: count - 1) + "> &nbsp;")] {
                let (tv, storage) = try editor(file)
                let end = (storage.string as NSString).range(of: "</div>")
                caret(tv, at: NSMaxRange(end))
                for _ in 0..<count { tv.insertNewline(nil) }
                let saved = expectKept(tv, storage, "\(count) Returns after \(file.debugDescription)")
                #expect(saved == written, "\(count) Returns after \(file.debugDescription): saved \(saved.debugDescription)")
                #expect(!storage.string.contains("\u{00A0}"), "\(file.debugDescription): \(storage.string.debugDescription)")
                // Typing on the last of those lines after the reopen gives it text, kept as a line of its own.
                caret(tv, at: NSMaxRange((storage.string as NSString).range(of: "</div>")) + count)
                type(tv, "T")
                _ = expectKept(tv, storage, "\(count) Returns after \(file.debugDescription), then text")
            }
        }
    }

    /// An HTML block is one newline from what follows it, as other blocks are: the blank line that ends it in the file
    /// is not an empty line, so one Return typed after it stays one.
    @Test func anHTMLBlockIsOneNewlineFromWhatFollows() throws {
        for (file, shown) in [("<div>\nx\n</div>\n\nafter", "<div>\nx\n</div>\nafter"),
                              ("<!-- c -->\n\nText", "<!-- c -->\nText"),
                              ("<div>\nx\n</div>\n\n- a", "<div>\nx\n</div>\na"),
                              ("<div>\nx\n</div>\n\n# H", "<div>\nx\n</div>\nH")] {
            let (tv, storage) = try editor(file)
            #expect(storage.string == shown, "\(file.debugDescription): shown \(storage.string.debugDescription)")
            #expect(expectKept(tv, storage, file.debugDescription) == file)
        }
    }

    /// After HTML inside a paragraph (`a <b>x</b>`), Returns are written as after any text: the hard break is the
    /// paragraph's.
    @Test func returnsAfterInlineHTMLAreKept() throws {
        for count in 1...3 {
            for (file, suffix) in [("a <b>x</b>", "&nbsp;"), ("a <b>x</b>\n\n# H", "&nbsp;\n\n# H")] {
                let (tv, storage) = try editor(file)
                caret(tv, at: NSMaxRange((storage.string as NSString).range(of: "</b>")))
                for _ in 0..<count { tv.insertNewline(nil) }
                let saved = expectKept(tv, storage, "\(count) Returns after \(file.debugDescription)")
                #expect(saved == "a <b>x</b>" + String(repeating: "\\\n", count: count) + suffix,
                        "\(file.debugDescription): saved \(saved.debugDescription)")
            }
            let (tv, storage) = try editor("a <b>x</b>")
            for _ in 0..<count { tv.insertNewline(nil) }
            type(tv, "B")
            _ = expectKept(tv, storage, "\(count) Returns after inline HTML, then text")
        }
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
