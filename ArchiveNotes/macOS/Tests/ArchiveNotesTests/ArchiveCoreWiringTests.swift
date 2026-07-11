import XCTest
import ArchiveCore
@testable import ArchiveNotes

/// Verifies that the Notes app target correctly links ArchiveCore and can
/// construct + use its public types at runtime (not just compile time).
final class ArchiveCoreWiringTests: XCTestCase {

    // MARK: - ArchiveSuiteMarker

    func testSuiteMarkerTagName() {
        XCTAssertEqual(ArchiveSuiteMarker.tagName, "ArchiveSuite")
    }

    func testSuiteMarkerRecognition() {
        XCTAssertTrue(ArchiveSuiteMarker.isMarker("ArchiveSuite"))
        XCTAssertFalse(ArchiveSuiteMarker.isMarker("archivesuite"))
        XCTAssertFalse(ArchiveSuiteMarker.isMarker("Archive Suite"))
        XCTAssertFalse(ArchiveSuiteMarker.isMarker(""))
    }

    func testSuiteMarkerFilterOutMarker() {
        let tags = ["History", "ArchiveSuite", "Tech", "1968"]
        let filtered = ArchiveSuiteMarker.filterOutMarker(from: tags)
        XCTAssertEqual(filtered, ["History", "Tech", "1968"])
    }

    // MARK: - DurableLink

    func testDurableLinkNotesOpenRoundTrip() {
        let id = UUID()
        let link = DurableLink.notesOpen(id: id, block: 3)
        let url = link.url

        XCTAssertEqual(url.scheme, DurableLink.notesScheme)

        guard let parsed = DurableLink(url: url) else {
            return XCTFail("Failed to parse notesOpen URL")
        }
        XCTAssertEqual(parsed, link)
    }

    func testDurableLinkReaderRevealRoundTrip() {
        let guid = UUID()
        let link = DurableLink.readerReveal(rootGUID: guid, relativePath: "Folder/Doc — Name.pdf", page: 2)
        let url = link.url

        XCTAssertEqual(url.scheme, DurableLink.readerScheme)

        guard let parsed = DurableLink(url: url) else {
            return XCTFail("Failed to parse readerReveal URL")
        }
        XCTAssertEqual(parsed, link)
    }

    func testDurableLinkMalformedURLReturnsNil() {
        let bogus = URL(string: "https://example.com")!
        XCTAssertNil(DurableLink(url: bogus))
    }

    // MARK: - RootMarker

    func testRootMarkerCodableRoundTrip() throws {
        let guid = UUID()
        let now = Date()
        let marker = RootMarker(guid: guid, name: "Test Root", kind: .notes, createdAt: now)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(marker)
        let decoded = try JSONDecoder().decode(RootMarker.self, from: data)

        XCTAssertEqual(decoded.guid, guid)
        XCTAssertEqual(decoded.name, "Test Root")
        XCTAssertEqual(decoded.kind, .notes)
        // ISO-8601 serialization drops sub-second precision; compare to within 1 second
        XCTAssertEqual(decoded.createdAt.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 1.0)
    }

    func testRootMarkerFilename() {
        XCTAssertEqual(RootMarker.filename, ".archive-suite-root.json")
    }

    func testRootKindRawValues() {
        XCTAssertEqual(RootKind.reader.rawValue, "reader")
        XCTAssertEqual(RootKind.notes.rawValue, "notes")
    }

    // MARK: - ItemKindShell (app-side type)

    func testItemKindShellCases() {
        // Verify the enum cases exist and are distinct
        let note: ItemKindShell = .note
        let extract: ItemKindShell = .extract
        XCTAssertNotEqual(String(describing: note), String(describing: extract))
    }
}
