import XCTest
import ArchiveCore
@testable import ArchiveReader

/// W49.storage-finder-reader-mirror (Tier-2: tag writes to archive PDFs and a settings document in the archive). The
/// Reader's Finder mirror over a catalogue-mode scratch archive: turning it on records the archive's choice and projects
/// the record, keeping a hand-made tag; an edit is projected; a tag changed in Finder is a divergence that blocks the
/// projection until Import takes it into the record; turning it off with Remove Suite Tags leaves only the hand-made
/// tag, and Put Back restores the suite's. Scratch `mktemp` roots only, never the corpus.
@MainActor
final class FinderMirrorReaderTests: XCTestCase {
    private func waitUntil(_ what: String, timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), what)
    }

    private func writePDF(at url: URL, metadata: Data?) throws {
        var bounds = CGRect(x: 0, y: 0, width: 60, height: 60)
        let pdf = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &bounds, nil))
        if let metadata { pdf.addDocumentMetadata(metadata as CFData) }
        pdf.beginPDFPage(nil)
        pdf.fill(bounds.insetBy(dx: 10, dy: 10))
        pdf.endPDFPage()
        pdf.closePDF()
    }

    private func tags(_ url: URL) -> [String] {
        (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }

    private func setTags(_ url: URL, _ tags: [String]) throws {
        try (URL(fileURLWithPath: url.path) as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
    }

    private func companion(_ url: URL) throws -> CatalogueRecord {
        try CatalogueRecord(json: Data(contentsOf: url.appendingPathExtension("archivesuite.json")))
    }

    func testTheMirrorFollowsTheRecordAndNeverTakesAFinderEditSilently() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderMirrorReaderTests-\(UUID())", isDirectory: true).resolvingSymlinksInPath()
        let root = folder.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        _ = try RootMarker.ensure(at: root, kind: .reader, name: "Scratch")
        let identity = CataloguePDFIdentity(fileID: UUID(), contentRevision: UUID())
        let page = UUID(), document = UUID()
        let packet = Data("""
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            </rdf:RDF></x:xmpmeta>
            """.utf8)
        let pdf = root.appendingPathComponent("Letter.pdf")
        try writePDF(at: pdf, metadata: XCTUnwrap(identity.adding(to: packet)))
        try setTags(pdf, ["ToPrint"])
        func field(_ value: String) -> String {
            "{\"state\":\"value\",\"value\":\(value),\"fieldRevision\":\"\(UUID())\",\"origin\":\"user\"}"
        }
        try Data("""
            {"schema":1,"fileID":"\(identity.fileID)","contentRevision":"\(identity.contentRevision)",
             "revision":"\(UUID())","parents":[],
             "pages":[{"id":"\(page)","physicalIndex":0,"documentID":"\(document)","role":"searchable"}],
             "documents":[{"id":"\(document)","ownerFileID":"\(identity.fileID)",
                           "fields":{"subjects":\(field("[\"Berlin\"]"))}}],
             "fileFields":{"readState":\(field("\"unread\""))}}
            """.utf8).write(to: root.appendingPathComponent("Letter.pdf.archivesuite.json"))

        let defaults = fixtureDefaults()
        let model = NavigationModel(defaults: defaults,
                                    indexer: ContentIndexer(url: folder.appendingPathComponent("index.sqlite")),
                                    thumbnailer: nil)
        XCTAssertNil(model.rootStore.setRoot(root))
        let key = try XCTUnwrap(ReaderRootIdentity.legacyCatalogueKey(for: root))
        defaults.set(UUID().uuidString, forKey: key)
        defaults.set(true, forKey: key + ".enabled")
        model.startLibrary(root)
        try await waitUntil("catalogue mode") {
            model.library.usesCatalogue && model.catalogueSnapshot != nil && model.library.files.first?.isCatalogue == true
        }
        XCTAssertFalse(model.finderMirrorOn, "off unless the archive turns it on")
        XCTAssertEqual(tags(pdf), ["ToPrint"])

        // Turning it on records the archive's choice and projects the record; the hand-made tag stays.
        model.requestFinderMirror(true)
        XCTAssertEqual(model.finderMirrorPrompt, .turnOn(pdfs: 1))
        model.confirmFinderMirror(on: true)
        XCTAssertEqual(try ArchiveSettings.read(root: root)?.mirrorFinderTags, true)
        try await waitUntil("projected") { Set(self.tags(pdf)) == ["ToPrint", "Berlin", "Unread"] && model.finderMirrorTask == nil }
        XCTAssertFalse(model.finderMirrorBackfillPending)

        // An edit is projected after it saves.
        let path = try XCTUnwrap(model.library.files.first).path
        model.applyEdit(.addSubject("Lincoln"), paths: [path])
        try await waitUntil("edit saved") { model.library.files.first?.subjects.contains("Lincoln") == true && !model.catalogueEditSaving }
        try await waitUntil("edit projected") { self.tags(pdf).contains("Lincoln") && model.finderMirrorTask == nil }

        // A mirrored tag changed in Finder blocks the next projection and is shown, not taken.
        try setTags(pdf, tags(pdf).filter { $0 != "Unread" } + ["Read"])
        model.checkFinderMirror(relativePath: "Letter.pdf")
        try await waitUntil("divergence shown") { model.finderMirrorDivergences["Letter.pdf"] != nil }
        // The file watcher re-reads a PDF changed in Finder (its change time moved, which a save's base checks); the
        // test host has none, so ask as it would, and save once the list holds the re-read file.
        for _ in 0..<20 where model.library.files.first?.subjects.contains("Bonn") != true {
            model.library.reviseCatalogue(relativePaths: ["Letter.pdf"])
            try await Task.sleep(nanoseconds: 250_000_000)
            model.applyEdit(.addSubject("Bonn"), paths: [path])
            try await waitUntil("save finished") { !model.catalogueEditSaving }
        }
        XCTAssertTrue(model.library.files.first?.subjects.contains("Bonn") == true, "saved")
        try await waitUntil("projection refused") { model.finderMirrorTask == nil }
        XCTAssertFalse(tags(pdf).contains("Bonn"), "a diverged file is not written")
        XCTAssertTrue(tags(pdf).contains("Read"))
        XCTAssertEqual(NavigationModel.value(try companion(pdf).fileFields.readState), "unread", "never taken silently")

        // Import takes the Finder value into the record, then the mirror follows the record again.
        model.importFinderMirror(relativePath: "Letter.pdf")
        try await waitUntil("imported") {
            (try? NavigationModel.value(self.companion(pdf).fileFields.readState)) == "read"
                && self.tags(pdf).contains("Bonn") && model.finderMirrorTask == nil && !model.catalogueEditSaving
        }
        XCTAssertNil(model.finderMirrorDivergences["Letter.pdf"])
        XCTAssertFalse(tags(pdf).contains("Unread"))

        // Turning off with Remove Suite Tags leaves only tags the suite did not write; Put Back restores the suite's.
        model.requestFinderMirror(false)
        XCTAssertEqual(model.finderMirrorPrompt, .turnOff)
        model.confirmFinderMirror(on: false, removingSuiteTags: true)
        XCTAssertEqual(try ArchiveSettings.read(root: root)?.mirrorFinderTags, false)
        // "Read" was typed in Finder and then imported: the suite never wrote it, so it stays.
        try await waitUntil("removed") { Set(self.tags(pdf)) == ["ToPrint", "Read"] && model.finderMirrorTask == nil }
        XCTAssertTrue(model.finderMirrorRemovalsAvailable)
        model.putBackSuiteFinderTags()
        try await waitUntil("put back") {
            Set(self.tags(pdf)) == ["ToPrint", "Berlin", "Lincoln", "Bonn", "Read"] && model.finderMirrorTask == nil
        }
        XCTAssertFalse(model.finderMirrorRemovalsAvailable)
    }
}
