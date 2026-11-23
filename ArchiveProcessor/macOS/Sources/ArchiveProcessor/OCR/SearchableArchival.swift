import ArchiveCore
import CoreGraphics
import Foundation
import PDFKit
import VisionOCRKit

/// W42.int-s5-compress — a PDF/A-2b file made from finished pages without drawing them again, for the searchable
/// form's compressed page (`CompressedPage`): Quartz's PDF/A writer redraws every page
/// and re-encodes its JBIG2 images, which undoes the compression. qpdf copies the pages as they are (`--empty
/// --pages`), and its JSON update gives the catalog what PDF/A-2b asks of it: the XMP (`pdfaid` part 2, conformance
/// B, the header list, `PDFHeaderCarrier`), stored unfiltered as `ArchivalFinish` stores Quartz's; an sRGB output
/// intent; and the trailer `/ID` qpdf writes. `--newline-before-endstream` is PDF/A's stream rule (6.1.7.1). The
/// document info dictionary is dropped (`--empty`), so it cannot disagree with the XMP.
/// Used for a new searchable output, a merge with searchable pages and the date-evidence rewrite of one; Quartz stays
/// the writer where qpdf is missing (the pages then are not compressed either) and for files of pairs only.
enum SearchableArchival {
    enum Failure: LocalizedError {
        case noQPDF
        case qpdf(String)
        case check(String)

        var errorDescription: String? {
            switch self {
            case .noQPDF: return "qpdf not found"
            case .qpdf(let why): return "qpdf: " + why
            case .check(let why): return why
            }
        }
    }

    /// Whether this Mac can write it.
    static var isAvailable: Bool { CompressedPage.qpdf != nil }

    /// Prepare a new derivative of a pre-OCRed PDF. Only the catalogue identity is added. The
    /// selected input stays untouched, and the candidate must preserve every active page and its
    /// rendering, document information, catalog and existing XMP before it can become a working PDF.
    static func catalogueCopy(of source: URL, identity: CataloguePDFIdentity) throws -> Data {
        guard let qpdf = CompressedPage.qpdf else { throw Failure.noQPDF }
        let original = try Data(contentsOf: source)
        try ReOCRIncrementalWriter.eligibility(of: original).get()
        guard let originalDoc = ReOCRPreservationCheck.document(original), originalDoc.numberOfPages > 0,
              let catalog = originalDoc.catalog else { throw PDFError.sourceUnreadable(source) }
        let packet: Data
        if CGPDFDictionaryGetObject(catalog, "Metadata", nil) {
            guard let existing = ReOCRPreservationCheck.metadata(of: originalDoc, requireKnownStreamKeys: true) else {
                throw Failure.check("the source metadata could not be read")
            }
            packet = existing
        } else {
            packet = Data("""
                <x:xmpmeta xmlns:x="adobe:ns:meta/">
                <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                </rdf:RDF></x:xmpmeta>
                """.utf8)
        }
        guard let xmp = identity.adding(to: packet) else {
            throw Failure.check("the source metadata could not safely carry a new identity")
        }

        let budget = PDFChildBudget(seconds: PDFChildBudget.secondsPerPage * Double(originalDoc.numberOfPages))
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ap-catalogue-copy-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: dir) }
        let input = dir.appendingPathComponent("original.pdf")
        let patch = dir.appendingPathComponent("catalogue.json")
        let output = dir.appendingPathComponent("derivative.pdf")
        try original.write(to: input, options: .withoutOverwriting)
        let shape = try jsonShape(qpdf, input, budget: budget, allowWarnings: false)
        var newCatalog = shape.catalog
        let metadataObject = "\(shape.maxObject + 1) 0 R"
        newCatalog["/Metadata"] = metadataObject
        let update: [String: Any] = ["qpdf": [
            ["jsonversion": 2, "pushedinheritedpageresources": false, "calledgetallpages": false,
             "maxobjectid": shape.maxObject + 1],
            [
                "obj:\(shape.root)": ["value": newCatalog],
                "obj:\(metadataObject)": ["stream": [
                    "dict": ["/Type": "/Metadata", "/Subtype": "/XML"],
                    "data": xmp.base64EncodedString()
                ]]
            ]
        ]]
        try JSONSerialization.data(withJSONObject: update, options: .withoutEscapingSlashes).write(to: patch)
        try run(qpdf, [input.path, "--update-from-json=" + patch.path, "--stream-data=preserve",
                       "--newline-before-endstream", output.path], budget: budget, allowWarnings: false)
        let candidate = try Data(contentsOf: output)
        let problems = ReOCRPreservationCheck.problems(original: original, candidate: candidate, replacing: [],
                                                       requiresOriginalPrefix: false, catalogueMetadata: xmp)
        guard problems.isEmpty, let written = ReOCRPreservationCheck.document(candidate),
              CataloguePDFIdentity.identity(in: written) == identity else {
            throw Failure.check(problems.first ?? "the copied catalogue identity could not be verified")
        }
        try budget.check()
        return candidate
    }

    /// `sources`' pages in order as one PDF/A-2b file at `url`, written atomically. `pageHeaders`: one entry per page
    /// of the result (`PDFHeaderCarrier`), nil for a pair's page.
    static func write(_ sources: [URL], pageHeaders: [String?], to url: URL, budget: PDFChildBudget,
                      catalogueIdentity: CataloguePDFIdentity? = nil) throws {
        let dir = try PDFGenerator.stagingDirectory(in: url.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: dir) }
        let candidate = try prepare(sources, pageHeaders: pageHeaders, in: dir, budget: budget,
                                    catalogueIdentity: catalogueIdentity)
        try budget.check()
        try PDFGenerator.installArchival(candidate, at: url)
    }

    /// The bounded header-edit API still returns bytes.
    static func data(_ sources: [URL], pageHeaders: [String?], budget: PDFChildBudget? = nil,
                     catalogueIdentity: CataloguePDFIdentity? = nil) throws -> Data {
        let budget = budget ?? PDFChildBudget(seconds: PDFChildBudget.secondsPerPage * Double(max(1, pageHeaders.count)))
        let dir = try PDFGenerator.stagingDirectory(in: FileManager.default.temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let candidate = try prepare(sources, pageHeaders: pageHeaders, in: dir, budget: budget,
                                    catalogueIdentity: catalogueIdentity)
        try budget.check()
        return try Data(contentsOf: candidate)
    }

    private static func prepare(_ sources: [URL], pageHeaders: [String?], in dir: URL, budget: PDFChildBudget,
                                catalogueIdentity: CataloguePDFIdentity?) throws -> URL {
        try budget.check()
        guard let qpdf = CompressedPage.qpdf else { throw Failure.noQPDF }
        guard !sources.isEmpty, !pageHeaders.isEmpty else { throw PDFError.writeFailed }

        let merged = dir.appendingPathComponent("merged.pdf"), patch = dir.appendingPathComponent("patch.json")
        let out = dir.appendingPathComponent("out.pdf")

        try run(qpdf, ["--empty", "--pages"] + sources.map(\.path) + ["--", merged.path], budget: budget)
        let shape = try jsonShape(qpdf, merged, budget: budget)
        guard let xmp = metadata(pageHeaders: pageHeaders, catalogueIdentity: catalogueIdentity),
              let icc = CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData() as Data? else {
            throw Failure.check("the metadata could not be made")
        }
        let m = shape.maxObject
        var catalog = shape.catalog
        catalog["/Metadata"] = "\(m + 1) 0 R"
        catalog["/OutputIntents"] = ["\(m + 2) 0 R"]
        let update: [String: Any] = ["qpdf": [
            ["jsonversion": 2, "pushedinheritedpageresources": false, "calledgetallpages": false, "maxobjectid": m + 3],
            [
                "obj:\(shape.root)": ["value": catalog],
                "obj:\(m + 1) 0 R": ["stream": ["dict": ["/Type": "/Metadata", "/Subtype": "/XML"],
                                                "data": xmp.base64EncodedString()]],
                "obj:\(m + 2) 0 R": ["value": ["/Type": "/OutputIntent", "/S": "/GTS_PDFA1",
                                               "/OutputConditionIdentifier": "u:sRGB IEC61966-2.1",
                                               "/Info": "u:sRGB IEC61966-2.1", "/DestOutputProfile": "\(m + 3) 0 R"]],
                "obj:\(m + 3) 0 R": ["stream": ["dict": ["/N": 3], "data": icc.base64EncodedString()]],
            ],
        ]]
        // Slashes unescaped: qpdf reads "\/" in a stream's base64 as invalid input.
        try JSONSerialization.data(withJSONObject: update, options: .withoutEscapingSlashes).write(to: patch)
        try run(qpdf, [merged.path, "--update-from-json=" + patch.path, "--newline-before-endstream", out.path], budget: budget)

        try check(out, against: sources, pageHeaders: pageHeaders, xmp: xmp, catalogueIdentity: catalogueIdentity,
                  budget: budget)
        return out
    }

    /// The result opens with every page in order, each with its source's size, turn and text, its XMP as written
    /// (unfiltered, so PDFium's rewrite in an Improve OCR revision keeps it) and the header list as given.
    private static func check(_ url: URL, against sources: [URL], pageHeaders: [String?], xmp: Data,
                              catalogueIdentity: CataloguePDFIdentity?, budget: PDFChildBudget) throws {
        guard let made = PDFDocument(url: url), let ref = made.documentRef else { throw Failure.check("the file does not open") }
        guard made.pageCount == pageHeaders.count else { throw Failure.check("the header list does not fit the pages") }
        var index = 0
        for source in sources {
            try autoreleasepool {
                guard let doc = PDFDocument(url: source), !doc.isLocked else { throw PDFError.sourceUnreadable(source) }
                for i in 0..<doc.pageCount {
                    try budget.check()
                    try autoreleasepool {
                        guard let page = doc.page(at: i), index < made.pageCount, let p = made.page(at: index),
                              p.bounds(for: .mediaBox) == page.bounds(for: .mediaBox), p.rotation == page.rotation,
                              (p.string ?? "") == (page.string ?? "") else {
                            throw Failure.check("page \(index + 1) does not read back as it was")
                        }
                        index += 1
                    }
                }
            }
        }
        guard made.pageCount == index else { throw Failure.check("the file does not have every page") }
        var stream: CGPDFStreamRef?
        var format = CGPDFDataFormat.raw
        guard let catalog = ref.catalog, CGPDFDictionaryGetStream(catalog, "Metadata", &stream), let stream,
              let dict = CGPDFStreamGetDictionary(stream), !CGPDFDictionaryGetObject(dict, "Filter", nil),
              CGPDFStreamCopyData(stream, &format) as Data? == xmp, format == .raw else {
            throw Failure.check("the XMP does not read back as written")
        }
        let wanted = pageHeaders.map { $0.flatMap { $0.isEmpty ? nil : $0 } }
        if wanted.contains(where: { $0 != nil }), PDFHeaderCarrier.pages(of: ref) != wanted {
            throw Failure.check("the headers do not read back")
        }
        if let catalogueIdentity, CataloguePDFIdentity.identity(in: ref) != catalogueIdentity {
            throw Failure.check("the catalogue identity does not read back")
        }
    }

    /// The XMP packet: PDF/A-2b's identification, the tool and the time, and the header list when a page has one.
    static func metadata(pageHeaders: [String?], date: Date = Date(),
                         catalogueIdentity: CataloguePDFIdentity? = nil) -> Data? {
        let stamp = ISO8601DateFormatter.string(from: date, timeZone: .current,
                                                formatOptions: [.withInternetDateTime])
        let base = """
            <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
            <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/">
            <pdfaid:part>2</pdfaid:part>
            <pdfaid:conformance>B</pdfaid:conformance>
            </rdf:Description>
            <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/">
            <xmp:CreatorTool>Archive Processor</xmp:CreatorTool>
            <xmp:CreateDate>\(stamp)</xmp:CreateDate>
            <xmp:ModifyDate>\(stamp)</xmp:ModifyDate>
            </rdf:Description>
            </rdf:RDF>
            </x:xmpmeta>
            <?xpacket end="w"?>
            """
        var packet = Data(base.utf8)
        if pageHeaders.contains(where: { $0?.isEmpty == false }) {
            guard let withHeaders = PDFHeaderCarrier.adding(pages: pageHeaders, to: packet) else { return nil }
            packet = withHeaders
        }
        if let catalogueIdentity { return catalogueIdentity.adding(to: packet) }
        return packet
    }

    /// The catalog's object, its dictionary and the highest object number, from qpdf's own JSON.
    private static func jsonShape(_ qpdf: URL, _ pdf: URL, budget: PDFChildBudget, allowWarnings: Bool = true)
        throws -> (root: String, catalog: [String: Any], maxObject: Int) {
        let json = try run(qpdf, ["--json=2", "--json-key=qpdf", pdf.path], budget: budget, allowWarnings: allowWarnings)
        guard let top = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let q = top["qpdf"] as? [Any], q.count == 2,
              let header = q[0] as? [String: Any], let maxObject = header["maxobjectid"] as? Int,
              let objects = q[1] as? [String: Any],
              let trailer = (objects["trailer"] as? [String: Any])?["value"] as? [String: Any],
              let root = trailer["/Root"] as? String,
              let catalog = (objects["obj:" + root] as? [String: Any])?["value"] as? [String: Any] else {
            throw Failure.qpdf("its JSON could not be read")
        }
        return (root, catalog, maxObject)
    }

    /// Runs qpdf; its output. Exit 3 is qpdf's "succeeded with warnings", which the read-back then judges.
    @discardableResult
    private static func run(_ qpdf: URL, _ arguments: [String], budget: PDFChildBudget, allowWarnings: Bool = true) throws -> Data {
        let process = Process()
        process.executableURL = qpdf
        process.arguments = arguments
        let (data, message) = try budget.capture(process)
        guard process.terminationReason == .exit,
              process.terminationStatus == 0 || (allowWarnings && process.terminationStatus == 3) else {
            let text = String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.qpdf(text.isEmpty ? "exit \(process.terminationStatus)" : String(text.prefix(300)))
        }
        return data
    }
}
