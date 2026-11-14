import Foundation
import PDFKit
import ArchiveCore

/// W46.date-route-header — the `Date evidence:` line of a Process Files output. Process Files renders each page before
/// the dating route runs, so the line is added afterwards: the text page is laid out again from its own header lines,
/// read back verbatim, and the run's OCR text, with the line in its SPEC place; the image page is kept as it is.
extension PDFGenerator {
    enum DateEvidenceRewrite: Equatable {
        /// The new file's bytes, verified to read back with every other header line and the body unchanged.
        case rewrite(Data)
        /// The page already carries this evidence (or none, and none is wanted).
        case unchanged
        /// Left as it is, and why: the sidecar still carries the evidence.
        case skipped(String)
    }

    /// The bytes `pdf` should have so its text page carries `evidence` (nil removes the line). Only a plain pair, one
    /// image page and one text page, whose header parses with no problem and whose text is `body`: anything else is
    /// skipped rather than guessed at.
    /// W42.int-s5-searchable: a searchable output of one page has its header in the XMP; the line goes there, the page
    /// kept as it is.
    func dateEvidenceRewrite(of pdf: Data, evidence: String?, body: String, textColumns: Int) -> DateEvidenceRewrite {
        guard let doc = PDFDocument(data: pdf), !doc.isLocked else { return .skipped("not readable") }
        if PDFPageRole.roles(of: doc).contains(.searchable) {
            return searchableDateEvidenceRewrite(doc, evidence: evidence, body: body)
        }
        guard doc.pageCount == 2, let image = doc.page(at: 0), let text = doc.page(at: 1) else {
            return .skipped("not one image page and one text page")
        }
        let parsed = PDFHeaderParser.parse(text)
        guard let old = parsed.header, let provenance = old.rawProvenance, old.provenance != nil,
              old.diagnostics.allSatisfy({ $0 == .missingKind }) else { return .skipped("the header does not parse cleanly") }
        if old.dateEvidence == evidence { return .unchanged }
        guard Self.squashed(parsed.body) == Self.squashed(body) else { return .skipped("the page's text is not this run's") }

        let (header, fit) = Self.headerText(old, provenance: provenance, evidence: evidence)
        let page = layoutTextPage(headerLine: header + "\n\n", fitRanges: fit, bodyText: body, textColumns: textColumns)

        let out = PDFDocument()
        out.insert(image, at: 0)
        out.insert(page, at: 1)
        guard let data = out.dataRepresentation() else { return .skipped("the new page was not made") }
        // It must read back as the old page did, with only the evidence changed.
        guard let made = PDFDocument(data: data), made.pageCount == 2, let madeImage = made.page(at: 0),
              let madeText = made.page(at: 1) else {
            return .skipped("the new file does not read back")
        }
        // The image page is the one PDFKit copies in a merge too; it must keep its size, turn and any text.
        guard madeImage.bounds(for: .mediaBox) == image.bounds(for: .mediaBox), madeImage.rotation == image.rotation,
              (madeImage.string ?? "") == (image.string ?? "") else {
            return .skipped("the image page does not read back")
        }
        let back = PDFHeaderParser.parse(madeText)
        var expected = old
        expected.dateEvidence = evidence
        guard back.header == expected, Self.squashed(back.body) == Self.squashed(body) else {
            return .skipped("the new header does not read back as the old one")
        }
        return .rewrite(data)
    }

    /// `old`'s header lines with `evidence` as its date-evidence line (nil: none), and the lines fitted to one line each.
    private static func headerText(_ old: PDFPageHeader, provenance: String, evidence: String?) -> (String, [NSRange]) {
        var header = "Extracted text."
        // PDFKit reads a wrapped filename back as several lines; the written name never holds a line break.
        if let name = old.originalFilename { header += "\n" + name.replacingOccurrences(of: "\n", with: "") }
        var fit = [NSRange(location: header.utf16.count + 1, length: provenance.utf16.count)]
        header += "\n" + provenance
        if let c = old.classification { header += "\nClassification: " + c }
        if let k = old.kind { header += "\n" + PDFHeaderParser.kindPrefix + k.rawValue }
        let dates = PDFSourceDates(documentDate: old.documentDate, sentWith: old.sentWith, dateEvidence: evidence)
        for line in dates.headerLines {
            if line.hasPrefix(PDFHeaderParser.dateEvidencePrefix) {
                fit.append(NSRange(location: header.utf16.count + 1, length: line.utf16.count))
            }
            header += "\n" + line
        }
        return (header, fit)
    }

    /// The searchable form's rewrite: one page, its header in the XMP. The page is drawn again unchanged, so it must read
    /// back with the same size, turn and text; the header must read back as the old one with only the evidence changed.
    private func searchableDateEvidenceRewrite(_ doc: PDFDocument, evidence: String?, body: String) -> DateEvidenceRewrite {
        guard doc.pageCount == 1, let page = doc.page(at: 0),
              let carried = doc.documentRef.flatMap(PDFHeaderCarrier.pages(of:)), carried.count == 1,
              let oldText = carried[0] else { return .skipped("not one searchable page") }
        let parsed = PDFHeaderParser.parse(oldText)
        guard let old = parsed.header, let provenance = old.rawProvenance, old.provenance != nil, parsed.body.isEmpty,
              old.diagnostics.allSatisfy({ $0 == .missingKind }) else { return .skipped("the header does not parse cleanly") }
        if old.dateEvidence == evidence { return .unchanged }
        // The page is not laid out again, but the line must be about this run's reading: a searchable page's layer holds
        // every word of it (`searchableImagePage`).
        guard OutputForm.holds(page.string ?? "", every: body) else { return .skipped("the page's text is not this run's") }
        let header = Self.headerText(old, provenance: provenance, evidence: evidence).0
        guard let data = Self.archivalData(doc, pageHeaders: [header]),
              let made = PDFDocument(data: data), made.pageCount == 1, let madePage = made.page(at: 0) else {
            return .skipped("the new file does not read back")
        }
        guard madePage.bounds(for: .mediaBox) == page.bounds(for: .mediaBox), madePage.rotation == page.rotation,
              Self.squashed(madePage.string ?? "") == Self.squashed(page.string ?? "") else {
            return .skipped("the page does not read back")
        }
        var expected = old
        expected.dateEvidence = evidence
        guard let back = made.documentRef.flatMap(PDFHeaderCarrier.pages(of:)), back.count == 1,
              let backText = back[0], PDFHeaderParser.parse(backText).header == expected else {
            return .skipped("the new header does not read back as the old one")
        }
        return .rewrite(data)
    }

    /// Text with every white space removed: PDFKit's read-back changes line breaks and spacing, never the characters.
    static func squashed(_ s: String) -> String {
        String(s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }
}
