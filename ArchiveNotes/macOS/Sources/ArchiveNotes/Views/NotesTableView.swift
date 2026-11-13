import SwiftUI
import AppKit
import ArchiveCoreUI

// MARK: - NSViewRepresentable bridge

/// The item-list table for the Notes browser (W6-S3). Adapted wholesale from ArchiveReader's
/// `AppKitTableView` (Views/AppKitTableView.swift): the same virtualized `NSTableView` +
/// `NSTableViewDiffableDataSource<Int, UUID>` + `Coordinator` + `ColumnPickerHeaderView` +
/// `ContextMenuTableView` structure. Differences from Reader: identity is `ItemSummary.id` (UUID,
/// front-matter) not `ArchiveFile` (path, Finder tags); the columns are the Notes set
/// (kind/title/instances/date/quality/tags); and the tags column draws the Reader's wrapping chips
/// (`TagChipsView`, W40.suite-reader-notes-consistency), edited in place by a token field laid over the cell.
/// Quality has an inline borderless menu; titles rename inline via Return, double-click, or the row context menu.
struct NotesTableView: NSViewRepresentable {
    @ObservedObject var model: NotesNavigationModel
    @Binding var selection: Set<UUID>
    var onDoubleClick: () -> Void
    var buildContextMenu: (Set<UUID>) -> NSMenu?
    /// Settings ▸ "Show dates in other calendars" (W24.cal1-toggle); the Date column follows it.
    var calendarsEnabled: Bool = false

    /// Non-hideable primary column (analogous to Reader's always-visible "File name").
    static let titleColumnID = "title"
    private static let fontSize: CGFloat = 13
    static var listFont: NSFont { .systemFont(ofSize: fontSize) }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator

        let scrollView = NotesListScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        // Not autohiding: with legacy (always-shown) scrollers the two would decide each other in the short
        // stacked list — the horizontal one's height pushes the rows past the clip and shows the vertical one,
        // whose width changes the columns' fit and the horizontal one's need — and SwiftUI's host re-laid the
        // table between AppKit's tiles until the window's constraint-pass cap threw (W48.notes-stacked-layout,
        // runs 15–16). Fixed tracks make the clip depend on the frame alone. Overlay scrollers are unaffected.
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder

        let tableView = ContextMenuTableView()
        tableView.setAccessibilityLabel("Notes")
        tableView.setAccessibilityIdentifier("an.table")
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        // Not `usesAutomaticRowHeights`: with automatic heights the rows collapsed to 16 pt and squeezed each 16 pt
        // text line to 12 (W40.fix-notes-row-clip). This is one line's height; a row whose tags wrap is as tall as
        // their chips, worked out from the Tags column's width (`Coordinator.tableView(_:heightOfRow:)`).
        tableView.rowHeight = ceil(max(20, Self.fontSize * 1.8))
        tableView.intercellSpacing = NSSize(width: 8, height: 2)

        let headerView = ColumnPickerHeaderView()
        headerView.setAccessibilityIdentifier("an.table.header")
        headerView.nonHideableColumnID = Self.titleColumnID
        headerView.windowKind = model.windowKind   // per-window column visibility (W14.4)
        headerView.currentSort = { [weak coordinator] in coordinator?.parent.model.sort ?? NotesSort.default }
        headerView.onSetSecondarySort = { [weak coordinator] field, ascending in
            guard let c = coordinator else { return }
            let primary = c.parent.model.sort.first ?? NoteSortDescriptor(field: .date, ascending: true)
            c.parent.model.setSort([primary, NoteSortDescriptor(field: field, ascending: ascending)])
        }
        headerView.onRemoveSecondarySort = { [weak coordinator] in
            guard let c = coordinator, let primary = c.parent.model.sort.first else { return }
            c.parent.model.setSort([primary])
        }
        headerView.onResetSort = { [weak coordinator] in
            coordinator?.parent.model.setSort(NotesSort.default)
        }
        tableView.headerView = headerView
        tableView.target = coordinator
        tableView.doubleAction = #selector(Coordinator.tableViewDoubleClicked(_:))
        tableView.contextMenuProvider = { [weak coordinator] selIDs in
            guard let coordinator else { return nil }
            let menu = coordinator.parent.buildContextMenu(selIDs) ?? NSMenu()
            if selIDs.count == 1, let id = selIDs.first {
                // The title, the date and the tags are edited in the list (W40.notes-detail-layout).
                let edits: [(String, () -> Void)] = [
                    ("Rename…", { [weak coordinator] in coordinator?.beginRename(id) }),
                    ("Edit Date", { [weak coordinator] in coordinator?.beginDateEdit(id) }),
                    ("Edit Tags", { [weak coordinator] in coordinator?.beginTagsEdit(id) }),
                ]
                menu.insertItem(.separator(), at: 0)
                for (title, perform) in edits.reversed() {
                    let item = NSMenuItem(title: title, action: #selector(NotesMenuAction.fire), keyEquivalent: "")
                    let action = NotesMenuAction(perform)
                    item.target = action
                    item.representedObject = action
                    menu.insertItem(item, at: 0)
                }
            }
            return menu
        }
        tableView.onRenameSelection = { [weak coordinator] in coordinator?.renameSelection() ?? false }

        let columns: [(id: String, title: String, width: CGFloat, minWidth: CGFloat, maxWidth: CGFloat, sortField: NoteSortField?)] = [
            ("kind",       "⬦",       28,  26,   34,  .kind),
            ("title",      "Title",   300, 180,  800, .title),
            ("instances",  "In",      46,  40,   70,  nil),
            ("date",       "Date",    140, 100,  220, .date),
            ("quality",    "Quality", 90,  70,   120, .quality),
            ("sources",    "Sources", 70,  50,   120, nil),
            ("tags",       "Tags",    280, 140,  600, nil),
        ]
        for col in columns {
            let tc = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.id))
            tc.title = col.title
            tc.width = col.width
            tc.minWidth = col.minWidth
            tc.maxWidth = col.maxWidth
            if let sf = col.sortField {
                tc.sortDescriptorPrototype = NSSortDescriptor(key: sf.rawValue, ascending: true)
            }
            tableView.addTableColumn(tc)
        }

        let hidden = NotesAppSettings.windowHiddenColumns(for: model.windowKind)
        for col in tableView.tableColumns where hidden.contains(col.identifier.rawValue) {
            col.isHidden = true
        }

        scrollView.documentView = tableView
        coordinator.tableView = tableView
        coordinator.displayedByID = Dictionary(uniqueKeysWithValues: model.displayed.map { ($0.id, $0) })

        let dataSource = NotesTableDataSource(tableView: tableView) { tv, column, _, itemID in
            coordinator.makeCell(tableView: tv, column: column, itemID: itemID)
        }
        coordinator.dataSource = dataSource
        tableView.delegate = coordinator
        // Rows are draggable onto folder-tree rows: MOVE (plain) / REPLICATE (⌥) — W6-S5.
        tableView.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        tableView.sortDescriptors = sortDescriptorsFromModel()

        coordinator.applySnapshot(model.displayed.map(\.id), animated: false)
        coordinator.syncSelection(selection)

        return scrollView
    }

    @MainActor
    /// The table takes what it is offered. Without this SwiftUI sizes the scroll view from the Auto Layout engine
    /// over its cells, which changes as columns resize, and a layout that measures it (the stacked panes did) can
    /// loop until AppKit throws (W48.notes-stacked-layout, VM runs 9 and 10). The fallbacks only answer an
    /// unspecified probe: the list pane's floor and the stacked list's floor.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        // Whole points, so the columns fitted to the clip never come out a point wider than it (see
        // `StackedPanesLayout.placeSubviews`); an infinite probe is passed through unchanged.
        func whole(_ v: CGFloat?, _ fallback: Double) -> CGFloat {
            guard let v else { return CGFloat(fallback) }
            return v.isFinite ? v.rounded(.down) : v
        }
        return CGSize(width: whole(proposal.width, NotesLayoutSettings.listMinWidth),
                      height: whole(proposal.height, NotesLayoutSettings.listHeightMin))
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let tableView = coordinator.tableView else { return }
        coordinator.parent = self
        // A body autosave or another window's update must not replace the field editor mid-draft.
        // Keep the old generation until editing ends, then apply the latest model snapshot once.
        if coordinator.editingTitle?.isRenaming == true || coordinator.editingTags != nil { return }

        // Only rebuild the O(N) lookup + diff the snapshot when `displayed` actually changed.
        let gen = model.displayedGeneration
        if coordinator.lastDisplayedGeneration != gen {
            coordinator.lastDisplayedGeneration = gen
            coordinator.displayedByID = Dictionary(uniqueKeysWithValues: model.displayed.map { ($0.id, $0) })

            let newIDs = model.displayed.map(\.id)
            if newIDs != coordinator.currentSnapshotIDs {
                coordinator.applySnapshotKeepingSelection(newIDs, wanted: selection)
            }
            // A tag added or removed can change how many lines a row's chips take.
            coordinator.noteRowHeights()
            // Values may have changed, and a row the snapshot moved keeps its old cell (a rename that
            // re-sorts the list would still show the old title) — reload the visible rows.
            let visRange = tableView.rows(in: tableView.visibleRect)
            if visRange.length > 0 {
                tableView.reloadData(
                    forRowIndexes: IndexSet(integersIn: visRange.location..<(visRange.location + visRange.length)),
                    columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
            }
        }

        // The Settings calendar switch changes only how dates read, so redraw the visible rows in place.
        if coordinator.lastCalendarsEnabled != calendarsEnabled {
            coordinator.lastCalendarsEnabled = calendarsEnabled
            let visRange = tableView.rows(in: tableView.visibleRect)
            if visRange.length > 0 {
                tableView.reloadData(
                    forRowIndexes: IndexSet(integersIn: visRange.location..<(visRange.location + visRange.length)),
                    columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
            }
        }

        // Selection sync (SwiftUI → AppKit)
        if coordinator.lastPushedSelection != selection {
            coordinator.syncSelection(selection)
        }

        // Sort descriptors (model → AppKit header arrows)
        let modelDescs = sortDescriptorsFromModel()
        if tableView.sortDescriptors != modelDescs {
            coordinator.isSortingFromModel = true
            tableView.sortDescriptors = modelDescs
            coordinator.isSortingFromModel = false
        }
    }

    private func sortDescriptorsFromModel() -> [NSSortDescriptor] {
        model.sort.map { NSSortDescriptor(key: $0.field.rawValue, ascending: $0.ascending) }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDelegate {
        var parent: NotesTableView
        weak var tableView: NSTableView?
        var dataSource: NSTableViewDiffableDataSource<Int, UUID>?
        var lastPushedSelection: Set<UUID> = []
        var lastCalendarsEnabled = false
        var isUpdatingSelection = false
        var isSortingFromModel = false
        var displayedByID: [UUID: ItemSummary] = [:]
        var lastDisplayedGeneration = -1
        var currentSnapshotIDs: [UUID] = []
        /// The title or date field being edited in a row, if any.
        weak var editingTitle: NoteTitleTextField?
        /// The tags field laid over a row's Tags cell while its tags are edited, and the item it edits.
        var editingTags: NoteTagsCellField?
        var editingTagsItemID: UUID?

        init(_ parent: NotesTableView) { self.parent = parent }

        func applySnapshot(_ ids: [UUID], animated: Bool) {
            guard ids != currentSnapshotIDs else { return }
            currentSnapshotIDs = ids
            var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
            snapshot.appendSections([0])
            snapshot.appendItems(ids, toSection: 0)
            dataSource?.apply(snapshot, animatingDifferences: animated)
        }

        /// A new row order keeps the selection on the same items. A rename re-sorts the list, and the moved
        /// row left the table's selection while the model still held it, so the note showed in the detail
        /// but not as selected, and a Return after a rename read as a deselect (W40.fix-notes-list-rename).
        /// The apply never writes the model's selection: the model has already pruned it to the listed items
        /// (`NotesNavigationModel.applyRecompute`), so it is put back on the table as it stands.
        func applySnapshotKeepingSelection(_ ids: [UUID], wanted: Set<UUID>) {
            isUpdatingSelection = true
            applySnapshot(ids, animated: false)
            isUpdatingSelection = false
            syncSelection(wanted)
        }

        func syncSelection(_ sel: Set<UUID>) {
            guard let tableView else { return }
            isUpdatingSelection = true
            defer { isUpdatingSelection = false; lastPushedSelection = sel }
            var indexSet = IndexSet()
            for (i, id) in currentSnapshotIDs.enumerated() where sel.contains(id) { indexSet.insert(i) }
            tableView.selectRowIndexes(indexSet, byExtendingSelection: false)
        }

        // MARK: Cell factory

        func makeCell(tableView: NSTableView, column: NSTableColumn, itemID: UUID) -> NSView {
            let colID = column.identifier.rawValue
            let item = displayedByID[itemID]

            if colID == "kind" { return makeKindCell(tableView: tableView, item: item) }
            if colID == "quality" { return makeQualityCell(tableView: tableView, item: item) }
            if colID == "tags" { return makeTagsCell(tableView: tableView, item: item) }

            let cellID = NSUserInterfaceItemIdentifier("cell.\(colID)")
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView {
                cell = reused
            } else {
                cell = colID == "title" ? NotesTitleCellView() : NSTableCellView()
                cell.identifier = cellID
                let tf = colID == "title" || colID == "date"
                    ? NoteTitleTextField(labelWithString: "") : NSTextField(labelWithString: "")
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
            }

            let tf = cell.textField!
            let regularFont = NSFont.systemFont(ofSize: NotesTableView.fontSize)
            tf.font = regularFont
            tf.textColor = .labelColor
            tf.toolTip = nil
            tf.setAccessibilityIdentifier(nil)

            guard let item else { tf.stringValue = ""; return cell }

            switch colID {
            case "title":
                if let titleField = tf as? NoteTitleTextField {
                    titleField.noteTitle = item.title
                    titleField.itemID = item.id
                    titleField.onBegin = { [weak self, weak titleField] in self?.editingTitle = titleField }
                    titleField.onEnd = { [weak self] in
                        self?.editingTitle = nil
                        self?.parent.model.objectWillChange.send()
                    }
                    titleField.onCommit = { [weak self] title, completion in
                        guard let model = self?.parent.model.model else { completion(false); return }
                        Task { @MainActor in
                            completion(await model.renameNote(item.id, to: title))
                        }
                    }
                }
                let displayTitle = item.title.isEmpty ? "Untitled" : item.title
                // Replicated items (in >1 folder) get a subtle accent-colored chain glyph prefix, so a
                // replicant reads as one at a glance (the "In" column shows the count). W6-S5, §5.
                if (parent.model.instanceCounts[item.id] ?? 0) > 1 {
                    let styled = NSMutableAttributedString(
                        string: NotesTitleCellView.replicatedGlyph,
                        attributes: [.foregroundColor: NotesTitleCellView.glyphColor(for: cell.backgroundStyle),
                                     .font: regularFont])
                    styled.append(NSAttributedString(
                        string: displayTitle,
                        attributes: [.foregroundColor: NSColor.labelColor, .font: regularFont]))
                    tf.attributedStringValue = styled
                } else {
                    tf.stringValue = displayTitle
                }
                tf.lineBreakMode = .byTruncatingMiddle
                tf.setAccessibilityIdentifier("an.cell.title.\(item.id.uuidString)")

            case "instances":
                let n = parent.model.instanceCounts[item.id] ?? 0
                tf.stringValue = n > 1 ? "▣ \(n)" : ""
                tf.textColor = .labelColor
                // VoiceOver reads the count in words; the blank cell still needs a name (the table exposes it
                // whether or not it is marked an element). Set on every pass because the cell is reused.
                tf.setAccessibilityLabel(n > 1 ? "In \(n) folders" : "Not replicated")
                tf.setAccessibilityIdentifier("an.cell.instances.\(item.id.uuidString)")

            case "date":
                tf.stringValue = item.dateColumnText(calendarsEnabled: parent.calendarsEnabled) ?? "—"
                tf.textColor = .labelColor
                if item.sortDateUncertain {
                    tf.font = NSFontManager.shared.convert(regularFont, toHaveTrait: .italicFontMask)
                }
                tf.setAccessibilityIdentifier("an.cell.date.\(item.id.uuidString)")
                if let dateField = tf as? NoteTitleTextField { configureDateField(dateField, for: item) }

            case "sources":
                // Distinct source notes for a segmented extract; blank for notes / source-less
                // extracts. The Extracts window features this; a notes list shows it empty (W7-S4, §4).
                tf.stringValue = item.sourcesText
                tf.textColor = .labelColor
                tf.setAccessibilityIdentifier("an.cell.sources.\(item.id.uuidString)")
                // An empty cell still says what it is (the audit, once the stacked list showed it; W48).
                tf.setAccessibilityLabel(item.sourcesText.isEmpty ? "No sources" : nil)

            default:
                tf.stringValue = ""
            }
            return cell
        }

        /// The Tags cell: the note's tags as the Reader's list draws them, wrapping at the column's width; the row is
        /// as tall as they need (`tableView(_:heightOfRow:)`).
        private func makeTagsCell(tableView: NSTableView, item: ItemSummary?) -> NSView {
            let cellID = NSUserInterfaceItemIdentifier("cell.tags")
            let cell = tableView.makeView(withIdentifier: cellID, owner: nil) as? NotesTagsCellView
                ?? NotesTagsCellView(identifier: cellID)
            cell.show(item?.managedTags ?? [], font: NotesTableView.listFont)
            cell.chips.setAccessibilityIdentifier(item.map { "an.cell.tags.\($0.id.uuidString)" })
            // A recycled cell still holding another row's tags field: end that edit, which saves to its own item.
            if let editing = editingTags, editing.superview === cell, editingTagsItemID != item?.id {
                tableView.window?.makeFirstResponder(tableView)
            }
            return cell
        }

        // MARK: Row heights

        /// Heights already worked out, by the Tags column's width and the row's tags.
        private var heightCache: [String: CGFloat] = [:]
        private var heightCacheWidth: CGFloat = -1
        /// Each tag's drawn width, which does not change with the column's: a live resize then rewraps every row
        /// with arithmetic alone, without measuring text again.
        private var titleWidths: [String: CGFloat] = [:]

        /// One line, or the height of the row's chips at the Tags column's width when they wrap.
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            let base = tableView.rowHeight
            guard currentSnapshotIDs.indices.contains(row),
                  let tags = displayedByID[currentSnapshotIDs[row]]?.managedTags, !tags.isEmpty,
                  let column = tableView.tableColumns.first(where: { $0.identifier.rawValue == "tags" }),
                  !column.isHidden else { return base }
            let width = NotesTagsCellView.chipsWidth(inColumn: column.width)
            if width != heightCacheWidth { heightCache = [:]; heightCacheWidth = width }
            let key = tags.joined(separator: "\u{1F}")
            if let known = heightCache[key] { return max(base, known) }
            let font = NotesTableView.listFont
            let needed = TagChipsView.height(for: tags, font: font, width: width, titleWidth: { [self] title in
                if let known = titleWidths[title] { return known }
                let measured = TagChips.titleWidth(title, font: font)
                titleWidths[title] = measured
                return measured
            }) + 2 * NotesTagsCellView.verticalInset
            heightCache[key] = needed
            return max(base, needed)
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
                  column.identifier.rawValue == "tags" else { return }
            noteRowHeights()
        }

        /// Asks the table for every row's height again, without animating: the tags, the Tags column's width or
        /// whether it shows changed.
        func noteRowHeights() {
            guard let tableView, tableView.numberOfRows > 0 else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<tableView.numberOfRows))
            }
        }

        private func makeQualityCell(tableView: NSTableView, item: ItemSummary?) -> NSView {
            guard let item else { return NSTextField(labelWithString: "") }
            let cellID = NSUserInterfaceItemIdentifier("cell.quality")
            let menu = QualityInlineMenu(itemID: item.id, quality: item.quality) { [weak self] value in
                guard let nav = self?.parent.model else { return }
                Task { @MainActor in await nav.setQuality(value, for: item.id) }
            }
            let hosting: NSHostingView<QualityInlineMenu>
            if let reused = tableView.makeView(withIdentifier: cellID, owner: nil)
                as? NSHostingView<QualityInlineMenu> {
                hosting = reused
                hosting.rootView = menu
            } else {
                hosting = NSHostingView(rootView: menu)
                hosting.identifier = cellID
                // The cell's group needs its own name: the audit flagged it once the stacked layout's wider
                // list showed the Quality column on screen (W48.notes-stacked-layout).
                hosting.setAccessibilityLabel("Quality")
                // A hosting view inside a table cell must not ask the window for a constraint pass of its own:
                // the column's width sizes it, and it has no safe area to track. With both on, the folder tree's
                // animated toggle in the stacked layout (the only layout wide enough to show this column) relaid
                // the table while the cell's safe-area observer fired `setNeedsUpdateConstraints` on the window
                // mid-layout, and AppKit threw inside `_postWindowNeedsUpdateConstraints` — the app died in the
                // stacked visual tour (W48.notes-stacked-layout, run 9; crash report in the VM artifacts).
                hosting.safeAreaRegions = []
                hosting.sizingOptions = []
            }
            return hosting
        }

        private func makeKindCell(tableView: NSTableView, item: ItemSummary?) -> NSView {
            let cellID = NSUserInterfaceItemIdentifier("cell.kind")
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = cellID
                let iv = NSImageView()
                iv.translatesAutoresizingMaskIntoConstraints = false
                iv.imageScaling = .scaleProportionallyDown
                cell.addSubview(iv)
                cell.imageView = iv
                NSLayoutConstraint.activate([
                    iv.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                    iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    iv.widthAnchor.constraint(equalToConstant: 16),
                    iv.heightAnchor.constraint(equalToConstant: 16),
                ])
            }
            let symbol = (item?.kind == .extract) ? "quote.opening" : "doc.text"
            cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: item?.kind.rawValue)
            cell.imageView?.contentTintColor = .secondaryLabelColor
            cell.setAccessibilityIdentifier(item.map { "an.cell.kind.\($0.id.uuidString)" })
            return cell
        }

        // MARK: NSTableViewDelegate

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdatingSelection, let tableView else { return }
            var newSel = Set<UUID>()
            for i in tableView.selectedRowIndexes where i < currentSnapshotIDs.count {
                newSel.insert(currentSnapshotIDs[i])
            }
            lastPushedSelection = newSel
            parent.selection = newSel
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isSortingFromModel else { return }
            let descriptors = tableView.sortDescriptors.compactMap { sd -> NoteSortDescriptor? in
                guard let key = sd.key, let field = NoteSortField(rawValue: key) else { return nil }
                return NoteSortDescriptor(field: field, ascending: sd.ascending)
            }
            if !descriptors.isEmpty { parent.model.setSort(descriptors) }
        }

        @objc func tableViewDoubleClicked(_ sender: Any?) {
            guard let tableView, tableView.clickedRow >= 0 else { return }
            // A double-click on the Date or Tags cell edits it there (W40.notes-detail-layout); elsewhere it renames.
            if tableView.clickedColumn >= 0, currentSnapshotIDs.indices.contains(tableView.clickedRow) {
                let id = currentSnapshotIDs[tableView.clickedRow]
                switch tableView.tableColumns[tableView.clickedColumn].identifier.rawValue {
                // On the next turn: laid over the cell during the table's own click handling, the field lost the
                // keyboard again as the double-click finished (VM run 2).
                case "date": DispatchQueue.main.async { [weak self] in self?.beginDateEdit(id) }; return
                case "tags": DispatchQueue.main.async { [weak self] in self?.beginTagsEdit(id) }; return
                default: break
                }
            }
            if !renameSelection() { parent.onDoubleClick() }
        }

        func renameSelection() -> Bool {
            guard let tableView, tableView.selectedRowIndexes.count == 1,
                  let row = tableView.selectedRowIndexes.first,
                  currentSnapshotIDs.indices.contains(row) else { return false }
            beginRename(currentSnapshotIDs[row])
            return true
        }

        func beginRename(_ id: UUID) {
            guard let tableView, let row = currentSnapshotIDs.firstIndex(of: id),
                  let column = tableView.tableColumns.firstIndex(where: {
                      $0.identifier.rawValue == NotesTableView.titleColumnID
                  }) else { return }
            tableView.scrollRowToVisible(row)
            let cell = tableView.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView
            (cell?.textField as? NoteTitleTextField)?.beginRename()
        }

        // MARK: Date and tags edited in the list (W40.notes-detail-layout)

        /// The Date cell's field: the date as the inspector's field shows it, typed over with the same rules
        /// (`DateFieldEntry.listEdit`); an emptied cell clears the date, refused text is said in the status line.
        private func configureDateField(_ field: NoteTitleTextField, for item: ItemSummary) {
            let seed = DateFieldEntry.listSeed(storedDate: item.date, precision: item.datePrecision,
                                               active: item.activeCalendar(calendarsEnabled: parent.calendarsEnabled))
            field.noteTitle = seed.text
            field.itemID = item.id
            field.commitsEmpty = true
            field.toolTip = "Double-click to edit the date"
            field.onBegin = { [weak self, weak field] in self?.editingTitle = field }
            field.onEnd = { [weak self] in
                self?.editingTitle = nil
                self?.parent.model.objectWillChange.send()
            }
            let id = item.id, stored = item.date
            field.onCommit = { [weak self] text, completion in
                guard let nav = self?.parent.model else { completion(false); return }
                switch DateFieldEntry.listEdit(text, seed: seed.text, calendar: seed.calendar, storedDate: stored) {
                case .unchanged:
                    completion(false)
                case .refused(let message):
                    nav.model.statusMessage = "Date not changed. \(message)"
                    NSSound.beep()
                    completion(false)
                case let .write(date, precision, note):
                    Task { @MainActor in
                        let saved = await nav.setDate(date, precision: precision, for: id)
                        if saved, let note { nav.model.statusMessage = note }
                        completion(saved)
                    }
                }
            }
        }

        private func cell(column columnID: String, item id: UUID) -> NSTableCellView? {
            guard let tableView, let row = currentSnapshotIDs.firstIndex(of: id),
                  let column = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == columnID }),
                  !tableView.tableColumns[column].isHidden else { return nil }
            tableView.scrollRowToVisible(row)
            tableView.scrollColumnToVisible(column)
            return tableView.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView
        }

        func beginDateEdit(_ id: UUID) {
            guard let field = cell(column: "date", item: id)?.textField as? NoteTitleTextField else {
                cannotEdit("The Date column is hidden. Show it from the list's header menu to edit the date here.")
                return
            }
            field.beginRename()
        }

        /// Says in the status line why a cell edit did not start, rather than only beeping.
        private func cannotEdit(_ message: String) {
            NSSound.beep()
            parent.model.model.statusMessage = message
        }

        /// Lays a tags field over the item's Tags cell and gives it the keyboard; it saves the edited tags as adds and
        /// removes (`NoteTagBar.edits`), one at a time, to the item it began on.
        func beginTagsEdit(_ id: UUID) {
            guard editingTags == nil else { return cannotEdit("Finish editing the other row's tags first.") }
            guard let item = displayedByID[id] else { return cannotEdit("That item is no longer listed.") }
            guard let cell = cell(column: "tags", item: id) else {
                return cannotEdit("The Tags column is hidden. Show it from the list's header menu to edit tags here.")
            }
            let model = parent.model.model
            let field = NoteTagsCellField(
                tags: item.managedTags,
                suggestions: { NoteTagBar.suggestions(for: item, in: model.allItems) },
                onCommit: { edited in
                    let (add, remove) = NoteTagBar.edits(from: edited, current: item.managedTags)
                    Task { @MainActor in
                        var saved = true
                        for tag in remove { saved = await model.removeTag(tag, from: id) && saved }
                        for tag in add { saved = await model.addTag(tag, to: id) && saved }
                        if !saved { model.statusMessage = "Some tags of “\(item.title)” could not be saved." }
                    }
                },
                onEnd: { [weak self, weak cell] in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.editingTags?.removeFromSuperview()
                        self.editingTags = nil
                        self.editingTagsItemID = nil
                        (cell as? NotesTagsCellView)?.chips.isHidden = false
                        self.parent.model.objectWillChange.send()
                    }
                })
            field.setAccessibilityIdentifier("an.cell.tags.edit.\(id.uuidString)")
            field.frame = cell.bounds.insetBy(dx: 1, dy: 1)
            field.autoresizingMask = [.width, .height]
            cell.addSubview(field)
            (cell as? NotesTagsCellView)?.chips.isHidden = true
            editingTags = field
            editingTagsItemID = id
            // A field that cannot take the keyboard would never end, and the list would stay frozen.
            if cell.window?.makeFirstResponder(field) != true {
                field.removeFromSuperview()
                (cell as? NotesTagsCellView)?.chips.isHidden = false
                editingTags = nil
                editingTagsItemID = nil
                cannotEdit("The tags could not be edited in the list; use the tag bar under the note.")
                return
            }
            // The caret after the tags, nothing selected: taking the keyboard selects every token, and the first key
            // typed then replaced the note's tags (VM run 5's screenshot).
            if let editor = field.currentEditor() {
                editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
            }
        }
    }
}

// MARK: - Column-picker header view

/// Right-click the table header → checkmark toggles for each column (persisted to
/// `NotesAppSettings.hiddenColumns`) plus secondary-sort options for the clicked column. Adapted from
/// Reader's `ColumnPickerHeaderView` (AppKitTableView.swift:492-586); the always-visible column is
/// injected (`nonHideableColumnID`) instead of hard-coded to "name".
@MainActor
final class ColumnPickerHeaderView: NSTableHeaderView {
    var nonHideableColumnID: String?
    /// The kind of the window this header belongs to — column visibility persists per window (W14.4).
    var windowKind: Item.Kind = .note
    var onSetSecondarySort: ((NoteSortField, Bool) -> Void)?
    var onRemoveSecondarySort: (() -> Void)?
    var onResetSort: (() -> Void)?
    var currentSort: (() -> [NoteSortDescriptor])?

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let tv = tableView else { return nil }
        let menu = NSMenu(title: "Columns")

        for col in tv.tableColumns {
            let id = col.identifier.rawValue
            let item = NSMenuItem(title: col.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = col.isHidden ? .off : .on
            if id == nonHideableColumnID { item.isEnabled = false }
            menu.addItem(item)
        }

        let point = convert(event.locationInWindow, from: nil)
        let colIndex = column(at: point)
        if colIndex >= 0 {
            let col = tv.tableColumns[colIndex]
            if let sd = col.sortDescriptorPrototype, let key = sd.key, let field = NoteSortField(rawValue: key) {
                let sort = currentSort?() ?? []
                let isPrimary = sort.first?.field == field
                let isSecondary = sort.count > 1 && sort[1].field == field

                menu.addItem(.separator())
                let header = NSMenuItem(title: "Sort — \(col.title)", action: nil, keyEquivalent: "")
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
                let resetItem = NSMenuItem(title: "Default Sort (date, then title)", action: #selector(resetSort(_:)), keyEquivalent: "")
                resetItem.target = self
                menu.addItem(resetItem)
            }
        }
        return menu
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let tv = tableView,
              let col = tv.tableColumns.first(where: { $0.identifier.rawValue == id }) else { return }
        col.isHidden.toggle()
        if id == "tags", tv.numberOfRows > 0 {   // a row is as tall as its tags only while they show
            NSAnimationContext.runAnimationGroup { context in   // not animated, as `Coordinator.noteRowHeights`
                context.duration = 0
                tv.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<tv.numberOfRows))
            }
        }
        var hidden = NotesAppSettings.windowHiddenColumns(for: windowKind)
        if col.isHidden { hidden.insert(id) } else { hidden.remove(id) }
        NotesAppSettings.setWindowHiddenColumns(hidden, for: windowKind)
    }

    @objc private func setSecondaryAsc(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let field = NoteSortField(rawValue: key) else { return }
        onSetSecondarySort?(field, true)
    }
    @objc private func setSecondaryDesc(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let field = NoteSortField(rawValue: key) else { return }
        onSetSecondarySort?(field, false)
    }
    @objc private func removeSecondary(_ sender: NSMenuItem) { onRemoveSecondarySort?() }
    @objc private func resetSort(_ sender: NSMenuItem) { onResetSort?() }
}

// MARK: - Drag-source data source

/// `NSTableViewDiffableDataSource` subclass that makes rows draggable, carrying the row's item id
/// (06-viewers §5, W6-S5). The payload is **ids only** — the custom `com.archivenotes.item-ids` type
/// plus the same JSON as `.string` (the folder drop delegate accepts both representations).
/// No file bytes ever cross the pasteboard.
@MainActor
final class NotesTableDataSource: NSTableViewDiffableDataSource<Int, UUID> {
    // Optional NSTableViewDataSource method (not declared on the diffable superclass, so no `override`);
    // @objc-exposed via the inherited NSTableViewDataSource conformance so NSTableView calls it.
    @objc func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let ids = snapshot().itemIdentifiers(inSection: 0)
        guard row >= 0, row < ids.count else { return nil }
        let item = NSPasteboardItem()
        item.setData(NotesItemDrag.encode([ids[row]]), forType: NotesItemDrag.pasteboardType)
        item.setString(NotesItemDrag.encodedString([ids[row]]), forType: .string)
        return item
    }
}

// MARK: - Context-menu NSTableView subclass

/// Right-clicking selects the clicked row (if not already in the selection) then asks the provider for
/// a menu over the resulting selection. Copied from Reader's `ContextMenuTableView`, keyed by UUID.
@MainActor
final class ContextMenuTableView: NSTableView {
    var contextMenuProvider: ((Set<UUID>) -> NSMenu?)?
    var onRenameSelection: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        if [36, 76].contains(event.keyCode),
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           onRenameSelection?() == true { return }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        if clickedRow >= 0 && !selectedRowIndexes.contains(clickedRow) {
            selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
        guard let ds = dataSource as? NSTableViewDiffableDataSource<Int, UUID> else { return nil }
        let allIDs = ds.snapshot().itemIdentifiers(inSection: 0)
        var selIDs = Set<UUID>()
        for i in selectedRowIndexes where i < allIDs.count { selIDs.insert(allIDs[i]) }
        return contextMenuProvider?(selIDs)
    }
}

/// The title column's cell. A replicated item's title starts with an accent-coloured glyph, which an
/// attributed colour keeps on a selected row, where the accent selection hid it; the cell re-tints it
/// as the row's background style changes (W40.fix-notes-visual-polish).
final class NotesTitleCellView: NSTableCellView {
    static let replicatedGlyph = "⧉ "

    static func glyphColor(for style: NSView.BackgroundStyle) -> NSColor {
        style == .emphasized ? .alternateSelectedControlTextColor : .controlAccentColor
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if backgroundStyle != oldValue { retintGlyph() } }
    }

    private func retintGlyph() {
        guard let field = textField, !((field as? NoteTitleTextField)?.isRenaming ?? false) else { return }
        let current = field.attributedStringValue
        guard current.string.hasPrefix(Self.replicatedGlyph) else { return }
        let styled = NSMutableAttributedString(attributedString: current)
        styled.addAttribute(.foregroundColor, value: Self.glyphColor(for: backgroundStyle),
                            range: NSRange(location: 0, length: (Self.replicatedGlyph as NSString).length))
        field.attributedStringValue = styled
    }
}

/// The Tags column's cell: the note's tags as chips (`TagChipsView`), filled on an ordinary row and outlined on a
/// selected one, as the Reader's File tags column draws them. One line of chips sits in the middle of the row, as the
/// other columns' text does; chips that wrap start at the top.
final class NotesTagsCellView: NSTableCellView {
    static let horizontalInset: CGFloat = 2
    static let verticalInset: CGFloat = 2
    let chips = TagChipsView()

    /// The width the chips wrap at in a Tags column `columnWidth` wide.
    static func chipsWidth(inColumn columnWidth: CGFloat) -> CGFloat { max(1, columnWidth - 2 * horizontalInset) }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        chips.placeholder = ""
        chips.setAccessibilityElement(true)
        chips.setAccessibilityRole(.staticText)
        addSubview(chips)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ tags: [String], font: NSFont) {
        chips.titles = tags
        chips.font = font
        chips.isHidden = false
        let text = tags.joined(separator: ", ")
        chips.setAccessibilityLabel(tags.isEmpty ? "No tags" : "Tags")
        chips.setAccessibilityValue(text)
        toolTip = tags.isEmpty ? nil : text
        needsLayout = true
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { chips.emphasized = backgroundStyle == .emphasized }
    }

    override func layout() {
        super.layout()
        placeChips()
    }

    /// A row whose height changes without a reload (the Tags column resized) resizes its cell; the chips follow.
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        placeChips()
    }

    private func placeChips() {
        let width = bounds.width - 2 * Self.horizontalInset
        let height = min(bounds.height, TagChipsView.height(for: chips.titles, font: chips.font, width: max(1, width)))
        chips.frame = CGRect(x: Self.horizontalInset, y: max(0, ((bounds.height - height) / 2).rounded()),
                             width: max(1, width), height: height)
    }
}

/// The list's scroll view. Under the UITest harness its tiling and layout calls feed `LayoutLoopProbe`, which
/// writes the sequence when one run-loop turn relays the view too many times (the stacked tree-toggle crash).
final class NotesListScrollView: NSScrollView {
    override func tile() {
        super.tile()
#if DEBUG
        LayoutLoopProbe.note(self, "tile")
#endif
    }

    override func layout() {
#if DEBUG
        LayoutLoopProbe.note(self, "layout")
#endif
        super.layout()
    }
}
