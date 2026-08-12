import Foundation

/// The one place that knows the `![alt](path)` inline-image grammar: how the app writes it, how it
/// matches it, and how an escaped alt text reads back.
///
/// **W3.notes-thumb-line-duplicates-fu1.** The alt text used to be interpolated raw, and the label
/// group cannot cross a `]`. A source block whose `display` was an ordinary bracketed document title
/// (`Moore [draft]`) therefore emitted `![Moore [draft]](assets/p1.png)`, which matches nothing: it
/// reloaded as prose with the brackets escaped, the imported asset was orphaned, and the block
/// header's `thumb:` went on claiming a thumbnail existed. Escaping the label is what CommonMark
/// requires anyway — an unbalanced `[` or `]` inside a link label means it is not a label — so this
/// also keeps the note readable in any other Markdown viewer.
///
/// Emitting and matching live together on purpose: they are two halves of one grammar, and the
/// failure mode is that changing one without the other is invisible until a note is reloaded.
enum InlineImageMarkdown {

    /// The alt-text (link-label) capture: any run of characters that is neither `]` nor a backslash,
    /// plus any backslash escape. The `\\.` alternative is the whole point — it is what lets an
    /// escaped `\]` sit inside the label instead of ending it.
    private static let altGroup = #"((?:[^\]\\]|\\.)*)"#

    /// `![alt](path)` as the app writes and reads it. The destination is one-or-more non-`)`
    /// characters, so an empty `()` is not an image reference.
    static let patternSource = #"!\["# + altGroup + #"\]\(([^)]+)\)"#

    /// The same grammar, tolerating an EMPTY destination — for callers that *strip* image references
    /// rather than read them (`ExtractBuilder.strippedTitleLine`, where an `![a]()` line should
    /// still read as empty rather than become a title).
    static let strippingPatternSource = #"!\["# + altGroup + #"\]\([^)]*\)"#

    static let pattern = try! NSRegularExpression(pattern: patternSource)

    /// CommonMark's ASCII punctuation — the characters a backslash may escape. Deliberately spelled
    /// out rather than taken from `Character.isPunctuation`, which classifies `*`, `+`, `<`, `=`,
    /// `>`, `|`, `~`, `$`, `^` and `` ` `` as symbols and would leave them escaped.
    private static let escapableASCII: Set<Character> =
        Set(##"!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~"##)

    /// Write one image reference. The **only** way the app should produce this grammar.
    static func emit(alt: String, path: String) -> String {
        "![\(escapeAlt(alt))](\(path))"
    }

    /// Escape exactly what the label cannot carry: the bracket pair, and the escape character
    /// itself. Narrower than `MarkdownBridge.escapeMarkdown` on purpose — an unescaped emphasis
    /// marker inside an alt text is a rendering nicety for other viewers, not something that can
    /// lose the reference.
    static func escapeAlt(_ alt: String) -> String {
        var out = ""
        out.reserveCapacity(alt.count)
        for ch in alt {
            if ch == "\\" || ch == "[" || ch == "]" { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// Read a label back: the inverse of `escapeAlt`, and CommonMark's rule besides — a backslash
    /// escapes an ASCII punctuation character and is literal before anything else.
    ///
    /// Both halves matter. Unescaping too little is not merely lossy: `escapeAlt` escapes the
    /// backslash itself, so a label that keeps its `\\` would gain one backslash per save and grow
    /// without bound.
    static func unescapeAlt(_ label: String) -> String {
        guard label.contains("\\") else { return label }
        var out = ""
        out.reserveCapacity(label.count)
        var afterBackslash = false
        for ch in label {
            if afterBackslash {
                if !escapableASCII.contains(ch) { out.append("\\") }
                out.append(ch)
                afterBackslash = false
            } else if ch == "\\" {
                afterBackslash = true
            } else {
                out.append(ch)
            }
        }
        // The capture group can't end on a lone backslash, but a hand-edited note can.
        if afterBackslash { out.append("\\") }
        return out
    }
}
