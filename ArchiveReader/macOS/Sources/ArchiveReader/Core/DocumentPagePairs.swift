import ArchiveCore
import PDFKit

/// The image/OCR-text **page-pair** model of an archival PDF.
///
/// `SPEC/tag-format.md` §"2-page PDF structure" pairs each scanned image page with a page-2-format OCR
/// text page, and its "Interleaved multi-page variant" clause says a single output PDF may alternate
/// image, text, image, text, … — one such pair per source page. That is produced by the Processor's
/// `PDFGenerator.mergeDocumentPDFs` (merged multi-page documents) and by its "Re-OCR multi-page PDF"
/// mode. The SPEC is explicit that **consumers must not hard-assume two pages**. Its §"The searchable form"
/// (W42.int-s5-searchable) adds a page that is a pair alone: the image with its text as the layer, no text page,
/// its header in the XMP. Which page is which is Core's `PDFPageRole.roles`, never the page's parity.
///
/// So "which pages does the two-pane viewer show" is a function of the *pair*, not a constant: pair `p`
/// displays its image page on the left and its OCR text page, when it has one, on the right. This small
/// value type is the single place that mapping lives, shared by `DocumentViewerModel` (display + cycling),
/// `DocumentFindScanner` (match bucketing) and the thumbnail views, so they can't drift.
struct DocumentPagePairs: Equatable, Sendable {
    struct Pair: Equatable, Sendable {
        var image: Int
        var text: Int?
    }

    let pairs: [Pair]

    /// Pages in order: an image starts a pair, a text page completes the pair waiting for one, a searchable page is
    /// a pair alone. A trailing image with no text page counts as a final pair with **no** text page — a merge of a
    /// 2-page document and a text-less 1-page one lands there, and dropping it would make that last scan unreachable.
    init(roles: [PDFPageRole]) {
        var pairs: [Pair] = []
        var waiting = false
        for (i, role) in roles.enumerated() {
            switch role {
            case .image:
                pairs.append(Pair(image: i, text: nil)); waiting = true
            case .text:
                if waiting { pairs[pairs.count - 1].text = i } else { pairs.append(Pair(image: i, text: nil)) }
                waiting = false
            case .searchable:
                pairs.append(Pair(image: i, text: nil)); waiting = false
            }
        }
        self.pairs = pairs
    }

    /// The file read as pairs alone: what a page count says when the file itself has not been read.
    init(pageCount: Int) { self.init(roles: PDFPageRole.pairs(pageCount)) }

    init(document: PDFDocument?) {
        self.init(roles: document.map(PDFPageRole.roles(of:)) ?? [])
    }

    static let empty = DocumentPagePairs(roles: [])

    /// How many image/text pairs the document has.
    var count: Int { pairs.count }

    /// PDF page index of a pair's image page (left pane). Past the last pair it is the index pairs alone would
    /// give, which callers bounds-check against `pageCount`.
    func imagePageIndex(pair: Int) -> Int {
        pairs.indices.contains(pair) ? pairs[pair].image : pair * 2
    }

    /// PDF page index of a pair's OCR text page (right pane); nil when the pair has none (a trailing scan, or a
    /// searchable page) or is past the end.
    func textPageIndex(pair: Int) -> Int? {
        pairs.indices.contains(pair) ? pairs[pair].text : nil
    }

    /// Which pair a PDF page index belongs to (image and text page of a pair share one pair index). A page past the
    /// end belongs to the pair pairs alone would give it.
    func pair(ofPageIndex index: Int) -> Int {
        pairs.firstIndex { $0.image == index || $0.text == index } ?? index / 2
    }

    /// True when a PDF page index is a pair's image page (a scan, or a searchable page) rather than its OCR text page.
    func isImagePage(_ index: Int) -> Bool {
        if pairs.contains(where: { $0.text == index }) { return false }
        return pairs.contains { $0.image == index } || index % 2 == 0
    }
}
