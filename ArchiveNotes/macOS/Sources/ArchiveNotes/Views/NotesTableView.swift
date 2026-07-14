import SwiftUI
import AppKit

// MARK: - NSViewRepresentable bridge

/// The item-list table for the Notes browser (W6-S3). Adapted wholesale from ArchiveReader's
/// `AppKitTableView` (Views/AppKitTableView.swift): the same virtualized `NSTableView` +
/// `NSTableViewDiffableDataSource<Int, UUID>` + `Coordinator` + `ColumnPickerHeaderView` +
/// `ContextMenuTableView` structure. Differences from Reader: identity is `ItemSummary.id` (UUID,
/// front-matter) not `ArchiveFile` (path, Finder tags); the columns are the Notes set
/// (kind/title/instances/date/quality/tags); and the tags column is **read-only** here (edited in the
/// detail inspector, W6-S7) — so none of Reader's inline `NSTokenField` editing machinery is copied.
struct NotesTableView: NSViewRepresentable {
    @ObservedObject var model: NotesNavigationModel
    @Binding var selection: Set<UUID>
    var onDoubleClick: () -> Void
    var buildContextMenu: (Set<UUID>) -> NSMenu?

    /// Non-hideable primary column (analogous to Reader's always-visible "File name").
    static let titleColumnID = "title"
    private static let fontSize: CGFloat = 13

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let tableView = ContextMenuTableView()
        tableView.setAccessibilityIdentifier("an.table")
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.rowHeight = max(20, Self.fontSize * 1.8)
        tableView.usesAutomaticRowHeights = true
        tableView.intercellSpacing = NSSize(width: 8, height: 2)

        let headerView = ColumnPickerHeaderView()
        headerView.setAccessibilityIdentifier("an.table.header")
        headerView.nonHideableColumnID = Self.titleColumnID
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
            coordinator?.parent.buildContextMenu(selIDs)
        }

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

        let hidden = NotesAppSettings.hiddenColumns
        for col in tableView.tableColumns where hidden.contains(col.identifier.rawValue) {
            col.isHidden = true
        }

        scrollView.documentView = tableView
        coordinator.tableView = tableView
        coordinator.displayedByID = Dictionary(uniqueKeysWithValues: model.displayed.map { ($0.id, $0) })

        let dataSource = NotesTableDataSource(tableView: tableView) { tv, column, row, itemID in
            coordinator.makeCell(tableView: tv, column: column, row: row, itemID: itemID)
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
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let tableView = coordinator.tableView else { return }
        coordinator.parent = self

        // Only rebuild the O(N) lookup + diff the snapshot when `displayed` actually changed.
        let gen = model.displayedGeneration
        if coordinator.lastDisplayedGeneration != gen {
            coordinator.lastDisplayedGeneration = gen
            coordinator.displayedByID = Dictionary(uniqueKeysWithValues: model.displayed.map { ($0.id, $0) })

            let newIDs = model.displayed.map(\.id)
            if newIDs != coordinator.currentSnapshotIDs {
                coordinator.applySnapshot(newIDs, animated: false)
            } else {
                // IDs unchanged but values may have changed — reload visible rows.
                let visRange = tableView.rows(in: tableView.visibleRect)
                if visRange.length > 0 {
                    tableView.reloadData(
                        forRowIndexes: IndexSet(integersIn: visRange.location..<(visRange.location + visRange.length)),
                        columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
                }
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
        var isUpdatingSelection = false
        var isSortingFromModel = false
        var displayedByID: [UUID: ItemSummary] = [:]
        var lastDisplayedGeneration = -1
        var currentSnapshotIDs: [UUID] = []

        init(_ parent: NotesTableView) { self.parent = parent }

        func applySnapshot(_ ids: [UUID], animated: Bool) {
            guard ids != currentSnapshotIDs else { return }
            currentSnapshotIDs = ids
            var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
            snapshot.appendSections([0])
            snapshot.appendItems(ids, toSection: 0)
            dataSource?.apply(snapshot, animatingDifferences: animated)
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

        func makeCell(tableView: NSTableView, column: NSTableColumn, row: Int, itemID: UUID) -> NSView {
            let colID = column.identifier.rawValue
            let item = displayedByID[itemID]

            if colID == "kind" { return makeKindCell(tableView: tableView, item: item) }

            let cellID = NSUserInterfaceItemIdentifier("cell.\(colID)")
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = cellID
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
                let displayTitle = item.title.isEmpty ? "Untitled" : item.title
                // Replicated items (in >1 folder) get a subtle accent-colored chain glyph prefix, so a
                // replicant reads as one at a glance (the "In" column shows the count). W6-S5, §5.
                if (parent.model.instanceCounts[item.id] ?? 0) > 1 {
                    let styled = NSMutableAttributedString(
                        string: "⧉ ",
                        attributes: [.foregroundColor: NSColor.controlAccentColor, .font: regularFont])
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
                tf.textColor = .secondaryLabelColor
                tf.setAccessibilityIdentifier("an.cell.instances.\(item.id.uuidString)")

            case "date":
                tf.stringValue = item.displayDate ?? "—"
                tf.textColor = item.sortDate == nil ? .secondaryLabelColor : .labelColor
                if item.dateUncertain {
                    tf.font = NSFontManager.shared.convert(regularFont, toHaveTrait: .italicFontMask)
                }
                tf.setAccessibilityIdentifier("an.cell.date.\(item.id.uuidString)")

            case "quality":
                tf.stringValue = item.qualityStars
                tf.textColor = item.quality == nil ? .secondaryLabelColor : .systemYellow
                tf.setAccessibilityIdentifier("an.cell.quality.\(item.id.uuidString)")

            case "sources":
                // Distinct source notes for a segmented extract; blank for notes / source-less
                // extracts. The Extracts window features this; a notes list shows it empty (W7-S4, §4).
                tf.stringValue = item.sourcesText
                tf.textColor = .secondaryLabelColor
                tf.setAccessibilityIdentifier("an.cell.sources.\(item.id.uuidString)")

            case "tags":
                tf.stringValue = item.displayTags
                tf.textColor = .secondaryLabelColor
                tf.setAccessibilityIdentifier("an.cell.tags.\(item.id.uuidString)")

            default:
                tf.stringValue = ""
            }
            return cell
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
            parent.onDoubleClick()
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
        var hidden = NotesAppSettings.hiddenColumns
        if col.isHidden { hidden.insert(id) } else { hidden.remove(id) }
        NotesAppSettings.setHiddenColumns(hidden)
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
/// plus the same JSON as `.string` (so the SwiftUI `dropDestination(for: String.self)` on folder rows
/// can read it without a declared `UTType`). No file bytes ever cross the pasteboard.
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
