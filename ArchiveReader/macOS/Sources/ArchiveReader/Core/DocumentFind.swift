import PDFKit

/// One matched occurrence of the find query, located by document (index into the viewer's open
/// selection), which pane it lives in (left = image page 0, right = OCR text page 1), and its ordinal
/// among that pane's matches. The document viewer only ever displays a document's first two pages, so
/// matches are scoped to those two pages — you can navigate only to what the viewer can actually show.
struct FindMatchLocation: Equatable, Sendable {
    var doc: Int
    var pane: DocumentViewerModel.Pane
    var index: Int   // 0-based ordinal within that (doc, pane)
}

/// Pure, view-free navigation over all find matches across the viewer's open documents. Holds the
/// ordered match list (reading order: document ascending, left/image pane before right/text pane) and a
/// wrap-around cursor. All the fiddly logic — ordering, wrap-around, empty/one-match edge cases, the
/// 1-based "N of M" position — lives here so it can be unit-tested without a live `PDFView`. The model
/// applies `current` to PDFKit; this type never touches a view.
struct FindNavigator: Equatable, Sendable {
    private(set) var locations: [FindMatchLocation]
    private(set) var cursor: Int?   // index into `locations`; nil when there are no matches

    init() {
        locations = []
        cursor = nil
    }

    /// Build the flat match list from per-`(doc, pane)` counts, kept in the caller's order (which is
    /// reading order). Zero-count entries contribute nothing. The cursor starts on the first match.
    init(perPane: [(doc: Int, pane: DocumentViewerModel.Pane, count: Int)]) {
        var locs: [FindMatchLocation] = []
        for entry in perPane where entry.count > 0 {
            for k in 0..<entry.count {
                locs.append(FindMatchLocation(doc: entry.doc, pane: entry.pane, index: k))
            }
        }
        locations = locs
        cursor = locs.isEmpty ? nil : 0
    }

    var total: Int { locations.count }
    var isEmpty: Bool { locations.isEmpty }

    /// 1-based position of the current match, for a "3 of 12" label. `nil` when there are no matches.
    var ordinal: Int? { cursor.map { $0 + 1 } }

    var current: FindMatchLocation? {
        guard let c = cursor, locations.indices.contains(c) else { return nil }
        return locations[c]
    }

    /// Advance to the next match, wrapping past the end back to the first. Returns the new current match.
    @discardableResult mutating func next() -> FindMatchLocation? {
        guard !locations.isEmpty else { cursor = nil; return nil }
        cursor = ((cursor ?? -1) + 1) % locations.count
        return current
    }

    /// Step to the previous match, wrapping before the start back to the last. Returns the new current match.
    @discardableResult mutating func previous() -> FindMatchLocation? {
        guard !locations.isEmpty else { cursor = nil; return nil }
        let c = cursor ?? 0
        cursor = (c - 1 + locations.count) % locations.count
        return current
    }
}

/// Counts find matches on a document's displayable pages (page 0 → left pane, page 1 → right pane),
/// matching how `PDFView.highlightedSelections` / `findString` report matches so the counts line up
/// with what gets highlighted. Read-only: never mutates the document.
enum DocumentFindScanner {
    /// Number of case-insensitive matches for `query` on page 0 (`left`) and page 1 (`right`). Matches on
    /// any page ≥ 2 of a merged multi-page PDF are ignored — the two-pane viewer can't display them, so
    /// there's nowhere to navigate them to. A single `findString` pass is bucketed by page.
    static func paneMatchCounts(in document: PDFDocument, query: String) -> (left: Int, right: Int) {
        guard !query.isEmpty else { return (0, 0) }
        var left = 0
        var right = 0
        for selection in document.findString(query, withOptions: [.caseInsensitive]) {
            guard let page = selection.pages.first else { continue }
            switch document.index(for: page) {
            case 0: left += 1
            case 1: right += 1
            default: break
            }
        }
        return (left, right)
    }
}
