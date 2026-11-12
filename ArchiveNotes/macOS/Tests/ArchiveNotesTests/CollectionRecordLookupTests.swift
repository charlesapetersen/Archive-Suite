import Foundation
import Testing
import ArchiveCore
@testable import ArchiveNotes

/// W46.settings-reader-notes: a note's linked PDFs find the Processor's record of their collection, only under a
/// granted Reader root, once per collection.
@Suite("Collection settings record lookup (W46.settings-reader-notes)")
struct CollectionRecordLookupTests {
    @Test("Linked PDFs find their collection's record once, and nothing outside a granted root")
    func findsRecordsUnderGrantedRoots() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-collrec-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = RootMarker(guid: UUID(), name: "Scratch Reader", kind: .reader, createdAt: Date())
        try JSONEncoder().encode(marker).write(to: root.appendingPathComponent(RootMarker.filename))

        let box = root.appendingPathComponent("Box 3/Folder 1", isDirectory: true)
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        let doc = #"{"schemaVersion":1,"createdAt":"2026-11-04T09:59:00Z","collection":{"id":"A","kind":"collection","name":"Box 3","entries":{}}}"#
        let suite = root.appendingPathComponent("Box 3/.archivesuite", isDirectory: true)
        try FileManager.default.createDirectory(at: suite, withIntermediateDirectories: true)
        try Data(doc.utf8).write(to: suite.appendingPathComponent("collection-settings.json"))
        for name in ["a.pdf", "b.pdf"] { try Data().write(to: box.appendingPathComponent(name)) }
        try Data().write(to: root.appendingPathComponent("loose.pdf"))

        func link(_ path: String) -> String {
            DurableLink.readerReveal(rootGUID: marker.guid, relativePath: path, page: nil).url.absoluteString
        }
        let roots = [marker.guid: root]
        let links = [link("Box 3/Folder 1/a.pdf"), link("Box 3/Folder 1/b.pdf"), link("loose.pdf"),
                     "not a Reader link", link("../escape.pdf")]
        let found = await CollectionRecordLookup.records(links: links, roots: roots)
        #expect(found.map(\.collectionName) == ["Box 3"])
        #expect(await CollectionRecordLookup.records(links: links, roots: [:]).isEmpty)
        #expect(await CollectionRecordLookup.records(links: [], roots: roots).isEmpty)
    }
}
