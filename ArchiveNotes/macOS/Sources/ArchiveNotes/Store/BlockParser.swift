import Foundation

/// A source anchor identifying the provenance of a block (00-overview §3.3).
struct SourceAnchor: Sendable, Equatable {
    var link: String?
    var display: String?
    var page: Int?
    var thumbRef: String?
    var zoteroSelect: String?
    var noteRef: String?
}

/// A content block with optional provenance (00-overview §3.2, §6).
struct Block: Sendable {
    enum Kind: String, Sendable {
        case freeform
        case readerPage = "reader-page"
        case readerDoc = "reader-doc"
        case zoteroItem = "zotero-item"
        case zoteroAttachment = "zotero-attachment"
        case notePassage = "note-passage"
    }

    var kind: Kind
    var source: SourceAnchor?
    var markdown: String
    var unknownHeaderFields: [(String, String)]
}

extension Block: Equatable {
    static func == (lhs: Block, rhs: Block) -> Bool {
        lhs.kind == rhs.kind &&
        lhs.source == rhs.source &&
        lhs.markdown == rhs.markdown &&
        lhs.unknownHeaderFields.count == rhs.unknownHeaderFields.count &&
        zip(lhs.unknownHeaderFields, rhs.unknownHeaderFields)
            .allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }
}

// MARK: - Parser & serializer

enum BlockParser {

    /// Parse the body text (everything after the front-matter closing `---`) into
    /// optional leading text + an ordered list of blocks per §6.
    static func parse(_ body: String) -> (leadingText: String?, blocks: [Block]) {
        if body.isEmpty { return (nil, []) }

        let marker = "<!-- block:"
        var positions: [String.Index] = []
        var search = body.startIndex

        while search < body.endIndex,
              let range = body.range(of: marker, range: search..<body.endIndex) {
            if isAtLineStart(range.lowerBound, in: body) { positions.append(range.lowerBound) }
            search = range.upperBound
        }

        if positions.isEmpty {
            return (body, [])
        }

        let leadingText: String? = positions[0] == body.startIndex
            ? nil
            : String(body[body.startIndex..<positions[0]])

        var blocks: [Block] = []
        for i in 0..<positions.count {
            let start = positions[i]
            let end = i + 1 < positions.count ? positions[i + 1] : body.endIndex
            let segment = String(body[start..<end])
            blocks.append(parseSegment(segment))
        }

        return (leadingText, blocks)
    }

    /// Serialize blocks back to body text.
    ///
    /// A block header is only recognized by `parse` at the **start of a line**, so every header must
    /// begin on its own line. A block body (or the leading text) that does not end in a newline —
    /// e.g. a partial-paragraph passage snapshot (W7 extracts) — would otherwise butt directly up
    /// against the next `<!-- block:` and be silently merged into one block on reload. We therefore
    /// insert a single separating newline before a header whenever the preceding text lacks one. The
    /// final block is left untouched (no spurious trailing newline), so a single-block or already
    /// newline-terminated body round-trips byte-for-byte.
    ///
    /// "Lacks one" is decided by `endsWithLineTerminator`, not `hasSuffix("\n")` — see the line-
    /// terminator section below (`W3.notes-cr-line-start`).
    static func serialize(leadingText: String?, blocks: [Block]) -> String {
        var out = leadingText ?? ""
        if !blocks.isEmpty, !out.isEmpty, !endsWithLineTerminator(out) { out += "\n" }
        for (i, block) in blocks.enumerated() {
            out += serializeHeader(block)
            out += block.markdown
            if i + 1 < blocks.count, !block.markdown.isEmpty, !endsWithLineTerminator(block.markdown) {
                out += "\n"
            }
        }
        return out
    }

    // MARK: - Line terminators (W3.notes-cr-line-start)

    /// A line here may be terminated by LF, CR LF or a lone CR, and the tests below compare unicode
    /// SCALARS rather than `Character`s on purpose.
    ///
    /// Swift merges `CR LF` into a SINGLE `"\r\n"` grapheme, so `"\r\n" == "\n"` is **false** and
    /// `"…\r\n".hasSuffix("\n")` is **false**. Every `Character`-level test in this file was therefore
    /// blind to CR-terminated text in four separate ways: a header after CR or CRLF was not recognized
    /// as a header at all, the terminator closing a header line leaked into the block body,
    /// CR-separated header fields did not split, and `serialize`'s separator guard appended a second
    /// newline (a blank line inserted into the operator's note on the next save).
    ///
    /// The lone-CR case is also why this could not be patched at the caller: any `\n` appended after a
    /// `\r` merges into that same grapheme, so the header stays unrecognized however careful the
    /// producer is. Reachable by pasting CR-delimited text into the editor, and now by reading one off
    /// disk too: `FrontMatterCodec.decode` used to normalize `\r\n` (never a lone `\r`) over the whole
    /// file, and since `W3.notes-cr-line-start-fu1` it normalizes nothing — every terminator reaching
    /// this parser is whatever the operator actually typed.
    private static func isLineTerminator(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\n" || scalar == "\r"
    }

    /// True for the `Character`s that are exactly one line break: `"\n"`, `"\r"`, and the merged
    /// `"\r\n"` grapheme.
    private static func isLineBreak(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(isLineTerminator)
    }

    /// True if `text` already ends a line, so a header written straight after it begins one.
    static func endsWithLineTerminator(_ text: String) -> Bool {
        guard let last = text.unicodeScalars.last else { return false }
        return isLineTerminator(last)
    }

    /// Split `text` into lines, treating LF, CR LF and a lone CR as ONE terminator each. Empty lines
    /// are kept, and the elements are `Substring`s of `text`, so a caller can slice the ORIGINAL bytes
    /// back out: a line's `endIndex` is its terminator, and `text.index(after:)` steps over the whole
    /// `"\r\n"` grapheme. `FrontMatterCodec.splitFrontMatter` uses that to find the front-matter fence
    /// without rewriting the body (W3.notes-cr-line-start-fu1) — it asks here rather than re-deriving
    /// the terminator test, which is how the four bugs above came to exist in the first place.
    static func splitLines(_ text: String) -> [Substring] {
        text.split(omittingEmptySubsequences: false, whereSeparator: { isLineBreak($0) })
    }

    /// True if `text` carries a line terminator ANYWHERE — the test for a value that is supposed to be a
    /// single line and is not. Scalar-level, so it catches a lone `"\r"` and the merged `"\r\n"` grapheme
    /// alike. `SourceBlockPaster` uses it on a pasted link's `rel` (W3.notes-paste-url-line-split): a
    /// terminator can also arrive percent-encoded (`rel=A.pdf%0D`), where no amount of splitting or
    /// trimming the pasted TEXT will remove it, and the result is a source anchor naming a path that
    /// cannot exist. Asked here rather than re-derived there, for the reason in `splitLines`.
    static func containsLineTerminator(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isLineTerminator)
    }

    /// Fold metadata that is about to enter the line-based block-header grammar into one safe line.
    /// This deliberately applies only to header FIELD values, never to the operator's block markdown.
    /// `splitLines` remains the single authority for LF / CR LF / lone-CR handling; joining with one
    /// space preserves the readable pieces without allowing a value to mint another header field.
    /// An embedded HTML-comment closer is separated visibly so it cannot end the header early.
    static func sanitizedHeaderFieldValue(_ value: String) -> String {
        let singleLine = containsLineTerminator(value)
            ? splitLines(value).joined(separator: " ")
            : value
        return singleLine.replacingOccurrences(of: "-->", with: "-- >")
    }

    /// The same invariant for every string field of a source anchor. `MarkdownBridge` uses this at
    /// the one seam that authors a thumbnail body line, so `display` and `thumbRef` cannot be safe in
    /// the header while still breaking the `![display](thumb)` line beside it.
    static func sanitizedHeaderSource(_ source: SourceAnchor) -> SourceAnchor {
        SourceAnchor(
            link: source.link.map(sanitizedUnquotedHeaderFieldValue),
            display: source.display.map(sanitizedHeaderFieldValue),
            page: source.page,
            thumbRef: source.thumbRef.map(sanitizedUnquotedHeaderFieldValue),
            zoteroSelect: source.zoteroSelect.map(sanitizedUnquotedHeaderFieldValue),
            noteRef: source.noteRef.map(sanitizedUnquotedHeaderFieldValue)
        )
    }

    /// `parseHeader` trims unquoted values. Match that canonical form on the first write, including
    /// when a boundary terminator folded to a boundary space, so save one and save two are identical.
    private static func sanitizedUnquotedHeaderFieldValue(_ value: String) -> String {
        sanitizedHeaderFieldValue(value).trimmingCharacters(in: .whitespaces)
    }

    /// True if `index` begins a line within `body` (the start of `body` counts).
    private static func isAtLineStart(_ index: String.Index, in body: String) -> Bool {
        guard let previous = body[..<index].unicodeScalars.last else { return true }
        return isLineTerminator(previous)
    }

    // MARK: - Internal

    private static func parseSegment(_ text: String) -> Block {
        guard let closeRange = text.range(of: "-->") else {
            return Block(kind: .freeform, source: nil, markdown: text, unknownHeaderFields: [])
        }

        let headerRaw = String(text[text.startIndex..<closeRange.upperBound])
        var mdStart = closeRange.upperBound
        // Consume exactly ONE terminator, whichever form it takes — `index(after:)` steps over the
        // whole `"\r\n"` grapheme, which is one line break, not two.
        if mdStart < text.endIndex, isLineBreak(text[mdStart]) {
            mdStart = text.index(after: mdStart)
        }
        let markdown = mdStart < text.endIndex ? String(text[mdStart...]) : ""

        let (kind, source, unknownFields) = parseHeader(headerRaw)
        return Block(kind: kind, source: source, markdown: markdown, unknownHeaderFields: unknownFields)
    }

    private static func parseHeader(_ raw: String) -> (Block.Kind, SourceAnchor?, [(String, String)]) {
        var text = raw
        if let r = text.range(of: "<!--") { text = String(text[r.upperBound...]) }
        if let r = text.range(of: "-->", options: .backwards) { text = String(text[..<r.lowerBound]) }

        let fieldLines = text.split(omittingEmptySubsequences: false, whereSeparator: { isLineBreak($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }

        var kind: Block.Kind = .freeform
        var link: String?, display: String?, thumbRef: String?, zoteroSel: String?, noteRef: String?
        var page: Int?
        var unknownFields: [(String, String)] = []
        let knownBlockFields: Set<String> = ["link", "display", "page", "thumb", "zotero", "note"]

        for fieldLine in fieldLines where !fieldLine.isEmpty {
            guard let colonIdx = fieldLine.firstIndex(of: ":") else { continue }
            let key = fieldLine[..<colonIdx].trimmingCharacters(in: .whitespaces)
            let val = fieldLine[fieldLine.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)

            if key == "block" {
                kind = Block.Kind(rawValue: val) ?? .freeform
            } else if knownBlockFields.contains(key) {
                let unq = unquote(val)
                switch key {
                case "link":    link = unq
                case "display": display = unq
                case "page":    page = Int(unq)
                case "thumb":   thumbRef = unq
                case "zotero":  zoteroSel = unq
                case "note":    noteRef = unq
                default: break
                }
            } else {
                unknownFields.append((key, val))
            }
        }

        let hasSource = link != nil || display != nil || page != nil ||
            thumbRef != nil || zoteroSel != nil || noteRef != nil
        let source: SourceAnchor? = hasSource
            ? SourceAnchor(link: link, display: display, page: page,
                           thumbRef: thumbRef, zoteroSelect: zoteroSel, noteRef: noteRef)
            : nil

        return (kind, source, unknownFields)
    }

    private static func serializeHeader(_ block: Block) -> String {
        var parts: [String] = ["<!-- block: \(block.kind.rawValue)"]

        if let source = block.source {
            let src = sanitizedHeaderSource(source)
            if let v = src.link        { parts.append("     link: \(v)") }
            if let v = src.display     { parts.append("     display: \(quote(v))") }
            if let v = src.page        { parts.append("     page: \(v)") }
            if let v = src.thumbRef    { parts.append("     thumb: \(v)") }
            if let v = src.zoteroSelect { parts.append("     zotero: \(v)") }
            if let v = src.noteRef     { parts.append("     note: \(v)") }
        }
        for (k, v) in block.unknownHeaderFields {
            parts.append("     \(k): \(sanitizedUnquotedHeaderFieldValue(v))")
        }

        if parts.count == 1 {
            return parts[0] + " -->\n"
        }
        return parts.dropLast().joined(separator: "\n") + "\n" + parts.last! + " -->\n"
    }

    /// `unquote` already decodes these two escapes. Encode them in the opposite order so a display
    /// containing a literal backslash beside a quote round-trips instead of changing on every save.
    private static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func unquote(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2 && t.hasPrefix("\"") && t.hasSuffix("\"") {
            return String(t.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return t
    }
}
