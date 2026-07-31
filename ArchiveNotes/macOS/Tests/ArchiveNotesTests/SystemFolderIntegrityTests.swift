import Testing
import Foundation
@testable import ArchiveNotes

/// W23.m15 — the two system folders the app itself files into (Inbox for `newItem`, Extracts for
/// `createExtract`, §16.6) were deletable, and deleting one was **permanent**:
///
/// * the sidebar offered Rename and Delete on every folder row, and `OrganizationStore.deleteFolder`
///   accepted the fixed ids;
/// * `load` re-seeded the system folders **only when the whole folder table was empty**, so any store
///   with even one user folder came back up without them, launch after launch;
/// * `addMembership` never checked that the folder existed and `memberships` had no foreign key, so
///   every note and extract created afterwards added a row to a folder that could never be rendered,
///   never be emptied, and never be restored.
///
/// The three layers are tested separately on purpose — the UI's disabled menu item is the one a user
/// meets, the store's throw is the backstop for a caller that skips it, and the SQL constraint is the
/// backstop for a writer that skips *both*.
///
/// Everything runs on **scratch** `temporaryDirectory` fixtures — never the owner's notes store
/// (Prime Directive #1).
@Suite("W23.m15 — system folders survive, memberships can't go ghost")
@MainActor
struct SystemFolderIntegrityTests {

    // MARK: - Scratch environment

    struct Env {
        let org: OrganizationStore
        let index: NotesIndex
        let root: URL
    }

    private func makeEnv() async throws -> Env {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-w23m15-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = NotesIndex(url: root.appendingPathComponent("index.db"))
        try await index.open()
        let org = OrganizationStore(index: index)
        try await org.load(storeRoot: root)
        return Env(org: org, index: index, root: root)
    }

    private func cleanup(_ env: Env) async {
        await env.index.close()
        try? FileManager.default.removeItem(at: env.root)
    }

    /// A second store over the SAME index + root — a relaunch, which is where restoration happens.
    private func relaunch(_ env: Env) async throws -> OrganizationStore {
        let store = OrganizationStore(index: env.index)
        try await store.load(storeRoot: env.root)
        return store
    }

    /// Delete a folder row **behind the store's back**, the way the shipped bug did — the guards under
    /// test would refuse the same thing through the API, so this is how a damaged store is reproduced.
    private func deleteFolderRowDirectly(_ id: UUID, in index: NotesIndex) async throws {
        try await index.executeForTesting(
            "DELETE FROM folders WHERE id = '\(id.uuidString)';")
    }

    private func dbMembershipCount(_ index: NotesIndex, folder: UUID) async -> Int {
        await index.allMemberships().count { $0.folderId == folder }
    }

    // MARK: - (a) Rename / delete are refused on the fixed ids

    @Test("deleteFolder refuses each system folder and changes nothing")
    func deleteRefusesSystemFolders() async throws {
        let env = try await makeEnv()
        defer { Task { await cleanup(env) } }

        let item = UUID()
        try await env.org.addMembership(item: item, folder: OrganizationStore.inboxFolderId)

        for id in [OrganizationStore.allNotesFolderId,
                   OrganizationStore.inboxFolderId,
                   OrganizationStore.extractsFolderId] {
            await #expect(throws: OrganizationError.self) {
                _ = try await env.org.deleteFolder(id)
            }
            #expect(env.org.folders.contains { $0.id == id })
            #expect(await env.index.allFolders().contains { $0.id == id })
        }

        // The refusal is total: the memberships the delete would have swept are untouched.
        #expect(env.org.items(in: OrganizationStore.inboxFolderId) == [item])
        #expect(await dbMembershipCount(env.index, folder: OrganizationStore.inboxFolderId) == 1)
    }

    @Test("renameFolder refuses a system folder")
    func renameRefusesSystemFolder() async throws {
        let env = try await makeEnv()
        defer { Task { await cleanup(env) } }

        await #expect(throws: OrganizationError.self) {
            try await env.org.renameFolder(OrganizationStore.inboxFolderId, to: "Junk")
        }
        #expect(env.org.folders.first { $0.id == OrganizationStore.inboxFolderId }?.name == "Inbox")
    }

    /// Non-vacuity for the two refusals above: a user folder still renames and deletes.
    @Test("a user folder is still fully mutable")
    func userFolderStillMutable() async throws {
        let env = try await makeEnv()
        defer { Task { await cleanup(env) } }

        let f = try await env.org.createFolder(name: "Research")
        try await env.org.renameFolder(f.id, to: "Sources")
        #expect(env.org.folders.first { $0.id == f.id }?.name == "Sources")
        _ = try await env.org.deleteFolder(f.id)
        #expect(!env.org.folders.contains { $0.id == f.id })
        #expect(await !env.index.allFolders().contains { $0.id == f.id })
    }

    @Test("the model reports the refusal in words and deletes nothing")
    func modelRefusesWithAMessage() async throws {
        let env = try await makeEnv()
        defer { Task { await cleanup(env) } }
        let model = NotesModel(organization: env.org, index: env.index,
                               noteStore: NoteStore(root: env.root))

        let orphaned = await model.deleteFolder(OrganizationStore.extractsFolderId)
        #expect(orphaned.isEmpty)
        #expect(model.statusMessage?.contains("built-in folder") == true)
        #expect(env.org.folders.contains { $0.id == OrganizationStore.extractsFolderId })

        model.statusMessage = nil
        await model.renameFolder(OrganizationStore.inboxFolderId, to: "Junk")
        #expect(model.statusMessage?.contains("built-in folder") == true)
        #expect(env.org.folders.first { $0.id == OrganizationStore.inboxFolderId }?.name == "Inbox")
    }

    /// The delete-and-trash-the-stranded-notes path refuses **before** anything is trashed — it is the
    /// one caller whose whole job is deleting notes, so a late refusal would be too late.
    @Test("deleteFolderDeletingStranded refuses a system folder before trashing anything")
    func strandedDeleteRefusesSystemFolder() async throws {
        let env = try await makeEnv()
        defer { Task { await cleanup(env) } }
        let noteStore = NoteStore(root: env.root)
        let model = NotesModel(organization: env.org, index: env.index, noteStore: noteStore)

        let item = Item(id: UUID(), kind: .note, title: "Only copy", authors: [], date: nil,
                        datePrecision: nil, dateUncertain: false, quality: nil, tags: [],
                        zotero: [], roundup: false, created: Date(), modified: Date(), schema: 1,
                        blocks: [], unknownFrontMatter: [], trailingBodyRaw: nil)
        _ = try await noteStore.create(item)
        try await env.org.addMembership(item: item.id, folder: OrganizationStore.inboxFolderId)

        await model.deleteFolderDeletingStranded(OrganizationStore.inboxFolderId, stranded: [item.id])

        #expect(model.statusMessage?.contains("built-in folder") == true)
        #expect(env.org.folders.contains { $0.id == OrganizationStore.inboxFolderId })
        #expect(env.org.items(in: OrganizationStore.inboxFolderId) == [item.id])
        // The note is still on disk — nothing reached the Trash.
        #expect(await (try? noteStore.load(item.id)) != nil)
    }

    // MARK: - (b) A missing system folder is restored by ID at load

    @Test("a system folder deleted from a NON-empty table is restored on the next load")
    func restoresMissingSystemFolderFromPopulatedTable() async throws {
        let env = try await makeEnv()
        defer { Task { await cleanup(env) } }

        // A user folder, so the folder table is not empty — the exact condition under which the old
        // "seed only when the table is empty" rule never fired again.
        _ = try await env.org.createFolder(name: "Research")
        try await deleteFolderRowDirectly(OrganizationStore.inboxFolderId, in: env.index)
        #expect(await !env.index.allFolders().contains { $0.id == OrganizationStore.inboxFolderId })

        let reloaded = try await relaunch(env)

        let inbox = reloaded.folders.first { $0.id == OrganizationStore.inboxFolderId }
        #expect(inbox?.name == "Inbox")
        #expect(inbox?.kind == .normal)
        #expect(inbox?.parentId == nil)
        #expect(await env.index.allFolders().contains { $0.id == OrganizationStore.inboxFolderId })
        // Restored, not duplicated.
        #expect(reloaded.folders.count(where: { $0.id == OrganizationStore.inboxFolderId }) == 1)
        #expect(reloaded.folders.count == 4)
    }

    @Test("restoration is by id — a renamed system folder keeps its name")
    func restorationDoesNotClobberARename() async throws {
        let env = try await makeEnv()
        defer { Task { await cleanup(env) } }

        // Renaming a system folder is refused through the API now, so an old store's rename is
        // reproduced at the DB layer.
        try await env.index.executeForTesting(
            "UPDATE folders SET name = 'In Tray' WHERE id = '\(OrganizationStore.inboxFolderId.uuidString)';")

        let reloaded = try await relaunch(env)
        #expect(reloaded.folders.first { $0.id == OrganizationStore.inboxFolderId }?.name == "In Tray")
        #expect(reloaded.folders.count == 3)
    }

    /// The point of restoring by id: the memberships that accrued to the dead folder come back with it.
    @Test("memberships stranded by a deleted system folder are live again after restore")
    func strandedMembershipsAreRevivedByRestore() async throws {
        let env = try await makeEnv()
        defer { Task { await cleanup(env) } }

        let item = UUID()
        try await env.org.addMembership(item: item, folder: OrganizationStore.inboxFolderId)
        _ = try await env.org.createFolder(name: "Research")
        try await deleteFolderRowDirectly(OrganizationStore.inboxFolderId, in: env.index)

        let reloaded = try await relaunch(env)
        #expect(reloaded.folders.contains { $0.id == OrganizationStore.inboxFolderId })
        #expect(reloaded.items(in: OrganizationStore.inboxFolderId) == [item])
    }

    @Test("a fresh store still seeds all three system folders")
    func freshStoreSeedsSystemFolders() async throws {
        let env = try await makeEnv()
        defer { Task { await cleanup(env) } }
        #expect(Set(env.org.folders.map(\.id)) == Set(OrganizationStore.systemFolderSeeds.map(\.id)))
    }

    // MARK: - (b) The organization.json import path

    @Test("importing a mirror without system folders restores them and drops folderless edges")
    func mirrorImportRestoresAndTidies() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-w23m15-mirror-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A mirror written by the buggy build: Inbox deleted, its memberships still recorded, plus one
        // membership + one template assignment pointing at a user folder that is also gone.
        let user = VFolder(id: UUID(), name: "Research", parentId: nil,
                           sortOrder: 0, kind: .normal, queryJSON: nil)
        let vanished = UUID()
        let keptItem = UUID(), ghostItem = UUID(), inboxItem = UUID()
        try OrganizationFile.export(
            folders: [user],
            memberships: [
                Membership(itemId: keptItem, folderId: user.id, addedAt: Date()),
                Membership(itemId: inboxItem, folderId: OrganizationStore.inboxFolderId, addedAt: Date()),
                Membership(itemId: ghostItem, folderId: vanished, addedAt: Date()),
            ],
            assignments: [TemplateAssignment(folderId: vanished, templateId: UUID())],
            to: root)

        let index = NotesIndex(url: root.appendingPathComponent("index.db"))
        try await index.open()
        defer { Task { await index.close() } }
        let org = OrganizationStore(index: index)
        try await org.load(storeRoot: root)

        // System folders restored alongside the imported user folder.
        #expect(org.folders.count == 4)
        #expect(org.folders.contains { $0.id == OrganizationStore.inboxFolderId })
        #expect(org.folders.contains { $0.id == user.id })

        // The Inbox edge survives *because* Inbox was restored first; the truly folderless ones go.
        #expect(org.items(in: OrganizationStore.inboxFolderId) == [inboxItem])
        #expect(org.items(in: user.id) == [keptItem])
        #expect(org.items(in: vanished).isEmpty)
        #expect(org.assignments.isEmpty)

        // Memory and the DB agree — the import must not leave the store holding rows SQLite refused.
        let dbMemberships = await index.allMemberships()
        #expect(Set(dbMemberships.map(\.itemId)) == Set([keptItem, inboxItem]))
        #expect(await index.allTemplateAssignments().isEmpty)
    }

    // MARK: - (c) A membership can't name a folder that doesn't exist

    @Test("addMembership refuses an unknown folder and writes nothing")
    func addMembershipRefusesUnknownFolder() async throws {
        let env = try await makeEnv()
        defer { Task { await cleanup(env) } }

        let ghostFolder = UUID()
        await #expect(throws: OrganizationError.self) {
            try await env.org.addMembership(item: UUID(), folder: ghostFolder)
        }
        #expect(env.org.memberships.isEmpty)
        #expect(await env.index.allMemberships().isEmpty)
    }

    @Test("moveMembership refuses an unknown target and leaves the source membership intact")
    func moveMembershipRefusesUnknownTarget() async throws {
        let env = try await makeEnv()
        defer { Task { await cleanup(env) } }

        let item = UUID()
        try await env.org.addMembership(item: item, folder: OrganizationStore.inboxFolderId)
        await #expect(throws: OrganizationError.self) {
            try await env.org.moveMembership(item: item,
                                             from: OrganizationStore.inboxFolderId, to: UUID())
        }
        #expect(env.org.items(in: OrganizationStore.inboxFolderId) == [item])
        #expect(await dbMembershipCount(env.index, folder: OrganizationStore.inboxFolderId) == 1)
    }

    /// Non-vacuity for the guard above: a membership to a folder that DOES exist still lands.
    @Test("addMembership to a real folder still works")
    func addMembershipToRealFolderWorks() async throws {
        let env = try await makeEnv()
        defer { Task { await cleanup(env) } }

        let f = try await env.org.createFolder(name: "Research")
        let item = UUID()
        try await env.org.addMembership(item: item, folder: f.id)
        #expect(env.org.items(in: f.id) == [item])
        #expect(await dbMembershipCount(env.index, folder: f.id) == 1)
    }
}
