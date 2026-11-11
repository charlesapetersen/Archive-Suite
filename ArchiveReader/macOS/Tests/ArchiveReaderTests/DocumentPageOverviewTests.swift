import XCTest
import PDFKit
import SwiftUI
import ArchiveCore
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

    /// The contact sheet and the thumbnails draw from the on-disk thumbnail cache (W40.reader-page-views): each
    /// page is its own picture, a second visit is read back from the cache, and the PDF is never touched.
    func testPageThumbnailsDrawEveryPageFromTheDiskCacheWithoutChangingThePDF() async throws {
        let url = try fixture()
        let original = try Data(contentsOf: url)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("page-thumbs-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: cache) }
        let thumbnailer = PDFThumbnailer(cacheDirectory: cache)
        var rendered = Set<Data>()
        for index in 0..<5 {
            let result = await PageThumbnails.image(path: url.path, pageIndex: index, maxPixel: 280,
                                                    thumbnailer: thumbnailer)
            let image = try XCTUnwrap(result, "page \(index + 1)")
            XCTAssertLessThanOrEqual(max(image.cgImage.width, image.cgImage.height), 280, "decoded down to its size")
            let png = try XCTUnwrap(RenderProbe.pngData(from: image.cgImage))
            rendered.insert(png)
            _ = try XCTUnwrap(assertRendersNonBlank(image.cgImage, "page picture \(index + 1)"))
            let label = PageThumbnailLabel(image: image, label: "PDF page \(index + 1)", selected: index == 4,
                                           finished: true, height: 220)
            let labelPNG = try XCTUnwrap(RenderProbe.pngData(from: label, size: CGSize(width: 240, height: 260)))
            writeRenderArtifact(labelPNG, named: "w40-page-views-tile-\(index + 1).png")
            _ = try XCTUnwrap(assertRendersNonBlank(RenderProbe.cgImage(fromPNG: labelPNG), "tile label \(index + 1)"))
        }
        XCTAssertEqual(rendered.count, 5, "later pages must not reuse the first page's pixels")
        let cached = try FileManager.default.contentsOfDirectory(atPath: cache.path).filter { $0.hasSuffix(".png") }
        XCTAssertEqual(cached.count, 5, "one cache entry per page")
        let again = await PageThumbnails.image(path: url.path, pageIndex: 2, maxPixel: 280, thumbnailer: thumbnailer)
        XCTAssertNotNil(again)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path).count, 5,
                       "a second visit reads the cache and draws nothing new")
        XCTAssertEqual(try Data(contentsOf: url), original, "page views are read-only")
        let invalid = await PageThumbnails.image(path: url.path, pageIndex: 5, maxPixel: 280, thumbnailer: thumbnailer)
        XCTAssertNil(invalid)
        let pageCount = await PageThumbnails.pageCount(path: url.path)
        XCTAssertEqual(pageCount, 5)
        let missing = await PageThumbnails.pageCount(path: "/tmp/does-not-exist-\(UUID()).pdf")
        XCTAssertNil(missing)
    }

    /// A page the reader turned shows turned in the page views too (W40.reader-view-rotate left the tiles upright).
    func testTurnedPicturesTurnClockwise() throws {
        // 4 × 2, red on its left half: a quarter turn clockwise puts the red on top.
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try XCTUnwrap(context.makeImage())
        func redOnTop(_ image: CGImage) -> Bool {
            let rep = NSBitmapImageRep(cgImage: image)
            let top = rep.colorAt(x: image.width / 2, y: 0)!, bottom = rep.colorAt(x: image.width / 2, y: image.height - 1)!
            return top.redComponent > 0.9 && top.greenComponent < 0.5 && bottom.greenComponent > 0.9
        }
        func redOnLeft(_ image: CGImage) -> Bool {
            let rep = NSBitmapImageRep(cgImage: image)
            let left = rep.colorAt(x: 0, y: image.height / 2)!, right = rep.colorAt(x: image.width - 1, y: image.height / 2)!
            return left.greenComponent < 0.5 && right.greenComponent > 0.9
        }
        XCTAssertTrue(redOnLeft(image))
        let once = PageThumbnails.rotated(image, turns: 1)
        XCTAssertEqual([once.width, once.height], [2, 4])
        XCTAssertTrue(redOnTop(once), "a quarter turn clockwise takes the left side to the top")
        let thrice = PageThumbnails.rotated(image, turns: -1)
        XCTAssertEqual([thrice.width, thrice.height], [2, 4])
        XCTAssertFalse(redOnTop(thrice), "a quarter turn anticlockwise takes it to the bottom")
        let half = PageThumbnails.rotated(image, turns: 2)
        XCTAssertEqual([half.width, half.height], [4, 2])
        XCTAssertFalse(redOnLeft(half))
        XCTAssertTrue(PageThumbnails.rotated(image, turns: 4) === image)
    }
}
