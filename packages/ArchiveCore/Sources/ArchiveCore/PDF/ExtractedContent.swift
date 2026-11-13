import Foundation
import PDFKit

/// The classifier's four measured classes. Unknown is nil, never an inferred printed page.
public enum OCRPageKind: String, CaseIterable, Codable, Sendable {
    case handwritten, typewritten, printed, forms

    public var displayName: String {
        switch self {
        case .handwritten: "Handwritten"
        case .typewritten: "Typewritten"
        case .printed: "Printed"
        case .forms: "Form or table"
        }
    }
}

/// Display provenance only. These strings never authorize an execution route or identify a model ID.
public struct PDFReaderProvenance: Sendable, Equatable {
    public let provider: String
    public let model: String
    public let processingDate: String

    public init(provider: String, model: String, processingDate: String) {
        self.provider = provider
        self.model = model
        self.processingDate = processingDate
    }
}

public enum PDFHeaderDiagnostic: String, Sendable, Equatable {
    case missingProvenance, malformedProvenance, missingKind, invalidKind, repeatedKind, outOfOrderKind
}

public struct PDFPageHeader: Sendable, Equatable {
    public var originalFilename: String?
    public var rawProvenance: String?
    public var provenance: PDFReaderProvenance?
    public var classification: String?
    public var kind: OCRPageKind?
    public var documentDate: String?
    public var sentWith: String?
    public var diagnostics: [PDFHeaderDiagnostic] = []
}

public struct ParsedPDFTextPage: Sendable, Equatable {
    public let header: PDFPageHeader?
    public let body: String
    internal var headerLineCount: Int = 0
}

/// Zero-based physical text slot. Missing headers remain represented, so a summary cannot silently
/// apply the first pair's metadata to an unknown page. This is metadata, not proof of a valid pair.
public struct PDFTextPageMetadata: Sendable, Equatable {
    public let pageIndex: Int
    public let header: PDFPageHeader?
}

public enum PDFMetadataSummary<Value: Sendable & Equatable>: Sendable, Equatable {
    case unknown
    case uniform(Value)
    /// Includes a known value beside an unknown page, as well as two different known values.
    case mixed

    static func summarize(_ values: [Value?]) -> Self {
        guard values.contains(where: { $0 != nil }) else { return .unknown }
        guard let first = values.first, let first else { return .mixed }
        return values.allSatisfy { $0 == first } ? .uniform(first) : .mixed
    }
}

/// Existing fullBody (all pages for FTS) and strippedBody (page 2 for display) semantics are preserved.
/// Per-page metadata is separate: never apply the first text page's Kind/reader to a whole merged file.
public struct ExtractedContent: Sendable {
    public var fullBody: String
    public var strippedBody: String
    public var classification: String?
    public var pageCount: Int
    public var textPages: [PDFTextPageMetadata]

    public var kindSummary: PDFMetadataSummary<OCRPageKind> {
        .summarize(textPages.map { $0.header?.kind })
    }
    public var readerSummary: PDFMetadataSummary<PDFReaderProvenance> {
        .summarize(textPages.map { $0.header?.provenance })
    }

    public init(fullBody: String, strippedBody: String, classification: String?, pageCount: Int,
                textPages: [PDFTextPageMetadata] = []) {
        self.fullBody = fullBody
        self.strippedBody = strippedBody
        self.classification = classification
        self.pageCount = pageCount
        self.textPages = textPages
    }
}

/// Read-only parsing of the single SPEC header grammar. Stripping and metadata use the same scan.
public enum PDFHeaderParser {
    public static let documentDatePrefix = "Document date: "
    public static let sentWithPrefix = "Sent with: "
    public static let kindPrefix = "Kind: "

    public static func extract(_ url: URL) -> ExtractedContent? {
        guard let doc = PDFDocument(url: url), !doc.isLocked else { return nil }
        var texts: [String] = []
        var textPages: [PDFTextPageMetadata] = []
        var firstTextPage: ParsedPDFTextPage?
        for i in 0..<doc.pageCount {
            let text = doc.page(at: i)?.string ?? ""
            if !text.isEmpty { texts.append(text) }
            if i % 2 == 1 {
                let parsed = doc.page(at: i).map { parse($0) } ?? parse(text)
                textPages.append(PDFTextPageMetadata(pageIndex: i, header: parsed.header))
                if i == 1 { firstTextPage = parsed }
            }
        }
        let fullBody = texts.joined(separator: "\n")
        return ExtractedContent(fullBody: fullBody,
            strippedBody: firstTextPage?.header != nil ? firstTextPage!.body : fullBody,
            classification: firstTextPage?.header?.classification, pageCount: doc.pageCount,
            textPages: textPages)
    }

    /// PDFKit can group short header lines together across a wide provenance line, returning Kind
    /// before provenance in `page.string`. Recover the header's physical order, but remove only its
    /// exact character ranges from the original string: never reorder the transcription or FTS text.
    public static func parse(_ page: PDFPage) -> ParsedPDFTextPage {
        let raw = page.string ?? ""
        guard page.rotation % 360 == 0,
              let selection = page.selection(for: page.bounds(for: .mediaBox)) else { return parse(raw) }
        let lines = selection.selectionsByLine().filter { !($0.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted {
                let a = $0.bounds(for: page), b = $1.bounds(for: page)
                return a.maxY != b.maxY ? a.maxY > b.maxY : a.minX < b.minX
            }
        let rawString = raw as NSString
        var orderedLines: [(text: String, selection: PDFSelection?)] = []
        for line in lines {
            orderedLines.append(((line.string ?? "").trimmingCharacters(in: .newlines), line))
            let ranges = (0..<line.numberOfTextRanges(on: page)).map { line.range(at: $0, on: page) }
            if let end = ranges.filter({ $0.location != NSNotFound && $0.location <= rawString.length
                && $0.length <= rawString.length - $0.location }).map({ $0.location + $0.length }).max(),
               hasBlankSeparator(after: end, in: rawString) {
                orderedLines.append(("", nil))
            }
        }
        let ordered = orderedLines.map(\.text).joined(separator: "\n")
        var parsed = parse(ordered)
        guard parsed.header != nil, parsed.headerLineCount > 0, parsed.headerLineCount <= orderedLines.count else {
            return parse(raw)
        }
        let body = NSMutableString(string: raw)
        var headerRanges = IndexSet()
        for line in orderedLines.prefix(parsed.headerLineCount).compactMap(\.selection) {
            for i in 0..<line.numberOfTextRanges(on: page) {
                let range = line.range(at: i, on: page)
                guard range.location != NSNotFound, range.location <= body.length,
                      range.length <= body.length - range.location else { return parse(raw) }
                headerRanges.insert(integersIn: range.location..<(range.location + range.length))
            }
        }
        for range in headerRanges.rangeView.reversed() {
            body.deleteCharacters(in: NSRange(location: range.lowerBound, length: range.count))
        }
        parsed = ParsedPDFTextPage(header: parsed.header,
            body: (body as String).trimmingCharacters(in: .whitespacesAndNewlines),
            headerLineCount: parsed.headerLineCount)
        return parsed
    }

    /// Preserve a separator PDFKit actually retained. Inspect only the whitespace immediately
    /// following a selected line, so a later blank paragraph cannot change the header boundary.
    static func hasBlankSeparator(after offset: Int, in raw: NSString) -> Bool {
        guard offset >= 0, offset <= raw.length else { return false }
        var end = offset
        while end < raw.length, let scalar = UnicodeScalar(Int(raw.character(at: end))),
              CharacterSet.whitespacesAndNewlines.contains(scalar) { end += 1 }
        let gap = raw.substring(with: NSRange(location: offset, length: end - offset))
            .replacingOccurrences(of: "\r\n", with: "\n")
        return gap.unicodeScalars.filter { CharacterSet.newlines.contains($0) }.count >= 2
    }

    public static func parseClassification(from text: String) -> String? { parse(text).header?.classification }
    public static func stripHeader(from pageText: String) -> String { parse(pageText).body }

    /// Stops at a blank separator or the first non-header line (PDFKit often drops blank lines).
    /// A valid-looking optional field at the very start of the body without that separator is
    /// intrinsically ambiguous in this format; it can be consumed as a header field. No body search.
    public static func parse(_ text: String) -> ParsedPDFTextPage {
        let lines = text.components(separatedBy: .newlines)
        func trimmed(_ index: Int) -> String { lines[index].trimmingCharacters(in: .whitespaces) }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "Extracted text." else {
            return ParsedPDFTextPage(header: nil, body: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var header = PDFPageHeader()
        // One optional filename precedes provenance. PDFKit can split that filename at an underscore
        // into two extracted lines. Inspect only these prefix slots, never arbitrary body lines.
        let candidates = [1, 2, 3].compactMap { start -> ProvenanceCandidate? in
            guard start < lines.count, (1..<start).allSatisfy({ !trimmed($0).isEmpty }),
                  start < 3 || !isField(trimmed(2)) else { return nil }
            return provenanceCandidate(lines, at: start)
        }
        // Only the first prefix slot can be a dot-containing filename. Once a provenance line
        // occupies the slot after it, keep even a malformed one; never repair it from the body.
        let first = candidates.first
        let selected: ProvenanceCandidate?
        if let first, first.start == 1, !first.complete,
           (first.raw.components(separatedBy: " · ").count < 3 || looksLikeFilename(first.raw)),
           let afterFilename = candidates.first(where: { $0.start == 2 }) {
            selected = afterFilename
        } else { selected = first }
        guard let meta = selected else {
            header.diagnostics = [.missingProvenance, .missingKind]
            return ParsedPDFTextPage(header: header, body: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if meta.start > 1 { header.originalFilename = lines[1..<meta.start].joined(separator: "\n") }
        header.rawProvenance = meta.raw
        header.provenance = parseProvenance(meta.raw)
        if header.provenance == nil { header.diagnostics.append(.malformedProvenance) }

        var index = meta.end
        var lastField = -1
        var kinds: [String] = []
        while index < lines.count {
            let line = trimmed(index)
            if line.isEmpty { index += 1; break }
            let field: Int
            let value: String
            if line.hasPrefix("Classification:") {
                field = 0; value = String(line.dropFirst("Classification:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Kind:") {
                field = 1; value = String(line.dropFirst("Kind:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix(documentDatePrefix) {
                field = 2; value = String(line.dropFirst(documentDatePrefix.count))
            } else if line.hasPrefix(sentWithPrefix) {
                field = 3; value = String(line.dropFirst(sentWithPrefix.count))
            } else { break }
            // Repeated or late Kind is consumed, diagnosed and never trusted. Other out-of-order
            // fields start the body; this preserves an archival Classification: security marking.
            if field == 1 {
                kinds.append(value)
                if field < lastField { header.diagnostics.append(.outOfOrderKind) }
            } else if field <= lastField { break }
            switch field {
            case 0: header.classification = value.isEmpty ? nil : value
            case 2: header.documentDate = value
            case 3: header.sentWith = value
            default: break
            }
            lastField = max(lastField, field)
            index += 1
        }
        if kinds.isEmpty { header.diagnostics.append(.missingKind) }
        else if kinds.count > 1 { header.diagnostics.append(.repeatedKind) }
        else if let kind = OCRPageKind(rawValue: kinds[0]) { header.kind = kind }
        else { header.diagnostics.append(.invalidKind) }
        if header.diagnostics.contains(.outOfOrderKind) { header.kind = nil }
        return ParsedPDFTextPage(header: header, body: lines.dropFirst(index).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines), headerLineCount: index)
    }

    private struct ProvenanceCandidate {
        let start: Int
        let end: Int
        let raw: String
        let complete: Bool
    }

    private static func provenanceCandidate(_ lines: [String], at start: Int) -> ProvenanceCandidate? {
        guard start < lines.count else { return nil }
        let line = lines[start].trimmingCharacters(in: .whitespaces)
        guard line.contains(" · ") || line.hasSuffix(" ·") else { return nil }
        var raw = line
        var end = start + 1
        // Existing one-line provenance wrap, commonly just the date on a second line. Do not eat
        // body text to repair malformed provenance: join only if the continuation completes a date.
        if !endsWithYear(raw), end < lines.count {
            let next = lines[end].trimmingCharacters(in: .whitespaces)
            if !next.isEmpty, !isField(next), endsWithYear(next) {
                let joined = raw + " " + next
                if parseProvenance(joined) != nil {
                    raw = joined; end += 1
                }
            }
        }
        let count = raw.components(separatedBy: " · ").count
        return ProvenanceCandidate(start: start, end: end, raw: raw, complete: count >= 3 && endsWithYear(raw))
    }

    private static func looksLikeFilename(_ line: String) -> Bool {
        // An explicit extension disambiguates a filename containing several middle dots from a
        // malformed three-position provenance line. Extensionless provenance lookalikes are ambiguous.
        line.range(of: #"\.[A-Za-z0-9]{1,8}$"#, options: .regularExpression) != nil
    }

    private static func isField(_ line: String) -> Bool {
        ["Classification:", "Kind:", documentDatePrefix, sentWithPrefix].contains { line.hasPrefix($0) }
    }

    private static func endsWithYear(_ text: String) -> Bool {
        text.range(of: #"[0-9]{4}$"#, options: .regularExpression) != nil
    }

    private static func parseProvenance(_ raw: String) -> PDFReaderProvenance? {
        let parts = raw.components(separatedBy: " · ").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty,
              parts.allSatisfy({ !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }),
              parts[2].range(of: #"^[0-9]{1,2} [A-Za-z]+ [0-9]{4}$"#, options: .regularExpression) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "d MMMM yyyy"
        formatter.isLenient = false
        guard let date = formatter.date(from: parts[2]), formatter.string(from: date) == parts[2] else { return nil }
        return PDFReaderProvenance(provider: parts[0], model: parts[1], processingDate: parts[2])
    }
}
