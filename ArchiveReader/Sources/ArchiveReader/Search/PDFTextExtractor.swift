import Foundation
import PDFKit

/// Text pulled from a document for indexing.
struct ExtractedContent: Sendable {
    var body: String
    var classification: String?   // "Document Start" / "Continuation" / "Box" / "Folder" — if present
    var pageCount: Int
}

/// Extracts selectable text from a PDF for the content index. Read-only; guards corrupt / non-PDF /
/// unusual page counts by returning nil or whatever text exists (never crashes).
enum PDFTextExtractor {
    static func extract(_ url: URL) -> ExtractedContent? {
        guard let doc = PDFDocument(url: url) else { return nil }   // corrupt / encrypted / non-PDF
        var parts: [String] = []
        var classification: String?
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let text = page.string, !text.isEmpty else { continue }
            parts.append(text)
            if classification == nil { classification = parseClassification(from: text) }
        }
        return ExtractedContent(body: parts.joined(separator: "\n"),
                                classification: classification,
                                pageCount: doc.pageCount)
    }

    /// The `Classification:` line Archive Processor writes on the OCR page (may be absent).
    static func parseClassification(from text: String) -> String? {
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Classification:") {
                let value = t.dropFirst("Classification:".count).trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}
