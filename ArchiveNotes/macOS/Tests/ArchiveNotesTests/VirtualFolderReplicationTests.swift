// VirtualFolderReplicationTests.swift — §1.5 virtual-folder / replication invariants.
//
// The plan (08 §1.5) sketched a "pure OrganizationGraph value type"; §16.1 (Interface Contract)
// supersedes that — the shipped graph owner is the @MainActor `OrganizationStore` (folders +
// memberships), so these tests exercise it on a SCRATCH temp store (never a corpus; Prime
// Directive #1). Tier-2 focus: the delete-last-instance guard (§3.6/§9) fires EXACTLY on the sole
// remaining membership and is computed WITHOUT mutating — the caller owns the file delete.
// (The on-disk complement — replicate/move/delete against NoteStore — lives in NotesReplicationTests.)
import Testing
import Foundation
@testable import ArchiveNotes

@MainActor
@Suite("VirtualFolderReplication — memberships + replicants + delete-last-instance guard (§1.5)")
struct VirtualFolderReplicationTests {

    private func makeTempEnv() async throws -> (store: OrganizationStore, index: NotesIndex, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vfolder-repl-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = NotesIndex(url: root.appendingPathComponent("index.db"))
        try await index.open()
        let store = OrganizationStore(index: index)
        try await store.load(storeRoot: root)
        return (store, index, root)
    }

    private func cleanup(_ root: URL, _ index: NotesIndex) async {
        await index.close()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Membership count invariants

    @Test func itemInKFoldersHasKMemberships() async throws {
        let (store, index, root) = try await makeTempEnv()
        defer { Task { await cleanup(root, index) } }

        let item = UUID()
        let a = try await store.createFolder(name: "A")
        let b = try await store.createFolder(name: "B")
        let c = try await store.createFolder(name: "C")
        try await store.addMembership(item: item, folder: a.id)
        try await store.addMembership(item: item, folder: b.id)
        try await store.addMembership(item: item, folder: c.id)

        #expect(store.membershipCount(item: item) == 3)
        #expect(Set(store.foldersContaining(item: item)) == Set([a.id, b.id, c.id]))

        // Duplicate add is a no-op — the K invariant holds.
        try await store.addMembership(item: item, folder: b.id)
        #expect(store.membershipCount(item: item) == 3)
    }

    @Test func replicateAddsMembershipRowNotACopy() async throws {
        let (store, index, root) = try await makeTempEnv()
        defer { Task { await cleanup(root, index) } }

        let item = UUID()
        let src = try await store.createFolder(name: "Source")
        let dst = try await store.createFolder(name: "Dest")
        try await store.addMembership(item: item, folder: src.id)

        // "Replicate" into a second folder = one more MEMBERSHIP ROW referencing the SAME item.
        try await store.addMembership(item: item, folder: dst.id)

        #expect(store.foldersContaining(item: item).count == 2)
        let rows = store.memberships.filter { $0.itemId == item }
        #expect(rows.count == 2)
        // Both rows carry the identical itemId — a replicant, never a duplicated item.
        #expect(Set(rows.map { $0.itemId }) == Set([item]))
    }

    // MARK: - Removing replicants vs the last instance

    @Test func removeMembershipRemovesReplicantOnly() async throws {
        let (store, index, root) = try await makeTempEnv()
        defer { Task { await cleanup(root, index) } }

        let item = UUID()
        let a = try await store.createFolder(name: "A")
        let b = try await store.createFolder(name: "B")
        try await store.addMembership(item: item, folder: a.id)
        try await store.addMembership(item: item, folder: b.id)

        let result = try await store.removeMembership(item: item, folder: a.id)
        guard case .removed = result else { Issue.record("expected .removed for a replicant"); return }
        #expect(store.membershipCount(item: item) == 1)
        #expect(store.foldersContaining(item: item) == [b.id])
    }

    @Test func removeLastMembershipSignalsDeleteGuardExactlyOnceAndDoesNotMutate() async throws {
        let (store, index, root) = try await makeTempEnv()
        defer { Task { await cleanup(root, index) } }

        let item = UUID()
        let a = try await store.createFolder(name: "A")
        let b = try await store.createFolder(name: "B")
        let c = try await store.createFolder(name: "C")
        try await store.addMembership(item: item, folder: a.id)
        try await store.addMembership(item: item, folder: b.id)
        try await store.addMembership(item: item, folder: c.id)

        // 3 → 2 and 2 → 1 both stay QUIET (the guard never fires earlier than the last).
        guard case .removed = try await store.removeMembership(item: item, folder: a.id) else {
            Issue.record("3→2 should be .removed"); return
        }
        guard case .removed = try await store.removeMembership(item: item, folder: b.id) else {
            Issue.record("2→1 should be .removed"); return
        }
        #expect(store.membershipCount(item: item) == 1)

        // 1 → 0 fires the guard AND does not mutate — deletion is the caller's decision (§3.6/§9).
        guard case .wasLastInstance = try await store.removeMembership(item: item, folder: c.id) else {
            Issue.record("the sole remaining membership must return .wasLastInstance"); return
        }
        #expect(store.membershipCount(item: item) == 1, "guard must not drop the row")
        #expect(store.foldersContaining(item: item) == [c.id])
    }

    // MARK: - Folder move preserves the membership graph (the clearest §1.5 gap)

    @Test func moveFolderPreservesMembershipGraph() async throws {
        let (store, index, root) = try await makeTempEnv()
        defer { Task { await cleanup(root, index) } }

        let item1 = UUID()
        let item2 = UUID()
        let parent = try await store.createFolder(name: "Parent")
        let child = try await store.createFolder(name: "Child")
        try await store.addMembership(item: item1, folder: child.id)
        try await store.addMembership(item: item2, folder: child.id)

        // Reparent the folder…
        try await store.moveFolder(child.id, newParent: parent.id, sortOrder: 0)
        #expect(store.folders.first { $0.id == child.id }?.parentId == parent.id)

        // …every membership survives the reparent unchanged.
        #expect(store.membershipCount(item: item1) == 1)
        #expect(store.membershipCount(item: item2) == 1)
        #expect(store.foldersContaining(item: item1) == [child.id])
        #expect(store.foldersContaining(item: item2) == [child.id])
        #expect(Set(store.items(in: child.id)) == Set([item1, item2]))
    }

    // MARK: - Smart folder = query, not memberships

    @Test func smartFolderScopeIsQueryNotMembership() async throws {
        let (store, index, root) = try await makeTempEnv()
        defer { Task { await cleanup(root, index) } }

        var query = NotesFilter()
        query.searchText = "invoice"
        query.tags = ["finance"]
        let encoded = String(decoding: try JSONEncoder().encode(query), as: UTF8.self)

        let smart = try await store.createFolder(name: "Invoices", kind: .smart, queryJSON: encoded)
        #expect(smart.kind == .smart)

        // Its scope is the stored query — and it holds ZERO membership rows.
        #expect(store.items(in: smart.id).isEmpty)
        #expect(store.memberships.filter { $0.folderId == smart.id }.isEmpty)

        // The saved query decodes back to the same filter.
        let decoded = try JSONDecoder().decode(NotesFilter.self, from: Data(smart.queryJSON!.utf8))
        #expect(decoded == query)
    }

    // MARK: - Cycle guard on reparent

    @Test func cycleGuardOnReparent() async throws {
        let (store, index, root) = try await makeTempEnv()
        defer { Task { await cleanup(root, index) } }

        let a = try await store.createFolder(name: "A")
        let b = try await store.createFolder(name: "B", parent: a.id)
        let c = try await store.createFolder(name: "C", parent: b.id)

        // Reparent A under its own descendant C → refused (no-op); A stays at the root.
        try await store.moveFolder(a.id, newParent: c.id, sortOrder: 0)
        #expect(store.folders.first { $0.id == a.id }?.parentId == nil)

        // Self-parent is also refused.
        try await store.moveFolder(b.id, newParent: b.id, sortOrder: 0)
        #expect(store.folders.first { $0.id == b.id }?.parentId == a.id)

        // A valid reparent still succeeds (sanity — the guard isn't over-broad).
        try await store.moveFolder(c.id, newParent: a.id, sortOrder: 0)
        #expect(store.folders.first { $0.id == c.id }?.parentId == a.id)
    }
}
