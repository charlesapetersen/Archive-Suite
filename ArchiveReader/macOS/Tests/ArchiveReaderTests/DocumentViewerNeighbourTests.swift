import XCTest
import PDFKit
import AppKit
import ArchiveCore
@testable import ArchiveReader

/// W40.fix-reader-viewer-switch: the document window opens the files either side of the open one ahead,
/// off the main actor, takes them on a switch, keeps the file just left, never serves a rewritten file as
/// it was, and holds no more than the neighbours. Scratch files only.
@MainActor
final class DocumentViewerNeighbourTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("viewer-neighbours-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func files(_ count: Int, in folder: URL? = nil) throws -> [URL] {
        let folder = folder ?? dir!
        return try (0..<count).map { i in
            let url = folder.appendingPathComponent(String(format: "%05d.pdf", i))
            XCTAssertTrue(TestPDFBuilder.write(pages: ["scan \(i)", "OCR text \(i)"], to: url))
            return try XCTUnwrap(url)
        }
    }

    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return condition()
    }

    func testTheNextFileIsOpenedAheadAndTakenOnTheSwitch() throws {
        let urls = try files(5)
        let viewer = DocumentViewerModel(persists: false, thumbnailer: nil)
        viewer.load(DocumentSelection(filePaths: urls.map(\.path)))
        XCTAssertTrue(waitUntil { viewer.holdsPrepared(document: urls[1].path) }, "the next file is opened ahead")
        XCTAssertFalse(viewer.holdsPrepared(document: urls[2].path), "only the neighbours")
        viewer.next()
        XCTAssertFalse(viewer.holdsPrepared(document: urls[1].path), "the switch took the opened document")
        XCTAssertEqual(viewer.textPage?.string?.contains("OCR text 1"), true)
        XCTAssertEqual(viewer.title, urls[1].lastPathComponent)
        XCTAssertTrue(waitUntil { viewer.holdsPrepared(document: urls[2].path) })
        XCTAssertTrue(viewer.holdsPrepared(document: urls[0].path), "the file just left is kept")
    }

    func testPreviousAfterNextShowsTheDocumentJustLeft() throws {
        let urls = try files(3)
        let viewer = DocumentViewerModel(persists: false, thumbnailer: nil)
        viewer.load(DocumentSelection(filePaths: urls.map(\.path)))
        let first = try XCTUnwrap(viewer.current)
        viewer.next()
        viewer.previous()
        XCTAssertTrue(viewer.current === first, "the same document, already drawn, not a reopen")
        XCTAssertEqual(viewer.imagePage?.string?.contains("scan 0"), true)
    }

    func testARewrittenFileIsOpenedAfreshNotShownAsItWas() throws {
        let urls = try files(3)
        let viewer = DocumentViewerModel(persists: false, thumbnailer: nil)
        viewer.load(DocumentSelection(filePaths: urls.map(\.path)))
        XCTAssertTrue(waitUntil { viewer.holdsPrepared(document: urls[1].path) })
        // A different size, so the stat(2) stamp differs even within one mtime tick.
        XCTAssertTrue(TestPDFBuilder.write(pages: ["rewritten scan, longer", "rewritten OCR text"], to: urls[1]))
        viewer.next()
        XCTAssertEqual(viewer.textPage?.string?.contains("rewritten OCR text"), true,
                       "\(viewer.textPage?.string ?? "nil")")
    }

    func testOnlyTheNeighboursAreHeldOverAWalk() throws {
        let urls = try files(12)
        let viewer = DocumentViewerModel(persists: false, thumbnailer: nil)
        viewer.load(DocumentSelection(filePaths: urls.map(\.path)))
        for i in 1..<urls.count {
            _ = waitUntil { viewer.holdsPrepared(document: urls[i].path) }
            viewer.next()
            XCTAssertEqual(viewer.index, i)
            XCTAssertLessThanOrEqual(viewer.preparedCounts.documents, 2, "step \(i)")
            XCTAssertEqual(viewer.textPage?.string?.contains("OCR text \(i)"), true, "step \(i)")
        }
        // Back through every file, each one the file just left or opened ahead.
        for i in stride(from: urls.count - 2, through: 0, by: -1) {
            viewer.previous()
            XCTAssertEqual(viewer.index, i)
            XCTAssertEqual(viewer.imagePage?.string?.contains("scan \(i)"), true, "back to \(i)")
            XCTAssertLessThanOrEqual(viewer.preparedCounts.documents, 2, "back to \(i)")
        }
    }

    func testTheNextFilesJPEGOriginalIsOpenedAhead() throws {
        let main = dir.appendingPathComponent(ReaderArchiveLayout.mainDirectoryName)
        let jpegs = dir.appendingPathComponent(ReaderArchiveLayout.jpegDirectoryName)
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: jpegs, withIntermediateDirectories: true)
        let urls = try files(3, in: main)
        for url in urls {
            try Self.grayJPEG().write(to: jpegs.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".jpg"))
        }
        let index = JPEGPartnerIndex(jpegRoot: jpegs, scan: CorpusWalker.scanFingerprints(root: jpegs))
        let marker = RootMarker(guid: UUID(), name: "scratch", kind: .reader, createdAt: Date())
        let target = ArchiveLinkTarget(rootPath: dir.path, marker: marker, mainRootPath: main.path)
        let viewer = DocumentViewerModel(persists: false, thumbnailer: nil)
        viewer.updateArchiveContext(target: target, index: index)
        viewer.load(DocumentSelection(filePaths: urls.map(\.path)))
        XCTAssertTrue(viewer.hasJPEGPartner)
        XCTAssertTrue(waitUntil { viewer.preparedCounts.jpegs == 1 }, "the next file's JPEG is opened ahead")
        viewer.next()
        XCTAssertTrue(viewer.hasJPEGPartner)
        XCTAssertEqual(viewer.jpegPartnerRelativePath, "\(ReaderArchiveLayout.jpegDirectoryName)/00001.jpg")
        XCTAssertTrue(waitUntil { viewer.preparedCounts.jpegs == 2 }, "the next and the one just left")
        viewer.toggleImageSource()
        XCTAssertTrue(viewer.isShowingJPEG)
        XCTAssertEqual(viewer.displayedImagePage?.bounds(for: .cropBox).size, CGSize(width: 40, height: 50))
    }

    func testTheDocumentWindowsBitmapsFollowThePaneSize() throws {
        let prefetcher = PreviewImagePrefetcher(pixelBox: CGSize(width: 512, height: 512), cacheLimit: 4)
        prefetcher.setPixelBox(longSide: 1_000)
        XCTAssertEqual(prefetcher.pixelBox, CGSize(width: 1_024, height: 1_024), "rounded up to 256 px")
        prefetcher.setPixelBox(longSide: 20_000)
        XCTAssertEqual(prefetcher.pixelBox.width, PreviewImagePrefetcher.maxPixelSide)
        let urls = try files(6)
        prefetcher.setPixelBox(longSide: 300)
        prefetcher.prefetch(paths: urls.map(\.path))
        XCTAssertTrue(waitUntil { prefetcher.image(path: urls[5].path, pageIndex: 0) != nil })
        XCTAssertNil(prefetcher.image(path: urls[0].path, pageIndex: 0), "bounded at its own limit of 4")
        XCTAssertNotNil(prefetcher.image(path: urls[2].path, pageIndex: 0))
        prefetcher.setPixelBox(longSide: 700)
        XCTAssertNil(prefetcher.image(path: urls[5].path, pageIndex: 0), "a new size drops the old bitmaps")
    }

    /// A bitmap asked for again, already drawn, must outlive the next one to land (the lane's switches 5–8
    /// each missed: the file just skipped as drawn was the eviction's oldest).
    func testABitmapAskedForAgainIsNotTheOneEvicted() throws {
        let urls = try files(4)
        let prefetcher = PreviewImagePrefetcher(pixelBox: CGSize(width: 64, height: 64), cacheLimit: 3)
        for url in urls.prefix(3) {
            prefetcher.prefetch(paths: [url.path])
            XCTAssertTrue(waitUntil { prefetcher.image(path: url.path, pageIndex: 0) != nil })
        }
        prefetcher.prefetch(paths: [urls[0].path, urls[3].path])   // the oldest, wanted again, and a new one
        XCTAssertTrue(waitUntil { prefetcher.image(path: urls[3].path, pageIndex: 0) != nil })
        XCTAssertNotNil(prefetcher.image(path: urls[0].path, pageIndex: 0), "still wanted, so not evicted")
        XCTAssertNil(prefetcher.image(path: urls[1].path, pageIndex: 0), "the oldest not asked for went")
    }

    private static func grayJPEG() throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 50,
                                                 bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<40 { for y in 0..<50 { rep.setColor(.gray, atX: x, y: y) } }
        return try XCTUnwrap(rep.representation(using: .jpeg, properties: [:]))
    }
}
