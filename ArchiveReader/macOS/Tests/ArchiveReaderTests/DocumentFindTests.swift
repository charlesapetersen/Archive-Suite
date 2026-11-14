import XCTest
import PDFKit
import AppKit
import CoreText
import SwiftUI
@testable import ArchiveReader

/// In-viewer find: the pure match-navigation model (`FindNavigator`) and the PDFKit match counter
/// (`DocumentFindScanner`). GUI-free — the live highlight/scroll in the panes is verified separately.
@MainActor
final class DocumentFindTests: XCTestCase {

    // MARK: FindNavigator — pure navigation over the flat match list

    private typealias Loc = FindMatchLocation

    func testEmptyNavigatorHasNoMatches() {
        var nav = FindNavigator()
        XCTAssertEqual(nav.total, 0)
        XCTAssertTrue(nav.isEmpty)
        XCTAssertNil(nav.ordinal)
        XCTAssertNil(nav.current)
        XCTAssertNil(nav.next())
        XCTAssertNil(nav.previous())
    }

    func testEmptyPerPairCountsProduceEmptyNavigator() {
        let nav = FindNavigator(perPair: [(0, 0, 0, 0), (0, 1, 0, 0)])
        XCTAssertEqual(nav.total, 0)
        XCTAssertNil(nav.ordinal)
        XCTAssertNil(nav.current)
    }

    /// W40.fix-reader-find-both-panes: a hit is the k-th match of EACH pane of its pair, not a match of
    /// one pane, so the two panes step together; the busier pane sets the pair's hit count, and the
    /// other pane's missing ordinals are nil.
    func testBuildPairsThePanesMatchesIntoHits() {
        // doc 0: 2 image + 3 text matches → 3 hits; doc 1: none (skipped); doc 2: text only (no text layer).
        let nav = FindNavigator(perPair: [(0, 0, 2, 3), (1, 0, 0, 0), (2, 0, 0, 1)])
        XCTAssertEqual(nav.total, 4)
        XCTAssertEqual(nav.ordinal, 1)                       // starts on the first hit
        XCTAssertEqual(nav.locations, [
            Loc(doc: 0, pair: 0, index: 0, left: 0,   right: 0),
            Loc(doc: 0, pair: 0, index: 1, left: 1,   right: 1),
            Loc(doc: 0, pair: 0, index: 2, left: nil, right: 2),
            Loc(doc: 2, pair: 0, index: 0, left: nil, right: 0),
        ])
        XCTAssertTrue(nav.locations[0].holds(.left) && nav.locations[0].holds(.right))
        XCTAssertFalse(nav.locations[2].holds(.left))
    }

    /// W23.m2: pairs order between doc and hit — a match on a LATER pair of the same document is a
    /// distinct, addressable location, not a duplicate of the first pair's.
    func testBuildKeepsPairOrderWithinADocument() {
        let nav = FindNavigator(perPair: [(0, 0, 1, 1), (0, 1, 1, 2), (0, 2, 1, 0)])
        XCTAssertEqual(nav.total, 4)
        XCTAssertEqual(nav.locations, [
            Loc(doc: 0, pair: 0, index: 0, left: 0,   right: 0),
            Loc(doc: 0, pair: 1, index: 0, left: 0,   right: 0),
            Loc(doc: 0, pair: 1, index: 1, left: nil, right: 1),
            Loc(doc: 0, pair: 2, index: 0, left: 0,   right: nil),
        ])
    }

    func testNextAdvancesThroughEveryMatchThenWraps() {
        var nav = FindNavigator(perPair: [(0, 0, 2, 0), (1, 0, 0, 1)])   // 3 hits
        XCTAssertEqual(nav.ordinal, 1)
        XCTAssertEqual(nav.next(), Loc(doc: 0, pair: 0, index: 1, left: 1, right: nil)); XCTAssertEqual(nav.ordinal, 2)
        XCTAssertEqual(nav.next(), Loc(doc: 1, pair: 0, index: 0, left: nil, right: 0)); XCTAssertEqual(nav.ordinal, 3)
        XCTAssertEqual(nav.next(), Loc(doc: 0, pair: 0, index: 0, left: 0, right: nil)); XCTAssertEqual(nav.ordinal, 1)  // wrap
    }

    func testPreviousFromFirstWrapsToLast() {
        var nav = FindNavigator(perPair: [(0, 0, 1, 2), (2, 0, 1, 0)])   // 3 hits
        XCTAssertEqual(nav.ordinal, 1)
        XCTAssertEqual(nav.previous(), Loc(doc: 2, pair: 0, index: 0, left: 0, right: nil))   // wrap back to the last
        XCTAssertEqual(nav.ordinal, 3)
        XCTAssertEqual(nav.previous(), Loc(doc: 0, pair: 0, index: 1, left: nil, right: 1))
        XCTAssertEqual(nav.ordinal, 2)
    }

    func testSingleMatchWrapsToItself() {
        var nav = FindNavigator(perPair: [(4, 0, 0, 1)])
        let only = Loc(doc: 4, pair: 0, index: 0, left: nil, right: 0)
        XCTAssertEqual(nav.total, 1)
        XCTAssertEqual(nav.current, only)
        XCTAssertEqual(nav.next(), only)
        XCTAssertEqual(nav.previous(), only)
        XCTAssertEqual(nav.ordinal, 1)
    }

    // MARK: the extracted-text pane's matches (W40.fix-reader-find-both-panes)

    func testRangesFindEveryCaseInsensitiveMatchInOrder() {
        let text = "Alpha bravo ALPHA alphalpha"
        let found = DocumentFindScanner.ranges(of: "alpha", in: text).map { String(text[$0]) }
        XCTAssertEqual(found, ["Alpha", "ALPHA", "alpha"], "non-overlapping, like PDFKit's find")
        XCTAssertTrue(DocumentFindScanner.ranges(of: "", in: text).isEmpty)
        XCTAssertTrue(DocumentFindScanner.ranges(of: "zulu", in: text).isEmpty)
    }

    func testExtractedTextHighlightsEveryMatchAndMarksTheCurrentHit() {
        let text = "zulu one zulu two"
        let storage = NSTextStorage(string: text)
        let current = ExtractedTextPane.highlight(storage, find: (query: "ZULU", current: 1))
        var backgrounds: [(String, NSColor)] = []
        storage.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let color = value as? NSColor { backgrounds.append(((text as NSString).substring(with: range), color)) }
        }
        XCTAssertEqual(backgrounds.map(\.0), ["zulu", "zulu"], "both matches are highlighted")
        XCTAssertNotEqual(backgrounds[0].1, backgrounds[1].1, "the current hit stands out from the others")
        XCTAssertEqual(backgrounds[1].1, .findHighlightColor)
        XCTAssertEqual(current, NSRange(location: 9, length: 4), "the current hit is the one scrolled to")
        ExtractedTextPane.highlight(storage, find: nil)
        var any = false
        storage.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: storage.length)) { v, _, _ in
            if v != nil { any = true }
        }
        XCTAssertFalse(any, "no search, no highlight")
    }

    // MARK: DocumentPagePairs — the interleaved image/OCR-text page-pair arithmetic (W23.m2)

    func testPairCountRoundsUpSoATrailingScanIsNotLost() {
        XCTAssertEqual(DocumentPagePairs(pageCount: 0).count, 0)
        XCTAssertEqual(DocumentPagePairs(pageCount: 1).count, 1)   // image only, no OCR page
        XCTAssertEqual(DocumentPagePairs(pageCount: 2).count, 1)   // the standard archival PDF
        XCTAssertEqual(DocumentPagePairs(pageCount: 3).count, 2)   // merged: 2-page doc + bare scan
        XCTAssertEqual(DocumentPagePairs(pageCount: 4).count, 2)
        XCTAssertEqual(DocumentPagePairs(pageCount: 9).count, 5)
        XCTAssertEqual(DocumentPagePairs(pageCount: -1).count, 0, "a negative count must not go negative")
        XCTAssertNil(DocumentPagePairs(pageCount: 3).textPageIndex(pair: 1), "the trailing scan has no text page")
    }

    func testPageIndexMappingIsSelfConsistent() {
        let pairs = DocumentPagePairs(pageCount: 12)
        for pair in 0..<6 {
            let image = pairs.imagePageIndex(pair: pair)
            let text = pairs.textPageIndex(pair: pair)
            XCTAssertEqual(text, image + 1)
            XCTAssertTrue(pairs.isImagePage(image))
            XCTAssertFalse(pairs.isImagePage(image + 1))
            XCTAssertEqual(pairs.pair(ofPageIndex: image), pair)
            XCTAssertEqual(pairs.pair(ofPageIndex: image + 1), pair)
        }
    }

    /// W42.int-s5-searchable: a searchable page is a pair alone, so the pairs after it are not shifted by one.
    func testSearchablePagesArePairsAlone() {
        let pairs = DocumentPagePairs(roles: [.searchable, .image, .text, .searchable, .image])
        XCTAssertEqual(pairs.count, 4)
        XCTAssertEqual((0..<4).map { pairs.imagePageIndex(pair: $0) }, [0, 1, 3, 4])
        XCTAssertEqual((0..<4).map { pairs.textPageIndex(pair: $0) }, [nil, 2, nil, nil])
        XCTAssertEqual((0..<5).map { pairs.pair(ofPageIndex: $0) }, [0, 1, 1, 2, 3])
        XCTAssertEqual((0..<5).map { pairs.isImagePage($0) }, [true, true, false, true, true])
    }

    func testFindBucketsASearchableFileByItsOwnPairs() {
        let header = "Extracted text.\nmemo.jpg\nApple Vision \u{00B7} macOS Vision \u{00B7} 13 November 2026\nKind: printed"
        let doc = PDFDocument(data: TestPDFBuilder.textPDFData(pages: ["Alpha one", "Alpha scan", "Extracted text.\nAlpha two Alpha"],
                                                               carried: [header, nil, nil]))!
        let counts = DocumentFindScanner.pairMatchCounts(in: doc, query: "alpha")
        XCTAssertEqual(counts.map(\.left), [1, 1])
        XCTAssertEqual(counts.map(\.right), [0, 2])
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

        // Control: the same document and query in a find-capable viewer — 2 hits (the image page's two
        // matches, the first shared with the text page's one).
        let window = DocumentViewerModel(persists: false)
        window.load(DocumentSelection(filePaths: [url.path]))
        window.findQuery = "alpha"
        window.performFind()
        XCTAssertEqual(window.findTotal, 2, "precondition: the query really does match this document")
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
