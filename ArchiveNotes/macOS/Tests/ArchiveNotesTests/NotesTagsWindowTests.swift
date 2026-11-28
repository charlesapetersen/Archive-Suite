import Testing
import Foundation
import Darwin
import ArchiveCore
import ArchiveCoreUI
@testable import ArchiveNotes

/// W40.tag-window-notes (Tier-2 — a front-matter and Finder-mirror write on every note carrying a tag, and a record in
/// the archive). The shared Tags window over Notes: the list is every note's and extract's subjects; Rename, Merge and
/// Remove run through `renameSubjects` with one Undo on the window's undo manager and are recorded for the other apps
/// (a remove as a schema 2 entry with an empty `to`). Scratch stores and scratch archive folders only — never a real
/// store or corpus (Prime Directive #1).
@Suite("Notes — the Tags window")
@MainActor
struct NotesTagsWindowTests {

    struct Env {
        let nav: NotesNavigationModel
        let model: NotesModel
        let store: NoteStore
        let index: NotesIndex
        let root: URL
        let archive: URL
        let suite: String
    }

    private func makeEnv() async throws -> Env {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-tags-window-test-\(UUID().uuidString)", isDirectory: true)
        let archive = root.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let index = NotesIndex(url: root.appendingPathComponent("index.db"))
        try await index.open()
        let org = OrganizationStore(index: index)
        let storeRoot = root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        try await org.load(storeRoot: storeRoot)
        let store = NoteStore(root: storeRoot)
        let model = NotesModel(organization: org, index: index, noteStore: store)
        let guid = UUID()
        model.archiveRoots = { [(guid, archive)] }
        let suite = "NotesTagsWindowTests-\(UUID().uuidString)"
        model.tagChangeDefaultsSuite = suite
        let nav = NotesNavigationModel(model: model, defaultKind: .note)
        return Env(nav: nav, model: model, store: store, index: index, root: root, archive: archive, suite: suite)
    }

    private func cleanup(_ env: Env) async {
        await env.index.close()
        UserDefaults().removePersistentDomain(forName: env.suite)
        try? FileManager.default.removeItem(at: env.root)
    }

    private func makeItem(_ env: Env, _ title: String, kind: Item.Kind = .note, tags: [String]) async throws -> UUID {
        let item = Item(id: UUID(), kind: kind, title: title, date: nil, datePrecision: nil,
                        dateUncertain: false, quality: nil, tags: tags, zotero: [], roundup: false,
                        created: Date(), modified: Date(), schema: 1, blocks: [],
                        unknownFrontMatter: [], trailingBodyRaw: nil)
        let ref = try await env.store.create(item)
        try await env.index.upsertBatch([NoteIndexRow(item: item, mtime: ref.mtime)])
        await env.model.reloadItems()
        return item.id
    }

    private func tags(_ env: Env, _ id: UUID) async throws -> [String] { try await env.store.load(id).tags }

    private func finderTags(_ env: Env, _ id: UUID) async throws -> Set<String> {
        let url = try await env.store.mdURL(for: id)
        return Set(try url.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? [])
    }

    private func log(_ env: Env) -> [TagChange] { TagChangeLog.load(root: env.archive).document?.changes ?? [] }

    /// The window's model over the library as it is now.
    private func window(_ env: Env) -> TagsWindowModel {
        let window = env.model.tagsWindow
        window.update(NotesModel.tagInventory(env.model.allItems.map {
            TagInventory.Item(id: $0.id.uuidString, tags: $0.managedTags)
        }))
        return window
    }

    @Test("the list is every note's and extract's subjects, spellings together, the suite's tokens apart")
    func inventory() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let a = try await makeItem(env, "Alpha", tags: ["Civil Rights", "Labor"])
        let x = try await makeItem(env, "Extract", kind: .extract, tags: ["civil rights"])
        _ = try await makeItem(env, "Rated", tags: ["Q1", "Oil"])
        let w = window(env)
        let civil = try #require(w.inventory.entry(for: "Civil Rights"))
        #expect(Set(civil.itemIDs) == [a.uuidString, x.uuidString], "a note and an extract")
        #expect(civil.hasVariantSpellings, "the hand-edited lower case is another spelling of it")
        #expect(Set(w.rows.map(\.name)) == ["Civil Rights", "Labor", "Oil"])
        #expect(w.suiteTokens.map(\.name) == ["Q1"], "a rating is listed apart and never changed")
        let oil = try #require(w.inventory.entry(for: "Oil"))
        #expect(w.renamePlan(oil, to: "q2") == nil)
        // Notes title-cases what it writes, so the plan's target is spelt that way.
        #expect(w.renamePlan(civil, to: "civil rights movement")?.target == "Civil Rights Movement")
    }

    @Test("Rename writes every spelling on notes and extracts to front matter, recorded; one Undo and Redo")
    func renameUndoRedo() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let a = try await makeItem(env, "Alpha", tags: ["Civil Rights", "Labor"])
        let x = try await makeItem(env, "Extract", kind: .extract, tags: ["civil rights"])
        let undo = UndoManager()
        undo.groupsByEvent = false
        env.model.tagsWindowUndo = { undo }
        let w = window(env)
        let entry = try #require(w.inventory.entry(for: "Civil Rights"))
        let plan = try #require(w.renamePlan(entry, to: "Movement"))
        undo.beginUndoGrouping()
        let outcome = try #require(await w.perform(plan))
        undo.endUndoGrouping()
        #expect(outcome == .init(changed: 2, failed: 0))
        #expect(try await tags(env, a) == ["Movement", "Labor"], "renamed where it stood")
        #expect(try await tags(env, x) == ["Movement"])
        #expect(try await finderTags(env, a).isEmpty)
        #expect(log(env).map { "\($0.app):\($0.from)→\($0.to)" } == ["notes:Civil Rights→Movement"])
        #expect(w.status?.contains("on 2 notes") == true)
        #expect(undo.undoActionName == "Rename Tag")

        undo.undo()
        await env.model.tagsWindowHistorySettled()
        #expect(Set(try await tags(env, a)) == ["Civil Rights", "Labor"])
        let xAfter = try await tags(env, x)
        #expect(xAfter == ["Civil Rights"], "the tag comes back in Notes' spelling: every write title-cases")
        #expect(log(env).map(\.withdrawn) == [true])

        undo.redo()
        await env.model.tagsWindowHistorySettled()
        #expect(Set(try await tags(env, a)) == ["Movement", "Labor"])
        #expect(log(env).map(\.withdrawn) == [false])
    }

    @Test("Merge folds several tags into one spelling; a note carrying two keeps one")
    func merge() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let a = try await makeItem(env, "Alpha", tags: ["Enviroment", "Environment", "Oil"])
        let b = try await makeItem(env, "Beta", tags: ["Enviroment"])
        let w = window(env)
        let entries = ["Enviroment", "Environment"].compactMap { w.inventory.entry(for: $0) }
        let plan = try #require(w.mergePlan(entries, into: "Environment"))
        #expect(plan.kind == .merge)
        _ = try #require(await w.perform(plan))
        #expect(try await tags(env, a) == ["Environment", "Oil"])
        #expect(try await tags(env, b) == ["Environment"])
        #expect(log(env).map(\.from) == ["Enviroment"], "the kept spelling is not recorded as a change")
    }

    @Test("Remove takes the tag off every note, records a schema 2 entry with an empty `to`, and Undo puts it back")
    func remove() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let a = try await makeItem(env, "Alpha", tags: ["Draft", "Labor"])
        let x = try await makeItem(env, "Extract", kind: .extract, tags: ["draft"])
        let undo = UndoManager()
        undo.groupsByEvent = false
        env.model.tagsWindowUndo = { undo }
        let w = window(env)
        let entry = try #require(w.inventory.entry(for: "Draft"))
        let plan = try #require(w.removePlan([entry]))
        undo.beginUndoGrouping()
        #expect(await w.perform(plan) == .init(changed: 2, failed: 0))
        undo.endUndoGrouping()
        #expect(try await tags(env, a) == ["Labor"])
        #expect(try await tags(env, x) == [])
        #expect(!(try await finderTags(env, a).contains("Draft")))
        let recorded = try #require(log(env).first)
        #expect(recorded.isRemoval && recorded.from == "Draft" && recorded.to.isEmpty)
        #expect(TagChangeLog.load(root: env.archive).document?.schemaVersion == 2)
        #expect(undo.undoActionName == "Remove Tag")

        undo.undo()
        await env.model.tagsWindowHistorySettled()
        #expect(Set(try await tags(env, a)) == ["Draft", "Labor"])
        let xAfter = try await tags(env, x)
        #expect(xAfter == ["Draft"], "in Notes' spelling: every write title-cases")
        #expect(log(env).map(\.withdrawn) == [true])
    }

    @Test("Show Notes filters the Archive Notes window to the tag alone, clearing a search that would hide it")
    func showNotes() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        _ = try await makeItem(env, "Alpha", tags: ["Draft"])
        let w = window(env)
        var asked: String?
        w.showItems = { asked = $0.name }
        w.showItems?(try #require(w.inventory.entry(for: "Draft")))
        #expect(asked == "Draft")
        env.nav.filter.searchText = "nothing matches this"
        env.nav.showNotes(withTag: "Draft")
        #expect(env.nav.filter.tags == ["Draft"])
        #expect(env.nav.filter.searchText.isEmpty)
        #expect(env.nav.paneMode == .notes)
    }

    @Test("a plan made before a note took or lost the tag acts on the notes as they are now")
    func freshState() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let a = try await makeItem(env, "Alpha", tags: ["Draft"])
        let b = try await makeItem(env, "Beta", tags: ["Draft", "Oil"])
        let w = window(env)
        let entry = try #require(w.inventory.entry(for: "Draft"))
        let plan = try #require(w.renamePlan(entry, to: "Final"))
        // Since the list was built: Alpha lost the tag, a new note took it.
        #expect(await env.model.removeTag("Draft", from: a))
        let c = try await makeItem(env, "Gamma", tags: ["Draft"])
        let aBefore = try await env.store.load(a).modified
        #expect(await w.perform(plan) == .init(changed: 2, failed: 0))
        #expect(try await tags(env, a) == [])
        #expect(try await env.store.load(a).modified == aBefore, "a note without the tag is not rewritten")
        #expect(try await tags(env, b) == ["Final", "Oil"])
        #expect(try await tags(env, c) == ["Final"])
    }
}
