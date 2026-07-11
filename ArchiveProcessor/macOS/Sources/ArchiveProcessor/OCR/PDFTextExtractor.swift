import Foundation
import ArchiveCore

/// Thin Processor-side wrapper over the shared `PDFHeaderParser`. Returns the header-stripped
/// body text and maps the raw classification string to the Processor's persisted
/// `DocumentClassification` enum (unknown values → `nil`).
struct PDFTextExtractor {

    struct ExtractionResult {
        let text: String?
        let classification: DocumentClassification?
    }

    /// Extract text from a PDF file, delegating to the shared Core parser.
    ///
    /// For app-format PDFs: returns the header-stripped body + mapped classification.
    /// For any other PDF: returns all-pages text, nil classification.
    static func extract(from url: URL) -> ExtractionResult {
        guard let content = PDFHeaderParser.extract(url) else {
            return ExtractionResult(text: nil, classification: nil)
        }

        let text = content.strippedBody.isEmpty ? nil : content.strippedBody
        return ExtractionResult(text: text, classification: mapClassification(content.classification))
    }

    /// Map the Core parser's raw classification string to the Processor's persisted enum.
    /// Only the four known SPEC values map; everything else (including unknown future values) → nil.
    private static func mapClassification(_ raw: String?) -> DocumentClassification? {
        switch raw {
        case "Box":                return .boxLabel
        case "Folder":             return .folderLabel
        case "Document Start":     return .documentStart
        case "Continuation":       return .documentContinuation
        default:                   return nil
        }
    }
}
