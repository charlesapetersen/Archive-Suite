import CoreGraphics
import Darwin
import XCTest
@testable import ArchiveCore

final class CataloguePDFIdentityTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("catalogue-pdf-identity-" + UUID().uuidString, isDirectory: true)
        .resolvingSymlinksInPath()
    private let packet = Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        </rdf:RDF></x:xmpmeta>
        """.utf8)

    func testIdentityKeepsPageHeadersAndRefusesAnotherIdentity() throws {
        let headers = ["Extracted text.\nOriginal & copy"]
        let carryingHeaders = try XCTUnwrap(PDFHeaderCarrier.adding(pages: headers, to: packet))
        let identity = CataloguePDFIdentity(fileID: UUID(), contentRevision: UUID())
        let withIdentity = try XCTUnwrap(identity.adding(to: carryingHeaders))
        XCTAssertEqual(CataloguePDFIdentity.identity(inXMP: withIdentity), identity)
        XCTAssertEqual(PDFHeaderCarrier.pages(inXMP: withIdentity), headers)
        XCTAssertNil(identity.adding(to: withIdentity))
        let xml = String(decoding: withIdentity, as: UTF8.self)
        XCTAssertEqual(xml.components(separatedBy: "<pdfaExtension:schemas>").count, 2)
        XCTAssertEqual(xml.components(separatedBy: "<pdfaSchema:namespaceURI>").count, 3)
        let changes = [
            ("</ascat:identity>", "</ascat:identity><ascat:identity>unrelated</ascat:identity>"),
            ("</ascat:identity>", "<![CDATA[unrelated]]></ascat:identity>"),
            ("rdf:about=\"\" xmlns:ascat", "rdf:about=\"urn:unrelated\" xmlns:ascat"),
            ("rdf:about=\"\" xmlns:ascat", "rdf:about=\"\" ascat:identity=\"unrelated\" xmlns:ascat")
        ]
        for (original, replacement) in changes {
            XCTAssertNil(CataloguePDFIdentity.identity(inXMP: Data(
                xml.replacingOccurrences(of: original, with: replacement).utf8
            )), replacement)
        }
    }

    func testBorrowedDescriptorSurvivesRenameAndKeepsItsOffset() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("preparing.pdf")
        let identity = CataloguePDFIdentity(fileID: UUID(), contentRevision: UUID())
        let metadata = try XCTUnwrap(identity.adding(to: packet))
        var mediaBox = CGRect(x: 0, y: 0, width: 60, height: 60)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &mediaBox, nil))
        context.addDocumentMetadata(metadata as CFData)
        for _ in 0..<2 {
            context.beginPDFPage(nil)
            context.fillEllipse(in: mediaBox.insetBy(dx: 15, dy: 15))
            context.endPDFPage()
        }
        context.closePDF()

        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        XCTAssertEqual(lseek(fd, 5, SEEK_SET), 5)
        try FileManager.default.moveItem(at: url, to: directory.appendingPathComponent("filed.pdf"))
        try Data("unrelated replacement".utf8).write(to: url)
        let occurrence = CatalogueAssociation.Occurrence(rootInstanceID: UUID(), relativePath: "filed.pdf")
        let verified = try XCTUnwrap(CataloguePDFIdentity.identify(fd, at: occurrence))
        XCTAssertEqual(verified.fileID, identity.fileID)
        XCTAssertEqual(verified.contentRevision, identity.contentRevision)
        XCTAssertEqual(verified.pageCount, 2)
        XCTAssertEqual(lseek(fd, 0, SEEK_CUR), 5)
    }
}
