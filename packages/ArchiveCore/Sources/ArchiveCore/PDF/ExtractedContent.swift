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
    /// W46.date-route-header — the evidence behind a non-explicit document date, as one display line.
    public var dateEvidence: String?
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
    /// What each physical page is (`PDFPageRole.roles(of:)`).
    public var pageRoles: [PDFPageRole]

    public var kindSummary: PDFMetadataSummary<OCRPageKind> {
        .summarize(textPages.map { $0.header?.kind })
    }
    public var readerSummary: PDFMetadataSummary<PDFReaderProvenance> {
        .summarize(textPages.map { $0.header?.provenance })
    }

    public init(fullBody: String, strippedBody: String, classification: String?, pageCount: Int,
                textPages: [PDFTextPageMetadata] = [], pageRoles: [PDFPageRole]? = nil) {
        self.fullBody = fullBody
        self.strippedBody = strippedBody
        self.classification = classification
        self.pageCount = pageCount
        self.textPages = textPages
        self.pageRoles = pageRoles ?? PDFPageRole.pairs(pageCount)
    }
}

/// W42.int-s5-searchable — what one physical page of an output is. Without a carrier list (`PDFHeaderCarrier`) a file
/// is pairs: even pages images, odd pages text. With one that has an entry for every page, a page with a header is a
/// searchable page, and the pages without one pair up in order, image then text (an image left at the end, or before a
/// searchable page, has no text page). A list whose count is not the page count is ignored: the file was edited.
public enum PDFPageRole: String, Sendable, Equatable {
    case image, text, searchable

    public static func roles(of document: PDFDocument) -> [PDFPageRole] {
        guard let carried = document.documentRef.flatMap(PDFHeaderCarrier.pages(of:)) else {
            return pairs(document.pageCount)
        }
        return roles(carried: carried, pageCount: document.pageCount)
    }

    public static func roles(of document: CGPDFDocument) -> [PDFPageRole] {
        guard let carried = PDFHeaderCarrier.pages(of: document) else { return pairs(document.numberOfPages) }
        return roles(carried: carried, pageCount: document.numberOfPages)
    }

    public static func roles(carried: [String?], pageCount: Int) -> [PDFPageRole] {
        guard carried.count == pageCount else { return pairs(pageCount) }
        var roles: [PDFPageRole] = []
        var imageOpen = false
        for entry in carried {
            if entry != nil { roles.append(.searchable); imageOpen = false }
            else if imageOpen { roles.append(.text); imageOpen = false }
            else { roles.append(.image); imageOpen = true }
        }
        return roles
    }

    public static func pairs(_ pageCount: Int) -> [PDFPageRole] {
        (0..<max(0, pageCount)).map { $0 % 2 == 0 ? .image : .text }
    }
}

/// Read-only parsing of the single SPEC header grammar. Stripping and metadata use the same scan.
public enum PDFHeaderParser {
    public static let documentDatePrefix = "Document date: "
    public static let sentWithPrefix = "Sent with: "
    public static let dateEvidencePrefix = "Date evidence: "
    public static let kindPrefix = "Kind: "

    public static func extract(_ url: URL) -> ExtractedContent? {
        guard let doc = PDFDocument(url: url), !doc.isLocked else { return nil }
        let carried = doc.documentRef.flatMap(PDFHeaderCarrier.pages(of:))
        let roles = carried.map { PDFPageRole.roles(carried: $0, pageCount: doc.pageCount) } ?? PDFPageRole.pairs(doc.pageCount)
        var texts: [String] = []
        var textPages: [PDFTextPageMetadata] = []
        var firstTextPage: ParsedPDFTextPage?
        for i in 0..<doc.pageCount {
            let text = doc.page(at: i)?.string ?? ""
            switch roles[i] {
            case .searchable:
                // W42.int-s5-searchable: the header is the carrier's; the page's own text is the layer, all body.
                let header = carried?[i].flatMap { parse($0).header }
                let headerText = header != nil ? carried?[i] ?? "" : ""
                let page = ParsedPDFTextPage(header: header, body: text.trimmingCharacters(in: .whitespacesAndNewlines))
                if !(headerText + text).isEmpty { texts.append([headerText, text].filter { !$0.isEmpty }.joined(separator: "\n")) }
                textPages.append(PDFTextPageMetadata(pageIndex: i, header: header))
                if firstTextPage == nil { firstTextPage = page }
            case .text:
                if !text.isEmpty { texts.append(text) }
                let parsed = doc.page(at: i).map { parse($0) } ?? parse(text)
                textPages.append(PDFTextPageMetadata(pageIndex: i, header: parsed.header))
                if firstTextPage == nil { firstTextPage = parsed }
            case .image:
                if !text.isEmpty { texts.append(text) }
            }
        }
        let fullBody = texts.joined(separator: "\n")
        return ExtractedContent(fullBody: fullBody,
            strippedBody: firstTextPage?.header != nil ? firstTextPage!.body : fullBody,
            classification: firstTextPage?.header?.classification, pageCount: doc.pageCount,
            textPages: textPages, pageRoles: roles)
    }

    /// The header of every text page and searchable page of `doc`, in page order (`PDFPageRole`), without the bodies:
    /// for a caller that summarizes Kind or reader across a file.
    public static func textPageHeaders(_ doc: PDFDocument) -> [PDFPageHeader?] {
        let carried = doc.documentRef.flatMap(PDFHeaderCarrier.pages(of:))
        let roles = carried.map { PDFPageRole.roles(carried: $0, pageCount: doc.pageCount) } ?? PDFPageRole.pairs(doc.pageCount)
        return roles.indices.compactMap { i -> PDFPageHeader?? in
            switch roles[i] {
            case .image: return nil
            case .text: return .some(doc.page(at: i).flatMap { parse($0).header })
            case .searchable: return .some(carried?[i].flatMap { parse($0).header })
            }
        }
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
        } else { selected = first ?? longFilenameCandidate(lines) }
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
            } else if line.hasPrefix(dateEvidencePrefix) {
                field = 4; value = String(line.dropFirst(dateEvidencePrefix.count))
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
            case 4: header.dateEvidence = value
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

    /// A filename PDFKit reads back as three or more lines (a long name wrapped, or split at
    /// underscores) pushes provenance past the fixed slots. Only when those slots hold no candidate:
    /// the filename lines must be nonempty, not fields, no longer together than one file name
    /// (255 bytes), contain no provenance separator, and end in an extension; the line after them
    /// must be well-formed provenance. Anything else leaves provenance missing, never a body search.
    static let maxFilenameBytes = 255

    private static func longFilenameCandidate(_ lines: [String]) -> ProvenanceCandidate? {
        var bytes = 0
        var start = 1
        while start < lines.count {
            let line = lines[start].trimmingCharacters(in: .whitespaces)
            if start >= 4, let candidate = provenanceCandidate(lines, at: start) {
                let previous = lines[start - 1].trimmingCharacters(in: .whitespaces)
                guard looksLikeFilename(previous), parseProvenance(candidate.raw) != nil else { return nil }
                return candidate
            }
            bytes += line.utf8.count
            guard !line.isEmpty, start == 1 || !isField(line), !line.contains(" · "), !line.hasSuffix(" ·"),
                  bytes <= maxFilenameBytes else { return nil }
            start += 1
        }
        return nil
    }

    private static func looksLikeFilename(_ line: String) -> Bool {
        // An explicit extension disambiguates a filename containing several middle dots from a
        // malformed three-position provenance line. Extensionless provenance lookalikes are ambiguous.
        line.range(of: #"\.[A-Za-z0-9]{1,8}$"#, options: .regularExpression) != nil
    }

    private static func isField(_ line: String) -> Bool {
        ["Classification:", "Kind:", documentDatePrefix, sentWithPrefix, dateEvidencePrefix].contains { line.hasPrefix($0) }
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
