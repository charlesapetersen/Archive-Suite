import AppKit
import PDFKit
import XCTest
@testable import ArchiveReader

/// Real AppKit responders and PDFKit scroll geometry; windows are never ordered onto the host display.
@MainActor
final class DocumentPaneInputTests: XCTestCase {
    private func key(_ code: Int, modifiers: NSEvent.ModifierFlags = [.numericPad, .function]) -> NSEvent {
        let chars = String(UnicodeScalar(code)!)
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                windowNumber: 0, context: nil, characters: chars,
                                charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 0)!
    }

    private func window(_ view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        addTeardownBlock { @MainActor in window.close() }
        return window
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }

    func testPlainArrowsPanInAllDirectionsAndStopAtEdges() throws {
        let view = ReaderPDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        let win = window(view)
        let document = TestPDFBuilder.textPDF(pages: ["A page large enough to pan"])
        view.document = document
        view.displayMode = .singlePage
        view.autoScales = false
        view.scaleFactor = 3
        view.layoutDocumentView()
        settle()
        let clip = try XCTUnwrap(view.documentView?.enclosingScrollView?.contentView)
        let doc = try XCTUnwrap(clip.documentView)
        clip.scroll(to: NSPoint(x: (doc.bounds.width - clip.bounds.width) / 2,
                                y: (doc.bounds.height - clip.bounds.height) / 2))
        XCTAssertTrue(win.makeFirstResponder(view))
        for (code, dx, dy) in [(NSRightArrowFunctionKey, 1.0, 0.0), (NSLeftArrowFunctionKey, -1.0, 0.0),
                               (NSUpArrowFunctionKey, 0.0, 1.0), (NSDownArrowFunctionKey, 0.0, -1.0)] {
            let before = clip.bounds.origin
            view.keyDown(with: key(code))
            let after = clip.bounds.origin
            if dx != 0 {
                XCTAssertGreaterThan((after.x - before.x) * dx, 0)
                XCTAssertEqual(after.y, before.y, accuracy: 0.01)
            } else {
                XCTAssertGreaterThan((after.y - before.y) * dy * (clip.isFlipped ? -1 : 1), 0)
                XCTAssertEqual(after.x, before.x, accuracy: 0.01)
            }
            XCTAssertEqual(view.currentPage, document.page(at: 0), "arrows pan instead of changing page")
        }
        for code in [NSRightArrowFunctionKey, NSLeftArrowFunctionKey, NSUpArrowFunctionKey, NSDownArrowFunctionKey] {
            for _ in 0..<100 { view.keyDown(with: key(code)) }
            let edge = clip.bounds.origin
            view.keyDown(with: key(code))
            XCTAssertEqual(clip.bounds.origin, edge, "an extra arrow at the edge is a no-op")
            XCTAssertEqual(clip.constrainBoundsRect(clip.bounds).origin, edge)
        }
        view.autoScales = true
        view.layoutDocumentView()
        settle()
        // PDFKit leaves a fractional centering adjustment after changing scale. Settle it before
        // measuring the arrows; compare coordinates within numerical precision.
        clip.scroll(to: clip.constrainBoundsRect(clip.bounds).origin)
        let fitted = clip.bounds.origin
        for code in [NSRightArrowFunctionKey, NSLeftArrowFunctionKey, NSUpArrowFunctionKey, NSDownArrowFunctionKey] {
            view.keyDown(with: key(code))
            XCTAssertEqual(clip.bounds.origin.x, fitted.x, accuracy: 0.001, "a fitted page has nowhere to pan")
            XCTAssertEqual(clip.bounds.origin.y, fitted.y, accuracy: 0.001, "a fitted page has nowhere to pan")
        }
    }

    func testPanLeavesModifiedArrowsToTextSelectionAndMenuCommands() {
        for code in [NSRightArrowFunctionKey, NSLeftArrowFunctionKey, NSUpArrowFunctionKey, NSDownArrowFunctionKey] {
            XCTAssertNotNil(ReaderPDFView.panKey(key(code)))
            XCTAssertNotNil(ReaderPDFView.panKey(key(code, modifiers: [.capsLock, .numericPad, .function])))
            for modifier: NSEvent.ModifierFlags in [.shift, .option, .command, .control, [.command, .shift], [.command, .option]] {
                XCTAssertNil(ReaderPDFView.panKey(key(code, modifiers: modifier)))
            }
        }
        XCTAssertNil(ReaderPDFView.panKey(key(65, modifiers: [])))
    }

    func testResponderFocusUpdatesBothPDFPanesAndExtractedTextWithoutASelection() throws {
        let model = DocumentViewerModel(persists: false)
        let container = NSView()
        let left = ReaderPDFView(frame: NSRect(x: 0, y: 0, width: 250, height: 400))
        left.paneController = model.leftController
        let right = ReaderPDFView(frame: NSRect(x: 250, y: 0, width: 250, height: 400))
        right.paneController = model.rightController
        let text = ExtractedTextView(frame: NSRect(x: 250, y: 0, width: 250, height: 400))
        text.controller = model.textController
        text.isEditable = false
        text.isSelectable = true
        text.string = "No selection needed to give this pane focus"
        for view in [left, right, text] { container.addSubview(view) }
        let win = window(container)
        XCTAssertTrue(win.makeFirstResponder(left))
        XCTAssertEqual(model.focusedPane, .left)
        XCTAssertTrue(win.makeFirstResponder(right))
        XCTAssertEqual(model.focusedPane, .right)
        XCTAssertTrue(win.makeFirstResponder(left))
        XCTAssertEqual(model.focusedPane, .left)
        XCTAssertTrue(win.makeFirstResponder(text))
        XCTAssertEqual(model.focusedPane, .right)
        XCTAssertEqual(text.selectedRange().length, 0)
        model.zoomFocusedIn()
        XCTAssertEqual(model.textScale, 1.1, accuracy: 0.001, "zoom now follows the clicked text pane")
    }

    /// The window becomes its own responder when the old PDF view leaves it. A replacement takes that
    /// focus back, but leaves an active find field alone. Covers the PDF and extracted-text replacement.
    func testRebuiltFocusedPaneRestoresResponderWithoutTakingItFromFind() throws {
        let model = DocumentViewerModel(persists: false)
        let container = NSView()
        let win = window(container)
        func pdf() -> ReaderPDFView {
            let view = ReaderPDFView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
            view.paneController = model.rightController
            return view
        }
        let original = pdf()
        container.addSubview(original)
        XCTAssertTrue(win.makeFirstResponder(original))
        XCTAssertEqual(model.focusedPane, .right)
        original.removeFromSuperview()
        XCTAssertTrue(win.firstResponder === win, "AppKit leaves focus at the window after removal")
        let rebuilt = pdf()
        container.addSubview(rebuilt)
        settle()
        XCTAssertTrue(win.firstResponder === rebuilt)
        rebuilt.removeFromSuperview()
        let text = ExtractedTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        text.controller = model.textController
        text.isSelectable = true
        text.isEditable = false
        container.addSubview(text)
        settle()
        XCTAssertTrue(win.firstResponder === text, "PDF-right to extracted-right keeps keyboard focus")
        text.string = "Next single-page document"
        settle()
        XCTAssertTrue(win.firstResponder === text, "reusing the text view keeps focus")
        text.removeFromSuperview()
        let restoredPDF = pdf()
        container.addSubview(restoredPDF)
        settle()
        XCTAssertTrue(win.firstResponder === restoredPDF)

        let find = NSTextField(frame: NSRect(x: 0, y: 410, width: 300, height: 25))
        container.addSubview(find)
        XCTAssertTrue(win.makeFirstResponder(find))
        let fieldEditor = win.firstResponder
        restoredPDF.removeFromSuperview()
        container.addSubview(pdf())
        container.addSubview(text)
        settle()
        XCTAssertTrue(win.firstResponder === fieldEditor, "neither pane steals the find field's caret")
    }
}
