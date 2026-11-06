import PDFKit

/// One find hit, located by document (index into the viewer's open selection), by which image/OCR-text
/// **page pair** of that document it sits in (`DocumentPagePairs`), and by its ordinal among that pair's
/// hits. A hit covers BOTH panes of the pair (W40.fix-reader-find-both-panes): the image page's text layer
/// and the OCR text page carry the same words, so their k-th matches are taken as the same occurrence and
/// Find selects both at once. `left` / `right` are that pane's match ordinal, or nil when the pane has
/// fewer matches than the pair has hits (an image page with no text layer has none). Every page of an
/// interleaved multi-page PDF is addressable this way, so a match is never dropped for being "past page 2".
struct FindMatchLocation: Equatable, Sendable {
    var doc: Int
    var pair: Int    // which image/text page pair within that document (page 2·pair / 2·pair+1)
    var index: Int   // 0-based ordinal of the hit within that (doc, pair)
    var left: Int?   // the image page's match ordinal for this hit, if it has one
    var right: Int?  // the OCR text page's match ordinal for this hit, if it has one

    /// Whether `pane` shows this hit.
    func holds(_ pane: DocumentViewerModel.Pane) -> Bool { (pane == .left ? left : right) != nil }
}

/// Pure, view-free navigation over all find hits across the viewer's open documents. Holds the ordered
/// hit list (reading order: document ascending, then page pair ascending, then position on the page) and
/// a wrap-around cursor. All the fiddly logic — pairing the two panes' matches, ordering, wrap-around,
/// empty/one-match edge cases, the 1-based "N of M" position — lives here so it can be unit-tested
/// without a live `PDFView`. The model applies `current` to PDFKit; this type never touches a view.
struct FindNavigator: Equatable, Sendable {
    private(set) var locations: [FindMatchLocation]
    private(set) var cursor: Int?   // index into `locations`; nil when there are no matches

    init() {
        locations = []
        cursor = nil
    }

    /// Build the hit list from each pane's match count per `(doc, pair)`, kept in the caller's order
    /// (which is reading order). A pair has as many hits as its busier pane has matches, the k-th hit
    /// being each pane's k-th match, so stepping moves both panes together. Pairs with no match
    /// contribute nothing. The cursor starts on the first hit.
    init(perPair: [(doc: Int, pair: Int, left: Int, right: Int)]) {
        var locs: [FindMatchLocation] = []
        for entry in perPair {
            for k in 0..<max(entry.left, entry.right, 0) {
                locs.append(FindMatchLocation(doc: entry.doc, pair: entry.pair, index: k,
                                              left: k < entry.left ? k : nil,
                                              right: k < entry.right ? k : nil))
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

    /// The ranges of `query` in `text`, case-insensitive, in order — the extracted-text pane's matches,
    /// which are the image page's own text layer, so their k-th is the image pane's k-th.
    static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        var found: [Range<String.Index>] = []
        var from = text.startIndex
        while from < text.endIndex,
              let r = text.range(of: query, options: [.caseInsensitive], range: from..<text.endIndex) {
            found.append(r)
            from = r.upperBound > r.lowerBound ? r.upperBound : text.index(after: r.lowerBound)
        }
        return found
    }
}
