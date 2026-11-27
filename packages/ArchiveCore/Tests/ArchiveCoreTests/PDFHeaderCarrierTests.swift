import AppKit
import CoreGraphics
import PDFKit
import XCTest
@testable import ArchiveCore

/// W42.int-s5-searchable — the searchable form's header carrier and the page roles it gives a file.
final class PDFHeaderCarrierTests: XCTestCase {
    private let header = "Extracted text.\nmemo & <copy>.jpg\nApple Vision \u{00B7} macOS Vision \u{00B7} 13 November 2026\nKind: printed"

    private func packet(_ pages: [String?]) -> Data {
        PDFHeaderCarrier.adding(pages: pages, to: Data(quartz.utf8))!
    }

    private let quartz = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
        <rdf:Description rdf:about="" xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/"><pdfaid:part>2</pdfaid:part>\
        </rdf:Description></rdf:RDF></x:xmpmeta>
        """

    func testRoundTripKeepsEveryEntryExactly() {
        let pages: [String?] = [header, nil, nil, "Extracted text.\nb.jpg\nX \u{00B7} Y \u{00B7} 1 March 2026"]
        XCTAssertEqual(PDFHeaderCarrier.pages(inXMP: packet(pages)), pages)
        XCTAssertTrue(String(decoding: packet(pages), as: UTF8.self).contains("<pdfaid:part>2</pdfaid:part>"))
    }

    func testControlCharactersAreDroppedNotWritten() {
        let pages: [String?] = ["Extracted text.\na\u{0001}b.jpg"]
        XCTAssertEqual(PDFHeaderCarrier.pages(inXMP: packet(pages)), ["Extracted text.\nab.jpg"])
    }

    func testAPacketWithoutTheListHasNone() {
        XCTAssertNil(PDFHeaderCarrier.pages(inXMP: Data("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"/>".utf8)))
        XCTAssertNil(PDFHeaderCarrier.adding(pages: [nil], to: Data("<x:xmpmeta/>".utf8)), "no rdf:RDF to add it to")
        XCTAssertNil(PDFHeaderCarrier.adding(pages: [nil], to: packet([header])), "a list is never added twice")
    }

    func testRoles() {
        XCTAssertEqual(PDFPageRole.pairs(4), [.image, .text, .image, .text])
        XCTAssertEqual(PDFPageRole.pairs(3), [.image, .text, .image])
        XCTAssertEqual(PDFPageRole.roles(carried: [header, nil, nil, header], pageCount: 4),
                       [.searchable, .image, .text, .searchable])
        // An image left open before a searchable page has no text page.
        XCTAssertEqual(PDFPageRole.roles(carried: [nil, header, nil, nil], pageCount: 4),
                       [.image, .searchable, .image, .text])
        // A list that does not match the pages (the file was edited) is ignored: the file is read as pairs.
        XCTAssertEqual(PDFPageRole.roles(carried: [header], pageCount: 2), [.image, .text])
    }

    /// W40.reader-plain-pdf — pages drawn with selectable text; `carried` adds the XMP list.
    private func writePDF(_ pages: [String], carried: [String?]? = nil) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("carrier-\(UUID().uuidString).pdf")
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &bounds, nil))
        for text in pages {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            (text as NSString).draw(in: bounds.insetBy(dx: 40, dy: 40), withAttributes: [.font: NSFont.systemFont(ofSize: 11)])
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        if let carried {
            context.addDocumentMetadata(try XCTUnwrap(PDFHeaderCarrier.adding(pages: carried, to: Data(quartz.utf8))) as CFData)
        }
        context.closePDF()
        return url
    }

    private let textPage = "Extracted text.\nKind: scan.jpg\nAtlas Cluster · Qwen (fp8, job 1) · 7 November 2026\nKind: printed\n\nThe transcription"

    func testAPlainPDFIsEveryPageAlone() throws {
        let url = try writePDF(["Chapter one", "Page two of the dissertation", "Page three", "Page four"])
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(PDFPageRole.roles(of: doc), Array(repeating: .searchable, count: 4))
        let content = try XCTUnwrap(PDFHeaderParser.extract(url))
        XCTAssertEqual(content.pageRoles, Array(repeating: .searchable, count: 4))
        XCTAssertEqual(content.textPages.map(\.pageIndex), [0, 1, 2, 3])
        XCTAssertTrue(content.textPages.allSatisfy { $0.header == nil })
        XCTAssertEqual(content.kindSummary, .unknown)
        for text in ["Chapter one", "Page two", "Page three", "Page four"] {
            XCTAssertTrue(content.fullBody.contains(text), text)
        }
        XCTAssertEqual(content.strippedBody, content.fullBody, "no header: the whole text is shown")
        XCTAssertEqual(PDFHeaderParser.textPageHeaders(doc).count, 4)
    }

    func testBlankAndSinglePagePlainPDFs() throws {
        let doc = PDFDocument()
        for _ in 0..<2 { doc.insert(PDFPage(), at: doc.pageCount) }
        XCTAssertEqual(PDFPageRole.roles(of: doc), [.searchable, .searchable])
        let one = try writePDF(["Only page"])
        defer { try? FileManager.default.removeItem(at: one) }
        XCTAssertEqual(PDFPageRole.roles(of: try XCTUnwrap(PDFDocument(url: one))), [.searchable])
        XCTAssertEqual(PDFPageRole.roles(of: PDFDocument()), [])
    }

    func testAFileWithoutTheListIsPairsWhenAnOddPageHasAHeader() throws {
        let url = try writePDF(["Image one", textPage, "Image two", "An unmarked imported text page"])
        defer { try? FileManager.default.removeItem(at: url) }
        let content = try XCTUnwrap(PDFHeaderParser.extract(url))
        XCTAssertEqual(content.pageRoles, [.image, .text, .image, .text])
        XCTAssertEqual(content.textPages.map(\.pageIndex), [1, 3])
        XCTAssertEqual(content.textPages[0].header?.kind, .printed)
        XCTAssertEqual(content.strippedBody, "The transcription")
        // A header on an even page alone does not make pairs: it is not where a text page sits.
        let even = try writePDF([textPage, "Page two"])
        defer { try? FileManager.default.removeItem(at: even) }
        XCTAssertEqual(PDFPageRole.roles(of: try XCTUnwrap(PDFDocument(url: even))), [.searchable, .searchable])
    }

    func testAListThatDoesNotFitIsReadLikeNoList() throws {
        let plain = try writePDF(["One", "Two", "Three"], carried: [header])
        defer { try? FileManager.default.removeItem(at: plain) }
        let content = try XCTUnwrap(PDFHeaderParser.extract(plain))
        XCTAssertEqual(content.pageRoles, [.searchable, .searchable, .searchable])
        XCTAssertTrue(content.textPages.allSatisfy { $0.header == nil }, "no page takes a header from a list that does not fit")
        let paired = try writePDF(["Image", textPage], carried: [header])
        defer { try? FileManager.default.removeItem(at: paired) }
        XCTAssertEqual(PDFHeaderParser.extract(paired)?.pageRoles, [.image, .text])
    }
}
