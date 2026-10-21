import SwiftUI

/// The navigation window's filter bar: one row when its controls fit, more when they do not
/// (W40.fix-reader-narrow-window).
///
/// It was an `HStack`, whose minimum width is the sum of its controls' minimums. At the window's 900-pt
/// minimum with the sidebar showing, that sum (plus the needs-attention toggle, plus "Save as Smart Folder"
/// and "Clear" once a filter is on) was wider than the content column, so the whole window's root `HStack`
/// overflowed on both sides: the sidebar started 50 pt left of the window and the toggle sat past its right
/// edge. This layout never asks for more width than it is offered; a control that does not fit moves to the
/// next row.
///
/// It is a `Layout` rather than a `ViewThatFits` over one-, two- and three-row copies on purpose: switching
/// copies rebuilds every control in the bar, so a filter that adds the Save/Clear buttons (which widen the
/// bar) rebuilds the text field the user is typing in and takes the keyboard from it (W40.fix-reader-filter-focus,
/// shown for the name and OCR fields). Here the subviews keep their identity; only their placement changes.
///
/// Each subview's minimum is its width when offered nothing, its ideal its width when offered no limit. Rows
/// break on the minimums; a row's spare width then goes to its controls in order, first up to each one's
/// ideal and then up to its maximum (its width when offered unlimited room, the fields' `maxWidth`). A
/// subview marked `.filterBarTrailing()` sits at its row's right edge (the old bar's `Spacer`).
struct FilterBarLayout: Layout {
    var spacing: CGFloat = 12
    var rowSpacing: CGFloat = 6

    struct Item: Equatable {
        var min: CGFloat
        var ideal: CGFloat
        var max: CGFloat
        var trailing = false

        init(min: CGFloat, ideal: CGFloat, max: CGFloat? = nil, trailing: Bool = false) {
            self.min = min; self.ideal = Swift.max(min, ideal); self.max = Swift.max(self.ideal, max ?? ideal)
            self.trailing = trailing
        }
    }

    struct Placed: Equatable {
        var index: Int
        var x: CGFloat
        var width: CGFloat
    }

    /// The rows for `items` in `width`: which subview goes where, and how wide. Pure, so it is unit-tested.
    static func rows(_ items: [Item], width: CGFloat, spacing: CGFloat) -> [[Placed]] {
        var rows: [[Int]] = [[]]
        var used: CGFloat = 0
        for (i, item) in items.enumerated() {
            let needed = rows[rows.count - 1].isEmpty ? item.min : used + spacing + item.min
            if !rows[rows.count - 1].isEmpty, needed > width {
                rows.append([i]); used = item.min
            } else {
                rows[rows.count - 1].append(i); used = needed
            }
        }
        return rows.filter { !$0.isEmpty }.map { row in
            var spare = width - row.reduce(0) { $0 + items[$1].min } - spacing * CGFloat(row.count - 1)
            var widths = row.map { items[$0].min }
            for limit in [\Item.ideal, \Item.max] {
                for (k, i) in row.enumerated() where spare > 0 {
                    let grow = min(spare, max(0, items[i][keyPath: limit] - widths[k]))
                    widths[k] += grow; spare -= grow
                }
            }
            // Leading controls run from the left; trailing ones are packed against the right edge.
            var placed: [Placed] = []
            var x: CGFloat = 0
            for (k, i) in row.enumerated() where !items[i].trailing {
                placed.append(Placed(index: i, x: x, width: widths[k])); x += widths[k] + spacing
            }
            var right = max(x - spacing, width)
            for (k, i) in row.enumerated().reversed() where items[i].trailing {
                right -= widths[k]
                placed.append(Placed(index: i, x: right, width: widths[k])); right -= spacing
            }
            return placed.sorted { $0.index < $1.index }
        }
    }

    private func items(_ subviews: Subviews) -> [Item] {
        subviews.map { v in
            let lo = v.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width
            let ideal = v.sizeThatFits(.unspecified).width
            let most = v.sizeThatFits(ProposedViewSize(width: .infinity, height: nil)).width
            return Item(min: lo, ideal: ideal, max: most.isFinite ? most : ideal, trailing: v[FilterBarTrailing.self])
        }
    }

    private func layout(_ subviews: Subviews, width: CGFloat) -> (rows: [[Placed]], heights: [CGFloat]) {
        let rows = Self.rows(items(subviews), width: width, spacing: spacing)
        let heights = rows.map { row in
            row.map { subviews[$0.index].sizeThatFits(ProposedViewSize(width: $0.width, height: nil)).height }
                .max() ?? 0
        }
        return (rows, heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let all = items(subviews)
        let oneRow = all.reduce(0) { $0 + $1.ideal } + spacing * CGFloat(max(0, all.count - 1))
        // It fills the width it is offered, as the old bar's `Spacer` made it. Offered nothing (the window asking
        // for its minimum), it needs only its widest control; offered no limit, one row.
        let widest = all.map(\.min).max() ?? 0
        let offered = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? oneRow
        let width = max(offered, widest)
        let (_, heights) = layout(subviews, width: width)
        let height = heights.reduce(0, +) + rowSpacing * CGFloat(max(0, heights.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let (rows, heights) = layout(subviews, width: bounds.width)
        var y = bounds.minY
        for (row, height) in zip(rows, heights) {
            for p in row {
                subviews[p.index].place(at: CGPoint(x: bounds.minX + p.x, y: y + height / 2), anchor: .leading,
                                        proposal: ProposedViewSize(width: p.width, height: nil))
            }
            y += height + rowSpacing
        }
    }
}

private struct FilterBarTrailing: LayoutValueKey {
    static let defaultValue = false
}

extension View {
    /// Pin this filter-bar control to the right edge of its row (see `FilterBarLayout`).
    func filterBarTrailing() -> some View { layoutValue(key: FilterBarTrailing.self, value: true) }
}
