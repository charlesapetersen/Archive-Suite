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

    @Test func readerRevealPreservesSlashesInMultiSegmentPath() {
        // Corpus folders nest, so a rel path carries both '/' separators and spaces. The '/'
        // must stay LITERAL on the wire (not percent-encoded to %2F) while spaces DO encode,
        // and the exact rel path must round-trip.
        let rel = "Box 1/Folder 2/old scan.pdf"
        let link = DurableLink.readerReveal(rootGUID: sampleUUID, relativePath: rel, page: 4)
        let url = link.url

        #expect(!url.absoluteString.contains("%2F"))
        #expect(url.absoluteString.contains("Box%201/Folder%202/old%20scan.pdf"))

        guard case let .readerReveal(_, parsedRel, parsedPage)? = DurableLink(url: url) else {
            Issue.record("expected a readerReveal link"); return
        }
        #expect(parsedRel == rel)
        #expect(parsedPage == 4)
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

    // MARK: - Percent-encoding of special characters

    @Test func readerRevealWithEmDashInPath() {
        // Em-dash (U+2014) must survive round-trip through percent-encoding
        let link = DurableLink.readerReveal(
            rootGUID: sampleUUID,
            relativePath: "Folder\u{2014}Name/doc.pdf",
            page: 1
        )
        let parsed = DurableLink(url: link.url)
        #expect(parsed == link)
    }

    @Test func readerRevealWithNBSPInPath() {
        // Non-breaking space (U+00A0) must survive round-trip
        let link = DurableLink.readerReveal(
            rootGUID: sampleUUID,
            relativePath: "Folder\u{00A0}Name/doc.pdf",
            page: nil
        )
        let parsed = DurableLink(url: link.url)
        #expect(parsed == link)
    }

    // MARK: - Tolerant parsing (unknown query items ignored)

    @Test func parseIgnoresUnknownQueryItems() {
        let url = URL(string: "archivereader://reveal?root=7f3a9c21-4b5e-4a8c-9d3f-1e2a6b7c8d9e&rel=a.pdf&future=yes&page=3")!
        let parsed = DurableLink(url: url)
        let expected = DurableLink.readerReveal(
            rootGUID: sampleUUID,
            relativePath: "a.pdf",
            page: 3
        )
        #expect(parsed == expected)
    }

    @Test func notesParseIgnoresUnknownQueryItems() {
        let url = URL(string: "archivenotes://open?id=7f3a9c21-4b5e-4a8c-9d3f-1e2a6b7c8d9e&extra=1")!
        let parsed = DurableLink(url: url)
        let expected = DurableLink.notesOpen(id: sampleUUID, block: nil)
        #expect(parsed == expected)
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

    // MARK: - Disk I/O (ensure / read)

    @Test func readReturnsNilForAbsentMarker() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RootMarkerTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = try RootMarker.read(at: dir)
        #expect(result == nil)
    }

    @Test func readReturnsExistingMarker() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RootMarkerTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let marker = RootMarker(guid: sampleUUID, name: "Test", kind: .reader, createdAt: sampleDate)
        let data = try JSONEncoder().encode(marker)
        try data.write(to: dir.appendingPathComponent(RootMarker.filename))

        let result = try RootMarker.read(at: dir)
        #expect(result == marker)
    }

    @Test func readThrowsMalformedForBadJSON() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RootMarkerTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("not json".utf8).write(to: dir.appendingPathComponent(RootMarker.filename))

        #expect(throws: RootMarkerError.self) {
            try RootMarker.read(at: dir)
        }
    }

    @Test func ensureCreatesMarkerOnce() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RootMarkerTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let marker = try RootMarker.ensure(at: dir, kind: .reader, name: "Archive")
        #expect(marker.kind == .reader)
        #expect(marker.name == "Archive")

        // File should exist on disk
        let fileURL = dir.appendingPathComponent(RootMarker.filename)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func ensureIsIdempotent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RootMarkerTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = try RootMarker.ensure(at: dir, kind: .reader, name: "Archive")
        let second = try RootMarker.ensure(at: dir, kind: .notes, name: "Different")

        // guid must be stable — second call returns the FIRST marker, not a new one
        #expect(second.guid == first.guid)
        #expect(second.kind == first.kind)
        #expect(second.name == first.name)
    }

    @Test func ensureNeverOverwritesMalformedFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RootMarkerTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent(RootMarker.filename)
        let garbage = Data("this is not json".utf8)
        try garbage.write(to: fileURL)

        // ensure should throw malformed, never silently overwrite
        #expect(throws: RootMarkerError.self) {
            try RootMarker.ensure(at: dir, kind: .reader, name: "Archive")
        }

        // Original garbage file must be untouched
        let afterData = try Data(contentsOf: fileURL)
        #expect(afterData == garbage)
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

@Suite("ArchiveLinkPayload")
struct ArchiveLinkPayloadTests {
    @Test func codableRoundTrip() throws {
        let payload = ArchiveLinkPayload(entries: [
            .init(link: "archivereader://reveal?root=abc&rel=doc.pdf", display: "doc", page: nil),
            .init(link: "archivereader://reveal?root=abc&rel=scan.pdf&page=3",
                  display: "scan \u{2014} p.3", page: 3, thumbPNGBase64: "iVBOR..."),
        ])
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ArchiveLinkPayload.self, from: data)
        #expect(decoded == payload)
    }

    @Test func versionDefaultsToOne() {
        let payload = ArchiveLinkPayload(entries: [])
        #expect(payload.version == 1)
    }

    @Test func entryFieldsPresent() throws {
        let entry = ArchiveLinkPayload.Entry(
            link: "archivereader://reveal?root=abc&rel=x.pdf&page=5",
            display: "x \u{2014} p.5",
            page: 5,
            thumbPNGBase64: "AAAA"
        )
        let data = try JSONEncoder().encode(entry)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("\"link\""))
        #expect(json.contains("\"display\""))
        #expect(json.contains("\"page\""))
        #expect(json.contains("\"thumbPNGBase64\""))
    }

    @Test func entryOptionalFieldsAbsent() throws {
        let entry = ArchiveLinkPayload.Entry(link: "x://y", display: "d")
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(ArchiveLinkPayload.Entry.self, from: data)
        #expect(decoded.page == nil)
        #expect(decoded.thumbPNGBase64 == nil)
    }

    @Test func utiConstant() {
        #expect(ArchiveLinkUTI.type == "com.archivesuite.archive-links")
    }
}
