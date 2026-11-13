import SwiftUI
import AppKit
import ArchiveCore
import ArchiveCoreUI

// MARK: - NSViewRepresentable bridge

/// A high-performance AppKit `NSTableView` wrapped for SwiftUI. Replaces the SwiftUI `Table` for
/// the navigation window: virtualized rows (cell reuse), incremental diffable-data-source apply,
/// and AppKit-native column-header sorting. The data model (`NavigationModel.displayed`) and tag
/// mutations (`NavigationModel`) are unchanged — this is a VIEW-layer swap only.
struct AppKitTableView: NSViewRepresentable {
    struct ColumnDefinition {
        let id: String
        let title: String
        let width: CGFloat
        let minWidth: CGFloat
        let maxWidth: CGFloat
        let sortField: SortField?
        /// Gives and takes width when the table's space changes (the tag cloud opening, the window resizing).
        var flexible = false
        /// The name in the header's menu, where a bare ⚑ or ⚠︎ says nothing.
        var menuTitle: String? = nil
        /// The header's tooltip: what the column shows and how it sorts (W40.fix-reader-columns).
        var toolTip = ""

        var chooserTitle: String { menuTitle ?? title }
    }

    /// The page-2 `Classification:` column. Its id predates the column's name, Capture marker.
    static let captureMarkerColumnID = "classification"

    /// One source for construction, the header's menu and tests.
    static let columnDefinitions: [ColumnDefinition] = [
        .init(id: "flag", title: "⚑", width: 26, minWidth: 26, maxWidth: 30, sortField: .flag,
              menuTitle: "⚑ Flag",
              toolTip: "Flag: your own mark for files to come back to. The Reader keeps it; the file is not changed. "
                  + "Click to sort flagged files first; Toggle Flag is in the Tags menu."),
        .init(id: "warning", title: "⚠︎", width: 24, minWidth: 24, maxWidth: 28, sortField: .attention,
              menuTitle: "⚠︎ Needs attention",
              toolTip: "Needs attention: a PDF that could not be opened or has no selectable text. "
                  + "Click to sort these files first; click a file’s warning for its reason and next steps."),
        .init(id: "date", title: "Document date", width: 140, minWidth: 110, maxWidth: 220, sortField: .date,
              toolTip: "The document's own date, from its tags. Click to sort; undated files go last."),
        // File name's and File tags' minimums are what lets every column fit at the 900-pt window beside the
        // default sidebar, Read included (W40.fix-reader-narrow-read-column); `TableColumnFitter` has the sums.
        .init(id: "name", title: "File name", width: 320, minWidth: 140, maxWidth: 800, sortField: .name, flexible: true,
              toolTip: "The file's name. Always shown. Click to sort."),
        .init(id: "type", title: "Type", width: 56, minWidth: 44, maxWidth: 80, sortField: .fileType,
              toolTip: "The file's type, such as PDF or JPEG. Click to sort."),
        .init(id: captureMarkerColumnID, title: "Capture marker", width: 132, minWidth: 100, maxWidth: 220, sortField: nil,
              toolTip: "What the Processor recorded on page 2 when it made the file: Box, Folder, Document Start "
                  + "or Continuation. Files made before the apps have none, so the column is offered only once "
                  + "a file in the library has one. It names the kind of capture, not the box or folder a file is in."),
        .init(id: "tags", title: "File tags", width: 300, minWidth: 100, maxWidth: 600, sortField: .subjects, flexible: true,
              toolTip: "The file's topic tags. Click a cell to edit them; click the header to sort."),
        // Quality holds a 75-pt pop-up inset 1 pt each side, so 78 is the narrowest it fits in. At 72 it overhung
        // its cell, unseen while the column sat scrolled off past the window (W40.fix-reader-tagcloud-width).
        .init(id: "quality", title: "Quality", width: 80, minWidth: 78, maxWidth: 100, sortField: .quality,
              toolTip: "The scan's quality, Q1 (best) to Q3. Choose it in the cell. Click to sort."),
        .init(id: "read", title: "Read", width: 84, minWidth: 70, maxWidth: 110, sortField: .readState,
              toolTip: "Whether you have read the file. Click the cell to change it; click the header to sort."),
    ]

    /// The columns. How they share the width is `TableColumnFitter`'s job, started once the table is in its scroll
    /// view (`fitColumns(of:)`).
    @MainActor
    static func addColumns(to tableView: NSTableView) {
        for col in columnDefinitions {
            let tc = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.id))
            if col.id == "flag" || col.id == "warning" {
                tc.headerCell = IconSortHeaderCell(textCell: col.title)
            }
            tc.title = col.title
            tc.width = col.width
            tc.minWidth = col.minWidth
            tc.maxWidth = col.maxWidth
            tc.resizingMask = .userResizingMask
            tc.headerToolTip = col.toolTip
            if let sf = col.sortField {
                tc.sortDescriptorPrototype = NSSortDescriptor(key: sf.rawValue, ascending: true)
            }
            tableView.addTableColumn(tc)
        }
    }

    /// Start fitting the columns to the scroll view's width (W40.fix-reader-tagcloud-width). The table must
    /// already be the scroll view's document view; the caller keeps the fitter.
    @MainActor
    static func fitColumns(of tableView: NSTableView) -> TableColumnFitter {
        TableColumnFitter(tableView: tableView, flexibleIDs: columnDefinitions.filter(\.flexible).map(\.id))
    }

    @ObservedObject var model: NavigationModel
    @Binding var selection: Set<ArchiveFile.ID>
    var fontSize: CGFloat
    var scrollRequest: Int
    var scrollTargetID: ArchiveFile.ID?
    /// Put `scrollTargetID` at the top of the list rather than just into view (a relaunch's place).
    var scrollTargetAtTop = false
    var onDoubleClick: () -> Void
    var buildContextMenu: (Set<ArchiveFile.ID>) -> NSMenu?
    var onOpenFile: (ArchiveFile) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator

        let scrollView = PixelAlignedScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let tableView = ContextMenuTableView()
        tableView.setAccessibilityIdentifier("ar.table")
        tableView.setAccessibilityLabel("Archive files")
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.rowHeight = max(20, fontSize * 1.8)
        tableView.usesAutomaticRowHeights = true
        tableView.intercellSpacing = NSSize(width: 8, height: 2)
        let headerView = ColumnPickerHeaderView()
        headerView.setAccessibilityIdentifier("ar.table.header")
        headerView.currentSort = { [weak coordinator] in coordinator?.parent.model.sort ?? LibrarySort.default }
        headerView.onSetSecondarySort = { [weak coordinator] field, ascending in
            guard let c = coordinator else { return }
            var sort = c.parent.model.sort
            // Keep the primary, replace/add the secondary
            sort = [sort.first ?? ARSortDescriptor(field: .date, ascending: true),
                    ARSortDescriptor(field: field, ascending: ascending)]
            c.parent.model.sort = sort
        }
        headerView.onRemoveSecondarySort = { [weak coordinator] in
            guard let c = coordinator else { return }
            if let primary = c.parent.model.sort.first {
                c.parent.model.sort = [primary]
            }
        }
        headerView.onResetSort = { [weak coordinator] in
            coordinator?.parent.model.sort = LibrarySort.default
        }
        headerView.isColumnAvailable = { [weak coordinator] id in coordinator?.parent.model.isColumnAvailable(id) ?? true }
        headerView.onSetColumnVisible = { [weak coordinator] id, visible in
            coordinator?.parent.model.setColumn(id, visible: visible)
        }
        tableView.headerView = headerView
        tableView.target = coordinator
        tableView.doubleAction = #selector(Coordinator.tableViewDoubleClicked(_:))
        tableView.contextMenuProvider = { [weak coordinator] selIDs in
            coordinator?.parent.buildContextMenu(selIDs)
        }

        Self.addColumns(to: tableView)

        coordinator.applyHiddenColumns(model.effectiveHiddenColumns, to: tableView)

        scrollView.documentView = tableView
        coordinator.tableView = tableView
        coordinator.observeScrolling(of: scrollView)
        tableView.onUserInput = { [weak coordinator] in coordinator?.parent.model.userMovedInList() }
        tableView.onExtendSelection = { [weak coordinator] in coordinator?.parent.model.extendSelectionInList($0) }
        scrollView.onScrollWheel = tableView.onUserInput
        coordinator.columnFitter = Self.fitColumns(of: tableView)

        let dataSource = SortableDiffableDataSource(tableView: tableView) { tv, column, row, itemID in
            coordinator.makeCell(tableView: tv, column: column, itemID: itemID)
        }
        // Header-click sorting: `sortDescriptorsDidChange` is an NSTableViewDataSource callback, so it
        // must live on the DATA SOURCE (the diffable source is the real dataSource) — not the coordinator,
        // which is only the table's delegate — or header clicks never reach the model. The subclass
        // forwards it to the coordinator here.
        dataSource.onSortDescriptorsChange = { [weak coordinator] descriptors in
            coordinator?.applyHeaderSort(descriptors)
        }
        dataSource.rowViewProvider = { [weak coordinator] tv, _, itemID in
            coordinator?.makeRowView(tableView: tv, itemID: itemID.base as? ArchiveFile.ID) ?? ListRowView()
        }
        coordinator.dataSource = dataSource
        tableView.delegate = coordinator
        tableView.sortDescriptors = sortDescriptorsFromModel()

        coordinator.showRows(model.displayed)
        coordinator.syncSelection(selection)

        return scrollView
    }

    @MainActor
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let tableView = coordinator.tableView else { return }

        coordinator.parent = self

        // Font size
        if coordinator.currentFontSize != fontSize {
            coordinator.currentFontSize = fontSize
            tableView.rowHeight = max(20, fontSize * 1.8)
            let visRange = tableView.rows(in: tableView.visibleRect)
            if visRange.length > 0 {
                tableView.reloadData(forRowIndexes: IndexSet(integersIn: visRange.location..<(visRange.location + visRange.length)),
                                     columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
            } else {
                tableView.reloadData()
            }
        }

        // W40.suite-item-types: a new marker colour redraws the visible names.
        if coordinator.currentMarkerColours != model.itemTypeMarkerColours {
            coordinator.currentMarkerColours = model.itemTypeMarkerColours
            let visRange = tableView.rows(in: tableView.visibleRect)
            if visRange.length > 0 {
                tableView.reloadData(forRowIndexes: IndexSet(integersIn: visRange.location..<(visRange.location + visRange.length)),
                                     columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
            }
        }

        // Only diff the snapshot when `displayed` actually changed.
        let gen = model.displayedGeneration
        var rowsChanged = false
        if coordinator.lastDisplayedGeneration != gen {
            // Only row patches since the rows the table last took: the surviving rows keep their place.
            let onlyPatched = coordinator.lastDisplayedGeneration >= 0
                && model.lastRebuildGeneration <= coordinator.lastDisplayedGeneration
            coordinator.lastDisplayedGeneration = gen
            if coordinator.showRows(model.displayed, orderGeneration: model.displayedOrderGeneration,
                                    keepingPlace: onlyPatched) {
                rowsChanged = true
            } else {
                // IDs unchanged but values may have changed (tag edit, flag toggle) — reload visible rows.
                // Exclude the row with an active tag edit to prevent editor dismissal.
                let visRange = tableView.rows(in: tableView.visibleRect)
                if visRange.length > 0 {
                    var rowSet = IndexSet(integersIn: visRange.location..<(visRange.location + visRange.length))
                    if let editID = coordinator.editingItemID,
                       let editIdx = coordinator.rowByID[editID] {
                        rowSet.remove(editIdx)
                    }
                    if !rowSet.isEmpty {
                        tableView.reloadData(
                            forRowIndexes: rowSet,
                            columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
                    }
                }
            }
        }

        // Search snippets filled in after the hits were listed (W40.fix-reader-fts-snippets): redraw the
        // visible rows that got one, and let them grow by the line.
        if coordinator.lastSnippetFillGeneration != model.snippetFillGeneration {
            coordinator.lastSnippetFillGeneration = model.snippetFillGeneration
            let filled = model.takeFilledSnippetPaths()
            let visRange = tableView.rows(in: tableView.visibleRect)
            if visRange.length > 0 {
                let ids = coordinator.currentSnapshotIDs
                var rowSet = IndexSet((visRange.location..<NSMaxRange(visRange)).filter {
                    $0 < ids.count && filled.contains(ids[$0].path)
                })
                if let editID = coordinator.editingItemID, let editIdx = coordinator.rowByID[editID] {
                    rowSet.remove(editIdx)
                }
                if !rowSet.isEmpty {
                    tableView.reloadData(forRowIndexes: rowSet,
                                         columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
                    tableView.noteHeightOfRows(withIndexesChanged: rowSet)
                }
            }
        }

        // Shown or hidden from the header's menu, or Capture marker's first value arriving.
        if coordinator.applyHiddenColumns(model.effectiveHiddenColumns, to: tableView) {
            coordinator.columnFitter?.fit()
        }

        // Flags live in `FlagStore`, not in the rows, so a toggle leaves `displayedGeneration` alone and the
        // reload above never ran: the ⚑ cell kept its old value (W40.fix-reader-flag).
        coordinator.reloadFlagChanges(model.flags.flagged)

        // Selection sync (SwiftUI → AppKit). Also after the rows change: the highlight is row indices,
        // and a new snapshot shifts or drops them while the model's selection stays the same, so the
        // `lastPushedSelection` check alone left a selection unhighlighted — the "2 selected", nothing highlighted, of
        // `W40.fix-reader-phantom-selection`.
        if rowsChanged || coordinator.lastPushedSelection != selection {
            coordinator.syncSelection(selection)
        }
        if rowsChanged { coordinator.remarkFileOnView() }
        coordinator.markFileOnView(model.fileOnViewPath)

        // Sort descriptors
        let modelDescs = sortDescriptorsFromModel()
        if tableView.sortDescriptors != modelDescs {
            coordinator.isSortingFromModel = true
            tableView.sortDescriptors = modelDescs
            coordinator.isSortingFromModel = false
        }

        // Scroll-to-row (keyboard triage)
        if coordinator.lastScrollRequest != scrollRequest, let target = scrollTargetID {
            coordinator.lastScrollRequest = scrollRequest
            if let idx = coordinator.rowByID[target] {
                tableView.scrollRowToVisible(idx)
                if scrollTargetAtTop { coordinator.scrollRowToTop(idx, in: scrollView) }
            }
        }
    }

    private func sortDescriptorsFromModel() -> [NSSortDescriptor] {
        model.sort.map { NSSortDescriptor(key: $0.field.rawValue, ascending: $0.ascending) }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDelegate, NSTokenFieldDelegate {
        var parent: AppKitTableView
        weak var tableView: NSTableView?
        var dataSource: NSTableViewDiffableDataSource<Int, ArchiveFile.ID>?
        var currentFontSize: CGFloat = 13
        var currentMarkerColours = ItemTypeColors.none
        var lastPushedSelection: Set<ArchiveFile.ID> = []
        var isUpdatingSelection = false
        var isSortingFromModel = false
        var lastScrollRequest = 0
        var lastDisplayedGeneration: Int = -1
        var lastSnippetFillGeneration: Int = 0
        private(set) var currentSnapshotIDs: [ArchiveFile.ID] = []
        /// Each id's row in `currentSnapshotIDs`, rebuilt only when the snapshot changes.
        private(set) var rowByID: [ArchiveFile.ID: Int] = [:]
        /// The displayed generation the table last took. A tag edit keeps every id in place, so it only
        /// swaps this copy-on-write array and rebuilds nothing; the id→file dictionary it used to
        /// rebuild cost ~110 ms per edit at 116k rows (W40.fix-reader-list-recompute-at-size).
        private(set) var rows: [ArchiveFile] = []
        var editingItemID: ArchiveFile.ID?
        /// A new set or order of rows arrived while a tag cell was being edited, and waits for the edit to end.
        private var rowsWaitingForEdit = false
        var columnFitter: TableColumnFitter?

        init(_ parent: AppKitTableView) {
            self.parent = parent
            self.currentFontSize = parent.fontSize
        }

        /// Take a displayed generation; a new snapshot is applied only when its ids differ from the
        /// current one. Returns whether they did.
        // MARK: Place in the list (W40.fix-reader-restore-scroll)

        /// Report the top row after each scroll, so a relaunch can return to it, and tell the model when
        /// the user scrolls, so a place still being restored stops pulling the list back. Selector
        /// observers, which the notification center drops by itself when the coordinator goes.
        func observeScrolling(of scrollView: NSScrollView) {
            scrollView.contentView.postsBoundsChangedNotifications = true
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(clipBoundsChanged(_:)),
                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
            center.addObserver(self, selector: #selector(liveScrollStarted(_:)),
                               name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        }

        @objc private func clipBoundsChanged(_ note: Notification) {
            guard let clip = note.object as? NSClipView else { return }
            noteTopRow(in: clip)
        }

        @objc private func liveScrollStarted(_ note: Notification) { parent.model.userMovedInList() }

        /// The first row under the top edge of the visible area (below the header, if it overlaps).
        private func topRow(in clip: NSClipView) -> Int? {
            guard let tableView else { return nil }
            let row = tableView.row(at: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + clip.contentInsets.top))
            return row >= 0 && row < currentSnapshotIDs.count ? row : nil
        }

        private func noteTopRow(in clip: NSClipView) {
            guard let row = topRow(in: clip) else { return }
            parent.model.noteTopVisibleRow(currentSnapshotIDs[row])
        }

        /// Scroll so `row` is the first one shown, as far as the list's length allows.
        func scrollRowToTop(_ row: Int, in scrollView: NSScrollView) {
            guard let tableView else { return }
            let clip = scrollView.contentView
            var bounds = clip.bounds
            bounds.origin.y = tableView.rect(ofRow: row).minY - clip.contentInsets.top
            clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
            scrollView.reflectScrolledClipView(clip)
        }

        @discardableResult
        /// `orderGeneration` is the model's `displayedOrderGeneration`. While it is the one the snapshot was
        /// last checked at, the rows were only replaced in place, so comparing every id (79 ms at 116k rows,
        /// W40.reader-scale-measure) is skipped. nil always compares. `keepingPlace`: rows left or came in a list
        /// that kept its order, and the rows that stay keep their place on screen (`keepPlace`).
        func showRows(_ files: [ArchiveFile], orderGeneration: Int? = nil, keepingPlace: Bool = false) -> Bool {
            let sameOrder = orderGeneration != nil && orderGeneration == checkedOrderGeneration
                && files.count == currentSnapshotIDs.count
            let idsChanged = !sameOrder && (files.count != currentSnapshotIDs.count
                || !zip(files, currentSnapshotIDs).allSatisfy { $0.id == $1 })
            // Return writes a tag cell's tags while it is still being edited (W40.fix-reader-tag-entry), and that
            // write can move or drop rows: a sort by tags, a tag filter. A new snapshot then would reload the cell
            // under its field editor, and the cell, reused for another row, would keep this file's id and tokens,
            // so the next tag typed would go to a file other than the one on screen. Rows and snapshot stay as
            // they are until the edit ends (`catchUpRows`).
            if idsChanged, editingItemID != nil {
                rowsWaitingForEdit = true
                return false
            }
            rows = files
            if idsChanged {
                let place = keepingPlace ? visiblePlace() : []
                applySnapshot(files.map(\.id), animated: false)
                keepPlace(place)
            }
            checkedOrderGeneration = orderGeneration
            return idsChanged
        }

        /// The rows on screen, top first, each with how far below the top of the visible area it starts.
        private func visiblePlace() -> [(id: ArchiveFile.ID, offset: CGFloat)] {
            guard let tableView, let clip = tableView.enclosingScrollView?.contentView else { return [] }
            let visible = tableView.rows(in: clip.bounds)
            guard visible.location != NSNotFound else { return [] }
            return (visible.location..<min(NSMaxRange(visible), currentSnapshotIDs.count)).map {
                (currentSnapshotIDs[$0], tableView.rect(ofRow: $0).minY - clip.bounds.minY)
            }
        }

        /// Point 12 of the owner's notes of 2026-11-10 (W40.reader-selection-current): when rows leave, the first row
        /// that was on screen and is still listed holds the list in place, so the rows around the ones that left do
        /// not jump: it stays where it was, or, when the rows above it on screen left, it moves up to where the first
        /// of them was, as the rows below a row that left close up. Nothing stays: the scroll is left as it is.
        private func keepPlace(_ place: [(id: ArchiveFile.ID, offset: CGFloat)]) {
            guard let tableView, let scrollView = tableView.enclosingScrollView, let offset = place.first?.offset,
                  let row = place.lazy.compactMap({ self.rowByID[$0.id] }).first
            else { return }
            let clip = scrollView.contentView
            var bounds = clip.bounds
            bounds.origin.y = tableView.rect(ofRow: row).minY - offset
            let origin = clip.constrainBoundsRect(bounds).origin
            guard origin != clip.bounds.origin else { return }
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
        }

        /// The `displayedOrderGeneration` at which the snapshot last matched the model's rows.
        private var checkedOrderGeneration: Int?

        /// The hidden columns the table last took.
        private var appliedHiddenColumns: Set<String>?

        /// Hide exactly `hidden`'s columns; returns whether any column changed.
        @discardableResult
        func applyHiddenColumns(_ hidden: Set<String>, to tableView: NSTableView) -> Bool {
            guard hidden != appliedHiddenColumns else { return false }
            appliedHiddenColumns = hidden
            var changed = false
            for col in tableView.tableColumns {
                let hide = hidden.contains(col.identifier.rawValue) && col.identifier.rawValue != "name"
                if col.isHidden != hide { col.isHidden = hide; changed = true }
            }
            return changed
        }

        /// The flagged set the table last drew.
        private var lastFlagged: Set<String>?

        /// Redraw the ⚑ cell of every row whose flag changed since the last call, and return those rows. Only
        /// the flag column is reloaded, so a tag cell being edited keeps its field editor.
        @discardableResult
        func reloadFlagChanges(_ flagged: Set<String>) -> IndexSet {
            defer { lastFlagged = flagged }
            guard let last = lastFlagged, last != flagged, let tableView else { return [] }
            let column = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("flag"))
            guard column >= 0 else { return [] }
            let changed = last.symmetricDifference(flagged)
            let rowSet = IndexSet(currentSnapshotIDs.indices.filter { changed.contains(currentSnapshotIDs[$0].path) })
            if !rowSet.isEmpty {
                tableView.reloadData(forRowIndexes: rowSet, columnIndexes: IndexSet(integer: column))
            }
            return rowSet
        }

        /// The file shown under `id`, or nil when `rows` and the snapshot disagree about it.
        func file(for id: ArchiveFile.ID) -> ArchiveFile? {
            guard let i = rowByID[id], i < rows.count, rows[i].id == id else { return nil }
            return rows[i]
        }

        func applySnapshot(_ ids: [ArchiveFile.ID], animated: Bool) {
            guard ids != currentSnapshotIDs else { return }
            currentSnapshotIDs = ids
            rowByID = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            var snapshot = NSDiffableDataSourceSnapshot<Int, ArchiveFile.ID>()
            snapshot.appendSections([0])
            snapshot.appendItems(ids, toSection: 0)
            // A selection change the apply itself reports is the table shifting or trimming row
            // indices, not the user choosing rows; written back it would retarget the model's selection
            // to whatever rows slid under the old indices. The caller re-pushes the model's selection
            // afterwards (`W40.fix-reader-phantom-selection`).
            isUpdatingSelection = true
            defer { isUpdatingSelection = false }
            dataSource?.apply(snapshot, animatingDifferences: animated)
        }

        func syncSelection(_ sel: Set<ArchiveFile.ID>) {
            guard let tableView else { return }
            isUpdatingSelection = true
            defer { isUpdatingSelection = false; lastPushedSelection = sel }
            var indexSet = IndexSet()
            for id in sel { if let i = rowByID[id] { indexSet.insert(i) } }
            // The cursor goes in last, so the table's last selected row is the model's cursor and a plain arrow
            // moves on from it (W40.reader-selection-current).
            if indexSet.count > 1, let cursor = parent.model.selectionCursor.flatMap({ rowByID[$0] }), indexSet.contains(cursor) {
                tableView.selectRowIndexes(indexSet.subtracting(IndexSet(integer: cursor)), byExtendingSelection: false)
                tableView.selectRowIndexes(IndexSet(integer: cursor), byExtendingSelection: true)
            } else {
                tableView.selectRowIndexes(indexSet, byExtendingSelection: false)
            }
        }

        // MARK: The file on view (W40.reader-selection-current)

        /// The path the rows were last marked for.
        private var markedOnView: String?

        /// The rows moved under the row views: mark them again.
        func remarkFileOnView() {
            let path = markedOnView
            markedOnView = nil
            markFileOnView(path)
        }

        /// Mark the row showing `path` "on view", and unmark the rest, on the row views the table holds now; a row
        /// view made later is marked as it is made (`makeRowView`).
        func markFileOnView(_ path: String?) {
            guard path != markedOnView, let tableView else { return }
            let previous = markedOnView
            markedOnView = path
            let ids = currentSnapshotIDs
            var changed = IndexSet()
            tableView.enumerateAvailableRowViews { rowView, row in
                guard let rowView = rowView as? ListRowView, row < ids.count else { return }
                let onView = self.isOnView(ids[row], path)
                if onView || self.isOnView(ids[row], previous) { changed.insert(row) }
                rowView.isOnView = onView
            }
            // The name cells of the rows that changed say "on view" again (`makeCell`). Only that column is
            // reloaded, so a tag cell being edited keeps its field editor.
            let column = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
            if column >= 0, !changed.isEmpty {
                tableView.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: column))
            }
        }

        private func isOnView(_ id: ArchiveFile.ID, _ path: String?) -> Bool {
            guard let path else { return false }
            return file(for: id)?.path == path
        }

        /// The diffable data source's row view provider: the table asks it, not the delegate.
        func makeRowView(tableView: NSTableView, itemID: ArchiveFile.ID?) -> NSTableRowView {
            let rowView = tableView.makeView(withIdentifier: ListRowView.reuseID, owner: nil) as? ListRowView ?? ListRowView()
            rowView.identifier = ListRowView.reuseID
            rowView.isOnView = itemID.map { isOnView($0, markedOnView) } ?? false
            return rowView
        }

        // MARK: Cell factory

        func makeCell(tableView: NSTableView, column: NSTableColumn, itemID: ArchiveFile.ID) -> NSView {
            let colID = column.identifier.rawValue
            let file = self.file(for: itemID)

            // Tags column: inline-editable NSTokenField cell
            if colID == "tags" {
                return makeTagTokenCell(tableView: tableView, itemID: itemID, file: file)
            }
            if colID == "quality" {
                return makeQualityMenuCell(tableView: tableView, file: file)
            }

            let cellID = NSUserInterfaceItemIdentifier("cell.\(colID)")
            let cell: TintedTextCellView
            if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? TintedTextCellView {
                cell = reused
            } else {
                if colID == "warning" || colID == "date" {
                    cell = Self.installLabel(in: FileHealthCellView(), identifier: cellID)
                } else {
                    cell = colID == "read" ? Self.makeReadStateCell(identifier: cellID) : Self.makeTextCell(identifier: cellID)
                }
            }

            guard let file else {
                (cell as? FileHealthCellView)?.configure(detail: nil, onAction: { _ in })
                cell.textField?.stringValue = ""
                (cell as? ReadStateCellView)?.file = nil
                return cell
            }

            let tf = cell.textField!
            let regularFont = NSFont.systemFont(ofSize: currentFontSize)
            tf.font = regularFont
            cell.tint = nil
            tf.textColor = .labelColor
            tf.toolTip = nil
            tf.setAccessibilityLabel(nil)
            tf.setAccessibilityIdentifier("ar.cell.\(colID).\(itemID.path)")

            switch colID {
            case "flag":
                let flagged = parent.model.flags.isFlagged(file.path)
                tf.stringValue = flagged ? "⚑" : ""
                tf.setAccessibilityLabel(flagged ? "Flagged" : "Not flagged")
                cell.tint = flagged ? ReaderColors.warningCellTint : nil

            case "warning":
                if let status = parent.model.formatStatus(for: file.path), status.needsAttention {
                    tf.stringValue = "⚠"
                    cell.tint = ReaderColors.warningCellTint
                    tf.toolTip = status.label
                    tf.setAccessibilityLabel("OCR warning")
                } else {
                    tf.stringValue = ""
                    tf.setAccessibilityLabel("No OCR warning")
                }

            case "date":
                let calendar = parent.model.displayCalendar(for: file)   // W24.cal1-reader; nil = as tagged
                let dateText = file.dateCellText(in: calendar)
                tf.toolTip = file.storedDateTooltip(in: calendar)
                // W40.fix-reader-date-ambiguity: two tags for one date facet are flagged on the row, and the
                // tooltip names the one the last-wins rule set aside.
                if let ambiguity = file.dateAmbiguityText {
                    tf.stringValue = dateText + " \u{26A0}\u{FE0E}"
                    tf.toolTip = [ambiguity, tf.toolTip].compactMap { $0 }.joined(separator: "\n")
                    tf.setAccessibilityLabel("\(dateText), ambiguous date. \(ambiguity)")
                    cell.tint = ReaderColors.warningCellTint
                } else {
                    tf.stringValue = dateText
                }
                tf.textColor = file.sortDate == nil ? .secondaryLabelColor : .labelColor
                if file.dateCellIsSpeculative {
                    tf.font = NSFontManager.shared.convert(regularFont, toHaveTrait: .italicFontMask)
                }

            case "name":
                // W40.suite-item-types: the type's marker is the user's colour for it, or the type's name.
                let type = file.itemType
                let dotColor = type.flatMap { parent.model.itemTypeMarkerColours.colour(for: $0) }
                    .map(ItemTypePreferences.nsColor)
                let disambiguator = parent.model.isDuplicatedName(file.name)
                    ? DuplicateNames.disambiguator(for: file.url) : nil
                Self.configureNameTextField(tf, name: file.name, dotColor: dotColor,
                                            typeLabel: dotColor == nil ? type?.displayName : nil,
                                            disambiguator: disambiguator,
                                            snippet: parent.model.searchSnippet(for: file.path),
                                            fontSize: currentFontSize)
                // VoiceOver reads a row by its cells, so the name says it too (W40.reader-selection-current).
                if file.path == markedOnView { tf.setAccessibilityLabel("\(file.name), on view") }

            case "type":
                tf.stringValue = file.fileType
                cell.tint = ReaderColors.informationalCellTint

            case "classification":
                Self.configureProvenanceTextField(
                    tf, classification: parent.model.classification(for: file.path),
                    fontSize: currentFontSize
                )

            case "read":
                Self.configureReadStateCell(cell, state: file.readState)
                if let readCell = cell as? ReadStateCellView {
                    readCell.file = file
                    readCell.onAction = { [weak self] action, file in self?.performReadAction(action, on: file) }
                }
                tf.toolTip = "Click to switch Read and Unread · right-click for more"

            default:
                tf.stringValue = ""
            }

            if let healthCell = cell as? FileHealthCellView {
                let detail = FileHealthDetail(file: file, status: parent.model.formatStatus(for: file.path))
                let hasWarning = colID == "warning" ? detail.pdfIssue != nil : file.dateIsAmbiguous
                if hasWarning {
                    healthCell.configure(detail: detail) { [weak self] action in
                        guard let self else { return }
                        // The popover acts on the file it names, even after cell reuse or a selection change.
                        switch action {
                        case .openDocument: self.parent.onOpenFile(file)
                        case .revealInFinder: NSWorkspace.shared.activateFileViewerSelecting([file.url])
                        case .editInfo:
                            guard self.parent.model.displayed.contains(where: { $0.id == file.id }) else { return }
                            self.parent.model.selection = [file.id]
                            self.parent.model.showingEditor = true
                        }
                    }
                } else {
                    healthCell.configure(detail: nil, onAction: { _ in })
                }
            }
            return cell
        }

        /// The actual in-table Quality editor. The former SwiftUI `QualityCell` stopped being part of
        /// the rendered hierarchy when this list moved to AppKit, so keeping its menu alone would leave
        /// the visible Quality column read-only. This popup keeps the one-file edit path beside the
        /// value it changes and still routes every selection through `NavigationModel.applyEdit` →
        /// `TagWriter`.
        private func makeQualityMenuCell(tableView: NSTableView, file: ArchiveFile?) -> NSView {
            let cellID = NSUserInterfaceItemIdentifier("cell.quality")
            let cell: NSTableCellView
            let menu: QualityPopUpButton
            if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView,
               let existing = reused.subviews.compactMap({ $0 as? QualityPopUpButton }).first {
                cell = reused
                menu = existing
            } else {
                cell = NSTableCellView()
                cell.identifier = cellID
                menu = QualityPopUpButton(frame: .zero, pullsDown: false)
                menu.translatesAutoresizingMaskIntoConstraints = false
                menu.controlSize = .small
                menu.target = self
                menu.action = #selector(qualityMenuChanged(_:))
                cell.addSubview(menu)
                NSLayoutConstraint.activate([
                    menu.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 1),
                    menu.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -1),
                    menu.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }

            menu.removeAllItems()
            // Item index n is quality n (0 = None), which `qualityMenuChanged` relies on.
            for value in [nil] + QualityLevels.all.map(Optional.some) {
                menu.addItem(withTitle: value.map { "Q\($0)" } ?? "None")
            }
            guard let file else {
                menu.isEnabled = false
                menu.file = nil
                menu.setAccessibilityIdentifier("")
                return cell
            }

            menu.isEnabled = true
            menu.file = file
            menu.selectItem(at: (file.quality ?? 0))
            menu.toolTip = "Set this file's quality"
            menu.setAccessibilityIdentifier("ar.quality.menu.\(file.name)")
            menu.setAccessibilityLabel("Quality for \(file.name)")
            return cell
        }

        @objc private func qualityMenuChanged(_ sender: QualityPopUpButton) {
            guard let file = sender.file else { return }
            let quality = sender.indexOfSelectedItem == 0 ? nil : sender.indexOfSelectedItem
            parent.model.applyEdit(.setQuality(quality), to: file)
        }

        /// The Read cell's gestures write through the same `TagWriter` read-state path as ⌘R and ⌘U, for
        /// the one file the cell shows (W40.fix-reader-read-toggle).
        private func performReadAction(_ action: ReadStateCellView.Action, on file: ArchiveFile) {
            switch action {
            case .toggle: parent.model.toggleReadState(for: file)
            case .set(let state): parent.model.setReadStateInline(state, for: file)
            case .clear: parent.model.clearReadState(for: file)
            }
        }

        /// A plain text cell (every column but tags and quality), exposed internally so the headless
        /// pixel guard lays out the same view the table does.
        static func makeTextCell(identifier: NSUserInterfaceItemIdentifier) -> TintedTextCellView {
            installLabel(in: TintedTextCellView(), identifier: identifier)
        }

        /// The Read column's text cell, which also takes the column's click and right-click.
        static func makeReadStateCell(identifier: NSUserInterfaceItemIdentifier) -> ReadStateCellView {
            installLabel(in: ReadStateCellView(), identifier: identifier)
        }

        private static func installLabel<Cell: TintedTextCellView>(in cell: Cell,
                                                                   identifier: NSUserInterfaceItemIdentifier) -> Cell {
            cell.identifier = identifier
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingMiddle
            tf.cell?.truncatesLastVisibleLine = true
            cell.addSubview(tf)
            cell.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                tf.topAnchor.constraint(greaterThanOrEqualTo: cell.topAnchor, constant: 2),
                tf.bottomAnchor.constraint(lessThanOrEqualTo: cell.bottomAnchor, constant: -2),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        /// Small labels need AA text contrast even on the selected row. Weight distinguishes Unread without
        /// relying on the system accent, whose contrast against an ordinary row can be below 4.5:1.
        static func configureReadStateCell(_ cell: TintedTextCellView, state: ReadState?) {
            cell.textField?.stringValue = state?.rawValue ?? "—"
            let size = cell.textField?.font?.pointSize ?? NSFont.systemFontSize
            cell.textField?.font = .systemFont(ofSize: size, weight: state == .unread ? .semibold : .regular)
            cell.tint = ReaderColors.informationalCellTint
        }

        /// The Name cell's formatter, exposed internally so the headless pixel guard renders the same
        /// field the table draws. W40.fix-reader-long-name-overrun: under `usesAutomaticRowHeights` the
        /// field's default horizontal compression resistance beat the column's width, so a long name's
        /// field grew to the whole name (934 pt in a 320-pt column) and drew across Type and File tags.
        /// The field now yields horizontally, and every line carries its own truncating paragraph style
        /// (an `attributedStringValue` without one ignores the field's `lineBreakMode`: no ellipsis).
        static func configureNameTextField(_ tf: NSTextField, name: String, dotColor: NSColor?,
                                           typeLabel: String? = nil,
                                           disambiguator: String?, snippet: [SearchSnippet.Segment]?,
                                           fontSize: CGFloat) {
            let nameLine = NSMutableAttributedString()
            if let dotColor {
                nameLine.append(NSAttributedString(string: "● ", attributes: [
                    .foregroundColor: dotColor,
                    .font: NSFont.systemFont(ofSize: fontSize * 0.7),
                ]))
            } else if let typeLabel {
                nameLine.append(NSAttributedString(string: "\(typeLabel) · ", attributes: [
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .font: NSFont.systemFont(ofSize: fontSize * 0.85, weight: .medium),
                ]))
            }
            nameLine.append(NSAttributedString(string: name, attributes: [
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.systemFont(ofSize: fontSize),
            ]))
            if let disambiguator {
                nameLine.append(NSAttributedString(string: "  ⌕ \(disambiguator)", attributes: [
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .font: NSFont.systemFont(ofSize: fontSize * 0.85),
                ]))
            }
            // The name middle-truncates (extension visible); a snippet line below it tail-truncates.
            let nameStyle = NSMutableParagraphStyle()
            nameStyle.lineBreakMode = .byTruncatingMiddle
            nameLine.addAttribute(.paragraphStyle, value: nameStyle,
                                  range: NSRange(location: 0, length: nameLine.length))
            // The field must never ask for more width than its column gives it.
            tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            if let snippet {
                // Full-text search hit: add a dimmed keyword-in-context OCR excerpt beneath the name
                // (usesAutomaticRowHeights grows the row).
                nameLine.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: nameStyle]))
                nameLine.append(snippetLine(snippet, baseSize: fontSize))
                // Put the field into the same multi-line-capable state the tags cell (TagTokenCellView)
                // needs, so `usesAutomaticRowHeights` actually grows the row. A `labelWithString:` field
                // is single-line by default (`usesSingleLineMode`/`wraps=false`), so the appended second
                // line + "\n" was being clipped and the row never grew — the snippet was invisible.
                tf.usesSingleLineMode = false
                (tf.cell as? NSTextFieldCell)?.wraps = true
                (tf.cell as? NSTextFieldCell)?.isScrollable = false
                tf.setContentCompressionResistancePriority(.required, for: .vertical)
                tf.maximumNumberOfLines = 2
                tf.lineBreakMode = .byTruncatingTail
            } else {
                // Reset to single-line: cells are reused, so a row that was a 2-line hit may now
                // render a non-hit row.
                tf.usesSingleLineMode = true
                (tf.cell as? NSTextFieldCell)?.wraps = false
                tf.maximumNumberOfLines = 1
                tf.lineBreakMode = .byTruncatingMiddle
            }
            tf.attributedStringValue = nameLine
        }

        /// The dimmed keyword-in-context second line for a full-text hit: matched OCR terms emphasised
        /// (bold + a faint yellow wash) against secondary-color context. All-adaptive colors so it reads
        /// in light and dark mode; the whole line tail-truncates.
        static func snippetLine(_ segments: [SearchSnippet.Segment], baseSize: CGFloat) -> NSAttributedString {
            let size = max(9, baseSize * 0.85)
            let base = NSFont.systemFont(ofSize: size)
            let bold = NSFont.boldSystemFont(ofSize: size)
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            let out = NSMutableAttributedString()
            for seg in segments {
                var attrs: [NSAttributedString.Key: Any] = [.paragraphStyle: style]
                if seg.isMatch {
                    attrs[.font] = bold
                    attrs[.foregroundColor] = NSColor.labelColor
                    attrs[.backgroundColor] = NSColor.systemYellow.withAlphaComponent(0.30)
                } else {
                    attrs[.font] = base
                    attrs[.foregroundColor] = NSColor.secondaryLabelColor
                }
                out.append(NSAttributedString(string: seg.text, attributes: attrs))
            }
            return out
        }

        /// The actual provenance-cell formatter, exposed internally so the headless pixel guard renders
        /// the same AppKit control and styling the table uses rather than a look-alike test view.
        static func configureProvenanceTextField(_ textField: NSTextField,
                                                 classification: String?, fontSize: CGFloat) {
            textField.stringValue = classification ?? "—"
            textField.font = NSFont.systemFont(ofSize: fontSize)
            textField.textColor = .secondaryLabelColor
            textField.lineBreakMode = .byTruncatingTail
            textField.toolTip = classification
        }

        // MARK: NSTableViewDelegate

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdatingSelection, let tableView else { return }
            parent.model.userMovedInList()
            let indices = tableView.selectedRowIndexes
            var newSel = Set<ArchiveFile.ID>()
            for i in indices {
                if i < currentSnapshotIDs.count {
                    newSel.insert(currentSnapshotIDs[i])
                }
            }
            lastPushedSelection = newSel
            parent.selection = newSel
            // The cursor is the row the table last selected; the other end, the selected row farthest from it.
            let last = tableView.selectedRow
            let cursor = last >= 0 && last < currentSnapshotIDs.count && indices.contains(last) ? last : nil
            let otherEnd = cursor.flatMap { c in [indices.first, indices.last].compactMap { $0 }.max { abs($0 - c) < abs($1 - c) } }
            parent.model.noteSelectionEnds(cursor: cursor.map { currentSnapshotIDs[$0] },
                                           otherEnd: otherEnd.map { currentSnapshotIDs[$0] })
        }

        /// Applies a header-click sort to the model. Invoked from `SortableDiffableDataSource`'s forwarded
        /// `sortDescriptorsDidChange` (that callback must live on the data source, not the delegate). The
        /// `isSortingFromModel` guard stops the model→table push (updateNSView) from feeding back.
        func applyHeaderSort(_ descriptors: [NSSortDescriptor]) {
            guard !isSortingFromModel else { return }
            let descs = descriptors.compactMap { sd -> ARSortDescriptor? in
                guard let key = sd.key, let field = SortField(rawValue: key) else { return nil }
                return ARSortDescriptor(field: field, ascending: sd.ascending)
            }
            if !descs.isEmpty {
                parent.model.sort = descs
            }
        }

        @objc func tableViewDoubleClicked(_ sender: Any?) {
            guard let tableView, tableView.clickedRow >= 0 else { return }
            parent.onDoubleClick()
        }

        // MARK: Inline tag editing (NSTokenFieldDelegate)

        private func makeTagTokenCell(tableView: NSTableView, itemID: ArchiveFile.ID, file: ArchiveFile?) -> NSView {
            let cellID = NSUserInterfaceItemIdentifier("cell.tags.token")
            let tagCell: TagTokenCellView
            if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? TagTokenCellView {
                tagCell = reused
            } else {
                tagCell = TagTokenCellView()
                tagCell.identifier = cellID
                tagCell.tokenField.delegate = self
            }
            // Freeze during edit: don't clobber the in-progress token field or its target file.
            if tagCell.tokenField.currentEditor() == nil {
                tagCell.tokenField.objectValue = file?.subjects ?? []
                tagCell.itemID = itemID
                tagCell.editBase = nil
            }
            tagCell.tokenField.font = .systemFont(ofSize: currentFontSize)
            // Per-row accessibility id so XCUITest can target a specific row's tag cell
            tagCell.tokenField.setAccessibilityIdentifier("ar.cell.tags.\(file?.name ?? "")")
            // Named, so a row with no subjects (a Box or Folder item, whose type is its own field since
            // W40.suite-item-types) still describes its empty field.
            tagCell.tokenField.setAccessibilityLabel("File tags")
            return tagCell
        }

        func tokenField(_ tokenField: NSTokenField, completionsForSubstring substring: String,
                        indexOfToken tokenIndex: Int,
                        indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?) -> [Any]? {
            let found = TagEntry.completions(for: substring, in: parent.model.allSubjects)
            selectedIndex?.pointee = TagEntry.filledInIndex(for: substring, in: found)
            return found
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            guard let tf = obj.object as? NSTokenField,
                  let tagCell = tf.superview as? TagTokenCellView else { return }
            tagCell.editBase = (tf.objectValue as? [String]) ?? []
            editingItemID = tagCell.itemID
        }

        /// Return commits the inline edit (R-23). The token field handles the key first, so pending text becomes a
        /// token and an open completion is taken. With text typed, the tags are written on the next turn and the
        /// field keeps the keyboard, so the next tag can be typed at once (W40.fix-reader-tag-entry: the field
        /// was left after every tag, and each further tag needed a click). Return in a field with nothing typed
        /// ends the edit: the list takes focus back, and `controlTextDidEndEditing` commits.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard let tagCell = control.superview as? TagTokenCellView,
                  commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let typed = !TagEntry.pendingText(in: textView).isEmpty
            DispatchQueue.main.async { [weak self, weak control, weak tagCell] in
                guard let self, let control, let tagCell, control.currentEditor() != nil else { return }
                if typed {
                    self.commitInProgress(tagCell)
                } else if let tableView = self.tableView {
                    tableView.window?.makeFirstResponder(tableView)
                }
            }
            return false
        }

        /// Writes the field's tags while it is still being edited, and makes them the base the rest of the edit
        /// is measured from, so leaving the field later writes only what changed after this.
        private func commitInProgress(_ tagCell: TagTokenCellView) {
            guard let base = tagCell.editBase, let fileID = tagCell.itemID, let file = self.file(for: fileID) else { return }
            let edited = (tagCell.tokenField.objectValue as? [String]) ?? []
            // A write that failed leaves the base where it was, so leaving the field tries those tags again.
            if parent.model.commitSubjectEdit(from: base, to: edited, for: file) { tagCell.editBase = edited }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let tf = obj.object as? NSTokenField,
                  let tagCell = tf.superview as? TagTokenCellView,
                  let base = tagCell.editBase,
                  let fileID = tagCell.itemID,
                  let file = self.file(for: fileID) else {
                editingItemID = nil
                catchUpRows()
                return
            }
            tagCell.editBase = nil
            editingItemID = nil
            let edited = (tf.objectValue as? [String]) ?? []
            parent.model.commitSubjectEdit(from: base, to: edited, for: file)
            catchUpRows()
        }

        /// Takes the rows that arrived during an edit, on the next turn, once the field editor has gone.
        private func catchUpRows() {
            guard rowsWaitingForEdit else { return }
            rowsWaitingForEdit = false
            DispatchQueue.main.async { [weak self] in
                guard let self, self.editingItemID == nil, let tableView = self.tableView else { return }
                if self.showRows(self.parent.model.displayed) {
                    self.syncSelection(self.parent.selection)
                } else {
                    tableView.reloadData()
                }
            }
        }
    }
}

// MARK: - Sortable diffable data source

/// `NSTableViewDiffableDataSource` does not forward `sortDescriptorsDidChange` (an NSTableViewDataSource
/// callback), and since the diffable source IS the table's `dataSource`, a header-click sort would be
/// dropped. This subclass implements the callback and forwards it to `onSortDescriptorsChange`.
@MainActor
final class SortableDiffableDataSource: NSTableViewDiffableDataSource<Int, ArchiveFile.ID> {
    var onSortDescriptorsChange: (([NSSortDescriptor]) -> Void)?
    // `@objc` is REQUIRED: this OPTIONAL NSTableViewDataSource method is added on a SUBCLASS (the
    // protocol conformance is inherited from NSTableViewDiffableDataSource), so Swift does NOT auto-infer
    // @objc for it. Without @objc the Obj-C runtime's `respondsToSelector:` returns false and AppKit never
    // calls it — which left header-click sorting dead even though the method existed.
    @objc func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        onSortDescriptorsChange?(tableView.sortDescriptors)
    }
}

// MARK: - Row marked "on view"

/// A list row that can be marked as the file on view in the preview sheet or the frontmost document window
/// (W40.reader-selection-current): an outline inside the row, over the selection highlight or the plain row, so
/// among several selected rows the one being read stands out. White on the active selection, the label colour on
/// an inactive one (the list is inactive while the sheet or a document window has the keyboard), the accent colour
/// on an unselected row. VoiceOver hears "on view" from the row's name cell (`makeCell`): a label set on the row view
/// itself never reached the accessibility tree (measured in the VM).
final class ListRowView: NSTableRowView {
    static let reuseID = NSUserInterfaceItemIdentifier("ar.row")
    static let outlineWidth: CGFloat = 2

    var isOnView = false {
        didSet {
            guard isOnView != oldValue else { return }
            needsDisplay = true
        }
    }

    /// The system's highlight colour for the row's state, painted by the row view itself: the colours AppKit uses
    /// for a plain-style table, so nothing changes on screen, but it is drawn where `cacheDisplay` sees it, so the
    /// render guard measures the outline against the real highlight (`SelectedRowContrastTests` found that headless
    /// rendering leaves the system's own highlight out).
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        (isEmphasized ? NSColor.selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor).setFill()
        bounds.fill()
    }

    override var isSelected: Bool { didSet { if isOnView, isSelected != oldValue { needsDisplay = true } } }
    override var isEmphasized: Bool { didSet { if isOnView, isEmphasized != oldValue { needsDisplay = true } } }

    /// The outline's colour in the row's current state.
    var outlineColor: NSColor {
        guard isSelected else { return .controlAccentColor }
        return isEmphasized ? .alternateSelectedControlTextColor : .labelColor
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isOnView else { return }
        let inset = Self.outlineWidth / 2 + 0.5
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: 4, yRadius: 4)
        path.lineWidth = Self.outlineWidth
        effectiveAppearance.performAsCurrentDrawingAppearance { outlineColor.setStroke(); path.stroke() }
    }
}

// MARK: - Text cell whose colour follows the selection

/// A plain text cell whose colour can follow the row's selection (W40.fix-reader-selected-row-contrast).
/// `NSTableCellView` hands the row's background style to its text field, and AppKit then draws `labelColor` and
/// `secondaryLabelColor` in the selected-row text colours itself; an explicit colour such as the accent it leaves
/// alone, which is how the Read column's blue "Unread" came to be drawn on the blue selection. A cell with a `tint`
/// draws `tint.normal` on an ordinary row, `tint.emphasized` on an active selection, and `tint.inactiveSelected`
/// on an inactive selection; without one it is a plain text cell whose caller sets the colour.
@MainActor
class TintedTextCellView: NSTableCellView {
    var tint: (normal: NSColor, emphasized: NSColor, inactiveSelected: NSColor)? {
        didSet { applyTint() }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyTint() }
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        // AppKit gives both an ordinary row and an inactive selection `.normal`. Recheck the row before
        // drawing as well, so selecting/deselecting while the table lacks focus cannot leave the old tint.
        applyTint()
    }

    private func applyTint() {
        guard let tint, let textField else { return }
        let selected = (superview as? NSTableRowView)?.isSelected == true
        let color = backgroundStyle == .emphasized
            ? tint.emphasized : (selected ? tint.inactiveSelected : tint.normal)
        if textField.textColor != color { textField.textColor = color }
    }
}

// MARK: - Read cell: click to switch, right-click for the menu

/// The Read column's cell (W40.fix-reader-read-toggle, ledger R-25). A click on the cell switches its file between
/// Unread and Read; a right-click or Control-click offers Read, Unread and Clear Read State, the only way to clear
/// the state. It acts on its own row's file and leaves the selection alone, so a click elsewhere in the row still only
/// selects, and ⌘- or ⇧-clicks on it go to the table to extend the selection.
///
/// A double-click goes to the table, which opens the file, and writes nothing: the switch waits out the double-click
/// interval and a second click cancels it. The switch is made on the release, inside the cell, and a press that drags
/// writes nothing. Every gesture acts on the file the cell showed when it began, so a row
/// refresh that reuses the cell for another file while a menu is open or a switch is waiting cannot retarget it.
@MainActor
final class ReadStateCellView: TintedTextCellView {
    enum Action: Equatable { case toggle, set(ReadState), clear }

    /// The file the row shows; nil on a row with no file, which leaves every click to the table.
    var file: ArchiveFile?
    var onAction: ((Action, ArchiveFile) -> Void)?
    /// How long a click waits to find out whether it is the first of a double-click.
    var toggleDelay: TimeInterval = NSEvent.doubleClickInterval
    private var pendingToggle: DispatchWorkItem?
    /// The file a plain press began on, until its release.
    private var armedFile: ArchiveFile?

    /// The label is the deepest view under the pointer; the cell takes the gesture itself.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return file == nil ? hit : self
    }

    // NSTableView may take a press on a plain (non-control) cell view itself, so the gestures are written as
    // `handle…` methods that both this view's overrides and `ContextMenuTableView`'s call; whichever receives the
    // event, the cell acts once. Each returns false when the event belongs to the table.

    override func mouseDown(with event: NSEvent) {
        if !handleMouseDown(event) { super.mouseDown(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        if !handleMouseDragged() { super.mouseDragged(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        if !handleMouseUp(event) { super.mouseUp(with: event) }
    }

    func handleMouseDown(_ event: NSEvent) -> Bool {
        guard let file else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.control), let menu = menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return true
        }
        if !modifiers.isDisjoint(with: [.command, .shift]) { return false }   // the table extends the selection
        pendingToggle?.cancel()
        pendingToggle = nil
        armedFile = nil
        guard event.clickCount == 1 else {
            // The table opens the selection, and the first click selected nothing: select this row first.
            if let table = enclosingTable, case let row = table.row(for: self), row >= 0 {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            return false
        }
        armedFile = file
        return true
    }

    /// A press that moves is not a click: it writes nothing.
    func handleMouseDragged() -> Bool {
        guard armedFile != nil else { return false }
        armedFile = nil
        return true
    }

    /// The switch is armed by the press and made by a release inside the cell, so a press that slides off and is
    /// released elsewhere writes nothing; it then waits out the double-click interval.
    func handleMouseUp(_ event: NSEvent) -> Bool {
        guard let file = armedFile else { return false }
        armedFile = nil
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return true }
        let toggle = DispatchWorkItem { [weak self] in
            self?.pendingToggle = nil
            self?.onAction?(.toggle, file)
        }
        pendingToggle = toggle
        DispatchQueue.main.asyncAfter(deadline: .now() + toggleDelay, execute: toggle)
        return true
    }

    private var enclosingTable: NSTableView? {
        var view = superview
        while let v = view, !(v is NSTableView) { view = v.superview }
        return view as? NSTableView
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let file else { return super.menu(for: event) }
        let menu = NSMenu(title: "Read State")
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Action, on: Bool = false) {
            let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = Choice(action: action, file: file)
            item.state = on ? .on : .off
            menu.addItem(item)
        }
        add("Read", .set(.read), on: file.readState == .read)
        add("Unread", .set(.unread), on: file.readState == .unread)
        if file.readState != nil {
            menu.addItem(.separator())
            add("Clear Read State", .clear)
        }
        return menu
    }

    /// What a menu item does, and to the file the menu was opened on.
    private final class Choice: NSObject {
        let action: Action
        let file: ArchiveFile
        init(action: Action, file: ArchiveFile) { self.action = action; self.file = file }
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? Choice else { return }
        onAction?(choice.action, choice.file)
    }
}

// MARK: - Tag token cell view for inline tag editing

/// Custom cell for the "File tags" column: an `NSTokenField` that renders subject tags as removable
/// chips and supports inline add/remove with autocomplete. The cell stores the file ID and edit-start
/// base so the coordinator's delegate methods can commit through `TagWriter`.
@MainActor
final class TagTokenCellView: NSTableCellView {
    let tokenField: WrappingTokenField = {
        let tf = WrappingTokenField()
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.tokenStyle = .rounded
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.placeholderString = "Add tags\u{2026}"
        tf.tokenizingCharacterSet = CharacterSet(charactersIn: ",")
        tf.lineBreakMode = .byWordWrapping
        tf.usesSingleLineMode = false
        if let cell = tf.cell as? NSTokenFieldCell { cell.wraps = true; cell.isScrollable = false }
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tf.setContentCompressionResistancePriority(.required, for: .vertical)
        return tf
    }()
    var itemID: ArchiveFile.ID?
    var editBase: [String]?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(tokenField)
        NSLayoutConstraint.activate([
            tokenField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            tokenField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            tokenField.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            tokenField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        tokenField.onEditingChange = { [weak self] in self?.editingStateChanged() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The row's selection state is what the field draws its chips by (W40.fix-reader-selected-row-contrast):
    /// filled on an ordinary row, outlined in the selected-row text colour on an emphasized one.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            guard backgroundStyle != oldValue else { return }
            tokenField.cell?.backgroundStyle = backgroundStyle
            tokenField.needsDisplay = true
        }
    }

    /// The height this cell last asked its row to grow to, so a table that keeps a row short is asked once.
    private var lastNotedHeight: CGFloat?

    /// The field wraps its tokens to its width, so the height it asks for must follow that width, and the row must
    /// be measured again when it changes: automatic row heights measure a row once, before this cell has a width, so
    /// a row whose tags wrap stayed one line tall and drew the second line below itself (W40.fix-reader-tagcloud-width,
    /// seen at File tags 160 and 214 pt). Re-noted on the next turn, not inside this layout pass.
    override func layout() {
        super.layout()
        let width = tokenField.frame.width
        guard width > 0 else { return }
        if tokenField.preferredMaxLayoutWidth != width {
            let before = tokenField.intrinsicContentSize.height
            tokenField.preferredMaxLayoutWidth = width
            tokenField.invalidateIntrinsicContentSize()
            lastNotedHeight = nil
            if tokenField.intrinsicContentSize.height != before {
                noteRowHeight()
                return
            }
        }
        // Before the field had a width it was measured as one line; a field whose chips wrap is then too short.
        let needed = tokenField.intrinsicContentSize.height
        guard tokenField.bounds.height + 0.5 < needed, lastNotedHeight != needed else { return }
        lastNotedHeight = needed
        noteRowHeight()
    }

    /// The field editor lays the tokens out natively while the Reader's chips are drawn otherwise, and the two can
    /// wrap differently; told after the editor comes or goes.
    private func editingStateChanged() {
        tokenField.needsDisplay = true
        tokenField.invalidateIntrinsicContentSize()
        let width = tokenField.preferredMaxLayoutWidth > 0 ? tokenField.preferredMaxLayoutWidth : tokenField.frame.width
        guard width > 0,
              tokenField.height(editing: true, width: width) != tokenField.height(editing: false, width: width)
        else { return }
        noteRowHeight()
    }

    private func noteRowHeight() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let table = self.enclosingTableView else { return }
            let row = table.row(for: self)
            if row >= 0 { table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row)) }
        }
    }

    private var enclosingTableView: NSTableView? {
        var view = superview
        while let v = view, !(v is NSTableView) { view = v.superview }
        return view as? NSTableView
    }
}

/// A token field whose height is that of its tokens wrapped to `preferredMaxLayoutWidth`. NSTokenField's own
/// intrinsic height is one line however many lines its tokens wrap to.
///
/// W40.fix-reader-selected-row-contrast: while no field editor is up, the field draws the Reader's own chips
/// (`TagChips`) and is as tall as they are, so a selected row's chips are outlined in the selected-row text colour
/// instead of filled with a tint of it. The native tokens return while the field is being edited.
final class WrappingTokenField: NSTokenField {
    /// Called on the next turn after the field editor comes or goes.
    var onEditingChange: (() -> Void)?

    /// The subjects as the field holds them (`objectValue` is the represented objects, strings here).
    var chipTitles: [String] { (objectValue as? [Any])?.compactMap { $0 as? String } ?? [] }

    /// Whether the row is selected and emphasized: the cell's background style, which the row view sets.
    var isEmphasized: Bool { cell?.backgroundStyle == .emphasized }

    var isBeingEdited: Bool { currentEditor() != nil }

    private var chipFont: NSFont { font ?? .systemFont(ofSize: NSFont.systemFontSize) }

    /// One line of native tokens, which is the chips' line height too, so a row measured for the chips is the row
    /// the tokens had, and the field editor needs no other height for one line.
    private var nativeLineHeight: CGFloat {
        nativeHeight(width: .greatestFiniteMagnitude) ?? TagChips.chipHeight(for: chipFont)
    }

    /// Native heights by width, for the subjects and font they were measured with: the chips ask on every layout
    /// and draw, and a field's subjects change far less often than it is drawn.
    private var nativeHeights: (titles: [String], font: NSFont, byWidth: [CGFloat: CGFloat]) = ([], .systemFont(ofSize: 0), [:])

    private func nativeHeight(width: CGFloat) -> CGFloat? {
        guard let cell else { return nil }
        let titles = chipTitles, font = chipFont
        if nativeHeights.titles != titles || nativeHeights.font != font || nativeHeights.byWidth.count > 32 {
            nativeHeights = (titles, font, [:])   // a window resize passes through many widths
        }
        if let known = nativeHeights.byWidth[width] { return known }
        let height = ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height)
        nativeHeights.byWidth[width] = height
        return height
    }

    /// The chips as this field lays them out at `width`, on at least as many lines as the native tokens take there.
    /// The chips are narrower than native tokens, so at some widths they fit one line where the tokens wrap to two;
    /// the row was then one line tall while accessibility, which reports the native tokens, put the second token
    /// below it (the layout guard: `1983` 17 pt under its 22-pt row at File tags 193 pt, W40.fix-reader-vm-suite-red).
    /// So the chips wrap at the widest narrower width that gives them the tokens' line count.
    func chipsLayout(width: CGFloat) -> TagChips.Layout {
        let titles = chipTitles, font = chipFont, line = nativeLineHeight
        let layout = TagChips.layout(titles, font: font, width: width, lineHeight: line)
        guard titles.count > 1, width < .greatestFiniteMagnitude, let native = nativeHeight(width: width) else {
            return layout
        }
        let nativeLines = Self.lineCount(height: native, lineHeight: line)
        guard Self.lineCount(of: layout) < nativeLines else { return layout }
        var fits = TagChips.leadingInset + 1, wraps = width   // the chips' line count is falling in the width
        while wraps - fits > 0.5 {
            let mid = ((fits + wraps) / 2).rounded()
            if mid >= wraps || mid <= fits { break }
            let lines = Self.lineCount(of: TagChips.layout(titles, font: font, width: mid, lineHeight: line))
            if lines >= nativeLines { fits = mid } else { wraps = mid }
        }
        return TagChips.layout(titles, font: font, width: fits, lineHeight: line)
    }

    private static func lineCount(of layout: TagChips.Layout) -> Int { Set(layout.chips.map(\.frame.minY)).count }

    /// Native lines in a native height: the first line is `lineHeight`, each further one a line plus a gap under one.
    private static func lineCount(height: CGFloat, lineHeight: CGFloat) -> Int {
        Int(((height - lineHeight + 0.5) / lineHeight).rounded(.down)) + 1
    }

    override var intrinsicContentSize: NSSize {
        let width = preferredMaxLayoutWidth > 0 ? preferredMaxLayoutWidth : frame.width
        return NSSize(width: NSView.noIntrinsicMetric, height: height(editing: isBeingEdited, width: width))
    }

    /// The height the field needs at `width`: the native tokens' while editing, the Reader's chips' otherwise.
    /// Before the field has a width (a row's first measurement) it is one line, the usual row; a row whose tags
    /// wrap is measured again once the cell is laid out (`TagTokenCellView.layout`).
    func height(editing: Bool, width: CGFloat) -> CGFloat {
        let width = width > 0 ? width : CGFloat.greatestFiniteMagnitude
        let native = nativeHeight(width: width) ?? nativeLineHeight
        if editing { return native }
        // As tall as the native tokens too, which accessibility reports even while the chips are drawn.
        return chipTitles.isEmpty ? chipsLayout(width: width).height : max(chipsLayout(width: width).height, native)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !isBeingEdited else { return super.draw(dirtyRect) }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        bounds.clip()
        let layout = chipsLayout(width: bounds.width)
        if layout.chips.isEmpty {
            TagChips.drawPlaceholder(placeholderString ?? "", in: bounds, flipped: isFlipped,
                                     font: chipFont, emphasized: isEmphasized, lineHeight: nativeLineHeight)
        } else {
            TagChips.draw(layout, in: bounds, flipped: isFlipped, font: chipFont, emphasized: isEmphasized)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { DispatchQueue.main.async { [weak self] in self?.onEditingChange?() } }
        return accepted
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        DispatchQueue.main.async { [weak self] in self?.onEditingChange?() }
    }
}

// MARK: - Compact sortable icon headers

/// AppKit suppresses the sort indicator in these narrow columns. Draw the icon and the primary-sort
/// caret together, without the native text header's padding, so the minimum-width window still fits.
@MainActor
final class IconSortHeaderCell: NSTableHeaderCell {
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard let header = controlView as? NSTableHeaderView, let table = header.tableView,
              let column = table.tableColumns.first(where: { $0.headerCell === self }) else {
            super.drawInterior(withFrame: cellFrame, in: controlView)
            return
        }
        // Use the whole header even if AppKit reserves its usual sort-indicator inset.
        let cellFrame = header.headerRect(ofColumn: table.column(withIdentifier: column.identifier))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        cellFrame.clip()
        let primary = table.sortDescriptors.first
        let active = primary?.key == column.sortDescriptorPrototype?.key
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.headerTextColor
        ]
        let size = (stringValue as NSString).size(withAttributes: attributes)
        let title = NSRect(x: cellFrame.minX + 4, y: cellFrame.midY - size.height / 2,
                           width: size.width, height: size.height)
        (stringValue as NSString).draw(in: title, withAttributes: attributes)
        guard active, let primary else { return }
        let caret = NSBezierPath()
        let x = cellFrame.maxX - 8, y = cellFrame.midY
        let tip: CGFloat = primary.ascending == controlView.isFlipped ? -2 : 2
        caret.move(to: NSPoint(x: x - 3, y: y - tip))
        caret.line(to: NSPoint(x: x, y: y + tip))
        caret.line(to: NSPoint(x: x + 3, y: y - tip))
        caret.lineWidth = 1.25
        caret.lineCapStyle = .round
        caret.lineJoinStyle = .round
        NSColor.secondaryLabelColor.setStroke()
        caret.stroke()
    }

    // The compact drawing above owns the indicator, including when a user widens the column.
    override func drawSortIndicator(withFrame cellFrame: NSRect, in controlView: NSView,
                                    ascending: Bool, priority: Int) {}
}

// MARK: - Column-picker header view

/// Right-click the table header → a menu with checkmark toggles for each column plus sort options.
/// "File name" is always visible (disabled toggle); the other available columns can be hidden.
/// Choices write `NavigationModel.hiddenColumns`. If the clicked column is sortable, a
/// secondary-sort section lets the user set it without Option-clicking.
@MainActor
final class ColumnPickerHeaderView: NSTableHeaderView {
    /// Callback to set a secondary sort field. Parameters: (field, ascending).
    var onSetSecondarySort: ((SortField, Bool) -> Void)?
    /// Callback to remove the secondary sort (collapse to primary only).
    var onRemoveSecondarySort: (() -> Void)?
    /// Callback to reset sort to the default (date, then name).
    var onResetSort: (() -> Void)?
    /// Show or hide a column: (id, visible).
    var onSetColumnVisible: ((String, Bool) -> Void)?
    /// Whether a column can be shown now (Capture marker waits for a file that has one).
    var isColumnAvailable: ((String) -> Bool)?
    /// Returns the current sort descriptors so the menu can reflect active state.
    var currentSort: (() -> [ARSortDescriptor])?

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let tv = tableView else { return nil }
        let menu = NSMenu(title: "Columns")
        // Availability is explicit: AppKit must not re-enable the fixed name or absent Capture marker.
        menu.autoenablesItems = false

        // Column visibility toggles
        for col in tv.tableColumns {
            let id = col.identifier.rawValue
            let available = isColumnAvailable?(id) ?? true
            let title = Self.chooserTitle(id: id, fallback: col.title)
            let item = NSMenuItem(title: available ? title : "\(title) (no file has one yet)",
                                  action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = col.isHidden ? .off : .on
            item.toolTip = col.headerToolTip
            if id == "name" || !available { item.isEnabled = false }
            menu.addItem(item)
        }

        // Detect which column was right-clicked and offer secondary-sort options
        let point = convert(event.locationInWindow, from: nil)
        let colIndex = column(at: point)
        if colIndex >= 0 {
            let col = tv.tableColumns[colIndex]
            if let sd = col.sortDescriptorPrototype, let key = sd.key, let field = SortField(rawValue: key) {
                let sort = currentSort?() ?? []
                let isPrimary = sort.first?.field == field
                let isSecondary = sort.count > 1 && sort[1].field == field

                menu.addItem(.separator())
                let header = NSMenuItem(title: "Sort — \(Self.chooserTitle(id: col.identifier.rawValue, fallback: col.title))",
                                        action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)

                if !isPrimary {
                    let ascItem = NSMenuItem(title: "Set as Secondary Sort (A→Z)", action: #selector(setSecondaryAsc(_:)), keyEquivalent: "")
                    ascItem.target = self
                    ascItem.representedObject = field.rawValue
                    if isSecondary && sort[1].ascending { ascItem.state = .on }
                    menu.addItem(ascItem)

                    let descItem = NSMenuItem(title: "Set as Secondary Sort (Z→A)", action: #selector(setSecondaryDesc(_:)), keyEquivalent: "")
                    descItem.target = self
                    descItem.representedObject = field.rawValue
                    if isSecondary && !sort[1].ascending { descItem.state = .on }
                    menu.addItem(descItem)
                }

                if sort.count > 1 {
                    let removeItem = NSMenuItem(title: "Remove Secondary Sort", action: #selector(removeSecondary(_:)), keyEquivalent: "")
                    removeItem.target = self
                    menu.addItem(removeItem)
                }

                let resetItem = NSMenuItem(title: "Default Sort (date, then name)", action: #selector(resetSort(_:)), keyEquivalent: "")
                resetItem.target = self
                menu.addItem(resetItem)
            }
        }

        return menu
    }

    private static func chooserTitle(id: String, fallback: String) -> String {
        AppKitTableView.columnDefinitions.first { $0.id == id }?.chooserTitle ?? fallback
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, id != "name",
              isColumnAvailable?(id) ?? true,
              let col = tableView?.tableColumns.first(where: { $0.identifier.rawValue == id }) else { return }
        onSetColumnVisible?(id, col.isHidden)
    }

    @objc private func setSecondaryAsc(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let field = SortField(rawValue: key) else { return }
        onSetSecondarySort?(field, true)
    }
    @objc private func setSecondaryDesc(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let field = SortField(rawValue: key) else { return }
        onSetSecondarySort?(field, false)
    }
    @objc private func removeSecondary(_ sender: NSMenuItem) {
        onRemoveSecondarySort?()
    }
    @objc private func resetSort(_ sender: NSMenuItem) {
        onResetSort?()
    }
}

/// A reusable Quality popup needs the current value-object because AppKit menu targets receive only
/// the selected control. The row's `ArchiveFile` is revalidated by `NavigationModel` before writing.
@MainActor
private final class QualityPopUpButton: NSPopUpButton {
    var file: ArchiveFile?
}

// MARK: - Context-menu NSTableView subclass

@MainActor
final class ContextMenuTableView: NSTableView {
    var contextMenuProvider: ((Set<ArchiveFile.ID>) -> NSMenu?)?
    /// A key or click the user pressed in the list (W40.fix-reader-restore-scroll).
    var onUserInput: (() -> Void)?
    /// The Read cell a press began on, which gets the rest of that press (W40.fix-reader-read-toggle).
    private var readCellPress: ReadStateCellView?

    /// The list takes the keyboard when the window opens, unless text is already being typed. With no
    /// focused view the window published no `NavigationModel` to the menus, so after a launch ⌘Z (and the
    /// other Tags shortcuts) did nothing until the list was clicked (W40.fix-reader-undo-focus; reader-1 row 37).
    private var tookInitialFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !tookInitialFocus else { return }
        tookInitialFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, !(window.firstResponder is NSText) else { return }
            window.makeFirstResponder(self)
        }
    }

    /// The Read cell under `event`, if the press is inside one that shows a file.
    private func readCell(at event: NSEvent) -> ReadStateCellView? {
        let point = convert(event.locationInWindow, from: nil)
        let (row, column) = (row(at: point), column(at: point))
        guard row >= 0, column >= 0, tableColumns[column].identifier.rawValue == "read",
              let cell = view(atColumn: column, row: row, makeIfNecessary: false) as? ReadStateCellView,
              cell.file != nil, cell.bounds.contains(cell.convert(event.locationInWindow, from: nil)) else { return nil }
        return cell
    }

    /// ⇧↑/⇧↓ go to the model, which extends from the anchor it keeps, so the list and the preview sheet extend
    /// the same run (W40.reader-selection-current). The table's own anchor is private and is lost whenever the
    /// model sets the selection.
    var onExtendSelection: ((Int) -> Void)?

    override func keyDown(with event: NSEvent) {
        onUserInput?()   // Page Down, Home and End move the list without changing the selection
        if let delta = Self.extendDelta(event), let onExtendSelection { onExtendSelection(delta); return }
        super.keyDown(with: event)
    }

    /// -1 for ⇧↑, 1 for ⇧↓, nil for any other key or modifier.
    static func extendDelta(_ event: NSEvent) -> Int? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        guard modifiers == .shift else { return nil }
        switch event.specialKey {
        case .upArrow?: return -1
        case .downArrow?: return 1
        default: return nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        onUserInput?()
        readCellPress = nil
        if let cell = readCell(at: event), cell.handleMouseDown(event) {
            readCellPress = cell
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if let cell = readCellPress, cell.handleMouseDragged() { return }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if let cell = readCellPress {
            readCellPress = nil
            if cell.handleMouseUp(event) { return }
        }
        super.mouseUp(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if let cell = readCell(at: event) { return cell.menu(for: event) }   // the cell's own Read / Unread / Clear
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)

        if clickedRow >= 0 && !selectedRowIndexes.contains(clickedRow) {
            selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }

        guard let ds = dataSource as? NSTableViewDiffableDataSource<Int, ArchiveFile.ID> else { return nil }
        let allIDs = ds.snapshot().itemIdentifiers(inSection: 0)
        var selIDs = Set<ArchiveFile.ID>()
        for i in selectedRowIndexes {
            if i < allIDs.count { selIDs.insert(allIDs[i]) }
        }

        return contextMenuProvider?(selIDs)
    }
}
