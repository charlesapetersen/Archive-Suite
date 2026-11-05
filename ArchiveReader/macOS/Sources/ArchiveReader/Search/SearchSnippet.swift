import Foundation

/// Keyword-in-context (KWIC) snippet support for full-text search results.
///
/// The content index asks FTS5's `snippet()` to wrap each matched term in sentinel marks; this type
/// owns those marks — so the SQL builder (`ContentIndex.searchRanked`) and the UI parser agree on a
/// single vocabulary — and the pure parser that turns a marked snippet back into highlight segments
/// the list cell renders.
///
/// The marks are the ASCII control characters STX (U+0002) / ETX (U+0003): they never occur in OCR
/// body text, need no escaping inside an FTS5 string literal, and are trivial to split on.
enum SearchSnippet {
    /// Wraps the start of a matched term in a `snippet()` result.
    static let openMark = "\u{2}"     // STX
    /// Wraps the end of a matched term.
    static let closeMark = "\u{3}"    // ETX
    /// Rendered by `snippet()` where it elides text around the extracted fragment.
    static let ellipsis = "…"
    /// Fragment width (tokens) requested from `snippet()` — a compact KWIC window. FTS5 clamps to 1…64.
    static let tokenCount = 12

    /// Wall-time cap on building the snippets for one search. Fragments are built best match first, and
    /// the rows left when it runs out show no preview, as rows past the snippet limit already do.
    static let timeBudget: TimeInterval = 0.25

    /// Query terms left out of the snippet expression (`ContentIndex.snippetMatchExpression`), never out
    /// of the MATCH that decides the hits. FTS5's `snippet()` scores every candidate fragment against every
    /// phrase instance in the document, so its cost grows with the square of the instance count, and
    /// `of`/`the` occur thousands of times in a long OCR body: `Bureau of the Budget` took about 200 ms a
    /// hit at corpus size (W40.fix-reader-fts-snippet-stall). Lower-case; compared with the token folded.
    static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "has", "he", "in", "is", "it",
        "its", "of", "on", "or", "that", "the", "this", "to", "was", "were", "will", "with",
    ]

    /// One run of a snippet. `isMatch` runs are the query terms FTS5 marked, to be emphasised.
    struct Segment: Equatable, Sendable {
        let text: String
        let isMatch: Bool
    }

    /// Split a `snippet()` result (matches wrapped in `openMark`/`closeMark`) into ordered runs.
    /// Robust to malformed input: a stray `closeMark` outside a match is dropped, a nested/duplicate
    /// `openMark` is ignored, and an unterminated match runs to the end. Never throws — the worst case
    /// degrades to a single plain-text run.
    static func segments(from marked: String) -> [Segment] {
        guard !marked.isEmpty else { return [] }
        let open = Character(openMark)
        let close = Character(closeMark)
        var segments: [Segment] = []
        var buffer = ""
        var inMatch = false
        func flush() {
            if !buffer.isEmpty { segments.append(Segment(text: buffer, isMatch: inMatch)) }
            buffer = ""
        }
        for ch in marked {
            if ch == open {
                if !inMatch { flush(); inMatch = true }   // ignore a duplicate/nested open
            } else if ch == close {
                if inMatch { flush(); inMatch = false }    // ignore a stray close
            } else {
                buffer.append(ch)
            }
        }
        flush()
        return segments
    }

    /// True if any run is a highlighted match — lets a caller skip rendering a match-free preview.
    static func hasMatch(_ segments: [Segment]) -> Bool { segments.contains { $0.isMatch } }

    /// A query term for `fragment(in:terms:)`: a folded word, matched whole or, for the query's last
    /// term as `ContentIndex.matchTerms` writes it, as a prefix.
    struct Term: Equatable, Sendable {
        let word: String
        let isPrefix: Bool
    }

    /// The `snippet()`-shaped fragment around the first matching word of `body`, built by scanning the
    /// text rather than by FTS5 (W40.fix-reader-fts-snippets). It is for a query made only of `stopWords`,
    /// which the snippet expression then keeps: `snippet()` on `the` took 0.9 s for one long sample body,
    /// while this stops one window past the first match. Words are runs of letters and digits, compared
    /// case- and diacritic-folded, as FTS5's default tokenizer does. `nil` when no word matches.
    static func fragment(in body: String, terms: [Term], tokenCount: Int = tokenCount) -> String? {
        guard !terms.isEmpty, tokenCount > 0 else { return nil }
        func matches(_ word: Substring) -> Bool {
            let folded = word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return terms.contains { $0.isPrefix ? folded.hasPrefix($0.word) : folded == $0.word }
        }
        func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber }
        let lead = tokenCount / 3   // words kept before the first match
        var before: [Range<String.Index>] = []   // up to `lead` words before the first match
        var window: [Range<String.Index>] = []   // the first match and the words after it
        var droppedBefore = false
        var i = body.startIndex
        while i < body.endIndex, before.count + window.count < tokenCount || window.isEmpty {
            guard isWordCharacter(body[i]) else { i = body.index(after: i); continue }
            var end = body.index(after: i)
            while end < body.endIndex, isWordCharacter(body[end]) { end = body.index(after: end) }
            if !window.isEmpty || matches(body[i..<end]) {
                window.append(i..<end)
            } else {
                before.append(i..<end)
                if before.count > lead { before.removeFirst(); droppedBefore = true }
            }
            i = end
        }
        guard let first = (before + window).first, !window.isEmpty else { return nil }
        var out = droppedBefore ? ellipsis : ""
        var cursor = first.lowerBound
        for range in before + window {
            out += body[cursor..<range.lowerBound]
            out += matches(body[range]) ? openMark + body[range] + closeMark : String(body[range])
            cursor = range.upperBound
        }
        // Text left out after the window gets an ellipsis; trailing punctuation alone is kept.
        out += body[cursor...].contains(where: isWordCharacter) ? ellipsis : String(body[cursor...])
        return out
    }
}
