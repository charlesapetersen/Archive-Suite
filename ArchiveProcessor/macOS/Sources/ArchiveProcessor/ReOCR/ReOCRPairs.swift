import ArchiveCore
import Foundation
import PDFKit

// MARK: - Improve OCR: which pages may be read again, and their new text pages (W44.reocr-processor)

/// Recognizes suite pairs and searchable pages. Every other page can receive searchable text on the page itself.
enum ReOCRPairs {
    struct Pair: Equatable, Sendable {
        /// 0-based page indices. For a direct layer edit the two refer to the same page.
        let imageIndex: Int
        let textIndex: Int
        let header: PDFPageHeader?

        var isSearchable: Bool { imageIndex == textIndex }
    }

    enum Refusal: Error, Equatable, CustomStringConvertible {
        case unreadable
        case locked
        case signed
        case noReading(page: Int, String)
        case pageNotMade(page: Int)
        case layerNotMade(page: Int)
        case headerNotKept(page: Int, String)

        var description: String {
            switch self {
            case .unreadable: "the file does not open as a PDF"
            case .locked: "the file is encrypted"
            case .signed: "the file carries a digital signature"
            case .noReading(let p, let why): "page \(p + 1) was not read: \(why)"
            case .layerNotMade(let p): "the new searchable text for page \(p + 1) could not be written and read back"
            case .pageNotMade(let p): "the new text page for page \(p + 1) could not be made"
            case .headerNotKept(let p, let what): "the new text page for page \(p + 1) would change its \(what)"
            }
        }
    }

    static func validate(_ data: Data) -> Result<[Pair], Refusal> {
        guard let doc = PDFDocument(data: data) else { return .failure(.unreadable) }
        if doc.isEncrypted || doc.isLocked { return .failure(.locked) }
        switch ReOCRIncrementalWriter.eligibility(of: data) {
        case .success: break
        case .failure(.encrypted): return .failure(.locked)
        case .failure(.signed): return .failure(.signed)
        case .failure: return .failure(.unreadable)
        }
        let count = doc.pageCount
        guard count > 0 else { return .failure(.unreadable) }
        let carrier = doc.documentRef.flatMap(PDFHeaderCarrier.pages(of:))
        let carried = carrier.flatMap { $0.count == count ? $0 : nil }
        let roles = PDFPageRole.roles(carried: carried ?? [], pageCount: count)
        var headers: [PDFPageHeader?] = []
        for index in 0..<count {
            guard let page = doc.page(at: index) else { return .failure(.unreadable) }
            headers.append(PDFHeaderParser.parse(page).header)
        }

        // Only replace separate text pages if the entire arrangement agrees with the suite's roles.
        // A header-like page in an ambiguous file is kept, like any other original page.
        let suiteLayout = roles.indices.allSatisfy { index in
            switch roles[index] {
            case .image: headers[index] == nil && index + 1 < count && roles[index + 1] == .text
            case .text:
                headers[index]?.rawProvenance != nil
                    && (headers[index]?.classification.map { classification($0) != nil } ?? true)
            case .searchable: true
            }
        }
        let targets: [Pair] = roles.indices.compactMap { index in
            if suiteLayout {
                if roles[index] == .image { return nil }
                if roles[index] == .text {
                    return Pair(imageIndex: index - 1, textIndex: index, header: headers[index])
                }
            }
            let header = carried?[index].flatMap { PDFHeaderParser.parse($0).header }
            return Pair(imageIndex: index, textIndex: index, header: header)
        }
        return .success(targets)
    }

    /// The classification a header line names, by the display name `makeTextPage` writes.
    static func classification(_ display: String) -> DocumentClassification? {
        [DocumentClassification.boxLabel, .folderLabel, .documentStart, .documentContinuation]
            .first { $0.displayName == display }
    }

    static func readingText(_ result: OCRResult, page: Int) throws -> String {
        if let code = result.errorCode { throw Refusal.noReading(page: page, result.errorMessage ?? code) }
        guard let text = result.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Refusal.noReading(page: page, "the reader returned no text")
        }
        return text
    }

    /// The new text page for `pair` keeps its original filename, classification, source dates and image straightening.
    /// It replaces the reader provenance, processing date, `kind` and transcription. `result` is the
    /// reading of this pair's image page; its own classification is not used, since the classification belongs to
    /// segmentation, not to this re-read. A failed, refused, cut-off or empty reading is never made into a page: the
    /// old text stays.
    static func replacementPage(for pair: Pair, result: OCRResult, model: LLMModel, kind: OCRPageKind?,
                                textColumns: Int = 1,
                                gatewayDisplayName: String? = nil, localAgentDisplayName: String? = nil,
                                localAgentModelName: String? = nil) throws -> Data {
        guard !pair.isSearchable, let old = pair.header else { throw Refusal.pageNotMade(page: pair.textIndex) }
        let text = try readingText(result, page: pair.textIndex)
        let kept = OCRResult(text: text, classification: old.classification.flatMap(classification),
                             rotationDegrees: result.rotationDegrees, errorMessage: result.errorMessage,
                             errorCode: result.errorCode, secondReader: result.secondReader,
                             pageReader: result.pageReader, imported: result.imported)
        let dates = PDFSourceDates(documentDate: old.documentDate, sentWith: old.sentWith,
                                   dateEvidence: old.dateEvidence, itemFields: old.itemFields)
        // PDFKit reads a wrapped or underscore-split filename back as several lines; the written name never holds a
        // line break (`headerBlock` turns control characters into spaces), so the lines join with nothing between.
        let filename = old.originalFilename?.replacingOccurrences(of: "\n", with: "")
        let cols = SessionProcessingConfig.clampTextColumns(textColumns)
        guard let page = PDFGenerator().textPageData(result: kept, model: model, originalFileName: filename,
                                                     gatewayDisplayName: gatewayDisplayName,
                                                     localAgentDisplayName: localAgentDisplayName,
                                                     localAgentModelName: localAgentModelName,
                                                     textColumns: cols,
                                                     sourceDates: dates.isEmpty ? nil : dates, pageKind: kind,
                                                     straightenedDegrees: old.straightenedDegrees) else {
            throw Refusal.pageNotMade(page: pair.textIndex)
        }
        // The kept lines must read back exactly as the old page's did.
        guard let made = PDFDocument(data: page)?.page(at: 0), let h = PDFHeaderParser.parse(made).header else {
            throw Refusal.pageNotMade(page: pair.textIndex)
        }
        if h.originalFilename != old.originalFilename { throw Refusal.headerNotKept(page: pair.textIndex, "original filename") }
        if h.classification != old.classification { throw Refusal.headerNotKept(page: pair.textIndex, "classification") }
        if h.documentDate != old.documentDate || h.sentWith != old.sentWith || h.dateEvidence != old.dateEvidence {
            throw Refusal.headerNotKept(page: pair.textIndex, "document dates")
        }
        if h.straightenedDegrees != old.straightenedDegrees {
            throw Refusal.headerNotKept(page: pair.textIndex, "image straightening")
        }
        if h.itemFields != old.itemFields { throw Refusal.headerNotKept(page: pair.textIndex, "item fields") }
        if let kind, h.kind != kind { throw Refusal.headerNotKept(page: pair.textIndex, "kind") }
        return page
    }
}
