// DocumentViewerPagePairTests.swift — W23.m2 functional gate.
//
// Processor merges a multi-page document as image, text, image, text, … and `SPEC/tag-format.md`
// §"Interleaved multi-page variant" says consumers must NOT hard-assume two pages. Reader did: the
// panes were pinned to PDF pages 0 and 1, cycling stepped file URLs, and the find scanner discarded
// every match on page index >= 2 — so for any merged document with 2+ source pages, later scans and
// their OCR text were both unviewable and unfindable.
//
// These tests drive the REAL `DocumentViewerModel` over REAL on-disk PDFs (synthesized into an
// `mktemp` scratch directory — never a corpus, never the owner's archive root) and assert (a) every
// page pair is reachable, (b) find lands on a match past page 2, (c) the standard 2-page archival PDF
// behaves exactly as it did before, and (d) the later pair's image page actually RENDERS — pixels, not
// just a non-nil `PDFPage`, which is the one thing an accessibility-tree assertion cannot check.

import XCTest
import PDFKit
import AppKit
@testable import ArchiveReader

@MainActor
final class DocumentViewerPagePairTests: XCTestCase {

    private var scratch: URL?

    /// An `mktemp`-style scratch directory, created on first use and removed at teardown. FILE SAFETY:
    /// every byte this suite writes lives in here. (Created lazily from the tests rather than in
    /// `setUpWithError`, which is nonisolated and so cannot touch this `@MainActor` state.)
    private func scratchDir() throws -> URL {
        if let scratch { return scratch }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("W23m2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        scratch = dir
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Write an interleaved archival-style PDF: one image page + one OCR-text page per source scan.
    /// (Both are text-bearing here so PDFKit's own extraction can be asserted exactly; the page-pair
    /// model is page-INDEX arithmetic, so this is faithful to what it has to get right.)
    /// `inky` fills each page with repeated text, for the render guard — a real scan covers its page,
    /// and one sparse line is legitimately near-blank by area.
    private func writeInterleaved(scans: Int, named name: String,
                                  extraImagePage: Bool = false, inky: Bool = false) throws -> URL {
        func body(_ label: String) -> String {
            inky ? Array(repeating: label, count: 22).joined(separator: "\n") : label
        }
        var pages: [String] = []
        for s in 1...scans {
            pages.append(body("SCAN \(s) image page"))
            pages.append(body("Extracted text.\nOCR body of scan \(s)"))
        }
        if extraImagePage { pages.append(body("SCAN \(scans + 1) image page with no OCR")) }
        let url = try scratchDir().appendingPathComponent(name)
        XCTAssertTrue(TestPDFBuilder.write(pages: pages, to: url), "failed to write scratch PDF \(name)")
        return url
    }

    private func load(_ urls: [URL]) -> DocumentViewerModel {
        let model = DocumentViewerModel(persists: false)   // never write the owner's zoom defaults
        model.load(DocumentSelection(filePaths: urls.map(\.path)))
        return model
    }

    // MARK: every page pair is reachable

    func testInterleavedDocumentExposesEveryPagePair() throws {
        let url = try writeInterleaved(scans: 3, named: "three-scans.pdf")
        let model = load([url])

        XCTAssertEqual(model.current?.pageCount, 6, "precondition: 3 scans → 6 interleaved pages")
        XCTAssertEqual(model.pairCount, 3)
        XCTAssertEqual(model.pair, 0)

        // Pair 0 — unchanged from the old pages-0-and-1 behaviour.
        XCTAssertTrue(model.imagePage?.string?.contains("SCAN 1") == true)
        XCTAssertTrue(model.textPage?.string?.contains("scan 1") == true)

        // Pairs 1 and 2 — previously unreachable at any UI affordance.
        model.next()
        XCTAssertEqual(model.pair, 1)
        XCTAssertTrue(model.imagePage?.string?.contains("SCAN 2") == true,
                      "pair 1's image page must be PDF page 2 — the second scan")
        XCTAssertTrue(model.textPage?.string?.contains("scan 2") == true)

        model.next()
        XCTAssertEqual(model.pair, 2)
        XCTAssertTrue(model.imagePage?.string?.contains("SCAN 3") == true)
        XCTAssertTrue(model.textPage?.string?.contains("scan 3") == true)

        // …and it stops at the end of the document (single-file selection).
        XCTAssertFalse(model.canGoNext)
        model.next()
        XCTAssertEqual(model.pair, 2, "next() past the last pair of the last file must not move")
    }

    func testNextWalksPairsBeforeMovingToTheNextFileAndPreviousComesBackToTheLastPair() throws {
        let multi = try writeInterleaved(scans: 2, named: "a-two-scans.pdf")     // 2 pairs
        let single = try writeInterleaved(scans: 1, named: "b-one-scan.pdf")     // 1 pair
        let model = load([multi, single])

        XCTAssertEqual([model.index, model.pair], [0, 0])
        model.next(); XCTAssertEqual([model.index, model.pair], [0, 1], "pairs first, within the document")
        model.next(); XCTAssertEqual([model.index, model.pair], [1, 0], "only then the next file")
        XCTAssertFalse(model.canGoNext)

        // Backwards must land on the PREVIOUS document's LAST pair, or walking back skips content.
        model.previous(); XCTAssertEqual([model.index, model.pair], [0, 1])
        model.previous(); XCTAssertEqual([model.index, model.pair], [0, 0])
        XCTAssertFalse(model.canGoPrevious)
        model.previous(); XCTAssertEqual([model.index, model.pair], [0, 0], "previous() at the start is a no-op")
    }

    func testTrailingScanWithNoOCRPageIsStillReachable() throws {
        // 2 scans interleaved + a bare image page: 5 pages → 3 pairs, the last with no text page.
        let url = try writeInterleaved(scans: 2, named: "odd-tail.pdf", extraImagePage: true)
        let model = load([url])
        XCTAssertEqual(model.current?.pageCount, 5, "precondition")
        XCTAssertEqual(model.pairCount, 3, "rounding DOWN would make the trailing scan unreachable")

        model.next(); model.next()
        XCTAssertEqual(model.pair, 2)
        XCTAssertTrue(model.imagePage?.string?.contains("no OCR") == true, "the trailing scan is displayable")
        XCTAssertNil(model.textPage, "…and honestly reports having no OCR text page")
        XCTAssertFalse(model.hasTextPage)
        // The right pane degrades to the image page's own text layer rather than showing nothing.
        XCTAssertTrue(model.embeddedText?.contains("no OCR") == true)
    }

    func testPositionLabelNamesThePageOnlyWhenThereIsMoreThanOne() throws {
        let multi = try writeInterleaved(scans: 2, named: "multi.pdf")
        let plain = try writeInterleaved(scans: 1, named: "plain.pdf")

        let one = load([plain])
        XCTAssertEqual(one.positionLabel, "1 of 1", "a standard 2-page PDF keeps the original label")

        let model = load([multi, plain])
        XCTAssertEqual(model.positionLabel, "1 of 2 · page 1 of 2")
        model.next()
        XCTAssertEqual(model.positionLabel, "1 of 2 · page 2 of 2")
        model.next()
        XCTAssertEqual(model.positionLabel, "2 of 2", "the single-pair document stays plain")
    }

    func testPageIdentityChangesWithThePairSoThePanesRebuild() throws {
        let url = try writeInterleaved(scans: 2, named: "identity.pdf")
        let model = load([url])
        let first = model.pageIdentity
        model.next()
        XCTAssertNotEqual(model.pageIdentity, first,
                          "the panes are keyed on this; an unchanged identity leaves the old scan on screen")
    }

    func testLoadingAndCyclingDocumentsResetsToTheFirstPair() throws {
        let a = try writeInterleaved(scans: 3, named: "reset-a.pdf")
        let b = try writeInterleaved(scans: 3, named: "reset-b.pdf")
        let model = load([a, b])
        model.next(); model.next()
        XCTAssertEqual(model.pair, 2)
        model.next()                                     // → next file
        XCTAssertEqual([model.index, model.pair], [1, 0], "a newly loaded document opens on its first pair")
        model.next()
        model.load(DocumentSelection(filePaths: [a.path]))
        XCTAssertEqual([model.index, model.pair], [0, 0], "a fresh selection starts at the beginning")
    }

    // MARK: the standard archival PDF is untouched (regression guard)

    func testStandardTwoPageDocumentBehavesExactlyAsBefore() throws {
        let url = try writeInterleaved(scans: 1, named: "standard.pdf")
        let model = load([url])
        XCTAssertEqual(model.pairCount, 1)
        XCTAssertTrue(model.imagePage?.string?.contains("SCAN 1") == true, "page 0 → left pane")
        XCTAssertTrue(model.textPage?.string?.contains("Extracted text.") == true, "page 1 → right pane")
        XCTAssertTrue(model.hasTextPage)
        XCTAssertNil(model.embeddedText, "a document WITH a text page doesn't degrade to embedded text")
        XCTAssertFalse(model.canGoNext)
        XCTAssertFalse(model.canGoPrevious)
        XCTAssertEqual(model.pageIdentity, "0#0")
    }

    // MARK: find reaches past page 2

    func testFindNavigatesToAMatchOnALaterPairsTextPage() throws {
        // "zulu" appears ONLY in the OCR text of scan 3 → PDF page 5, i.e. pair 2's right pane.
        var pages: [String] = []
        for s in 1...3 {
            pages.append("SCAN \(s) image page")
            pages.append("Extracted text.\nOCR body of scan \(s)" + (s == 3 ? " mentioning zulu" : ""))
        }
        let url = try scratchDir().appendingPathComponent("find-late.pdf")
        XCTAssertTrue(TestPDFBuilder.write(pages: pages, to: url))
        let model = load([url])
        XCTAssertTrue(model.current?.page(at: 5)?.string?.contains("zulu") == true, "precondition")

        model.findQuery = "zulu"
        model.performFind()

        XCTAssertEqual(model.findTotal, 1, "the match on page 5 used to be discarded entirely")
        XCTAssertEqual(model.findOrdinal, 1)
        XCTAssertEqual(model.pair, 2, "find must move the viewer to the match's page pair")
        XCTAssertEqual(model.focusedPane, .right, "the match is on the OCR text page of that pair")
        XCTAssertTrue(model.textPage?.string?.contains("zulu") == true,
                      "the pane the user is looking at actually contains the match")
        XCTAssertEqual(model.findStatusText, "1 of 1")
    }

    func testFindWalksMatchesAcrossPairsAndDocumentsInReadingOrder() throws {
        // doc A: "zulu" on page 0 (pair 0 image) and page 3 (pair 1 text). doc B: page 1 (pair 0 text).
        let a = try scratchDir().appendingPathComponent("walk-a.pdf")
        XCTAssertTrue(TestPDFBuilder.write(pages: ["SCAN 1 zulu image", "Extracted text.\nbody one",
                                                   "SCAN 2 image", "Extracted text.\nbody two zulu"], to: a))
        let b = try scratchDir().appendingPathComponent("walk-b.pdf")
        XCTAssertTrue(TestPDFBuilder.write(pages: ["SCAN 1 image", "Extracted text.\nzulu again"], to: b))

        let model = load([a, b])
        model.findQuery = "zulu"
        model.performFind()

        XCTAssertEqual(model.findTotal, 3)
        XCTAssertEqual([model.index, model.pair], [0, 0]); XCTAssertEqual(model.focusedPane, .left)
        model.findNext()
        XCTAssertEqual([model.index, model.pair], [0, 1], "second match is on a LATER pair of the same file")
        XCTAssertEqual(model.focusedPane, .right)
        model.findNext()
        XCTAssertEqual([model.index, model.pair], [1, 0], "third match is in the next file")
        model.findNext()
        XCTAssertEqual([model.index, model.pair], [0, 0], "wraps back to the first match")
        XCTAssertEqual(model.findOrdinal, 1)
    }

    func testCopyArchivePageLinkNamesThePairOnScreen() throws {
        let url = try writeInterleaved(scans: 3, named: "link.pdf")
        let model = load([url])
        // 1-based PDF page of the image page of the displayed pair: pair 0 → 1, pair 1 → 3, pair 2 → 5.
        XCTAssertEqual(DocumentPagePairs.imagePageIndex(pair: model.pair) + 1, 1)
        model.next()
        XCTAssertEqual(DocumentPagePairs.imagePageIndex(pair: model.pair) + 1, 3,
                       "a link copied on pair 1 must not claim page 1")
        model.next()
        XCTAssertEqual(DocumentPagePairs.imagePageIndex(pair: model.pair) + 1, 5)
    }

    // MARK: it actually DRAWS (pixels, not just a non-nil PDFPage)

    /// STEP 3.5 render guard: a `PDFPage` that is non-nil but renders blank would satisfy every
    /// assertion above and still show the reader a grey rectangle. Rasterize the pair-1 image page and
    /// assert it has ink AND is visibly different from pair 0's — i.e. we really moved.
    func testLaterPairImagePageRendersNonBlankAndDiffersFromTheFirst() throws {
        let url = try writeInterleaved(scans: 2, named: "render.pdf", inky: true)
        let model = load([url])

        let firstPNG = try XCTUnwrap(rasterize(model.imagePage), "pair 0 image page did not rasterize")
        writeRenderArtifact(firstPNG, named: "w23m2-pair0-image.png")
        let firstStats = try XCTUnwrap(assertRendersNonBlank(RenderProbe.cgImage(fromPNG: firstPNG),
                                                            "pair 0 image page"))

        model.next()
        XCTAssertEqual(model.pair, 1)
        let laterPNG = try XCTUnwrap(rasterize(model.imagePage), "pair 1 image page did not rasterize")
        writeRenderArtifact(laterPNG, named: "w23m2-pair1-image.png")
        let laterStats = try XCTUnwrap(assertRendersNonBlank(RenderProbe.cgImage(fromPNG: laterPNG),
                                                            "pair 1 image page (unreachable before W23.m2)"))

        XCTAssertNotEqual(firstPNG, laterPNG,
                          "pair 1 rendered byte-identical pixels to pair 0 — the pane never moved")
        XCTAssertGreaterThan(firstStats.nonWhiteFraction, 0, "precondition: the first page has ink")
        XCTAssertGreaterThan(laterStats.nonWhiteFraction, 0)
    }

    /// Draw a PDF page to a bitmap the same way a `PDFView` would, then encode to PNG.
    private func rasterize(_ page: PDFPage?) -> Data? {
        guard let page else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let image = page.thumbnail(of: CGSize(width: bounds.width, height: bounds.height), for: .mediaBox)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cg = rep.cgImage else { return nil }
        return RenderProbe.pngData(from: cg)
    }
}
