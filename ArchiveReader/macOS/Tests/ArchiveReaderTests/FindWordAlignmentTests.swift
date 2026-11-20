import XCTest
import PDFKit
import AppKit
import CoreText
@testable import ArchiveReader

/// W49.reader-find-word-align: Find pairs the image pane's matches with the text pane's through a word
/// alignment of the two pages, so a word the image page's text layer split or missed no longer shifts every
/// later hit by one. GUI-free.
@MainActor
final class FindWordAlignmentTests: XCTestCase {
    /// Each case-insensitive, non-overlapping match's UTF-16 offset, as PDFKit's find reports them here.
    private func offsets(_ query: String, in text: String) -> [Int] {
        var found: [Int] = []
        var from = text.startIndex
        while let r = text.range(of: query, options: [.caseInsensitive], range: from..<text.endIndex) {
            found.append(NSRange(r, in: text).location)
            from = r.upperBound
        }
        return found
    }

    private func hits(_ query: String, left: String, right: String) -> [PairHit] {
        FindWordAlignment.pairHits(leftText: left, leftMatches: offsets(query, in: left),
                                   rightText: right, rightMatches: offsets(query, in: right))
    }

    private func h(_ left: Int?, _ right: Int?) -> PairHit { PairHit(left: left, right: right) }

    /// The case behind the item: the text layer splits the first occurrence, so ordinal pairing put the
    /// image page's first match beside the text page's first, a different word, and every later hit too.
    func testASplitWordInTheTextLayerDoesNotShiftLaterHits() {
        let left = "Letter to Wash ington about the treaty. Washington replied; Washington signed."
        let right = "Letter to Washington about the treaty. Washington replied; Washington signed."
        XCTAssertEqual(hits("washington", left: left, right: right), [h(nil, 0), h(0, 1), h(1, 2)])
    }

    func testAWordTheTextLayerMissedIsAHitOfTheTextPaneAlone() {
        let left = "one alpha two three alpha four"
        let right = "one alpha two alpha three alpha four"
        XCTAssertEqual(hits("alpha", left: left, right: right), [h(0, 0), h(nil, 1), h(1, 2)])
    }

    func testAMatchOnlyTheImagePaneHasIsItsAlone() {
        let left = "alpha bravo alpha charlie alpha"
        let right = "alpha bravo charlie alpha"
        XCTAssertEqual(hits("alpha", left: left, right: right), [h(0, 0), h(1, nil), h(2, 1)])
    }

    func testIdenticalTextsPairByOrdinal() {
        let text = "zulu one zulu two zulu"
        XCTAssertEqual(hits("zulu", left: text, right: text), FindWordAlignment.ordinalHits(left: 3, right: 3))
    }

    /// A short query that matches more than once inside one word pairs the n-th on a word with the n-th on
    /// its counterpart.
    func testSeveralMatchesInsideOneWordPairInOrder() {
        let left = "a banana here"
        let right = "Extracted text. a banana here"
        XCTAssertEqual(hits("an", left: left, right: right), [h(0, 0), h(1, 1)])
    }

    /// Case, diacritics and width are folded before the words are compared; punctuation is not a word.
    func testWordsAreComparedNormalised() {
        let left = "CAFÉ, cafe; Café."
        let right = "café cafe CAFE"
        XCTAssertEqual(FindWordAlignment.words(in: left).map(\.key), ["cafe", "cafe", "cafe"])
        XCTAssertEqual(hits("caf", left: left, right: right), [h(0, 0), h(1, 1), h(2, 2)])
    }

    /// A phrase query spanning words is placed by the word it starts on; one starting in a space falls on
    /// the next word.
    func testMatchOffsetsMapToTheWordTheyStartOn() {
        let words = FindWordAlignment.words(in: "ab  cd ef")
        XCTAssertEqual(FindWordAlignment.wordIndex(of: 0, in: words), 0)
        XCTAssertEqual(FindWordAlignment.wordIndex(of: 1, in: words), 0)
        XCTAssertEqual(FindWordAlignment.wordIndex(of: 2, in: words), 1, "in the spaces → the next word")
        XCTAssertEqual(FindWordAlignment.wordIndex(of: 4, in: words), 1)
        XCTAssertEqual(FindWordAlignment.wordIndex(of: 9, in: words), 3, "past the last word")
        XCTAssertEqual(hits("b cd", left: "ab cd ef ab cd", right: "xx ab cd ef ab cd"), [h(0, 0), h(1, 1)])
    }

    /// A misread word the diff cannot line up still pairs with the other page's match in the same stretch
    /// between shared words; a split word whose stretch has no match on the other page stays alone.
    func testAMisreadWordPairsWithinItsStretch() {
        XCTAssertEqual(hits("the", left: "of thee treaty, the end", right: "of the treaty, the end"), [h(0, 0), h(1, 1)])
        XCTAssertEqual(hits("the", left: "of thee their treaty", right: "of the treaty"), [h(0, 0), h(1, nil)])
    }

    /// Texts with nothing in common are one stretch: their matches pair in order, every match exactly once.
    func testUnrelatedTextsPairInOrderWithinTheirOneStretch() {
        XCTAssertEqual(hits("x", left: "x1 x2 x3", right: "yx yx"), [h(0, 0), h(1, 1), h(2, nil)])
        let got = hits("x", left: "x1 common x2", right: "common yx yx")
        XCTAssertEqual(got.compactMap(\.left), [0, 1])
        XCTAssertEqual(got.compactMap(\.right), [0, 1])
    }

    // MARK: through PDFKit

    /// End to end on a real PDF: the scanner's offsets come from PDFKit's own selections, and the viewer
    /// steps both panes to the same occurrence after a word the image page's layer split.
    func testTheViewerSelectsTheSameOccurrenceInBothPanes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FindWordAlign-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("split.pdf")
        XCTAssertTrue(TestPDFBuilder.write(pages: ["Wash ington wrote. Washington left.",
                                                   "Extracted text.\nWashington wrote. Washington left."], to: url))
        let doc = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(DocumentFindScanner.pairHits(in: doc, query: "washington"), [[h(nil, 0), h(0, 1)]])

        let model = DocumentViewerModel(persists: false)   // never write the owner's zoom defaults
        model.load(DocumentSelection(filePaths: [url.path]))
        model.findQuery = "washington"
        model.performFind()
        XCTAssertEqual(model.findTotal, 2)
        XCTAssertNil(model.leftController.findCurrentIndex, "the split word has no match in the image pane")
        XCTAssertEqual(model.rightController.findCurrentIndex, 0)
        model.findNext()
        XCTAssertEqual([model.leftController.findCurrentIndex, model.rightController.findCurrentIndex], [0, 1],
                       "ordinal pairing put the image pane's match beside the text pane's first one")
    }

    // MARK: cost on a long document

    /// The cost the owner asked to have measured: a 150-pair document of ~600-word pages whose image layer
    /// is a damaged copy of the text page (a word split, dropped or misread every few words), searched for
    /// a word on every line. Prints the figures; the bound is loose, to catch a blow-up, not a regression.
    func testCostOnALongDocument() throws {
        let vocabulary = ["the", "treaty", "of", "commerce", "and", "navigation", "between", "parties",
                          "signed", "at", "Washington", "in", "year", "minister", "letter", "reply"]
        var rng = SystemRandomNumberGenerator()
        var pages: [String] = []
        for _ in 0..<150 {
            let words = (0..<600).map { _ in vocabulary.randomElement(using: &rng)! }
            var damaged: [String] = []
            for (i, w) in words.enumerated() {
                switch i % 9 {
                case 3: damaged.append(String(w.prefix(2)) + " " + String(w.dropFirst(2)))   // split
                case 6: break                                                                 // dropped
                case 8: damaged.append(w + "e")                                               // misread
                default: damaged.append(w)
                }
            }
            pages.append(damaged.joined(separator: " "))
            pages.append("Extracted text.\n" + words.joined(separator: " "))
        }
        let doc = try XCTUnwrap(PDFDocument(data: Self.densePDF(pages: pages)))
        XCTAssertEqual(doc.pageCount, 300)

        let clock = ContinuousClock()
        var counts: [(left: Int, right: Int)] = []
        let countTime = clock.measure { counts = DocumentFindScanner.pairMatchCounts(in: doc, query: "the") }
        var hits: [[PairHit]] = []
        let hitTime = clock.measure { hits = DocumentFindScanner.pairHits(in: doc, query: "the") }
        let matches = counts.reduce(0) { $0 + $1.left + $1.right }
        let paired = hits.joined().filter { $0.left != nil && $0.right != nil }.count
        print("W49.reader-find-word-align cost: 300 pages, \(matches) matches; find alone \(countTime), "
              + "find + word alignment \(hitTime); \(paired) hits paired across panes")
        XCTAssertEqual(hits.count, 150)
        for (pair, c) in zip(hits, counts) {
            XCTAssertEqual(pair.compactMap(\.left), Array(0..<c.left))
            XCTAssertEqual(pair.compactMap(\.right), Array(0..<c.right))
        }
        XCTAssertLessThan(hitTime, .seconds(30))

        // The worst case for the diff: two unrelated 1,500-word pages, nothing to line up.
        let a = (0..<1500).map { _ in vocabulary.randomElement(using: &rng)! + "a" }.joined(separator: " ")
        let b = (0..<1500).map { _ in vocabulary.randomElement(using: &rng)! + "b" }.joined(separator: " ")
        let worst = clock.measure { _ = self.hits("t", left: a, right: b) }
        print("W49.reader-find-word-align cost: two unrelated 1,500-word pages \(worst)")
        XCTAssertLessThan(worst, .seconds(10))
    }

    /// Letter-size pages at 5 pt, so a ~600-word page fits whole.
    private static func densePDF(pages: [String]) -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        var box = pageRect
        let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)!
        for text in pages {
            ctx.beginPDFPage(nil)
            let attr = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 5)])
            let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attr), CFRangeMake(0, 0),
                                                 CGPath(rect: pageRect.insetBy(dx: 20, dy: 20), transform: nil), nil)
            CTFrameDraw(frame, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }
}
