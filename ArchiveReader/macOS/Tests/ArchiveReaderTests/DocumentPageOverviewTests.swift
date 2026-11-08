import XCTest
import PDFKit
import SwiftUI
@testable import ArchiveReader

@MainActor
final class DocumentPageOverviewTests: XCTestCase {
    private func fixture(pages: Int = 5) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tiled-pages-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("pages.pdf")
        XCTAssertTrue(TestPDFBuilder.write(pages: (0..<pages).map { index in
            String(repeating: "PDF PAGE \(index + 1) — \(index == 3 ? "needle" : "archive")\n", count: 16)
        }, to: url))
        return url
    }

    private func model(_ url: URL, supportsOverview: Bool = true) -> DocumentViewerModel {
        let model = DocumentViewerModel(persists: false, supportsPageOverview: supportsOverview)
        model.load(DocumentSelection(filePaths: [url.path]))
        return model
    }

    func testEveryPhysicalPageOpensIncludingOCRAndOddTrailingScan() throws {
        let url = try fixture()
        let reader = model(url)
        XCTAssertTrue(reader.canShowAllPages)
        for number in 1...5 {
            reader.setShowingAllPages(true)
            XCTAssertTrue(reader.showingAllPages)
            XCTAssertTrue(reader.positionLabel.contains("all 5 PDF pages"))
            XCTAssertFalse(reader.hasTextSelection)
            reader.openTiledPage(number)
            XCTAssertFalse(reader.showingAllPages)
            XCTAssertEqual(reader.pair, (number - 1) / 2)
            XCTAssertEqual(reader.focusedPageNumber, number)
            let page = reader.focusedPane == .left ? reader.imagePage : reader.textPage
            XCTAssertTrue(page?.string?.contains("PDF PAGE \(number)") == true)
        }
        reader.setShowingAllPages(true)
        reader.openTiledPage(0)
        reader.openTiledPage(6)
        XCTAssertTrue(reader.showingAllPages, "an invalid tile cannot change the reading position")
        XCTAssertEqual(reader.focusedPageNumber, 5)
        reader.setShowingAllPages(false)
        XCTAssertEqual(reader.focusedPageNumber, 5, "returning to reading preserves the selected page")
    }

    func testFindCyclingAndLinksReturnToTheReadingPanes() throws {
        let reader = model(try fixture())
        reader.setShowingAllPages(true)
        reader.next()
        XCTAssertFalse(reader.showingAllPages)
        XCTAssertEqual(reader.pair, 1)
        reader.setShowingAllPages(true)
        reader.previous()
        XCTAssertFalse(reader.showingAllPages)
        XCTAssertEqual(reader.pair, 0)
        reader.setShowingAllPages(true)
        reader.beginFind()
        XCTAssertFalse(reader.showingAllPages)
        reader.findQuery = "needle"
        reader.setShowingAllPages(true)
        reader.findNext()
        XCTAssertFalse(reader.showingAllPages)
        XCTAssertEqual(reader.focusedPageNumber, 4, "the later OCR page with the match is visible")
        reader.setShowingAllPages(true)
        reader.findPrevious()
        XCTAssertFalse(reader.showingAllPages)
        reader.setShowingAllPages(true)
        reader.goToPDFPage(5)
        XCTAssertFalse(reader.showingAllPages)
        XCTAssertEqual(reader.focusedPageNumber, 5)
    }

    func testOverviewIsUnavailableForPreviewSinglePageAndFailedLoads() throws {
        let preview = model(try fixture(), supportsOverview: false)
        let single = model(try fixture(pages: 1))
        let missing = model(URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID()).pdf"))
        for reader in [preview, single, missing] {
            XCTAssertFalse(reader.canShowAllPages)
            reader.setShowingAllPages(true)
            XCTAssertFalse(reader.showingAllPages)
        }
        XCTAssertFalse(NSWindow.allowsAutomaticWindowTabbing,
                       "Reader's View menu must not offer automatic window tabbing")
    }

    func testActualTileRendererAndLabelDrawEveryPageWithoutChangingThePDF() async throws {
        let url = try fixture()
        let original = try Data(contentsOf: url)
        var rendered = Set<Data>()
        for index in 0..<5 {
            let result = await DocumentPageTileRenderer.shared.png(path: url.path, pageIndex: index)
            let png = try XCTUnwrap(result)
            rendered.insert(png)
            _ = try XCTUnwrap(assertRendersNonBlank(RenderProbe.cgImage(fromPNG: png), "PDF tile \(index + 1)"))
            let label = DocumentPageTileLabel(png: png, pageNumber: index + 1, selected: index == 4, finished: true)
            let labelPNG = try XCTUnwrap(RenderProbe.pngData(from: label, size: CGSize(width: 240, height: 290)))
            writeRenderArtifact(labelPNG, named: "w40-tiled-page-\(index + 1).png")
            _ = try XCTUnwrap(assertRendersNonBlank(RenderProbe.cgImage(fromPNG: labelPNG), "tile label \(index + 1)"))
        }
        XCTAssertEqual(rendered.count, 5, "later tiles must not reuse the first page's pixels")
        XCTAssertEqual(try Data(contentsOf: url), original, "overview rendering is read-only")
        let invalid = await DocumentPageTileRenderer.shared.png(path: url.path, pageIndex: 5)
        XCTAssertNil(invalid)
    }
}
