import Testing
import Foundation
@testable import ArchiveNotes

/// W6-S3: per-window item-list view model (`NotesNavigationModel`) — kind filtering, sort, selection→
/// detail, generation bumps, instance counts, and the shared-source refresh path. Also stands in for
/// the plan's `NotesTableSnapshotTests` (id-diff) by asserting `displayed.map(\.id)` — the exact list
/// the AppKit diffable data source snapshots.
@MainActor
struct NotesNavigationModelTests {

    private func makeModel() async throws -> (NotesModel, NotesIndex, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-nav-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = NotesIndex(url: root.appendingPathComponent("index.db"))
        try await index.open()
        let store = OrganizationStore(index: index)
        try await store.load(storeRoot: root)
        return (NotesModel(organization: store), index, root)
    }
    private func cleanup(_ root: URL, _ index: NotesIndex) async {
        await index.close(); try? FileManager.default.removeItem(at: root)
    }
    private func sum(_ title: String, kind: Item.Kind, sortDate: Int? = nil, id: UUID = UUID()) -> ItemSummary {
        let t = Date(timeIntervalSince1970: 0)
        return ItemSummary(id: id, title: title, kind: kind, date: nil, datePrecision: nil,
                           dateUncertain: false, authors: [], sortDate: sortDate, quality: nil,
                           created: t, modified: t, mtime: 0, managedTags: [])
    }

    @Test func defaultKindSeededFromWindow() async throws {
        let (model, index, root) = try await makeModel()
        defer { Task { await cleanup(root, index) } }
        #expect(NotesNavigationModel(model: model, defaultKind: .note).kindFilter == .notes)
        #expect(NotesNavigationModel(model: model, defaultKind: .extract).kindFilter == .extracts)
    }

    @Test func kindFilterScopesDisplayed() async throws {
        let (model, index, root) = try await makeModel()
        defer { Task { await cleanup(root, index) } }
        model.replaceItems([sum("n1", kind: .note), sum("e1", kind: .extract), sum("n2", kind: .note)])

        let nav = NotesNavigationModel(model: model, defaultKind: .note)
        #expect(Set(nav.displayed.map(\.title)) == ["n1", "n2"])   // notes only

        nav.kindFilter = .extracts
        #expect(nav.displayed.map(\.title) == ["e1"])

        nav.kindFilter = .both
        #expect(nav.displayed.count == 3)
    }

    @Test func changingKindBumpsGeneration() async throws {
        let (model, index, root) = try await makeModel()
        defer { Task { await cleanup(root, index) } }
        model.replaceItems([sum("n", kind: .note), sum("e", kind: .extract)])
        let nav = NotesNavigationModel(model: model, defaultKind: .note)
        let before = nav.displayedGeneration
        nav.kindFilter = .both
        #expect(nav.displayedGeneration > before)
        // Setting the same value again is a no-op (didSet guards on change).
        let steady = nav.displayedGeneration
        nav.kindFilter = .both
        #expect(nav.displayedGeneration == steady)
    }

    @Test func sortReordersDisplayed() async throws {
        let (model, index, root) = try await makeModel()
        defer { Task { await cleanup(root, index) } }
        model.replaceItems([
            sum("b", kind: .note, sortDate: 20000000),
            sum("a", kind: .note, sortDate: 19000000),
        ])
        let nav = NotesNavigationModel(model: model, defaultKind: .note)
        // Default sort = date asc → 1900 before 2000.
        #expect(nav.displayed.map(\.title) == ["a", "b"])
        nav.setSort([NoteSortDescriptor(field: .date, ascending: false)])
        #expect(nav.displayed.map(\.title) == ["b", "a"])
    }

    @Test func setSortIgnoresEmpty() async throws {
        let (model, index, root) = try await makeModel()
        defer { Task { await cleanup(root, index) } }
        let nav = NotesNavigationModel(model: model, defaultKind: .note)
        nav.setSort([NoteSortDescriptor(field: .title, ascending: false)])
        let current = nav.sort
        nav.setSort([])   // empty → ignored, keeps prior sort
        #expect(nav.sort == current)
    }

    @Test func singleSelectionResolvesDetailSummary() async throws {
        let (model, index, root) = try await makeModel()
        defer { Task { await cleanup(root, index) } }
        let a = sum("a", kind: .note), b = sum("b", kind: .note)
        model.replaceItems([a, b])
        let nav = NotesNavigationModel(model: model, defaultKind: .note)

        nav.select(a.id)
        #expect(nav.selectedItemID == a.id)
        #expect(nav.selectedSummary?.title == "a")

        // Multi-select → no single detail.
        nav.selection = [a.id, b.id]
        #expect(nav.selectedItemID == nil)
        #expect(nav.selectedSummary == nil)

        nav.select(nil)
        #expect(nav.selection.isEmpty)
    }

    @Test func selectionPrunedWhenItemDisappears() async throws {
        let (model, index, root) = try await makeModel()
        defer { Task { await cleanup(root, index) } }
        let gone = sum("gone", kind: .note), stays = sum("stays", kind: .note)
        model.replaceItems([gone, stays])
        let nav = NotesNavigationModel(model: model, defaultKind: .note)
        nav.selection = [gone.id, stays.id]

        // Refresh the shared source without `gone` → the sink recomputes and prunes it.
        model.replaceItems([stays])
        #expect(nav.selection == [stays.id])
        #expect(nav.displayed.map(\.id) == [stays.id])
    }

    @Test func kindFilterPrunesSelectionOfHiddenItem() async throws {
        let (model, index, root) = try await makeModel()
        defer { Task { await cleanup(root, index) } }
        let e = sum("e", kind: .extract)
        model.replaceItems([sum("n", kind: .note), e])
        let nav = NotesNavigationModel(model: model, defaultKind: .note)
        nav.kindFilter = .both      // show both kinds so the extract is visible + selectable
        nav.select(e.id)
        #expect(nav.selectedSummary?.title == "e")
        // Switch to notes-only → the extract is no longer visible, so its selection is dropped.
        nav.kindFilter = .notes
        #expect(nav.selection.isEmpty)
    }

    @Test func replaceItemsRefreshesViaSink() async throws {
        let (model, index, root) = try await makeModel()
        defer { Task { await cleanup(root, index) } }
        let nav = NotesNavigationModel(model: model, defaultKind: .note)
        #expect(nav.displayed.isEmpty)
        model.replaceItems([sum("late", kind: .note)])
        #expect(nav.displayed.map(\.title) == ["late"])   // Combine sink recomputed
    }

    @Test func instanceCountsFromMemberships() async throws {
        let (model, index, root) = try await makeModel()
        defer { Task { await cleanup(root, index) } }
        let multi = sum("multi", kind: .note), single = sum("single", kind: .note)
        model.replaceItems([multi, single])

        let f1 = try await model.organization.createFolder(name: "F1", parent: nil, kind: .normal)
        let f2 = try await model.organization.createFolder(name: "F2", parent: nil, kind: .normal)
        try await model.organization.addMembership(item: multi.id, folder: f1.id)
        try await model.organization.addMembership(item: multi.id, folder: f2.id)
        try await model.organization.addMembership(item: single.id, folder: f1.id)

        let nav = NotesNavigationModel(model: model, defaultKind: .note)
        nav.recompute()   // membership mutation UI is W6-S5; recompute picks up counts here
        #expect(nav.instanceCounts[multi.id] == 2)
        #expect(nav.instanceCounts[single.id] == 1)
    }
}
