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

    private func makeFile(_ path: String) -> ArchiveFile {
        let url = URL(fileURLWithPath: path)
        return ArchiveFile(
            url: url,
            name: url.lastPathComponent,
            fileType: "PDF",
            tags: DocumentTags.parse(raw: [], labelNumber: nil),
            contentModified: nil
        )
    }

    // MARK: - pasteboardItem

    func testPasteboardItemVendsStringAndCustomUTI() async throws {
        let root = URL(fileURLWithPath: "/tmp/TestArchive")
        let files = [
            makeFile("/tmp/TestArchive/Box1/doc.pdf"),
            makeFile("/tmp/TestArchive/Box2/letter.pdf"),
        ]
        let item = await ArchiveLinkWriter.pasteboardItem(
            for: files, root: root, marker: testMarker, thumbnailer: nil
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
            for: files, root: root, marker: testMarker, thumbnailer: nil
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
        if case .readerReveal(let guid, let rel, let page) = parsed {
            XCTAssertEqual(guid, testGUID)
            XCTAssertEqual(rel, "Sub Dir/file.pdf")
            XCTAssertNil(page, "Doc-level link should have no page")
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
            for: files, root: root, marker: testMarker, thumbnailer: nil
        )

        let customType = NSPasteboard.PasteboardType(ArchiveLinkUTI.type)
        let jsonData = item.data(forType: customType)!
        let payload = try JSONDecoder().decode(ArchiveLinkPayload.self, from: jsonData)
        XCTAssertEqual(payload.entries[0].display, "MEMO-1962")
    }

    func testDocLevelLinksHaveNoThumb() async throws {
        let root = URL(fileURLWithPath: "/tmp/TestArchive")
        let files = [
            makeFile("/tmp/TestArchive/doc.pdf"),
        ]
        let item = await ArchiveLinkWriter.pasteboardItem(
            for: files, root: root, marker: testMarker, thumbnailer: nil
        )

        let customType = NSPasteboard.PasteboardType(ArchiveLinkUTI.type)
        let jsonData = item.data(forType: customType)!
        let payload = try JSONDecoder().decode(ArchiveLinkPayload.self, from: jsonData)
        XCTAssertNil(payload.entries[0].thumbPNGBase64, "Doc-level link should have no thumbnail")
        XCTAssertNil(payload.entries[0].page, "Doc-level link should have no page")
    }

    // MARK: - pageLink

    func testPageLinkHasPageAndDisplay() async throws {
        let root = URL(fileURLWithPath: "/tmp/TestArchive")
        let fileURL = URL(fileURLWithPath: "/tmp/TestArchive/letter.pdf")
        let item = await ArchiveLinkWriter.pageLink(
            fileURL: fileURL, page: 1,
            root: root, marker: testMarker, thumbnailer: nil
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
            root: root, marker: testMarker, thumbnailer: nil
        )

        let text = item.string(forType: .string)!
        let parsed = DurableLink(url: URL(string: text)!)
        if case .readerReveal(let guid, let rel, let page) = parsed {
            XCTAssertEqual(guid, testGUID)
            XCTAssertEqual(rel, "Box/doc.pdf")
            XCTAssertEqual(page, 3)
        } else {
            XCTFail("Expected readerReveal")
        }
    }

    // MARK: - Special characters in paths

    func testEmDashAndSpacesInPath() async throws {
        let root = URL(fileURLWithPath: "/tmp/TestArchive")
        let files = [
            makeFile("/tmp/TestArchive/Box \u{2014} Special/file name.pdf"),
        ]
        let item = await ArchiveLinkWriter.pasteboardItem(
            for: files, root: root, marker: testMarker, thumbnailer: nil
        )

        let text = item.string(forType: .string)!
        let parsed = DurableLink(url: URL(string: text)!)
        if case .readerReveal(_, let rel, _) = parsed {
            XCTAssertEqual(rel, "Box \u{2014} Special/file name.pdf",
                           "Em-dash and spaces should survive the URL round-trip")
        } else {
            XCTFail("Expected readerReveal")
        }
    }

    func testEmptySelectionReturnsEmptyPayload() async throws {
        let root = URL(fileURLWithPath: "/tmp/TestArchive")
        let item = await ArchiveLinkWriter.pasteboardItem(
            for: [], root: root, marker: testMarker, thumbnailer: nil
        )

        let customType = NSPasteboard.PasteboardType(ArchiveLinkUTI.type)
        let jsonData = item.data(forType: customType)!
        let payload = try JSONDecoder().decode(ArchiveLinkPayload.self, from: jsonData)
        XCTAssertTrue(payload.entries.isEmpty)
    }
}
