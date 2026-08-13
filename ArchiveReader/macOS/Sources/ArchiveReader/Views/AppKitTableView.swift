import SwiftUI
import AppKit
import ArchiveCore

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
    }

    /// One source for construction and tests. Provenance is display-only and receives a one-time
    /// default-hidden migration; the existing header picker then persists the explicit user choice.
    static let columnDefinitions: [ColumnDefinition] = [
        .init(id: "flag", title: "⚑", width: 26, minWidth: 26, maxWidth: 30, sortField: nil),
        .init(id: "warning", title: "⚠︎", width: 24, minWidth: 24, maxWidth: 28, sortField: nil),
        .init(id: "date", title: "Document date", width: 140, minWidth: 110, maxWidth: 220, sortField: .date),
        .init(id: "name", title: "File name", width: 320, minWidth: 200, maxWidth: 800, sortField: .name),
        .init(id: "type", title: "Type", width: 56, minWidth: 44, maxWidth: 80, sortField: .fileType),
        .init(id: "classification", title: "Provenance", width: 132, minWidth: 100, maxWidth: 220, sortField: nil),
        .init(id: "tags", title: "File tags", width: 300, minWidth: 160, maxWidth: 600, sortField: .subjects),
        .init(id: "priority", title: "Priority", width: 72, minWidth: 60, maxWidth: 100, sortField: .priority),
        .init(id: "read", title: "Read", width: 84, minWidth: 70, maxWidth: 110, sortField: .readState),
    ]

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
        tableView.setAccessibilityIdentifier("ar.table")
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
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
        tableView.headerView = headerView
        tableView.target = coordinator
        tableView.doubleAction = #selector(Coordinator.tableViewDoubleClicked(_:))
        tableView.contextMenuProvider = { [weak coordinator] selIDs in
            coordinator?.parent.buildContextMenu(selIDs)
        }

        for col in Self.columnDefinitions {
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

        let dataSource = SortableDiffableDataSource(tableView: tableView) { tv, column, row, itemID in
            coordinator.makeCell(tableView: tv, column: column, row: row, itemID: itemID)
        }
        // Header-click sorting: `sortDescriptorsDidChange` is an NSTableViewDataSource callback, so it
        // must live on the DATA SOURCE (the diffable source is the real dataSource) — not the coordinator,
        // which is only the table's delegate — or header clicks never reach the model. The subclass
        // forwards it to the coordinator here.
        dataSource.onSortDescriptorsChange = { [weak coordinator] descriptors in
            coordinator?.applyHeaderSort(descriptors)
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

        // Only rebuild the O(N) lookup dictionary + diff the snapshot when `displayed` actually changed.
        let gen = model.displayedGeneration
        if coordinator.lastDisplayedGeneration != gen {
            coordinator.lastDisplayedGeneration = gen
            coordinator.displayedByID = Dictionary(uniqueKeysWithValues: model.displayed.map { ($0.id, $0) })

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
        var lastDisplayedGeneration: Int = -1
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
                    tf.topAnchor.constraint(greaterThanOrEqualTo: cell.topAnchor, constant: 2),
                    tf.bottomAnchor.constraint(lessThanOrEqualTo: cell.bottomAnchor, constant: -2),
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
                let nameLine = NSMutableAttributedString()
                if let color = file.color {
                    let dotColor: NSColor = color == .box ? .systemRed : .systemPurple
                    nameLine.append(NSAttributedString(string: "● ", attributes: [
                        .foregroundColor: dotColor,
                        .font: NSFont.systemFont(ofSize: currentFontSize * 0.7),
                    ]))
                }
                nameLine.append(NSAttributedString(string: file.name, attributes: [
                    .foregroundColor: NSColor.labelColor,
                    .font: regularFont,
                ]))
                if parent.model.isDuplicatedName(file.name) {
                    let folder = DuplicateNames.disambiguator(for: file.url)
                    nameLine.append(NSAttributedString(string: "  ⌕ \(folder)", attributes: [
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .font: NSFont.systemFont(ofSize: currentFontSize * 0.85),
                    ]))
                }
                if let segs = parent.model.searchSnippet(for: file.url.path) {
                    // Full-text search hit: add a dimmed keyword-in-context OCR excerpt beneath the name
                    // (usesAutomaticRowHeights grows the row). Per-line paragraph styles keep the name
                    // middle-truncated (extension visible) and the excerpt tail-truncated.
                    let nameStyle = NSMutableParagraphStyle()
                    nameStyle.lineBreakMode = .byTruncatingMiddle
                    nameLine.addAttribute(.paragraphStyle, value: nameStyle,
                                          range: NSRange(location: 0, length: nameLine.length))
                    nameLine.append(NSAttributedString(string: "\n"))
                    nameLine.append(Self.snippetLine(segs, baseSize: currentFontSize))
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

            case "type":
                tf.stringValue = file.fileType
                tf.textColor = .secondaryLabelColor

            case "classification":
                Self.configureProvenanceTextField(
                    tf, classification: parent.model.classification(for: file.url.path),
                    fontSize: currentFontSize
                )

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
            // Mirrors SubjectTokenField.updateNSView's currentEditor() guard.
            if tagCell.tokenField.currentEditor() == nil {
                tagCell.tokenField.objectValue = file?.subjects ?? []
                tagCell.itemID = itemID
                tagCell.editBase = nil
            }
            tagCell.tokenField.font = .systemFont(ofSize: currentFontSize)
            // Per-row accessibility id so XCUITest can target a specific row's tag cell
            tagCell.tokenField.setAccessibilityIdentifier("ar.cell.tags.\(file?.name ?? "")")
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
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - Column-picker header view

/// Right-click the table header → a menu with checkmark toggles for each column plus sort options.
/// "File name" is always visible (disabled toggle); all others can be hidden. If the clicked
/// column is sortable, a secondary-sort section lets the user set it without Option-clicking.
@MainActor
final class ColumnPickerHeaderView: NSTableHeaderView {
    /// Callback to set a secondary sort field. Parameters: (field, ascending).
    var onSetSecondarySort: ((SortField, Bool) -> Void)?
    /// Callback to remove the secondary sort (collapse to primary only).
    var onRemoveSecondarySort: (() -> Void)?
    /// Callback to reset sort to the default (date, then name).
    var onResetSort: (() -> Void)?
    /// Returns the current sort descriptors so the menu can reflect active state.
    var currentSort: (() -> [ARSortDescriptor])?

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let tv = tableView else { return nil }
        let menu = NSMenu(title: "Columns")

        // Column visibility toggles
        for col in tv.tableColumns {
            let id = col.identifier.rawValue
            let item = NSMenuItem(title: col.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = col.isHidden ? .off : .on
            if id == "name" { item.isEnabled = false }
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

                let resetItem = NSMenuItem(title: "Default Sort (date, then name)", action: #selector(resetSort(_:)), keyEquivalent: "")
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
        var hidden = AppSettings.hiddenColumns
        if col.isHidden { hidden.insert(id) } else { hidden.remove(id) }
        AppSettings.setHiddenColumns(hidden)
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
