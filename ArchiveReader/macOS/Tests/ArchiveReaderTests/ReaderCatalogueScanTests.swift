import ArchiveCore
import CoreGraphics
import XCTest
@testable import ArchiveReader

final class ReaderCatalogueScanTests: XCTestCase {
    func testAllPDFsAreMembersAndOnlyVerifiedCompanionsSupplyFacets() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-catalogue-\(UUID())", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileID = UUID(), contentID = UUID(), documentID = UUID()
        let packet = Data("""
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
            <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"></rdf:RDF></x:xmpmeta>
            """.utf8)
        let identity = CataloguePDFIdentity(fileID: fileID, contentRevision: contentID)
        let metadata = try XCTUnwrap(identity.adding(to: packet))
        let paired = root.appendingPathComponent("Paired.pdf")
        let plain = root.appendingPathComponent("Plain.pdf")
        try writePDF(at: paired, metadata: metadata)
        try writePDF(at: plain, metadata: nil)
        let companion = root.appendingPathComponent("Paired.pdf.archivesuite.json")
        try Data("""
            {"schema":1,"fileID":"\(fileID)","contentRevision":"\(contentID)","revision":"\(UUID())",
             "parents":[],"pages":[{"id":"\(UUID())","physicalIndex":0,"documentID":"\(documentID)","role":"searchable"}],
             "documents":[{"id":"\(documentID)","ownerFileID":"\(fileID)","fields":{
               "subjects":{"state":"value","value":["Read","1957"],"fieldRevision":"\(UUID())","origin":"user"},
               "documentDate":{"state":"value","value":{"date":"1958-04","uncertain":true},
                               "fieldRevision":"\(UUID())","origin":"user"}
             }}],
             "fileFields":{"readState":{"state":"value","value":"unread","fieldRevision":"\(UUID())","origin":"user"}}}
            """.utf8).write(to: companion)
        let before = try Data(contentsOf: paired)

        let instance = UUID()
        let pass = ReaderCatalogueScan.run(root: root, instance: instance, isCancelled: { false }, onProgress: { _ in })
        XCTAssertEqual(pass.rows.map(\.name), ["Paired.pdf", "Plain.pdf"])
        let first = try XCTUnwrap(pass.rows.first)
        XCTAssertEqual(first.subjects, ["Read", "1957"])
        XCTAssertEqual(first.readState, .unread)
        XCTAssertEqual(first.tags.ownSortDate, 19580400)
        XCTAssertTrue(first.dateIsSpeculative)
        XCTAssertNil(pass.rows.last?.readState)
        XCTAssertThrowsError(try pass.rows.last?.catalogueFacts?.file.get())

        try FileManager.default.removeItem(at: companion)
        let refreshed = ReaderCatalogueScan.run(root: root, instance: instance, isCancelled: { false }, onProgress: { _ in })
        XCTAssertEqual(refreshed.rows.map(\.name), ["Paired.pdf", "Plain.pdf"])
        XCTAssertEqual(refreshed.rows.first?.subjects, [])
        XCTAssertNil(refreshed.rows.first?.readState)
        XCTAssertEqual(try Data(contentsOf: paired), before)
    }

    private func writePDF(at url: URL, metadata: Data?) throws {
        var bounds = CGRect(x: 0, y: 0, width: 60, height: 60)
        let pdf = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &bounds, nil))
        if let metadata { pdf.addDocumentMetadata(metadata as CFData) }
        pdf.beginPDFPage(nil)
        pdf.fill(bounds.insetBy(dx: 10, dy: 10))
        pdf.endPDFPage()
        pdf.closePDF()
    }
}
