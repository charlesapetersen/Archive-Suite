import XCTest
@testable import ArchiveCore

/// W40.d11 — the shared contract on real Processor output: the parsers the Reader and Notes read through
/// (`TagReading.readTags`, `PDFHeaderParser.extract`) must give back what the Processor wrote.
///
/// "What it wrote" is stated without these parsers: `ops/verify/cross_app_contract.py expect` decodes each PDF's
/// tag xattr with plistlib and sorts it by the SPEC's grammar, and reads page 2 with pypdf. This test reads the
/// same files through ArchiveCore and compares. Real Processor output is corpus-derived, so it is never committed:
/// the test runs only when `ARCHIVE_CONTRACT_DIR` names a folder holding the PDFs and `ARCHIVE_CONTRACT_EXPECTED`
/// the JSON (`ops/verify/cross-app-contract.sh` sets both), and is skipped otherwise.
final class ProcessorOutputContractTests: XCTestCase {

    private struct Expected: Decodable {
        let count: Int
        let errors: [String]
        let files: [String: File]
        struct File: Decodable {
            let tags: [String]
            let colours: [Int]
            let facets: Facets
            let classification: String?
            let header: [String: String?]
            let pages: Int
        }
        struct Facets: Decodable {
            let year: Int?, month: Int?, day: Int?, decade: Int?, quality: Int?
            let dateUncertain: Bool
            let readState: String?, itemType: String?, sentWith: String?
            let subjects: [String]
        }
    }

    /// PDFKit reads a U+00A0 back as an ordinary space (W40.fix-processor-evidence-rewrite-name, measured), and
    /// pypdf keeps it, so a name read through the two is compared with that one difference set aside.
    private func spaced(_ s: String?) -> String? { s?.replacingOccurrences(of: "\u{00A0}", with: " ") }

    func testProcessorOutputReadsAsWritten() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["ARCHIVE_CONTRACT_DIR"], let json = env["ARCHIVE_CONTRACT_EXPECTED"] else {
            throw XCTSkip("set ARCHIVE_CONTRACT_DIR and ARCHIVE_CONTRACT_EXPECTED (ops/verify/cross-app-contract.sh)")
        }
        let expected = try JSONDecoder().decode(Expected.self, from: Data(contentsOf: URL(fileURLWithPath: json)))
        XCTAssertEqual(expected.errors, [], "the expectation itself reported errors")
        XCTAssertGreaterThan(expected.files.count, 0)
        let folder = URL(fileURLWithPath: dir, isDirectory: true)
        var checked = 0, classified = 0, dated = 0
        for (name, want) in expected.files.sorted(by: { $0.key < $1.key }) {
            let url = folder.appendingPathComponent(name)
            let tags = try XCTUnwrap(TagReading.readTags(url), "\(name): the tags should be readable")
            // The tag array itself, verbatim and in order.
            XCTAssertEqual(tags.raw, want.tags, "\(name): raw tags")
            XCTAssertEqual(tags.labelNumber ?? 0, want.colours.last ?? 0, "\(name): colour label")
            // Every facet the SPEC's grammar gives.
            let f = want.facets
            XCTAssertEqual(tags.year, f.year, "\(name): year")
            XCTAssertEqual(tags.month?.number, f.month, "\(name): month")
            XCTAssertEqual(tags.day, f.day, "\(name): day")
            XCTAssertEqual(tags.decade, f.decade, "\(name): decade")
            XCTAssertEqual(tags.dateUncertain, f.dateUncertain, "\(name): Date Uncertain")
            XCTAssertEqual(tags.quality, f.quality, "\(name): quality")
            XCTAssertEqual(tags.readState?.rawValue, f.readState, "\(name): read state")
            XCTAssertEqual(tags.itemType?.rawValue, f.itemType, "\(name): item type")
            XCTAssertEqual(tags.itemTypeToken, f.itemType, "\(name): the item type is the token, not a colour")
            XCTAssertEqual(tags.sentWith?.wireValue, f.sentWith, "\(name): sent with")
            XCTAssertEqual(tags.subjects, f.subjects, "\(name): subjects")
            XCTAssertTrue(tags.dateAmbiguities.isEmpty, "\(name): no date facet is written twice")

            // Page 2's header, through the parser the Reader's index and viewer use.
            let content = try XCTUnwrap(PDFHeaderParser.extract(url), "\(name): the PDF should open")
            XCTAssertEqual(content.pageCount, want.pages, "\(name): pages")
            XCTAssertEqual(content.classification, want.classification, "\(name): classification")
            let header = try XCTUnwrap(content.textPages.first?.header, "\(name): page 2 should have a header")
            let h = want.header
            XCTAssertEqual(spaced(header.originalFilename), spaced(h["originalFilename"] ?? nil), "\(name): source name")
            XCTAssertEqual(header.rawProvenance, h["provenance"] ?? nil, "\(name): provenance line")
            XCTAssertNotNil(header.provenance, "\(name): the provenance line should be well formed")
            // A page with no Kind line reads as unknown with that diagnosis (SPEC, "Kind"); nothing else is diagnosed.
            XCTAssertEqual(header.diagnostics, (h["Kind"] ?? nil) == nil ? [.missingKind] : [],
                           "\(name): header diagnostics")
            XCTAssertEqual(header.kind?.rawValue, h["Kind"] ?? nil, "\(name): Kind")
            XCTAssertEqual(header.documentDate, h["Document date"] ?? nil, "\(name): Document date")
            XCTAssertEqual(header.sentWith, h["Sent with"] ?? nil, "\(name): Sent with")
            XCTAssertEqual(header.dateEvidence, h["Date evidence"] ?? nil, "\(name): Date evidence")
            let fields = header.itemFields
            XCTAssertEqual(fields.documentKind, h["Document kind"] ?? nil, "\(name): Document kind")
            XCTAssertEqual(fields.title, h["Title"] ?? nil, "\(name): Title")
            XCTAssertEqual(fields.byline, h["Byline"] ?? nil, "\(name): Byline")
            XCTAssertEqual(fields.publication, h["Publication"] ?? nil, "\(name): Publication")
            XCTAssertEqual(fields.publicationDate, h["Publication date"] ?? nil, "\(name): Publication date")
            XCTAssertEqual(fields.recipientPlace, h["Recipient place"] ?? nil, "\(name): Recipient place")
            checked += 1
            if want.classification != nil { classified += 1 }
            if f.year != nil || f.decade != nil { dated += 1 }
        }
        print("[d11] ArchiveCore read \(checked) Processor PDFs as written: \(classified) with a classification, "
              + "\(dated) dated")
    }
}
