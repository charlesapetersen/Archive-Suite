import Foundation

// MARK: - Non-standard PDF detection (read-only)
//
// Pure, UI-free classifier for whether a tagged PDF is a *standard* readable document or a
// non-standard one that needs a human's attention. Read-only triage signal only — this never
// drives a write (that is TagWriter's exclusive job) and never mutates a file.
//
// NOTE — page count is deliberately NOT a defect signal: the corpus legitimately holds >2-page
// merged PDFs, so a file is flagged ONLY when it can't be opened, or opens with no selectable text.
// Page count is recorded for display, never for "needs attention".

/// The readability/format status of a tagged PDF, derived from a single content-extraction attempt.
enum PDFFormatStatus: Sendable, Equatable {
    case standard          // opened, has selectable OCR text
    case unreadable        // couldn't open: corrupt / encrypted / non-PDF
    case noTextLayer       // opened but zero selectable text (can't read/search as text)

    /// Classify from the two orthogonal facts the extractor establishes.
    static func classify(readable: Bool, hasText: Bool) -> PDFFormatStatus {
        guard readable else { return .unreadable }
        return hasText ? .standard : .noTextLayer
    }

    /// Convenience over an extraction result: `nil` (open failed) → `.unreadable`; otherwise text
    /// presence is decided by a non-empty body.
    static func classify(_ content: ExtractedContent?) -> PDFFormatStatus {
        guard let content else { return .unreadable }
        return classify(readable: true, hasText: !content.body.isEmpty)
    }

    /// True for anything a human should look at (unreadable or text-less); `.standard` is fine.
    var needsAttention: Bool { self != .standard }

    /// Short, human-readable label for a badge tooltip / health readout.
    var label: String {
        switch self {
        case .standard:    return "Standard"
        case .unreadable:  return "Unreadable"
        case .noTextLayer: return "No text layer"
        }
    }
}
