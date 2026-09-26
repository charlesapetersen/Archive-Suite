import XCTest
import ArchiveCore
@testable import ArchiveReader

@MainActor
final class ArchiveLinkWriterTests: XCTestCase {

    private let testGUID = UUID()
    private lazy var testMarker = RootMarker(
        guid: testGUID,
        name: "TestArchive",
        kind: .reader,
        createdAt: Date()
    )

    private func makeFile(_ path: String, isDataless: Bool = false) -> ArchiveFile {
        let url = URL(fileURLWithPath: path)
        return ArchiveFile(
            url: url,
            name: url.lastPathComponent,
            fileType: "PDF",
            tags: DocumentTags.parse(raw: [], labelNumber: nil),
            contentModified: nil,
            isDataless: isDataless
        )
    }

    private func makeScratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveLinkWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    // MARK: - pasteboardItem

    func testPasteboardItemVendsStringAndCustomUTI() async throws {
        let root = URL(fileURLWithPath: "/tmp/TestArchive")
        let files = [
            makeFile("/tmp/TestArchive/Box1/doc.pdf"),
            makeFile("/tmp/TestArchive/Box2/letter.pdf"),
        ]
        let item = await ArchiveLinkWriter.pasteboardItem(
            for: files, rootPath: root.path, marker: testMarker, thumbnailer: nil
        )

        // Rep 1: plain text — two archivereader:// URLs
        let text = item.string(forType: .string)
        XCTAssertNotNil(text)
        let lines = text!.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        for line in lines {
            XCTAssertTrue(line.hasPrefix("archivereader://reveal?"), "Expected archivereader URL, got: \(line)")
        }

        // Rep 2: custom UTI JSON
        let customType = NSPasteboard.PasteboardType(ArchiveLinkUTI.type)
        let jsonData = item.data(forType: customType)
        XCTAssertNotNil(jsonData, "Should vend custom UTI data")

        let payload = try JSONDecoder().decode(ArchiveLinkPayload.self, from: jsonData!)
        XCTAssertEqual(payload.version, 1)
        XCTAssertEqual(payload.entries.count, 2)
    }

    func testPayloadEntriesHaveCorrectRelativePaths() async throws {
        let root = URL(fileURLWithPath: "/tmp/TestArchive")
        let files = [
            makeFile("/tmp/TestArchive/Sub Dir/file.pdf"),
        ]
        let item = await ArchiveLinkWriter.pasteboardItem(
            for: files, rootPath: root.path, marker: testMarker, thumbnailer: nil
        )

        let customType = NSPasteboard.PasteboardType(ArchiveLinkUTI.type)
        let jsonData = item.data(forType: customType)!
        let payload = try JSONDecoder().decode(ArchiveLinkPayload.self, from: jsonData)
        let entry = payload.entries[0]

        // The link URL should contain the relative path
        XCTAssertTrue(entry.link.contains("archivereader://reveal"))
        // Parse and verify the link round-trips
        let parsed = DurableLink(url: URL(string: entry.link)!)
        XCTAssertNotNil(parsed)
        if case .readerReveal(let guid, let rel, let page, let jpegRel) = parsed {
            XCTAssertEqual(guid, testGUID)
            XCTAssertEqual(rel, "Sub Dir/file.pdf")
            XCTAssertNil(page, "Doc-level link should have no page")
            XCTAssertNil(jpegRel)
        } else {
            XCTFail("Expected readerReveal, got \(String(describing: parsed))")
        }
    }

    func testDisplayNameStripsExtension() async throws {
        let root = URL(fileURLWithPath: "/tmp/TestArchive")
        let files = [
            makeFile("/tmp/TestArchive/MEMO-1962.pdf"),
        ]
        let item = await ArchiveLinkWriter.pasteboardItem(
            for: files, rootPath: root.path, marker: testMarker, thumbnailer: nil
        )

        let customType = NSPasteboard.PasteboardType(ArchiveLinkUTI.type)
        let jsonData = item.data(forType: customType)!
        let payload = try JSONDecoder().decode(ArchiveLinkPayload.self, from: jsonData)
        XCTAssertEqual(payload.entries[0].display, "MEMO-1962")
    }

    func testDocLevelLinksHaveNoThumbWithoutARenderer() async throws {
        let root = URL(fileURLWithPath: "/tmp/TestArchive")
        let files = [
            makeFile("/tmp/TestArchive/doc.pdf"),
        ]
        let item = await ArchiveLinkWriter.pasteboardItem(
            for: files, rootPath: root.path, marker: testMarker, thumbnailer: nil
        )

        let customType = NSPasteboard.PasteboardType(ArchiveLinkUTI.type)
        let jsonData = item.data(forType: customType)!
        let payload = try JSONDecoder().decode(ArchiveLinkPayload.self, from: jsonData)
        XCTAssertNil(payload.entries[0].thumbPNGBase64, "Doc-level link should have no thumbnail")
        XCTAssertNil(payload.entries[0].page, "Doc-level link should have no page")
    }

    /// A document link still has no cited page; its first-page image is only an optional source-block
    /// preview. The batch path must nevertheless use its injected renderer rather than dropping it.
    func testBatchLinksEmbedFirstPageThumbnailWhenRendererAvailable() async throws {
        let root = try makeScratchDirectory()
        let pdf = root.appendingPathComponent("batch.pdf")
        XCTAssertTrue(TestPDFBuilder.write(pages: ["dense thumbnail fixture"], to: pdf))
        let thumbnailer = PDFThumbnailer(cacheDirectory: root.appendingPathComponent("thumb-cache"))

        let item = await ArchiveLinkWriter.pasteboardItem(
            for: [makeFile(pdf.path)], rootPath: root.path, marker: testMarker, thumbnailer: thumbnailer
        )
        let customType = NSPasteboard.PasteboardType(ArchiveLinkUTI.type)
        let payload = try JSONDecoder().decode(
            ArchiveLinkPayload.self, from: try XCTUnwrap(item.data(forType: customType))
        )

        XCTAssertNil(payload.entries[0].page, "the durable batch link remains document-level")
        let encoded = try XCTUnwrap(payload.entries[0].thumbPNGBase64)
        XCTAssertGreaterThan(try XCTUnwrap(Data(base64Encoded: encoded)).count, 100,
                             "the rich payload must carry actual rendered PNG bytes")
    }

    /// Optional link previews must not open a known cloud placeholder. The fixture is deliberately a
    /// valid local PDF: without the `isDataless` gate it would render successfully, so `nil` proves
    /// the batch path skipped the open rather than merely degrading on unreadable input.
    func testBatchLinksSkipKnownDatalessFiles() async throws {
        let root = try makeScratchDirectory()
        let pdf = root.appendingPathComponent("placeholder.pdf")
        XCTAssertTrue(TestPDFBuilder.write(pages: ["must not be opened"], to: pdf))
        let thumbnailer = PDFThumbnailer(cacheDirectory: root.appendingPathComponent("thumb-cache"))

        let item = await ArchiveLinkWriter.pasteboardItem(
            for: [makeFile(pdf.path, isDataless: true)], rootPath: root.path,
            marker: testMarker, thumbnailer: thumbnailer
        )
        let customType = NSPasteboard.PasteboardType(ArchiveLinkUTI.type)
        let payload = try JSONDecoder().decode(
            ArchiveLinkPayload.self, from: try XCTUnwrap(item.data(forType: customType))
        )
        XCTAssertNil(payload.entries[0].thumbPNGBase64,
                     "a known dataless file must keep its durable link but never open for a preview")
    }

    // MARK: - pageLink

    func testPageLinkHasPageAndDisplay() async throws {
        let root = URL(fileURLWithPath: "/tmp/TestArchive")
        let fileURL = URL(fileURLWithPath: "/tmp/TestArchive/letter.pdf")
        let item = await ArchiveLinkWriter.pageLink(
            fileURL: fileURL, page: 1,
            rootPath: root.path, marker: testMarker, thumbnailer: nil
        )

        let text = item.string(forType: .string)
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.hasPrefix("archivereader://reveal?"))

        let customType = NSPasteboard.PasteboardType(ArchiveLinkUTI.type)
        let jsonData = item.data(forType: customType)!
        let payload = try JSONDecoder().decode(ArchiveLinkPayload.self, from: jsonData)
        XCTAssertEqual(payload.entries.count, 1)

        let entry = payload.entries[0]
        XCTAssertEqual(entry.page, 1)
        XCTAssertEqual(entry.display, "letter \u{2014} p.1")
        // No thumbnailer provided → no thumb
        XCTAssertNil(entry.thumbPNGBase64)
    }

    func testPageLinkRoundTrips() async throws {
        let root = URL(fileURLWithPath: "/tmp/TestArchive")
        let fileURL = URL(fileURLWithPath: "/tmp/TestArchive/Box/doc.pdf")
        let item = await ArchiveLinkWriter.pageLink(
            fileURL: fileURL, page: 3,
            rootPath: root.path, marker: testMarker, thumbnailer: nil
        )

        let text = item.string(forType: .string)!
        let parsed = DurableLink(url: URL(string: text)!)
        if case .readerReveal(let guid, let rel, let page, let jpegRel) = parsed {
            XCTAssertEqual(guid, testGUID)
            XCTAssertEqual(rel, "Box/doc.pdf")
            XCTAssertEqual(page, 3)
            XCTAssertNil(jpegRel)
        } else {
            XCTFail("Expected readerReveal")
        }
    }

    func testPageLinkCarriesOnlyTheCleanlyResolvedJPEGPartner() throws {
        let root = try makeScratchDirectory()
        let main = root.appendingPathComponent(ReaderArchiveLayout.mainDirectoryName, isDirectory: true)
        let jpegs = root.appendingPathComponent(ReaderArchiveLayout.jpegDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: jpegs, withIntermediateDirectories: true)
        let pdf = main.appendingPathComponent("Box/letter.pdf")
        let jpeg = jpegs.appendingPathComponent("Box/letter.jpg")
        try FileManager.default.createDirectory(at: pdf.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: jpeg.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("scratch".utf8).write(to: jpeg)
        let candidate = JPEGPartnerCandidate(
            stem: "letter", path: jpeg.path, collectionContext: "Box",
            fingerprint: CorpusFileFingerprint(mtime: 1, ctime: 1, size: 7, inode: 1, isDataless: false)
        )
        let clean = JPEGPartnerIndex(jpegRootPath: jpegs.path, candidates: [candidate],
                                     isClean: true, filesSeen: 1)
        let item = ArchiveLinkWriter.pageLinkWithoutThumbnail(
            fileURL: pdf, page: 1, rootPath: root.path, marker: testMarker,
            mainRootPath: main.path, jpegPartnerIndex: clean
        )
        let parsed = try XCTUnwrap(item.string(forType: .string).flatMap(URL.init(string:)).flatMap(DurableLink.init(url:)))
        guard case let .readerReveal(_, relativePath, page, jpegRelativePath) = parsed else {
            return XCTFail("Expected a reader reveal link")
        }
        XCTAssertEqual(relativePath, "Archival Photos/Box/letter.pdf")
        XCTAssertEqual(page, 1)
        XCTAssertEqual(jpegRelativePath, "Archival Photos JPEGS/Box/letter.jpg")

        let incomplete = JPEGPartnerIndex(jpegRootPath: jpegs.path, candidates: [candidate],
                                          isClean: false, filesSeen: 1)
        let unknownItem = ArchiveLinkWriter.pageLinkWithoutThumbnail(
            fileURL: pdf, page: 1, rootPath: root.path, marker: testMarker,
            mainRootPath: main.path, jpegPartnerIndex: incomplete
        )
        let unknownParsed = try XCTUnwrap(unknownItem.string(forType: .string)
            .flatMap(URL.init(string:)).flatMap(DurableLink.init(url:)))
        guard case let .readerReveal(_, _, _, unknownJPEGPath) = unknownParsed else {
            return XCTFail("Expected a reader reveal link")
        }
        XCTAssertNil(unknownJPEGPath, "partial scans cannot claim a partner or verified absence")
    }

    // MARK: - Special characters in paths

    func testEmDashAndSpacesInPath() async throws {
        let root = URL(fileURLWithPath: "/tmp/TestArchive")
        let files = [
            makeFile("/tmp/TestArchive/Box \u{2014} Special/file name.pdf"),
        ]
        let item = await ArchiveLinkWriter.pasteboardItem(
            for: files, rootPath: root.path, marker: testMarker, thumbnailer: nil
        )

        let text = item.string(forType: .string)!
        let parsed = DurableLink(url: URL(string: text)!)
        if case .readerReveal(_, let rel, _, _) = parsed {
            XCTAssertEqual(rel, "Box \u{2014} Special/file name.pdf",
                           "Em-dash and spaces should survive the URL round-trip")
        } else {
            XCTFail("Expected readerReveal")
        }
    }

    func testEmptySelectionReturnsEmptyPayload() async throws {
        let root = URL(fileURLWithPath: "/tmp/TestArchive")
        let item = await ArchiveLinkWriter.pasteboardItem(
            for: [], rootPath: root.path, marker: testMarker, thumbnailer: nil
        )

        let customType = NSPasteboard.PasteboardType(ArchiveLinkUTI.type)
        let jsonData = item.data(forType: customType)!
        let payload = try JSONDecoder().decode(ArchiveLinkPayload.self, from: jsonData)
        XCTAssertTrue(payload.entries.isEmpty)
    }
}
