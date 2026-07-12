import XCTest
@testable import ArchiveNotes
import ArchiveCore

final class SourceBlockPasterTests: XCTestCase {

    // MARK: - entriesFromPayload (custom UTI path)

    func testPayloadWithPageEntry() {
        let payload = ArchiveLinkPayload(entries: [
            .init(
                link: "archivereader://reveal?root=7F3A1B2C-4D5E-6F78-9A0B-CDEF01234567&rel=Letters/Moore.pdf&page=41",
                display: "Gordon E. Moore Oral History \u{2014} p. 41",
                page: 41,
                thumbPNGBase64: pngBase64Stub
            )
        ])

        let entries = SourceBlockPaster.entriesFromPayload(payload)
        XCTAssertEqual(entries.count, 1)

        let e = entries[0]
        XCTAssertEqual(e.kind, .readerPage)
        XCTAssertEqual(e.anchor.link, payload.entries[0].link)
        XCTAssertEqual(e.anchor.display, "Gordon E. Moore Oral History \u{2014} p. 41")
        XCTAssertEqual(e.anchor.page, 41)
        XCTAssertNotNil(e.thumbnailData, "Base64 thumbnail should decode")
    }

    func testPayloadWithDocEntry() {
        let payload = ArchiveLinkPayload(entries: [
            .init(
                link: "archivereader://reveal?root=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE&rel=Reports/Annual.pdf",
                display: "Annual Report"
            )
        ])

        let entries = SourceBlockPaster.entriesFromPayload(payload)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].kind, .readerDoc)
        XCTAssertNil(entries[0].anchor.page)
        XCTAssertNil(entries[0].thumbnailData)
    }

    func testPayloadInvalidLinkRejected() {
        let payload = ArchiveLinkPayload(entries: [
            .init(link: "https://example.com", display: "Not an archive link"),
            .init(
                link: "archivereader://reveal?root=7F3A1B2C-4D5E-6F78-9A0B-CDEF01234567&rel=ok.pdf",
                display: "Valid"
            )
        ])

        let entries = SourceBlockPaster.entriesFromPayload(payload)
        XCTAssertEqual(entries.count, 1, "Invalid link should be filtered out")
        XCTAssertEqual(entries[0].anchor.display, "Valid")
    }

    func testPayloadOversizedThumbnailRejected() {
        let oversized = String(repeating: "A", count: 6_000_000)
        let payload = ArchiveLinkPayload(entries: [
            .init(
                link: "archivereader://reveal?root=7F3A1B2C-4D5E-6F78-9A0B-CDEF01234567&rel=x.pdf&page=1",
                display: "Huge",
                page: 1,
                thumbPNGBase64: oversized
            )
        ])

        let entries = SourceBlockPaster.entriesFromPayload(payload)
        XCTAssertEqual(entries.count, 1, "Entry with valid link is kept even if thumbnail is oversized")
        XCTAssertNil(entries[0].thumbnailData, "Oversized base64 thumbnail should be stripped")
    }

    func testPayloadMultipleEntries() {
        let payload = ArchiveLinkPayload(entries: [
            .init(
                link: "archivereader://reveal?root=7F3A1B2C-4D5E-6F78-9A0B-CDEF01234567&rel=a.pdf&page=1",
                display: "Doc A \u{2014} p. 1", page: 1
            ),
            .init(
                link: "archivereader://reveal?root=7F3A1B2C-4D5E-6F78-9A0B-CDEF01234567&rel=b.pdf",
                display: "Doc B"
            )
        ])

        let entries = SourceBlockPaster.entriesFromPayload(payload)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].kind, .readerPage)
        XCTAssertEqual(entries[1].kind, .readerDoc)
    }

    // MARK: - scanURLs (plain-text fallback)

    func testScanURLsSinglePage() {
        let text = "archivereader://reveal?root=7F3A1B2C-4D5E-6F78-9A0B-CDEF01234567&rel=Letters/Moore.pdf&page=41\n"
        let entries = SourceBlockPaster.scanURLs(in: text)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].kind, .readerPage)
        XCTAssertEqual(entries[0].anchor.page, 41)
        XCTAssertEqual(entries[0].anchor.display, "Moore \u{2014} p. 41")
        XCTAssertNil(entries[0].thumbnailData)
    }

    func testScanURLsDocLevel() {
        let text = "archivereader://reveal?root=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE&rel=Report.pdf\n"
        let entries = SourceBlockPaster.scanURLs(in: text)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].kind, .readerDoc)
        XCTAssertEqual(entries[0].anchor.display, "Report")
        XCTAssertNil(entries[0].anchor.page)
    }

    func testScanURLsMultipleLines() {
        let text = """
        archivereader://reveal?root=7F3A1B2C-4D5E-6F78-9A0B-CDEF01234567&rel=a.pdf&page=1
        archivereader://reveal?root=7F3A1B2C-4D5E-6F78-9A0B-CDEF01234567&rel=b.pdf
        """
        let entries = SourceBlockPaster.scanURLs(in: text)
        XCTAssertEqual(entries.count, 2)
    }

    func testScanURLsIgnoresNonArchiveLines() {
        let text = """
        https://example.com
        archivereader://reveal?root=7F3A1B2C-4D5E-6F78-9A0B-CDEF01234567&rel=ok.pdf&page=1
        some random text
        """
        let entries = SourceBlockPaster.scanURLs(in: text)
        XCTAssertEqual(entries.count, 1, "Only archive links should be recognized")
    }

    func testScanURLsEmptyText() {
        let entries = SourceBlockPaster.scanURLs(in: "")
        XCTAssertTrue(entries.isEmpty)
    }

    func testScanURLsNonPDFExtension() {
        let text = "archivereader://reveal?root=7F3A1B2C-4D5E-6F78-9A0B-CDEF01234567&rel=Photos/scan.jpg\n"
        let entries = SourceBlockPaster.scanURLs(in: text)
        XCTAssertEqual(entries.count, 1)
        // Non-PDF basename preserved as-is
        XCTAssertEqual(entries[0].anchor.display, "scan.jpg")
    }

    // MARK: - importThumbnail (asset import)

    @MainActor
    func testImportThumbnailPageEntry() throws {
        let store = ScratchAssetStore()
        let pngData = try XCTUnwrap(Data(base64Encoded: pngBase64Stub))

        let ref = SourceBlockPaster.importThumbnail(pngData, page: 41, assetStore: store)
        XCTAssertEqual(ref, "assets/p41-thumb.png")

        // Verify file exists on disk
        let fileURL = store.root.appendingPathComponent("assets/p41-thumb.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @MainActor
    func testImportThumbnailDocEntry() throws {
        let store = ScratchAssetStore()
        let pngData = try XCTUnwrap(Data(base64Encoded: pngBase64Stub))

        let ref = SourceBlockPaster.importThumbnail(pngData, page: nil, assetStore: store)
        XCTAssertEqual(ref, "assets/doc-thumb.png")
    }

    @MainActor
    func testImportThumbnailCollision() throws {
        let store = ScratchAssetStore()
        let pngData = try XCTUnwrap(Data(base64Encoded: pngBase64Stub))

        let ref1 = SourceBlockPaster.importThumbnail(pngData, page: 1, assetStore: store)
        let ref2 = SourceBlockPaster.importThumbnail(pngData, page: 1, assetStore: store)
        XCTAssertEqual(ref1, "assets/p1-thumb.png")
        XCTAssertEqual(ref2, "assets/p1-thumb-1.png", "Second import should disambiguate")
    }

    // MARK: - pasteboardHasArchiveLinks (quick check)

    @MainActor
    func testPasteboardHasArchiveLinksCustomUTI() {
        let pb = NSPasteboard(name: .init("test-has-uti-\(UUID().uuidString)"))
        pb.clearContents()
        let item = NSPasteboardItem()
        let payload = ArchiveLinkPayload(entries: [
            .init(
                link: "archivereader://reveal?root=7F3A1B2C-4D5E-6F78-9A0B-CDEF01234567&rel=x.pdf",
                display: "X"
            )
        ])
        item.setData(try! JSONEncoder().encode(payload),
                     forType: NSPasteboard.PasteboardType(ArchiveLinkUTI.type))
        pb.writeObjects([item])

        XCTAssertTrue(SourceBlockPaster.pasteboardHasArchiveLinks(pb))
    }

    @MainActor
    func testPasteboardHasArchiveLinksPlainText() {
        let pb = NSPasteboard(name: .init("test-has-text-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString("archivereader://reveal?root=X&rel=y.pdf", forType: .string)

        XCTAssertTrue(SourceBlockPaster.pasteboardHasArchiveLinks(pb))
    }

    @MainActor
    func testPasteboardNoArchiveLinks() {
        let pb = NSPasteboard(name: .init("test-no-links-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString("Just regular text", forType: .string)

        XCTAssertFalse(SourceBlockPaster.pasteboardHasArchiveLinks(pb))
    }

    // MARK: - readPasteboard (full flow)

    @MainActor
    func testReadPasteboardCustomUTI() {
        let pb = NSPasteboard(name: .init("test-read-uti-\(UUID().uuidString)"))
        pb.clearContents()
        let item = NSPasteboardItem()
        let payload = ArchiveLinkPayload(entries: [
            .init(
                link: "archivereader://reveal?root=7F3A1B2C-4D5E-6F78-9A0B-CDEF01234567&rel=Doc.pdf&page=3",
                display: "Doc \u{2014} p. 3",
                page: 3,
                thumbPNGBase64: pngBase64Stub
            )
        ])
        item.setData(try! JSONEncoder().encode(payload),
                     forType: NSPasteboard.PasteboardType(ArchiveLinkUTI.type))
        pb.writeObjects([item])

        let entries = SourceBlockPaster.readPasteboard(from: pb)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].kind, .readerPage)
        XCTAssertNotNil(entries[0].thumbnailData)
    }

    @MainActor
    func testReadPasteboardPlainTextFallback() {
        let pb = NSPasteboard(name: .init("test-read-text-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString(
            "archivereader://reveal?root=7F3A1B2C-4D5E-6F78-9A0B-CDEF01234567&rel=Note.pdf&page=2",
            forType: .string
        )

        let entries = SourceBlockPaster.readPasteboard(from: pb)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].kind, .readerPage)
        XCTAssertNil(entries[0].thumbnailData, "Plain text path has no thumbnails")
    }

    @MainActor
    func testReadPasteboardEmpty() {
        let pb = NSPasteboard(name: .init("test-empty-\(UUID().uuidString)"))
        pb.clearContents()

        let entries = SourceBlockPaster.readPasteboard(from: pb)
        XCTAssertTrue(entries.isEmpty)
    }

    // MARK: - Block header serialization (round-trip)

    func testSerializedBlockHeaderMatchesSpec() {
        // Verify that a block built from paste entries serializes to the §6 format
        let anchor = SourceAnchor(
            link: "archivereader://reveal?root=7F3A1B2C-4D5E-6F78-9A0B-CDEF01234567&rel=SV/Business/Moore.pdf&page=41",
            display: "Gordon E. Moore Oral History \u{2014} p. 41",
            page: 41,
            thumbRef: "assets/p41-thumb.png"
        )
        let block = Block(
            kind: .readerPage,
            source: anchor,
            markdown: "Moore says he and Noyce were **responsible** for Intel\u{2019}s early egalitarian culture\u{2026}\n",
            unknownHeaderFields: []
        )
        let serialized = BlockParser.serialize(leadingText: nil, blocks: [block])

        // Header must start with <!-- block: reader-page
        XCTAssertTrue(serialized.hasPrefix("<!-- block: reader-page"), "Header should start with block kind")
        XCTAssertTrue(serialized.contains("link: archivereader://reveal?"), "Should contain link field")
        XCTAssertTrue(serialized.contains("display: \"Gordon E. Moore"), "Should contain quoted display")
        XCTAssertTrue(serialized.contains("page: 41"), "Should contain page field")
        XCTAssertTrue(serialized.contains("thumb: assets/p41-thumb.png"), "Should contain thumb field")
        XCTAssertTrue(serialized.contains("-->"), "Header should close")
        XCTAssertTrue(serialized.contains("Moore says"), "Block body should follow")

        // Round-trip: parse the serialized output
        let (_, parsed) = BlockParser.parse(serialized)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].kind, .readerPage)
        XCTAssertEqual(parsed[0].source?.link, anchor.link)
        XCTAssertEqual(parsed[0].source?.display, anchor.display)
        XCTAssertEqual(parsed[0].source?.page, 41)
        XCTAssertEqual(parsed[0].source?.thumbRef, "assets/p41-thumb.png")
    }

    // MARK: - Helpers

    /// Minimal valid 1x1 red PNG, base64-encoded.
    private var pngBase64Stub: String {
        // A minimal 1x1 red PNG (67 bytes)
        let pngBytes: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR chunk
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
            0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, // IDAT chunk
            0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
            0x00, 0x00, 0x02, 0x00, 0x01, 0xE2, 0x21, 0xBC,
            0x33, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, // IEND chunk
            0x44, 0xAE, 0x42, 0x60, 0x82
        ]
        return Data(pngBytes).base64EncodedString()
    }
}
