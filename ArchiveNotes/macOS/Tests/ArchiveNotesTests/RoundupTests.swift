import Foundation
import Testing
import PDFKit
import ArchiveCore
@testable import ArchiveNotes

@MainActor
@Suite("Round-up notes (W9.d6)")
struct RoundupTests {
    private func note() -> Item {
        Item(id: UUID(), kind: .note, title: "RoundupSearchMarker", date: nil,
             datePrecision: nil, dateUncertain: false, quality: nil, tags: [], zotero: [], roundup: false,
             created: Date(), modified: Date(), schema: 1, blocks: [],
             unknownFrontMatter: [UnknownKey(key: "future_key", rawLines: ["future_key: preserve"])], trailingBodyRaw: "Keep body\n")
    }

    @Test("Toggle persists independently of date/body, and live and saved filters agree after reopen")
    func toggleAndSavedQuery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-roundup-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = NotesIndex(url: root.appendingPathComponent("index.db"))
        try await index.open()
        let organization = OrganizationStore(index: index)
        try await organization.load(storeRoot: root)
        let store = NoteStore(root: root)
        let item = note()
        _ = try await store.create(item)
        let model = NotesModel(organization: organization, index: index, noteStore: store)
        #expect(await model.setRoundup(true, for: item.id))
        let saved = try await store.load(item.id)
        #expect(saved.roundup && saved.date == nil)
        #expect(saved.trailingBodyRaw == item.trailingBodyRaw)
        #expect(saved.unknownFrontMatter == item.unknownFrontMatter)
        let summary = try #require(await index.summary(for: item.id))
        #expect(summary.roundup)
        #expect(await index.search("RoundupSearchMarker") == [item.id])

        let query = NotesAdvancedSearch(filter: NotesFilter(searchText: "RoundupSearchMarker", roundup: true),
                                        keyword: "")
        let folderID = try #require(await model.createSmartFolder(name: "Round-ups", query: query))
        let folder = try #require(organization.folders.first { $0.id == folderID })
        let encoded = try #require(folder.queryJSON?.data(using: .utf8))
        let decoded = try JSONDecoder().decode(NotesAdvancedSearch.self, from: encoded)
        #expect(decoded.matches(summary, NotesRuleContext()))
        // A round-up smart folder narrowed by "other items" in the filter bar matches nothing, saved or not.
        let conflict = decoded.narrowed(by: NotesAdvancedSearch(filter: NotesFilter(roundup: false), keyword: ""))
        #expect(!conflict.matches(summary, NotesRuleContext()))
        var nonRoundup = summary; nonRoundup.roundup = false
        #expect(!conflict.matches(nonRoundup, NotesRuleContext()))
        let restoredConflict = try JSONDecoder().decode(NotesAdvancedSearch.self, from: JSONEncoder().encode(conflict))
        #expect(!restoredConflict.matches(summary, NotesRuleContext()))
        #expect(!restoredConflict.matches(nonRoundup, NotesRuleContext()))
        #expect(try JSONDecoder().decode(NotesFilter.self, from: Data("{}".utf8)).roundup == nil)

        await index.close()
        try await index.open()
        #expect(await index.summary(for: item.id)?.roundup == true)
        #expect(try await index.allFolders().contains { $0.id == folderID })
        #expect(await model.setRoundup(false, for: item.id))
        let ordinary = try #require(await index.summary(for: item.id))
        #expect(!decoded.matches(ordinary, NotesRuleContext()))
        #expect(NotesFilter(roundup: false).matches(ordinary, folderItemIDs: nil))
        #expect(try await store.load(item.id).date == nil)
        var extract = item
        extract.id = UUID(); extract.kind = .extract
        _ = try await store.create(extract)
        #expect(await model.setRoundup(true, for: extract.id) == false)
        #expect(try await store.load(extract.id).roundup == false)
        await index.close()
    }

    @Test("Legacy index rows reproject unchanged files and retain organization and FTS data")
    func legacyIndexBackfill() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-roundup-migration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = NotesIndex(url: root.appendingPathComponent("index.db"))
        try await index.open()
        let organization = OrganizationStore(index: index)
        try await organization.load(storeRoot: root)
        let folder = try await organization.createFolder(name: "Preserved folder")
        let store = NoteStore(root: root)
        var item = note(); item.roundup = true
        let ref = try await store.create(item)
        let row = NoteIndexRow(item: item, mtime: ref.mtime)
        try await index.upsertBatch([row])
        try await index.executeForTesting("ALTER TABLE items DROP COLUMN roundup;")
        await index.close()
        try await index.open()
        #expect(await index.existingMTimes()[item.id.uuidString] == nil,
                "the indexer must not skip a pre-roundup row even when disk mtime is unchanged")
        #expect(await index.search("RoundupSearchMarker") == [item.id])
        #expect(try await index.allFolders().contains { $0.id == folder.id })
        try await index.upsertBatch([row])
        #expect(await index.summary(for: item.id)?.roundup == true)
        #expect(await index.existingMTimes()[item.id.uuidString] == ref.mtime)
        await index.close()
    }

    @Test("Year offer requires every exact linked PDF to be dated in the same granted archive")
    func sourceYears() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-roundup-reader-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = RootMarker(guid: UUID(), name: "Scratch Reader", kind: .reader, createdAt: Date())
        try JSONEncoder().encode(marker).write(to: root.appendingPathComponent(RootMarker.filename))
        let first = root.appendingPathComponent("first.pdf"), second = root.appendingPathComponent("second.pdf")
        try scratchPDF().write(to: first)
        try scratchPDF().write(to: second)
        try (first as NSURL).setResourceValue(["1968"], forKey: .tagNamesKey)
        try (second as NSURL).setResourceValue(["1968"], forKey: .tagNamesKey)
        func link(_ path: String, page: Int? = nil) -> String {
            DurableLink.readerReveal(rootGUID: marker.guid, relativePath: path, page: page).url.absoluteString
        }
        let roots = [marker.guid: root]
        let links = [link("first.pdf"), link("first.pdf", page: 2), link("second.pdf")]
        #expect(await RoundupYearSuggestion.commonYear(links: links, roots: roots) == 1968)
        #expect(await RoundupYearSuggestion.commonYear(links: links, roots: [:]) == nil)
        #expect(await RoundupYearSuggestion.commonYear(links: [link("missing.pdf")], roots: roots) == nil)
        try (second as NSURL).setResourceValue(["1969"], forKey: .tagNamesKey)
        #expect(await RoundupYearSuggestion.commonYear(links: links, roots: roots) == nil)
        try (second as NSURL).setResourceValue([], forKey: .tagNamesKey)
        #expect(await RoundupYearSuggestion.commonYear(links: links, roots: roots) == nil)
        #expect(await RoundupYearSuggestion.commonYear(links: [], roots: roots) == nil)
        #expect(await RoundupYearSuggestion.commonYear(links: ["not a Reader link"], roots: roots) == nil)
        let outside = root.deletingLastPathComponent().appendingPathComponent("roundup-outside-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: outside) }
        try scratchPDF().write(to: outside)
        try (outside as NSURL).setResourceValue(["1968"], forKey: .tagNamesKey)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.pdf"), withDestinationURL: outside)
        #expect(await RoundupYearSuggestion.commonYear(links: [link("escape.pdf")], roots: roots) == nil)
    }

    /// W49.storage-notes-zotero: a PDF with a catalogue companion offers its record's year, never its Finder tag, and
    /// a PDF separated from its companion offers none.
    @Test("Year offer reads the catalogue record of each exact linked PDF")
    func catalogueYears() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-roundup-catalogue-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = RootMarker(guid: UUID(), name: "Scratch Reader", kind: .reader, createdAt: Date())
        try JSONEncoder().encode(marker).write(to: root.appendingPathComponent(RootMarker.filename))
        let pdf = root.appendingPathComponent("letter.pdf")
        try scratchPDF().write(to: pdf)
        try (pdf as NSURL).setResourceValue(["1968"], forKey: .tagNamesKey)
        let fileID = UUID(), content = UUID(), document = UUID()
        let companion = root.appendingPathComponent(CatalogueRecord.companionFilename(forPDFFilename: "letter.pdf"))
        try Data("""
        {"schema":1,"fileID":"\(fileID)","contentRevision":"\(content)","revision":"\(UUID())","parents":[],
         "pages":[{"id":"\(UUID())","physicalIndex":0,"documentID":"\(document)","role":"searchable"}],
         "documents":[{"id":"\(document)","ownerFileID":"\(fileID)","fields":{"documentDate":{"state":"value",
           "value":{"date":"1970-05","uncertain":false},"fieldRevision":"\(UUID())","origin":"user"}}}],"fileFields":{}}
        """.utf8).write(to: companion)
        let identify: CatalogueReader.IdentifyPDF = { _, _ in .init(fileID: fileID, contentRevision: content, pageCount: 1) }
        let links = [DurableLink.readerReveal(rootGUID: marker.guid, relativePath: "letter.pdf", page: 1).url.absoluteString]
        let roots = [marker.guid: root]
        #expect(RoundupYearSuggestion.readYear(links: links, roots: roots, identifyPDF: identify) == 1970)
        try FileManager.default.removeItem(at: companion)
        #expect(RoundupYearSuggestion.readYear(links: links, roots: roots, identifyPDF: identify) == nil,
                "a detached PDF's tag is not its current date")
        #expect(RoundupYearSuggestion.readYear(links: links, roots: roots, identifyPDF: { _, _ in nil }) == 1968,
                "a file with no catalogue identity keeps its tags")
        try Data("not a PDF".utf8).write(to: pdf)
        #expect(RoundupYearSuggestion.readYear(links: links, roots: roots, identifyPDF: { _, _ in nil }) == nil,
                "a file that cannot be shown to predate the catalogue offers no tag")
    }

    /// A real one-page PDF with no catalogue identity: a file that predates the catalogue.
    private func scratchPDF() throws -> Data {
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        return try #require(document.dataRepresentation())
    }
}
