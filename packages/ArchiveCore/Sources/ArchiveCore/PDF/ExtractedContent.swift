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

        // Scan all pages for a Classification: line (Reader's behavior — first match wins).
        var classification: String?
        for text in pageTexts {
            if let c = parseClassification(from: text) {
                classification = c
                break
            }
        }

        // Attempt to parse the Processor's app-format header from page 2 to produce strippedBody.
        let strippedBody: String
        if doc.pageCount >= 2, let textPage = doc.page(at: 1),
           let pageText = textPage.string, pageText.hasPrefix("Extracted text.") {
            strippedBody = stripHeader(from: pageText)
        } else {
            // Not app-format — stripped = full (nothing to strip).
            strippedBody = fullBody
        }

        return ExtractedContent(
            fullBody: fullBody,
            strippedBody: strippedBody,
            classification: classification,
            pageCount: doc.pageCount
        )
    }

    /// Parse the `Classification:` value from a page's text. Returns `nil` if absent or empty.
    public static func parseClassification(from text: String) -> String? {
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Classification:") {
                let value = t.dropFirst("Classification:".count).trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    /// Strip the Processor's app-format header from page-2 text, returning only the body below it.
    ///
    /// Header format (from PDFGenerator.makeTextPage):
    ///   Extracted text.
    ///   {original filename}
    ///   {Provider} · {Model} · {Date}
    ///   Classification: {value}   (optional)
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
