// NotesNavigationModel.swift — per-window item-list view model (W6-S3, 06-viewers §3/§9).
//
// The shared `NotesModel` owns the org graph + the single item source (`allItems`); this object is
// per-window (@StateObject inside `NotesBrowserView`) and owns the list state that legitimately
// differs between the Notes and Extracts windows: the kind segmented control, the sort, the
// selection, and the resulting `displayed` list. That split is what lets "two windows share one
// shell but differ by default kind" (06-viewers §1/§3) coexist with the single shared `NotesModel`
// that §16.1 mandates.
//
// W6-S3 scope: kind filter + multi-level sort. Folder-scope intersection, tag/quality/date filters,
// keyword FTS + relevance are W6-S4 (recompute() has a single seam for them).

import Foundation
import Combine

@MainActor
final class NotesNavigationModel: ObservableObject {
    /// Shared source of items + org graph (one instance for both windows). Strong ref is safe: the
    /// shared model never references back, so there is no retain cycle.
    let model: NotesModel

    /// Which kinds this window shows. Seeded from the window's default kind (Notes → `.notes`,
    /// Extracts → `.extracts`); the segmented control flips it live.
    @Published var kindFilter: KindFilter { didSet { if kindFilter != oldValue { recompute() } } }

    /// Active multi-level sort (header-click drives this; `ColumnPickerHeaderView` sets the secondary).
    @Published var sort: [NoteSortDescriptor] = NotesSort.default {
        didSet { if sort != oldValue { recompute() } }
    }

    /// Filtered + sorted items for this window's table.
    @Published private(set) var displayed: [ItemSummary] = []

    /// Bumped whenever `displayed` changes, so the AppKit table rebuilds its O(N) id→row cache and
    /// diffs its snapshot only when needed (mirrors Reader's `NavigationModel.displayedGeneration`).
    @Published private(set) var displayedGeneration = 0

    /// Membership count per item id, for the "instances" column ("▣ N", blank if 1). Recomputed from
    /// the shared org graph each pass; membership mutation UI is W6-S5.
    @Published private(set) var instanceCounts: [UUID: Int] = [:]

    /// Rows selected in the table. A single-row selection loads that item into the detail pane.
    @Published var selection: Set<UUID> = []

    private var cancellables: Set<AnyCancellable> = []

    init(model: NotesModel, defaultKind: ItemKindShell) {
        self.model = model
        self.kindFilter = (defaultKind == .extract) ? .extracts : .notes
        // Recompute whenever the shared item source changes (index load / refresh).
        model.$allItems
            .sink { [weak self] items in self?.recompute(items: items) }
            .store(in: &cancellables)
        recompute()
    }

    // MARK: Selection → detail

    /// The single selected item (nil unless exactly one row is selected), resolved from the shared
    /// item source. The detail pane renders this; multi-select shows no single detail.
    var selectedItemID: UUID? { selection.count == 1 ? selection.first : nil }
    var selectedSummary: ItemSummary? {
        guard let id = selectedItemID else { return nil }
        return model.allItems.first { $0.id == id }
    }

    /// Select a single item (context-menu "Open" / double-click). Loads it into the detail pane.
    func select(_ id: UUID?) {
        selection = id.map { [$0] } ?? []
    }

    // MARK: Sort control (from the table header)

    func setSort(_ descriptors: [NoteSortDescriptor]) {
        guard !descriptors.isEmpty else { return }
        sort = descriptors
    }

    // MARK: Recompute

    /// Rebuild `displayed` from the shared item source: filter by kind (W6-S3), then sort. The
    /// `// FILTER SEAM` marks where W6-S4 layers folder-scope + tag/quality/date + FTS/relevance.
    func recompute(items: [ItemSummary]? = nil) {
        let source = items ?? model.allItems
        let filtered = source.filter { matchesKind($0) }        // FILTER SEAM (W6-S4 extends here)
        let ordered = NotesSort.sorted(filtered, by: sort)

        // Drop selections that no longer exist in the visible set (e.g. after a refresh).
        let visibleIDs = Set(ordered.map(\.id))
        let prunedSelection = selection.intersection(visibleIDs)
        if prunedSelection != selection { selection = prunedSelection }

        instanceCounts = Dictionary(grouping: model.organization.memberships, by: \.itemId)
            .mapValues(\.count)
        displayed = ordered
        displayedGeneration &+= 1
    }

    private func matchesKind(_ item: ItemSummary) -> Bool {
        switch kindFilter {
        case .both: return true
        case .notes: return item.kind == .note
        case .extracts: return item.kind == .extract
        }
    }
}
