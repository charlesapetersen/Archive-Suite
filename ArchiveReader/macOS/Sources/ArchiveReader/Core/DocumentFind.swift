import PDFKit

/// One find hit, located by document (index into the viewer's open selection), by which image/OCR-text
/// **page pair** of that document it sits in (`DocumentPagePairs`), and by its ordinal among that pair's
/// hits. A hit covers BOTH panes of the pair (W40.fix-reader-find-both-panes): the image page's text layer
/// and the OCR text page carry much the same words, and a match in one is paired with the match on the
/// same word of the other through a word alignment of the two pages (`FindWordAlignment`,
/// W49.reader-find-word-align), so Find selects the same occurrence in both at once. `left` / `right` are
/// that pane's match ordinal, or nil when the other pane's match has no counterpart there (a word the text
/// layer split or missed; an image page with no text layer has none at all). Every page of an
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

    /// Build the hit list from each `(doc, pair)`'s hits, kept in the caller's order (which is reading
    /// order), each pair's hits in their own order. Stepping moves both panes together, each to its own
    /// match for the hit. Pairs with no hit contribute nothing. The cursor starts on the first hit.
    init(hits perPair: [(doc: Int, pair: Int, hits: [PairHit])]) {
        var locs: [FindMatchLocation] = []
        for entry in perPair {
            for (k, hit) in entry.hits.enumerated() {
                locs.append(FindMatchLocation(doc: entry.doc, pair: entry.pair, index: k,
                                              left: hit.left, right: hit.right))
            }
        }
        locations = locs
        cursor = locs.isEmpty ? nil : 0
    }

    /// The same from each pane's match count alone, pairing by ordinal: a pair has as many hits as its
    /// busier pane has matches, the k-th hit being each pane's k-th match.
    init(perPair: [(doc: Int, pair: Int, left: Int, right: Int)]) {
        self.init(hits: perPair.map { ($0.doc, $0.pair, FindWordAlignment.ordinalHits(left: $0.left, right: $0.right)) })
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
        pairMatches(in: document, query: query).map { ($0.left.count, $0.right.count) }
    }

    /// Each page pair's find hits, in reading order, with each pane's matches paired through a word
    /// alignment of the image page's text layer and the OCR text page (`FindWordAlignment`). A pair whose
    /// panes do not both have matches needs no alignment, so a page is only diffed when it can pair a hit.
    static func pairHits(in document: PDFDocument, query: String) -> [[PairHit]] {
        let layout = DocumentPagePairs(document: document)
        return pairMatches(in: document, query: query).enumerated().map { p, matches in
            guard !matches.left.isEmpty, !matches.right.isEmpty,
                  let textIndex = layout.textPageIndex(pair: p),
                  let left = document.page(at: layout.imagePageIndex(pair: p))?.string,
                  let right = document.page(at: textIndex)?.string
            else { return FindWordAlignment.ordinalHits(left: matches.left.count, right: matches.right.count) }
            return FindWordAlignment.pairHits(leftText: left, leftMatches: matches.left,
                                              rightText: right, rightMatches: matches.right)
        }
    }

    /// One `findString` pass bucketed by page: each pair's matches per pane, as UTF-16 offsets into that
    /// page's `string`, in the order PDFKit reports (and selects) them.
    private static func pairMatches(in document: PDFDocument, query: String) -> [(left: [Int], right: [Int])] {
        let layout = DocumentPagePairs(document: document)
        let pairs = layout.count
        guard !query.isEmpty, pairs > 0 else { return [] }
        var matches = [(left: [Int], right: [Int])](repeating: ([], []), count: pairs)
        for selection in document.findString(query, withOptions: [.caseInsensitive]) {
            guard let page = selection.pages.first else { continue }
            let pageIndex = document.index(for: page)
            // `index(for:)` answers NSNotFound for a page that isn't in this document; the bounds check
            // below rejects that (and any future surprise) rather than trusting the arithmetic.
            let pair = layout.pair(ofPageIndex: pageIndex)
            guard pageIndex >= 0, matches.indices.contains(pair) else { continue }
            let offset = selection.numberOfTextRanges(on: page) > 0 ? selection.range(at: 0, on: page).location : 0
            if layout.isImagePage(pageIndex) { matches[pair].left.append(offset) } else { matches[pair].right.append(offset) }
        }
        return matches
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
