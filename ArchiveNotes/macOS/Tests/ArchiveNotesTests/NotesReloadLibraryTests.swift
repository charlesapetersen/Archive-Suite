import Testing
import Foundation
@testable import ArchiveNotes

/// W49.notes-reload-library — File ▸ Reload Library picks up notes and folders changed on disk outside the
/// app, without a relaunch, and never loads the disk over this session's own changes.
///
/// "Outside the app" is a second `NoteStore` on the same scratch library (what a sync service or another
/// Mac amounts to) and a hand-written `organization.json`. All scratch: a per-test temp dir holds the
/// library and the index. Never the owner's notes, never a corpus.
@Suite("File ▸ Reload Library (W49.notes-reload-library)")
@MainActor
struct NotesReloadLibraryTests {

    private struct Fixture {
        let dir: URL
        let root: URL
        let index: NotesIndex
        let organization: OrganizationStore
        let model: NotesModel
        let store: NoteStore
        /// The same library seen from outside the app.
        let outside: NoteStore
    }

    private func makeItem(_ title: String) -> Item {
        Item(id: UUID(), kind: .note, title: title, date: nil, datePrecision: nil,
             dateUncertain: false, quality: nil, tags: [], zotero: [], roundup: false,
             created: Date(), modified: Date(), schema: 1, blocks: [],
             unknownFrontMatter: [], trailingBodyRaw: nil)
    }

    /// A model shaped like the app path after `bootstrap`: graph loaded, index built from disk.
    private func fixture(titles: [String]) async throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesReloadLibrary-\(UUID().uuidString)", isDirectory: true)
        let root = dir.appendingPathComponent("Library.archivenotes", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = NoteStore(root: root)
        for title in titles { _ = try await store.create(makeItem(title)) }
        let index = NotesIndex(url: dir.appendingPathComponent("index.sqlite3"))
        try await index.open()
        let organization = OrganizationStore(index: index, mirrorDebounce: .milliseconds(1))
        try await organization.load(storeRoot: root)
        await organization.flushPendingMirror()
        let model = NotesModel(organization: organization, index: index,
                               noteStore: store, indexer: NotesIndexer(index: index))
        await model.buildIndexFromDisk()
        return Fixture(dir: dir, root: root, index: index, organization: organization, model: model,
                       store: store, outside: NoteStore(root: root))
    }

    private func cleanUp(_ f: Fixture) async {
        await f.organization.flushPendingMirror()
        await f.index.close()
        try? FileManager.default.removeItem(at: f.dir)
    }

    /// Write `organization.json` as another Mac would: the graph on disk plus `extra` folders.
    private func writeMirrorFromOutside(_ f: Fixture, adding extra: [VFolder]) throws {
        let file = try #require(OrganizationFile.load(from: f.root))
        try OrganizationFile.export(folders: file.folders + extra, memberships: file.memberships,
                                    assignments: file.assignments, to: f.root)
    }

    private func folder(_ name: String) -> VFolder {
        VFolder(id: UUID(), name: name, parentId: nil, sortOrder: 99, kind: .normal, queryJSON: nil)
    }

    // MARK: - Notes

    @Test("a note added, edited or deleted outside the app shows after Reload Library")
    func notesChangedOnDiskAreReloaded() async throws {
        let f = try await fixture(titles: ["Ptolemy", "Quintessence", "Rhetoric"])
        defer { Task { await cleanUp(f) } }
        let ids = Dictionary(uniqueKeysWithValues: f.model.allItems.map { ($0.title, $0.id) })
        #expect(f.model.allItems.count == 3, "precondition: the launch pass indexed the library")

        _ = try await f.outside.create(makeItem("Syzygy"))
        var edited = try await f.outside.load(try #require(ids["Quintessence"]))
        edited.title = "Quintessential"
        try await Task.sleep(for: .milliseconds(20))   // a distinct mtime on every file system
        _ = try await f.outside.save(edited)
        try FileManager.default.removeItem(at: await f.outside.itemDir(try #require(ids["Rhetoric"])))

        #expect(await f.model.search("Syzygy").isEmpty, "precondition: nothing rescans on its own")

        await f.model.reloadLibrary()

        let titles = Set(f.model.allItems.map(\.title))
        #expect(titles == ["Ptolemy", "Quintessential", "Syzygy"])
        #expect(await f.model.search("Syzygy").count == 1, "the new note is searchable")
        #expect(await f.model.search("Rhetoric").isEmpty, "the deleted note's row is dropped from the index")
        #expect(f.model.statusMessage == "Library reloaded: 1 note added, 1 note changed, 1 note removed.")
        #expect(!f.model.isReloadingLibrary)
    }

    @Test("Reload Library over an unchanged library changes nothing and says so")
    func unchangedLibraryIsANoOp() async throws {
        let f = try await fixture(titles: ["Ptolemy"])
        defer { Task { await cleanUp(f) } }
        let foldersBefore = f.organization.folders.map(\.id)

        await f.model.reloadLibrary()

        #expect(f.model.allItems.map(\.title) == ["Ptolemy"])
        #expect(f.organization.folders.map(\.id) == foldersBefore)
        #expect(f.model.statusMessage == "Library reloaded: no notes changed on disk.")
    }

    @Test("a note missing from only one walk is not dropped: an empty walk prunes nothing")
    func emptyLibraryWalkDropsNothing() async throws {
        let f = try await fixture(titles: ["Ptolemy", "Quintessence"])
        defer { Task { await cleanUp(f) } }
        // The library's items folder vanishes (a volume unmounted, a sync client mid-swap): both walks
        // read empty, which is no evidence that anything was deleted.
        let items = f.root.appendingPathComponent("items", isDirectory: true)
        let parked = f.dir.appendingPathComponent("items-parked", isDirectory: true)
        try FileManager.default.moveItem(at: items, to: parked)

        await f.model.reloadLibrary()

        #expect(await f.index.allIndexedIDs().count == 2, "an empty walk must never empty the index")
        try FileManager.default.moveItem(at: parked, to: items)
    }

    // MARK: - Folders

    @Test("an organization.json edited outside the app is adopted, into the index too")
    func externalMirrorIsAdopted() async throws {
        let f = try await fixture(titles: ["Ptolemy"])
        defer { Task { await cleanUp(f) } }
        let synced = folder("From the other Mac")
        try writeMirrorFromOutside(f, adding: [synced])

        await f.model.reloadLibrary()

        #expect(f.organization.folders.contains { $0.id == synced.id })
        #expect(try await f.index.allFolders().contains { $0.id == synced.id },
                "the index holds the adopted graph, so the next launch shows it too")
        #expect(f.model.statusMessage?.hasSuffix("Folders were reloaded from organization.json.") == true)
        // A folder change after the reload is written on top of the adopted graph, not the old one.
        _ = try await f.organization.createFolder(name: "After")
        await f.organization.flushPendingMirror()
        let file = try #require(OrganizationFile.load(from: f.root))
        #expect(file.folders.contains { $0.id == synced.id } && file.folders.contains { $0.name == "After" })
    }

    @Test("a folder made in the app just before Reload Library is kept, not loaded over")
    func sessionChangeWinsOverOlderFile() async throws {
        let f = try await fixture(titles: ["Ptolemy"])
        defer { Task { await cleanUp(f) } }
        let organization = OrganizationStore(index: f.index, mirrorDebounce: .seconds(60))
        try await organization.load(storeRoot: f.root)
        let made = try await organization.createFolder(name: "Made here")
        #expect(organization.isMirrorWritePending, "precondition: the change has not reached the file yet")

        #expect(try await organization.reloadFromMirrorIfChanged() == .unchanged,
                "the pending write lands first, so the file then matches the graph")
        #expect(organization.folders.contains { $0.id == made.id })
        #expect(try #require(OrganizationFile.load(from: f.root)).folders.contains { $0.id == made.id })
    }

    @Test("an earlier copy put back by a sync service does not undo folders saved this session")
    func olderFileDoesNotUndoSavedFolders() async throws {
        let f = try await fixture(titles: ["Ptolemy"])
        defer { Task { await cleanUp(f) } }
        let earlier = try #require(OrganizationFile.load(from: f.root))
        let earlierDate = try #require(try FileManager.default.attributesOfItem(
            atPath: f.root.appendingPathComponent("organization.json").path)[.modificationDate] as? Date)
        try await Task.sleep(for: .milliseconds(20))
        let made = try await f.organization.createFolder(name: "Saved this session")
        await f.organization.flushPendingMirror()
        // The sync service restores the earlier copy, with its earlier modification date.
        let mirror = f.root.appendingPathComponent("organization.json")
        try OrganizationFile.export(folders: earlier.folders, memberships: earlier.memberships,
                                    assignments: earlier.assignments, to: f.root)
        try FileManager.default.setAttributes([.modificationDate: earlierDate], ofItemAtPath: mirror.path)

        guard case .keptLocal = try await f.organization.reloadFromMirrorIfChanged() else {
            Issue.record("an older file must not be adopted"); return
        }
        #expect(f.organization.folders.contains { $0.id == made.id })
        #expect(try await f.index.allFolders().contains { $0.id == made.id })
        await f.organization.flushPendingMirror()
        #expect(try #require(OrganizationFile.load(from: f.root)).folders.contains { $0.id == made.id },
                "the folders here are written back over the earlier copy")
    }

    @Test("a missing or unreadable organization.json is left alone, never read as an empty graph")
    func unreadableMirrorKeepsTheGraph() async throws {
        let f = try await fixture(titles: ["Ptolemy"])
        defer { Task { await cleanUp(f) } }
        let made = try await f.organization.createFolder(name: "Kept")
        await f.organization.flushPendingMirror()
        let mirror = f.root.appendingPathComponent("organization.json")

        try Data("{ not json".utf8).write(to: mirror)
        #expect(try await f.organization.reloadFromMirrorIfChanged() == .unchanged)
        try FileManager.default.removeItem(at: mirror)
        #expect(try await f.organization.reloadFromMirrorIfChanged() == .unchanged)

        #expect(f.organization.folders.contains { $0.id == made.id })
        #expect(try await f.index.allFolders().contains { $0.id == made.id })
    }

    @Test("a folder repeated in a hand-edited file is adopted once, in memory as in the index")
    func repeatedFolderIsAdoptedOnce() async throws {
        let f = try await fixture(titles: ["Ptolemy"])
        defer { Task { await cleanUp(f) } }
        let twin = folder("Twin")
        var renamed = twin
        renamed.name = "Twin, renamed"
        try writeMirrorFromOutside(f, adding: [twin, renamed])

        #expect(try await f.organization.reloadFromMirrorIfChanged() == .adopted)

        #expect(f.organization.folders.filter { $0.id == twin.id }.map(\.name) == ["Twin, renamed"])
        let indexed = try await f.index.allFolders()
        #expect(indexed.filter { $0.id == twin.id }.map(\.name) == ["Twin, renamed"])
        #expect(Set(indexed.map(\.id)) == Set(f.organization.folders.map(\.id))
                && indexed.count == f.organization.folders.count, "memory holds what the index does")
    }

    @Test("a placement write that starts during the swap waits for it and lands on the adopted graph")
    func placementWaitsForTheSwap() async throws {
        let f = try await fixture(titles: ["Ptolemy"])
        defer { Task { await cleanUp(f) } }
        let item = try #require(f.model.allItems.first).id
        let synced = folder("Synced")
        try writeMirrorFromOutside(f, adding: [synced])

        async let reload = f.organization.reloadFromMirrorIfChanged()
        async let add: Void = f.organization.addMembership(item: item, folder: synced.id)
        #expect(try await reload == .adopted)
        // Either order is sound: the add ran first (folder unknown, so it throws) or after the swap.
        if (try? await add) != nil {
            #expect(f.organization.foldersContaining(item: item).contains(synced.id))
            #expect(try await f.index.allMemberships().contains { $0.itemId == item && $0.folderId == synced.id })
        }
    }

    // MARK: - The status line

    @Test("the summary counts added, changed and removed notes")
    func summaryCounts() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        func summary(_ id: UUID, _ mtime: Double) -> ItemSummary {
            var item = makeItem("x")
            item.id = id
            return ItemSummary(item: item, mtime: mtime)
        }
        let before: [UUID: Double] = [a: 1, b: 1, c: 1]
        let after = [summary(a, 1), summary(b, 2), summary(d, 1)]
        #expect(NotesModel.reloadSummary(before: before, after: after, folderLine: nil)
                == "Library reloaded: 1 note added, 1 note changed, 1 note removed.")
        #expect(NotesModel.reloadSummary(before: before, after: [summary(a, 1), summary(b, 1), summary(c, 1)],
                                         folderLine: "Folders were reloaded from organization.json.")
                == "Library reloaded: no notes changed on disk. Folders were reloaded from organization.json.")
    }
}
