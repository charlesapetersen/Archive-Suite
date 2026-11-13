import ArchiveCore
import Foundation
import PDFKit

// MARK: - Improve OCR: which pages may be read again, and their new text pages (W44.reocr-processor)

/// The suite image/text pairs of a file, positively validated before any in-place work (`execution-plans/reocr/
/// 00-plan.md` §4), and the replacement text page for a pair (§2).
///
/// A file qualifies only when it opens unlocked, has an even number of pages, at least two, every odd page (the
/// second of each pair) begins with the suite header and carries a provenance line, and no even page (an image page)
/// reads as a suite header. An even page count alone proves nothing. A raw one-page or image-only original, an odd
/// or mixed structure, an encrypted file and a header-like trap are refused with the reason; the separate-output
/// re-OCR route is the one for them. Signed files and cross-reference streams are refused later by
/// `ReOCRIncrementalWriter`, which also proves the candidate kept everything else.
enum ReOCRPairs {
    struct Pair: Equatable, Sendable {
        /// 0-based page indices: the image page and the text page after it.
        let imageIndex: Int
        let textIndex: Int
        let header: PDFPageHeader
    }

    enum Refusal: Error, Equatable, CustomStringConvertible {
        case unreadable
        case locked
        case notPaired(pages: Int)
        case textPageWithoutHeader(page: Int)
        case textPageWithoutProvenance(page: Int)
        case imagePageLooksLikeText(page: Int)
        case unknownClassification(page: Int, String)
        case noReading(page: Int, String)
        case pageNotMade(page: Int)
        case headerNotKept(page: Int, String)

        var description: String {
            switch self {
            case .unreadable: "the file does not open as a PDF"
            case .locked: "the file is encrypted"
            case .notPaired(let n):
                n < 2 ? "the file is a single page, not an image page with its text page; use Reprocess to make a new file"
                    : "the file has \(n) pages, not image and text pages in pairs"
            case .textPageWithoutHeader(let p): "page \(p + 1) is not a suite text page (it does not begin with “Extracted text.”)"
            case .textPageWithoutProvenance(let p): "page \(p + 1) has no reader line in its header"
            case .imagePageLooksLikeText(let p): "page \(p + 1) should be an image page but reads as a text page"
            case .unknownClassification(let p, let c): "page \(p + 1) has a classification this app does not write (“\(c)”)"
            case .noReading(let p, let why): "page \(p + 1) was not read: \(why)"
            case .pageNotMade(let p): "the new text page for page \(p + 1) could not be made"
            case .headerNotKept(let p, let what): "the new text page for page \(p + 1) would change its \(what)"
            }
        }
    }

    static func validate(_ data: Data) -> Result<[Pair], Refusal> {
        guard let doc = PDFDocument(data: data) else { return .failure(.unreadable) }
        if doc.isEncrypted || doc.isLocked { return .failure(.locked) }
        let count = doc.pageCount
        guard count >= 2, count % 2 == 0 else { return .failure(.notPaired(pages: count)) }
        var pairs: [Pair] = []
        for imageIndex in stride(from: 0, to: count, by: 2) {
            guard let image = doc.page(at: imageIndex), let text = doc.page(at: imageIndex + 1) else {
                return .failure(.unreadable)
            }
            if PDFHeaderParser.parse(image).header != nil { return .failure(.imagePageLooksLikeText(page: imageIndex)) }
            guard let header = PDFHeaderParser.parse(text).header else {
                return .failure(.textPageWithoutHeader(page: imageIndex + 1))
            }
            guard header.rawProvenance != nil else { return .failure(.textPageWithoutProvenance(page: imageIndex + 1)) }
            if let c = header.classification, classification(c) == nil {
                return .failure(.unknownClassification(page: imageIndex + 1, c))
            }
            pairs.append(Pair(imageIndex: imageIndex, textIndex: imageIndex + 1, header: header))
        }
        return .success(pairs)
    }

    /// The classification a header line names, by the display name `makeTextPage` writes.
    static func classification(_ display: String) -> DocumentClassification? {
        [DocumentClassification.boxLabel, .folderLabel, .documentStart, .documentContinuation]
            .first { $0.displayName == display }
    }

    /// The new text page for `pair`: the pair's original filename, classification and source-date lines as they
    /// were, the new reader's provenance (today's date) and `kind`, then the new transcription. `result` is the
    /// reading of this pair's image page; its own classification is not used, since the classification belongs to
    /// segmentation, not to this re-read. A failed, refused, cut-off or empty reading is never made into a page: the
    /// old text stays.
    static func replacementPage(for pair: Pair, result: OCRResult, model: LLMModel, kind: OCRPageKind?,
                                gatewayDisplayName: String? = nil, localAgentDisplayName: String? = nil,
                                localAgentModelName: String? = nil) throws -> Data {
        if let code = result.errorCode { throw Refusal.noReading(page: pair.textIndex, result.errorMessage ?? code) }
        guard let text = result.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Refusal.noReading(page: pair.textIndex, "the reader returned no text")
        }
        let kept = OCRResult(text: text, classification: pair.header.classification.flatMap(classification),
                             rotationDegrees: result.rotationDegrees, errorMessage: result.errorMessage,
                             errorCode: result.errorCode, secondReader: result.secondReader,
                             pageReader: result.pageReader, imported: result.imported)
        let dates = PDFSourceDates(documentDate: pair.header.documentDate, sentWith: pair.header.sentWith)
        // PDFKit reads a wrapped or underscore-split filename back as several lines; the written name never holds a
        // line break (`makeTextPage` turns control characters into spaces), so the lines join with nothing between.
        let filename = pair.header.originalFilename?.replacingOccurrences(of: "\n", with: "")
        guard let page = PDFGenerator().textPageData(result: kept, model: model, originalFileName: filename,
                                                     gatewayDisplayName: gatewayDisplayName,
                                                     localAgentDisplayName: localAgentDisplayName,
                                                     localAgentModelName: localAgentModelName,
                                                     sourceDates: dates.isEmpty ? nil : dates, pageKind: kind) else {
            throw Refusal.pageNotMade(page: pair.textIndex)
        }
        // The kept lines must read back exactly as the old page's did.
        guard let made = PDFDocument(data: page)?.page(at: 0), let h = PDFHeaderParser.parse(made).header else {
            throw Refusal.pageNotMade(page: pair.textIndex)
        }
        let old = pair.header
        if h.originalFilename != old.originalFilename { throw Refusal.headerNotKept(page: pair.textIndex, "original filename") }
        if h.classification != old.classification { throw Refusal.headerNotKept(page: pair.textIndex, "classification") }
        if h.documentDate != old.documentDate || h.sentWith != old.sentWith {
            throw Refusal.headerNotKept(page: pair.textIndex, "document dates")
        }
        if let kind, h.kind != kind { throw Refusal.headerNotKept(page: pair.textIndex, "kind") }
        return page
    }
}
