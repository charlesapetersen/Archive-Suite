import Testing
import Foundation
@testable import ArchiveNotes

/// W6-S2 tests for `NotesModel`'s folder-tree slice: mutation wiring through the (real, scratch)
/// `OrganizationStore`, tree rebuild, scope selection, and the pure helpers. Mirrors the scratch-env
/// idiom in `OrganizationStoreTests`.
@MainActor
struct NotesModelTests {

    private func makeModel() async throws -> (model: NotesModel, index: NotesIndex, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-model-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = NotesIndex(url: root.appendingPathComponent("index.db"))
        try await index.open()
        let store = OrganizationStore(index: index)
        try await store.load(storeRoot: root)
        return (NotesModel(organization: store), index, root)
    }
    private func cleanup(_ root: URL, _ index: NotesIndex) async {
        await index.close()
        try? FileManager.default.removeItem(at: root)
    }
    private func topLevelNames(_ model: NotesModel) -> [String] { model.normalTree.map(\.name) }

    // MARK: itemsGeneration (W14.4 c — reactive provenance-chip refresh signal)

    @Test func replaceItemsBumpsItemsGeneration() async throws {
        let (model, index, root) = try await makeModel()
        defer { Task { await cleanup(root, index) } }

        // The extract editor gates its reactive chip re-style on inequality of this counter, so every
        // replaceItems (create/rename/delete/reindex) must advance it — even an identical set, so a
        // rename that leaves the summary count unchanged still prompts a chip re-resolve.
        let g0 = model.itemsGeneration
        model.replaceItems([])
        let g1 = model.itemsGeneration
        model.replaceItems([])
        let g2 = model.itemsGeneration
        #expect(g1 != g0)
        #expect(g2 != g1)
    }

    // MARK: create

    @Test func createFolderAppearsInTree() async throws {
        let (model, index, root) = try await makeModel()
        defer { Task { await cleanup(root, index) } }

        let id = await model.createFolder(name: "Research", under: nil)
        #expect(id != nil)
        #expect(topLevelNames(model).contains("Research"))
        #expect(model.statusMessage == nil)
    }

    @Test func createDedupesSiblingNames() async throws {
        let (model, index, root) = try await makeModel()
        defer { Task { await cleanup(root, index) } }

        _ = await model.createFolder(name: "Notes", under: nil)
        _ = await model.createFolder(name: "Notes", under: nil)
        _ = await model.createFolder(name: "notes", under: nil)   // case-insensitive collision
        let names = topLevelNames(model)
        // Collision detection is case-insensitive; the suffixed name preserves the input's case
        // (matches Reader's SavedSearchStore.uniqueName), so "notes" → "notes 3", not "Notes 3".
        #expect(names.contains("Notes"))
        #expect(names.contains("Notes 2"))
        #expect(names.contains("notes 3"))
    }

    @Test func createEmptyNameRejected() async throws {
        let (model, index, root) = try await makeModel()
        defer { Task { await cleanup(root, index) } }

        let before = model.normalTree.count
        let id = await model.createFolder(name: "   \n", under: nil)
        #expect(id == nil)
        #expect(model.statusMessage != nil)
        #expect(model.normalTree.count == before)
    }

    // MARK: rename

    @Test func renameUpdatesTree() async throws {
        let (model, index, root) = try await makeModel()
        defer { Task { await cleanup(root, index) } }

        let id = try #require(await model.createFolder(name: "Draft", under: nil))
        await model.renameFolder(id, to: "Final")
        #expect(topLevelNames(model).contains("Final"))
        #expect(!topLevelNames(model).contains("Draft"))
    }

    // MARK: move

    @Test func moveCycleSurfacesMessageAndNoOps() async throws {
        let (model, index, root) = try await makeModel()
        defer { Task { await cleanup(root, index) } }

        let parent = try #require(await model.createFolder(name: "Parent", under: nil))
        let child = try #require(await model.createFolder(name: "Child", under: parent))
        // Moving Parent under its own Child is a cycle → refused with a message, tree unchanged.
        await model.moveFolder(parent, newParent: child, at: 0)
        #expect(model.statusMessage != nil)
        #expect(model.organization.folders.first { $0.id == parent }?.parentId == nil)
    }

    @Test func moveValidReparents() async throws {
        let (model, index, root) = try await makeModel()
        defer { Task { await cleanup(root, index) } }

        let a = try #require(await model.createFolder(name: "A", under: nil))
        let b = try #require(await model.createFolder(name: "B", under: nil))
        await model.moveFolder(b, newParent: a, at: 0)
        #expect(model.organization.folders.first { $0.id == b }?.parentId == a)
        // B is no longer a top-level node; it nests under A.
        #expect(!topLevelNames(model).contains("B"))
        let aNode = try #require(model.normalTree.first { $0.id == a })
        #expect(aNode.children.map(\.id) == [b])
    }

    // MARK: delete

    @Test func deleteReparentsChildrenToRoot() async throws {
        let (model, index, root) = try await makeModel()
        defer { Task { await cleanup(root, index) } }

        let parent = try #require(await model.createFolder(name: "Parent", under: nil))
        let child = try #require(await model.createFolder(name: "Child", under: parent))
        _ = await model.deleteFolder(parent)
        #expect(!topLevelNames(model).contains("Parent"))
        // Child survives, reparented to root.
        #expect(model.normalTree.contains { $0.id == child })
    }

    @Test func deleteStrandingSoleInstanceItemSetsStatus() async throws {
        let (model, index, root) = try await makeModel()
        defer { Task { await cleanup(root, index) } }

        let folder = try #require(await model.createFolder(name: "Only", under: nil))
        let item = UUID()
        try await model.organization.addMembership(item: item, folder: folder)
        model.rebuild()

        let orphaned = await model.deleteFolder(folder)
        #expect(orphaned == [item])
        #expect(model.statusMessage?.contains("All Notes") == true)
    }

    @Test func deletingSelectedFolderClearsScope() async throws {
        let (model, index, root) = try await makeModel()
        defer { Task { await cleanup(root, index) } }

        let folder = try #require(await model.createFolder(name: "Scoped", under: nil))
        model.setFolderScope(folder)
        #expect(model.scope != nil)
        _ = await model.deleteFolder(folder)
        #expect(model.scope == nil)
        #expect(model.selectedFolderId == nil)
    }

    // MARK: scope

    @Test func scopeSelectionAllNotesVsFolder() async throws {
        let (model, index, root) = try await makeModel()
        defer { Task { await cleanup(root, index) } }

        let folder = try #require(await model.createFolder(name: "F", under: nil))
        model.setFolderScope(folder)
        #expect(model.selectedFolderId == folder)
        #expect(model.scope?.folderId == folder)

        model.setFolderScope(OrganizationStore.allNotesFolderId)   // All-Notes root clears scope
        #expect(model.scope == nil)
        #expect(model.selectedFolderId == nil)
    }

    @Test func applySmartScopeDecodesSavedQuery() async throws {
        let (model, index, root) = try await makeModel()
        defer { Task { await cleanup(root, index) } }

        var query = NotesFilter()
        query.searchText = "silicon valley"
        query.tags = ["meritocracy"]
        let json = String(data: try JSONEncoder().encode(query), encoding: .utf8)!
        let smart = try await model.organization.createFolder(
            name: "SV", parent: nil, kind: .smart, queryJSON: json)
        model.rebuild()

        model.applySmartScope(smart.id)
        #expect(model.selectedSmartId == smart.id)
        #expect(model.scope?.searchText == "silicon valley")
        #expect(model.scope?.tags == ["meritocracy"])
    }

    @Test func applySmartScopeUnreadableDegradesToAllNotes() async throws {
        let (model, index, root) = try await makeModel()
        defer { Task { await cleanup(root, index) } }

        let smart = try await model.organization.createFolder(
            name: "Broken", parent: nil, kind: .smart, queryJSON: "{ not json")
        model.rebuild()
        model.setFolderScope(nil)   // start from a known state

        model.applySmartScope(smart.id)
        #expect(model.scope == nil)                          // degraded to All Notes
        #expect(model.statusMessage?.contains("unreadable") == true)
    }

    // MARK: pure helpers

    @Test func wouldCreateCycleHelper() async throws {
        let (model, index, root) = try await makeModel()
        defer { Task { await cleanup(root, index) } }

        let a = try #require(await model.createFolder(name: "A", under: nil))
        let b = try #require(await model.createFolder(name: "B", under: a))
        #expect(model.wouldCreateCycle(moving: a, to: b))      // into own descendant
        #expect(model.wouldCreateCycle(moving: a, to: a))      // into self
        #expect(!model.wouldCreateCycle(moving: b, to: nil))   // to root — fine
    }
}
