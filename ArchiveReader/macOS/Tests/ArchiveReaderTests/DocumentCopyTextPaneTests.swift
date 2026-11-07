// DocumentCopyTextPaneTests.swift — W40.fix-reader-copy-text-pane.
//
// The owner's Reader session 2 (rows 10-12): with text selected in the text pane on the right, Edit ▸ Copy
// was greyed and every copy command took the image page's text. A one-page PDF (almost all of the corpus)
// showed that text as a selectable SwiftUI `Text`, whose selection nothing could read. These drive the REAL
// `DocumentViewerModel` over scratch PDFs (never a corpus) with the panes' own views, unwindowed, and read
// what a copy would put on the pasteboard without touching the owner's clipboard.

import XCTest
import SwiftUI
import PDFKit
import AppKit
@testable import ArchiveReader

@MainActor
final class DocumentCopyTextPaneTests: XCTestCase {

    private func scratchPDF(pages: [String]) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("W40copytext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("doc.pdf")
        XCTAssertTrue(TestPDFBuilder.write(pages: pages, to: url), "failed to write scratch PDF")
        return url
    }

    private func load(_ urls: [URL]) -> DocumentViewerModel {
        let model = DocumentViewerModel(persists: false)
        model.load(DocumentSelection(filePaths: urls.map(\.path)))
        return model
    }

    /// The image pane's PDFView, showing the model's image page as the window would.
    private func imagePane(_ model: DocumentViewerModel) -> ReaderPDFView {
        let view = ReaderPDFView(frame: NSRect(x: 0, y: 0, width: 400, height: 500))
        view.paneController = model.leftController
        model.leftController.pdfView = view
        model.leftController.show(model.imagePage, reference: nil, in: view)
        return view
    }

    /// The extracted-text pane's text view, holding the model's embedded text.
    private func textPane(_ model: DocumentViewerModel) throws -> ExtractedTextView {
        let view = ExtractedTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 500))
        view.isEditable = false
        view.controller = model.textController
        model.textController.textView = view
        view.string = try XCTUnwrap(model.embeddedText)
        return view
    }

    private func select(_ word: String, in view: NSTextView) {
        view.setSelectedRange((view.string as NSString).range(of: word))
    }

    private func select(_ word: String, in view: PDFView) throws {
        let page = try XCTUnwrap(view.document?.page(at: 0))
        let hit = try XCTUnwrap(view.document?.findString(word, withOptions: []).first, "no \(word) on the page")
        XCTAssertNotNil(hit.bounds(for: page))
        view.setCurrentSelection(hit, animate: false)
    }

    private func copyItem() -> NSMenuItem { NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c") }

    // MARK: rows 10-11 — copy takes the text pane's selection

    func testCopyTakesTheTextPanesSelectionOnAOnePagePDF() throws {
        let model = load([try scratchPDF(pages: ["Dear Riesman, the hyphen-\nated report follows."])])
        XCTAssertFalse(model.hasTextPage, "precondition: a one-page PDF")
        let image = imagePane(model)
        let text = try textPane(model)
        XCTAssertFalse(model.hasTextSelection)
        XCTAssertFalse(image.validateMenuItem(copyItem()), "nothing selected: Copy is off")

        select("Riesman", in: text)
        XCTAssertTrue(model.hasTextSelection)
        XCTAssertEqual(model.plainCopyText, "Riesman", "⌘C takes the text pane's selection")
        XCTAssertTrue(text.validateMenuItem(copyItem()), "Edit ▸ Copy is live in the text pane")
        XCTAssertTrue(image.validateMenuItem(copyItem()), "…and with the image pane focused too")

        text.string = "the hyphen-\nated report"   // the cleaner's input exactly, whatever PDFKit's line breaks
        select("hyphen-\nated", in: text)
        XCTAssertEqual(model.cleanedCopyText(CopyTextOptions()), "hyphenated",
                       "Copy Cleaned for Prose takes it, cleaned")
    }

    func testTheImagePanesSelectionStillCopies() throws {
        let model = load([try scratchPDF(pages: ["Dear Riesman, the report follows."])])
        let image = imagePane(model)
        _ = try textPane(model)
        try select("report", in: image)
        model.userSelected(in: .left)
        XCTAssertEqual(model.plainCopyText, "report")
        XCTAssertEqual(model.focusedPane, .left)
    }

    // MARK: row 12 — one live selection

    func testSelectingInOnePaneClearsTheOther() throws {
        let model = load([try scratchPDF(pages: ["Dear Riesman, the report follows."])])
        let image = imagePane(model)
        let text = try textPane(model)

        try select("report", in: image)
        model.userSelected(in: .left)
        select("Riesman", in: text)
        model.userSelected(in: .right)
        XCTAssertNil(image.currentSelection?.string.flatMap { $0.isEmpty ? nil : $0 },
                     "selecting in the text pane clears the image pane's")
        XCTAssertEqual(model.focusedPane, .right, "the focus border follows the selection")
        XCTAssertEqual(model.plainCopyText, "Riesman")

        try select("follows", in: image)
        model.userSelected(in: .left)
        XCTAssertEqual(text.selectedRange().length, 0, "selecting in the image pane clears the text pane's")
        XCTAssertEqual(model.plainCopyText, "follows")
    }

    /// The same on a two-page pair, whose text pane is a PDFView.
    func testATwoPagePairKeepsOneSelectionToo() throws {
        let model = load([try scratchPDF(pages: ["Image page words", "OCR text page words"])])
        XCTAssertTrue(model.hasTextPage)
        let image = imagePane(model)
        let textView = ReaderPDFView(frame: NSRect(x: 0, y: 0, width: 300, height: 500))
        textView.paneController = model.rightController
        model.rightController.pdfView = textView
        model.rightController.show(model.textPage, reference: nil, in: textView)

        try select("Image", in: image)
        model.userSelected(in: .left)
        try select("OCR", in: textView)
        model.userSelected(in: .right)
        XCTAssertNil(image.currentSelection?.string.flatMap { $0.isEmpty ? nil : $0 })
        XCTAssertEqual(model.plainCopyText, "OCR")
    }

    /// The pane's own `selectionChanged` reports only a selection made while it is first responder — find
    /// selects its hit with the caret in the find field, and must not clear the other pane.
    func testAPaneThatIsNotFirstResponderDoesNotClaimTheSelection() throws {
        let model = load([try scratchPDF(pages: ["Dear Riesman, the report follows."])])
        let image = imagePane(model)
        let text = try textPane(model)
        select("Riesman", in: text)
        model.userSelected(in: .right)
        try select("report", in: image)
        model.leftController.selectionChanged()   // unwindowed: not first responder
        XCTAssertEqual(text.selectedRange().length, "Riesman".count, "the text pane keeps its selection")
    }

    // MARK: the pane itself

    func testTheTextPaneCopiesPlainTextNotTheFindHighlights() throws {
        let model = load([try scratchPDF(pages: ["zulu one"])])
        let text = try textPane(model)
        var copied: String?
        model.textController.copySelection = { copied = model.plainCopyText }
        select("zulu", in: text)
        text.copy(nil)
        XCTAssertEqual(copied, "zulu", "Edit ▸ Copy in the text pane goes through the viewer's copy")
    }

    /// Render guard: the pane, as SwiftUI hosts it, draws its text. A unit run sees no pixels otherwise, and
    /// the pane changed from a SwiftUI `Text` to an AppKit text view.
    func testTheTextPaneDrawsItsText() throws {
        let text = Array(repeating: "Archival OCR text on a single-page scan.", count: 30).joined(separator: "\n")
        let host = NSHostingView(rootView: ExtractedTextPane(text: text, scale: 1.5, controller: ExtractedTextController()))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 300)
        // The pane draws no background of its own (the window's shows through), so back it with white:
        // the probe reads black text on a transparent field as one flat colour.
        let backing = WhiteBacking(frame: host.frame)
        backing.addSubview(host)
        backing.layoutSubtreeIfNeeded()
        let data = try XCTUnwrap(RenderProbe.pngData(fromAppKitView: backing, size: backing.frame.size))
        let image = try XCTUnwrap(RenderProbe.cgImage(fromPNG: data))
        let stats = PixelStats.from(cgImage: image)
        XCTAssertFalse(stats.isEffectivelyBlank(), "the text pane drew nothing: \(stats)")
    }

    func testFindHighlightRangesMatchTheScanner() {
        let text = "Zulu one, zulu two"
        XCTAssertEqual(ExtractedTextPane.highlightRanges(query: "zulu", in: text),
                       [NSRange(location: 0, length: 4), NSRange(location: 10, length: 4)])
        XCTAssertEqual(ExtractedTextPane.highlightRanges(query: "", in: text), [])
    }
}

private final class WhiteBacking: NSView {
    override func draw(_ dirtyRect: NSRect) { NSColor.white.setFill(); dirtyRect.fill() }
}
