import Foundation
import Testing
import ArchiveCore
@testable import ArchiveNotes

@MainActor
@Suite("Round-up notes (W9.d6)")
struct RoundupTests {
    private func note() -> Item {
        Item(id: UUID(), kind: .note, title: "RoundupSearchMarker", authors: ["Keep Author"], date: nil,
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
        #expect(saved.trailingBodyRaw == item.trailingBodyRaw && saved.authors == item.authors)
        #expect(saved.unknownFrontMatter == item.unknownFrontMatter)
        let summary = try #require(await index.summary(for: item.id))
        #expect(summary.roundup)
        #expect(await index.search("RoundupSearchMarker") == [item.id])

        let query = NotesFilter(searchText: "RoundupSearchMarker", roundup: true)
        let folderID = try #require(await model.createSmartFolder(name: "Round-ups", query: query))
        let folder = try #require(organization.folders.first { $0.id == folderID })
        let encoded = try #require(folder.queryJSON?.data(using: .utf8))
        let decoded = try JSONDecoder().decode(NotesFilter.self, from: encoded)
        #expect(decoded.matches(summary, folderItemIDs: nil))
        #expect(NotesFilter.effective(base: decoded, user: NotesFilter()).roundup == true)
        let conflict = NotesFilter.effective(base: decoded, user: NotesFilter(roundup: false))
        #expect(!conflict.matches(summary, folderItemIDs: nil))
        var nonRoundup = summary; nonRoundup.roundup = false
        #expect(!conflict.matches(nonRoundup, folderItemIDs: nil))
        let restoredConflict = try JSONDecoder().decode(NotesFilter.self, from: JSONEncoder().encode(conflict))
        #expect(!restoredConflict.matches(summary, folderItemIDs: nil))
        #expect(!restoredConflict.matches(nonRoundup, folderItemIDs: nil))
        #expect(try JSONDecoder().decode(NotesFilter.self, from: Data("{}".utf8)).roundup == nil)

        await index.close()
        try await index.open()
        #expect(await index.summary(for: item.id)?.roundup == true)
        #expect(await index.allFolders().contains { $0.id == folderID })
        #expect(await model.setRoundup(false, for: item.id))
        let ordinary = try #require(await index.summary(for: item.id))
        #expect(!decoded.matches(ordinary, folderItemIDs: nil))
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
        #expect(await index.allFolders().contains { $0.id == folder.id })
        try await index.upsertBatch([row])
        #expect(await index.summary(for: item.id)?.roundup == true)
        #expect(await index.existingMTimes()[item.id.uuidString] == ref.mtime)
        #expect(await index.allSummaries().first?.authors == item.authors)
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
        try Data("scratch".utf8).write(to: first)
        try Data("scratch".utf8).write(to: second)
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
        try Data("outside scratch".utf8).write(to: outside)
        try (outside as NSURL).setResourceValue(["1968"], forKey: .tagNamesKey)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.pdf"), withDestinationURL: outside)
        #expect(await RoundupYearSuggestion.commonYear(links: [link("escape.pdf")], roots: roots) == nil)
    }
}
