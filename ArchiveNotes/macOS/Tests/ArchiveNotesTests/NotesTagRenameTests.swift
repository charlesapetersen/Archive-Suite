import Testing
import Foundation
import Darwin
import ArchiveCore
@testable import ArchiveNotes

/// W40.tag-rename-suite (Tier-2 — a front-matter and Finder-mirror write on every note carrying a subject, and a record
/// in the archive). Rename and merge reach every note and extract carrying the subject, front matter first and then the
/// mirror; one Undo puts back only what the rename changed; the change is recorded in each reachable archive's log and
/// withdrawn by Undo; other apps' changes are offered, applied without being recorded again, or skipped. All on scratch
/// stores and scratch archive folders — never a real store or corpus (Prime Directive #1).
@Suite("Notes — rename or merge a tag across the suite")
@MainActor
struct NotesTagRenameTests {

    struct Env {
        let nav: NotesNavigationModel
        let model: NotesModel
        let store: NoteStore
        let index: NotesIndex
        let root: URL
        let archive: URL
        let archiveGUID: UUID
        let suite: String
    }

    private func makeEnv(withArchive: Bool = true) async throws -> Env {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-tag-rename-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
        if withArchive { model.archiveRoots = { [(guid, archive)] } }
        let suite = "NotesTagRenameTests-\(UUID().uuidString)"
        model.tagChangeDefaultsSuite = suite
        let nav = NotesNavigationModel(model: model, defaultKind: .note)
        return Env(nav: nav, model: model, store: store, index: index, root: root, archive: archive,
                   archiveGUID: guid, suite: suite)
    }

    private func cleanup(_ env: Env) async {
        await env.index.close()
        chmod(env.archive.appendingPathComponent(ContainerFile.folderName).path, 0o755)
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

    // MARK: Rename and merge

    @Test("a rename reaches every note and extract carrying the subject, in any case, and nothing else")
    func renameReachesNotesAndExtracts() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let a = try await makeItem(env, "Alpha", tags: ["Civil Rights", "Labor"])
        let x = try await makeItem(env, "Extract", kind: .extract, tags: ["civil rights"])
        let c = try await makeItem(env, "Gamma", tags: ["Oil"])
        let untouched = try await env.store.load(c).modified

        let outcome = try #require(await env.nav.renameSubjects(["Civil Rights"], to: "civil rights movement", undo: nil))
        #expect(outcome.to == "Civil Rights Movement")
        #expect(Set(outcome.changed.keys) == [a, x])
        #expect(try await tags(env, a) == ["Civil Rights Movement", "Labor"], "renamed where it stood")
        #expect(try await tags(env, x) == ["Civil Rights Movement"])
        #expect(try await finderTags(env, a).isEmpty, "Notes does not mirror subjects to Finder tags")
        #expect(try await env.store.load(c).modified == untouched, "a note without the subject is not rewritten")
        #expect(env.model.statusMessage?.contains("on 2 notes") == true)
    }

    @Test("renaming into a subject already in use merges, leaving one of it on a note that had both")
    func renameIntoExistingMerges() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let a = try await makeItem(env, "Alpha", tags: ["Enviroment", "Environment", "Oil"])
        let b = try await makeItem(env, "Beta", tags: ["Enviroment"])
        _ = try await makeItem(env, "Gamma", tags: ["Environment"])
        #expect(env.model.subjectSpelling(for: "environment") == "Environment")
        _ = try #require(await env.nav.renameSubjects(["Enviroment"], to: "environment", undo: nil))
        #expect(try await tags(env, a) == ["Environment", "Oil"])
        #expect(try await tags(env, b) == ["Environment"])
        #expect(env.model.subjectCounts["Environment"] == 3)
        #expect(env.model.subjectCounts["Enviroment"] == nil)
    }

    @Test("facet tokens and an unknown subject are not renamed")
    func refusesFacetsAndNothing() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        _ = try await makeItem(env, "Alpha", tags: ["Labor"])
        #expect(await env.nav.renameSubjects(["Nobody"], to: "Somebody", undo: nil) == nil)
        #expect(await env.nav.renameSubjects(["Labor"], to: "Q1", undo: nil) == nil)
        #expect(await env.nav.renameSubjects(["Q1"], to: "Labor", undo: nil) == nil)
        #expect(log(env).isEmpty)
    }

    // MARK: Undo and Redo

    @Test("one Undo puts back only what the rename changed, keeping a later edit; Redo renames again")
    func undoAndRedo() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let a = try await makeItem(env, "Alpha", tags: ["Draft", "Labor"])
        let b = try await makeItem(env, "Beta", tags: ["Draft", "Final"])
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        let outcome = try #require(await env.nav.renameSubjects(["Draft"], to: "Final", undo: undo))
        undo.endUndoGrouping()
        #expect(undo.undoActionName == "Rename Tag")
        #expect(try await tags(env, b) == ["Final"])
        // An edit made since, to another subject, survives the Undo.
        #expect(await env.model.addTag("Oil", to: a))

        undo.undo()
        await env.nav.deleteHistorySettled()
        #expect(Set(try await tags(env, a)) == ["Draft", "Labor", "Oil"])
        #expect(Set(try await tags(env, b)) == ["Draft", "Final"], "Final was already there, so it stays")
        #expect(try await finderTags(env, a).isEmpty)
        #expect(log(env).map(\.withdrawn) == [true])
        #expect(log(env).first?.id == outcome.recorded.first)

        #expect(undo.canRedo)
        undo.redo()
        await env.nav.deleteHistorySettled()
        #expect(Set(try await tags(env, a)) == ["Final", "Labor", "Oil"])
        #expect(try await tags(env, b) == ["Final"])
        #expect(log(env).map(\.withdrawn) == [false], "Redo clears the withdrawal, and records nothing new")

        undo.undo()
        await env.nav.deleteHistorySettled()
        #expect(Set(try await tags(env, a)) == ["Draft", "Labor", "Oil"], "the Redo's own Undo works too")
        #expect(log(env).map(\.withdrawn) == [true])
    }

    // MARK: Recording for the other apps

    @Test("a rename is recorded in the archive's change log, one entry per subject merged")
    func recordsInTheArchive() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        _ = try await makeItem(env, "Alpha", tags: ["Draft"])
        _ = try await makeItem(env, "Beta", tags: ["Drafts"])
        let outcome = try #require(await env.model.renameSubjects(["Draft", "Drafts"], to: "Draft Copy"))
        let entries = log(env)
        #expect(entries.map(\.from) == ["Draft", "Drafts"])
        #expect(entries.allSatisfy { $0.to == "Draft Copy" && $0.app == TagChangeLog.notes && !$0.withdrawn })
        #expect(Set(outcome.recorded) == Set(entries.map(\.id)))
        #expect(outcome.notRecorded == nil)
        // Nothing else in the archive.
        #expect(try FileManager.default.contentsOfDirectory(atPath: env.archive.path) == [ContainerFile.folderName])
    }

    @Test("a read-only archive does not stop the rename; the status says the other apps were not told")
    func readOnlyArchive() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let a = try await makeItem(env, "Alpha", tags: ["Draft"])
        let suite = env.archive.appendingPathComponent(ContainerFile.folderName)
        try FileManager.default.createDirectory(at: suite, withIntermediateDirectories: false)
        #expect(chmod(suite.path, 0o555) == 0)
        let outcome = try #require(await env.model.renameSubjects(["Draft"], to: "Final"))
        #expect(try await tags(env, a) == ["Final"])
        #expect(outcome.notRecorded?.contains("read-only") == true)
        #expect(env.model.statusMessage?.contains("The other apps were not told") == true)
    }

    @Test("with no archive granted the rename is made and nothing is written anywhere else")
    func noArchive() async throws {
        let env = try await makeEnv(withArchive: false); defer { Task { await cleanup(env) } }
        let a = try await makeItem(env, "Alpha", tags: ["Draft"])
        let outcome = try #require(await env.model.renameSubjects(["Draft"], to: "Final"))
        #expect(try await tags(env, a) == ["Final"])
        #expect(outcome.recorded.isEmpty && outcome.notRecorded == nil)
        #expect(TagChangeLog.load(root: env.archive) == .missing)
    }

    // MARK: Other apps' changes

    @Test("the Reader's rename is offered with its count, applied without being recorded again, and not asked twice")
    func appliesAReaderChange() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let a = try await makeItem(env, "Alpha", tags: ["civil rights"])
        let reader = TagChange(app: TagChangeLog.reader, from: "Civil Rights", to: "Civil Rights Movement")
        let elsewhere = TagChange(app: TagChangeLog.reader, from: "Nobody Has This", to: "Anything")
        try TagChangeLog.record([reader, elsewhere], root: env.archive)

        await env.model.refreshTagChangeInbox()
        let offer = try #require(env.model.tagChangeOffers.first)
        #expect(env.model.tagChangeOffers.count == 1, "an entry no note carries is settled without asking")
        #expect(offer.id == reader.id && offer.count == 1 && !offer.isWithdrawal)
        #expect(offer.summary.hasPrefix("The Reader renamed “Civil Rights” to “Civil Rights Movement”"))

        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        _ = try #require(await env.nav.applyTagChange(offer, undo: undo))
        undo.endUndoGrouping()
        #expect(try await tags(env, a) == ["Civil Rights Movement"])
        #expect(log(env).count == 2, "applying it records nothing new")
        #expect(env.model.tagChangeOffers.isEmpty)
        await env.model.refreshTagChangeInbox()
        #expect(env.model.tagChangeOffers.isEmpty, "handled, so not offered again")

        // The Reader undoes it: Notes says so once and changes nothing.
        try TagChangeLog.setWithdrawn([reader.id], true, root: env.archive)
        await env.model.refreshTagChangeInbox()
        let notice = try #require(env.model.tagChangeOffers.first)
        #expect(notice.isWithdrawal)
        #expect(notice.summary.contains("undid"))
        env.model.dismissTagChange(notice)
        await env.model.refreshTagChangeInbox()
        #expect(env.model.tagChangeOffers.isEmpty)
        #expect(try await tags(env, a) == ["Civil Rights Movement"], "never reverted behind the user's back")
    }

    @Test("another app's remove (schema 2) is offered, takes the subject off every note, and Undo and Redo work")
    func removeFromAnotherAppAppliesWithUndo() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let a = try await makeItem(env, "Alpha", tags: ["Draft", "Labor"])
        let b = try await makeItem(env, "Beta", kind: .extract, tags: ["draft"])
        let c = try await makeItem(env, "Gamma", tags: ["Final"])
        let removal = TagChange(app: TagChangeLog.reader, from: "Draft", to: "")
        try TagChangeLog.record([removal], root: env.archive)
        await env.model.refreshTagChangeInbox()
        let offer = try #require(env.model.tagChangeOffers.first)
        #expect(offer.count == 2 && !offer.isWithdrawal)
        #expect(offer.summary.hasPrefix("The Reader removed “Draft” from its items"))

        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        let outcome = try #require(await env.nav.applyTagChange(offer, undo: undo))
        undo.endUndoGrouping()
        #expect(outcome.isRemoval && undo.undoActionName == "Remove Tag")
        #expect(try await tags(env, a) == ["Labor"])
        #expect(try await tags(env, b) == [])
        #expect(try await tags(env, c) == ["Final"])
        #expect(try await !finderTags(env, a).contains("Draft"))
        #expect(log(env).count == 1, "applying it records nothing new")
        await env.model.refreshTagChangeInbox()
        #expect(env.model.tagChangeOffers.isEmpty)

        undo.undo()
        await env.nav.deleteHistorySettled()
        #expect(Set(try await tags(env, a)) == ["Draft", "Labor"])
        #expect(try await tags(env, b) == ["Draft"], "put back in Notes' spelling")
        undo.redo()
        await env.nav.deleteHistorySettled()
        #expect(try await tags(env, a) == ["Labor"])
        #expect(try await tags(env, b) == [])

        // The Reader undoes its remove: told once, nothing changes.
        try TagChangeLog.setWithdrawn([removal.id], true, root: env.archive)
        await env.model.refreshTagChangeInbox()
        let notice = try #require(env.model.tagChangeOffers.first)
        #expect(notice.isWithdrawal && notice.summary.contains("undid removing"))
    }

    @Test("Skip leaves the notes alone and is not asked again; a change withdrawn before it was applied is dropped")
    func skipAndWithdrawnBeforeApplying() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let a = try await makeItem(env, "Alpha", tags: ["Draft", "Labor"])
        let skip = TagChange(app: TagChangeLog.reader, from: "Draft", to: "Final")
        var gone = TagChange(app: TagChangeLog.reader, from: "Labor", to: "Work")
        gone.withdrawn = true
        try TagChangeLog.record([skip, gone], root: env.archive)
        await env.model.refreshTagChangeInbox()
        #expect(env.model.tagChangeOffers.map(\.id) == [skip.id])
        env.model.dismissTagChange(try #require(env.model.tagChangeOffers.first))
        await env.model.refreshTagChangeInbox()
        #expect(env.model.tagChangeOffers.isEmpty)
        #expect(try await tags(env, a) == ["Draft", "Labor"])
    }

    @Test("a change nothing carries yet, or withdrawn, is passed over, and offered once a note carries it or it is redone")
    func passedOverThenOffered() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let a = try await makeItem(env, "Alpha", tags: ["Labor"])
        let later = TagChange(app: TagChangeLog.reader, from: "Draft", to: "Final")
        var undone = TagChange(app: TagChangeLog.reader, from: "Labor", to: "Work")
        undone.withdrawn = true
        try TagChangeLog.record([later, undone], root: env.archive)
        await env.model.refreshTagChangeInbox()
        #expect(env.model.tagChangeOffers.isEmpty)

        #expect(await env.model.addTag("Draft", to: a))
        try TagChangeLog.setWithdrawn([undone.id], false, root: env.archive)   // the Reader's Redo
        await env.model.refreshTagChangeInbox()
        #expect(Set(env.model.tagChangeOffers.map(\.id)) == [later.id, undone.id])
    }

    @Test("each library keeps its own list: a change skipped in one is still offered in another")
    func listsPerLibrary() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        _ = try await makeItem(env, "Alpha", tags: ["Draft"])
        try TagChangeLog.record([TagChange(app: TagChangeLog.reader, from: "Draft", to: "Final")], root: env.archive)
        env.model.tagChangeLibraryKey = "library-one"
        await env.model.refreshTagChangeInbox()
        env.model.dismissTagChange(try #require(env.model.tagChangeOffers.first))
        await env.model.refreshTagChangeInbox()
        #expect(env.model.tagChangeOffers.isEmpty)
        env.model.tagChangeLibraryKey = "library-two"
        await env.model.refreshTagChangeInbox()
        #expect(env.model.tagChangeOffers.count == 1)
    }

    @Test("Notes' own entries are never offered back to it")
    func ownEntriesNotOffered() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        _ = try await makeItem(env, "Alpha", tags: ["Draft"])
        _ = try await makeItem(env, "Beta", tags: ["Labor"])
        _ = try #require(await env.model.renameSubjects(["Draft"], to: "Labor"))
        await env.model.refreshTagChangeInbox()
        #expect(env.model.tagChangeOffers.isEmpty)
    }

    @Test("the rename keeps each note's other subjects in place and puts the new one where the old stood")
    func renamedOrder() {
        let keys: Set<String> = [tagKey("Draft")]
        #expect(NotesModel.renamed(["Labor", "Draft", "Oil"], from: keys, to: "Final", targetKey: tagKey("Final"))
                == ["Labor", "Final", "Oil"])
        #expect(NotesModel.renamed(["Final", "Draft"], from: keys, to: "Final", targetKey: tagKey("Final")) == ["Final"])
        #expect(NotesModel.renamed(["Oil"], from: keys, to: "Final", targetKey: tagKey("Final")) == ["Oil"])
    }
}
