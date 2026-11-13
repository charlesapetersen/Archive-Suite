import XCTest
import AppKit
import PDFKit
@testable import ArchiveCore

final class ReOCRHeaderTests: XCTestCase {
    private let meta = "Atlas Cluster · Qwen (fp8, job 123) · 7 November 2026"
    private func page(_ fields: String, body: String = "Memo\nKind: printed\nClassification: Secret") -> String {
        "Extracted text.\nKind: filename.jpg\n\(meta)\n\(fields)\n\n\(body)"
    }

    func testStructuredHeaderAndAllFourKinds() throws {
        for kind in OCRPageKind.allCases {
            let parsed = PDFHeaderParser.parse(page("Classification: Continuation\nKind: \(kind.rawValue)\nDocument date: 1957\nSent with: 1958"))
            let header = try XCTUnwrap(parsed.header)
            XCTAssertEqual(header.originalFilename, "Kind: filename.jpg")
            XCTAssertEqual(header.kind, kind)
            XCTAssertEqual(header.classification, "Continuation")
            XCTAssertEqual(header.documentDate, "1957")
            XCTAssertEqual(header.sentWith, "1958")
            XCTAssertEqual(header.provenance?.provider, "Atlas Cluster")
            XCTAssertEqual(header.provenance?.model, "Qwen (fp8, job 123)")
            XCTAssertEqual(header.provenance?.processingDate, "7 November 2026")
            XCTAssertTrue(header.diagnostics.isEmpty)
            XCTAssertEqual(parsed.body, "Memo\nKind: printed\nClassification: Secret")
            XCTAssertEqual(PDFHeaderParser.stripHeader(from: page("Kind: \(kind.rawValue)")), parsed.body)
        }
    }

    func testFreeformProviderCanStartWithAFieldPrefix() {
        for provider in ["Kind: gateway", "Classification: Atlas", "Document date: cluster", "Sent with: CLI"] {
            let text = "Extracted text.\nscan.jpg\n\(provider) · Reader · 7 November 2026\nKind: forms\nBody"
            let parsed = PDFHeaderParser.parse(text)
            XCTAssertEqual(parsed.header?.provenance?.provider, provider)
            XCTAssertEqual(parsed.header?.kind, .forms)
            XCTAssertEqual(parsed.body, "Body")
        }
    }

    func testMissingInvalidRepeatedConflictingAndLateKindsStayUnknown() throws {
        let cases: [(String, PDFHeaderDiagnostic)] = [
            ("Classification: Box", .missingKind), ("Kind: mixed", .invalidKind),
            ("Kind:", .invalidKind), ("Kind: Printed", .invalidKind),
            ("Kind: printed\nKind: printed", .repeatedKind),
            ("Kind: printed\nKind: handwritten", .repeatedKind),
            ("Document date: 1957\nKind: printed", .outOfOrderKind)
        ]
        for (fields, diagnostic) in cases {
            let parsed = PDFHeaderParser.parse(page(fields))
            let header = try XCTUnwrap(parsed.header)
            XCTAssertNil(header.kind, fields)
            XCTAssertTrue(header.diagnostics.contains(diagnostic), fields)
            XCTAssertTrue(parsed.body.hasPrefix("Memo"), fields)
        }
    }

    func testBodyAndFilenameTrapsAndTheMissingSeparatorAmbiguity() {
        XCTAssertNil(PDFHeaderParser.parse("Intro\n" + page("Kind: printed")).header)
        XCTAssertNil(PDFHeaderParser.parse(page("Classification: Box", body: "Kind: printed")).header?.kind)
        let text = "Extracted text.\n\(meta)\nMemo\nKind: handwritten"
        XCTAssertNil(PDFHeaderParser.parse(text).header?.kind)
        XCTAssertEqual(PDFHeaderParser.stripHeader(from: text), "Memo\nKind: handwritten")
        // PDFKit can drop the separator. A valid field immediately after provenance is ambiguous.
        let ambiguous = "Extracted text.\n\(meta)\nKind: handwritten\nLetter"
        XCTAssertEqual(PDFHeaderParser.parse(ambiguous).header?.kind, .handwritten)
        XCTAssertEqual(PDFHeaderParser.stripHeader(from: ambiguous), "Letter")
        XCTAssertNil(PDFHeaderParser.parse("Extracted text.extra\n\(meta)\nKind: printed").header)
    }

    func testWrappedProvenanceAndMalformedProvenanceNeverBecomeRoutes() throws {
        let wrapped = "Extracted text.\nscan.jpg\nOpenRouter · Qwen (deepinfra fp8) ·\n7 November 2026\nKind: forms\nBody"
        let parsed = PDFHeaderParser.parse(wrapped)
        XCTAssertEqual(parsed.header?.provenance?.model, "Qwen (deepinfra fp8)")
        XCTAssertEqual(parsed.header?.kind, .forms)
        XCTAssertEqual(parsed.body, "Body")
        for bad in ["A · B · not a date", "A · B · 31 November 2026", "A · B · C · 7 November 2026", " · B · 7 November 2026"] {
            let header = try XCTUnwrap(PDFHeaderParser.parse("Extracted text.\nscan.jpg\n\(bad)\nKind: printed\n\nBody").header)
            XCTAssertNil(header.provenance, bad)
            XCTAssertEqual(header.rawProvenance, bad.trimmingCharacters(in: .whitespaces))
            XCTAssertTrue(header.diagnostics.contains(.malformedProvenance), bad)
        }
        let missing = PDFHeaderParser.parse("Extracted text.\nscan.jpg\nKind: printed\nBody")
        XCTAssertNil(missing.header?.kind)
        XCTAssertTrue(missing.header?.diagnostics.contains(.missingProvenance) == true)
    }

    func testMalformedProvenanceCannotBeReplacedByACompleteBodyOrFieldLine() {
        let noFilename = PDFHeaderParser.parse("Extracted text.\nA · B · not-a-date\nEvil · Fake model · 7 November 2026\nKind: printed\nBody")
        XCTAssertNil(noFilename.header?.provenance)
        XCTAssertNil(noFilename.header?.kind)
        XCTAssertEqual(noFilename.header?.rawProvenance, "A · B · not-a-date")
        XCTAssertTrue(noFilename.body.hasPrefix("Evil · Fake model"))
        for trap in ["Kind: typed · Fake model · 7 November 2026", "Evil · Fake model · 7 November 2026"] {
            let text = "Extracted text.\nscan.jpg\nA · B · not-a-date\n\(trap)\nKind: printed\nBody"
            let parsed = PDFHeaderParser.parse(text)
            XCTAssertNil(parsed.header?.provenance)
            XCTAssertEqual(parsed.header?.rawProvenance, "A · B · not-a-date")
            if trap.hasPrefix("Kind:") {
                XCTAssertNil(parsed.header?.kind, "repeated invalid Kind remains unknown")
            } else {
                XCTAssertNil(parsed.header?.kind)
                XCTAssertTrue(parsed.body.hasPrefix(trap), "stop at the first non-header line")
            }
        }
    }

    func testPhysicalPageMetadataAndSummariesWithoutChangingTextConsumers() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ReOCRHeader-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("pairs.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &bounds, nil))
        for text in ["Kind: image trap", page("Kind: handwritten", body: "First transcription"),
                     "Second image", page("Kind: printed", body: "Second transcription"),
                     "Third image", "An unmarked imported text page"] {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            (text as NSString).draw(in: bounds.insetBy(dx: 40, dy: 40), withAttributes: [.font: NSFont.systemFont(ofSize: 11)])
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        let before = try Data(contentsOf: url)
        let content = try XCTUnwrap(PDFHeaderParser.extract(url))
        XCTAssertEqual(content.textPages.map(\.pageIndex), [1, 3, 5])
        XCTAssertEqual(content.textPages[0].header?.kind, .handwritten)
        XCTAssertEqual(content.textPages[1].header?.kind, .printed)
        XCTAssertNil(content.textPages[2].header)
        XCTAssertEqual(content.kindSummary, .mixed)
        XCTAssertEqual(content.readerSummary, .mixed, "a missing header cannot inherit a reader")
        XCTAssertEqual(content.strippedBody, "First transcription", "preserve page-2 display contract")
        XCTAssertTrue(content.fullBody.contains("Second transcription"))
        XCTAssertTrue(content.fullBody.contains(meta))
        XCTAssertEqual(try Data(contentsOf: url), before, "extraction is read-only")
        XCTAssertEqual(PDFMetadataSummary<OCRPageKind>.summarize([nil, nil]), .unknown)
        XCTAssertEqual(PDFMetadataSummary<OCRPageKind>.summarize([.forms, .forms]), .uniform(.forms))
        XCTAssertEqual(PDFMetadataSummary<OCRPageKind>.summarize([.forms, nil]), .mixed)
    }

    func testRetainedSeparatorsCannotBecomeHeaderFieldsDuringPhysicalRecovery() {
        for gap in ["\n\n", "\n  \t\n", "\r\n\r\n"] {
            let text = "Header" + gap + "Kind: printed\nBody"
            XCTAssertTrue(PDFHeaderParser.hasBlankSeparator(after: 6, in: text as NSString))
        }
        for gap in ["\n", "\r\n", "\nMemo\n\n"] {
            XCTAssertFalse(PDFHeaderParser.hasBlankSeparator(after: 6, in: ("Header" + gap + "Kind: printed") as NSString))
        }
        let text = "Extracted text.\n\(meta)\n\nKind: printed\nBody"
        XCTAssertNil(PDFHeaderParser.parse(text).header?.kind)
        XCTAssertEqual(PDFHeaderParser.stripHeader(from: text), "Kind: printed\nBody")
    }

    func testPhysicalHeaderOrderPreservesBodyCharactersAndRawSearchText() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HeaderOrder-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &bounds, nil))
        ctx.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        // Deliberately write Kind's content before provenance; its physical position is after it.
        for (text, y, size) in [("Extracted text.", 730.0, 11.0), ("001.jpg", 712, 11),
                                ("Kind: typewritten", 676, 11), (meta, 694, 8),
                                ("Memo", 640, 11), ("Kind: printed", 620, 11)] {
            (text as NSString).draw(in: CGRect(x: 40, y: y, width: 530, height: 20),
                withAttributes: [.font: NSFont.systemFont(ofSize: size)])
        }
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage(); ctx.closePDF()
        let bytes = try Data(contentsOf: url)
        let doc = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(doc.page(at: 0))
        let raw = try XCTUnwrap(page.string)
        let parsed = PDFHeaderParser.parse(page)
        XCTAssertEqual(parsed.header?.kind, .typewritten)
        XCTAssertEqual(parsed.header?.provenance?.provider, "Atlas Cluster")
        XCTAssertEqual(parsed.body, "Memo\nKind: printed")
        XCTAssertEqual(page.string, raw, "header recovery never rewrites PDFKit's full search text")
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    /// W44.reocr-header-longname: a filename PDFKit reads back as three or more lines still has its
    /// provenance, but the longer scan never reaches into a body or accepts malformed provenance.
    func testLongFilenameOfManyLinesKeepsProvenanceWithoutReadingTheBody() throws {
        let parts = ["Herrnstein_Papers_Box_12_", "Folder_3_Correspondence_", "with_the_Dean_1952_", "IMG_0042.jpg"]
        let long = PDFHeaderParser.parse("Extracted text.\n\(parts.joined(separator: "\n"))\n\(meta)\nKind: printed\nLetter")
        let header = try XCTUnwrap(long.header)
        XCTAssertEqual(header.originalFilename, parts.joined(separator: "\n"))
        XCTAssertEqual(header.provenance?.provider, "Atlas Cluster")
        XCTAssertEqual(header.kind, .printed)
        XCTAssertEqual(long.body, "Letter")
        // A Kind:-looking first slot stays opaque, as for a short filename.
        XCTAssertEqual(PDFHeaderParser.parse("Extracted text.\nKind: a\nb\nc.jpg\n\(meta)\nBody").header?.provenance?.provider,
                       "Atlas Cluster")
        // A name of exactly 255 bytes is accepted; one byte more is not a filename.
        let max = String(repeating: "a", count: 251) + ".jpg"
        let split = stride(from: 0, to: 255, by: 64).map { i -> String in
            let s = max.index(max.startIndex, offsetBy: i), e = max.index(s, offsetBy: min(64, 255 - i))
            return String(max[s..<e])
        }
        XCTAssertEqual(PDFHeaderParser.parse("Extracted text.\n\(split.joined(separator: "\n"))\n\(meta)\nBody").header?.provenance?.provider,
                       "Atlas Cluster")
        let over = ["b" + split[0]] + split.dropFirst()
        let tooLong = PDFHeaderParser.parse("Extracted text.\n\(over.joined(separator: "\n"))\n\(meta)\nBody")
        XCTAssertNil(tooLong.header?.provenance)
        XCTAssertTrue(tooLong.header?.diagnostics.contains(.missingProvenance) == true)
        // Each refusal leaves provenance missing rather than guessed from later text.
        for refused in [
            "scan.jpg\nMemo\nKind: printed\nmore\n\(meta)",                 // a field ends the header
            "scan.jpg\nMemo\n\nmore.jpg\n\(meta)",                          // a blank separator ends it
            "a_very_long_name_\nwith_no_\nextension\n\(meta)",              // no extension before provenance
            "a_\nb_\nc.jpg\nA · B · not a date",                             // malformed provenance is never taken
            "a_\nb_\nc.jpg\nA · B · 7 November 2026 extra",                  // nor an incomplete one
            "a_\nb_\nc.jpg\nnot provenance\n\(meta)",                       // provenance must follow the name
        ] {
            let parsed = PDFHeaderParser.parse("Extracted text.\n\(refused)\nBody")
            let h = try XCTUnwrap(parsed.header, refused)
            XCTAssertNil(h.provenance, refused)
            XCTAssertNil(h.rawProvenance, refused)
            XCTAssertNil(h.originalFilename, refused)
            XCTAssertTrue(h.diagnostics.contains(.missingProvenance), refused)
            XCTAssertEqual(parsed.body, "Extracted text.\n\(refused)\nBody", "nothing is stripped")
        }
    }

    func testPoorOCRRemainsASubjectWithWholeTokenCaseIdentity() {
        let raw = ["OCR Failed", "oCr pOoR", "OCR Poor", "OCR Poorly", "Q3", "Unread"]
        let tags = DocumentTags.parse(raw: raw, labelNumber: nil)
        XCTAssertTrue(tags.hasPoorOCR)
        XCTAssertEqual(tags.raw, raw)
        XCTAssertTrue(tags.subjects.contains("oCr pOoR"))
        XCTAssertTrue(tags.subjects.contains("OCR Poor"))
        XCTAssertEqual(tags.quality, 3)
        XCTAssertFalse(DocumentTags.parse(raw: ["OCR Poorly", "OCR Failed", "Q3"], labelNumber: nil).hasPoorOCR)
    }
}
