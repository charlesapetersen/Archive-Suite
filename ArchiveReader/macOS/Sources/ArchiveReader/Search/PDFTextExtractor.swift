import Foundation
import ArchiveCore

/// Thin Reader-side wrapper over the shared `PDFHeaderParser`. Reader indexes `fullBody`
/// (all pages, including headers) for FTS — preserving the historical behavior that page-1
/// text-layer content and header metadata are searchable.
enum PDFTextExtractor {
    static func extract(_ url: URL) -> ExtractedContent? {
        PDFHeaderParser.extract(url)
    }
}
