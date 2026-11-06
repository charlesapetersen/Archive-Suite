import Foundation
import PDFKit

/// Text extracted from a PDF for indexing and display.
///
/// - `fullBody`: every page's text concatenated (header lines included). Feed this to FTS — it
///   preserves page-1 text-layer content and the header metadata that Reader historically indexed.
/// - `strippedBody`: page-2 body text with the Processor header removed. Use for display.
/// - `classification`: the raw `Classification:` value (e.g. "Document Start"), or `nil`.
/// - `pageCount`: from `PDFDocument.pageCount`.
public struct ExtractedContent: Sendable {
    public var fullBody: String
    public var strippedBody: String
    public var classification: String?
    public var pageCount: Int

    public init(fullBody: String, strippedBody: String, classification: String?, pageCount: Int) {
        self.fullBody = fullBody
        self.strippedBody = strippedBody
        self.classification = classification
        self.pageCount = pageCount
    }
}

/// Extracts selectable text from a PDF. Read-only; guards corrupt / non-PDF / unusual page counts
/// by returning nil or whatever text exists (never crashes).
public enum PDFHeaderParser {

    /// Extract text content from a PDF at the given URL.
    ///
    /// Returns `nil` if the PDF can't be opened (corrupt / encrypted / non-PDF).
    /// The returned `ExtractedContent` provides both a full-body view (all pages, for FTS)
    /// and a stripped-body view (header removed, for display).
    public static func extract(_ url: URL) -> ExtractedContent? {
        guard let doc = PDFDocument(url: url) else { return nil }

        // Collect per-page text.
        var pageTexts: [String] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let text = page.string, !text.isEmpty else { continue }
            pageTexts.append(text)
        }

        let fullBody = pageTexts.joined(separator: "\n")

        // Parse the Processor's app-format header from page 2: the classification and strippedBody.
        // W40.fix-core-classification-from-body: the classification comes from that header block only,
        // never from a `Classification:` line in OCR body text or on another page.
        let strippedBody: String
        var classification: String?
        if doc.pageCount >= 2, let textPage = doc.page(at: 1),
           let pageText = textPage.string, pageText.hasPrefix("Extracted text.") {
            strippedBody = stripHeader(from: pageText)
            classification = parseClassification(from: pageText)
        } else {
            // Not app-format — stripped = full (nothing to strip), and no header to read a classification from.
            strippedBody = fullBody
        }

        return ExtractedContent(
            fullBody: fullBody,
            strippedBody: strippedBody,
            classification: classification,
            pageCount: doc.pageCount
        )
    }

    /// Parse the `Classification:` value from an app-format page-2 text. Returns `nil` if absent or empty.
    ///
    /// Read only from the header block (`stripHeader`'s layout): the page must start `Extracted text.`, and
    /// the line must directly follow the provider/model line, ahead of any source-date line (the SPEC's
    /// order). A `Classification:` line in the OCR body (an archival security marking) or a file name that
    /// starts with the word is not the classification (W40.fix-core-classification-from-body).
    ///
    /// The scan stops at the first line that is not a header line, not only at the blank separator: PDFKit
    /// drops that blank line from a real page's text (seen on the corpus's app-format PDFs, 2026-11-06), so
    /// the header runs straight into the body. A body whose FIRST line is a `Classification:` line under a
    /// header without one therefore still reads as the header's; nothing on such a page tells them apart.
    public static func parseClassification(from text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("Extracted text.") else {
            return nil
        }
        var seenMetaLine = false, metaLineEnded = false, extraLine = false
        for line in lines.dropFirst() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { break }  // the blank separator, when the text kept it
            if !seenMetaLine {
                // The optional file name comes before the meta line and is skipped whatever it says.
                if t.contains(" \u{00B7} ") { seenMetaLine = true; metaLineEnded = endsWithYear(t) }
                continue
            }
            if t.hasPrefix("Classification:") {
                let value = t.dropFirst("Classification:".count).trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
            if isSourceDateLine(t) { return nil }  // the classification comes before the date lines
            // One more line may belong to the meta line: the rest of a wrapped one (it has not reached its
            // closing `d MMMM yyyy` date yet), or the real one after a file name with " · " in it.
            if !extraLine && (!metaLineEnded || (t.contains(" \u{00B7} ") && endsWithYear(t))) {
                extraLine = true
                metaLineEnded = true
                continue
            }
            return nil  // the body: the header had no classification
        }
        return nil
    }

    /// The meta line ends with the Processor's `d MMMM yyyy` processing date.
    private static func endsWithYear(_ trimmed: String) -> Bool {
        trimmed.range(of: #"[0-9]{4}$"#, options: .regularExpression) != nil
    }

    /// W37.dual-date: exact prefix of the optional source-document date line in the OCR-text header
    /// (the item's OWN date, e.g. `Document date: Nov 3, 1957`). Distinct from the provider line's OCR
    /// processing date. Written by Processor `PDFGenerator.makeTextPage`.
    public static let documentDatePrefix = "Document date: "
    /// W37.dual-date: exact prefix of the optional covering-letter date line (`Sent with: Mar 12, 1958`).
    public static let sentWithPrefix = "Sent with: "

    /// True when a trimmed header line is one of the two W37 source-date lines. Exact, case-sensitive
    /// prefixes; only consulted INSIDE the header block (after the provider/model line, before the first
    /// blank line), so body text that happens to start with these words is never consumed.
    static func isSourceDateLine(_ trimmed: String) -> Bool {
        trimmed.hasPrefix(documentDatePrefix) || trimmed.hasPrefix(sentWithPrefix)
    }

    /// Strip the Processor's app-format header from page-2 text, returning only the body below it.
    ///
    /// Header format (from PDFGenerator.makeTextPage):
    ///   Extracted text.
    ///   {original filename}
    ///   {Provider} · {Model} · {Date}
    ///   Classification: {value}   (optional)
    ///   Document date: {display}  (optional, W37.dual-date)
    ///   Sent with: {display}      (optional, W37.dual-date)
    ///
    ///   {body text}
    public static func stripHeader(from pageText: String) -> String {
        let lines = pageText.components(separatedBy: .newlines)
        var bodyStartIndex = 0
        var seenMetaLine = false

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("Classification:") {
                bodyStartIndex = i + 1
                continue
            }

            // W37 source-date lines sit after the provider/model line and before the blank separator.
            // Gated on `seenMetaLine` so they are only recognised inside the header block; the loop has
            // already broken out at the first blank line, so body text never reaches this test.
            if seenMetaLine && isSourceDateLine(trimmed) {
                bodyStartIndex = i + 1
                continue
            }

            // Header ends at the first blank line after "Extracted text."
            if trimmed.isEmpty && i > 0 {
                bodyStartIndex = i + 1
                break
            }

            if trimmed.hasPrefix("Extracted text.") || trimmed.contains(" \u{00B7} ") {
                if trimmed.contains(" \u{00B7} ") { seenMetaLine = true }
                bodyStartIndex = i + 1
                continue
            }

            // Unknown line before the meta line (e.g. filename) — skip, don't mistake for body.
            if !seenMetaLine {
                continue
            }

            // Reached body text.
            bodyStartIndex = i
            break
        }

        return lines.dropFirst(bodyStartIndex)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
