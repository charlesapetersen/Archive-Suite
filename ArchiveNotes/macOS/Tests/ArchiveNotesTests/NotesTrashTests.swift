import Testing
import Foundation
@testable import ArchiveNotes

/// W40.fix-notes-delete-undo (Tier-2 — the delete path). A confirmed delete moves the note into the
/// store's own `Trash/`, recording the folders that held it; Put Back (the Trash view, and Edit ▸ Undo)
/// brings it home, re-indexed and filed again; Empty Trash sends it on to the Finder's Trash. All on a
/// scratch store — never a real corpus (Prime Directive #1).
@Suite("NotesTrash — delete, put back, empty")
@MainActor
struct NotesTrashTests {

    struct Env {
        let nav: NotesNavigationModel
        let model: NotesModel
        let org: OrganizationStore
        let store: NoteStore
        let index: NotesIndex
        let root: URL
    }

    private func makeEnv() async throws -> Env {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-trash-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = NotesIndex(url: root.appendingPathComponent("index.db"))
        try await index.open()
        let org = OrganizationStore(index: index)
        try await org.load(storeRoot: root)
        let store = NoteStore(root: root)
        let model = NotesModel(organization: org, index: index, noteStore: store)
        let nav = NotesNavigationModel(model: model, defaultKind: .note)
        return Env(nav: nav, model: model, org: org, store: store, index: index, root: root)
    }

    private func cleanup(_ env: Env) async {
        await env.index.close()
        try? FileManager.default.removeItem(at: env.root)
    }

    private func makeNote(_ env: Env, _ title: String) async throws -> UUID {
        let item = Item(id: UUID(), kind: .note, title: title, date: nil, datePrecision: nil,
                        dateUncertain: false, quality: nil, tags: [], zotero: [], roundup: false,
                        created: Date(), modified: Date(), schema: 1, blocks: [],
                        unknownFrontMatter: [], trailingBodyRaw: nil)
        let ref = try await env.store.create(item)
        try await env.index.upsertBatch([NoteIndexRow(item: item, mtime: ref.mtime)])
        await env.model.reloadItems()
        return item.id
    }

    private func dir(_ env: Env, _ area: String, _ id: UUID) -> URL {
        env.root.appendingPathComponent(area, isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @Test("a confirmed delete moves the note into the store's Trash, listed with its folders")
    func deleteLandsInStoreTrash() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let a = try await makeNote(env, "Alpha")
        let f1 = try await env.org.createFolder(name: "F1", parent: nil, kind: .normal).id
        let f2 = try await env.org.createFolder(name: "F2", parent: nil, kind: .normal).id
        try await env.org.addMembership(item: a, folder: f1)
        try await env.org.addMembership(item: a, folder: f2)

        let trashed = await env.nav.confirmDeletion(.init(itemId: a, folderId: nil, title: "Alpha", allInstances: true))

        #expect(trashed, "the delete reports the note reached the Trash")
        #expect(!exists(dir(env, "items", a)), "the note left the library")
        #expect(exists(dir(env, "Trash", a)), "it waits in the store's Trash, not gone")
        #expect(!env.model.allItems.contains { $0.id == a })
        let listed = try #require(env.model.trashedNotes.first { $0.id == a })
        #expect(listed.title == "Alpha")
        #expect(Set(listed.formerFolderIds) == [f1, f2])
    }

    @Test("Put Back brings the note home, re-indexed and filed in every folder that held it")
    func putBackRestoresNoteAndPlacements() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let a = try await makeNote(env, "Alpha")
        let f1 = try await env.org.createFolder(name: "F1", parent: nil, kind: .normal).id
        try await env.org.addMembership(item: a, folder: f1)
        try #require(await env.nav.confirmDeletion(.init(itemId: a, folderId: f1, title: "Alpha")))

        let restored = await env.model.putBack([a])

        #expect(restored == [a])
        #expect(exists(dir(env, "items", a)))
        #expect(!exists(dir(env, "Trash", a)))
        #expect(env.model.allItems.contains { $0.id == a }, "listed under All Notes again")
        #expect(env.org.foldersContaining(item: a) == [f1], "filed back in its folder")
        #expect(env.model.trashedNotes.isEmpty)
        #expect(!env.model.noteWasTrashed(a))
        #expect(try await env.store.load(a).title == "Alpha", "the note's content came back intact")
    }

    @Test("a note whose folder was deleted meanwhile is put back under All Notes, and says so")
    func putBackWithFolderGone() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let a = try await makeNote(env, "Alpha")
        let f1 = try await env.org.createFolder(name: "F1", parent: nil, kind: .normal).id
        try await env.org.addMembership(item: a, folder: f1)
        try #require(await env.nav.confirmDeletion(.init(itemId: a, folderId: f1, title: "Alpha")))
        _ = await env.model.deleteFolder(f1)

        #expect(await env.model.putBack([a]) == [a])
        #expect(env.org.foldersContaining(item: a).isEmpty)
        #expect(env.model.allItems.contains { $0.id == a })
        #expect(env.model.statusMessage?.contains("All Notes") == true)
    }

    @Test("Put Back never overwrites a note already home with the same id")
    func putBackRefusesToOverwrite() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let a = try await makeNote(env, "Alpha")
        try #require(await env.nav.confirmDeletion(.init(itemId: a, folderId: nil, title: "Alpha", allInstances: true)))
        // Something put a note of that id back by hand.
        try FileManager.default.createDirectory(at: dir(env, "items", a), withIntermediateDirectories: true)
        let marker = dir(env, "items", a).appendingPathComponent("keep.md")
        try Data("mine".utf8).write(to: marker)

        #expect(await env.model.putBack([a]).isEmpty)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "mine", "the note at home is untouched")
        #expect(exists(dir(env, "Trash", a)), "the trashed copy stays in the Trash")
        #expect(env.model.statusMessage?.contains("still in the Trash") == true)
    }

    @Test("the Trash survives a relaunch: a fresh model lists what an earlier one deleted")
    func trashListedAfterRelaunch() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let a = try await makeNote(env, "Alpha")
        try #require(await env.nav.confirmDeletion(.init(itemId: a, folderId: nil, title: "Alpha", allInstances: true)))
        let fresh = NotesModel(organization: env.org, index: env.index, noteStore: NoteStore(root: env.root))
        await fresh.reloadTrash()
        #expect(fresh.trashedNotes.map(\.id) == [a])
    }

    @Test("a folder delete that takes its sole notes sends them to the Trash too, where Put Back finds them")
    func folderDeleteStrandedGoesToTrash() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let a = try await makeNote(env, "Alpha")
        let f1 = try await env.org.createFolder(name: "F1", parent: nil, kind: .normal).id
        try await env.org.addMembership(item: a, folder: f1)
        await env.model.deleteFolderDeletingStranded(f1, stranded: [a])
        #expect(env.model.trashedNotes.map(\.id) == [a])
        #expect(await env.model.putBack([a]) == [a])
        #expect(env.model.allItems.contains { $0.id == a })
    }

    @Test("a stray home folder with no note in it (a late asset write) does not block Put Back")
    func putBackClearsAssetOnlyStray() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let a = try await makeNote(env, "Alpha")
        try #require(await env.nav.confirmDeletion(.init(itemId: a, folderId: nil, title: "Alpha", allInstances: true)))
        let strayAssets = dir(env, "items", a).appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: strayAssets, withIntermediateDirectories: true)
        try Data([0x89]).write(to: strayAssets.appendingPathComponent("late.png"))

        #expect(await env.model.putBack([a]) == [a])
        #expect(try await env.store.load(a).title == "Alpha", "the real note came home")
        #expect(!exists(dir(env, "Trash", a)))
    }

    @Test("a stale Undo after the note was already put back says nothing and changes nothing")
    func stalePutBackIsQuiet() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let a = try await makeNote(env, "Alpha")
        try #require(await env.nav.confirmDeletion(.init(itemId: a, folderId: nil, title: "Alpha", allInstances: true)))
        #expect(await env.model.putBack([a]) == [a])
        env.model.statusMessage = nil
        #expect(await env.model.putBack([a]).isEmpty)
        #expect(env.model.statusMessage == nil, "no false \"still in the Trash\" message")
        #expect(exists(dir(env, "items", a)))
    }

    @Test("a trashed note that no longer parses is still listed, so it can be put back or emptied")
    func unreadableTrashEntryListed() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let a = try await makeNote(env, "Alpha")
        try #require(await env.nav.confirmDeletion(.init(itemId: a, folderId: nil, title: "Alpha", allInstances: true)))
        let md = try #require(try FileManager.default.contentsOfDirectory(at: dir(env, "Trash", a),
                                                                          includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "md" })
        try Data("not front matter".utf8).write(to: md)
        await env.model.reloadTrash()
        #expect(env.model.trashedNotes.map(\.id) == [a])
        #expect(env.model.trashedNotes.first?.title == "Unreadable note")
    }

    @Test("Empty Trash sends the notes on (to the Finder's Trash) and leaves the store's Trash empty")
    func emptyTrashEmptiesStoreTrash() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let a = try await makeNote(env, "Alpha")
        try #require(await env.nav.confirmDeletion(.init(itemId: a, folderId: nil, title: "Alpha", allInstances: true)))
        #expect(await env.model.emptyTrash().isEmpty)
        #expect(!exists(dir(env, "Trash", a)))
        #expect(!exists(dir(env, "items", a)))
        #expect(env.model.trashedNotes.isEmpty)
    }

    /// W40.fix-notes-delete-redo (notes-2 row 17): Redo after the Undo of a delete moves the note to the Trash
    /// again, with no placement left behind, and the next Undo brings it home once more.
    @Test("Undo puts a deleted note back, Redo deletes it again, and Undo again restores it")
    func undoRedoUndoOfDelete() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let a = try await makeNote(env, "Alpha")
        let f1 = try await env.org.createFolder(name: "F1", parent: nil, kind: .normal).id
        try await env.org.addMembership(item: a, folder: f1)
        let undo = UndoManager()
        undo.groupsByEvent = false
        try #require(await env.nav.confirmDeletion(.init(itemId: a, folderId: f1, title: "Alpha")))
        undo.beginUndoGrouping()
        env.nav.registerUndoOfDelete(a, title: "Alpha", with: undo)
        undo.endUndoGrouping()
        #expect(undo.undoActionName == "Delete Note")

        undo.undo()
        await env.nav.deleteHistorySettled()
        #expect(exists(dir(env, "items", a)), "Undo brought the note home")
        #expect(env.org.foldersContaining(item: a) == [f1])
        #expect(undo.canRedo, "Redo is offered after the Undo")
        #expect(undo.redoActionName == "Delete Note")

        undo.redo()
        await env.nav.deleteHistorySettled()
        #expect(!exists(dir(env, "items", a)), "Redo deleted the note again")
        #expect(exists(dir(env, "Trash", a)), "into the store's Trash, never gone")
        #expect(env.org.foldersContaining(item: a).isEmpty, "with no placement left on a trashed note")
        #expect(!env.model.allItems.contains { $0.id == a })
        #expect(Set(try #require(env.model.trashedNotes.first { $0.id == a }).formerFolderIds) == [f1],
                "the Trash still knows where it came from")
        #expect(undo.canUndo)

        undo.undo()
        await env.nav.deleteHistorySettled()
        #expect(exists(dir(env, "items", a)), "the second Undo brought it home again")
        #expect(env.org.foldersContaining(item: a) == [f1])
        #expect(undo.canRedo)
    }

    @Test("a Redo whose Undo could not bring the note back deletes nothing")
    func redoAfterFailedPutBackDoesNothing() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let a = try await makeNote(env, "Alpha")
        let undo = UndoManager()
        undo.groupsByEvent = false
        try #require(await env.nav.confirmDeletion(.init(itemId: a, folderId: nil, title: "Alpha", allInstances: true)))
        undo.beginUndoGrouping()
        env.nav.registerUndoOfDelete(a, title: "Alpha", with: undo)
        undo.endUndoGrouping()
        // The Trash view put it back first, so the Undo finds nothing to bring home.
        #expect(await env.model.putBack([a]) == [a])

        undo.undo()
        await env.nav.deleteHistorySettled()
        undo.redo()
        await env.nav.deleteHistorySettled()
        #expect(exists(dir(env, "items", a)), "the note the Undo did not restore stays in the library")
        #expect(!exists(dir(env, "Trash", a)))
    }
}
