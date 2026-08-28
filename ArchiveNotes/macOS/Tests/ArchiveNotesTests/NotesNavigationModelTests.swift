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

    // MARK: - W6-S4: kind proxy

    @Test func kindFilterProxiesFilterKind() async throws {
        let (model, index, root) = try await makeModel()
        defer { Task { await cleanup(root, index) } }
        let nav = NotesNavigationModel(model: model, defaultKind: .note)
        #expect(nav.filter.kind == .notes)
        nav.kindFilter = .both
        #expect(nav.filter.kind == .both)
        nav.filter.kind = .extracts
        #expect(nav.kindFilter == .extracts)
    }

    // MARK: - W6-S4: folder scope (shared model.scope)

    @Test func folderScopeNarrowsDisplayed() async throws {
        let (model, index, root) = try await makeModel()
        defer { Task { await cleanup(root, index) } }
        let a = sum("a", kind: .note), b = sum("b", kind: .note), c = sum("c", kind: .note)
        model.replaceItems([a, b, c])
        let folder = try await model.organization.createFolder(name: "F", parent: nil, kind: .normal)
        try await model.organization.addMembership(item: a.id, folder: folder.id)
        try await model.organization.addMembership(item: b.id, folder: folder.id)   // c is not a member

        let nav = NotesNavigationModel(model: model, defaultKind: .note)
        #expect(nav.displayed.count == 3)                          // no scope → all notes

        model.setFolderScope(folder.id)                            // scope sink → recompute
        #expect(Set(nav.displayed.map(\.title)) == ["a", "b"])
        model.setAllNotesScope()
        #expect(nav.displayed.count == 3)
    }

    // MARK: - W6-S4: facet filters (quality / date)

    @Test func qualityAndDateFacetsNarrowDisplayed() async throws {
        let (model, index, root) = try await makeModel()
        defer { Task { await cleanup(root, index) } }
        let hi = sumQ("hi", quality: 3, sortDate: 19750000)
        let lo = sumQ("lo", quality: 2, sortDate: 19750000)
        let old = sumQ("old", quality: 3, sortDate: 19500000)
        model.replaceItems([hi, lo, old])
        let nav = NotesNavigationModel(model: model, defaultKind: .note)

        nav.filter.qualities = [3]
        #expect(Set(nav.displayed.map(\.title)) == ["hi", "old"])
        nav.filter.dateFrom = 19700000                            // 1970 onward
        #expect(nav.displayed.map(\.title) == ["hi"])             // old (1950) drops out
    }

    // MARK: - W6-S4: keyword FTS (relevance + intersection + clear)

    @Test func keywordSearchIntersectsAndRanksByRelevance() async throws {
        let (model, index, root) = try await makeModelWithIndex()
        defer { Task { await cleanup(root, index) } }
        let titleHit = UUID(), bodyHit = UUID(), unrelated = UUID()
        // "napoleon" in the TITLE (bm25 weight 10) outranks a body-only mention (weight 1).
        try await index.upsertBatch([
            row(bodyHit, title: "War notes", body: "a passing mention of napoleon here"),
            row(titleHit, title: "Napoleon Bonaparte", body: "empire"),
            row(unrelated, title: "Gardening", body: "tomatoes"),
        ])
        model.replaceItems([
            sum("War notes", kind: .note, id: bodyHit),
            sum("Napoleon Bonaparte", kind: .note, id: titleHit),
            sum("Gardening", kind: .note, id: unrelated),
        ])
        let nav = NotesNavigationModel(model: model, defaultKind: .note)

        nav.searchText = "napoleon"
        await nav.runSearchAwaitingResult()
        #expect(nav.displayed.map(\.id) == [titleHit, bodyHit])   // title-hit first, unrelated excluded
        #expect(nav.sort.first?.field == .relevance)

        nav.searchText = ""
        await nav.runSearchAwaitingResult()
        #expect(nav.displayed.count == 3)                         // keyword cleared → all restored
        #expect(nav.sort.first?.field == .date)                   // relevance dropped
    }

    // MARK: - W6-S4: clear + save-as-smart-folder

    @Test func clearUserFiltersResetsFacetsKeepsKind() async throws {
        let (model, index, root) = try await makeModel()
        defer { Task { await cleanup(root, index) } }
        model.replaceItems([sum("a", kind: .note)])
        let nav = NotesNavigationModel(model: model, defaultKind: .note)
        nav.filter.qualities = [3]
        nav.filter.tags = ["X"]
        nav.searchText = "zzz"
        nav.sort = [NoteSortDescriptor(field: .relevance)]

        nav.clearUserFilters()
        #expect(nav.filter.qualities.isEmpty)
        #expect(nav.filter.tags.isEmpty)
        #expect(nav.searchText == "")
        #expect(nav.kindFilter == .notes)                         // kind preserved
        #expect(nav.sort.first?.field == .date)                   // relevance dropped
    }

    @Test func saveAsSmartFolderPersistsEffectiveQuery() async throws {
        let (model, index, root) = try await makeModel()
        defer { Task { await cleanup(root, index) } }
        let nav = NotesNavigationModel(model: model, defaultKind: .note)
        nav.filter.qualities = [3]
        nav.searchText = "brown"

        await nav.saveAsSmartFolder(named: "My Search")
        let smart = model.organization.folders.first { $0.kind == .smart && $0.name == "My Search" }
        #expect(smart != nil)
        let decoded = smart?.queryJSON
            .flatMap { try? JSONDecoder().decode(NotesFilter.self, from: Data($0.utf8)) }
        #expect(decoded?.qualities == [3])
        #expect(decoded?.searchText == "brown")   // live keyword folded into the durable query
        #expect(decoded?.kind == .notes)          // window kind (user wins over base .both)
    }

    // MARK: - W6-S4 helpers

    private func makeModelWithIndex() async throws -> (NotesModel, NotesIndex, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-fts-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = NotesIndex(url: root.appendingPathComponent("index.db"))
        try await index.open()
        let store = OrganizationStore(index: index)
        try await store.load(storeRoot: root)
        return (NotesModel(organization: store, index: index), index, root)
    }
    private func sumQ(_ title: String, kind: Item.Kind = .note, quality: Int?, sortDate: Int?,
                      id: UUID = UUID()) -> ItemSummary {
        let t = Date(timeIntervalSince1970: 0)
        return ItemSummary(id: id, title: title, kind: kind, date: nil, datePrecision: nil,
                           dateUncertain: false, authors: [], sortDate: sortDate, quality: quality,
                           created: t, modified: t, mtime: 0, managedTags: [])
    }
    private func row(_ id: UUID, title: String, body: String, kind: Item.Kind = .note) -> NoteIndexRow {
        let t = Date(timeIntervalSince1970: 0)
        return NoteIndexRow(id: id, mtime: 0, title: title, kind: kind, tags: "", authors: "",
                            authorsJSON: "[]", body: body, date: nil, datePrecision: nil,
                            dateUncertain: false, sortDate: nil, quality: nil, created: t,
                            modified: t, managedTags: "[]", sourceCount: 0)
    }
}
