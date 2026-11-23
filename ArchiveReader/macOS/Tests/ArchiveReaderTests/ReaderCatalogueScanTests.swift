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

    func testMergedFileRulesStayOnOneDocumentAndRefuseStaleSearchHits() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-catalogue-merged-\(UUID())", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let identity = CataloguePDFIdentity(fileID: UUID(), contentRevision: UUID())
        let packet = Data("""
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            </rdf:RDF></x:xmpmeta>
            """.utf8)
        let pdf = root.appendingPathComponent("Merged.pdf")
        try writePDF(at: pdf, metadata: XCTUnwrap(identity.adding(to: packet)), pageCount: 2)
        let documents = [(UUID(), "1901", "Private letter"), (UUID(), "1958", "Public speech")]
        let pages = documents.enumerated().map { number, document in
            ["id": UUID().uuidString, "physicalIndex": number, "documentID": document.0.uuidString,
             "role": "searchable"] as [String: Any]
        }
        let records = documents.map { document in
            ["id": document.0.uuidString, "ownerFileID": identity.fileID.uuidString,
             "fields": [
                "documentDate": ["state": "value", "value": ["date": document.1, "uncertain": false],
                                 "fieldRevision": UUID().uuidString, "origin": "user"],
                "subjects": ["state": "value", "value": [document.2], "fieldRevision": UUID().uuidString, "origin": "user"]
             ]] as [String: Any]
        }
        let bytes = try JSONSerialization.data(withJSONObject: [
            "schema": 1, "fileID": identity.fileID.uuidString, "contentRevision": identity.contentRevision.uuidString,
            "revision": UUID().uuidString, "parents": [], "pages": pages, "documents": records, "fileFields": [:]
        ])
        try bytes.write(to: root.appendingPathComponent("Merged.pdf.archivesuite.json"))

        let pass = ReaderCatalogueScan.run(root: root, instance: UUID(), isCancelled: { false }, onProgress: { _ in })
        let file = try XCTUnwrap(pass.rows.first)
        var filter = LibraryFilter(subjects: ["Private letter"], dateFromYear: 1958, dateToYear: 1958)
        XCTAssertFalse(filter.matches(file))
        filter.subjects = ["Public speech"]
        XCTAssertTrue(filter.matches(file))
        filter.read = .noReadState
        XCTAssertFalse(filter.matches(file), "An unassessed field cannot satisfy a negative rule.")

        var rule = SearchRule(field: .catalogueFields)
        rule.text = "Private"
        var date = SearchRule(field: .date, op: .between)
        date.text = "1958"
        date.text2 = "1958"
        let search = AdvancedSearch(rules: [rule, date]).prepared()
        let digest = try XCTUnwrap(file.catalogueFacts?.file.get().revision.companionSHA256)
        var context = RuleContext(catalogueHits: [rule.id: [UTF8Key(file.path): [documents[0].0: digest]]])
        XCTAssertFalse(search.matchesPrepared(file, context), "A date in the other document is not a match.")
        context.catalogueHits[rule.id]?[UTF8Key(file.path)] = [documents[1].0: Data([0])]
        XCTAssertFalse(search.matchesPrepared(file, context), "An old digest is not a current field match.")
        context.catalogueHits[rule.id]?[UTF8Key(file.path)] = [documents[1].0: digest]
        XCTAssertTrue(search.matchesPrepared(file, context))
    }

    private func writePDF(at url: URL, metadata: Data?, pageCount: Int = 1) throws {
        var bounds = CGRect(x: 0, y: 0, width: 60, height: 60)
        let pdf = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &bounds, nil))
        if let metadata { pdf.addDocumentMetadata(metadata as CFData) }
        for _ in 0..<pageCount {
            pdf.beginPDFPage(nil)
            pdf.fill(bounds.insetBy(dx: 10, dy: 10))
            pdf.endPDFPage()
        }
        pdf.closePDF()
    }
}
