import Foundation

/// Options for intelligent copy (configurable in Options ⌘,). Tuned for OCR'd photographed documents.
struct CopyTextOptions: Sendable, Equatable {
    /// Collapse single line breaks within a paragraph into spaces.
    var collapseSingleNewlines = true
    /// Treat a blank line (2+ newlines) as a paragraph break (preserved as a blank line).
    var paragraphOnBlankLine = true
    /// Join a word split across a line by a trailing hyphen ("wel-\nfare" → "welfare").
    var deHyphenate = true
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
}
