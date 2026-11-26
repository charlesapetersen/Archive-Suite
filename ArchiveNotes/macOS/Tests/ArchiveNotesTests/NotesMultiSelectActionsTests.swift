import Testing
import Foundation
@testable import ArchiveNotes

/// W49.notes-multiselect-actions (Tier-2 — the delete path, front-matter and tag-projection writes). Several selected
/// notes are deleted after ONE prompt, through the same guarded delete as one note's (every placement removed inside
/// the hard-delete window, then the store's own Trash), and one Undo puts them all back; Set Quality and Add/Remove
/// Tag reach every selected note through each note's own atomic save and Finder mirror. All on a scratch store —
/// never a real corpus (Prime Directive #1).
@Suite("Notes multi-selection — bulk delete, quality and tags")
@MainActor
struct NotesMultiSelectActionsTests {

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
            .appendingPathComponent("notes-multiselect-test-\(UUID().uuidString)", isDirectory: true)
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
        env.model.hardDeleteWindowHookForTesting = nil
        await env.index.close()
        try? FileManager.default.removeItem(at: env.root)
    }

    private func makeNote(_ env: Env, _ title: String, quality: Int? = nil, tags: [String] = []) async throws -> UUID {
        let item = Item(id: UUID(), kind: .note, title: title, date: nil, datePrecision: nil,
                        dateUncertain: false, quality: quality, tags: tags, zotero: [], roundup: false,
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

    private func finderTags(_ env: Env, _ id: UUID) async throws -> Set<String> {
        let url = try await env.store.mdURL(for: id)
        return Set(try url.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? [])
    }

    // MARK: Delete

    @Test("several selected notes ask once, and the confirm sends every one to the store's Trash with its folders")
    func bulkDeleteAsksOnceAndTrashesAll() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let a = try await makeNote(env, "Alpha")
        let b = try await makeNote(env, "Beta")
        let c = try await makeNote(env, "Gamma")
        let f1 = try await env.org.createFolder(name: "F1", parent: nil, kind: .normal).id
        let f2 = try await env.org.createFolder(name: "F2", parent: nil, kind: .normal).id
        try await env.org.addMembership(item: a, folder: f1)
        try await env.org.addMembership(item: b, folder: f1)
        try await env.org.addMembership(item: b, folder: f2)

        env.nav.requestDeleteItems([a, b, c, a])
        let pending = try #require(env.nav.pendingDeletion)
        #expect(pending.isBatch && pending.allInstances)
        #expect(pending.itemIds == [a, b, c], "each note once, in the order asked")
        #expect(exists(dir(env, "items", a)), "nothing changes before the confirm")

        let trashed = await env.nav.confirmPendingDeletionTrashing(pending)

        #expect(Set(trashed) == [a, b, c])
        for id in [a, b, c] {
            #expect(!exists(dir(env, "items", id)) && exists(dir(env, "Trash", id)), "in the store's Trash, not gone")
            #expect(env.org.foldersContaining(item: id).isEmpty, "no placement left on a trashed note")
        }
        #expect(Set(try #require(env.model.trashedNotes.first { $0.id == b }).formerFolderIds) == [f1, f2])
        #expect(Set(try #require(env.model.trashedNotes.first { $0.id == a }).formerFolderIds) == [f1])
        #expect(env.nav.pendingDeletion == nil, "ONE prompt for them all: no second one follows")
    }

    @Test("one selected note still asks by its title")
    func singleSelectionKeepsItsPrompt() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let a = try await makeNote(env, "Alpha")
        env.nav.requestDeleteItems([a])
        let pending = try #require(env.nav.pendingDeletion)
        #expect(!pending.isBatch && pending.allInstances)
        #expect(pending.title == "Alpha")
        env.nav.cancelPendingDeletion(pending)
        env.nav.requestDeleteItems([])
        #expect(env.nav.pendingDeletion == nil, "an empty selection stages nothing")
    }

    @Test("Cancel on the one prompt keeps every selected note")
    func bulkCancelKeepsAll() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let a = try await makeNote(env, "Alpha")
        let b = try await makeNote(env, "Beta")
        env.nav.requestDeleteItems([a, b])
        env.nav.cancelPendingDeletion(env.nav.pendingDeletion)
        #expect(env.nav.pendingDeletion == nil)
        #expect(exists(dir(env, "items", a)) && exists(dir(env, "items", b)))
    }

    @Test("every selected note is inside the hard-delete window: a drag into a folder cannot follow one to the Trash")
    func bulkDeleteHoldsWindowForEveryNote() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let a = try await makeNote(env, "Alpha")
        let c = try await makeNote(env, "Gamma")
        let f2 = try await env.org.createFolder(name: "F2", parent: nil, kind: .normal).id
        var windowWasOpen = false
        env.model.hardDeleteWindowHookForTesting = { @MainActor in
            windowWasOpen = env.org.isHardDeleting(a) && env.org.isHardDeleting(c)
            await env.nav.replicate([c], to: f2)
        }
        env.nav.requestDeleteItems([a, c])
        let trashed = await env.nav.confirmPendingDeletionTrashing(try #require(env.nav.pendingDeletion))

        #expect(windowWasOpen, "non-vacuity: the drag really ran inside the window, which covered both notes")
        #expect(Set(trashed) == [a, c])
        #expect(env.org.foldersContaining(item: c).isEmpty, "NO membership may point at a trashed note")
        #expect(!env.org.isHardDeleting(a) && !env.org.isHardDeleting(c), "the window closes afterwards")
    }

    @Test("one Undo puts every note of a bulk delete back in its folders; Redo deletes them all again")
    func bulkUndoRedo() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let a = try await makeNote(env, "Alpha")
        let b = try await makeNote(env, "Beta")
        let f1 = try await env.org.createFolder(name: "F1", parent: nil, kind: .normal).id
        try await env.org.addMembership(item: a, folder: f1)
        let undo = UndoManager()
        undo.groupsByEvent = false
        env.nav.requestDeleteItems([a, b])
        let trashed = await env.nav.confirmPendingDeletionTrashing(try #require(env.nav.pendingDeletion))
        undo.beginUndoGrouping()
        env.nav.registerUndoOfDelete(trashed, title: "2 notes", with: undo)
        undo.endUndoGrouping()
        #expect(undo.undoActionName == "Delete 2 Notes")

        undo.undo()
        await env.nav.deleteHistorySettled()
        #expect(exists(dir(env, "items", a)) && exists(dir(env, "items", b)), "one Undo brought both home")
        #expect(env.org.foldersContaining(item: a) == [f1], "filed again where it was")
        #expect(undo.redoActionName == "Delete 2 Notes")

        undo.redo()
        await env.nav.deleteHistorySettled()
        #expect(!exists(dir(env, "items", a)) && !exists(dir(env, "items", b)), "Redo deleted both again")
        #expect(exists(dir(env, "Trash", a)) && exists(dir(env, "Trash", b)))
        #expect(env.org.foldersContaining(item: a).isEmpty)
    }

    @Test("⌘⌫'s target is every selected row, in list order, and nothing outside the note list")
    func deletableSelectionIsTheSelectedRows() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let a = try await makeNote(env, "Alpha")
        let b = try await makeNote(env, "Beta")
        env.nav.selection = [a, b]
        await env.nav.waitForPendingRecompute()
        #expect(Set(env.nav.deletableSelection) == [a, b])
        #expect(env.nav.deletableSelection == env.nav.displayed.map(\.id).filter { [a, b].contains($0) })
        env.nav.paneMode = .trash
        #expect(env.nav.deletableSelection.isEmpty)
    }

    // MARK: Quality and tags

    @Test("Set Quality on several notes writes each note's front matter and exactly its Q tag")
    func bulkSetQuality() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let a = try await makeNote(env, "Alpha", quality: 1)
        let b = try await makeNote(env, "Beta")
        await env.nav.setQuality(3, for: [a, b])
        for id in [a, b] {
            #expect(try await env.store.load(id).quality == 3)
            #expect(try await finderTags(env, id).contains("Q3"))
            #expect(!(try await finderTags(env, id).contains("Q1")))
        }
        await env.nav.setQuality(nil, for: [a, b])
        for id in [a, b] {
            #expect(try await env.store.load(id).quality == nil)
            #expect(try await finderTags(env, id).isDisjoint(with: ["Q1", "Q2", "Q3"]))
        }
    }

    @Test("Add Tag reaches every selected note, keeping each note's own tags; Remove takes it off only where it is")
    func bulkAddRemoveTag() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let a = try await makeNote(env, "Alpha", tags: ["Labor"])
        let b = try await makeNote(env, "Beta")
        let c = try await makeNote(env, "Gamma", tags: ["Oil"])
        let failedAdd = await env.nav.addTag("intel", to: [a, b])
        #expect(failedAdd.isEmpty)
        #expect(Set(try await env.store.load(a).tags) == ["Labor", "Intel"])
        #expect(try await env.store.load(b).tags == ["Intel"])
        #expect(try await finderTags(env, a).isSuperset(of: ["Labor", "Intel"]))
        #expect(try await finderTags(env, b).contains("Intel"))

        let untouched = try await env.store.load(c).modified
        let failedRemove = await env.nav.removeTag("Intel", from: [a, b, c])
        #expect(failedRemove.isEmpty)
        #expect(try await env.store.load(a).tags == ["Labor"])
        #expect(try await env.store.load(b).tags.isEmpty)
        #expect(!(try await finderTags(env, a).contains("Intel")))
        #expect(try await env.store.load(c).modified == untouched, "a note without the tag is not rewritten")
        #expect(try await env.store.load(c).tags == ["Oil"])
    }

    @Test("the bulk tag list counts each tag once per note across spellings, the shared ones first")
    func bulkTagsCounting() {
        func summary(_ tags: [String]) -> ItemSummary {
            ItemSummary(id: UUID(), title: "", kind: .note, date: nil, datePrecision: nil, dateUncertain: false,
                        sortDate: nil, quality: nil, created: Date(), modified: Date(), mtime: 0, managedTags: tags)
        }
        let entries = NoteBulkTags.tags(in: [summary(["intel", "Oil"]), summary(["Intel", "intel"]), summary(["Labor"])])
        #expect(entries == [.init(tag: "Intel", count: 2), .init(tag: "Labor", count: 1), .init(tag: "Oil", count: 1)])
    }
}
