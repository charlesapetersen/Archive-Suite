import Testing
import Foundation
@testable import ArchiveNotes

/// W23.h3-fu (Tier-2 — the destructive seam). The **hard-delete window**: while a confirmed delete is
/// in flight, no replicate or move may mint a membership onto the note being trashed.
///
/// W23.h3 closed the *decision* — `removeConfirmedLastMembership` reads its last-instance verdict from
/// what survives the removal, so a membership appearing during the DB write downgrades the outcome and
/// the file is kept. What it could not close is the verdict's **shelf life**: `.deletedLastInstance`
/// means "zero memberships now", and the caller then `await`s the trash on a `@MainActor` that is
/// reentrant at every suspension point. A replicate landing in *that* gap arrives after the verdict, so
/// nothing downgrades — the note is trashed carrying a live membership row that points at it.
///
/// Everything here is deterministic. The window is sub-millisecond in production, so racing two tasks
/// and hoping to land inside it would prove nothing on a green run; instead the concurrent mutation is
/// driven from `NotesModel.hardDeleteWindowHookForTesting`, which `trashItems` awaits **inside** the
/// open window before anything is trashed. That is the same instant the production race would hit.
///
/// Scratch store only (`temporaryDirectory`, never the real notes store, never a corpus — Prime
/// Directive #1). A delete moves the note's directory to the macOS Trash, so it stays recoverable.
@Suite("HardDeleteWindow — no membership may be minted onto a note being trashed (W23.h3-fu)")
@MainActor
struct HardDeleteWindowTests {

    // MARK: Scratch environment

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
            .appendingPathComponent("notes-harddelete-test-\(UUID().uuidString)", isDirectory: true)
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

    /// Create a real on-disk note and seed the shared item source; returns its id.
    private func makeItem(_ env: Env, _ title: String) async throws -> UUID {
        let item = Item(id: UUID(), kind: .note, title: title, authors: [], date: nil,
                        datePrecision: nil, dateUncertain: false, quality: nil, tags: [], zotero: [],
                        roundup: false, created: Date(), modified: Date(), schema: 1, blocks: [],
                        unknownFrontMatter: [], trailingBodyRaw: nil)
        _ = try await env.store.create(item)
        env.model.replaceItems([ItemSummary(id: item.id, title: item.title, kind: item.kind, date: nil,
                                            datePrecision: nil, dateUncertain: false, authors: [],
                                            sortDate: nil, quality: nil, created: item.created,
                                            modified: item.modified, mtime: 0, managedTags: [])])
        return item.id
    }

    private func makeFolder(_ env: Env, _ name: String) async throws -> UUID {
        try await env.org.createFolder(name: name, parent: nil, kind: .normal).id
    }

    private func itemDir(_ env: Env, _ id: UUID) -> URL {
        env.root.appendingPathComponent("items", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    private func itemDirExists(_ env: Env, _ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: itemDir(env, id).path)
    }

    /// The memberships SQLite actually holds for `id` — the durable answer, not the in-memory one.
    private func persistedFolders(_ env: Env, _ id: UUID) async -> [UUID] {
        await env.index.allMemberships().filter { $0.itemId == id }.map(\.folderId)
    }

    /// Drive `item` to a pending §3.6 delete-last-instance confirmation, as the sidebar does.
    private func pendingDelete(_ env: Env, _ item: UUID,
                               from folder: UUID) async throws -> NotesNavigationModel.PendingDeletion {
        await env.nav.removeMembership(item, from: folder)
        return try #require(env.nav.pendingDeletion, "the last membership must ask for confirmation")
    }

    // MARK: - The mechanism (deterministic, no trash involved)

    @Test("a guarded item refuses BOTH membership-minting seams, in memory and on disk")
    func guardRefusesAddAndMove() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let b = try await makeItem(env, "B")
        let f1 = try await makeFolder(env, "F1"); let f2 = try await makeFolder(env, "F2")

        env.org.beginHardDelete([b])
        defer { env.org.endHardDelete([b]) }

        await #expect(throws: OrganizationError.itemBeingDeleted(b)) {
            try await env.org.addMembership(item: b, folder: f1)
        }
        // `moveMembership` mints a membership too — it shipped after the guard was prototyped (W23.m13),
        // and a stale drag from the other window would strand one exactly the same way.
        await #expect(throws: OrganizationError.itemBeingDeleted(b)) {
            try await env.org.moveMembership(item: b, from: f1, to: f2)
        }
        #expect(env.org.foldersContaining(item: b).isEmpty)
        let persisted = await persistedFolders(env, b)
        #expect(persisted.isEmpty, "the refusal must also mean nothing reached SQLite")
    }

    @Test("closing the window restores both seams")
    func closingTheWindowRestoresMutation() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let b = try await makeItem(env, "B")
        let f1 = try await makeFolder(env, "F1"); let f2 = try await makeFolder(env, "F2")

        env.org.beginHardDelete([b])
        env.org.endHardDelete([b])
        #expect(!env.org.isHardDeleting(b))

        try await env.org.addMembership(item: b, folder: f1)
        try await env.org.moveMembership(item: b, from: f1, to: f2)
        #expect(env.org.foldersContaining(item: b) == [f2])
    }

    /// The reason the guard counts instead of flagging. The trash primitive holds one window and its
    /// caller nests a wider one, so the inner `end` runs first — with a `Bool` that would unguard the
    /// item while the outer window is still open, which is the gap this whole item is about.
    @Test("nested windows compose — the inner close does not unguard")
    func refcountComposesAcrossNestedWindows() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let b = try await makeItem(env, "B")
        let f1 = try await makeFolder(env, "F1")

        env.org.beginHardDelete([b])            // outer (the caller, from the verdict)
        env.org.beginHardDelete([b])            // inner (trashItems)
        env.org.endHardDelete([b])              // inner closes first
        #expect(env.org.isHardDeleting(b), "the outer window is still open")
        await #expect(throws: OrganizationError.itemBeingDeleted(b)) {
            try await env.org.addMembership(item: b, folder: f1)
        }

        env.org.endHardDelete([b])              // outer
        #expect(!env.org.isHardDeleting(b))
        try await env.org.addMembership(item: b, folder: f1)
        #expect(env.org.foldersContaining(item: b) == [f1])
    }

    /// An `end` with no matching `begin` must not drive the count below zero — that would leave the
    /// next real window permanently unguarded, silently reopening the defect.
    @Test("an unbalanced end is a no-op, not a negative count")
    func unbalancedEndCannotPoisonTheNextWindow() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let b = try await makeItem(env, "B")
        let f1 = try await makeFolder(env, "F1")

        env.org.endHardDelete([b])              // never begun
        #expect(!env.org.isHardDeleting(b))

        env.org.beginHardDelete([b])
        #expect(env.org.isHardDeleting(b), "the next real window still guards")
        await #expect(throws: OrganizationError.itemBeingDeleted(b)) {
            try await env.org.addMembership(item: b, folder: f1)
        }
        env.org.endHardDelete([b])
        #expect(!env.org.isHardDeleting(b))
    }

    @Test("the guard is per item — an unrelated note is untouched")
    func guardIsScopedToTheItem() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let b = try await makeItem(env, "B")
        let other = try await makeItem(env, "Other")
        let f1 = try await makeFolder(env, "F1")

        env.org.beginHardDelete([b])
        defer { env.org.endHardDelete([b]) }

        try await env.org.addMembership(item: other, folder: f1)
        #expect(env.org.foldersContaining(item: other) == [f1])
    }

    // MARK: - The finding: a replicate driven INTO the real window

    @Test("W23.h3-fu: a replicate inside the confirmed-delete window cannot follow the note to the Trash")
    func replicateIntoConfirmDeletionWindowIsRefused() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let b = try await makeItem(env, "B")
        let f1 = try await makeFolder(env, "F1"); let f2 = try await makeFolder(env, "F2")
        try await env.org.addMembership(item: b, folder: f1)
        let pending = try await pendingDelete(env, b, from: f1)

        // The other window drags B into F2 at the one instant the production race would hit: after the
        // store answered `.deletedLastInstance`, before the note reaches the Trash.
        var windowWasOpen = false
        env.model.hardDeleteWindowHookForTesting = { @MainActor in
            windowWasOpen = env.org.isHardDeleting(b)
            await env.nav.replicate([b], to: f2)
        }

        await env.nav.confirmDeletion(pending)

        #expect(windowWasOpen, "non-vacuity: the replicate really did run inside an open window")
        #expect(!itemDirExists(env, b), "the confirmed delete still happens — it was genuinely the last")
        #expect(env.org.foldersContaining(item: b).isEmpty, "NO membership may point at a trashed note")
        let persisted = await persistedFolders(env, b)
        #expect(persisted.isEmpty, "and none may survive in SQLite either")
        #expect(env.model.statusMessage == "That note is being deleted — it can't be filed into a folder.",
                "the refused drag says why, instead of silently doing nothing")
    }

    @Test("W23.h3-fu: a MOVE inside the window is refused too, and reports failure rather than success")
    func moveIntoConfirmDeletionWindowIsRefused() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let b = try await makeItem(env, "B")
        let f1 = try await makeFolder(env, "F1"); let f2 = try await makeFolder(env, "F2")
        try await env.org.addMembership(item: b, folder: f1)
        let pending = try await pendingDelete(env, b, from: f1)

        env.model.hardDeleteWindowHookForTesting = { @MainActor in
            await env.nav.move([b], to: f2, from: f1)
        }

        await env.nav.confirmDeletion(pending)

        #expect(!itemDirExists(env, b))
        #expect(env.org.foldersContaining(item: b).isEmpty)
        let persisted = await persistedFolders(env, b)
        #expect(persisted.isEmpty)
        #expect(env.model.statusMessage?.contains("Couldn't move") == true,
                "a refused move is reported, never presented as a completed one")
    }

    /// The other hard-delete caller — deleting a folder that strands its sole-instance notes. It reaches
    /// the same primitive, so it inherits the same window; this pins that rather than assuming it.
    @Test("W23.h3-fu: a replicate inside the folder-delete window is refused")
    func replicateIntoFolderDeleteWindowIsRefused() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let b = try await makeItem(env, "B")
        let f1 = try await makeFolder(env, "F1"); let f2 = try await makeFolder(env, "F2")
        try await env.org.addMembership(item: b, folder: f1)
        let stranded = env.model.strandedByDeletingFolder(f1)
        #expect(stranded == [b], "premise: deleting F1 would permanently delete B")

        var windowWasOpen = false
        env.model.hardDeleteWindowHookForTesting = { @MainActor in
            windowWasOpen = env.org.isHardDeleting(b)
            await env.nav.replicate([b], to: f2)
        }

        await env.model.deleteFolderDeletingStranded(f1, stranded: stranded)

        #expect(windowWasOpen)
        #expect(!itemDirExists(env, b))
        #expect(env.org.foldersContaining(item: b).isEmpty)
        let persisted = await persistedFolders(env, b)
        #expect(persisted.isEmpty)
    }

    // MARK: - Every exit path balances

    /// The path the item called out by name. The disk refuses the trash (`UF_IMMUTABLE` on the item
    /// directory — per-item, so it breaks the trash and nothing else), the note survives on disk and
    /// stays findable under All Notes (§5, W23.m12) — and the window must still close, or that survivor
    /// could never be filed into a folder again for the rest of the session.
    @Test("a trash the disk REFUSES still closes the window, so the survivor stays fileable")
    func refusedTrashStillClosesTheWindow() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let b = try await makeItem(env, "B")
        let f1 = try await makeFolder(env, "F1"); let f2 = try await makeFolder(env, "F2")
        try await env.org.addMembership(item: b, folder: f1)
        let pending = try await pendingDelete(env, b, from: f1)
        defer { try? FileManager.default.setAttributes([.immutable: false],
                                                       ofItemAtPath: itemDir(env, b).path) }
        try FileManager.default.setAttributes([.immutable: true],
                                              ofItemAtPath: itemDir(env, b).path)

        await env.nav.confirmDeletion(pending)

        #expect(itemDirExists(env, b), "premise: the fixture really did refuse the trash")
        #expect(!env.org.isHardDeleting(b), "the window closed on the failure path too")
        try await env.org.addMembership(item: b, folder: f2)   // would throw if it had not
        #expect(env.org.foldersContaining(item: b) == [f2])
    }

    /// The two early returns from `confirmDeletion` never trash, so they must never leave a window open
    /// either — a `begin` placed before the verdict would strand one here.
    @Test("an outcome that keeps the file leaves no window open")
    func keepTheFileOutcomesLeaveNoWindow() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let b = try await makeItem(env, "B")
        let f1 = try await makeFolder(env, "F1"); let f2 = try await makeFolder(env, "F2")
        try await env.org.addMembership(item: b, folder: f1)
        let pending = try await pendingDelete(env, b, from: f1)

        // `.unlinkedNotLast`: a replica appears while the alert is open, so the confirm only unlinks.
        try await env.org.addMembership(item: b, folder: f2)
        await env.nav.confirmDeletion(pending)
        #expect(itemDirExists(env, b))
        #expect(env.org.foldersContaining(item: b) == [f2])
        #expect(!env.org.isHardDeleting(b))

        // `.notPresent`: the same stale confirm replayed — the pair is gone now.
        await env.nav.confirmDeletion(pending)
        #expect(itemDirExists(env, b))
        #expect(!env.org.isHardDeleting(b))
        try await env.org.addMembership(item: b, folder: f1)   // still fileable
        #expect(Set(env.org.foldersContaining(item: b)) == Set([f1, f2]))
    }
}
