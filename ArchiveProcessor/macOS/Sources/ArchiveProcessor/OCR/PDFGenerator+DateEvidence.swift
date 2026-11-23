import Foundation
import PDFKit
import ArchiveCore

/// Process Files renders each page before tagging. Add the source dates, dating evidence and item fields together
/// once those values are known, keeping the image page and the rest of the text page.
extension PDFGenerator {
    enum DateEvidenceRewrite: Equatable {
        /// The new file's bytes, verified to read back with every other header line and the body unchanged.
        case rewrite(Data)
        /// The page already carries the requested fields.
        case unchanged
        /// The output could not be safely rewritten.
        case skipped(String)
    }

    /// Rebuild a generated pair's text page, or update a searchable page's XMP header. Absent fields clear old values.
    /// Use the actual source filename since PDFKit can read a nonbreaking space back as a space.
    func taggedHeaderRewrite(of pdf: Data, sourceName: String, fields: PDFSourceDates, body: String,
                             textColumns: Int) -> DateEvidenceRewrite {
        headerRewrite(of: pdf, sourceName: sourceName, body: body, textColumns: textColumns) {
            $0.documentDate = fields.documentDate
            $0.sentWith = fields.sentWith
            $0.dateEvidence = fields.dateEvidence
            $0.itemFields = fields.itemFields
        }
    }

    /// A reclassification can change Sent with independently of the dating route's own date and evidence.
    func reviewDateHeaderRewrite(of pdf: Data, sourceName: String, sentWith: String?,
                                 ownDating: (date: String?, evidence: String?)?, body: String,
                                 textColumns: Int) -> DateEvidenceRewrite {
        headerRewrite(of: pdf, sourceName: sourceName, body: body, textColumns: textColumns) {
            $0.sentWith = sentWith
            if let ownDating {
                $0.documentDate = ownDating.date
                $0.dateEvidence = ownDating.evidence
            }
        }
    }

    /// W40.fix-processor-review-classification-stale — the bytes `pdf` should have so its text page's
    /// `Classification:` line reads `classification` (a `DocumentClassification.displayName`; nil removes the line).
    /// Each page is rendered with the reader's proposal, and a review that changes the class afterwards must reach the
    /// header too, which SPEC §2-page PDF structure makes the value consumers read. Same checks as the evidence line.
    func classificationRewrite(of pdf: Data, sourceName: String, classification: String?, body: String,
                               textColumns: Int) -> DateEvidenceRewrite {
        headerRewrite(of: pdf, sourceName: sourceName, body: body, textColumns: textColumns) {
            $0.classification = classification
        }
    }

    /// The text page laid out again with `change` applied to its header, every other line and the body read back
    /// unchanged; the image page kept as it is.
    private func headerRewrite(of pdf: Data, sourceName: String, body: String, textColumns: Int,
                               change: (inout PDFPageHeader) -> Void) -> DateEvidenceRewrite {
        guard let doc = PDFDocument(data: pdf), !doc.isLocked else { return .skipped("not readable") }
        if PDFPageRole.roles(of: doc).contains(.searchable) {
            return searchableHeaderRewrite(doc, original: pdf, sourceName: sourceName, body: body, change: change)
        }
        guard doc.pageCount == 2, let image = doc.page(at: 0), let text = doc.page(at: 1) else {
            return .skipped("not one image page and one text page")
        }
        let parsed = PDFHeaderParser.parse(text)
        guard let old = parsed.header, let provenance = old.rawProvenance, old.provenance != nil,
              old.diagnostics.allSatisfy({ $0 == .missingKind }) else { return .skipped("the header does not parse cleanly") }
        var expected = old
        change(&expected)
        if expected == old { return .unchanged }
        guard Self.squashed(parsed.body) == Self.squashed(body) else { return .skipped("the page's text is not this run's") }
        guard Self.namesSource(old, sourceName) else { return .skipped("the name line does not read back as the source's name") }

        let (header, fit) = Self.headerText(expected, name: sourceName, provenance: provenance)
        let page = layoutTextPage(headerLine: header + "\n\n", fitRanges: fit, bodyText: body, textColumns: textColumns)

        let out = PDFDocument()
        out.insert(image, at: 0)
        out.insert(page, at: 1)
        // Written as `generate` writes the pair (PDF/A, the unwritten object freed), not `dataRepresentation`, whose
        // xref lists an object at offset 0.
        guard let data = Self.archivalData(out) else { return .skipped("the new page was not made") }
        // It must read back as the old page did, with only the changed lines changed.
        guard let made = PDFDocument(data: data), made.pageCount == 2, let madeImage = made.page(at: 0),
              let madeText = made.page(at: 1) else {
            return .skipped("the new file does not read back")
        }
        // The image page is the one PDFKit copies in a merge too; it must keep its size, turn and any text.
        guard madeImage.bounds(for: .mediaBox) == image.bounds(for: .mediaBox), madeImage.rotation == image.rotation,
              (madeImage.string ?? "") == (image.string ?? "") else {
            return .skipped("the image page does not read back")
        }
        // The name line reads back as the old one did: PDFKit cannot tell a U+00A0 from a space, so this checks the
        // layout, and the name's characters are the source's because `headerText` writes them from it.
        let back = PDFHeaderParser.parse(madeText)
        guard back.header == expected, Self.squashed(back.body) == Self.squashed(body) else {
            return .skipped("the new header does not read back as the old one")
        }
        return .rewrite(data)
    }

    /// Whether `old`'s name line is `sourceName`'s, as PDFKit reads it: a wrapped name comes back as several lines, and
    /// a U+00A0 as a space, so the two are compared without their white space.
    private static func namesSource(_ old: PDFPageHeader, _ sourceName: String) -> Bool {
        guard let name = old.originalFilename else { return false }
        return squashed(name) == squashed(headerFileName(sourceName))
    }

    /// `old`'s header lines, its name line `name` as `generate` writes it, and the lines fitted to one line each.
    private static func headerText(_ old: PDFPageHeader, name: String, provenance: String) -> (String, [NSRange]) {
        var header = "Extracted text.\n" + headerFileName(name)
        var fit = [NSRange(location: header.utf16.count + 1, length: provenance.utf16.count)]
        header += "\n" + provenance
        if let c = old.classification { header += "\nClassification: " + c }
        if let k = old.kind { header += "\n" + PDFHeaderParser.kindPrefix + k.rawValue }
        let dates = PDFSourceDates(documentDate: old.documentDate, sentWith: old.sentWith, dateEvidence: old.dateEvidence,
                                   itemFields: old.itemFields)
        for line in dates.headerLines {
            if PDFSourceDates.isFitted(line) {
                fit.append(NSRange(location: header.utf16.count + 1, length: line.utf16.count))
            }
            header += "\n" + line
        }
        if let degrees = old.straightenedDegrees, let line = PDFHeaderParser.straighteningLine(degrees: degrees) {
            header += "\n" + line
        }
        return (header, fit)
    }

    /// The searchable form's rewrite: one page, its header in the XMP. The page is copied as it is (or, without qpdf,
    /// drawn again unchanged), so it must read back with the same size, turn and text; the header must read back as the old one with only `change` applied.
    private func searchableHeaderRewrite(_ doc: PDFDocument, original: Data, sourceName: String, body: String,
                                         change: (inout PDFPageHeader) -> Void) -> DateEvidenceRewrite {
        guard doc.pageCount == 1, let page = doc.page(at: 0),
              let carried = doc.documentRef.flatMap(PDFHeaderCarrier.pages(of:)), carried.count == 1,
              let oldText = carried[0] else { return .skipped("not one searchable page") }
        let parsed = PDFHeaderParser.parse(oldText)
        guard let old = parsed.header, let provenance = old.rawProvenance, old.provenance != nil, parsed.body.isEmpty,
              old.diagnostics.allSatisfy({ $0 == .missingKind }) else { return .skipped("the header does not parse cleanly") }
        var changed = old
        change(&changed)
        if changed == old { return .unchanged }
        // The page is not laid out again, but the line must be about this run's reading: a searchable page's layer holds
        // every word of it (`searchableImagePage`).
        guard OutputForm.holds(page.string ?? "", every: body) else { return .skipped("the page's text is not this run's") }
        guard Self.namesSource(old, sourceName) else { return .skipped("the name line does not read back as the source's name") }
        let header = Self.headerText(changed, name: sourceName, provenance: provenance).0
        guard let data = Self.searchableRewrite(doc, original: original, pageHeaders: [header]),
              let made = PDFDocument(data: data), made.pageCount == 1, let madePage = made.page(at: 0) else {
            return .skipped("the new file does not read back")
        }
        guard madePage.bounds(for: .mediaBox) == page.bounds(for: .mediaBox), madePage.rotation == page.rotation,
              Self.squashed(madePage.string ?? "") == Self.squashed(page.string ?? "") else {
            return .skipped("the page does not read back")
        }
        // The XMP keeps the header's characters, so here the name reads back exactly.
        var expected = changed
        expected.originalFilename = Self.headerFileName(sourceName)
        guard let back = made.documentRef.flatMap(PDFHeaderCarrier.pages(of:)), back.count == 1,
              let backText = back[0], PDFHeaderParser.parse(backText).header == expected else {
            return .skipped("the new header does not read back as the old one")
        }
        return .rewrite(data)
    }

    /// W42.int-s5-compress: the page copied out of `original` (the file's bytes) as it is, with the new header
    /// (`SearchableArchival`), so a compressed page is not redrawn and re-encoded; through Quartz where qpdf is missing
    /// or fails.
    private static func searchableRewrite(_ doc: PDFDocument, original pdf: Data, pageHeaders: [String?]) -> Data? {
        guard !Task.isCancelled else { return nil }
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("ap-evidence-" + UUID().uuidString + ".pdf")
        defer { try? fm.removeItem(at: url) }
        do {
            guard SearchableArchival.isAvailable else { throw SearchableArchival.Failure.noQPDF }
            try pdf.write(to: url)
            return try SearchableArchival.data([url], pageHeaders: pageHeaders)
        } catch {
            guard !Task.isCancelled else { return nil }
            NSLog("ArchiveProcessor: searchable header rewrite through qpdf failed (%@); rewriting through Quartz",
                  error.localizedDescription)
        }
        return archivalData(doc, pageHeaders: pageHeaders)
    }

    /// Text with every white space removed: PDFKit's read-back changes line breaks and spacing, never the characters.
    static func squashed(_ s: String) -> String {
        String(s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }
}
