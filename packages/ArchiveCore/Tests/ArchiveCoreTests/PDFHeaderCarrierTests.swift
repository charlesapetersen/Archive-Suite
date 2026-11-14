import CoreGraphics
import PDFKit
import XCTest
@testable import ArchiveCore

/// W42.int-s5-searchable — the searchable form's header carrier and the page roles it gives a file.
final class PDFHeaderCarrierTests: XCTestCase {
    private let header = "Extracted text.\nmemo & <copy>.jpg\nApple Vision \u{00B7} macOS Vision \u{00B7} 13 November 2026\nKind: printed"

    private func packet(_ pages: [String?]) -> Data {
        let quartz = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
        <rdf:Description rdf:about="" xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/"><pdfaid:part>2</pdfaid:part>\
        </rdf:Description></rdf:RDF></x:xmpmeta>
        """
        return PDFHeaderCarrier.adding(pages: pages, to: Data(quartz.utf8))!
    }

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

    func testAFileWithoutTheListIsReadAsPairsAsBefore() throws {
        let doc = PDFDocument()
        for _ in 0..<2 { doc.insert(PDFPage(), at: doc.pageCount) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("carrier-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(doc.write(to: url))
        let content = try XCTUnwrap(PDFHeaderParser.extract(url))
        XCTAssertEqual(content.pageRoles, [.image, .text])
        XCTAssertEqual(content.textPages.map(\.pageIndex), [1])
    }
}
