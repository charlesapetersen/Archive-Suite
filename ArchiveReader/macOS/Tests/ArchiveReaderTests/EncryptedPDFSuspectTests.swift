import XCTest
import PDFKit
import CoreGraphics
import CoreText
import AppKit
import ArchiveCore
@testable import ArchiveReader

/// W49.reader-s005-reproduce — the reproduce attempt for suspect S-005 (phase rule 5a): a password-protected PDF,
/// written on scratch with `kCGPDFContextUserPassword`, run through the content indexer's real pass and the
/// document viewer's real `load`.
///
/// The indexer half holds: `PDFHeaderParser.extract` refuses a locked document, so the row is `.unreadable`. The
/// viewer half reproduced on 2026-11-20: PDFKit opens the file locked with its real page count, so `loadError` stays
/// nil and `formatNote` calls it image-only, never encrypted. That check is a known issue: the run stays green while
/// the defect is there and fails once it is gone, when the fix removes the `XCTExpectFailure`. Phase rule 5a(4): a
/// second session on another model checks the reproduction before a fix item is filed
/// (`W49.reader-s005-reproduce-check`).
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

    func testTheViewerDoesNotSayTheDocumentIsEncrypted() throws {
        let url = try lockedPDF()
        let viewer = DocumentViewerModel(persists: false, thumbnailer: nil)
        viewer.load(DocumentSelection(filePaths: [url.path]))

        // What the viewer shows today: a document that opened, locked, with its two pages and no error.
        let doc = try XCTUnwrap(viewer.current, "PDFKit opens a locked file")
        XCTAssertTrue(doc.isLocked)
        XCTAssertEqual(doc.pageCount, 2, "a locked file still reports its page count")
        XCTAssertNil(viewer.textPage?.string, "no text can be read from a locked page")

        XCTExpectFailure("S-005: the viewer says nothing about encryption (W49.reader-s005-reproduce)") {
            let shown = [viewer.loadError, viewer.formatNote].compactMap { $0 }
            XCTAssertTrue(shown.contains { $0.localizedCaseInsensitiveContains("encrypt")
                                           || $0.localizedCaseInsensitiveContains("password") },
                          "shown instead: \(shown)")
        }
        XCTAssertNil(viewer.loadError, "today: no load error")
        XCTAssertEqual(viewer.formatNote?.contains("image-only"), true,
                       "today: the format note calls a locked text PDF image-only")
    }
}
