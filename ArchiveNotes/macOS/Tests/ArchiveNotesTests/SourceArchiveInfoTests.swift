// SourceArchiveInfoTests.swift — W47.ct-zotero: a source block's archival location and its "Copy for Zotero".
//
// Every root is a temporary Reader-shaped folder with a marker, an "Archival Photos" tree, a level map, a container
// file and a sidecar. Nothing outside it is read, and only the exact path a link names is.

import Testing
import Foundation
import AppKit
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
        try Data("scratch fixture".utf8).write(to: pdf)
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
        let gathered = try #require(await info.zoteroSource(for: source))
        let sent = try #require(ZoteroExport.connectorItems([gathered]).first)
        #expect(sent["itemType"] as? String == "letter")
        #expect((sent["tags"] as? [[String: String]])?.compactMap { $0["tag"] } == ["Trotskyism"])
        #expect(sent["url"] as? String == source.link)
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
