import XCTest
import PDFKit
import AppKit
import CoreText
@testable import ArchiveReader

/// In-viewer find: the pure match-navigation model (`FindNavigator`) and the PDFKit match counter
/// (`DocumentFindScanner`). GUI-free — the live highlight/scroll in the panes is verified separately.
@MainActor
final class DocumentFindTests: XCTestCase {

    // MARK: FindNavigator — pure navigation over the flat match list

    private typealias Loc = FindMatchLocation
    private typealias Pane = DocumentViewerModel.Pane

    func testEmptyNavigatorHasNoMatches() {
        var nav = FindNavigator()
        XCTAssertEqual(nav.total, 0)
        XCTAssertTrue(nav.isEmpty)
        XCTAssertNil(nav.ordinal)
        XCTAssertNil(nav.current)
        XCTAssertNil(nav.next())
        XCTAssertNil(nav.previous())
    }

    func testEmptyPerPaneCountsProduceEmptyNavigator() {
        let nav = FindNavigator(perPane: [(0, .left, 0), (0, .right, 0)])
        XCTAssertEqual(nav.total, 0)
        XCTAssertNil(nav.ordinal)
        XCTAssertNil(nav.current)
    }

    func testBuildOrdersByDocThenLeftBeforeRightAndSkipsZeroCounts() {
        // doc 0: 2 left + 1 right; doc 1: 0 left (skipped) + 3 right.
        let nav = FindNavigator(perPane: [
            (0, .left, 2), (0, .right, 1),
            (1, .left, 0), (1, .right, 3),
        ])
        XCTAssertEqual(nav.total, 6)
        XCTAssertEqual(nav.ordinal, 1)                       // starts on the first match
        XCTAssertEqual(nav.current, Loc(doc: 0, pane: .left, index: 0))
        XCTAssertEqual(nav.locations, [
            Loc(doc: 0, pane: .left,  index: 0),
            Loc(doc: 0, pane: .left,  index: 1),
            Loc(doc: 0, pane: .right, index: 0),
            Loc(doc: 1, pane: .right, index: 0),             // doc-1 left skipped (zero count)
            Loc(doc: 1, pane: .right, index: 1),
            Loc(doc: 1, pane: .right, index: 2),
        ])
    }

    func testNextAdvancesThroughEveryMatchThenWraps() {
        var nav = FindNavigator(perPane: [(0, .left, 2), (1, .right, 1)])   // 3 matches
        XCTAssertEqual(nav.ordinal, 1)
        XCTAssertEqual(nav.next(), Loc(doc: 0, pane: .left, index: 1)); XCTAssertEqual(nav.ordinal, 2)
        XCTAssertEqual(nav.next(), Loc(doc: 1, pane: .right, index: 0)); XCTAssertEqual(nav.ordinal, 3)
        XCTAssertEqual(nav.next(), Loc(doc: 0, pane: .left, index: 0)); XCTAssertEqual(nav.ordinal, 1)  // wrap
    }

    func testPreviousFromFirstWrapsToLast() {
        var nav = FindNavigator(perPane: [(0, .left, 1), (0, .right, 1), (2, .left, 1)])   // 3 matches
        XCTAssertEqual(nav.ordinal, 1)
        XCTAssertEqual(nav.previous(), Loc(doc: 2, pane: .left, index: 0))   // wrap back to the last
        XCTAssertEqual(nav.ordinal, 3)
        XCTAssertEqual(nav.previous(), Loc(doc: 0, pane: .right, index: 0))
        XCTAssertEqual(nav.ordinal, 2)
    }

    func testSingleMatchWrapsToItself() {
        var nav = FindNavigator(perPane: [(4, .right, 1)])
        XCTAssertEqual(nav.total, 1)
        XCTAssertEqual(nav.current, Loc(doc: 4, pane: .right, index: 0))
        XCTAssertEqual(nav.next(), Loc(doc: 4, pane: .right, index: 0))
        XCTAssertEqual(nav.previous(), Loc(doc: 4, pane: .right, index: 0))
        XCTAssertEqual(nav.ordinal, 1)
    }

    // MARK: DocumentFindScanner — count matches on page 0 (left) / page 1 (right)

    func testPaneMatchCountsBucketsByPageAndIgnoresPageTwoPlus() {
        // page 0: "Alpha" ×2, page 1: "Alpha" ×1, page 2: "Alpha" ×1 (must be ignored — not displayable).
        let doc = makeTextPDF(pages: ["Alpha Alpha bravo", "Alpha charlie", "Alpha delta"])
        XCTAssertEqual(doc.pageCount, 3, "precondition: synthesized 3-page PDF")
        XCTAssertTrue(doc.page(at: 0)?.string?.lowercased().contains("alpha") == true,
                      "precondition: PDFKit can extract the drawn text")

        let counts = DocumentFindScanner.paneMatchCounts(in: doc, query: "alpha")   // case-insensitive
        XCTAssertEqual(counts.left, 2)
        XCTAssertEqual(counts.right, 1)
    }

    func testPaneMatchCountsEmptyQueryIsZero() {
        let doc = makeTextPDF(pages: ["Alpha", "Alpha"])
        let counts = DocumentFindScanner.paneMatchCounts(in: doc, query: "")
        XCTAssertEqual(counts.left, 0)
        XCTAssertEqual(counts.right, 0)
    }

    func testPaneMatchCountsNoMatchIsZero() {
        let doc = makeTextPDF(pages: ["Alpha", "Bravo"])
        let counts = DocumentFindScanner.paneMatchCounts(in: doc, query: "zulu")
        XCTAssertEqual(counts.left, 0)
        XCTAssertEqual(counts.right, 0)
    }

    func testPaneMatchCountsSinglePageHasNoRight() {
        let doc = makeTextPDF(pages: ["Alpha alpha"])   // one page only
        let counts = DocumentFindScanner.paneMatchCounts(in: doc, query: "alpha")
        XCTAssertEqual(counts.left, 2)
        XCTAssertEqual(counts.right, 0)
    }

    // MARK: helper — render selectable text into a real multi-page PDFDocument

    private func makeTextPDF(pages: [String]) -> PDFDocument {
        let pageRect = CGRect(x: 0, y: 0, width: 400, height: 400)
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        var box = pageRect
        let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)!
        for text in pages {
            ctx.beginPDFPage(nil)
            let attr = NSAttributedString(string: text,
                                          attributes: [.font: NSFont.systemFont(ofSize: 14)])
            let framesetter = CTFramesetterCreateWithAttributedString(attr)
            let path = CGPath(rect: pageRect.insetBy(dx: 20, dy: 20), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), path, nil)
            CTFrameDraw(frame, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return PDFDocument(data: data as Data)!
    }
}
