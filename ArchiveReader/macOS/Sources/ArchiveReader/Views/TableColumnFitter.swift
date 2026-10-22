import AppKit

/// Fits the table's columns into the width its scroll view shows by narrowing the flexible columns (File name and
/// File tags) and leaving the rest alone (W40.fix-reader-tagcloud-width).
///
/// Before this the table used last-column-only autoresizing. Opening the 240-pt tag cloud took the width from Read
/// alone, which stopped at its minimum, so Quality showed "Qua" and Read could only be reached by scrolling
/// sideways. AppKit's uniform style was tried next and fell short in two ways. It works from the CHANGE in width,
/// so once File tags reached its minimum the rest of the cut was not passed to File name and the table still
/// overflowed. And closing the cloud did not give each column back what it gave up. This fit is instead a function
/// of the space and each flexible column's preferred width (the width it was built with, or the last one the user
/// dragged it to), so opening and closing the cloud any number of times puts them back exactly.
///
/// Only a narrower space changes anything. A wider one leaves the columns at their preferred widths, with blank
/// space after Read, as the old style did once Read reached its maximum. Past what the flexible columns can give
/// (both at their minimums), the table scrolls sideways; Quality and Read are never squeezed.
@MainActor
final class TableColumnFitter: NSObject {
    private weak var tableView: NSTableView?
    private let flexibleIDs: [String]
    private var preferred: [String: CGFloat] = [:]
    private var isFitting = false

    init(tableView: NSTableView, flexibleIDs: [String]) {
        self.tableView = tableView
        self.flexibleIDs = flexibleIDs
        super.init()
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        for column in tableView.tableColumns where flexibleIDs.contains(column.identifier.rawValue) {
            preferred[column.identifier.rawValue] = column.width
        }
        NotificationCenter.default.addObserver(self, selector: #selector(columnDidResize(_:)),
                                               name: NSTableView.columnDidResizeNotification, object: tableView)
        if let clip = tableView.enclosingScrollView?.contentView {
            clip.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(clipFrameDidChange(_:)),
                                                   name: NSView.frameDidChangeNotification, object: clip)
        }
        fit()
    }

    /// The flexible columns' widths when `available` points are left for them: their preferred widths if those
    /// fit, otherwise each gives up a share of the shortfall in proportion to how far it is above its minimum.
    /// Whole points that add up to `available` rounded down, the last column taking the remainder. Rounding each
    /// share down on its own let the sum, and so where Read starts, jitter by a point as the sidebar slid in
    /// (TransientStateUITests saw Read go 1007 → 1223 → 1222); while the cut lasts, Read now stays put.
    nonisolated static func widths(preferred: [CGFloat], minimums: [CGFloat], available: CGFloat) -> [CGFloat] {
        let total = preferred.reduce(0, +)
        guard total > available else { return preferred }
        let slack = zip(preferred, minimums).map { max(0, $0 - $1) }
        let totalSlack = slack.reduce(0, +)
        guard totalSlack > 0 else { return preferred }
        let cut = min(total - available, totalSlack)
        var result = zip(preferred, slack).map { p, s in (p - cut * s / totalSlack).rounded(.down) }
        let last = result.count - 1
        let sumOfOthers = result.dropLast().reduce(0, +)
        result[last] = max(minimums[last], (total - cut).rounded(.down) - sumOfOthers)
        return result
    }

    /// Refit to the scroll view's current width. Also called after a column is shown or hidden.
    func fit() {
        guard !isFitting, let tableView, let clip = tableView.enclosingScrollView?.contentView else { return }
        let visible = tableView.tableColumns.filter { !$0.isHidden }
        let flexible = visible.filter { flexibleIDs.contains($0.identifier.rawValue) }
        guard !flexible.isEmpty else { return }
        let fixed = visible.filter { !flexibleIDs.contains($0.identifier.rawValue) }.reduce(0) { $0 + $1.width }
        let available = clip.bounds.width - fixed - CGFloat(visible.count) * tableView.intercellSpacing.width
        let target = Self.widths(preferred: flexible.map { preferred[$0.identifier.rawValue] ?? $0.width },
                                 minimums: flexible.map(\.minWidth), available: available)
        isFitting = true
        defer { isFitting = false }
        var changed = false
        for (column, width) in zip(flexible, target) where column.width != width {
            column.width = width
            changed = true
        }
        if changed { remeasureVisibleRows() }
    }

    /// Automatic row heights are measured once per row, so a File tags column made narrower would leave its wrapped
    /// second line of tags drawn below the row. Only the rows on screen: the rest are measured as they scroll in.
    private func remeasureVisibleRows() {
        guard let tableView else { return }
        let rows = tableView.rows(in: tableView.visibleRect)
        guard rows.length > 0 else { return }
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: rows.location..<NSMaxRange(rows)))
    }

    @objc private func clipFrameDidChange(_ note: Notification) { fit() }

    /// A drag by the user sets that column's preferred width. It is not refitted at once: that would fight the drag,
    /// and a user who widens File name past the window is asking to scroll.
    @objc private func columnDidResize(_ note: Notification) {
        guard !isFitting, let column = note.userInfo?["NSTableColumn"] as? NSTableColumn,
              flexibleIDs.contains(column.identifier.rawValue) else { return }
        preferred[column.identifier.rawValue] = column.width
        remeasureVisibleRows()
    }
}
