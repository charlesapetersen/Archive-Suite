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
            let atLineStart = range.lowerBound == body.startIndex ||
                body[body.index(before: range.lowerBound)] == "\n"
            if atLineStart { positions.append(range.lowerBound) }
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
    static func serialize(leadingText: String?, blocks: [Block]) -> String {
        var out = leadingText ?? ""
        if !blocks.isEmpty, !out.isEmpty, !out.hasSuffix("\n") { out += "\n" }
        for (i, block) in blocks.enumerated() {
            out += serializeHeader(block)
            out += block.markdown
            if i + 1 < blocks.count, !block.markdown.isEmpty, !block.markdown.hasSuffix("\n") {
                out += "\n"
            }
        }
        return out
    }

    // MARK: - Internal

    private static func parseSegment(_ text: String) -> Block {
        guard let closeRange = text.range(of: "-->") else {
            return Block(kind: .freeform, source: nil, markdown: text, unknownHeaderFields: [])
        }

        let headerRaw = String(text[text.startIndex..<closeRange.upperBound])
        var mdStart = closeRange.upperBound
        if mdStart < text.endIndex && text[mdStart] == "\n" {
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

        let fieldLines = text.split(separator: "\n", omittingEmptySubsequences: false)
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

        if let src = block.source {
            if let v = src.link        { parts.append("     link: \(v)") }
            if let v = src.display     { parts.append("     display: \"\(v)\"") }
            if let v = src.page        { parts.append("     page: \(v)") }
            if let v = src.thumbRef    { parts.append("     thumb: \(v)") }
            if let v = src.zoteroSelect { parts.append("     zotero: \(v)") }
            if let v = src.noteRef     { parts.append("     note: \(v)") }
        }
        for (k, v) in block.unknownHeaderFields {
            parts.append("     \(k): \(v)")
        }

        if parts.count == 1 {
            return parts[0] + " -->\n"
        }
        return parts.dropLast().joined(separator: "\n") + "\n" + parts.last! + " -->\n"
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
