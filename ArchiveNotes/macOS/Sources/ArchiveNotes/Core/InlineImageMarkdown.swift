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
/// **W3.notes-image-dest-paren.** The destination had the same shape of bug one field over. It was
/// `[^)]+`, so a path containing a `)` stopped there: `![p](assets/photo (1).png)` read back with
/// `noteImageRelPath` = `assets/photo (1`, and the tail `.png)` re-serialized as a **new body line** —
/// prose the operator never typed, and not a fixed point. The destination now has both of CommonMark's
/// spellings: a bare one with balanced parentheses, and the angle-bracket form `<…>` that the emitter
/// reaches for whenever a path holds a space, a parenthesis, an angle bracket, a backslash or a control
/// character. That also closes a latent divergence: the old pattern accepted a space in a bare
/// destination and CommonMark does not, so a path with a space was readable here and broken in every
/// other viewer.
///
/// **W3.notes-extract-title-link-markdown.** It also owns the bang-less form, `[label](dest)` — a
/// LINK — because CommonMark's image *is* a link with a bang in front, and the title pass needs to
/// recognise one to reduce it to its label. Spelling that as a second, nearly-identical pattern
/// somewhere else is the same mistake as the two `isEscapable` sets below.
///
/// Emitting and matching live together on purpose: they are two halves of one grammar, and the
/// failure mode is that changing one without the other is invisible until a note is reloaded.
enum InlineImageMarkdown {

    /// The alt-text (link-label) capture: any run of characters that is neither `]` nor a backslash,
    /// plus any backslash escape. The `\\.` alternative is the whole point — it is what lets an
    /// escaped `\]` sit inside the label instead of ending it.
    ///
    /// **The quantifiers are POSSESSIVE (`++`, `*+`) on purpose, and it is not a micro-optimisation.**
    /// Backtracking here is pure waste: a `\` can only be consumed by `\\.`, so the label cannot
    /// reinterpret an escaped `\]`, and the greedy run therefore always halts at the FIRST bare `]` —
    /// which is the only thing that can follow it. No shorter label can succeed, so refusing to try
    /// is free. Without the possessive form, every *non-matching* `![` in a note (a pasted code
    /// fence, a hand edit) re-scans the rest of the line for each start position: measured 4x–1400x
    /// slower than the old bracket-free pattern on such input, 6–8x faster with it, byte-identical
    /// captures either way.
    private static let altGroup = #"((?:[^\]\\]++|\\.)*+)"#

    /// Line terminators, excluded from a destination in **both** spellings. CommonMark forbids them
    /// there, and the old `[^)]` admitted them: a reference broken across two lines matched, swallowed
    /// the newline into the path, and the emitter wrote it back on ONE line — a line break silently
    /// deleted from the note. Spelled as ICU escapes because this string is regex source, not Swift.
    private static let terminators = "\\n\\r\\u000B\\u000C\\u2028\\u2029"

    /// One unit of an angle-bracket destination: a RUN of anything but a bracket, a backslash or a
    /// line terminator, or one backslash escape (which is how a literal `<`, `>` or `\` gets in).
    ///
    /// Runs, not single characters, and possessive throughout — for the same reason `altGroup` is:
    /// the alternatives are distinguishable by their first character, so backtracking can never find
    /// a different parse, and matching one character per step on a long path is pure overhead.
    private static let angleDestUnit = #"(?:[^<>\\"# + terminators + #"]++|\\.)"#

    /// One unit of a bare destination: an ordinary character, a backslash escape, or a **balanced**
    /// parenthesised run. The balance rule is what stops the destination at the reference's own
    /// closing `)` instead of at the first `)` inside the path.
    ///
    /// Deliberately LENIENT where CommonMark is strict: a space is allowed here. Notes written before
    /// the angle-bracket emitter (and hand edits) spell such a path bare, and reading it is what lets
    /// the next save re-emit it as `<…>` — a lenient reader in front of a strict writer is what makes
    /// the malformed form self-heal instead of turning into prose.
    private static let bareDestUnit =
        #"(?:[^()\\"# + terminators + #"]++|\\.|\((?:[^()\\"# + terminators + #"]++|\\.)*+\))"#

    /// The destination group in both spellings, as WRITTEN (`decodeDestination` turns it into a path).
    /// A bare destination may not *start* with `<` — that is the angle form's territory, and the
    /// exclusion is what keeps the two spellings distinguishable after the fact.
    private static func destGroup(allowEmpty: Bool) -> String {
        let q = allowEmpty ? #"*+"# : #"++"#
        return #"(<"# + angleDestUnit + q + #">|(?!<)(?:"# + bareDestUnit + #")"# + q + #")"#
    }

    /// The inline-reference grammar, with the leading `!` that makes it an image optional. CommonMark
    /// defines an image as exactly that — a link with a bang in front — so the two are one grammar
    /// here, not two that have to be kept in step.
    ///
    /// **Capture groups: 1 = the label, still escaped; 2 = the destination, still spelled.** A caller
    /// that KEEPS the label owes it the same escape-resolving pass the label was written with
    /// (`unescapeAlt`, or the equivalent inside `ExtractBuilder.strippedInlineMarkers`) — the label is
    /// `escapeAlt`'s output, not plain text.
    private static func referenceSource(image: Bool, allowEmpty: Bool) -> String {
        (image ? #"!\["# : #"\["#) + altGroup + #"\]\("# + destGroup(allowEmpty: allowEmpty) + #"\)"#
    }

    /// `![alt](path)` as the app writes and reads it. The destination must be non-empty, so neither
    /// `![a]()` nor `![a](<>)` is an image reference.
    static let patternSource = referenceSource(image: true, allowEmpty: false)

    /// The same grammar, tolerating an EMPTY destination — for callers that *strip* image references
    /// rather than read them (`ExtractBuilder.strippedTitleLine`, where an `![a]()` line should
    /// still read as empty rather than become a title).
    static let strippingPatternSource = referenceSource(image: true, allowEmpty: true)

    /// A LINK — the same grammar without the bang — for the one caller that reduces one to its LABEL
    /// rather than deleting it: `ExtractBuilder.strippedTitleLine`, where a first line that is a
    /// pasted URL used to title the extract (and name its file) with the raw
    /// `[Label](https://example.com)` (`W3.notes-extract-title-link-markdown`). The label is
    /// CommonMark's rendering of the construct, and usually the good title.
    ///
    /// An empty destination is tolerated for the same reason as above, one step further: `[a]()` IS a
    /// link, and it renders as `a`.
    ///
    /// ⚠️ **Strip images FIRST.** This differs from `strippingPatternSource` only by the bang, so it
    /// matches the `[alt](path)` inside an `![alt](path)` and would leave the `!` behind as a title.
    static let linkPatternSource = referenceSource(image: false, allowEmpty: true)

    static let pattern = try! NSRegularExpression(pattern: patternSource)

    /// CommonMark's ASCII punctuation — the characters a backslash may escape. Deliberately spelled
    /// out rather than taken from `Character.isPunctuation`, which classifies `*`, `+`, `<`, `=`,
    /// `>`, `|`, `~`, `$`, `^` and `` ` `` as symbols and would leave them escaped.
    private static let escapableASCII: Set<Character> =
        Set(##"!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~"##)

    /// Whether a backslash *before* `ch` escapes it (CommonMark: ASCII punctuation only) rather than
    /// standing for a literal backslash.
    ///
    /// Exposed because `unescapeAlt` is not the only place that has to resolve an escape:
    /// `ExtractBuilder.strippedTitleLine` reads the same inline text to name an extract, and it has to
    /// agree with the label about which backslashes exist. Two private copies of this set is how the
    /// label and the title path came to disagree in the first place
    /// (`W3.notes-image-label-trailing-backslash`).
    static func isEscapable(_ ch: Character) -> Bool { escapableASCII.contains(ch) }

    /// Write one image reference. The **only** way the app should produce this grammar.
    static func emit(alt: String, path: String) -> String {
        "![\(escapeAlt(alt))](\(destination(path)))"
    }

    /// Spell `path` as a destination: bare when it can be, `<…>` when it cannot.
    ///
    /// A bare destination cannot carry a space (CommonMark's rule, and the one the old emitter broke),
    /// and can only carry parentheses in balanced pairs — so any of `( ) < > \`, whitespace or a
    /// control character sends the path into the angle form, where `\`, `<` and `>` are escaped. Every
    /// other path is written exactly as before, so the common case (`assets/p1-thumb.png`) is untouched.
    ///
    /// ⚠️ **A line terminator in a path cannot be represented in either spelling** — CommonMark forbids
    /// one in a destination, and there is nowhere else on the line to put it. Such a path is written
    /// literally and will not read back. No producer can create one (`pasted-<date>.png`,
    /// `p<N>-thumb.png`, `doc-thumb.png`, and both disambiguators only ever append `-N`), so this is a
    /// documented limit rather than a guard: a guard would have to alter the path, which is worse.
    static func destination(_ path: String) -> String {
        guard path.contains(where: destinationNeedsAngleBrackets) else { return path }
        var out = "<"
        out.reserveCapacity(path.count + 2)
        for ch in path {
            if ch == "\\" || ch == "<" || ch == ">" { out.append("\\") }
            out.append(ch)
        }
        out.append(">")
        return out
    }

    /// The literal text that closes a reference to `path` — `](<dest>)` — for the one caller that has
    /// to find or rewrite a destination by string match rather than by regex
    /// (`ExtractBuilder`'s asset re-key, which anchors on the alt-independent tail). Asking the grammar
    /// owner how a path is spelled is what keeps that match from silently missing an angle-bracketed one.
    static func destinationLiteral(_ path: String) -> String { "](\(destination(path)))" }

    /// Read a destination back: the inverse of `destination`, and CommonMark's reading of a
    /// hand-written one. Strips the angle brackets if they are there, then unescapes.
    static func decodeDestination(_ raw: String) -> String {
        var body = Substring(raw)
        if body.count >= 2, body.hasPrefix("<"), body.hasSuffix(">") {
            body = body.dropFirst().dropLast()
        }
        return unescapeCommonMark(String(body))
    }

    private static func destinationNeedsAngleBrackets(_ ch: Character) -> Bool {
        switch ch {
        case "(", ")", "<", ">", "\\": return true
        default:
            return ch.isWhitespace
                || ch.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
        }
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
    static func unescapeAlt(_ label: String) -> String { unescapeCommonMark(label) }

    /// CommonMark's backslash rule, shared by the label and the destination: a backslash before an
    /// ASCII punctuation character escapes it, and is literal before anything else.
    private static func unescapeCommonMark(_ label: String) -> String {
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
