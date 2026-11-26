import Foundation

/// The inspector's word and character count (W49.notes-polish-small). It counts the text a reader sees: block
/// headers, image references, link targets, HTML tags and Markdown markers are left out, and line breaks are
/// not characters. Pure, so it is unit-tested without a window.
enum NoteTextStats {
    struct Counts: Equatable, Sendable {
        let words: Int
        let characters: Int
    }

    static func counts(markdown: String) -> Counts {
        let parsed = BlockParser.parse(markdown)
        let parts = [parsed.leadingText ?? ""] + parsed.blocks.map(\.markdown)
        return counts(visible: parts.map(visibleText).joined(separator: "\n"))
    }

    static func counts(visible text: String) -> Counts {
        var words = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            words += 1
        }
        return Counts(words: words, characters: text.reduce(0) { $1.isNewline ? $0 : $0 + 1 })
    }

    /// `markdown` without its markup: what the styled editor draws as text.
    static func visibleText(_ markdown: String) -> String {
        var text = markdown
        for (pattern, template) in replacements {
            text = pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                    withTemplate: template)
        }
        return text
    }

    private static let replacements: [(NSRegularExpression, String)] = [
        (#"<!--[\s\S]*?-->"#, ""),                          // comments
        (#"!\[[^\]]*\]\([^)]*\)"#, ""),                     // images
        (#"\[([^\]]*)\]\([^)]*\)"#, "$1"),                  // links keep their text
        (#"</?[A-Za-z][^>]*>"#, ""),                        // HTML tags (underline)
        (#"(?m)^[ \t]*(?:>[ \t]?)+"#, ""),                  // quote markers
        (#"(?m)^[ \t]*(?:#{1,6}[ \t]+|[-*+][ \t]+(?:\[[ xX]\][ \t]+)?|\d+[.)][ \t]+)"#, ""),  // headings, lists
        (#"(?m)^[ \t]*(?:```|~~~).*$"#, ""),                // code fences
        (#"(?m)^[ \t]*(?:[-*_][ \t]*){3,}$"#, ""),          // rules
        (#"\*\*|__|~~|==|[*`]"#, ""),                       // emphasis, highlight, code spans
        (#"\\([\\`*_{}\[\]()#+\-.!<>=~|])"#, "$1"),         // escapes
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
}
