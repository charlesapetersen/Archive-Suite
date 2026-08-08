// DocumentPageLinkTests.swift — W23.m4 functional gate.
//
// Page-level durable links (`archivereader://reveal?…&page=N`) were broken at all three ends, so the
// feature could not work at all:
//   1. the command that MAKES one was disabled in the document window (it required a focused
//      `NavigationModel`, which that scene has none of);
//   2. the page it wrote was always the pair's IMAGE page, whichever pane you were reading;
//   3. an incoming link's page was stashed in `pendingRevealPage` and then cleared — never read.
//
// These tests drive the REAL models over REAL on-disk PDFs synthesized into an `mktemp` scratch
// directory. FILE SAFETY: every byte written here (PDFs, the root marker, the `Unread` Finder tag that
// makes a fixture file discoverable) lives inside that scratch directory; nothing touches a corpus, and
// the archive root is pinned with `ARUITestRootPath` in a THROWAWAY defaults suite (`fixtureDefaults`),
// so the owner's real `archiveRootBookmark` is never read or written. This comment used to call that
// domain "volatile"; it was `.standard` — see `W26.fixturehang`.
//
// Non-vacuity, per defect: with the pre-fix rules these are RED —
//   (2) `testLinkCitesTextPageWhenTextPaneFocused` expects page 6 where the old
//       `imagePageIndex(pair:) + 1` produced 5, and `testPageLinkURLCarriesTheFocusedPanePage` asserts
//       that number all the way through the pasteboard URL;
//   (3) both `testRevealWithPageRequestsTheViewerOnThatPage` assertions fail (no request existed), and
//       every `goToPDFPage` test fails to compile against a model that couldn't go to a page at all.

import XCTest
import PDFKit
import AppKit
import ArchiveCore
@testable import ArchiveReader

@MainActor
final class DocumentPageLinkTests: XCTestCase {

    private var scratch: URL?

    /// An `mktemp`-style scratch directory, removed at teardown. (Created lazily from the tests rather
    /// than `setUpWithError`, which is nonisolated and so cannot touch this `@MainActor` state.)
    private func scratchDir() throws -> URL {
        if let scratch { return scratch }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("W23m4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        scratch = dir
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// An interleaved archival PDF: image page + OCR text page per scan (`SPEC/tag-format.md`
    /// §"Interleaved multi-page variant"), optionally with a trailing scan that has no text page.
    private func writeInterleaved(scans: Int, named name: String,
                                  extraImagePage: Bool = false) throws -> URL {
        var pages: [String] = []
        for s in 1...scans {
            pages.append("SCAN \(s) image page")
            pages.append("OCR TEXT of scan \(s)")
        }
        if extraImagePage { pages.append("SCAN \(scans + 1) image page with no OCR") }
        let url = try scratchDir().appendingPathComponent(name)
        XCTAssertTrue(TestPDFBuilder.write(pages: pages, to: url), "failed to write scratch PDF \(name)")
        return url
    }

    private func load(_ url: URL) -> DocumentViewerModel {
        let model = DocumentViewerModel(persists: false)   // never write the owner's zoom defaults
        model.load(DocumentSelection(filePaths: [url.path]))
        return model
    }

    private func target(root: URL) -> ArchiveLinkTarget {
        ArchiveLinkTarget(rootPath: root.path,
                          marker: RootMarker(guid: UUID(), name: "scratch", kind: .reader, createdAt: Date()))
    }

    // MARK: - Defect 2 — the page a link cites is the page you are reading

    func testLinkCitesImagePageWhenImagePaneFocused() throws {
        let model = load(try writeInterleaved(scans: 3, named: "three-scans.pdf"))
        XCTAssertEqual(model.focusedPageNumber, 1, "pair 0, image pane → PDF page 1")

        model.next(); model.next()                       // → pair 2
        model.focusPane(.left)
        XCTAssertEqual(model.pair, 2)
        XCTAssertEqual(model.focusedPageNumber, 5, "pair 2's image page is the 5th PDF page")
    }

    func testLinkCitesTextPageWhenTextPaneFocused() throws {
        let model = load(try writeInterleaved(scans: 3, named: "three-scans.pdf"))
        model.focusPane(.right)
        XCTAssertEqual(model.focusedPageNumber, 2, "pair 0's OCR text page is the 2nd PDF page")

        model.next(); model.next()                       // → pair 2
        model.focusPane(.right)
        XCTAssertNotNil(model.textPage, "pair 2 has an OCR text page")
        // The whole point of the fix: reading scan 3's OCR text and citing it must name PAGE 6.
        // The old rule cited page 5 (the scan) here, so a quote's citation pointed at the image.
        XCTAssertEqual(model.focusedPageNumber, 6)
    }

    func testLinkFallsBackToImagePageWhenPairHasNoTextPage() throws {
        // 3 scans + a trailing scan with no OCR → 7 pages, so the last pair (3) has no text page.
        let model = load(try writeInterleaved(scans: 3, named: "trailing-scan.pdf", extraImagePage: true))
        XCTAssertEqual(model.pairCount, 4)
        for _ in 0..<3 { model.next() }
        XCTAssertEqual(model.pair, 3)
        XCTAssertNil(model.textPage, "the trailing scan has no OCR text page")
        model.focusPane(.right)
        // Never cite page 8 of a 7-page document, even if focus were somehow on the missing pane.
        XCTAssertEqual(model.focusedPageNumber, 7, "degrades to the pair's image page")
    }

    func testPageLinkURLCarriesTheFocusedPanePage() async throws {
        let root = try scratchDir()
        let url = try writeInterleaved(scans: 3, named: "cite-me.pdf")
        let model = load(url)
        model.next(); model.next()                       // → pair 2
        model.focusPane(.right)

        let t = target(root: root)
        let item = await model.archivePageLink(target: t)
        let text = try XCTUnwrap(item?.string(forType: .string))
        let parsed = DurableLink(url: try XCTUnwrap(URL(string: text)))
        guard case .readerReveal(let guid, let rel, let page) = parsed else {
            return XCTFail("expected a readerReveal link, got \(String(describing: parsed))")
        }
        XCTAssertEqual(guid, t.marker.guid, "the link carries the root marker's GUID")
        XCTAssertEqual(rel, "cite-me.pdf", "root-relative path")
        XCTAssertEqual(page, 6, "the link cites the OCR text page being read, not the scan")
    }

    func testPageLinkNeedsNoNavigationModel() async throws {
        // Defect 1 in model terms: everything the command needs is a focused viewer + an
        // `ArchiveLinkTarget`. Nothing here constructs a NavigationModel, and the link still resolves.
        let root = try scratchDir()
        let model = load(try writeInterleaved(scans: 1, named: "standalone.pdf"))
        let item = await model.archivePageLink(target: target(root: root))
        XCTAssertEqual(item?.string(forType: .string)?.hasPrefix("archivereader://reveal?"), true)
        XCTAssertNotNil(item?.data(forType: NSPasteboard.PasteboardType(ArchiveLinkUTI.type)),
                        "the rich payload Notes reads on paste is present too")
    }

    func testNoDocumentLoadedYieldsNoLink() async throws {
        let root = try scratchDir()
        let model = DocumentViewerModel(persists: false)
        let item = await model.archivePageLink(target: target(root: root))
        XCTAssertNil(item, "no document → no link (rather than a link to nothing)")
    }

    // MARK: - Defect 3a — a cited page is somewhere the viewer can actually go

    func testGoToPDFPageLandsOnTheCitedTextPageAndPane() throws {
        let model = load(try writeInterleaved(scans: 3, named: "three-scans.pdf"))
        model.goToPDFPage(6)
        XCTAssertEqual(model.pair, 2, "PDF page 6 is pair 2's OCR text page")
        XCTAssertEqual(model.focusedPane, .right, "focus follows the cited page's pane")
        // Prove the PANES actually moved, not just an integer: the right pane holds scan 3's OCR text.
        XCTAssertEqual(model.textPage?.string?.contains("OCR TEXT of scan 3"), true)
        XCTAssertEqual(model.imagePage?.string?.contains("SCAN 3 image page"), true)
    }

    func testGoToPDFPageLandsOnTheCitedImagePage() throws {
        let model = load(try writeInterleaved(scans: 3, named: "three-scans.pdf"))
        model.goToPDFPage(5)
        XCTAssertEqual(model.pair, 2)
        XCTAssertEqual(model.focusedPane, .left, "an image page focuses the image pane")
        XCTAssertEqual(model.imagePage?.string?.contains("SCAN 3 image page"), true)
    }

    func testGoToPDFPageClampsOutOfRangePages() throws {
        let model = load(try writeInterleaved(scans: 2, named: "two-scans.pdf"))
        model.goToPDFPage(99)                            // a link into a since-shortened document
        XCTAssertEqual(model.pair, model.pairCount - 1, "clamped to the last pair, not left blank")
        XCTAssertNotNil(model.imagePage)
        model.goToPDFPage(0)                             // a malformed 0/negative page
        XCTAssertEqual(model.pair, 0)
        XCTAssertNotNil(model.imagePage)
    }

    func testGoToPDFPageDegradesWhenTheCitedTextPageIsGone() throws {
        // A link cited page 8 (pair 3's OCR text) but this document's last pair is a text-less scan.
        let model = load(try writeInterleaved(scans: 3, named: "trailing-scan.pdf", extraImagePage: true))
        model.goToPDFPage(8)
        XCTAssertEqual(model.pair, 3)
        XCTAssertNil(model.textPage)
        XCTAssertEqual(model.focusedPane, .left, "never focus a pane that holds no page")
        XCTAssertNotNil(model.imagePage, "the scan itself is still shown")
    }

    func testCopiedPageLinkRoundTripsToTheSamePage() async throws {
        // The end-to-end contract: what you cite is what a reader gets back.
        let root = try scratchDir()
        let url = try writeInterleaved(scans: 4, named: "roundtrip.pdf")
        let source = load(url)
        source.next(); source.next(); source.next()      // → pair 3
        source.focusPane(.right)

        let item = await source.archivePageLink(target: target(root: root))
        let text = try XCTUnwrap(item?.string(forType: .string))
        guard case .readerReveal(_, _, let page) = DurableLink(url: try XCTUnwrap(URL(string: text))),
              let citedPage = page else {
            return XCTFail("the copied link carried no page")
        }

        let reopened = load(url)                          // a fresh window, as a reveal would open
        reopened.goToPDFPage(citedPage)
        XCTAssertEqual(reopened.pair, source.pair)
        XCTAssertEqual(reopened.focusedPane, source.focusedPane)
        XCTAssertEqual(reopened.textPage?.string, source.textPage?.string,
                       "the reader lands on the very page that was cited")
        XCTAssertEqual(reopened.focusedPageNumber, citedPage, "and citing it again reproduces the link")
    }

    // MARK: - Defect 3b — reveal asks for the viewer instead of dropping the page

    /// A scratch archive root the navigation model will adopt: a root marker plus one discoverable
    /// (`Unread`-tagged) PDF. Returns the root, the marker GUID and the file's path.
    private func makeScratchRoot(pdfNamed name: String = "cited.pdf",
                                 scans: Int = 3) throws -> (root: URL, guid: UUID, filePath: String) {
        let root = try scratchDir()
        let guid = UUID()
        let marker = RootMarker(guid: guid, name: "scratch", kind: .reader, createdAt: Date())
        try JSONEncoder().encode(marker).write(to: root.appendingPathComponent(RootMarker.filename))
        let pdf = try writeInterleaved(scans: scans, named: name)
        // The library's fixture loader only surfaces files carrying Read/Unread — the production
        // predicate. Scratch file, scratch tag.
        try (pdf as NSURL).setResourceValue(["Unread"], forKey: .tagNamesKey)
        return (root, guid, pdf.path)
    }

    /// A NavigationModel pinned to a scratch root in a throwaway defaults domain (`fixtureDefaults`),
    /// so nothing it persists — the pin included — can reach the owner's app.
    private func navModel(root: URL, _ testName: String = #function) -> NavigationModel {
        fixtureNavigationModel(pinnedTo: root, testName)
    }

    func testRevealWithPageRequestsTheViewerOnThatPage() throws {
        let (root, guid, filePath) = try makeScratchRoot()
        let model = navModel(root: root)
        XCTAssertEqual(model.rootStore.rootMarker?.guid, guid)
        XCTAssertTrue(model.library.files.contains { $0.url.path == filePath },
                      "precondition: the scratch PDF is discoverable")
        XCTAssertEqual(model.openViewerRequest, 0)

        model.revealAndSelect(rootGUID: guid, relativePath: "cited.pdf", page: 6)

        XCTAssertFalse(model.selection.isEmpty, "reveal still selects the row")
        XCTAssertEqual(model.openViewerRequest, 1, "…and now also asks for the viewer")
        XCTAssertEqual(model.openViewerSelection?.filePaths, [filePath])
        XCTAssertEqual(model.openViewerSelection?.initialPage, 6,
                       "the cited page survives the reveal — it used to be cleared unread")
    }

    func testRevealWithoutPageDoesNotOpenAViewer() throws {
        let (root, guid, _) = try makeScratchRoot()
        let model = navModel(root: root)
        model.revealAndSelect(rootGUID: guid, relativePath: "cited.pdf", page: nil)
        XCTAssertFalse(model.selection.isEmpty, "a document-level link still selects the row")
        XCTAssertEqual(model.openViewerRequest, 0, "but opens no window — that is not what it asked for")
    }

    func testRevealForTheWrongArchiveRequestsNothing() throws {
        let (root, _, _) = try makeScratchRoot()
        let model = navModel(root: root)
        model.revealAndSelect(rootGUID: UUID(), relativePath: "cited.pdf", page: 6)
        XCTAssertTrue(model.statusMessage.contains("different archive"))
        XCTAssertEqual(model.openViewerRequest, 0, "a mismatched root opens nothing")
    }

    func testRevealOfAnAbsentFileRequestsNothing() throws {
        let (root, guid, _) = try makeScratchRoot()
        let model = navModel(root: root)
        model.revealAndSelect(rootGUID: guid, relativePath: "not-here.pdf", page: 6)
        XCTAssertEqual(model.openViewerRequest, 0, "no target → no viewer")
        XCTAssertTrue(model.selection.isEmpty)
    }

    func testDeepLinkURLReachesTheViewerRequestWithItsPage() throws {
        // The whole incoming path: URL → router → nav → viewer request.
        let (root, guid, filePath) = try makeScratchRoot()
        let model = navModel(root: root)
        let router = DeepLinkRouter()
        router.nav = model
        let link = DurableLink.readerReveal(rootGUID: guid, relativePath: "cited.pdf", page: 4)

        router.handle(link.url)

        XCTAssertEqual(model.openViewerRequest, 1)
        XCTAssertEqual(model.openViewerSelection?.filePaths, [filePath])
        XCTAssertEqual(model.openViewerSelection?.initialPage, 4)
    }

    // MARK: - Defect 1 — the target the command needs, without a NavigationModel

    func testLinkContextPublishesAndClearsTheTarget() {
        let context = ArchiveLinkContext()
        XCTAssertNil(context.target, "no root granted → no target → the command stays disabled")

        let root = URL(fileURLWithPath: "/tmp/W23m4-context", isDirectory: true)
        let marker = RootMarker(guid: UUID(), name: "scratch", kind: .reader, createdAt: Date())
        context.update(rootPath: root.path, marker: marker)
        XCTAssertEqual(context.target, ArchiveLinkTarget(rootPath: root.path, marker: marker))

        // A root whose marker could not be read is not linkable — clear rather than go stale.
        context.update(rootPath: root.path, marker: nil)
        XCTAssertNil(context.target)

        // A root switch replaces the target (never leaves a document window citing the old archive).
        let other = URL(fileURLWithPath: "/tmp/W23m4-other", isDirectory: true)
        let otherMarker = RootMarker(guid: UUID(), name: "other", kind: .reader, createdAt: Date())
        context.update(rootPath: other.path, marker: otherMarker)
        XCTAssertEqual(context.target?.rootPath, other.path)
        XCTAssertEqual(context.target?.marker.guid, otherMarker.guid)
    }

    func testNavigationModelPublishesItsRootAsTheLinkTarget() throws {
        let (root, guid, _) = try makeScratchRoot()
        let model = navModel(root: root)
        let context = ArchiveLinkContext()
        model.attach(linkContext: context)
        // The store's DISCOVERED spelling, not `root.path`: the target exists to be stripped off
        // discovered file paths, so publishing the caller's spelling made every link under an aliased
        // or symlinked root degrade to a bare filename. (`W26.symroot-fu1`.)
        XCTAssertEqual(context.target?.rootPath, model.rootStore.discoveredPathPrefix,
                       "the document window's target comes from the navigation window's root store")
        XCTAssertNotNil(context.target?.rootPath)
        XCTAssertEqual(context.target?.marker.guid, guid)
    }
}
