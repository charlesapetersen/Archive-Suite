import Testing
import Foundation
@testable import ArchiveNotes

/// W23.m12 — a move-to-Trash the disk REFUSES must leave the note both on disk and *discoverable*.
///
/// `NotesModel.trashItems` used to log each `NoteStore.delete` failure and then drop **every**
/// requested id from `NotesIndex`. All Notes is served from that index (`reloadItems` →
/// `NotesIndex.allSummaries`), nothing watches the store, and the full disk rebuild only runs at
/// bootstrap — so a note that was never actually trashed vanished from the list for the rest of the
/// run while sitting safe on disk, with no way to find it again. That contradicted the invariant both
/// call sites document in their own comments.
///
/// Everything here is **scratch only**: a `temporaryDirectory` store + an index in a sibling
/// directory. No test touches the real notes store, and none writes outside its own fixture.
///
/// ## Fault injection
///
/// The refusal is real, not mocked: the item directory is flagged **`UF_IMMUTABLE`**
/// (`FileAttributeKey.immutable`), which is per-item — so one note in a batch can be refused while its
/// sibling trashes normally, which is exactly the case the old code lost. `trashItem` then fails with
/// NSCocoaError 513 and leaves the directory in place, the finding's literal scenario (a locked entry,
/// a read-only or full volume, a permissions change under a synced store root).
/// The flag is always cleared in a `defer` — otherwise the fixture itself could not be removed.
@MainActor
struct NotesTrashFailureTests {

    // MARK: - Fixture

    private struct Env {
        let model: NotesModel
        let store: NoteStore
        let index: NotesIndex
        let root: URL
        let scratch: URL
    }

    /// A live model over a scratch store + a real index, wired the way the app wires them (real
    /// `NoteStore`, real `NotesIndex`, real `NotesIndexer`) so the item list really is index-served.
    /// The index deliberately lives OUTSIDE the store root: a fixture that makes the store unwritable
    /// must break the trash and nothing else.
    private func makeEnv() async throws -> Env {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-trash-test-\(UUID().uuidString)")
        let dbDir = scratch.appendingPathComponent("db")
        let root = scratch.appendingPathComponent("store")
        for dir in [dbDir, root] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let index = NotesIndex(url: dbDir.appendingPathComponent("index.db"))
        try await index.open()
        let organization = OrganizationStore(index: index)
        try await organization.load(storeRoot: root)
        let store = NoteStore(root: root)
        let model = NotesModel(organization: organization, index: index, noteStore: store,
                               indexer: NotesIndexer(index: index))
        return Env(model: model, store: store, index: index, root: root, scratch: scratch)
    }

    private func cleanup(_ env: Env) async {
        await env.index.close()
        try? FileManager.default.removeItem(at: env.scratch)
    }

    /// Write a real note to the scratch store and return its id.
    private func addNote(_ title: String, to env: Env) async throws -> UUID {
        let item = Item(id: UUID(), kind: .note, title: title, authors: [], date: "1980",
                        datePrecision: .year, dateUncertain: false, quality: nil, tags: [],
                        zotero: [], roundup: false, created: Date(), modified: Date(), schema: 1,
                        blocks: [], unknownFrontMatter: [], trailingBodyRaw: nil)
        _ = try await env.store.create(item)
        return item.id
    }

    /// Index every note on disk and refresh the shared item list — the app's own bootstrap path.
    private func indexFromDisk(_ env: Env) async {
        await env.model.buildIndexFromDisk()
    }

    private func itemDir(_ id: UUID, in env: Env) -> URL {
        env.root.appendingPathComponent("items", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    private func setImmutable(_ id: UUID, _ on: Bool, in env: Env) {
        try? FileManager.default.setAttributes([.immutable: on],
                                               ofItemAtPath: itemDir(id, in: env).path)
    }

    private func isListed(_ id: UUID, in env: Env) -> Bool {
        env.model.allItems.contains { $0.id == id }
    }

    private func existsOnDisk(_ id: UUID, in env: Env) -> Bool {
        FileManager.default.fileExists(atPath: itemDir(id, in: env).path)
    }

    // MARK: - The fixture is honest (a refusal really is a refusal)

    @Test("the immutable flag really does refuse a trash and leave the directory behind")
    func immutableFlagRefusesTheTrash() async throws {
        let env = try await makeEnv()
        defer { Task { await cleanup(env) } }
        let id = try await addNote("Locked", to: env)
        defer { setImmutable(id, false, in: env) }

        setImmutable(id, true, in: env)
        await #expect(throws: (any Error).self) { try await env.store.delete(id) }
        #expect(existsOnDisk(id, in: env), "the finding's premise: the note is still on disk")
        #expect(await env.store.itemExists(id), "the store must report the ground truth")
    }

    // MARK: - The healthy path is unchanged

    @Test("a successful trash removes the note from disk AND from All Notes, silently")
    func healthyTrashRemovesTheNoteEverywhere() async throws {
        let env = try await makeEnv()
        defer { Task { await cleanup(env) } }
        let doomed = try await addNote("Doomed", to: env)
        let keeper = try await addNote("Keeper", to: env)
        await indexFromDisk(env)
        #expect(isListed(doomed, in: env) && isListed(keeper, in: env), "both start out listed")

        let survivors = await env.model.trashItems([doomed])

        #expect(survivors.isEmpty)
        #expect(existsOnDisk(doomed, in: env) == false, "the note really went to the Trash")
        #expect(isListed(doomed, in: env) == false, "and its row went with it")
        #expect(isListed(keeper, in: env), "an untouched note is unaffected")
        #expect(env.model.statusMessage == nil, "a working delete must not raise a false warning")
        #expect(await env.store.itemExists(doomed) == false)
    }

    // MARK: - The finding

    @Test("a REFUSED trash leaves the note listed under All Notes (the finding)")
    func refusedTrashKeepsTheNoteInAllNotes() async throws {
        let env = try await makeEnv()
        defer { Task { await cleanup(env) } }
        let refused = try await addNote("Refused", to: env)
        let trashed = try await addNote("Trashed", to: env)
        await indexFromDisk(env)
        defer { setImmutable(refused, false, in: env) }
        setImmutable(refused, true, in: env)

        // One batch, mixed outcome — the case the old code got exactly backwards.
        let survivors = await env.model.trashItems([refused, trashed])

        #expect(survivors == [refused], "the caller is told which note survived")
        #expect(existsOnDisk(refused, in: env), "still on disk")
        #expect(isListed(refused, in: env),
                "AND still findable: this is the bug — the row used to go anyway")
        #expect(existsOnDisk(trashed, in: env) == false, "its sibling still went to the Trash")
        #expect(isListed(trashed, in: env) == false, "so that row is correctly gone")
        #expect(env.model.statusMessage?.contains("Couldn't move 1 note to the Trash") == true,
                "the operator is told, not just the log: \(env.model.statusMessage ?? "nil")")
        #expect(env.model.statusMessage?.contains("All Notes") == true,
                "and told WHERE the note still is")
    }

    @Test("every refused note in a batch survives, and the message counts them")
    func wholeRefusedBatchSurvives() async throws {
        let env = try await makeEnv()
        defer { Task { await cleanup(env) } }
        let a = try await addNote("A", to: env)
        let b = try await addNote("B", to: env)
        await indexFromDisk(env)
        defer { setImmutable(a, false, in: env); setImmutable(b, false, in: env) }
        setImmutable(a, true, in: env); setImmutable(b, true, in: env)

        let survivors = await env.model.trashItems([a, b])

        #expect(Set(survivors) == Set([a, b]))
        #expect(isListed(a, in: env) && isListed(b, in: env), "neither note may be lost from the list")
        #expect(env.model.statusMessage?.contains("2 notes") == true,
                "plural, and counted: \(env.model.statusMessage ?? "nil")")
        #expect(env.model.statusMessage?.contains("they are") == true)
    }

    /// The over-correction guard. `NoteStore.delete` ALSO throws when the directory is already gone
    /// (`StoreError.notFound` — the other window got there first, or the operator emptied it by hand).
    /// Keeping that row "because the delete threw" would leave a phantom note in All Notes that opens
    /// on nothing, so the row must go whenever the note is absent — whatever the reason.
    @Test("an ALREADY-ABSENT note loses its row instead of becoming a phantom")
    func alreadyAbsentNoteLosesItsRow() async throws {
        let env = try await makeEnv()
        defer { Task { await cleanup(env) } }
        let vanished = try await addNote("Vanished", to: env)
        await indexFromDisk(env)
        #expect(isListed(vanished, in: env))
        // Out-of-band disappearance, inside our own scratch fixture only.
        try FileManager.default.removeItem(at: itemDir(vanished, in: env))

        let survivors = await env.model.trashItems([vanished])

        #expect(survivors.isEmpty, "nothing survived — there was nothing there")
        #expect(isListed(vanished, in: env) == false,
                "the row must go, or All Notes offers a note that cannot be opened")
        #expect(env.model.statusMessage == nil,
                "and no warning: the requested end state was reached")
    }

    /// Same seam, opposite direction: the files went to the Trash but their rows outlived them, so the
    /// list still offers notes that no longer exist. That used to be a bare `try?`.
    @Test("a failed index write is reported instead of swallowed")
    func failedIndexWriteIsReported() async throws {
        let env = try await makeEnv()
        defer { Task { await cleanup(env) } }
        let doomed = try await addNote("Doomed", to: env)
        await indexFromDisk(env)
        await env.index.close()        // every later index write now fails (SQLITE_MISUSE)

        let survivors = await env.model.trashItems([doomed])

        #expect(survivors.isEmpty, "the FILE was trashed — this is not a survivor")
        #expect(existsOnDisk(doomed, in: env) == false)
        #expect(env.model.statusMessage?.contains("note list couldn't be updated") == true,
                "a half-done delete must not read as a clean one: \(env.model.statusMessage ?? "nil")")
    }

    // MARK: - Through the real caller (the folder-delete path's own documented invariant)

    @Test("deleteFolderDeletingStranded leaves a refused note findable under All Notes")
    func folderDeletePathKeepsARefusedNoteFindable() async throws {
        let env = try await makeEnv()
        defer { Task { await cleanup(env) } }
        let stranded = try await addNote("Sole instance", to: env)
        await indexFromDisk(env)
        let folder = try await env.model.organization.createFolder(name: "Ledgers")
        try await env.model.organization.addMembership(item: stranded, folder: folder.id)
        #expect(env.model.strandedByDeletingFolder(folder.id) == [stranded],
                "the confirmation modal would offer exactly this note")
        defer { setImmutable(stranded, false, in: env) }
        setImmutable(stranded, true, in: env)

        await env.model.deleteFolderDeletingStranded(folder.id, stranded: [stranded])

        #expect(env.model.organization.folders.contains { $0.id == folder.id } == false,
                "the folder itself is gone — the membership removal committed")
        #expect(env.model.organization.membershipCount(item: stranded) == 0)
        #expect(existsOnDisk(stranded, in: env), "the note the disk refused is still on disk")
        #expect(isListed(stranded, in: env),
                "…and still under All Notes, which is what this method's comment promises")
        #expect(env.model.statusMessage?.contains("Couldn't move") == true)
    }

    @Test("confirmDeletion (the single-note path) also keeps a refused note findable")
    func confirmDeletionKeepsARefusedNoteFindable() async throws {
        let env = try await makeEnv()
        defer { Task { await cleanup(env) } }
        let note = try await addNote("Only copy", to: env)
        await indexFromDisk(env)
        let folder = try await env.model.organization.createFolder(name: "Inbox items")
        try await env.model.organization.addMembership(item: note, folder: folder.id)
        let nav = NotesNavigationModel(model: env.model, defaultKind: .note)
        defer { setImmutable(note, false, in: env) }
        setImmutable(note, true, in: env)

        await nav.confirmDeletion(.init(itemId: note, folderId: folder.id, title: "Only copy"))

        #expect(env.model.organization.membershipCount(item: note) == 0,
                "the membership removal is the part that DID commit")
        #expect(existsOnDisk(note, in: env), "the file is still there")
        #expect(isListed(note, in: env), "so the operator can still find it")
    }

    // MARK: - The store-level seam

    @Test("itemExists tracks the disk across a create and a trash")
    func itemExistsTracksTheDisk() async throws {
        let env = try await makeEnv()
        defer { Task { await cleanup(env) } }
        let id = try await addNote("Transient", to: env)

        #expect(await env.store.itemExists(id))
        try await env.store.delete(id)
        #expect(await env.store.itemExists(id) == false)
        #expect(await env.store.itemExists(UUID()) == false, "an id that was never created")
    }
}
