import Foundation
import PDFKit

/// Extracts OCR text and classification from pre-existing PDFs.
struct PDFTextExtractor {

    struct ExtractionResult {
        let text: String?
        let classification: DocumentClassification?
    }

    /// Extract text from a PDF file.
    ///
    /// For PDFs produced by this app (2-page format: image + text page):
    ///   - Reads page 2 and parses classification from the header.
    ///   - Returns the OCR body text (below the header).
    ///
    /// For any other PDF:
    ///   - Concatenates text from all pages.
    static func extract(from url: URL) -> ExtractionResult {
        guard let document = PDFDocument(url: url) else {
            return ExtractionResult(text: nil, classification: nil)
        }

        // Try the app's 2-page format first: page 2 is the text page
        if document.pageCount >= 2, let textPage = document.page(at: 1) {
            let pageText = textPage.string ?? ""
            if pageText.hasPrefix("Extracted text.") {
                return parseAppFormat(pageText)
            }
        }

        // Generic PDF: concatenate text from all pages
        var allText = ""
        for i in 0..<document.pageCount {
            if let page = document.page(at: i), let text = page.string {
                if !allText.isEmpty { allText += "\n\n" }
                allText += text
            }
        }

        return ExtractionResult(
            text: allText.isEmpty ? nil : allText,
            classification: nil
        )
    }

    /// Parse text from a page produced by this app's PDFGenerator.
    /// Format (see PDFGenerator.makeTextPage):
    ///   Extracted text.
    ///   {original filename}
    ///   {Provider} · {Model} · {Date}
    ///   Classification: {Box|Folder|Document Start|Continuation}   (optional)
    ///
    ///   {body text}
    private static func parseAppFormat(_ pageText: String) -> ExtractionResult {
        let lines = pageText.components(separatedBy: .newlines)
        var bodyStartIndex = 0
        var classification: DocumentClassification? = nil
        // The provider/model/date line (contains " · ") marks the end of the fixed header.
        // We must not treat an earlier unknown line (the filename) as the body, but we also
        // can't rely on a blank separator surviving PDFKit extraction — so the body-break
        // fallback below is only armed once this line has been seen.
        var seenMetaLine = false

        // Scan header lines
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("Classification:") {
                let value = trimmed
                    .replacingOccurrences(of: "Classification:", with: "")
                    .trimmingCharacters(in: .whitespaces)

                switch value {
                case "Box": classification = .boxLabel
                case "Folder": classification = .folderLabel
                case "Document Start": classification = .documentStart
                case "Continuation": classification = .documentContinuation
                default: break
                }
                bodyStartIndex = i + 1
                continue
            }

            // Header ends at the first blank line after "Extracted text."
            if trimmed.isEmpty && i > 0 {
                bodyStartIndex = i + 1
                break
            }

            // Still in header area
            if trimmed.hasPrefix("Extracted text.") || trimmed.contains(" \u{00B7} ") {
                if trimmed.contains(" \u{00B7} ") { seenMetaLine = true }
                bodyStartIndex = i + 1
                continue
            }

            // An unknown line before the provider/model/date line (e.g. the filename): skip it,
            // don't mistake it for body. The real body-break is only armed after the meta line.
            if !seenMetaLine {
                continue
            }

            // Reached body text
            bodyStartIndex = i
            break
        }

        let bodyText = lines.dropFirst(bodyStartIndex)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ExtractionResult(
            text: bodyText.isEmpty ? nil : bodyText,
            classification: classification
        )
    }
}
