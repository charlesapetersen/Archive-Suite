// DurableLinkTests.swift — URL parse/format round-trip + RootMarker Codable + marker recognition
import Testing
import Foundation
@testable import ArchiveCore

@Suite("DurableLink")
struct DurableLinkTests {
    let sampleUUID = UUID(uuidString: "7f3a9c21-4b5e-4a8c-9d3f-1e2a6b7c8d9e")!

    // MARK: - readerReveal

    @Test func readerRevealRoundTripWithPage() {
        let link = DurableLink.readerReveal(
            rootGUID: sampleUUID,
            relativePath: "Photos/1962/letter.pdf",
            page: 2
        )
        let url = link.url
        #expect(url.scheme == "archivereader")
        #expect(url.host == "reveal")
        #expect(url.absoluteString.contains("root=7f3a9c21-4b5e-4a8c-9d3f-1e2a6b7c8d9e"))
        #expect(url.absoluteString.contains("page=2"))

        let parsed = DurableLink(url: url)
        #expect(parsed == link)
    }

    @Test func readerRevealRoundTripWithoutPage() {
        let link = DurableLink.readerReveal(
            rootGUID: sampleUUID,
            relativePath: "memo.pdf",
            page: nil
        )
        let url = link.url
        #expect(!url.absoluteString.contains("page="))

        let parsed = DurableLink(url: url)
        #expect(parsed == link)
    }

    @Test func readerRevealWithSpacesInPath() {
        let link = DurableLink.readerReveal(
            rootGUID: sampleUUID,
            relativePath: "My Documents/old scan.pdf",
            page: nil
        )
        let parsed = DurableLink(url: link.url)
        #expect(parsed == link)
    }

    // MARK: - notesOpen

    @Test func notesOpenRoundTripWithBlock() {
        let link = DurableLink.notesOpen(id: sampleUUID, block: 3)
        let url = link.url
        #expect(url.scheme == "archivenotes")
        #expect(url.host == "open")
        #expect(url.absoluteString.contains("id=7f3a9c21-4b5e-4a8c-9d3f-1e2a6b7c8d9e"))
        #expect(url.fragment == "block-3")

        let parsed = DurableLink(url: url)
        #expect(parsed == link)
    }

    @Test func notesOpenRoundTripWithoutBlock() {
        let link = DurableLink.notesOpen(id: sampleUUID, block: nil)
        let url = link.url
        #expect(url.fragment == nil)

        let parsed = DurableLink(url: url)
        #expect(parsed == link)
    }

    // MARK: - Parse failures

    @Test func parseRejectsUnknownScheme() {
        let url = URL(string: "https://example.com/foo")!
        #expect(DurableLink(url: url) == nil)
    }

    @Test func parseRejectsReaderMissingRoot() {
        let url = URL(string: "archivereader://reveal?rel=foo.pdf")!
        #expect(DurableLink(url: url) == nil)
    }

    @Test func parseRejectsReaderMissingRel() {
        let url = URL(string: "archivereader://reveal?root=7f3a9c21-4b5e-4a8c-9d3f-1e2a6b7c8d9e")!
        #expect(DurableLink(url: url) == nil)
    }

    @Test func parseRejectsReaderInvalidPage() {
        let url = URL(string: "archivereader://reveal?root=7f3a9c21-4b5e-4a8c-9d3f-1e2a6b7c8d9e&rel=a.pdf&page=abc")!
        #expect(DurableLink(url: url) == nil)
    }

    @Test func parseRejectsNotesMissingId() {
        let url = URL(string: "archivenotes://open")!
        #expect(DurableLink(url: url) == nil)
    }

    @Test func parseRejectsNotesInvalidUUID() {
        let url = URL(string: "archivenotes://open?id=not-a-uuid")!
        #expect(DurableLink(url: url) == nil)
    }

    // MARK: - UUID lowercased in URL

    @Test func urlContainsLowercasedUUID() {
        let link = DurableLink.readerReveal(rootGUID: sampleUUID, relativePath: "a.pdf", page: nil)
        let urlStr = link.url.absoluteString
        let uuidLower = sampleUUID.uuidString.lowercased()
        #expect(urlStr.contains(uuidLower))
        // Should NOT contain uppercase UUID
        #expect(!urlStr.contains(sampleUUID.uuidString))
    }
}

@Suite("RootMarker")
struct RootMarkerTests {
    let sampleDate = ISO8601DateFormatter().date(from: "2026-07-10T14:30:00Z")!
    let sampleUUID = UUID(uuidString: "a1b2c3d4-e5f6-7890-abcd-ef1234567890")!

    @Test func codableRoundTrip() throws {
        let marker = RootMarker(
            guid: sampleUUID,
            name: "My Archive",
            kind: .reader,
            createdAt: sampleDate
        )
        let data = try JSONEncoder().encode(marker)
        let decoded = try JSONDecoder().decode(RootMarker.self, from: data)
        #expect(decoded == marker)
    }

    @Test func jsonContainsLowercasedUUID() throws {
        let marker = RootMarker(
            guid: sampleUUID,
            name: "Test",
            kind: .notes,
            createdAt: sampleDate
        )
        let data = try JSONEncoder().encode(marker)
        let json = String(data: data, encoding: .utf8)!

        let uuidLower = sampleUUID.uuidString.lowercased()
        #expect(json.contains(uuidLower))
        // Must NOT contain uppercase UUID (Swift's default Codable would emit uppercase)
        #expect(!json.contains(sampleUUID.uuidString))
    }

    @Test func jsonContainsISO8601Date() throws {
        let marker = RootMarker(
            guid: sampleUUID,
            name: "Test",
            kind: .reader,
            createdAt: sampleDate
        )
        let data = try JSONEncoder().encode(marker)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("2026-07-10T14:30:00Z"))
        // Must NOT contain a float date (Swift's default Date Codable)
        #expect(!json.contains("804"))  // timeIntervalSinceReferenceDate would contain this
    }

    @Test func decodesFromHandwrittenJSON() throws {
        let json = """
        {
            "guid": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
            "name": "My Archive",
            "kind": "reader",
            "createdAt": "2026-07-10T14:30:00Z"
        }
        """
        let marker = try JSONDecoder().decode(RootMarker.self, from: Data(json.utf8))
        #expect(marker.guid == sampleUUID)
        #expect(marker.name == "My Archive")
        #expect(marker.kind == .reader)
        #expect(marker.createdAt == sampleDate)
    }

    @Test func decodesNotesKind() throws {
        let json = """
        {"guid":"a1b2c3d4-e5f6-7890-abcd-ef1234567890","name":"Notes","kind":"notes","createdAt":"2026-07-10T14:30:00Z"}
        """
        let marker = try JSONDecoder().decode(RootMarker.self, from: Data(json.utf8))
        #expect(marker.kind == .notes)
    }

    @Test func rejectsInvalidUUID() {
        let json = """
        {"guid":"not-valid","name":"X","kind":"reader","createdAt":"2026-07-10T14:30:00Z"}
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RootMarker.self, from: Data(json.utf8))
        }
    }

    @Test func rejectsInvalidDate() {
        let json = """
        {"guid":"a1b2c3d4-e5f6-7890-abcd-ef1234567890","name":"X","kind":"reader","createdAt":"not-a-date"}
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RootMarker.self, from: Data(json.utf8))
        }
    }

    @Test func filename() {
        #expect(RootMarker.filename == ".archive-suite-root.json")
    }
}

@Suite("ArchiveSuiteMarker")
struct ArchiveSuiteMarkerTests {
    @Test func isMarkerExactMatch() {
        #expect(ArchiveSuiteMarker.isMarker("ArchiveSuite") == true)
    }

    @Test func isMarkerCaseSensitive() {
        #expect(ArchiveSuiteMarker.isMarker("archivesuite") == false)
        #expect(ArchiveSuiteMarker.isMarker("ARCHIVESUITE") == false)
        #expect(ArchiveSuiteMarker.isMarker("Archive Suite") == false)
    }

    @Test func isMarkerRejectsSubstrings() {
        #expect(ArchiveSuiteMarker.isMarker("ArchiveSuiteExtra") == false)
        #expect(ArchiveSuiteMarker.isMarker("") == false)
    }

    @Test func filterOutMarker() {
        let tags = ["History", "ArchiveSuite", "1962", "Letters"]
        let filtered = ArchiveSuiteMarker.filterOutMarker(from: tags)
        #expect(filtered == ["History", "1962", "Letters"])
    }

    @Test func filterOutMarkerPreservesCollisionSubject() {
        // A user subject literally named "ArchiveSuite" WILL be filtered —
        // this is by design (the marker IS that string). The collision case
        // is handled at a higher level (NotesTagProjector), not here.
        let tags = ["ArchiveSuite"]
        let filtered = ArchiveSuiteMarker.filterOutMarker(from: tags)
        #expect(filtered.isEmpty)
    }

    @Test func tagNameConstant() {
        #expect(ArchiveSuiteMarker.tagName == "ArchiveSuite")
    }
}
