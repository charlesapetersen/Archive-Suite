import XCTest
import SwiftUI
@testable import ArchiveReader

/// W40.reader-page-views: Preview's page views — Show/Hide Thumbnails ⌥⌘2 (one item that toggles,
/// W40.reader-thumbnails-toggle) and Contact Sheet ⌥⌘6 — across every file in the viewer.
@MainActor
final class PageViewsTests: XCTestCase {
    /// Three files: a five-page scan (three pairs, the last an odd trailing scan), and two one-page files.
    private func fixtures() throws -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("page-views-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        var urls: [URL] = []
        for (name, pages) in [("a.pdf", 5), ("b.pdf", 1), ("c.pdf", 1)] {
            let url = dir.appendingPathComponent(name)
            XCTAssertTrue(TestPDFBuilder.write(pages: (0..<pages).map { "\(name) PAGE \($0 + 1)" }, to: url))
            urls.append(url)
        }
        return urls
    }

    private func viewer(_ urls: [URL], supportsPageViews: Bool = true) -> DocumentViewerModel {
        let model = DocumentViewerModel(persists: false, supportsPageOverview: supportsPageViews, thumbnailer: nil)
        model.load(DocumentSelection(filePaths: urls.map(\.path)))
        return model
    }

    func testThePageViewsAreOneAtATimeAndOnlyTheContactSheetEndsOnAMove() throws {
        let reader = viewer(try fixtures())
        XCTAssertEqual(reader.pageView, .single)
        reader.setPageView(.thumbnails)
        XCTAssertEqual(reader.pageView, .thumbnails)
        reader.next()
        XCTAssertEqual(reader.pageView, .thumbnails, "the sidebar stays up while the reader moves")
        reader.setPageView(.contactSheet)
        XCTAssertEqual(reader.pageView, .contactSheet)
        reader.next()
        XCTAssertEqual(reader.pageView, .thumbnails, "a move ends the contact sheet and returns to the sidebar")
        reader.setPageView(.single)
        XCTAssertEqual(reader.pageView, .single)
        XCTAssertFalse(reader.showingThumbnails)
        reader.setPageView(.contactSheet)
        reader.setShowingAllPages(false)
        XCTAssertEqual(reader.pageView, .single)
    }

    /// Show/Hide Thumbnails is one item: ⌥⌘2 toggles the sidebar, its name follows it, and from the contact sheet
    /// it shows the sidebar, as Preview's does (W40.reader-thumbnails-toggle).
    func testShowHideThumbnailsIsOneToggle() throws {
        let reader = viewer(try fixtures())
        let item = ReaderCommand.showThumbnails
        XCTAssertEqual(item.title(showing: reader.pageView == .thumbnails), "Show Thumbnails")
        reader.toggleThumbnails()
        XCTAssertEqual(reader.pageView, .thumbnails)
        XCTAssertEqual(item.title(showing: reader.pageView == .thumbnails), "Hide Thumbnails")
        reader.toggleThumbnails()
        XCTAssertEqual(reader.pageView, .single)
        XCTAssertFalse(reader.showingThumbnails)
        reader.setPageView(.contactSheet)
        XCTAssertEqual(item.title(showing: reader.pageView == .thumbnails), "Show Thumbnails")
        reader.toggleThumbnails()
        XCTAssertEqual(reader.pageView, .thumbnails, "from the contact sheet the toggle shows the sidebar")
        let none = viewer([])
        none.toggleThumbnails()
        XCTAssertEqual(none.pageView, .single, "nothing open, nothing to show")
    }

    func testAThumbnailGoesToItsFileAndPair() throws {
        let urls = try fixtures()
        let reader = viewer(urls)
        reader.setPageView(.thumbnails)
        reader.openThumbnail(file: 0, pair: 2)
        XCTAssertEqual(reader.index, 0)
        XCTAssertEqual(reader.pair, 2)
        XCTAssertEqual(reader.focusedPageNumber, 5, "a thumbnail is the pair's image page")
        reader.openThumbnail(file: 2, pair: 0)
        XCTAssertEqual(reader.currentFilePath, urls[2].path)
        XCTAssertEqual(reader.pair, 0)
        XCTAssertTrue(reader.imagePage?.string?.contains("c.pdf PAGE 1") == true)
        reader.openThumbnail(file: 0, pair: 9)
        XCTAssertEqual(reader.index, 0)
        XCTAssertEqual(reader.pair, 2, "a pair past the end lands on the last one")
        reader.openThumbnail(file: 7, pair: 0)
        XCTAssertEqual(reader.index, 0, "a file that is not in the viewer changes nothing")
        XCTAssertEqual(reader.pageView, .thumbnails)
    }

    func testTheContactSheetSpansTheFilesInTheViewer() async throws {
        let urls = try fixtures()
        let reader = viewer([urls[1], urls[2]])
        XCTAssertTrue(reader.canShowAllPages, "two one-page files still make a sheet")
        XCTAssertEqual(reader.pageCounts.count(urls[1].path), 1, "the current file's count is known when it loads")
        XCTAssertNil(reader.pageCounts.count(urls[2].path), "the others are read as their sections appear")
        reader.setPageView(.contactSheet)
        reader.openTiledPage(file: 1, page: 2)
        XCTAssertEqual(reader.index, 0, "a file not yet counted shows only its first page, so no other opens")
        XCTAssertTrue(reader.showingAllPages)
        await reader.pageCounts.request(urls[2].path)
        XCTAssertEqual(reader.pageCounts.count(urls[2].path), 1)
        reader.openTiledPage(file: 1, page: 2)
        XCTAssertEqual(reader.index, 0, "a page past the end of its file changes nothing")
        XCTAssertTrue(reader.showingAllPages)
        reader.openTiledPage(file: 1, page: 1)
        XCTAssertEqual(reader.currentFilePath, urls[2].path)
        XCTAssertFalse(reader.showingAllPages)
        let fresh = viewer([urls[1], urls[2]])
        fresh.setPageView(.contactSheet)
        fresh.openTiledPage(file: 1, page: 1)
        XCTAssertEqual(fresh.currentFilePath, urls[2].path, "the stand-in first page opens before the count is read")

        let five = viewer([urls[0], urls[1]])
        five.setPageView(.contactSheet)
        five.openTiledPage(file: 0, page: 4)
        XCTAssertEqual(five.focusedPageNumber, 4, "the sheet still reaches OCR pages (W40.reader-tiled-pages)")
        XCTAssertEqual(five.focusedPane, .right)

        // Counts are kept only for the files now in the viewer.
        five.load(DocumentSelection(filePaths: [urls[2].path]))
        XCTAssertNil(five.pageCounts.count(urls[0].path))
        XCTAssertEqual(five.pageCounts.count(urls[2].path), 1)
        let missing = OpenFilePageCounts()
        let gone = "/tmp/does-not-exist-\(UUID()).pdf"
        await missing.request(gone)
        XCTAssertEqual(missing.count(gone), 0, "a file that cannot be read counts no pages")
    }

    func testAViewerWithoutPageViewsAndASinglePageFile() throws {
        let urls = try fixtures()
        let none = viewer(urls, supportsPageViews: false)
        none.setPageView(.thumbnails)
        none.setPageView(.contactSheet)
        XCTAssertEqual(none.pageView, .single)
        let single = viewer([urls[1]])
        XCTAssertTrue(single.canShowThumbnails)
        XCTAssertFalse(single.canShowAllPages, "one page has nothing to lay out")
        single.setPageView(.thumbnails)
        XCTAssertEqual(single.pageView, .thumbnails)
    }

    /// The contact sheet is one run of tiles across the files (W40.reader-contact-sheet-grid): every page in order,
    /// a file not yet counted stands in with its first page, and one that cannot be opened keeps that page's id.
    func testTheContactSheetRunsEveryFilesPagesInOneGrid() {
        let counts: [String: Int] = ["/a.pdf": 3, "/b.pdf": 0]
        let cells = ContactSheetCell.cells(files: ["/a.pdf", "/b.pdf", "/c.pdf"]) { counts[$0] }
        XCTAssertEqual(cells.map(\.slot), [PageSlot(file: 0, index: 0), PageSlot(file: 0, index: 1),
                                           PageSlot(file: 0, index: 2), PageSlot(file: 1, index: 0),
                                           PageSlot(file: 2, index: 0)])
        XCTAssertEqual(cells.map(\.unreadable), [false, false, false, true, false])
        XCTAssertEqual(cells.map(\.path), ["/a.pdf", "/a.pdf", "/a.pdf", "/b.pdf", "/c.pdf"])
        XCTAssertEqual(Set(cells.map(\.id)).count, cells.count, "ids are unique across files")
        XCTAssertTrue(ContactSheetCell.cells(files: []) { _ in nil }.isEmpty)
    }

    /// The menu items' keys, as the table holds them.
    func testThePageViewCommandsAreBoundToPreviewsKeys() {
        XCTAssertEqual(ReaderCommand.showThumbnails.glyph, "⌥⌘2")
        XCTAssertFalse(ReaderCommand.allCases.contains { $0.key == CommandKey("1", [.command, .option]) },
                       "⌥⌘1 is free: the toggle replaced Hide Thumbnails")
        XCTAssertEqual(ReaderCommand.contactSheet.glyph, "⌥⌘6")
        XCTAssertFalse(ReaderCommand.allCases.contains { $0.reserved }, "no key is held for a later item")
    }

    /// Render guards: the sidebar and the sheet lay out their headings and cells for several files without a
    /// window (their pictures arrive asynchronously; `DocumentPageOverviewTests` draws the pictures themselves).
    func testTheSidebarAndTheSheetDrawForSeveralFiles() throws {
        let reader = viewer(try fixtures())
        reader.setPageView(.thumbnails)
        let sidebar = PageThumbnailSidebar(model: reader, pages: reader.pageCounts, idPrefix: "ar.doc")
        let sidebarPNG = try XCTUnwrap(RenderProbe.pngData(from: sidebar.list.frame(width: PageThumbnailSidebar.width),
                                                           size: CGSize(width: PageThumbnailSidebar.width, height: 600)))
        writeRenderArtifact(sidebarPNG, named: "w40-page-views-sidebar.png")
        assertRendersNonBlank(RenderProbe.cgImage(fromPNG: sidebarPNG), "thumbnail sidebar")
        let header = OpenFileHeader(name: "a.pdf", position: "1/3", current: true)
        let headerPNG = try XCTUnwrap(RenderProbe.pngData(from: header, size: CGSize(width: 150, height: 24)))
        assertRendersNonBlank(RenderProbe.cgImage(fromPNG: headerPNG), "the current file's heading")
        reader.setPageView(.contactSheet)
        let sheet = DocumentPageOverview(model: reader, pages: reader.pageCounts, idPrefix: "ar.doc")
        let sheetPNG = try XCTUnwrap(RenderProbe.pngData(from: sheet.grid, size: CGSize(width: 700, height: 600)))
        writeRenderArtifact(sheetPNG, named: "w40-page-views-contact-sheet.png")
        assertRendersNonBlank(RenderProbe.cgImage(fromPNG: sheetPNG), "contact sheet")
    }
}
