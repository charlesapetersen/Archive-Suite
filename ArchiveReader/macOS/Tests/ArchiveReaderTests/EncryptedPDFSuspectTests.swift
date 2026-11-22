import XCTest
import PDFKit
import CoreGraphics
import CoreText
import AppKit
import ArchiveCore
@testable import ArchiveReader

/// S-005 regression: a PDF with an open password is unreadable to the indexer and gets a
/// password message in the document viewer, including when opened ahead as a neighbour.
@MainActor
final class EncryptedPDFSuspectTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("EncryptedPDFSuspectTests-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Two text pages, encrypted with a user (open) password, so nothing can be read without it.
    private func lockedPDF() throws -> URL {
        let url = dir.appendingPathComponent("locked.pdf")
        var box = CGRect(x: 0, y: 0, width: 300, height: 300)
        let info: [CFString: Any] = [kCGPDFContextUserPassword: "secret", kCGPDFContextOwnerPassword: "owner"]
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, info as CFDictionary))
        for text in ["page one text", "page two text"] {
            ctx.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 24)]))
            ctx.textPosition = CGPoint(x: 20, y: 150)
            CTLineDraw(line, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        let doc = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertTrue(doc.isEncrypted && doc.isLocked, "precondition: the scratch file is locked")
        XCTAssertTrue(doc.unlock(withPassword: "secret"), "precondition: the password opens it")
        XCTAssertEqual(doc.page(at: 0)?.string?.contains("page one text"), true,
                       "precondition: the pages carry text once unlocked, so the file is not image-only")
        return url
    }

    func testTheIndexerFlagsAnEncryptedPDFUnreadable() async throws {
        let url = try lockedPDF()
        let file = ArchiveFile(url: url, name: url.lastPathComponent, fileType: "PDF",
                               tags: DocumentTags.parse(raw: ["Unread"], labelNumber: nil),
                               contentModified: Date())
        let indexer = ContentIndexer(url: dir.appendingPathComponent("content.sqlite3"))
        indexer.startIndexing([file])
        let deadline = Date().addingTimeInterval(20)
        while indexer.completedPassesForTesting < 1, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(indexer.completedPassesForTesting, 1, "the pass finishes")
        let statuses = await indexer.formatStatuses(for: [url.path])
        XCTAssertEqual(statuses[url.path], .unreadable, "PDFFormatStatus counts an encrypted PDF as unreadable")
    }

    func testTheViewerExplainsWhyALockedPDFCannotOpen() throws {
        let url = try lockedPDF()
        let viewer = DocumentViewerModel(persists: false, thumbnailer: nil)
        viewer.load(DocumentSelection(filePaths: [url.path]))

        assertPasswordError(viewer)
    }

    func testSwitchingToAPreparedLockedPDFShowsTheErrorAndLeavingClearsIt() async throws {
        let locked = try lockedPDF()
        let readable = dir.appendingPathComponent("readable.pdf")
        XCTAssertTrue(TestPDFBuilder.write(pages: ["scan", "OCR text"], to: readable))
        let viewer = DocumentViewerModel(persists: false, thumbnailer: nil)
        viewer.load(DocumentSelection(filePaths: [readable.path, locked.path]))

        let deadline = Date().addingTimeInterval(10)
        while !viewer.holdsPrepared(document: locked.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(viewer.holdsPrepared(document: locked.path), "the locked PDF was opened ahead")
        viewer.next()
        XCTAssertEqual(viewer.currentFilePath, locked.path)
        XCTAssertFalse(viewer.holdsPrepared(document: locked.path), "the switch took the prepared PDF")
        assertPasswordError(viewer)

        viewer.previous()
        XCTAssertNil(viewer.loadError)
        XCTAssertEqual(viewer.textPage?.string?.contains("OCR text"), true)
    }

    private func assertPasswordError(_ viewer: DocumentViewerModel, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(viewer.loadError, "“locked.pdf” is password-protected.", file: file, line: line)
        XCTAssertNil(viewer.current, "the viewer must show the load error in place of the PDF", file: file, line: line)
        XCTAssertNil(viewer.formatNote, "a locked PDF must not be described as image-only", file: file, line: line)
    }
}
