// SourceArchiveInfoTests.swift — W47.ct-zotero: a source block's archival location and its "Copy for Zotero".
//
// Every root is a temporary Reader-shaped folder with a marker, an "Archival Photos" tree, a level map, a container
// file and a sidecar. Nothing outside it is read, and only the exact path a link names is.

import Testing
import Foundation
import AppKit
import PDFKit
import ArchiveCore
@testable import ArchiveNotes

@MainActor
@Suite("Source block archival location and Copy for Zotero (W47.ct-zotero)")
struct SourceArchiveInfoTests {

    private func makeRoot() throws -> (root: URL, marker: RootMarker, pdf: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceArchiveInfo-\(UUID().uuidString)", isDirectory: true)
        let main = root.appendingPathComponent(ContainerLookup.mainDirectoryName, isDirectory: true)
        let box = main.appendingPathComponent("Hoover Institution Archives/Glotzer Papers/Box 17", isDirectory: true)
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        let marker = RootMarker(guid: UUID(), name: "Scratch Reader", kind: .reader, createdAt: Date())
        try JSONEncoder().encode(marker).write(to: root.appendingPathComponent(RootMarker.filename), options: .atomic)
        try ContainerFileStore.writeLevelMap(ContainerLevelMap(levels: [.repository, .collection, .box]), root: main,
                                             expecting: nil)
        try ContainerFileStore.write(ContainerFile(runs: [ContainerRun(start: "0001.pdf", level: .folder, fields:
            ContainerFieldSet([.folder: ContainerValue("Folder 8", source: .user)]))]), directory: box, expecting: nil)
        let pdf = box.appendingPathComponent("0002.pdf")
        // A real PDF with no catalogue identity: a file that predates the catalogue (W49.storage-notes-zotero).
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        try #require(document.dataRepresentation()).write(to: pdf)
        try (pdf as NSURL).setResourceValue(["1959", "Trotskyism"], forKey: .tagNamesKey)
        try Data(#"{"author_name": "Max Shachtman", "recipient_name": "Albert Glotzer", "format": "Letter"}"#.utf8)
            .write(to: box.appendingPathComponent("0002.json"))
        return (root, marker, pdf)
    }

    private func scratchDefaults() -> UserDefaults {
        let suite = "ArchiveNotesTests.SourceArchiveInfo.\(UUID().uuidString)"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    private func anchor(_ marker: RootMarker, _ relativePath: String) -> SourceAnchor {
        SourceAnchor(link: DurableLink.readerReveal(rootGUID: marker.guid, relativePath: relativePath, page: 1)
            .url.absoluteString, display: "0002.pdf — p. 1", page: 1)
    }

    private let relative = "Archival Photos/Hoover Institution Archives/Glotzer Papers/Box 17/0002.pdf"

    @Test("The chip's line is the repository, collection and location; Copy for Zotero carries every gathered field")
    func lineAndExport() async throws {
        let fixture = try makeRoot()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = ReaderRootStore(defaults: scratchDefaults())
        #expect(store.grantRoot(fixture.root).marker?.guid == fixture.marker.guid)
        let info = SourceArchiveInfo(rootStore: store)
        let source = anchor(fixture.marker, relative)

        #expect(await info.containerLine(for: source)
                == "Hoover Institution Archives · Glotzer Papers · Box 17, Folder 8")

        let json = try #require(await info.zoteroJSON(for: source))
        let items = try #require(try JSONSerialization.jsonObject(with: json) as? [[String: Any]])
        let item = try #require(items.first)
        #expect(item["type"] as? String == "personal_communication")
        #expect(item["archive"] as? String == "Hoover Institution Archives")
        #expect(item["archive_location"] as? String == "Box 17, Folder 8")
        #expect((item["recipient"] as? [[String: String]])?.first?["literal"] == "Albert Glotzer")
        #expect((item["issued"] as? [String: Any])?["date-parts"] as? [[Int]] == [[1959]])
        #expect(item["URL"] as? String == source.link)
        #expect((item["note"] as? String)?.contains("Subjects: Trotskyism") == true)

        // W47.ct-zotero-tags: Add to Zotero sends the same source, with the subjects as tags.
        let gathered = try #require(await info.zoteroSources(for: source))
        let sent = try #require(ZoteroExport.connectorItems(gathered).first)
        #expect(sent["itemType"] as? String == "letter")
        #expect((sent["tags"] as? [[String: String]])?.compactMap { $0["tag"] } == ["Trotskyism"])
        #expect(sent["url"] as? String == source.link)
    }

    /// W49.storage-notes-zotero: a PDF with a catalogue companion is described by its record, read from the linked
    /// page's document, the same in Copy for Zotero and Add to Zotero; its tags and sidecar are not read. Separated from
    /// its companion it exports only the file and its container, saying why. The root may move between grants.
    @Test("Copy and Add to Zotero read the linked page's catalogue record")
    func catalogueRecord() async throws {
        let fixture = try makeRoot()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let fileID = UUID(), content = UUID(), letter = UUID(), clipping = UUID()
        func field(_ value: String) -> String {
            #"{"state":"value","value":\#(value),"fieldRevision":"\#(UUID())","origin":"user"}"#
        }
        let companion = fixture.pdf.deletingLastPathComponent()
            .appendingPathComponent(CatalogueRecord.companionFilename(forPDFFilename: "0002.pdf"))
        try Data("""
        {"schema":1,"fileID":"\(fileID)","contentRevision":"\(content)","revision":"\(UUID())","parents":[],
         "pages":[{"id":"\(UUID())","physicalIndex":0,"documentID":"\(letter)","role":"searchable"},
                  {"id":"\(UUID())","physicalIndex":1,"documentID":"\(clipping)","role":"searchable"}],
         "documents":[{"id":"\(letter)","ownerFileID":"\(fileID)","fields":{"documentKind":\(field(#""letter""#)),
             "documentDate":\(field(#"{"date":"1961-02","uncertain":true}"#)),
             "recipients":\(field(#"["Record Recipient"]"#)),"subjects":\(field(#"["Record Subject"]"#))}},
           {"id":"\(clipping)","ownerFileID":"\(fileID)","fields":{"title":\(field(#""Second document""#))}}],
         "fileFields":{}}
        """.utf8).write(to: companion)
        let store = ReaderRootStore(defaults: scratchDefaults())
        _ = store.grantRoot(fixture.root)
        let info = SourceArchiveInfo(rootStore: store) { _, _ in .init(fileID: fileID, contentRevision: content, pageCount: 2) }
        let source = anchor(fixture.marker, relative)

        let json = try #require(await info.zoteroJSON(for: source))
        let items = try #require(try JSONSerialization.jsonObject(with: json) as? [[String: Any]])
        let item = try #require(items.count == 1 ? items.first : nil)
        #expect(item["archive"] as? String == "Hoover Institution Archives")
        #expect((item["recipient"] as? [[String: String]])?.first?["literal"] == "Record Recipient")
        #expect((item["issued"] as? [String: Any])?["date-parts"] as? [[Int]] == [[1961, 2]])
        #expect((item["issued"] as? [String: Any])?["circa"] as? Bool == true)
        #expect((item["note"] as? String)?.contains("Trotskyism") == false, "the tag is not the record")
        #expect(item["author"] == nil, "the sidecar's sender is not the record's")
        let sent = try #require(await info.zoteroSources(for: source))
        #expect(ZoteroExport.connectorItems(sent).first?["tags"] as? [[String: String]] == [["tag": "Record Subject"]])

        let fileLink = SourceAnchor(link: DurableLink.readerReveal(rootGUID: fixture.marker.guid, relativePath: relative,
                                                                   page: nil).url.absoluteString)
        #expect(try #require(await info.zoteroSources(for: fileLink)).map(\.itemFields.title) == [nil, "Second document"])

        let moved = fixture.root.deletingLastPathComponent().appendingPathComponent("Moved-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: fixture.root, to: moved)
        defer { try? FileManager.default.removeItem(at: moved) }
        _ = store.grantRoot(moved)
        let movedCompanion = moved.appendingPathComponent(ContainerLookup.mainDirectoryName)
            .appendingPathComponent("Hoover Institution Archives/Glotzer Papers/Box 17")
            .appendingPathComponent(CatalogueRecord.companionFilename(forPDFFilename: "0002.pdf"))
        #expect(try #require(await info.zoteroSources(for: source)).first?.sidecar?.recipients == ["Record Recipient"])
        try FileManager.default.removeItem(at: movedCompanion)
        let detached = try #require(await info.zoteroSources(for: source)?.first)
        #expect(detached.catalogueUnavailable == "the catalogue companion is missing")
        #expect(detached.tags == nil && detached.sidecar == nil)
        #expect(detached.container[.repository] == "Hoover Institution Archives")
    }

    @Test("A source not at its recorded path, or in a root not granted, gives nothing")
    func unreachable() async throws {
        let fixture = try makeRoot()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = ReaderRootStore(defaults: scratchDefaults())
        let info = SourceArchiveInfo(rootStore: store)
        #expect(await info.zoteroJSON(for: anchor(fixture.marker, relative)) == nil, "the root is not granted")
        _ = store.grantRoot(fixture.root)
        #expect(await info.containerLine(for: anchor(fixture.marker, "Archival Photos/moved/0002.pdf")) == nil)
        #expect(await info.zoteroJSON(for: anchor(fixture.marker, "../outside.pdf")) == nil)
        #expect(await info.zoteroJSON(for: SourceAnchor(link: "https://example.com/x.pdf")) == nil)
    }

    @Test("A Reader source's chip has the location line and Copy for Zotero; a Zotero item's chip has neither")
    func chipControls() {
        func ids(_ view: NSView) -> [String] {
            [view.accessibilityIdentifier()].filter { !$0.isEmpty } + view.subviews.flatMap(ids)
        }
        let reader = SourceAnchor(link: "archivereader://reveal?x", display: "a.pdf — p. 1", page: 1)
        let chip = BlockHeaderChipView(box: SourceAnchorBox(anchor: reader, kind: .readerPage), onReveal: nil)
        #expect(ids(chip).contains("an.chip.copyForZotero"))
        #expect(ids(chip).contains("an.chip.addToZotero"))
        #expect(ids(chip).contains("an.chip.container"))
        let zotero = SourceAnchor(display: "Item", zoteroSelect: "zotero://select/items/ABC")
        let other = BlockHeaderChipView(box: SourceAnchorBox(anchor: zotero, kind: .zoteroItem), onReveal: nil)
        #expect(!ids(other).contains("an.chip.copyForZotero"))
        #expect(!ids(other).contains("an.chip.addToZotero"))
        #expect(!ids(other).contains("an.chip.container"))
    }

    @Test("A line from whatever the container has")
    func lineParts() {
        #expect(SourceArchiveInfo.containerLine([:]) == nil)
        #expect(SourceArchiveInfo.containerLine([.collectionNumber: "Mss 1036", .container: "Box 2"])
                == "Mss 1036 · Box 2")
    }
}
