import PDFKit

/// One matched occurrence of the find query, located by document (index into the viewer's open
/// selection), by which image/OCR-text **page pair** of that document it sits in
/// (`DocumentPagePairs`), by which pane of that pair (left = the pair's image page, right = its OCR
/// text page), and by its ordinal among that pane's matches. Every page of an interleaved multi-page
/// PDF is addressable this way, so a match is never dropped for being "past page 2".
struct FindMatchLocation: Equatable, Sendable {
    var doc: Int
    var pair: Int    // which image/text page pair within that document (page 2·pair / 2·pair+1)
    var pane: DocumentViewerModel.Pane
    var index: Int   // 0-based ordinal within that (doc, pair, pane)
}

/// Pure, view-free navigation over all find matches across the viewer's open documents. Holds the
/// ordered match list (reading order: document ascending, then page pair ascending, then left/image
/// pane before right/text pane) and a wrap-around cursor. All the fiddly logic — ordering, wrap-around,
/// empty/one-match edge cases, the 1-based "N of M" position — lives here so it can be unit-tested
/// without a live `PDFView`. The model applies `current` to PDFKit; this type never touches a view.
struct FindNavigator: Equatable, Sendable {
    private(set) var locations: [FindMatchLocation]
    private(set) var cursor: Int?   // index into `locations`; nil when there are no matches

    init() {
        locations = []
        cursor = nil
    }

    /// Build the flat match list from per-`(doc, pair, pane)` counts, kept in the caller's order (which
    /// is reading order). Zero-count entries contribute nothing. The cursor starts on the first match.
    init(perPane: [(doc: Int, pair: Int, pane: DocumentViewerModel.Pane, count: Int)]) {
        var locs: [FindMatchLocation] = []
        for entry in perPane where entry.count > 0 {
            for k in 0..<entry.count {
                locs.append(FindMatchLocation(doc: entry.doc, pair: entry.pair, pane: entry.pane, index: k))
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

/// Counts find matches per displayable pane of every page pair in a document, matching how
/// `PDFView.highlightedSelections` / `findString` report matches so the counts line up with what gets
/// highlighted. Read-only: never mutates the document.
enum DocumentFindScanner {
    /// Case-insensitive match counts for `query`, one entry per page pair in reading order: entry `p`
    /// holds the matches on PDF page `2p` (`left`, the image page) and page `2p + 1` (`right`, the OCR
    /// text page). A single `findString` pass is bucketed by page, so **every** page of an interleaved
    /// multi-page PDF contributes — matches past page 2 used to be discarded, which made the later
    /// scans of a merged document unfindable even though the viewer can now navigate to them.
    /// Empty array for an empty query or an empty document.
    static func pairMatchCounts(in document: PDFDocument, query: String) -> [(left: Int, right: Int)] {
        let pairs = DocumentPagePairs.pairCount(pageCount: document.pageCount)
        guard !query.isEmpty, pairs > 0 else { return [] }
        var counts = [(left: Int, right: Int)](repeating: (0, 0), count: pairs)
        for selection in document.findString(query, withOptions: [.caseInsensitive]) {
            guard let page = selection.pages.first else { continue }
            let pageIndex = document.index(for: page)
            // `index(for:)` answers NSNotFound for a page that isn't in this document; the bounds check
            // below rejects that (and any future surprise) rather than trusting the arithmetic.
            let pair = DocumentPagePairs.pair(ofPageIndex: pageIndex)
            guard pageIndex >= 0, counts.indices.contains(pair) else { continue }
            if DocumentPagePairs.isImagePage(pageIndex) { counts[pair].left += 1 } else { counts[pair].right += 1 }
        }
        return counts
    }
}
