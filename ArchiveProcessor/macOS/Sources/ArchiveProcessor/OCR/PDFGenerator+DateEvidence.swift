import Foundation
import PDFKit
import ArchiveCore

/// A review that changes a page's class after it was rendered rewrites the `Classification:` line, keeping the image page
/// and the rest of the text page. Dates and item fields are catalogue facts (SPEC/catalogue-fields.md): no step adds them
/// to a generated header after rendering (W49.storage-drop-dead-copies). Lines an older file already carries are kept.
extension PDFGenerator {
    enum DateEvidenceRewrite: Equatable {
        /// The new file's bytes, verified to read back with every other header line and the body unchanged.
        case rewrite(Data)
        /// The page already carries the requested fields.
        case unchanged
        /// The output could not be safely rewritten.
        case skipped(String)
    }

    /// W40.fix-processor-review-classification-stale — the bytes `pdf` should have so its text page's
    /// `Classification:` line reads `classification` (a `DocumentClassification.displayName`; nil removes the line).
    /// Each page is rendered with the reader's proposal, and a review that changes the class afterwards must reach the
    /// header too, which SPEC §2-page PDF structure makes the value consumers read. Same checks as the evidence line.
    func classificationRewrite(of pdf: Data, sourceName: String, classification: String?, body: String,
                               textColumns: Int) -> DateEvidenceRewrite {
        headerRewrite(of: pdf, sourceName: sourceName, body: body, textColumns: textColumns,
                      allowMerged: true) {
            $0.classification = classification
        }
    }

    /// Change one source's header, then check that every other page and header reads back as before.
    private func headerRewrite(of pdf: Data, sourceName: String, body: String, textColumns: Int,
                               allowMerged: Bool = false, change: (inout PDFPageHeader) -> Void) -> DateEvidenceRewrite {
        guard let doc = PDFDocument(data: pdf), !doc.isLocked else { return .skipped("not readable") }
        let carried = doc.documentRef.flatMap(PDFHeaderCarrier.pages(of:))
        guard carried == nil || carried?.count == doc.pageCount else { return .skipped("the header list does not fit") }
        // An unfiled working PDF carries its catalogue identity from its write (W49.proc-identity-at-write): kept.
        let identity = doc.documentRef.flatMap(CataloguePDFIdentity.identity(in:))
        let roles = PDFPageRole.roles(of: doc)
        guard allowMerged || roles == [.image, .text] || roles == [.searchable] else {
            return .skipped("not one source page")
        }

        // Merged files may mix pairs and searchable pages. A searchable layer's word check can
        // match a superset of the reading, so require a unique name before checking the body.
        var match: (index: Int, parsed: ParsedPDFTextPage)?
        for (index, role) in roles.enumerated() where role != .image {
            guard let page = doc.page(at: index) else { return .skipped("a page is missing") }
            let parsed = role == .searchable ? carried?[index].map(PDFHeaderParser.parse) : PDFHeaderParser.parse(page)
            guard let parsed, let old = parsed.header, Self.namesSource(old, sourceName) else { continue }
            guard match == nil else { return .skipped("more than one page matches the source name") }
            match = (index, parsed)
        }
        guard let (index, parsed) = match, let old = parsed.header, let page = doc.page(at: index) else {
            return .skipped("no header matches the source name")
        }
        guard let provenance = old.rawProvenance, old.provenance != nil,
              old.diagnostics.allSatisfy({ $0 == .missingKind }) else {
            return .skipped("the header does not parse cleanly")
        }
        let searchable = roles[index] == .searchable
        let bodyKey = Self.squashed(body)
        let matchesReading = searchable
            ? parsed.body.isEmpty && OutputForm.holds(page.string ?? "", every: body)
            : Self.squashed(parsed.body) == bodyKey
        guard matchesReading else { return .skipped("the page's text is not this run's") }

        var expected = old
        change(&expected)
        if expected == old { return .unchanged }

        let (header, fit) = Self.headerText(expected, name: sourceName, provenance: provenance)
        var newHeaders = carried
        let replacement: PDFPage?
        if searchable {
            newHeaders?[index] = header
            expected.originalFilename = Self.headerFileName(sourceName)
            replacement = nil
        } else {
            replacement = layoutTextPage(headerLine: header + "\n\n", fitRanges: fit,
                                         bodyText: body, textColumns: textColumns)
        }

        let data: Data?
        if let newHeaders {
            data = Self.searchableRewrite(doc, original: pdf, pageHeaders: newHeaders,
                                          replacing: replacement.map { (index, $0) }, catalogueIdentity: identity)
        } else {
            guard let replacement, let out = Self.withReplacement(in: doc, at: index, page: replacement) else {
                return .skipped("the original pages could not be copied")
            }
            data = Self.archivalData(out, catalogueIdentity: identity)
        }
        guard let data, let made = PDFDocument(data: data), made.pageCount == doc.pageCount,
              made.documentRef.flatMap(PDFHeaderCarrier.pages(of:)) == newHeaders,
              made.documentRef.flatMap(CataloguePDFIdentity.identity(in:)) == identity else {
            return .skipped("the new file does not read back")
        }

        for offset in roles.indices where searchable || offset != index {
            guard let before = doc.page(at: offset), let after = made.page(at: offset),
                  before.pageRef != nil, after.pageRef != nil,
                  after.bounds(for: .mediaBox) == before.bounds(for: .mediaBox), after.rotation == before.rotation,
                  Self.squashed(after.string ?? "") == Self.squashed(before.string ?? "") else {
                return .skipped("an unchanged page does not read back")
            }
        }
        let readBack = searchable ? newHeaders?[index].map(PDFHeaderParser.parse)
            : made.page(at: index).map(PDFHeaderParser.parse)
        guard let readBack, readBack.header == expected,
              Self.squashed(readBack.body) == (searchable ? "" : bodyKey) else {
            return .skipped("the new header does not read back as expected")
        }
        return .rewrite(data)
    }

    /// Use a separate document so the original remains available for the read-back checks.
    private static func withReplacement(in doc: PDFDocument, at index: Int, page: PDFPage) -> PDFDocument? {
        let out = PDFDocument()
        for offset in 0..<doc.pageCount {
            guard let copy = offset == index ? page : doc.page(at: offset)?.copy() as? PDFPage,
                  copy.pageRef != nil else { return nil }
            out.insert(copy, at: out.pageCount)
        }
        return out
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

    /// Use qpdf to keep the searchable pages' compressed streams. Quartz is the fallback used by merge.
    private static func searchableRewrite(_ doc: PDFDocument, original pdf: Data, pageHeaders: [String?],
                                          replacing: (index: Int, page: PDFPage)?,
                                          catalogueIdentity: CataloguePDFIdentity?) -> Data? {
        guard !Task.isCancelled else { return nil }
        let fm = FileManager.default
        do {
            guard SearchableArchival.isAvailable else { throw SearchableArchival.Failure.noQPDF }
            let dir = try stagingDirectory(in: fm.temporaryDirectory)
            defer { try? fm.removeItem(at: dir) }
            let url = dir.appendingPathComponent("original.pdf")
            try pdf.write(to: url, options: .withoutOverwriting)
            if let replacing {
                let replacement = PDFDocument()
                replacement.insert(replacing.page, at: 0)
                guard let newBytes = archivalData(replacement) else { throw PDFError.writeFailed }
                let newPage = dir.appendingPathComponent("page.pdf")
                try newBytes.write(to: newPage, options: .withoutOverwriting)
                return try SearchableArchival.data([url], pageHeaders: pageHeaders, catalogueIdentity: catalogueIdentity,
                                                   replacing: (replacing.index, newPage))
            }
            return try SearchableArchival.data([url], pageHeaders: pageHeaders, catalogueIdentity: catalogueIdentity)
        } catch {
            guard !Task.isCancelled else { return nil }
            NSLog("ArchiveProcessor: searchable header rewrite through qpdf failed (%@); rewriting through Quartz",
                  error.localizedDescription)
        }
        if let replacing {
            guard let out = withReplacement(in: doc, at: replacing.index, page: replacing.page) else { return nil }
            return archivalData(out, pageHeaders: pageHeaders, catalogueIdentity: catalogueIdentity)
        }
        guard (0..<doc.pageCount).allSatisfy({ doc.page(at: $0)?.pageRef != nil }) else { return nil }
        return archivalData(doc, pageHeaders: pageHeaders, catalogueIdentity: catalogueIdentity)
    }

    /// Text with every white space removed: PDFKit's read-back changes line breaks and spacing, never the characters.
    static func squashed(_ s: String) -> String {
        String(s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }
}
