import Testing
import Foundation
import AppKit
@testable import ArchiveNotes

/// W8-S7 §3.3 — the DEBUG-only editor test seam that lets XCUITest commit text + set a selection without
/// relying on field-editor focus (a documented weak spot for a styled TextKit-2 NSTextView). These
/// exercise the `EditorTextView` primitives directly, GUI-off; the coordinator's Markdown parse/serialize
/// wrapper is covered by `MarkdownBridgeTests`, and the hidden-control → `testBox` wiring is GUI-run
/// verified under W8-S8. The seam is compiled out of Release (`#if DEBUG`), so this suite is DEBUG-only.
@Suite("EditorTestSeamTests — W8-S7 §3.3 DEBUG UITest seam")
@MainActor
struct EditorTestSeamTests {

    // MARK: - Selection clamping (pure)

    @Test
    func clampsLocationBeyondEnd() {
        let tv = EditorTextView()
        tv.uiTestReplace(with: NSAttributedString(string: "Hello"))   // length 5
        let r = tv.uiTestClampedRange(location: 100, length: 5)
        #expect(r == NSRange(location: 5, length: 0), "location past the end clamps to the end, length 0")
    }

    @Test
    func clampsNegativeLocation() {
        let tv = EditorTextView()
        tv.uiTestReplace(with: NSAttributedString(string: "Hello"))
        let r = tv.uiTestClampedRange(location: -3, length: 2)
        #expect(r == NSRange(location: 0, length: 2), "negative location clamps to 0, length preserved")
    }

    @Test
    func clampsLengthOverflow() {
        let tv = EditorTextView()
        tv.uiTestReplace(with: NSAttributedString(string: "Hello"))
        let r = tv.uiTestClampedRange(location: 2, length: 100)
        #expect(r == NSRange(location: 2, length: 3), "length past the end clamps to what remains")
    }

    @Test
    func setSelectionAppliesClampedRange() {
        let tv = EditorTextView()
        tv.uiTestReplace(with: NSAttributedString(string: "Hello"))
        tv.uiTestSetSelection(location: 1, length: 3)
        #expect(tv.selectedRange() == NSRange(location: 1, length: 3))
        // Out of range must clamp, not crash.
        tv.uiTestSetSelection(location: 99, length: 99)
        #expect(tv.selectedRange() == NSRange(location: 5, length: 0))
    }

    // MARK: - Commit / insert primitives

    @Test
    func replaceSetsWholeDocument() {
        let tv = EditorTextView()
        tv.uiTestReplace(with: NSAttributedString(string: "First"))
        #expect(tv.string == "First")
        // A second replace fully supersedes the first (whole-document range).
        tv.uiTestReplace(with: NSAttributedString(string: "# Heading"))
        #expect(tv.string == "# Heading")
    }

    @Test
    func insertPlacesTextAtCaretAndAdvancesSelection() {
        let tv = EditorTextView()
        tv.uiTestReplace(with: NSAttributedString(string: "AB"))
        tv.uiTestSetSelection(location: 1, length: 0)   // caret between A and B
        tv.uiTestInsert(NSAttributedString(string: "X"))
        #expect(tv.string == "AXB", "insert lands at the caret")
        #expect(tv.selectedRange() == NSRange(location: 2, length: 0), "caret follows the inserted text")
    }

    @Test
    func insertReplacesTheSelection() {
        let tv = EditorTextView()
        tv.uiTestReplace(with: NSAttributedString(string: "keep-DROP-keep"))
        tv.uiTestSetSelection(location: 5, length: 4)   // "DROP"
        tv.uiTestInsert(NSAttributedString(string: "X"))
        #expect(tv.string == "keep-X-keep", "insert over a selection replaces it")
    }
}
