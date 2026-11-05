import Foundation
import CoreGraphics

/// Options for intelligent copy (configurable in Options ⌘,). Tuned for OCR'd photographed documents.
struct CopyTextOptions: Sendable, Equatable {
    /// Collapse single line breaks within a paragraph into spaces.
    var collapseSingleNewlines = true
    /// Treat a blank line (2+ newlines) as a paragraph break (preserved as a blank line).
    var paragraphOnBlankLine = true
    /// Join a word split across a line by a trailing hyphen ("wel-\nfare" → "welfare").
    var deHyphenate = true
    /// Find paragraph breaks the OCR left unmarked (no blank line) from where the lines sit on the page:
    /// a wider gap above a line, a first-line indent, or a short line that ends a sentence.
    var paragraphFromLayout = true
}

/// One selected line as PDFKit lays it out: its text and its box in page space (origin bottom-left).
struct CopyTextLine: Sendable, Equatable {
    var text: String
    var box: CGRect
    var page: Int
}

/// Cleans selected text on copy: single newlines become spaces, blank lines stay as paragraph
/// breaks, and hyphenated line-splits are rejoined — so copied text reads as prose, not as the
/// ragged line-by-line layout of a scanned page.
enum CopyTextCleaner {
    static func clean(_ raw: String, options: CopyTextOptions = .init()) -> String {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Group non-blank lines into paragraphs; any run of blank lines separates paragraphs.
        var paragraphs: [[String]] = []
        var current: [String] = []
        for line in normalized.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { paragraphs.append(current); current = [] }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { paragraphs.append(current) }
        if paragraphs.isEmpty { return "" }

        let joined = paragraphs.map { join($0, options) }
        let separator = options.paragraphOnBlankLine ? "\n\n" : (options.collapseSingleNewlines ? " " : "\n")
        return joined.joined(separator: separator)
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
                result.removeLast()      // drop the line-split hyphen and join the word halves
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

    // MARK: - Paragraph breaks from layout

    /// `clean`, after first marking with a blank line each paragraph break the layout shows but the text
    /// does not. `lines` are the selection's lines in reading order; when they don't match the text's
    /// non-blank lines one for one, the text is cleaned exactly as it would be without them.
    static func clean(_ raw: String, lines: [CopyTextLine], options: CopyTextOptions = .init()) -> String {
        guard options.paragraphFromLayout else { return clean(raw, options: options) }
        return clean(markLayoutBreaks(raw, lines: lines), options: options)
    }

    /// `raw` with a blank line inserted before every line that `layoutBreaks` says starts a paragraph.
    static func markLayoutBreaks(_ raw: String, lines: [CopyTextLine]) -> String {
        let rawLines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        let boxes = lines.filter { !squeezed($0.text).isEmpty }
        let nonBlank = rawLines.filter { !squeezed($0).isEmpty }
        guard boxes.count == nonBlank.count,
              zip(boxes, nonBlank).allSatisfy({ squeezed($0.text) == squeezed($1) }) else { return raw }

        let breaks = layoutBreaks(boxes)
        guard !breaks.isEmpty else { return raw }
        var out: [String] = []
        var k = 0                                      // index into the non-blank lines
        for line in rawLines {
            if squeezed(line).isEmpty { out.append(line); continue }
            if breaks.contains(k), let last = out.last, !squeezed(last).isEmpty { out.append("") }
            out.append(line)
            k += 1
        }
        return out.joined(separator: "\n")
    }

    /// Indices of the lines that begin a paragraph, judged against the other lines of their block (a run
    /// of lines on one page in one column). A block needs three lines before its margins mean anything.
    /// Three signs, each measured in the block's median line height (`em`):
    /// - the gap above the line is over 1.6× the block's usual line spacing;
    /// - the line is indented over 1.2 em past the left margin, and neither the line before nor the line
    ///   after is (so a hanging indent or a quoted block is not split line by line);
    /// - the line before stops well short of the right margin and ends a sentence — over a quarter of the
    ///   width short after `.`, `!`, `?` or `:`, or over half short whatever it ends with (a heading),
    ///   unless it ends in a comma or hyphen. Typewritten pages are ragged, so a short line alone is not.
    /// A line that continues a word hyphenated at the end of the line before never starts a paragraph.
    static func layoutBreaks(_ lines: [CopyTextLine]) -> Set<Int> {
        var breaks = Set<Int>()
        for block in blocks(lines) where block.count >= 3 {
            let ls = block.map { lines[$0] }
            let em = median(ls.map(\.box.height))
            guard em > 0 else { continue }
            let spacings = zip(ls, ls.dropFirst()).map { $0.box.midY - $1.box.midY }
            let usualSpacing = median(spacings)
            let left = percentile(ls.map(\.box.minX), 0.25)
            let right = percentile(ls.map(\.box.maxX), 0.8)
            let width = right - left
            guard width > 0 else { continue }
            func indented(_ j: Int) -> Bool { ls[j].box.minX - left > 1.2 * em }

            for j in 1..<ls.count {
                let prev = ls[j - 1].text.trimmingCharacters(in: .whitespaces)
                let cur = ls[j].text.trimmingCharacters(in: .whitespaces)
                if prev.hasSuffix("-"), isLetter(prev.dropLast().last), cur.first?.isLowercase == true { continue }

                let wideGap = usualSpacing > 0 && spacings[j - 1] > 1.6 * usualSpacing
                let indent = indented(j) && !indented(j - 1) && (j + 1 == ls.count || !indented(j + 1))
                let shortfall = (right - ls[j - 1].box.maxX) / width
                let startsCap = cur.first.map { $0.isUppercase || $0.isNumber || "\"“'‘(".contains($0) } ?? false
                let endsSentence = sentenceEnd(prev)
                let shortLine = startsCap && (
                    (shortfall > 0.25 && endsSentence) ||
                    (shortfall > 0.5 && !prev.hasSuffix(",") && !prev.hasSuffix("-")))
                if wideGap || indent || shortLine { breaks.insert(block[j]) }
            }
        }
        return breaks
    }

    /// Splits `lines` into runs on one page and in one column: a new run starts on a new page, when a
    /// line sits higher than the one before (the next column), or when it shares no horizontal extent
    /// with it.
    private static func blocks(_ lines: [CopyTextLine]) -> [[Int]] {
        var result: [[Int]] = []
        for (i, l) in lines.enumerated() {
            if let last = result.last?.last {
                let p = lines[last]
                let sameRun = l.page == p.page
                    && l.box.midY < p.box.midY
                    && l.box.minX < p.box.maxX && p.box.minX < l.box.maxX
                if sameRun { result[result.count - 1].append(i); continue }
            }
            result.append([i])
        }
        return result
    }

    private static func sentenceEnd(_ s: String) -> Bool {
        var t = Substring(s)
        while let c = t.last, "\"”'’)]".contains(c) { t = t.dropLast() }
        return t.last.map { ".!?:".contains($0) } ?? false
    }

    /// Whitespace-free form, for matching PDFKit's line strings against the selection's text.
    private static func squeezed(_ s: String) -> String { s.filter { !$0.isWhitespace } }

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
