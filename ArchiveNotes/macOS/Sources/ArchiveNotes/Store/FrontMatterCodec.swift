import Foundation

/// Hand-rolled strict YAML front-matter (de)serializer for the locked
/// Archive Notes schema (00-overview §5). Round-trip preserves unknown keys
/// verbatim and emits a stable canonical field order.
enum FrontMatterCodec {

    enum CodecError: Error, Sendable {
        case missingFrontMatter
        case unterminatedFrontMatter
        case missingId
    }

    // MARK: - Decode

    static func decode(_ text: String) throws -> Item {
        let norm = text.replacingOccurrences(of: "\r\n", with: "\n")

        guard norm.hasPrefix("---\n") || norm == "---" else {
            throw CodecError.missingFrontMatter
        }

        let afterOpener = norm[norm.index(norm.startIndex, offsetBy: 4)...]
        guard let closeRange = afterOpener.range(of: "\n---\n") ??
              afterOpener.range(of: "\n---", options: [], range: afterOpener.startIndex..<afterOpener.endIndex) else {
            throw CodecError.unterminatedFrontMatter
        }

        let fmText = String(afterOpener[afterOpener.startIndex..<closeRange.lowerBound])

        let bodyStartIdx: String.Index
        if let full = afterOpener.range(of: "\n---\n") {
            bodyStartIdx = full.upperBound
        } else {
            bodyStartIdx = closeRange.upperBound
        }
        let body = bodyStartIdx < afterOpener.endIndex ? String(afterOpener[bodyStartIdx...]) : ""

        let fields = parseFrontMatter(fmText)
        let (leadingText, blocks) = BlockParser.parse(body)

        guard let idStr = fields.id, let id = UUID(uuidString: idStr) else {
            throw CodecError.missingId
        }

        return Item(
            id: id,
            kind: Item.Kind(rawValue: fields.kind ?? "note") ?? .note,
            title: fields.title ?? "",
            authors: fields.authors,
            date: fields.date,
            datePrecision: fields.datePrecision.flatMap(Item.DatePrecision.init(rawValue:)),
            dateUncertain: fields.dateUncertain,
            quality: fields.quality,
            tags: fields.tags,
            zotero: fields.zotero,
            roundup: fields.roundup,
            created: fields.created ?? Date(),
            modified: fields.modified ?? Date(),
            schema: fields.schema,
            blocks: blocks,
            unknownFrontMatter: fields.unknownKeys,
            trailingBodyRaw: leadingText
        )
    }

    // MARK: - Encode

    static func encode(_ item: Item) -> String {
        var lines: [String] = ["---"]

        lines.append("schema: \(item.schema)")
        lines.append("id: \(item.id.uuidString.lowercased())")
        lines.append("kind: \(item.kind.rawValue)")
        lines.append("title: \(quoteScalar(item.title))")

        if !item.authors.isEmpty {
            lines.append("authors: \(emitFlowList(item.authors))")
        }

        if let date = item.date {
            lines.append("date: \(quoteScalar(date))")
        }
        if let dp = item.datePrecision {
            lines.append("date_precision: \(dp.rawValue)")
        }
        if item.date != nil {
            lines.append("date_uncertain: \(item.dateUncertain)")
        }

        if let q = item.quality {
            lines.append("quality: \(q)")
        }

        if !item.tags.isEmpty {
            lines.append("tags: \(emitFlowList(item.tags))")
        }

        lines.append("roundup: \(item.roundup)")

        if !item.zotero.isEmpty {
            lines.append("zotero:")
            for ref in item.zotero {
                lines.append("  - selectLink: \(quoteScalar(ref.selectLink))")
                lines.append("    itemKey: \(quoteScalar(ref.itemKey))")
                lines.append("    library: \(quoteScalar(ref.library.frontMatterValue))")
                lines.append("    kind: \(ref.kind.rawValue)")
                if let pk = ref.parentKey { lines.append("    parentKey: \(quoteScalar(pk))") }
                if let c = ref.citation   { lines.append("    citation: \(quoteScalar(c))") }
                if let fa = ref.fetchedAt { lines.append("    fetchedAt: \(formatISO(fa))") }
                for u in ref.unknown {
                    for raw in u.rawLines { lines.append(raw) }
                }
            }
        }

        lines.append("created: \(formatISO(item.created))")
        lines.append("modified: \(formatISO(item.modified))")

        for u in item.unknownFrontMatter {
            for raw in u.rawLines { lines.append(raw) }
        }

        lines.append("---")

        var result = lines.joined(separator: "\n") + "\n"

        // Joining leading prose to the first block header is `BlockParser.serialize`'s job, not ours:
        // it inserts the separating newline a header needs when the prose does not end in one
        // (`BlockParser.swift:92` — a header is only recognized at the start of a line). Appending
        // `trailingBodyRaw` here by hand and then passing `leadingText: nil` made that guard dead code
        // on the ONLY path that reaches disk (`NoteStore.saveEntry`), so a leading body with no trailing
        // newline butted straight up against `<!-- block:` and the first block was swallowed into the
        // prose on reload — provenance and all. (W3.notes-frontmatter-codec-bypasses-the-leading-text-guard.)
        result += BlockParser.serialize(leadingText: item.trailingBodyRaw, blocks: item.blocks)

        return result
    }

    // MARK: - Front-matter parser

    private struct ParsedFields {
        var schema: Int = 1
        var id: String?
        var kind: String?
        var title: String?
        var authors: [String] = []
        var date: String?
        var datePrecision: String?
        var dateUncertain: Bool = false
        var quality: Int?
        var tags: [String] = []
        var roundup: Bool = false
        var zotero: [ZoteroRef] = []
        var created: Date?
        var modified: Date?
        var unknownKeys: [UnknownKey] = []
    }

    private static let knownKeys: Set<String> = [
        "schema", "id", "kind", "title", "authors", "date",
        "date_precision", "date_uncertain", "quality", "tags",
        "roundup", "zotero", "created", "modified"
    ]

    private static func parseFrontMatter(_ text: String) -> ParsedFields {
        var fields = ParsedFields()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { i += 1; continue }

            guard let colonIdx = line.firstIndex(of: ":"),
                  colonIdx > line.startIndex else {
                i += 1; continue
            }

            let keyPart = line[line.startIndex..<colonIdx]
            guard !keyPart.contains(" "), !keyPart.isEmpty else { i += 1; continue }
            let key = String(keyPart)
            let valuePart = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)

            guard knownKeys.contains(key) else {
                var rawLines = [line]
                var j = i + 1
                while j < lines.count && isIndented(lines[j]) {
                    rawLines.append(lines[j])
                    j += 1
                }
                fields.unknownKeys.append(UnknownKey(key: key, rawLines: rawLines))
                i = j
                continue
            }

            switch key {
            case "schema":
                fields.schema = Int(valuePart) ?? 1
                i += 1

            case "id":
                fields.id = unquoteScalar(valuePart)
                i += 1

            case "kind":
                fields.kind = unquoteScalar(valuePart)
                i += 1

            case "title":
                fields.title = unquoteScalar(valuePart)
                i += 1

            case "authors":
                let (list, consumed) = parseList(valuePart, lines: lines, from: i)
                fields.authors = list
                i += consumed

            case "date":
                fields.date = unquoteScalar(valuePart)
                i += 1

            case "date_precision":
                fields.datePrecision = unquoteScalar(valuePart)
                i += 1

            case "date_uncertain":
                fields.dateUncertain = parseBool(valuePart)
                i += 1

            case "quality":
                fields.quality = Int(valuePart)
                i += 1

            case "tags":
                let (list, consumed) = parseList(valuePart, lines: lines, from: i)
                fields.tags = list
                i += consumed

            case "roundup":
                fields.roundup = parseBool(valuePart)
                i += 1

            case "zotero":
                let (refs, consumed) = parseZoteroBlock(lines, from: i + 1)
                fields.zotero = refs
                i += consumed + 1

            case "created":
                fields.created = parseISO(unquoteScalar(valuePart))
                i += 1

            case "modified":
                fields.modified = parseISO(unquoteScalar(valuePart))
                i += 1

            default:
                i += 1
            }
        }

        return fields
    }

    // MARK: - List parsing (flow + block)

    /// Returns parsed elements and how many lines were consumed (starting at `from`).
    private static func parseList(_ value: String, lines: [String], from idx: Int) -> ([String], Int) {
        if let flow = parseFlowList(value) {
            return (flow, 1)
        }
        if value.isEmpty {
            var items: [String] = []
            var j = idx + 1
            while j < lines.count && isIndented(lines[j]) {
                let trimmed = lines[j].trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("- ") {
                    items.append(unquoteScalar(String(trimmed.dropFirst(2))))
                } else if trimmed == "-" {
                    items.append("")
                }
                j += 1
            }
            return (items, j - idx)
        }
        return ([unquoteScalar(value)], 1)
    }

    private static func parseFlowList(_ value: String) -> [String]? {
        let t = value.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("[") && t.hasSuffix("]") else { return nil }
        let inner = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        if inner.isEmpty { return [] }

        var elements: [String] = []
        var current = ""
        var inDouble = false
        var inSingle = false
        var escape = false

        for ch in inner {
            if escape { current.append(ch); escape = false; continue }
            if ch == "\\" && inDouble { escape = true; continue }
            if ch == "\"" && !inSingle { inDouble.toggle(); continue }
            if ch == "'" && !inDouble { inSingle.toggle(); continue }
            if ch == "," && !inDouble && !inSingle {
                elements.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
            current.append(ch)
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty || !elements.isEmpty { elements.append(last) }

        return elements.filter { !$0.isEmpty }
    }

    // MARK: - Zotero nested map parsing

    private static let knownZoteroKeys: Set<String> = [
        "selectLink", "itemKey", "library", "kind", "parentKey", "citation", "fetchedAt"
    ]

    private static func parseZoteroBlock(_ lines: [String], from start: Int) -> ([ZoteroRef], Int) {
        var refs: [ZoteroRef] = []
        var j = start
        var current: [String: String] = [:]
        var currentUnknown: [UnknownKey] = []

        func flushCurrent() {
            guard let sl = current["selectLink"],
                  let ik = current["itemKey"],
                  let lib = current["library"] else { return }
            let kind = ZoteroRefKind(rawValue: current["kind"] ?? "item") ?? .item
            refs.append(ZoteroRef(
                selectLink: sl, itemKey: ik,
                library: ZoteroLibrary.from(frontMatter: lib), kind: kind,
                parentKey: current["parentKey"],
                citation: current["citation"],
                fetchedAt: current["fetchedAt"].flatMap(parseISO),
                unknown: currentUnknown
            ))
        }

        while j < lines.count && isIndented(lines[j]) {
            let trimmed = lines[j].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") {
                if !current.isEmpty { flushCurrent() }
                current = [:]
                currentUnknown = []
                let pair = String(trimmed.dropFirst(2))
                if let (k, v) = parseKV(pair) {
                    if knownZoteroKeys.contains(k) {
                        current[k] = v
                    } else {
                        currentUnknown.append(UnknownKey(key: k, rawLines: [lines[j]]))
                    }
                }
            } else if let (k, v) = parseKV(trimmed) {
                if knownZoteroKeys.contains(k) {
                    current[k] = v
                } else {
                    currentUnknown.append(UnknownKey(key: k, rawLines: [lines[j]]))
                }
            }
            j += 1
        }
        if !current.isEmpty { flushCurrent() }

        return (refs, j - start)
    }

    // MARK: - Helpers

    private static func isIndented(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        return first == " " || first == "\t"
    }

    private static func parseKV(_ s: String) -> (String, String)? {
        guard let idx = s.firstIndex(of: ":") else { return nil }
        let key = s[s.startIndex..<idx].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        let val = s[s.index(after: idx)...].trimmingCharacters(in: .whitespaces)
        return (key, unquoteScalar(val))
    }

    private static func parseBool(_ s: String) -> Bool {
        let lower = s.lowercased().trimmingCharacters(in: .whitespaces)
        return lower == "true" || lower == "yes" || lower == "on"
    }

    // MARK: - Scalar quoting

    static func unquoteScalar(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2 {
            if t.hasPrefix("\"") && t.hasSuffix("\"") {
                return String(t.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            if t.hasPrefix("'") && t.hasSuffix("'") {
                return String(t.dropFirst().dropLast())
                    .replacingOccurrences(of: "''", with: "'")
            }
        }
        return t
    }

    static func quoteScalar(_ s: String) -> String {
        if needsQuoting(s) {
            let escaped = s
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return s
    }

    private static let yamlLiterals: Set<String> = [
        "true", "false", "null", "~", "yes", "no", "on", "off",
        "True", "False", "Null", "Yes", "No", "On", "Off",
        "TRUE", "FALSE", "NULL", "YES", "NO", "ON", "OFF",
    ]

    private static func needsQuoting(_ s: String) -> Bool {
        if s.isEmpty { return true }
        if yamlLiterals.contains(s) { return true }
        let first = s.first!
        let indicators: Set<Character> = ["!", "&", "*", "?", "|", ">", "%", "@", "`", "\"", "'", "#", ",", "[", "]", "{", "}"]
        if indicators.contains(first) { return true }
        if first == ":" && s.count > 1 && s[s.index(after: s.startIndex)] == " " { return true }
        if first == "-" && s.count > 1 && s[s.index(after: s.startIndex)] == " " { return true }
        if s.hasPrefix(" ") || s.hasSuffix(" ") { return true }
        if s.contains(": ") || s.contains(" #") || s.contains("\n") { return true }
        return false
    }

    private static func needsQuotingInFlow(_ s: String) -> Bool {
        if needsQuoting(s) { return true }
        if s.contains(",") || s.contains("[") || s.contains("]") { return true }
        // A quote char anywhere in an UNquoted flow element is treated as a delimiter by
        // `parseFlowList` (it toggles in-single/in-double state mid-stream), which drops a
        // single-quote (e.g. author "O'Brien" → "OBrien") or merges elements across a stray
        // double-quote. Double-quoting the element (quoteFlowElement escapes `\` and `"`) makes
        // the parser treat both quote kinds as literal content. (Found by NotesFrontMatterTests fuzz.)
        if s.contains("\"") || s.contains("'") { return true }
        return false
    }

    private static func quoteFlowElement(_ s: String) -> String {
        if needsQuotingInFlow(s) {
            let escaped = s
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return s
    }

    private static func emitFlowList(_ items: [String]) -> String {
        "[\(items.map { quoteFlowElement($0) }.joined(separator: ", "))]"
    }

    // MARK: - ISO-8601 dates

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseISO(_ s: String) -> Date? {
        isoFormatter.date(from: s)
    }

    private static func formatISO(_ d: Date) -> String {
        isoFormatter.string(from: d)
    }
}
