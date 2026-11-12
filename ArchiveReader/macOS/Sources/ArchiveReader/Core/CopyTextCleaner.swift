import Foundation
import CoreGraphics
import ArchiveCore

/// Options for intelligent copy (configurable in Options ⌘,). Tuned for OCR'd photographed documents.
struct CopyTextOptions: Sendable, Equatable {
    /// Collapse single line breaks within a paragraph into spaces.
    var collapseSingleNewlines = true
    /// Treat a blank line (2+ newlines) as a paragraph break (preserved as a blank line).
    var paragraphOnBlankLine = true
    /// Join a word split across a line by a trailing hyphen ("wel-\nfare" → "welfare").
    var deHyphenate = true
    /// Rebuild the structure the OCR left unmarked from where the lines sit: paragraphs (a wider gap, a
    /// first-line indent, a short line that ends a sentence), list items with their level, and headings.
    /// Reads the PDF's line boxes when there are any, else the text's own lines and leading spaces.
    var paragraphFromLayout = true
    /// A heading, a list item or a one-line unit written wholly in capitals is copied in title case (ArchiveCore
    /// `TitleCase`). Prose of several lines in capitals (a cable, a telegram) is quoted as written.
    var titleCaseCapitals = true
}

/// One selected line as PDFKit lays it out: its text and its box in page space (origin bottom-left).
struct CopyTextLine: Sendable, Equatable {
    var text: String
    var box: CGRect
    var page: Int
}

/// Cleans selected text on copy so it reads as prose, not as the ragged line-by-line layout of a scanned
/// page: lines of a paragraph are joined, hyphenated line-splits rejoined, list items kept one per line with
/// their markers and sub-items indented, headings kept on their own lines, and capitals title-cased.
///
/// The words are never changed: the result is refused, and the selection cleaned the plain way instead,
/// unless its letters (case aside) are the selection's letters less whitespace and line-split hyphens.
enum CopyTextCleaner {
    /// From the text alone: its lines, blank lines and leading spaces stand in for the page geometry.
    static func clean(_ raw: String, options: CopyTextOptions = .init()) -> String {
        guard structured(options) else { return plain(raw, options: options) }
        return assemble(structure(textLines(raw), columns: false), raw: raw, options: options)
            ?? plain(raw, options: options)
    }

    /// From the selection's lines on the page (`lines`, in reading order), when they hold the same words as
    /// `raw`, space for space; else from the text alone. (So a repair that fused or split a word is caught here:
    /// the final guard in `assemble` sets whitespace aside.)
    static func clean(_ raw: String, lines: [CopyTextLine], options: CopyTextOptions = .init()) -> String {
        guard structured(options) else { return plain(raw, options: options) }
        let rows = layoutRows(lines)
        guard !rows.isEmpty, words(rows.map(\.text).joined(separator: "\n")) == words(raw),
              let out = assemble(structure(rows, columns: true), raw: raw, options: options)
        else { return clean(raw, options: options) }
        return out
    }

    private static func structured(_ o: CopyTextOptions) -> Bool {
        o.paragraphFromLayout && o.collapseSingleNewlines && o.paragraphOnBlankLine
    }

    // MARK: - Plain cleaning (no structure)

    /// Blank lines separate paragraphs; within one, lines are joined. What the options ask for when the
    /// structure pass is off.
    static func plain(_ raw: String, options: CopyTextOptions = .init()) -> String {
        var paragraphs: [[String]] = []
        var current: [String] = []
        for line in normalizedLines(raw) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { paragraphs.append(current); current = [] }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { paragraphs.append(current) }
        if paragraphs.isEmpty { return "" }

        let joined = paragraphs.map { $0.count == 1 ? titled(join($0, options), options) : join($0, options) }
        let separator = options.paragraphOnBlankLine ? "\n\n" : (options.collapseSingleNewlines ? " " : "\n")
        return joined.joined(separator: separator)
    }

    private static func titled(_ s: String, _ options: CopyTextOptions) -> String {
        options.titleCaseCapitals ? TitleCase.titleCased(s) : s
    }

    private static func join(_ lines: [String], _ options: CopyTextOptions) -> String {
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        var result = trimmed[0]
        for i in 1..<trimmed.count {
            let cont = trimmed[i]
            // De-hyphenation is independent of newline-collapsing: a word split by a trailing hyphen
            // is rejoined even when single line breaks are otherwise preserved.
            if options.deHyphenate, result.hasSuffix("-"),
               isLetter(result.dropLast().last), isLetter(cont.first) {
                // A capital after the hyphen is a compound broken at its hyphen (Anglo-|American): kept.
                if cont.first?.isUppercase != true { result.removeLast() }   // drop the line-split hyphen
                result += cont
            } else if options.collapseSingleNewlines {
                result += " " + cont
            } else {
                result += "\n" + cont
            }
        }
        return result
    }

    private static func isLetter(_ c: Character?) -> Bool { c?.isLetter ?? false }

    // MARK: - Lines

    private static func normalizedLines(_ raw: String) -> [String] {
        raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    /// Stand-in geometry for text with no boxes: one row per non-blank line, a blank line a gap of a row,
    /// leading spaces an indent and the character count the width. Two units of height to a row's 2.4 of
    /// spacing, so three leading spaces count as an indent and one blank line as a gap.
    static func textLines(_ raw: String) -> [CopyTextLine] {
        var rows: [CopyTextLine] = []
        var y: CGFloat = 0
        for line in normalizedLines(raw) {
            defer { y -= 2.4 }
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let lead = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            rows.append(CopyTextLine(text: text, box: CGRect(x: CGFloat(lead), y: y, width: CGFloat(text.count),
                                                             height: 2), page: 0))
        }
        return rows
    }

    /// PDFKit's line selections as text lines. Two repairs, both measured on OCR'd corpus pages:
    /// - a word the OCR wrote whole across a line end ("adhering") is split by the line geometry, so the
    ///   selection of the second line reads "ing\nto the…": the text before an embedded newline belongs to
    ///   the line before;
    /// - a list marker can be its own selection on its item's baseline ("(c)", then "Provide…"): selections
    ///   side by side on one baseline, under four line heights apart, are one line (further apart, they are
    ///   columns, as a memo's date beside its sender).
    /// Object replacement characters (an image's place in the text) are dropped.
    static func layoutRows(_ lines: [CopyTextLine]) -> [CopyTextLine] {
        var rows: [CopyTextLine] = []
        for line in lines {
            var parts = normalizedLines(line.text.replacingOccurrences(of: "\u{FFFC}", with: ""))
            let text = parts.removeLast()
            for (n, part) in parts.enumerated() where !squeezed(part).isEmpty {
                if n == 0, let last = rows.indices.last, rows[last].page == line.page,
                   isLetter(rows[last].text.last), part.first?.isLowercase == true {
                    rows[last].text += part
                } else {
                    rows.append(CopyTextLine(text: part, box: line.box, page: line.page))
                }
            }
            let t = text.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            if let last = rows.indices.last, sameBaseline(rows[last], line) {
                rows[last].text = rows[last].text.trimmingCharacters(in: .whitespaces) + " " + t
                rows[last].box = rows[last].box.union(line.box)
            } else {
                rows.append(CopyTextLine(text: t, box: line.box, page: line.page))
            }
        }
        return rows
    }

    private static func sameBaseline(_ a: CopyTextLine, _ b: CopyTextLine) -> Bool {
        let h = min(a.box.height, b.box.height)
        let overlap = min(a.box.maxY, b.box.maxY) - max(a.box.minY, b.box.minY)
        let gap = b.box.minX - a.box.maxX
        return a.page == b.page && h > 0 && overlap > 0.5 * h && gap >= -0.5 * h && gap < 4 * h
    }

    // MARK: - Structure

    enum Kind: Equatable {
        case paragraph
        case heading
        /// A list item at `level` (0 outermost); its text starts with the marker, `markerLength` characters.
        case item(level: Int, markerLength: Int)
    }

    struct Unit: Equatable {
        var kind: Kind
        var lines: [String]
        /// Text with no geometry had a blank line before this unit: kept as one whatever the units are.
        var blankBefore = false
    }

    /// The marker's kind, for telling a sub-list from its parent when both sit at one indent.
    enum MarkerStyle: Equatable { case number, parenNumber, letter, parenLetter, roman, parenRoman, bullet }

    private typealias OpenItem = (x: CGFloat, style: MarkerStyle)

    /// The rows sorted into paragraphs, headings and list items, judged within each block (a run of rows
    /// on one page and, with `columns`, one column). Measured in the block's median row height (`em`):
    /// - a **list item** starts with a marker — `1.` `1)` `(1)` `a.` `a)` `(a)` `iv.` `(iv)` `•` `–` `*` — on a
    ///   line that starts afresh: the first, after a line that ended (a gap, a short line) or a colon, at an
    ///   indent of its own, or another marker of a list already open (a glyph bullet needs none of these). Its level comes from
    ///   its marker's indent against the open items, and from a new marker style at the same indent. The lines
    ///   after it, hanging or back at the margin, are its own until a gap, a short line ending a sentence, or a
    ///   new indent after a sentence end;
    /// - a **heading** is a short line (under 60% of the block's width) that starts afresh and is followed by
    ///   a fresh start, set apart by being wholly in capitals (unless most of its block is), centred, or alone
    ///   between gaps;
    /// - a **paragraph** starts after a gap over 1.6× the block's line spacing, at a first-line indent over
    ///   1.2 em that its neighbours do not share (a quoted block is not split line by line), or after a line
    ///   stopping well short that ends a sentence (over a quarter of the width short after `.`, `!`, `?` or `:`,
    ///   or over half short unless it ends in a comma or hyphen; typed pages are ragged, so short alone is not).
    /// A line that continues a word hyphenated at the end of the line before never starts anything. A new
    /// block continues the unit before it only when its first line starts lower case.
    static func structure(_ rows: [CopyTextLine], columns: Bool) -> [Unit] {
        var units: [Unit] = []
        var open: [OpenItem] = []          // the list items open, outermost first
        var continuation: CGFloat?         // x of the current item's continuation lines
        var previous: String?              // the last row's text, across blocks

        // A block of one or two rows has no margins of its own; it is measured against its page's.
        var pageMargins: [Int: (left: CGFloat, right: CGFloat)] = [:]
        for page in Set(rows.map(\.page)) {
            let on = rows.filter { $0.page == page }
            pageMargins[page] = (percentile(on.map(\.box.minX), 0.25), percentile(on.map(\.box.maxX), 0.8))
        }

        for block in blocks(rows, columns: columns) {
            let ls = block.map { rows[$0] }
            let em = max(median(ls.map(\.box.height)), 0.001)
            let spacings = zip(ls, ls.dropFirst()).map { $0.box.midY - $1.box.midY }
            let measuredSpacing = ls.count >= 3 ? median(spacings) : 0
            let usual = measuredSpacing > 0 ? measuredSpacing : 1.2 * em
            let margins = pageMargins[ls[0].page] ?? (0, 0)
            let left = ls.count >= 3 ? percentile(ls.map(\.box.minX), 0.25) : margins.left
            let right = ls.count >= 3 ? percentile(ls.map(\.box.maxX), 0.8) : margins.right
            let width = max(right - left, em)

            func gapAbove(_ j: Int) -> Bool { j > 0 && spacings[j - 1] > 1.6 * usual }
            // In a block mostly in capitals (a cable, a telegram) capitals set nothing apart.
            let capitalsBlock = ls.count >= 3
                && ls.filter { TitleCase.isAllCapitals($0.text) }.count * 2 > ls.count
            func indented(_ j: Int) -> Bool { ls[j].box.minX - left > 1.2 * em }
            func shortfall(_ j: Int) -> CGFloat { (right - ls[j].box.maxX) / width }
            func text(_ j: Int) -> String { ls[j].text.trimmingCharacters(in: .whitespaces) }
            /// The line before `j` looks finished: a gap, or short and ending a sentence (or very short).
            func ended(_ j: Int) -> Bool {
                guard j > 0 else { return true }
                let prev = text(j - 1)
                return gapAbove(j)
                    || (shortfall(j - 1) > 0.25 && sentenceEnd(prev))
                    || (shortfall(j - 1) > 0.5 && !prev.hasSuffix(",") && !prev.hasSuffix("-"))
            }

            for j in ls.indices {
                let cur = text(j)
                let prev = previous ?? ""
                defer { previous = cur }
                let x = ls[j].box.minX
                let continuesWord = prev.hasSuffix("-") && isLetter(prev.dropLast().last)
                    && cur.first?.isLowercase == true
                let afterHeading = units.last?.kind == .heading
                let startsLower = cur.first?.isLowercase == true
                // A unit with no letters (a page number) is never continued.
                let blockStartJoins = j == 0 && !afterHeading && startsLower
                    && units.last.map { $0.lines.joined().contains(where: \.isLetter) } == true
                let fresh = j == 0 ? !blockStartJoins : (ended(j) || afterHeading || sentenceEnd(prev))
                let blank = !columns && gapAbove(j)

                // A list item.
                if !continuesWord, let marker = listMarker(cur) {
                    let ownIndent = j > 0 && abs(x - ls[j - 1].box.minX) > 1.2 * em
                        && abs(x - (continuation ?? .infinity)) > 1.2 * em
                    let listGoesOn = open.contains { $0.style == marker.style }
                    // A glyph bullet always starts an item. A dash, a letter or a number at a line start
                    // can be prose ("- and this", "Mr.|J. Edgar", "page|12. The"): only after a line that
                    // ended or a colon, at an indent of its own, or in a list already open.
                    let glyph = marker.style == .bullet && !"–—*-".contains(cur.first ?? " ")
                    let start = j == 0 ? fresh : (ended(j) || afterHeading || prev.hasSuffix(":"))
                    if glyph || start || ownIndent || listGoesOn {
                        let level = place(marker.style, at: x, in: &open, tolerance: em)
                        units.append(Unit(kind: .item(level: level, markerLength: marker.length), lines: [cur],
                                          blankBefore: blank))
                        continuation = nil
                        continue
                    }
                }

                // A heading.
                let last = j == ls.count - 1
                let gapBelow = last || gapAbove(j + 1)
                let nextFresh = gapBelow || startsFresh(text(j + 1))
                let narrow = (ls[j].box.maxX - ls[j].box.minX) / width < 0.6
                let centred = (x - left) > 2 * em && abs((x - left) - (right - ls[j].box.maxX)) < 2 * em
                let capitals = TitleCase.isAllCapitals(cur) && !capitalsBlock
                let endsOK = !cur.hasSuffix(",") && !cur.hasSuffix(";") && !cur.hasSuffix("-")
                    && (capitals || !cur.hasSuffix("."))
                let setApart = capitals || centred || ((j == 0 || gapAbove(j)) && gapBelow && ls.count > 1)
                if !continuesWord, fresh, narrow, endsOK, nextFresh, setApart {
                    units.append(Unit(kind: .heading, lines: [cur], blankBefore: blank))
                    open = []; continuation = nil
                    continue
                }

                // A line of the open list item.
                if case .item = units.last?.kind, j > 0 || blockStartJoins {
                    let newIndent = continuation.map { abs(x - $0) > 1.2 * em } ?? false
                    let leaves = gapAbove(j) || (j > 0 && shortfall(j - 1) > 0.25 && sentenceEnd(prev))
                        || (newIndent && sentenceEnd(prev))
                    if continuesWord || !leaves {
                        units[units.count - 1].lines.append(cur)
                        if continuation == nil { continuation = x }
                        continue
                    }
                }

                // A paragraph: a new one, or a line of the one before.
                let breaks: Bool
                if j == 0 {
                    breaks = !blockStartJoins
                } else if continuesWord {
                    breaks = false
                } else {
                    let indent = indented(j) && !indented(j - 1) && (last || !indented(j + 1))
                    let shortLine = startsFresh(cur) && ended(j)
                    breaks = gapAbove(j) || indent || shortLine || afterHeading
                }
                if breaks || units.last?.kind != .paragraph {
                    units.append(Unit(kind: .paragraph, lines: [cur], blankBefore: blank))
                    open = []; continuation = nil
                } else {
                    units[units.count - 1].lines.append(cur)
                }
            }
        }
        return units
    }

    /// The level of a marker of `style` at `x`, closing the open items it ends: those indented deeper, and
    /// those opened since an earlier item of its style at its indent. A new style at an open item's indent
    /// is a sub-list.
    private static func place(_ style: MarkerStyle, at x: CGFloat, in open: inout [OpenItem],
                              tolerance: CGFloat) -> Int {
        while let top = open.last, top.x > x + tolerance { open.removeLast() }
        if let k = open.lastIndex(where: { $0.style == style && abs($0.x - x) <= tolerance }) {
            open.removeSubrange((k + 1)...)
            open[k].x = x
        } else {
            open.append((x, style))
        }
        return open.count - 1
    }

    /// The list marker `s` opens with, and its length with the space after it, if any.
    static func listMarker(_ s: String) -> (style: MarkerStyle, length: Int)? {
        let patterns: [(String, MarkerStyle)] = [
            (#"^[•·▪◦‣●○■□➢►]\s*"#, .bullet),
            (#"^[–—*-]\s+"#, .bullet),
            (#"^\((?:[ivx]{1,5}|[IVX]{1,5})\)\s+"#, .parenRoman),
            (#"^\(\d{1,2}\)\s+"#, .parenNumber),
            (#"^\([A-Za-z]\)\s+"#, .parenLetter),
            (#"^\d{1,2}[.)]\s+"#, .number),
            (#"^(?:[ivx]{2,5}|[IVX]{2,5})[.)]\s+"#, .roman),
            (#"^[A-Za-z][.)]\s+"#, .letter),
        ]
        for (pattern, style) in patterns {
            if let r = s.range(of: pattern, options: .regularExpression), r.upperBound < s.endIndex {
                return (style, s.distance(from: s.startIndex, to: r.upperBound))
            }
        }
        return nil
    }

    /// Splits `rows` into runs on one page (and, with `columns`, in one column): a new run starts on a new
    /// page, when a row sits higher than the one before (the next column), or when it shares no horizontal
    /// extent with it.
    private static func blocks(_ rows: [CopyTextLine], columns: Bool) -> [[Int]] {
        var result: [[Int]] = []
        for (i, l) in rows.enumerated() {
            if let last = result.last?.last {
                let p = rows[last]
                let sameRun = l.page == p.page && l.box.midY < p.box.midY
                    && (!columns || (l.box.minX < p.box.maxX && p.box.minX < l.box.maxX))
                if sameRun { result[result.count - 1].append(i); continue }
            }
            result.append([i])
        }
        return result
    }

    // MARK: - Assembly

    /// The units as text: paragraphs and headings joined, items one per line with sub-items indented four
    /// spaces a level, a blank line between units except between items and between headings (unless the
    /// text had one there). Nil when the
    /// letters differ from `raw`'s — the structure pass never changes a word.
    static func assemble(_ units: [Unit], raw: String, options: CopyTextOptions) -> String? {
        var out = ""
        var previous: Kind?
        for u in units {
            var text = join(u.lines, options)
            var indent = ""
            if case .item(let level, let markerLength) = u.kind {
                indent = String(repeating: "    ", count: level)
                let cut = text.index(text.startIndex, offsetBy: min(markerLength, text.count))
                text = String(text[..<cut]) + titled(String(text[cut...]), options)
            } else if u.kind == .heading || u.lines.count == 1 {
                text = titled(text, options)
            }
            if let p = previous {
                switch (p, u.kind) {
                case (.item, .item) where !u.blankBefore, (.heading, .heading) where !u.blankBefore: out += "\n"
                default: out += "\n\n"
                }
            }
            out += indent + text
            previous = u.kind
        }
        return letters(out) == letters(raw) ? out : nil
    }

    /// The text with case, whitespace, hyphens and object replacement characters set aside: what the
    /// cleaner may not change.
    private static func letters(_ s: String) -> String {
        s.lowercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "\u{FFFC}" }
    }

    // MARK: - Helpers

    private static func startsFresh(_ s: String) -> Bool {
        s.first.map { $0.isUppercase || $0.isNumber || "\"“'‘(•–—*".contains($0) } ?? false
    }

    private static func sentenceEnd(_ s: String) -> Bool {
        var t = Substring(s)
        while let c = t.last, "\"”'’)]".contains(c) { t = t.dropLast() }
        return t.last.map { ".!?:".contains($0) } ?? false
    }

    /// Whitespace-free form, for telling an empty line selection.
    private static func squeezed(_ s: String) -> String {
        s.filter { !$0.isWhitespace && $0 != "\u{FFFC}" }
    }

    /// The words of `s` in order, object replacement characters set aside.
    private static func words(_ s: String) -> [Substring] {
        s.replacingOccurrences(of: "\u{FFFC}", with: " ").split(whereSeparator: \.isWhitespace)
    }

    /// The lower median, so that of two spacings, one of them a paragraph gap, the usual one is chosen.
    private static func median(_ xs: [CGFloat]) -> CGFloat {
        guard !xs.isEmpty else { return 0 }
        return xs.sorted()[(xs.count - 1) / 2]
    }

    private static func percentile(_ xs: [CGFloat], _ p: CGFloat) -> CGFloat {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s[Int((CGFloat(s.count - 1) * p).rounded())]
    }
}
