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
        let nav = FindNavigator(perPane: [(0, 0, .left, 0), (0, 0, .right, 0)])
        XCTAssertEqual(nav.total, 0)
        XCTAssertNil(nav.ordinal)
        XCTAssertNil(nav.current)
    }

    func testBuildOrdersByDocThenLeftBeforeRightAndSkipsZeroCounts() {
        // doc 0: 2 left + 1 right; doc 1: 0 left (skipped) + 3 right.
        let nav = FindNavigator(perPane: [
            (0, 0, .left, 2), (0, 0, .right, 1),
            (1, 0, .left, 0), (1, 0, .right, 3),
        ])
        XCTAssertEqual(nav.total, 6)
        XCTAssertEqual(nav.ordinal, 1)                       // starts on the first match
        XCTAssertEqual(nav.current, Loc(doc: 0, pair: 0, pane: .left, index: 0))
        XCTAssertEqual(nav.locations, [
            Loc(doc: 0, pair: 0, pane: .left,  index: 0),
            Loc(doc: 0, pair: 0, pane: .left,  index: 1),
            Loc(doc: 0, pair: 0, pane: .right, index: 0),
            Loc(doc: 1, pair: 0, pane: .right, index: 0),    // doc-1 left skipped (zero count)
            Loc(doc: 1, pair: 0, pane: .right, index: 1),
            Loc(doc: 1, pair: 0, pane: .right, index: 2),
        ])
    }

    /// W23.m2: pairs order between doc and pane — a match on a LATER pair of the same document is a
    /// distinct, addressable location, not a duplicate of the first pair's.
    func testBuildKeepsPairOrderWithinADocument() {
        let nav = FindNavigator(perPane: [
            (0, 0, .left, 1), (0, 0, .right, 1),
            (0, 1, .left, 1), (0, 1, .right, 2),
            (0, 2, .left, 1), (0, 2, .right, 0),
        ])
        XCTAssertEqual(nav.total, 6)
        XCTAssertEqual(nav.locations, [
            Loc(doc: 0, pair: 0, pane: .left,  index: 0),
            Loc(doc: 0, pair: 0, pane: .right, index: 0),
            Loc(doc: 0, pair: 1, pane: .left,  index: 0),
            Loc(doc: 0, pair: 1, pane: .right, index: 0),
            Loc(doc: 0, pair: 1, pane: .right, index: 1),
            Loc(doc: 0, pair: 2, pane: .left,  index: 0),
        ])
    }

    func testNextAdvancesThroughEveryMatchThenWraps() {
        var nav = FindNavigator(perPane: [(0, 0, .left, 2), (1, 0, .right, 1)])   // 3 matches
        XCTAssertEqual(nav.ordinal, 1)
        XCTAssertEqual(nav.next(), Loc(doc: 0, pair: 0, pane: .left, index: 1)); XCTAssertEqual(nav.ordinal, 2)
        XCTAssertEqual(nav.next(), Loc(doc: 1, pair: 0, pane: .right, index: 0)); XCTAssertEqual(nav.ordinal, 3)
        XCTAssertEqual(nav.next(), Loc(doc: 0, pair: 0, pane: .left, index: 0)); XCTAssertEqual(nav.ordinal, 1)  // wrap
    }

    func testPreviousFromFirstWrapsToLast() {
        var nav = FindNavigator(perPane: [(0, 0, .left, 1), (0, 0, .right, 1), (2, 0, .left, 1)])   // 3 matches
        XCTAssertEqual(nav.ordinal, 1)
        XCTAssertEqual(nav.previous(), Loc(doc: 2, pair: 0, pane: .left, index: 0))   // wrap back to the last
        XCTAssertEqual(nav.ordinal, 3)
        XCTAssertEqual(nav.previous(), Loc(doc: 0, pair: 0, pane: .right, index: 0))
        XCTAssertEqual(nav.ordinal, 2)
    }

    func testSingleMatchWrapsToItself() {
        var nav = FindNavigator(perPane: [(4, 0, .right, 1)])
        XCTAssertEqual(nav.total, 1)
        XCTAssertEqual(nav.current, Loc(doc: 4, pair: 0, pane: .right, index: 0))
        XCTAssertEqual(nav.next(), Loc(doc: 4, pair: 0, pane: .right, index: 0))
        XCTAssertEqual(nav.previous(), Loc(doc: 4, pair: 0, pane: .right, index: 0))
        XCTAssertEqual(nav.ordinal, 1)
    }

    // MARK: DocumentPagePairs — the interleaved image/OCR-text page-pair arithmetic (W23.m2)

    func testPairCountRoundsUpSoATrailingScanIsNotLost() {
        XCTAssertEqual(DocumentPagePairs.pairCount(pageCount: 0), 0)
        XCTAssertEqual(DocumentPagePairs.pairCount(pageCount: 1), 1)   // image only, no OCR page
        XCTAssertEqual(DocumentPagePairs.pairCount(pageCount: 2), 1)   // the standard archival PDF
        XCTAssertEqual(DocumentPagePairs.pairCount(pageCount: 3), 2)   // merged: 2-page doc + bare scan
        XCTAssertEqual(DocumentPagePairs.pairCount(pageCount: 4), 2)
        XCTAssertEqual(DocumentPagePairs.pairCount(pageCount: 9), 5)
        XCTAssertEqual(DocumentPagePairs.pairCount(pageCount: -1), 0, "a negative count must not go negative")
    }

    func testPageIndexMappingIsSelfConsistent() {
        for pair in 0..<6 {
            let image = DocumentPagePairs.imagePageIndex(pair: pair)
            let text = DocumentPagePairs.textPageIndex(pair: pair)
            XCTAssertEqual(text, image + 1)
            XCTAssertTrue(DocumentPagePairs.isImagePage(image))
            XCTAssertFalse(DocumentPagePairs.isImagePage(text))
            XCTAssertEqual(DocumentPagePairs.pair(ofPageIndex: image), pair)
            XCTAssertEqual(DocumentPagePairs.pair(ofPageIndex: text), pair)
        }
    }

    // MARK: DocumentFindScanner — matches bucketed per pair (page 2p → left, page 2p+1 → right)

    /// W23.m2 REGRESSION GUARD: the scanner used to `default: break` every match on page ≥ 2, so the OCR
    /// text of every scan after the first in a merged document was unfindable. Now each pair reports its
    /// own counts.
    func testPairMatchCountsBucketsEveryPageIncludingPastPageTwo() {
        // pair 0 → pages 0/1; pair 1 → pages 2/3; pair 2 → page 4 (image only, odd trailing page).
        let doc = makeTextPDF(pages: ["Alpha Alpha bravo", "Alpha charlie",
                                      "Alpha delta", "Alpha echo Alpha",
                                      "Alpha foxtrot"])
        XCTAssertEqual(doc.pageCount, 5, "precondition: synthesized 5-page PDF")
        XCTAssertTrue(doc.page(at: 4)?.string?.lowercased().contains("alpha") == true,
                      "precondition: PDFKit can extract the drawn text from the LAST page")

        let counts = DocumentFindScanner.pairMatchCounts(in: doc, query: "alpha")   // case-insensitive
        XCTAssertEqual(counts.count, 3, "one entry per page pair")
        XCTAssertEqual(counts[0].left, 2)
        XCTAssertEqual(counts[0].right, 1)
        XCTAssertEqual(counts[1].left, 1, "page 2 — silently discarded before W23.m2")
        XCTAssertEqual(counts[1].right, 2, "page 3 — silently discarded before W23.m2")
        XCTAssertEqual(counts[2].left, 1, "page 4 — the odd trailing scan")
        XCTAssertEqual(counts[2].right, 0, "the trailing pair has no text page")
    }

    func testPairMatchCountsEmptyQueryIsEmpty() {
        let doc = makeTextPDF(pages: ["Alpha", "Alpha"])
        XCTAssertTrue(DocumentFindScanner.pairMatchCounts(in: doc, query: "").isEmpty)
    }

    func testPairMatchCountsNoMatchIsZeroForEveryPair() {
        let doc = makeTextPDF(pages: ["Alpha", "Bravo", "Charlie", "Delta"])
        let counts = DocumentFindScanner.pairMatchCounts(in: doc, query: "zulu")
        XCTAssertEqual(counts.count, 2)
        XCTAssertTrue(counts.allSatisfy { $0.left == 0 && $0.right == 0 })
    }

    func testPairMatchCountsSinglePageHasNoRight() {
        let doc = makeTextPDF(pages: ["Alpha alpha"])   // one page only
        let counts = DocumentFindScanner.pairMatchCounts(in: doc, query: "alpha")
        XCTAssertEqual(counts.count, 1)
        XCTAssertEqual(counts[0].left, 2)
        XCTAssertEqual(counts[0].right, 0)
    }

    func testPairMatchCountsEmptyDocumentIsEmpty() {
        XCTAssertTrue(DocumentFindScanner.pairMatchCounts(in: PDFDocument(), query: "alpha").isEmpty)
    }

    // MARK: supportsFind — a viewer with no find bar cannot find (W26.previewzoom-fu1)

    /// The DEFAULT is find-capable: the document window renders the app's only find bar, and gating the
    /// menu on `supportsFind` would silently kill find everywhere if this flipped.
    func testDocumentWindowViewerSupportsFind() {
        XCTAssertTrue(DocumentViewerModel().supportsFind)
        XCTAssertTrue(DocumentViewerModel(persists: false).supportsFind,
                      "not derived from `persists` — a non-persisting viewer may still render a find bar")
    }

    /// The preview sheet's model. Since `W26.previewzoom` the sheet publishes its model to the scene, which
    /// enables every `.disabled(doc == nil)` item in the Document menu — and the sheet has no find bar, so
    /// `Find…`/`Find Next`/`Find Previous` were enabled with no way to type a query.
    func testPreviewViewerDoesNotSupportFind() {
        XCTAssertFalse(DocumentViewerModel(persists: false, supportsFind: false).supportsFind)
    }

    /// The invariant belongs to the MODEL, not to three menu modifiers: even driven directly — as a second
    /// publisher of the preview model could — find does nothing on a viewer that has no bar. A query can
    /// only have been set programmatically there, which is exactly the case the guard exists for.
    func testFindIsInertOnAViewerThatDoesNotSupportFind() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("W26previewzoomfu1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("finds.pdf")
        XCTAssertTrue(TestPDFBuilder.write(pages: ["Alpha alpha image", "Alpha OCR text"], to: url),
                      "precondition: scratch PDF written")

        // Control: the same document and query in a find-capable viewer — 3 matches.
        let window = DocumentViewerModel(persists: false)
        window.load(DocumentSelection(filePaths: [url.path]))
        window.findQuery = "alpha"
        window.performFind()
        XCTAssertEqual(window.findTotal, 3, "precondition: the query really does match this document")
        XCTAssertEqual(window.findOrdinal, 1)

        let preview = DocumentViewerModel(persists: false, supportsFind: false)
        preview.load(DocumentSelection(filePaths: [url.path]))
        preview.findQuery = "alpha"
        preview.performFind()
        XCTAssertEqual(preview.findTotal, 0, "no find bar → no search")
        XCTAssertNil(preview.findOrdinal)
        preview.findNext()
        preview.findPrevious()
        XCTAssertEqual(preview.findTotal, 0, "…and next/prev cannot rebuild the match list behind it")
        XCTAssertNil(preview.findOrdinal)
        XCTAssertEqual(preview.findStatusText, "", "nothing to report — the bar it would report in is absent")
    }

    // MARK: helper — render selectable text into a real multi-page PDFDocument

    private func makeTextPDF(pages: [String]) -> PDFDocument { TestPDFBuilder.textPDF(pages: pages) }
}
