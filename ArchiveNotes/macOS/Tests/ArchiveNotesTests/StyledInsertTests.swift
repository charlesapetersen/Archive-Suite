import Testing
import AppKit
@testable import ArchiveNotes

/// W9.cand2: a pasted passage must draw exactly as the same markdown does after a reload. The paste path
/// used `insertText`, which re-fonted the run from `typingAttributes` (a 28 pt heading landed at 14 pt).
@MainActor
struct StyledInsertTests {
    private let existing = "Existing body.\n"
    private let pasted = "# Plain Note\n\nBody text here.\n"

    private func editor() -> EditorTextView {
        let tv = EditorTextView()
        tv.textStorage?.setAttributedString(MarkdownBridge.parse(markdown: existing))
        tv.setSelectedRange(NSRange(location: tv.textStorage!.length, length: 0))
        return tv
    }

    @Test func insertedRunKeepsEveryParsedFont() throws {
        let tv = editor()
        let parsed = MarkdownBridge.parse(markdown: pasted)
        let start = tv.selectedRange().location
        tv.insertStyled(parsed, replacementRange: tv.selectedRange())
        let storage = try #require(tv.textStorage)
        #expect(storage.attributedSubstring(from: NSRange(location: start, length: parsed.length)).string
                == parsed.string)
        parsed.enumerateAttribute(.font, in: NSRange(location: 0, length: parsed.length)) { value, r, _ in
            let want = (value as? NSFont)?.pointSize
            let got = (storage.attribute(.font, at: start + r.location, effectiveRange: nil) as? NSFont)?.pointSize
            #expect(got == want, "run \(r) must keep its parsed font size")
        }
        let heading = try #require(storage.attribute(.font, at: start, effectiveRange: nil) as? NSFont)
        #expect(heading.pointSize > 14, "the pasted heading must stay heading-sized")
        #expect(tv.selectedRange() == NSRange(location: start + parsed.length, length: 0))
        #expect(MarkdownBridge.serialize(storage).contains("# Plain Note"))
    }

    /// A windowless text view has no undo manager unless its delegate supplies one.
    @MainActor private final class UndoHost: NSObject, NSTextViewDelegate {
        let manager = UndoManager()
        func undoManager(for view: NSTextView) -> UndoManager? { manager }
    }

    @Test func undoRemovesTheWholeInsertion() throws {
        let tv = editor()
        let host = UndoHost()
        tv.delegate = host
        defer { withExtendedLifetime(host) {} }
        let before = tv.string
        tv.undoManager?.beginUndoGrouping()
        tv.insertStyled(MarkdownBridge.parse(markdown: pasted), replacementRange: tv.selectedRange())
        tv.undoManager?.endUndoGrouping()
        #expect(tv.string != before)
        let undo = try #require(tv.undoManager)
        #expect(undo.canUndo)
        undo.undo()
        #expect(tv.string == before)
        undo.redo()
        let storage = try #require(tv.textStorage)
        let start = (existing as NSString).length
        let heading = try #require(storage.attribute(.font, at: start, effectiveRange: nil) as? NSFont)
        #expect(heading.pointSize > 14, "redo must restore the heading's parsed font")
    }

    /// A passage chip pasted mid-body serializes back exactly once, with its body — the shape the saved
    /// `.md` depends on.
    @Test func midBodyPassageRoundTripsThroughSerialize() throws {
        let tv = EditorTextView()
        tv.textStorage?.setAttributedString(MarkdownBridge.parse(markdown: "First paragraph.\n\nSecond paragraph.\n"))
        let mid = (tv.string as NSString).range(of: "Second").location
        let passage = """
        <!-- block: note-passage
             note: archivenotes://open?id=\(UUID().uuidString)#block-0
             display: "Src — 1968" -->
        Snapshotted passage text.

        """
        tv.insertStyled(MarkdownBridge.parse(markdown: passage), replacementRange: NSRange(location: mid, length: 0))
        let saved = MarkdownBridge.serialize(try #require(tv.textStorage))
        #expect(saved.components(separatedBy: "<!-- block: note-passage").count == 2, "exactly one header: \(saved)")
        #expect(saved.contains("Snapshotted passage text."))
        #expect(saved.contains("First paragraph."))
        #expect(saved.contains("Second paragraph."))
        let reloaded = MarkdownBridge.serialize(MarkdownBridge.parse(markdown: saved))
        #expect(reloaded == saved, "the pasted shape must be stable across a reload")
    }

    // MARK: - W9.cand2-fu1: every edit that lands an attachment asks for a viewport relayout

    private func chipMarkdown() -> String {
        """
        <!-- block: note-passage
             note: archivenotes://open?id=\(UUID().uuidString)#block-0
             display: "Src — 1968" -->
        Passage.

        """
    }

    /// The first attachment run in `tv`, or nil.
    private func attachmentRange(in tv: EditorTextView) -> NSRange? {
        guard let storage = tv.textStorage else { return nil }
        var found: NSRange?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { v, r, stop in
            if v != nil { found = r; stop.pointee = true }
        }
        return found
    }

    @Test func insertTextOfAChipAsksForARelayoutButTypingDoesNot() throws {
        let tv = editor()
        tv.insertText("\n", replacementRange: tv.selectedRange())   // the chip gets its own paragraph
        let chip = MarkdownBridge.parse(markdown: chipMarkdown())
        tv.insertText(chip, replacementRange: tv.selectedRange())   // the insertBlock / insertSourceBlocks shape
        #expect(attachmentRange(in: tv) != nil)
        let afterChip = tv.attachmentRelayoutRequests
        #expect(afterChip >= 1, "inserting a chip through insertText must ask for a relayout")
        tv.insertText("x", replacementRange: tv.selectedRange())
        tv.insertText("y", replacementRange: NSRange(location: 0, length: 0))
        #expect(tv.attachmentRelayoutRequests == afterChip,
                "typing in a paragraph without an attachment must not relayout: \(tv.string.debugDescription)")
    }

    @Test func undoOfADeletedChipAsksForARelayoutAndTheDeleteDoesNot() throws {
        let tv = EditorTextView()
        let host = UndoHost()
        tv.delegate = host
        defer { withExtendedLifetime(host) {} }
        tv.replaceStyledDocument(with: MarkdownBridge.parse(markdown: "Lead.\n\n" + chipMarkdown()))
        #expect(tv.attachmentRelayoutRequests == 0, "a document load is not an edit")
        let chip = try #require(attachmentRange(in: tv))
        tv.insertText("", replacementRange: chip)
        #expect(attachmentRange(in: tv) == nil)
        #expect(tv.attachmentRelayoutRequests == 0, "deleting a chip leaves nothing to load")
        let undo = try #require(tv.undoManager)
        undo.undo()
        #expect(attachmentRange(in: tv) != nil, "undo must restore the chip")
        let afterUndo = tv.attachmentRelayoutRequests
        #expect(afterUndo >= 1, "NSTextView's own undo putting the chip back must ask for a relayout")
        undo.redo()
        #expect(attachmentRange(in: tv) == nil)
        #expect(tv.attachmentRelayoutRequests == afterUndo, "redoing the delete leaves nothing to load")
        undo.undo()
        #expect(tv.attachmentRelayoutRequests > afterUndo, "a second undo asks again")
    }

    @Test func insertStyledRelaysOutOnceItself() throws {
        let tv = editor()
        tv.insertStyled(MarkdownBridge.parse(markdown: chipMarkdown()), replacementRange: tv.selectedRange())
        #expect(attachmentRange(in: tv) != nil)
        #expect(tv.attachmentRelayoutRequests == 0, "insertStyled schedules its own relayout-then-scroll")
    }
}
