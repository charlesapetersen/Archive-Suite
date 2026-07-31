import Testing
import Foundation
@testable import ArchiveNotes

/// W23.m13 — the Notes façade documents its organization mutations as atomic, but three of them spanned
/// several independent awaited writes with no transaction and no rollback:
///
/// * `deleteFolder` reparented each child **in memory** before its own DB update, then deleted the
///   memberships, the template assignment and the folder as three more separate writes.
/// * `deleteTemplate` cleared **every** folder assignment before it even attempted the trash.
/// * `move` added the target membership and then swallowed a failed source removal with `try?`.
///
/// The nastiest ordering was silent rather than loud: the memberships delete commits, the folder delete
/// then fails, and the throw skips the in-memory cleanup — so memory and `organization.json` still list
/// memberships the DB no longer has. `OrganizationStore.load` prefers the DB whenever it holds folders,
/// so the *next launch* adopts the lossy half as the durable truth and those notes are orphaned with no
/// §3.6 confirmation ever shown.
///
/// Everything here runs on **scratch** `temporaryDirectory` fixtures — never the owner's notes store,
/// never a corpus (Prime Directive #1).
///
/// **Fault injection is real SQLite, not a mock.** A `BEFORE DELETE … RAISE(ABORT)` trigger breaks
/// exactly ONE leg of a transaction and leaves every other table readable, which is the only way to ask
/// the disk whether the other legs actually rolled back. (`RAISE(ABORT)` backs out the current statement
/// and leaves the transaction open, so what undoes the earlier legs is our own `ROLLBACK`.) Two tests
/// assert the fixture's own honesty before anything is concluded from it.
@Suite("W23.m13 — multi-step organization ops are all-or-nothing")
@MainActor
struct OrganizationAtomicityTests {

    // MARK: - Scratch environment

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
            .appendingPathComponent("notes-w23m13-\(UUID().uuidString)", isDirectory: true)
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

    private func makeItem(_ title: String, kind: Item.Kind = .note) -> Item {
        Item(id: UUID(), kind: kind, title: title, authors: [], date: nil, datePrecision: nil,
             dateUncertain: false, quality: nil, tags: [], zotero: [], roundup: false,
             created: Date(), modified: Date(), schema: 1, blocks: [],
             unknownFrontMatter: [], trailingBodyRaw: nil)
    }

    // MARK: - Fault injection

    /// Refuse `DELETE FROM <table>` on this connection — every row, or only those matching `where`
    /// (a predicate over `OLD`). Not compiled into Release — it goes through
    /// `NotesIndex.executeForTesting`, which is `#if DEBUG`.
    ///
    /// A *targeted* refusal is what makes a batch test non-vacuous: if every delete fails, a
    /// non-transactional loop and a transaction are indistinguishable — both leave the table alone.
    /// Letting the first row through and refusing the second is the only fault that can tell a rollback
    /// from a half-applied batch.
    private func breakDeletes(on table: String, where predicate: String? = nil,
                              _ index: NotesIndex) async throws {
        let when = predicate.map { " WHEN \($0)" } ?? ""
        try await index.executeForTesting("""
            CREATE TRIGGER w23m13_block_\(table) BEFORE DELETE ON \(table)\(when)
            BEGIN SELECT RAISE(ABORT, 'w23m13 injected failure'); END;
            """)
    }

    private func healDeletes(on table: String, _ index: NotesIndex) async throws {
        try await index.executeForTesting("DROP TRIGGER IF EXISTS w23m13_block_\(table);")
    }

    private func setImmutable(_ path: URL, _ on: Bool) {
        try? FileManager.default.setAttributes([.immutable: on], ofItemAtPath: path.path)
    }

    // MARK: - Readers that ask the DISK, not memory

    private func dbFolder(_ id: UUID, _ index: NotesIndex) async -> VFolder? {
        await index.allFolders().first { $0.id == id }
    }

    private func dbFolders(of item: UUID, _ index: NotesIndex) async -> Set<UUID> {
        Set(await index.allMemberships().filter { $0.itemId == item }.map(\.folderId))
    }

    private func dbAssignedFolders(_ index: NotesIndex) async -> Set<UUID> {
        Set(await index.allTemplateAssignments().map(\.folderId))
    }

    // MARK: - The fixture is honest

    @Test("the injected trigger really does refuse a folder delete")
    func triggerRefusesAFolderDelete() async throws {
        let env = try await makeEnv()
        defer { Task { await cleanup(env) } }
        let folder = try await env.org.createFolder(name: "Ledgers")

        try await breakDeletes(on: "folders", env.index)
        await #expect(throws: (any Error).self) { try await env.index.deleteFolder(id: folder.id) }
        #expect(await dbFolder(folder.id, env.index) != nil,
                "the premise: the row survives a refused delete")
    }

    @Test("the immutable flag really does refuse a template trash")
    func immutableFlagRefusesATemplateTrash() async throws {
        let env = try await makeEnv()
        defer { Task { await cleanup(env) } }
        let template = makeItem("Field Note", kind: .note)
        _ = try await env.store.createTemplate(template)
        let dir = await env.store.templateDir(template.id)
        defer { setImmutable(dir, false) }

        setImmutable(dir, true)
        await #expect(throws: (any Error).self) { try await env.store.deleteTemplate(template.id) }
        #expect(FileManager.default.fileExists(atPath: dir.path),
                "the premise: the template is still on disk after a refused trash")
    }

    // MARK: - deleteFolder — the finding's headline case

    /// The exact ordering the finding describes: memberships and the template assignment delete fine,
    /// the folder row does not. Pre-fix those were separate autocommitted writes, so the memberships
    /// were **gone from the DB** while memory and `organization.json` still listed them.
    @Test("a folder delete that fails part-way leaves every membership on disk")
    func failedFolderDeleteRollsBackTheMemberships() async throws {
        let env = try await makeEnv()
        defer { Task { await cleanup(env) } }
        let folder = try await env.org.createFolder(name: "Box 12")
        let template = makeItem("Field Note")
        let a = UUID(), b = UUID()
        try await env.org.addMembership(item: a, folder: folder.id)
        try await env.org.addMembership(item: b, folder: folder.id)
        try await env.org.assignTemplate(template.id, to: folder.id)

        try await breakDeletes(on: "folders", env.index)
        await #expect(throws: (any Error).self) { _ = try await env.org.deleteFolder(folder.id) }

        #expect(await dbFolders(of: a, env.index) == [folder.id], "membership must roll back with it")
        #expect(await dbFolders(of: b, env.index) == [folder.id])
        #expect(await dbAssignedFolders(env.index).contains(folder.id),
                "the template assignment must roll back too")
        #expect(await dbFolder(folder.id, env.index) != nil)
    }

    /// The property the finding is really about, stated directly: **memory and the DB must still say
    /// the same thing.** Asserting "memory is unchanged" alone would be vacuous here — pre-fix, memory
    /// was *also* unchanged in this shape (the throw skipped its cleanup), and that is exactly what made
    /// the bug silent. What changed underneath was the disk. So compare the two.
    @Test("a folder delete that fails leaves memory and the DB still agreeing")
    func failedFolderDeleteLeavesNoDivergence() async throws {
        let env = try await makeEnv()
        defer { Task { await cleanup(env) } }
        let folder = try await env.org.createFolder(name: "Box 12")
        let item = UUID()
        try await env.org.addMembership(item: item, folder: folder.id)
        try await env.org.assignTemplate(UUID(), to: folder.id)

        try await breakDeletes(on: "folders", env.index)
        await #expect(throws: (any Error).self) { _ = try await env.org.deleteFolder(folder.id) }

        #expect(env.org.folders.contains { $0.id == folder.id }, "the folder is still there")
        #expect(env.org.foldersContaining(item: item) == [folder.id])
        #expect(env.org.assignments.contains { $0.folderId == folder.id })
        // …and the disk says the same. Pre-fix the memberships and the assignment were already gone
        // from the DB while these in-memory checks all still passed, and `load()` prefers the DB — so
        // the next launch would have adopted the lossy half and orphaned the item with no §3.6 prompt.
        #expect(await dbFolders(of: item, env.index) == Set(env.org.foldersContaining(item: item)),
                "memory must not describe memberships the DB has already dropped")
        #expect(await dbAssignedFolders(env.index) == Set(env.org.assignments.map(\.folderId)))
        #expect(await Set(env.index.allFolders().map(\.id)) == Set(env.org.folders.map(\.id)))
    }

    /// The finding's first bullet, directly: the child used to be reparented in memory *before* the DB
    /// update that could refuse it, so the sidebar showed a move the disk never took.
    @Test("a folder delete that fails does not reparent the child in memory or on disk")
    func failedFolderDeleteDoesNotReparentTheChild() async throws {
        let env = try await makeEnv()
        defer { Task { await cleanup(env) } }
        let parent = try await env.org.createFolder(name: "Series A")
        let doomed = try await env.org.createFolder(name: "Box 12", parent: parent.id)
        let child = try await env.org.createFolder(name: "Folder 3", parent: doomed.id)

        try await breakDeletes(on: "folders", env.index)
        await #expect(throws: (any Error).self) { _ = try await env.org.deleteFolder(doomed.id) }

        #expect(env.org.folders.first { $0.id == child.id }?.parentId == doomed.id,
                "memory must not run ahead of a reparent the disk refused")
        #expect(await dbFolder(child.id, env.index)?.parentId == doomed.id)
    }

    @Test("a healthy folder delete still reparents, unlinks and reports its orphans")
    func healthyFolderDeleteIsUnchanged() async throws {
        let env = try await makeEnv()
        defer { Task { await cleanup(env) } }
        let parent = try await env.org.createFolder(name: "Series A")
        let doomed = try await env.org.createFolder(name: "Box 12", parent: parent.id)
        let child = try await env.org.createFolder(name: "Folder 3", parent: doomed.id)
        let keeper = try await env.org.createFolder(name: "Elsewhere")
        let orphan = UUID(), survivor = UUID()
        try await env.org.addMembership(item: orphan, folder: doomed.id)
        try await env.org.addMembership(item: survivor, folder: doomed.id)
        try await env.org.addMembership(item: survivor, folder: keeper.id)
        try await env.org.assignTemplate(UUID(), to: doomed.id)

        let orphaned = try await env.org.deleteFolder(doomed.id)

        #expect(orphaned == [orphan], "only the sole-instance item is reported stranded")
        #expect(env.org.folders.first { $0.id == child.id }?.parentId == parent.id)
        #expect(await dbFolder(child.id, env.index)?.parentId == parent.id)
        #expect(await dbFolder(doomed.id, env.index) == nil)
        #expect(await dbFolders(of: survivor, env.index) == [keeper.id])
        #expect(await dbFolders(of: orphan, env.index).isEmpty)
        #expect(await dbAssignedFolders(env.index).contains(doomed.id) == false)
        #expect(env.org.mirrorFailure == nil, "a writable fixture must not raise a mirror warning")
    }

    /// Nothing has to be replayed after a transient fault: the rollback left the graph exactly as it
    /// was, so the same call simply works once the fault clears.
    @Test("a folder delete succeeds in full once the fault clears")
    func folderDeleteRecoversAfterTheFaultClears() async throws {
        let env = try await makeEnv()
        defer { Task { await cleanup(env) } }
        let folder = try await env.org.createFolder(name: "Box 12")
        let item = UUID()
        try await env.org.addMembership(item: item, folder: folder.id)

        try await breakDeletes(on: "folders", env.index)
        await #expect(throws: (any Error).self) { _ = try await env.org.deleteFolder(folder.id) }
        try await healDeletes(on: "folders", env.index)

        let orphaned = try await env.org.deleteFolder(folder.id)
        #expect(orphaned == [item])
        #expect(await dbFolder(folder.id, env.index) == nil)
        #expect(await dbFolders(of: item, env.index).isEmpty)
    }

    // MARK: - move — never replicated in both folders

    /// The finding's third bullet at the store seam. Pre-fix the target add committed and the refused
    /// source removal was swallowed, so the item ended up in BOTH folders while the UI said "moved".
    @Test("a refused move leaves the item in exactly one folder — the one it started in")
    func refusedMoveDoesNotReplicate() async throws {
        let env = try await makeEnv()
        defer { Task { await cleanup(env) } }
        let source = try await env.org.createFolder(name: "Inbox 2")
        let target = try await env.org.createFolder(name: "Box 12")
        let item = UUID()
        try await env.org.addMembership(item: item, folder: source.id)

        try await breakDeletes(on: "memberships", env.index)
        await #expect(throws: (any Error).self) {
            try await env.org.moveMembership(item: item, from: source.id, to: target.id)
        }

        #expect(await dbFolders(of: item, env.index) == [source.id],
                "the target add must roll back with the refused source removal")
        #expect(env.org.foldersContaining(item: item) == [source.id])
    }

    @Test("a healthy move relocates the item instead of replicating it")
    func healthyMoveRelocates() async throws {
        let env = try await makeEnv()
        defer { Task { await cleanup(env) } }
        let source = try await env.org.createFolder(name: "Inbox 2")
        let target = try await env.org.createFolder(name: "Box 12")
        let item = UUID()
        try await env.org.addMembership(item: item, folder: source.id)

        try await env.org.moveMembership(item: item, from: source.id, to: target.id)

        #expect(await dbFolders(of: item, env.index) == [target.id])
        #expect(env.org.foldersContaining(item: item) == [target.id])
    }

    /// The property the old add-then-remove order existed to protect, preserved by the new one: a note
    /// whose only membership is the source must never become member-less (which would strand it under
    /// All Notes) and must never trip the §3.6 delete-last-instance guard.
    @Test("moving a sole-instance note never leaves it member-less")
    func moveOfASoleInstanceKeepsExactlyOneMembership() async throws {
        let env = try await makeEnv()
        defer { Task { await cleanup(env) } }
        let source = try await env.org.createFolder(name: "Inbox 2")
        let target = try await env.org.createFolder(name: "Box 12")
        let item = UUID()
        try await env.org.addMembership(item: item, folder: source.id)
        #expect(env.org.membershipCount(item: item) == 1, "the setup really is a sole instance")

        try await env.org.moveMembership(item: item, from: source.id, to: target.id)

        #expect(env.org.membershipCount(item: item) == 1)
        #expect(env.org.foldersContaining(item: item) == [target.id])
    }

    @Test("a stale drag from a folder the item is not in is a plain add, not an error")
    func staleDragDegradesToAnAdd() async throws {
        let env = try await makeEnv()
        defer { Task { await cleanup(env) } }
        let source = try await env.org.createFolder(name: "Inbox 2")
        let target = try await env.org.createFolder(name: "Box 12")
        let item = UUID()

        try await env.org.moveMembership(item: item, from: source.id, to: target.id)

        #expect(await dbFolders(of: item, env.index) == [target.id])
    }

    // MARK: - move — what the operator is told

    @Test("the UI says the note is still where it was when the move is refused")
    func navigationModelReportsARefusedMoveHonestly() async throws {
        let env = try await makeEnv()
        defer { Task { await cleanup(env) } }
        let source = try await env.org.createFolder(name: "Inbox 2")
        let target = try await env.org.createFolder(name: "Box 12")
        let item = UUID()
        try await env.org.addMembership(item: item, folder: source.id)

        try await breakDeletes(on: "memberships", env.index)
        await env.nav.move([item], to: target.id, from: source.id)

        #expect(env.org.mirrorFailure == nil,
                "a writable fixture: the message under test must not be the mirror's")
        #expect(env.model.statusMessage?.contains("still where it was") == true,
                "got: \(env.model.statusMessage ?? "nil")")
        #expect(env.org.foldersContaining(item: item) == [source.id],
                "and the message is true — the item really is only in the source")
    }

    @Test("a healthy move through the UI says nothing and moves the note")
    func navigationModelHealthyMoveIsSilent() async throws {
        let env = try await makeEnv()
        defer { Task { await cleanup(env) } }
        let source = try await env.org.createFolder(name: "Inbox 2")
        let target = try await env.org.createFolder(name: "Box 12")
        let item = UUID()
        try await env.org.addMembership(item: item, folder: source.id)

        await env.nav.move([item], to: target.id, from: source.id)

        #expect(env.model.statusMessage == nil, "got: \(env.model.statusMessage ?? "nil")")
        #expect(await dbFolders(of: item, env.index) == [target.id])
    }

    // MARK: - deleteTemplate — the trash decides

    /// The finding's second bullet. Pre-fix every assignment was cleared before the trash was even
    /// attempted, so a refused trash reported a failure about a template that was still there while
    /// its folder assignments had already been thrown away.
    @Test("a refused template trash keeps every folder assignment")
    func refusedTemplateTrashKeepsTheAssignments() async throws {
        let env = try await makeEnv()
        defer { Task { await cleanup(env) } }
        let a = try await env.org.createFolder(name: "Correspondence")
        let b = try await env.org.createFolder(name: "Memoranda")
        let template = makeItem("Field Note")
        _ = try await env.store.createTemplate(template)
        try await env.org.assignTemplate(template.id, to: a.id)
        try await env.org.assignTemplate(template.id, to: b.id)
        let dir = await env.store.templateDir(template.id)
        defer { setImmutable(dir, false) }

        setImmutable(dir, true)
        await env.model.deleteTemplate(template.id)

        #expect(FileManager.default.fileExists(atPath: dir.path), "the template survived the refusal")
        #expect(await dbAssignedFolders(env.index) == [a.id, b.id],
                "so its assignments must survive with it")
        #expect(Set(env.org.assignments.map(\.folderId)) == [a.id, b.id])
        #expect(env.model.statusMessage?.contains("delete the template") == true,
                "got: \(env.model.statusMessage ?? "nil")")
    }

    @Test("a successful template delete clears every folder that pointed at it")
    func healthyTemplateDeleteClearsEveryAssignment() async throws {
        let env = try await makeEnv()
        defer { Task { await cleanup(env) } }
        let a = try await env.org.createFolder(name: "Correspondence")
        let b = try await env.org.createFolder(name: "Memoranda")
        let other = try await env.org.createFolder(name: "Untouched")
        let template = makeItem("Field Note")
        let keeper = makeItem("Roundup")
        _ = try await env.store.createTemplate(template)
        _ = try await env.store.createTemplate(keeper)
        try await env.org.assignTemplate(template.id, to: a.id)
        try await env.org.assignTemplate(template.id, to: b.id)
        try await env.org.assignTemplate(keeper.id, to: other.id)

        await env.model.deleteTemplate(template.id)

        #expect(await dbAssignedFolders(env.index) == [other.id],
                "only the deleted template's assignments go")
        #expect(env.org.assignments.map(\.folderId) == [other.id])
        #expect(env.model.statusMessage == nil, "got: \(env.model.statusMessage ?? "nil")")
    }

    /// The batch clear is itself one transaction, so it cannot half-apply across folders — which is
    /// what would leave one folder pointing at a trashed template and its sibling not.
    ///
    /// The fault is deliberately **targeted at the second folder only**: the first delete succeeds, so
    /// a plain loop would commit it and then fail, leaving exactly the half-applied state under test.
    @Test("a refused assignment clear leaves all of the assignments in place, not some")
    func refusedAssignmentClearIsAllOrNothing() async throws {
        let env = try await makeEnv()
        defer { Task { await cleanup(env) } }
        let a = try await env.org.createFolder(name: "Correspondence")
        let b = try await env.org.createFolder(name: "Memoranda")
        let template = UUID()
        try await env.org.assignTemplate(template, to: a.id)
        try await env.org.assignTemplate(template, to: b.id)

        try await breakDeletes(on: "template_assignments",
                               where: "OLD.folder_id = '\(b.id.uuidString)'", env.index)
        await #expect(throws: (any Error).self) {
            try await env.org.removeTemplateAssignments(folders: [a.id, b.id])
        }

        #expect(await dbAssignedFolders(env.index) == [a.id, b.id],
                "the first folder's clear must roll back with the second one's refusal")
        #expect(Set(env.org.assignments.map(\.folderId)) == [a.id, b.id])
    }
}
