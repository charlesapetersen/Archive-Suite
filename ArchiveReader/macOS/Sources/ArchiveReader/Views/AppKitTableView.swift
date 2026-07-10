import SwiftUI
import AppKit

// MARK: - NSViewRepresentable bridge

/// A high-performance AppKit `NSTableView` wrapped for SwiftUI. Replaces the SwiftUI `Table` for
/// the navigation window: virtualized rows (cell reuse), incremental diffable-data-source apply,
/// and AppKit-native column-header sorting. The data model (`NavigationModel.displayed`) and tag
/// mutations (`NavigationModel`) are unchanged — this is a VIEW-layer swap only.
struct AppKitTableView: NSViewRepresentable {
    @ObservedObject var model: NavigationModel
    @Binding var selection: Set<ArchiveFile.ID>
    var fontSize: CGFloat
    var scrollRequest: Int
    var scrollTargetID: ArchiveFile.ID?
    var onDoubleClick: () -> Void
    var buildContextMenu: (Set<ArchiveFile.ID>) -> NSMenu?

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
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.rowHeight = max(20, fontSize * 1.8)
        tableView.intercellSpacing = NSSize(width: 8, height: 2)
        tableView.headerView = ColumnPickerHeaderView()
        tableView.target = coordinator
        tableView.doubleAction = #selector(Coordinator.tableViewDoubleClicked(_:))
        tableView.contextMenuProvider = { [weak coordinator] selIDs in
            coordinator?.parent.buildContextMenu(selIDs)
        }

        let columns: [(id: String, title: String, width: CGFloat, minWidth: CGFloat, maxWidth: CGFloat, sortField: SortField?)] = [
            ("flag",     "⚑",             26,  26,   30,  nil),
            ("warning",  "⚠︎",             24,  24,   28,  nil),
            ("date",     "Document date",  140, 110,  220, .date),
            ("name",     "File name",      320, 200,  800, .name),
            ("type",     "Type",           56,  44,   80,  .fileType),
            ("tags",     "File tags",      300, 160,  600, .subjects),
            ("priority", "Priority",       72,  60,   100, .priority),
            ("read",     "Read",           84,  70,   110, .readState),
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

        let hidden = AppSettings.hiddenColumns
        for col in tableView.tableColumns where hidden.contains(col.identifier.rawValue) {
            col.isHidden = true
        }

        scrollView.documentView = tableView
        coordinator.tableView = tableView
        coordinator.displayedByID = Dictionary(uniqueKeysWithValues: model.displayed.map { ($0.id, $0) })

        let dataSource = NSTableViewDiffableDataSource<Int, ArchiveFile.ID>(tableView: tableView) { tv, column, row, itemID in
            coordinator.makeCell(tableView: tv, column: column, row: row, itemID: itemID)
        }
        coordinator.dataSource = dataSource
        tableView.delegate = coordinator
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

        coordinator.displayedByID = Dictionary(uniqueKeysWithValues: model.displayed.map { ($0.id, $0) })

        // Snapshot (incremental diff)
        let newIDs = model.displayed.map(\.id)
        let idsChanged = newIDs != coordinator.currentSnapshotIDs
        if idsChanged {
            coordinator.applySnapshot(newIDs, animated: false)
        } else {
            // IDs unchanged but values may have changed (tag edit, flag toggle) — reload visible rows.
            // Exclude the row with an active tag edit to prevent editor dismissal.
            let visRange = tableView.rows(in: tableView.visibleRect)
            if visRange.length > 0 {
                var rowSet = IndexSet(integersIn: visRange.location..<(visRange.location + visRange.length))
                if let editID = coordinator.editingItemID,
                   let editIdx = coordinator.currentSnapshotIDs.firstIndex(of: editID) {
                    rowSet.remove(editIdx)
                }
                if !rowSet.isEmpty {
                    tableView.reloadData(
                        forRowIndexes: rowSet,
                        columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
                }
            }
        }

        // Selection sync (SwiftUI → AppKit)
        if coordinator.lastPushedSelection != selection {
            coordinator.syncSelection(selection)
        }

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
            if let idx = coordinator.currentSnapshotIDs.firstIndex(of: target) {
                tableView.scrollRowToVisible(idx)
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
        var lastPushedSelection: Set<ArchiveFile.ID> = []
        var isUpdatingSelection = false
        var isSortingFromModel = false
        var lastScrollRequest = 0
        var displayedByID: [ArchiveFile.ID: ArchiveFile] = [:]
        var currentSnapshotIDs: [ArchiveFile.ID] = []
        var editingItemID: ArchiveFile.ID?

        init(_ parent: AppKitTableView) {
            self.parent = parent
            self.currentFontSize = parent.fontSize
        }

        func applySnapshot(_ ids: [ArchiveFile.ID], animated: Bool) {
            guard ids != currentSnapshotIDs else { return }
            currentSnapshotIDs = ids
            var snapshot = NSDiffableDataSourceSnapshot<Int, ArchiveFile.ID>()
            snapshot.appendSections([0])
            snapshot.appendItems(ids, toSection: 0)
            dataSource?.apply(snapshot, animatingDifferences: animated)
        }

        func syncSelection(_ sel: Set<ArchiveFile.ID>) {
            guard let tableView else { return }
            isUpdatingSelection = true
            defer { isUpdatingSelection = false; lastPushedSelection = sel }
            var indexSet = IndexSet()
            for (i, id) in currentSnapshotIDs.enumerated() {
                if sel.contains(id) { indexSet.insert(i) }
            }
            tableView.selectRowIndexes(indexSet, byExtendingSelection: false)
        }

        // MARK: Cell factory

        func makeCell(tableView: NSTableView, column: NSTableColumn, row: Int, itemID: ArchiveFile.ID) -> NSView {
            let colID = column.identifier.rawValue
            let file = displayedByID[itemID]

            // Tags column: inline-editable NSTokenField cell
            if colID == "tags" {
                return makeTagTokenCell(tableView: tableView, itemID: itemID, file: file)
            }

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
                    tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }

            guard let file else {
                cell.textField?.stringValue = ""
                return cell
            }

            let tf = cell.textField!
            let regularFont = NSFont.systemFont(ofSize: currentFontSize)
            tf.font = regularFont
            tf.textColor = .labelColor
            tf.toolTip = nil

            switch colID {
            case "flag":
                let flagged = parent.model.notes.isFlagged(file.url.path)
                tf.stringValue = flagged ? "⚑" : ""
                tf.textColor = flagged ? .systemOrange : .secondaryLabelColor

            case "warning":
                if let status = parent.model.formatStatus(for: file.url.path), status.needsAttention {
                    tf.stringValue = "⚠"
                    tf.textColor = .systemOrange
                    tf.toolTip = status.label
                } else {
                    tf.stringValue = ""
                }

            case "date":
                tf.stringValue = file.tags.displayDate ?? "—"
                tf.textColor = file.sortDate == nil ? .secondaryLabelColor : .labelColor
                if file.dateIsSpeculative {
                    tf.font = NSFontManager.shared.convert(regularFont, toHaveTrait: .italicFontMask)
                }

            case "name":
                if let color = file.color {
                    let as_ = NSMutableAttributedString()
                    let dotColor: NSColor = color == .box ? .systemRed : .systemPurple
                    as_.append(NSAttributedString(string: "● ", attributes: [
                        .foregroundColor: dotColor,
                        .font: NSFont.systemFont(ofSize: currentFontSize * 0.7),
                    ]))
                    as_.append(NSAttributedString(string: file.name, attributes: [
                        .foregroundColor: NSColor.labelColor,
                        .font: regularFont,
                    ]))
                    if parent.model.isDuplicatedName(file.name) {
                        let folder = DuplicateNames.disambiguator(for: file.url)
                        as_.append(NSAttributedString(string: "  ⌕ \(folder)", attributes: [
                            .foregroundColor: NSColor.secondaryLabelColor,
                            .font: NSFont.systemFont(ofSize: currentFontSize * 0.85),
                        ]))
                    }
                    tf.attributedStringValue = as_
                } else if parent.model.isDuplicatedName(file.name) {
                    let as_ = NSMutableAttributedString()
                    as_.append(NSAttributedString(string: file.name, attributes: [
                        .foregroundColor: NSColor.labelColor,
                        .font: regularFont,
                    ]))
                    let folder = DuplicateNames.disambiguator(for: file.url)
                    as_.append(NSAttributedString(string: "  ⌕ \(folder)", attributes: [
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .font: NSFont.systemFont(ofSize: currentFontSize * 0.85),
                    ]))
                    tf.attributedStringValue = as_
                } else {
                    tf.stringValue = file.name
                }
                tf.lineBreakMode = .byTruncatingMiddle

            case "type":
                tf.stringValue = file.fileType
                tf.textColor = .secondaryLabelColor

            case "priority":
                tf.stringValue = file.priority.map { "P\($0)" } ?? "—"
                tf.textColor = .secondaryLabelColor

            case "read":
                let state = file.readState
                tf.stringValue = state?.rawValue ?? "—"
                tf.textColor = state == .unread ? .controlAccentColor : .secondaryLabelColor

            default:
                tf.stringValue = ""
            }

            return cell
        }

        // MARK: NSTableViewDelegate

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdatingSelection, let tableView else { return }
            let indices = tableView.selectedRowIndexes
            var newSel = Set<ArchiveFile.ID>()
            for i in indices {
                if i < currentSnapshotIDs.count {
                    newSel.insert(currentSnapshotIDs[i])
                }
            }
            lastPushedSelection = newSel
            parent.selection = newSel
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isSortingFromModel else { return }
            let descriptors = tableView.sortDescriptors.compactMap { sd -> ARSortDescriptor? in
                guard let key = sd.key, let field = SortField(rawValue: key) else { return nil }
                return ARSortDescriptor(field: field, ascending: sd.ascending)
            }
            if !descriptors.isEmpty {
                parent.model.sort = descriptors
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
            // Mirrors SubjectTokenField.updateNSView's currentEditor() guard.
            if tagCell.tokenField.currentEditor() == nil {
                tagCell.tokenField.objectValue = file?.subjects ?? []
                tagCell.itemID = itemID
                tagCell.editBase = nil
            }
            tagCell.tokenField.font = .systemFont(ofSize: currentFontSize)
            return tagCell
        }

        func tokenField(_ tokenField: NSTokenField, completionsForSubstring substring: String,
                        indexOfToken tokenIndex: Int,
                        indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?) -> [Any]? {
            let s = substring.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { return [] }
            let suggestions = parent.model.allSubjects
            return Array(suggestions.filter {
                $0.caseInsensitiveCompare(s) != .orderedSame &&
                $0.range(of: s, options: [.caseInsensitive, .anchored]) != nil
            }.prefix(20))
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            guard let tf = obj.object as? NSTokenField,
                  let tagCell = tf.superview as? TagTokenCellView else { return }
            tagCell.editBase = (tf.objectValue as? [String]) ?? []
            editingItemID = tagCell.itemID
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let tf = obj.object as? NSTokenField,
                  let tagCell = tf.superview as? TagTokenCellView,
                  let base = tagCell.editBase,
                  let fileID = tagCell.itemID,
                  let file = displayedByID[fileID] else {
                editingItemID = nil
                return
            }
            tagCell.editBase = nil
            editingItemID = nil
            let edited = (tf.objectValue as? [String]) ?? []
            parent.model.commitSubjectEdit(from: base, to: edited, for: file)
        }
    }
}

// MARK: - Tag token cell view for inline tag editing

/// Custom cell for the "File tags" column: an `NSTokenField` that renders subject tags as removable
/// chips and supports inline add/remove with autocomplete. The cell stores the file ID and edit-start
/// base so the coordinator's delegate methods can commit through `TagWriter`.
@MainActor
final class TagTokenCellView: NSTableCellView {
    let tokenField: NSTokenField = {
        let tf = NSTokenField()
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.tokenStyle = .rounded
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.placeholderString = "Add tags\u{2026}"
        tf.tokenizingCharacterSet = CharacterSet(charactersIn: ",")
        tf.lineBreakMode = .byTruncatingTail
        tf.usesSingleLineMode = true
        if let cell = tf.cell as? NSTokenFieldCell { cell.wraps = false; cell.isScrollable = true }
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
            tokenField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - Column-picker header view

/// Right-click the table header → a menu with checkmark toggles for each column.
/// "File name" is always visible (disabled toggle); all others can be hidden.
@MainActor
final class ColumnPickerHeaderView: NSTableHeaderView {
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let tv = tableView else { return nil }
        let menu = NSMenu(title: "Columns")
        for col in tv.tableColumns {
            let id = col.identifier.rawValue
            let item = NSMenuItem(title: col.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = col.isHidden ? .off : .on
            if id == "name" { item.isEnabled = false }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let tv = tableView,
              let col = tv.tableColumns.first(where: { $0.identifier.rawValue == id }) else { return }
        col.isHidden.toggle()
        var hidden = AppSettings.hiddenColumns
        if col.isHidden { hidden.insert(id) } else { hidden.remove(id) }
        AppSettings.setHiddenColumns(hidden)
    }
}

// MARK: - Context-menu NSTableView subclass

@MainActor
final class ContextMenuTableView: NSTableView {
    var contextMenuProvider: ((Set<ArchiveFile.ID>) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
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
