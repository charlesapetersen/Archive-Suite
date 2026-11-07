// DocumentTextZoomTests.swift — W40.fix-reader-text-zoom.
//
// The owner focused the text page and chose Zoom In: nothing changed. Almost every corpus PDF has ONE page,
// so its right pane is not a PDFView but the page's text layer as SwiftUI text at a fixed body size, and
// zoom only ever reached a PDFView. These drive the REAL `DocumentViewerModel` over scratch PDFs
// (`mktemp`-style, never a corpus) and the pane's key handling with synthesized events.

import XCTest
import SwiftUI
import AppKit
@testable import ArchiveReader

@MainActor
final class DocumentTextZoomTests: XCTestCase {

    private func scratchPDF(pages: [String]) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("W40textzoom-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("doc.pdf")
        XCTAssertTrue(TestPDFBuilder.write(pages: pages, to: url), "failed to write scratch PDF")
        return url
    }

    private func load(_ urls: [URL]) -> DocumentViewerModel {
        let model = DocumentViewerModel(persists: false)   // never write the owner's zoom defaults
        model.load(DocumentSelection(filePaths: urls.map(\.path)))
        return model
    }

    private func key(_ chars: String, _ mods: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: 0)!
    }
    private let up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
    private let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)

    // MARK: the bug — zoom on a single-page PDF's text pane

    func testZoomOnTheExtractedTextPaneChangesItsTextSize() throws {
        let model = load([try scratchPDF(pages: ["A single-page scan with a text layer"])])
        XCTAssertFalse(model.hasTextPage, "precondition: a single-page PDF has no OCR text page")
        XCTAssertNotNil(model.embeddedText, "precondition: its right pane is the extracted text")
        XCTAssertEqual(model.textScale, 1)

        model.focusPane(.right)
        model.zoomFocusedIn()
        XCTAssertEqual(model.textScale, 1.25, accuracy: 0.0001, "Zoom In on the text pane enlarges its text")
        model.zoomFocusedIn()
        model.zoomFocusedOut()
        XCTAssertEqual(model.textScale, 1.25, accuracy: 0.0001)
        model.fitFocused()
        XCTAssertEqual(model.textScale, 1, "Fit Page (⌘0) resets the text size")
    }

    /// W40.fix-reader-doc-toolbar: Reset Zoom is disabled while it has nothing to do, and resets the text.
    func testResetZoomIsLiveOnlyWhileTheTextIsResized() throws {
        let model = load([try scratchPDF(pages: ["A single-page scan with a text layer"])])
        XCTAssertTrue(model.zoomIsDefault, "a freshly opened document is fitted, at the normal text size")
        model.zoomTextIn()
        XCTAssertFalse(model.zoomIsDefault, "larger text gives Reset Zoom something to do")
        model.resetZoom()
        XCTAssertEqual(model.textScale, 1)
        XCTAssertTrue(model.zoomIsDefault)
        model.zoomTextOut()
        XCTAssertFalse(model.zoomIsDefault, "smaller text counts too")
    }

    func testTextSizeIsClamped() throws {
        let model = load([try scratchPDF(pages: ["Text"])])
        model.focusPane(.right)
        for _ in 0..<20 { model.zoomTextIn() }
        XCTAssertEqual(model.textScale, DocumentViewerModel.textScaleRange.upperBound)
        for _ in 0..<40 { model.zoomTextOut() }
        XCTAssertEqual(model.textScale, DocumentViewerModel.textScaleRange.lowerBound)
    }

    func testImagePaneZoomLeavesTheTextSizeAlone() throws {
        let model = load([try scratchPDF(pages: ["Text"])])
        XCTAssertEqual(model.focusedPane, .left)
        model.zoomFocusedIn()
        XCTAssertEqual(model.textScale, 1)
    }

    func testATwoPageDocumentZoomsItsTextPageNotTheTextSize() throws {
        let model = load([try scratchPDF(pages: ["Image page", "OCR text page"])])
        XCTAssertTrue(model.hasTextPage)
        model.focusPane(.right)
        model.zoomFocusedIn()
        XCTAssertEqual(model.textScale, 1, "a real text page is a PDFView, zoomed by its controller")
    }

    /// Paging used to pull focus off any right pane without an OCR text page, so the text pane of the next
    /// single-page document could not keep it.
    func testFocusStaysOnTheExtractedTextPaneAcrossDocuments() throws {
        let model = load([try scratchPDF(pages: ["First"]), try scratchPDF(pages: ["Second"])])
        model.focusPane(.right)
        model.next()
        XCTAssertEqual(model.index, 1)
        XCTAssertEqual(model.focusedPane, .right)
    }

    // MARK: the keys

    func testZoomKeys() {
        XCTAssertEqual(ReaderPDFView.zoomKey(key("=", .command)), true)
        XCTAssertEqual(ReaderPDFView.zoomKey(key("+", [.command, .shift])), true)
        XCTAssertEqual(ReaderPDFView.zoomKey(key("+", .command)), true)
        XCTAssertEqual(ReaderPDFView.zoomKey(key("-", .command)), false)
        XCTAssertEqual(ReaderPDFView.zoomKey(key(up, [.command, .numericPad, .function])), true)
        XCTAssertEqual(ReaderPDFView.zoomKey(key(down, [.command, .numericPad, .function])), false)
        // ⌘⇧↑/↓ page through the segment; they must stay navigation.
        XCTAssertNil(ReaderPDFView.zoomKey(key(up, [.command, .shift, .numericPad, .function])))
        XCTAssertNil(ReaderPDFView.zoomKey(key(down, [.command, .shift, .numericPad, .function])))
        XCTAssertNil(ReaderPDFView.zoomKey(key("=", [.command, .option])))
        XCTAssertNil(ReaderPDFView.zoomKey(key("=", [])))
        XCTAssertNil(ReaderPDFView.zoomKey(key("0", .command)))
        XCTAssertNil(ReaderPDFView.zoomKey(key("-", [.command, .shift])))
    }

    /// ⌘= reaching EITHER pane's view zooms the FOCUSED pane — here the text pane, though the key landed
    /// on the image pane's PDFView (the only PDFView a single-page document has).
    func testKeyOnAPaneZoomsTheFocusedPane() throws {
        let model = load([try scratchPDF(pages: ["Text"])])
        model.focusPane(.right)
        let view = ReaderPDFView()
        view.paneController = model.leftController
        XCTAssertTrue(view.performKeyEquivalent(with: key("=", .command)))
        XCTAssertEqual(model.textScale, 1.25, accuracy: 0.0001)
        XCTAssertTrue(view.performKeyEquivalent(with: key("-", .command)))
        XCTAssertEqual(model.textScale, 1, accuracy: 0.0001)
        XCTAssertFalse(view.performKeyEquivalent(with: key("0", .command)), "⌘0 is the menu's Fit Page")
    }

    // MARK: it lays out larger

    /// The size reaches the layout, not just the model: at twice the scale, the same text at the same
    /// width needs well over half again the height.
    func testExtractedTextPaneLaysOutLargerWhenZoomed() {
        let text = String(repeating: "Archival OCR text on a single-page scan. ", count: 30)
        func height(_ scale: CGFloat) -> CGFloat {
            // The pane's own text view and font (an NSTextView since W40.fix-reader-copy-text-pane).
            let view = ExtractedTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 10))
            view.string = text
            view.font = ExtractedTextPane.font(scale: scale)
            guard let layout = view.layoutManager, let container = view.textContainer else { return 0 }
            layout.ensureLayout(for: container)
            return layout.usedRect(for: container).height
        }
        XCTAssertGreaterThan(height(1), 0)
        XCTAssertGreaterThan(height(2), height(1) * 1.5)
    }
}
