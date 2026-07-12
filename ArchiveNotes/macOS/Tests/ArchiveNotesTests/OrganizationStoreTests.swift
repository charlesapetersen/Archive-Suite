import Testing
import Foundation
@testable import ArchiveNotes

@MainActor
struct OrganizationStoreTests {
    private func makeTempEnv() async throws -> (store: OrganizationStore, index: NotesIndex, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("org-store-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dbURL = root.appendingPathComponent("index.db")
        let index = NotesIndex(url: dbURL)
        try await index.open()
        let store = OrganizationStore(index: index)
        try await store.load(storeRoot: root)
        return (store, index, root)
    }

    private func cleanup(_ root: URL, _ index: NotesIndex) async {
        await index.close()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - System folders

    @Test func seedsSystemFoldersOnFreshInstall() async throws {
        let (store, index, root) = try await makeTempEnv()
        defer { Task { await cleanup(root, index) } }

        #expect(store.folders.count == 3)
        let ids = Set(store.folders.map(\.id))
        #expect(ids.contains(OrganizationStore.allNotesFolderId))
        #expect(ids.contains(OrganizationStore.inboxFolderId))
        #expect(ids.contains(OrganizationStore.extractsFolderId))
        #expect(store.extractsHomeFolderId == OrganizationStore.extractsFolderId)

        let allNotes = store.folders.first { $0.id == OrganizationStore.allNotesFolderId }
        #expect(allNotes?.kind == .smart)
        #expect(allNotes?.name == "All Notes")
    }

    // MARK: - Folder CRUD

    @Test func createFolder() async throws {
        let (store, index, root) = try await makeTempEnv()
        defer { Task { await cleanup(root, index) } }

        let folder = try await store.createFolder(name: "Research")
        #expect(store.folders.count == 4) // 3 system + 1
        #expect(folder.name == "Research")
        #expect(folder.kind == .normal)
        #expect(folder.parentId == nil)

        // Persisted to DB
        let dbFolders = await index.allFolders()
        #expect(dbFolders.contains { $0.id == folder.id })
    }

    @Test func renameFolder() async throws {
        let (store, index, root) = try await makeTempEnv()
        defer { Task { await cleanup(root, index) } }

        let folder = try await store.createFolder(name: "Old Name")
        try await store.renameFolder(folder.id, to: "New Name")
        #expect(store.folders.first { $0.id == folder.id }?.name == "New Name")
    }

    @Test func moveFolderCycleGuardRefuses() async throws {
        let (store, index, root) = try await makeTempEnv()
        defer { Task { await cleanup(root, index) } }

        let parent = try await store.createFolder(name: "Parent")
        let child = try await store.createFolder(name: "Child", parent: parent.id)

        // Try to move parent under child — should be a no-op (cycle)
        try await store.moveFolder(parent.id, newParent: child.id, sortOrder: 0)
        #expect(store.folders.first { $0.id == parent.id }?.parentId == nil)

        // Try to move a folder under itself — should be a no-op
        try await store.moveFolder(parent.id, newParent: parent.id, sortOrder: 0)
        #expect(store.folders.first { $0.id == parent.id }?.parentId == nil)
    }

    @Test func moveFolderValidMoveSucceeds() async throws {
        let (store, index, root) = try await makeTempEnv()
        defer { Task { await cleanup(root, index) } }

        let a = try await store.createFolder(name: "A")
        let b = try await store.createFolder(name: "B")

        // Move B under A — valid, no cycle
        try await store.moveFolder(b.id, newParent: a.id, sortOrder: 0)
        #expect(store.folders.first { $0.id == b.id }?.parentId == a.id)
    }

    @Test func deleteFolderReparentsChildrenAndReturnsOrphans() async throws {
        let (store, index, root) = try await makeTempEnv()
        defer { Task { await cleanup(root, index) } }

        let parent = try await store.createFolder(name: "Parent")
        let child = try await store.createFolder(name: "Child", parent: parent.id)
        let itemId = UUID()
        try await store.addMembership(item: itemId, folder: parent.id)

        let orphaned = try await store.deleteFolder(parent.id)

        // Child reparented to root (parent's parent was nil)
        #expect(store.folders.first { $0.id == child.id }?.parentId == nil)
        // Parent removed
        #expect(!store.folders.contains { $0.id == parent.id })
        // Item had only one membership (in deleted folder) → orphaned
        #expect(orphaned == [itemId])
        #expect(store.membershipCount(item: itemId) == 0)
    }

    // MARK: - Replication

    @Test func addMembershipAndFoldersContaining() async throws {
        let (store, index, root) = try await makeTempEnv()
        defer { Task { await cleanup(root, index) } }

        let f1 = try await store.createFolder(name: "F1")
        let f2 = try await store.createFolder(name: "F2")
        let itemId = UUID()

        try await store.addMembership(item: itemId, folder: f1.id)
        try await store.addMembership(item: itemId, folder: f2.id)

        #expect(store.membershipCount(item: itemId) == 2)
        #expect(Set(store.foldersContaining(item: itemId)) == Set([f1.id, f2.id]))
        #expect(store.items(in: f1.id) == [itemId])

        // Duplicate add is a no-op
        try await store.addMembership(item: itemId, folder: f1.id)
        #expect(store.membershipCount(item: itemId) == 2)
    }

    @Test func removeMembershipRemovedWhenMultiple() async throws {
        let (store, index, root) = try await makeTempEnv()
        defer { Task { await cleanup(root, index) } }

        let f1 = try await store.createFolder(name: "F1")
        let f2 = try await store.createFolder(name: "F2")
        let itemId = UUID()

        try await store.addMembership(item: itemId, folder: f1.id)
        try await store.addMembership(item: itemId, folder: f2.id)

        let result = try await store.removeMembership(item: itemId, folder: f1.id)
        #expect(result == .removed)
        #expect(store.membershipCount(item: itemId) == 1)
        #expect(store.foldersContaining(item: itemId) == [f2.id])
    }

    @Test func removeMembershipWasLastInstanceDoesNotMutate() async throws {
        let (store, index, root) = try await makeTempEnv()
        defer { Task { await cleanup(root, index) } }

        let folder = try await store.createFolder(name: "Only")
        let itemId = UUID()
        try await store.addMembership(item: itemId, folder: folder.id)

        let countBefore = store.memberships.count
        let result = try await store.removeMembership(item: itemId, folder: folder.id)

        #expect(result == .wasLastInstance)
        // State unchanged — the membership was NOT removed
        #expect(store.memberships.count == countBefore)
        #expect(store.membershipCount(item: itemId) == 1)
    }

    @Test func forceRemoveLastMembership() async throws {
        let (store, index, root) = try await makeTempEnv()
        defer { Task { await cleanup(root, index) } }

        let folder = try await store.createFolder(name: "Only")
        let itemId = UUID()
        try await store.addMembership(item: itemId, folder: folder.id)

        try await store.forceRemoveLastMembership(item: itemId, folder: folder.id)
        #expect(store.membershipCount(item: itemId) == 0)
    }

    // MARK: - Templates

    @Test func assignTemplateAndInheritance() async throws {
        let (store, index, root) = try await makeTempEnv()
        defer { Task { await cleanup(root, index) } }

        let parent = try await store.createFolder(name: "Parent")
        let child = try await store.createFolder(name: "Child", parent: parent.id)
        let templateId = UUID()

        // No template assigned yet
        #expect(store.template(for: child.id) == nil)

        // Assign template to parent
        try await store.assignTemplate(templateId, to: parent.id)
        // Child inherits from parent (§16.4 ancestor walk)
        #expect(store.template(for: child.id) == templateId)
        #expect(store.template(for: parent.id) == templateId)

        // Remove the template
        try await store.removeTemplateAssignment(folder: parent.id)
        #expect(store.template(for: parent.id) == nil)
    }

    // MARK: - Organization.json export/round-trip

    @Test func exportAndReloadFromJSON() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("org-store-json-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let dbURL = root.appendingPathComponent("index.db")
        let index = NotesIndex(url: dbURL)
        try await index.open()

        // Create data
        let store1 = OrganizationStore(index: index)
        try await store1.load(storeRoot: root)
        let folder = try await store1.createFolder(name: "Test")
        let itemId = UUID()
        try await store1.addMembership(item: itemId, folder: folder.id)
        let templateId = UUID()
        try await store1.assignTemplate(templateId, to: folder.id)

        // Verify organization.json exists
        let jsonURL = root.appendingPathComponent("organization.json")
        #expect(FileManager.default.fileExists(atPath: jsonURL.path))

        await index.close()

        // Simulate DB wipe: reopen with a new (empty) DB
        let dbURL2 = root.appendingPathComponent("index2.db")
        let index2 = NotesIndex(url: dbURL2)
        try await index2.open()

        let store2 = OrganizationStore(index: index2)
        try await store2.load(storeRoot: root)

        // Should have rebuilt from organization.json
        #expect(store2.folders.contains { $0.id == folder.id && $0.name == "Test" })
        #expect(store2.memberships.contains { $0.itemId == itemId && $0.folderId == folder.id })
        #expect(store2.assignments.contains { $0.folderId == folder.id && $0.templateId == templateId })

        // System folders also present
        #expect(store2.folders.contains { $0.id == OrganizationStore.inboxFolderId })

        await index2.close()
    }

    // MARK: - DB persistence round-trip

    @Test func foldersPersistToDB() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("org-store-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let dbURL = root.appendingPathComponent("index.db")
        let index = NotesIndex(url: dbURL)
        try await index.open()

        let store1 = OrganizationStore(index: index)
        try await store1.load(storeRoot: root)
        let folder = try await store1.createFolder(name: "Persistent")
        let itemId = UUID()
        try await store1.addMembership(item: itemId, folder: folder.id)

        // Close and reopen — loading from DB (not JSON)
        await index.close()
        try await index.open()

        let store2 = OrganizationStore(index: index)
        try await store2.load(storeRoot: root)
        #expect(store2.folders.contains { $0.id == folder.id && $0.name == "Persistent" })
        #expect(store2.membershipCount(item: itemId) == 1)

        await index.close()
    }
}
