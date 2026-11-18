import AppKit
import PDFKit
import XCTest
@testable import ArchiveReader

/// Real AppKit responders and PDFKit scroll geometry; windows are never ordered onto the host display.
@MainActor
final class DocumentPaneInputTests: XCTestCase {
    private func key(_ code: Int, modifiers: NSEvent.ModifierFlags = [.numericPad, .function],
                     repeating: Bool = false) -> NSEvent {
        let chars = String(UnicodeScalar(code)!)
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                windowNumber: 0, context: nil, characters: chars,
                                charactersIgnoringModifiers: chars, isARepeat: repeating, keyCode: 0)!
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

    // MARK: Page turns (W40.reader-page-nav)

    /// A zoomed page pans with ← / →; at the edge, a fresh press turns the page and a held one does not.
    /// A fitted page turns at once. ↑ / ↓ never turn.
    func testHorizontalArrowsTurnThePageOnlyWhenThePanHasNowhereToGo() throws {
        let model = DocumentViewerModel(persists: false)
        var turns: [Bool] = []
        model.leftController.turnPage = { turns.append($0) }
        let view = ReaderPDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        view.paneController = model.leftController
        let win = window(view)
        view.document = TestPDFBuilder.textPDF(pages: ["A page large enough to pan"])
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
        XCTAssertEqual(PageEdge.reached(by: clip), [], "a centred zoomed page is at no edge")

        view.keyDown(with: key(NSRightArrowFunctionKey))
        view.keyDown(with: key(NSLeftArrowFunctionKey))
        XCTAssertEqual(turns, [], "with room to pan, the arrows pan")
        for _ in 0..<100 { view.keyDown(with: key(NSRightArrowFunctionKey, repeating: true)) }
        XCTAssertTrue(PageEdge.reached(by: clip).contains(.right))
        XCTAssertEqual(turns, [], "holding → stops at the edge")
        view.keyDown(with: key(NSRightArrowFunctionKey))
        XCTAssertEqual(turns, [true], "a fresh → at the right edge turns to the next page")
        for _ in 0..<100 { view.keyDown(with: key(NSLeftArrowFunctionKey, repeating: true)) }
        view.keyDown(with: key(NSLeftArrowFunctionKey))
        XCTAssertEqual(turns, [true, false], "a fresh ← at the left edge turns back")
        for _ in 0..<100 { view.keyDown(with: key(NSDownArrowFunctionKey)) }
        for _ in 0..<100 { view.keyDown(with: key(NSUpArrowFunctionKey)) }
        view.keyDown(with: key(NSRightArrowFunctionKey, modifiers: [.command, .shift]))
        XCTAssertEqual(turns, [true, false], "↑ / ↓ at an edge and modified arrows never turn")

        view.autoScales = true
        view.layoutDocumentView()
        settle()
        clip.scroll(to: clip.constrainBoundsRect(clip.bounds).origin)
        XCTAssertEqual(PageEdge.reached(by: clip), Set(PageEdge.allCases), "a fitted page is at every edge")
        turns = []
        view.keyDown(with: key(NSRightArrowFunctionKey))
        view.keyDown(with: key(NSLeftArrowFunctionKey))
        XCTAssertEqual(turns, [true, false], "a fitted page turns at once")
    }

    func testExtractedTextArrowsTurnThePageAndLeaveModifiedArrows() {
        let model = DocumentViewerModel(persists: false)
        var turns: [Bool] = []
        model.textController.turnPage = { turns.append($0) }
        let text = ExtractedTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        text.controller = model.textController
        text.isEditable = false
        text.isSelectable = true
        text.string = "Some extracted text"
        let win = window(text)
        XCTAssertTrue(win.makeFirstResponder(text))
        text.keyDown(with: key(NSRightArrowFunctionKey))
        text.keyDown(with: key(NSRightArrowFunctionKey, repeating: true))
        text.keyDown(with: key(NSLeftArrowFunctionKey))
        text.keyDown(with: key(NSRightArrowFunctionKey, modifiers: [.shift, .numericPad, .function]))
        text.keyDown(with: key(NSDownArrowFunctionKey))
        XCTAssertEqual(turns, [true, false], "plain ← / → turn once per press; ⇧→ and ↓ stay the text view's")
    }

    func testPushedEdgeFollowsTheDominantAxis() {
        XCTAssertEqual(PageEdge.pushed(dx: 0, dy: 5), .top)
        XCTAssertEqual(PageEdge.pushed(dx: 1, dy: -5), .bottom)
        XCTAssertEqual(PageEdge.pushed(dx: 6, dy: -5), .left)
        XCTAssertEqual(PageEdge.pushed(dx: -6, dy: 2), .right)
        XCTAssertNil(PageEdge.pushed(dx: 0, dy: 0))
        XCTAssertTrue(PageEdge.bottom.isNext && PageEdge.right.isNext)
        XCTAssertFalse(PageEdge.top.isNext || PageEdge.left.isNext)
    }

    /// A trackpad gesture turns only past an edge it began at, once, and swallows its own rest and momentum.
    func testScrollGestureTurnsOncePastAnEdgeItBeganAt() {
        let all = Set(PageEdge.allCases)
        var scroll = PageTurnScroll()
        XCTAssertEqual(scroll.handle(phase: .began, momentum: [], dx: 0, dy: -2, time: 0, edges: all), .scroll)
        XCTAssertEqual(scroll.handle(phase: .changed, momentum: [], dx: 0, dy: -30, time: 0.01, edges: all), .scroll,
                       "short of the overscroll, the scroll view bounces as usual")
        XCTAssertEqual(scroll.handle(phase: .changed, momentum: [], dx: 0, dy: -40, time: 0.02, edges: all),
                       .turn(next: true), "past the bottom edge: the next page")
        XCTAssertEqual(scroll.handle(phase: .changed, momentum: [], dx: 0, dy: -40, time: 0.03, edges: all), .swallow)
        XCTAssertEqual(scroll.handle(phase: .ended, momentum: [], dx: 0, dy: 0, time: 0.04, edges: all), .swallow)
        XCTAssertEqual(scroll.handle(phase: [], momentum: .changed, dx: 0, dy: -20, time: 0.05, edges: all), .swallow,
                       "its momentum does not turn a second page")

        // A swipe to the right on a fitted page (fingers right: content toward the left edge) turns back.
        XCTAssertEqual(scroll.handle(phase: .began, momentum: [], dx: 1, dy: 0, time: 1, edges: all), .scroll)
        XCTAssertEqual(scroll.handle(phase: .changed, momentum: [], dx: 70, dy: 3, time: 1.01, edges: all),
                       .turn(next: false))

        // A zoomed page scrolled to its bottom edge in this gesture stops there; only the next gesture turns.
        XCTAssertEqual(scroll.handle(phase: .began, momentum: [], dx: 0, dy: -2, time: 2, edges: []), .scroll)
        XCTAssertEqual(scroll.handle(phase: .changed, momentum: [], dx: 0, dy: -200, time: 2.1, edges: [.bottom]),
                       .scroll)
        XCTAssertEqual(scroll.handle(phase: [], momentum: .changed, dx: 0, dy: -50, time: 2.2, edges: [.bottom]), .scroll)
        XCTAssertEqual(scroll.handle(phase: .began, momentum: [], dx: 0, dy: -2, time: 3, edges: [.bottom]), .scroll)
        XCTAssertEqual(scroll.handle(phase: .changed, momentum: [], dx: 0, dy: 100, time: 3.1, edges: [.bottom]),
                       .scroll, "scrolling back up, away from the edge, pans")
        XCTAssertEqual(scroll.handle(phase: .changed, momentum: [], dx: 0, dy: -100, time: 3.2, edges: [.bottom]),
                       .turn(next: true))

        // A pane rebuilt mid-gesture never saw it begin: it scrolls, and never turns.
        var rebuilt = PageTurnScroll()
        XCTAssertEqual(rebuilt.handle(phase: .changed, momentum: [], dx: 0, dy: -200, time: 0, edges: all), .scroll)
        XCTAssertEqual(rebuilt.handle(phase: [], momentum: .changed, dx: 0, dy: -200, time: 0.1, edges: all), .scroll)
    }

    /// A mouse wheel has no phases: a run of clicks that begins at an edge turns once.
    func testWheelRunTurnsOnceFromAnEdge() {
        var scroll = PageTurnScroll()
        XCTAssertEqual(scroll.handle(phase: [], momentum: [], dx: 0, dy: -3, time: 0, edges: []), .scroll)
        XCTAssertEqual(scroll.handle(phase: [], momentum: [], dx: 0, dy: -3, time: 0.1, edges: [.bottom]), .scroll,
                       "the run that reaches the edge stops there")
        XCTAssertEqual(scroll.handle(phase: [], momentum: [], dx: 0, dy: -3, time: 1, edges: [.bottom]),
                       .turn(next: true))
        XCTAssertEqual(scroll.handle(phase: [], momentum: [], dx: 0, dy: -3, time: 1.1, edges: [.bottom]), .swallow)
        XCTAssertEqual(scroll.handle(phase: [], momentum: [], dx: 0, dy: -3, time: 1.2, edges: [.bottom]), .swallow)
        XCTAssertEqual(scroll.handle(phase: [], momentum: [], dx: 0, dy: 3, time: 2, edges: Set(PageEdge.allCases)),
                       .turn(next: false))
    }
}
