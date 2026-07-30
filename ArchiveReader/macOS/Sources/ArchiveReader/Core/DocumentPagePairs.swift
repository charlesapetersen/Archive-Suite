/// The interleaved image/OCR-text **page-pair** model of an archival PDF.
///
/// `SPEC/tag-format.md` §"2-page PDF structure" pairs each scanned image page with a page-2-format OCR
/// text page, and its "Interleaved multi-page variant" clause says a single output PDF may alternate
/// image, text, image, text, … — one such pair per source page. That is produced by the Processor's
/// `PDFGenerator.mergeDocumentPDFs` (merged multi-page documents) and by its "Re-OCR multi-page PDF"
/// mode. The SPEC is explicit that **consumers must not hard-assume two pages**.
///
/// So "which pages does the two-pane viewer show" is a function of the *pair*, not a constant: pair `p`
/// displays PDF page `2p` on the left (image) and page `2p + 1` on the right (OCR text). This tiny pure
/// type is the single place that arithmetic lives, shared by `DocumentViewerModel` (display + cycling)
/// and `DocumentFindScanner` (match bucketing) so the two can't drift.
enum DocumentPagePairs {
    /// How many image/text pairs a `pageCount`-page document has. A trailing odd page counts as a final
    /// pair with **no** text page — a merge of a 2-page document and a text-less 1-page one lands there,
    /// and rounding down would make that last scan unreachable, which is the bug this model fixes.
    static func pairCount(pageCount: Int) -> Int {
        pageCount <= 0 ? 0 : (pageCount + 1) / 2
    }

    /// PDF page index of a pair's image page (left pane).
    static func imagePageIndex(pair: Int) -> Int { pair * 2 }

    /// PDF page index of a pair's OCR text page (right pane). May be past the end of a document whose
    /// last pair has no text page — callers bounds-check against `pageCount`.
    static func textPageIndex(pair: Int) -> Int { pair * 2 + 1 }

    /// Which pair a PDF page index belongs to (image and text page of a pair share one pair index).
    static func pair(ofPageIndex index: Int) -> Int { index / 2 }

    /// True when a PDF page index is a pair's image page (even) rather than its OCR text page (odd).
    static func isImagePage(_ index: Int) -> Bool { index % 2 == 0 }
}
