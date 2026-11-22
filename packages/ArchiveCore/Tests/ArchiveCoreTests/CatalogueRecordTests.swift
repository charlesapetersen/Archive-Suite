import Foundation
import PDFKit
import Testing
import ArchiveCore

@Suite("Catalogue companion contract")
struct CatalogueRecordTests {
    private let fileA = UUID()
    private let fileB = UUID()
    private let contentA = UUID()
    private let contentB = UUID()
    private let documentA = UUID()
    private let documentB = UUID()
    private let revision = UUID()

    private func fixture(fileID: UUID, content: UUID, documents: [(id: UUID, owner: UUID)],
                         ownedFields: String = "{}", extensions: String = "") -> Data {
        let sourcePages = Dictionary(grouping: documents, by: \.id).mapValues { _ in UUID() }
        let pages = documents.enumerated().map { index, document in
            """
            {"id":"\(UUID())","physicalIndex":\(index),"documentID":"\(document.id)",
             "sourcePageID":"\(sourcePages[document.id]!)","role":"searchable","viewRotation":90}
            """
        }.joined(separator: ",")
        let members = Dictionary(grouping: documents, by: \.id).values.compactMap(\.first).map { document in
            let fields = document.owner == fileID ? #", "fields": "# + ownedFields : ""
            return #"{"id":"\#(document.id)","ownerFileID":"\#(document.owner)"\#(fields)}"#
        }.joined(separator: ",")
        return Data("""
        {"schema":1,"fileID":"\(fileID)","contentRevision":"\(content)","revision":"\(revision)",
         "parents":[],"pages":[\(pages)],"documents":[\(members)],"fileFields":{}\(extensions)}
        """.utf8)
    }

    private func single(_ fields: String = "{}", extensions: String = "") -> Data {
        fixture(fileID: fileA, content: contentA, documents: [(documentA, fileA)],
                ownedFields: fields, extensions: extensions)
    }

    @Test func precisionClearsAndChecksSurviveVerbatimExport() throws {
        let old = UUID()
        let fields = """
        {"documentDate":{"state":"value","value":{"date":"1950s","uncertain":true,"precisionNote":"目録"},
          "fieldRevision":"\(revision)","checkedRevision":"\(revision)","origin":"user",
          "evidence":[{"source":"model","supportsRevision":"\(old)","observedValue":{"date":"1958-03-12",
            "uncertain":false},"quote":"12 mars 1958"}]},
         "sentWith":{"state":"value","value":{"date":"1957","uncertain":false},
          "fieldRevision":"\(UUID())","checkedRevision":"\(old)","origin":"future-source"},
         "publicationDate":{"state":"value","value":{"date":"1958-03","uncertain":false},
          "fieldRevision":"\(UUID())","origin":"model"},
         "recipientPlaces":{"state":"cleared","fieldRevision":"\(UUID())","origin":"user"},
         "documentKind":{"state":"value","value":"future-kind","fieldRevision":"\(UUID())","origin":"model"},
         "senders":{"state":"value","value":["Nguyễn, An","王芳"],"fieldRevision":"\(UUID())","origin":"user"},
         "newField":{"state":"future","payload":[null,9007199254740993]}}
        """
        let json = single(fields, extensions: #", "extension": {"array":[true,{"nested":"résumé"}]}"#)
        let record = try CatalogueRecord(json: json)
        let decoded = try #require(record.document(id: documentA)?.fields)
        guard case .value(let own)? = decoded.documentDate?.current,
              case .value(let sent)? = decoded.sentWith?.current,
              case .value(let published)? = decoded.publicationDate?.current,
              case .cleared? = decoded.recipientPlaces?.current,
              case .value(let kind)? = decoded.documentKind?.current,
              case .value(let senders)? = decoded.senders?.current else {
            Issue.record("Missing a current value or explicit clear")
            return
        }
        #expect(own.date.precision == .decade && own.uncertain)
        #expect(sent.date.precision == .year && !sent.uncertain)
        #expect(published.date.precision == .month)
        #expect(decoded.documentDate?.evidence.first?.observedValue?.date.precision == .day)
        #expect(decoded.documentDate?.isChecked == true)
        #expect(decoded.sentWith?.isChecked == false)
        #expect(decoded.sentWith?.origin == "future-source")
        #expect(decoded.title == nil)
        #expect(kind == "future-kind")
        #expect(senders == ["Nguyễn, An", "王芳"])
        #expect(record.originalJSON == json)
        #expect(try CatalogueRecord(json: record.originalJSON).originalJSON == json)
    }

    @Test func malformedUnsupportedAndAmbiguousJSONFailClosed() throws {
        let valid = String(decoding: single(), as: UTF8.self)
        #expect(throws: (any Error).self) {
            try CatalogueRecord(json: single(extensions: #", "unknown":[00]"#))
        }
        #expect(throws: CatalogueRecord.Invalid.malformedJSON) {
            try CatalogueRecord(json: single(extensions: #", "unknown":[1,]"#))
        }
        #expect(throws: CatalogueRecord.Invalid.unsupportedSchema(2)) {
            try CatalogueRecord(json: Data(valid.replacingOccurrences(of: #""schema":1"#, with: #""schema":2"#).utf8))
        }
        #expect(throws: CatalogueRecord.Invalid.malformedJSON) {
            try CatalogueRecord(json: single(extensions: #", "nested":{"owner":1,"\u006fwner":2}"#))
        }
        #expect(throws: CatalogueRecord.Invalid.inputLimit) {
            try CatalogueRecord(json: single(extensions: #", "nested":"# + String(repeating: "[", count: 70)
                                              + "0" + String(repeating: "]", count: 70)))
        }
        #expect(throws: (any Error).self) {
            try CatalogueRecord(json: single(#"{"documentDate":{"state":"value","value":{"date":"1958-02-30","uncertain":false},"fieldRevision":"\#(revision)","origin":"user"}}"#))
        }
        #expect(throws: CatalogueRecord.Invalid.inconsistentRecord) {
            try CatalogueRecord(json: single(#"{"recipients":{"state":"cleared","value":null,"fieldRevision":"\#(revision)","origin":"user"}}"#))
        }
        #expect(throws: (any Error).self) {
            try CatalogueRecord(json: single(#"{"title":{"state":"future","fieldRevision":"\#(revision)","origin":"user"}}"#))
        }
        #expect(throws: CatalogueRecord.Invalid.inconsistentRecord) {
            try CatalogueRecord(json: Data(valid.replacingOccurrences(of: #""physicalIndex":0"#, with: #""physicalIndex":1"#).utf8))
        }
    }

    @Test func splitAndMergedPDFsHaveExactlyOneOwnerPerDocument() throws {
        let replica = UUID()
        let owner = try pair(fixture(fileID: fileA, content: contentA, documents: [(documentA, fileA)]),
                             root: replica, path: "owner.pdf")
        let member = try pair(fixture(fileID: fileB, content: contentB,
                                      documents: [(documentA, fileA), (documentA, fileA), (documentB, fileB)]),
                              root: replica, path: "merged.pdf")
        #expect(member.record.pages.map(\.documentID) == [documentA, documentA, documentB])
        #expect(member.record.pages[0].sourcePageID == member.record.pages[1].sourcePageID)
        #expect(member.record.pages[0].sourcePageID != member.record.pages[2].sourcePageID)
        #expect(member.record.document(id: documentA)?.fields == nil)
        #expect(try member.owner(of: documentA, among: [owner]).occurrence == owner.occurrence)
        #expect(try member.owner(of: documentB, among: []).occurrence == member.occurrence)
        #expect(throws: CatalogueAssociation.Unavailable.missingOwner) {
            try member.owner(of: documentA, among: [])
        }
        let otherRoot = try pair(owner.record.originalJSON, root: UUID(), path: "owner.pdf")
        #expect(throws: CatalogueAssociation.Unavailable.missingOwner) {
            try member.owner(of: documentA, among: [otherRoot])
        }
        let copy = try pair(owner.record.originalJSON, root: replica, path: "copies/owner.pdf")
        #expect(throws: CatalogueAssociation.Unavailable.ambiguousOwner) {
            try member.owner(of: documentA, among: [copy, owner])
        }
        let wrong = try pair(fixture(fileID: fileA, content: contentA, documents: [(UUID(), fileA)]),
                             root: replica, path: "wrong.pdf")
        #expect(throws: CatalogueAssociation.Unavailable.invalidOwner) {
            try member.owner(of: documentA, among: [wrong])
        }
    }

    @Test func movedRootAndCopiesLeaveScratchPDFBytesIntact() throws {
        let files = FileManager.default
        let scratch = files.temporaryDirectory.appendingPathComponent("catalogue-tests-\(UUID())")
        try files.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: scratch) }
        let root = scratch.appendingPathComponent("before")
        let moved = scratch.appendingPathComponent("after")
        try files.createDirectory(at: root, withIntermediateDirectories: false)
        let pdf = PDFDocument()
        pdf.insert(PDFPage(), at: 0)
        let bytes = try #require(pdf.dataRepresentation())
        let filename = "Scan.PDF"
        let companion = CatalogueRecord.companionFilename(forPDFFilename: filename)
        #expect(companion == "Scan.PDF.archivesuite.json")
        let pdfURL = root.appendingPathComponent(filename)
        try bytes.write(to: pdfURL) // Only the fixture setup writes a PDF.
        try single().write(to: root.appendingPathComponent(companion))
        let replica = UUID()
        let location = CatalogueAssociation.Occurrence(rootInstanceID: replica, relativePath: filename)
        let proof = CatalogueAssociation.VerifiedPDF(occurrence: location, fileID: fileA,
                                                      contentRevision: contentA, pageCount: pdf.pageCount)
        let before = try CatalogueAssociation.pair(CatalogueRecord(json: Data(contentsOf: root.appendingPathComponent(companion))),
                                                    at: location, verifiedBy: proof)
        try files.moveItem(at: root, to: moved)
        let movedPDF = moved.appendingPathComponent(filename)
        let movedCompanion = moved.appendingPathComponent(companion)
        let after = try CatalogueAssociation.pair(CatalogueRecord(json: Data(contentsOf: movedCompanion)),
                                                   at: location, verifiedBy: proof)
        #expect(after.occurrence == before.occurrence && after.record.revision == before.record.revision)

        let copiedPDF = moved.appendingPathComponent("Copy.pdf")
        try files.copyItem(at: movedPDF, to: copiedPDF)
        let copyLocation = CatalogueAssociation.Occurrence(rootInstanceID: replica, relativePath: "Copy.pdf")
        #expect(throws: CatalogueAssociation.Unavailable.missingCompanion) {
            try CatalogueAssociation.pair(nil, at: copyLocation, verifiedBy: nil)
        }
        #expect(throws: CatalogueAssociation.Unavailable.unverifiedPDF) {
            try CatalogueAssociation.pair(after.record, at: copyLocation, verifiedBy: proof)
        }
        let replacement = CatalogueAssociation.VerifiedPDF(occurrence: location, fileID: fileA,
                                                            contentRevision: UUID(), pageCount: 1)
        #expect(throws: CatalogueAssociation.Unavailable.mismatchedPDF) {
            try CatalogueAssociation.pair(after.record, at: location, verifiedBy: replacement)
        }
        let copyCompanion = moved.appendingPathComponent(CatalogueRecord.companionFilename(forPDFFilename: "Copy.pdf"))
        try files.copyItem(at: movedCompanion, to: copyCompanion)
        let copiedPair = try pair(Data(contentsOf: copyCompanion), root: replica, path: "Copy.pdf")
        #expect(copiedPair.record.fileID == after.record.fileID)
        #expect(copiedPair.occurrence != after.occurrence)
        #expect(PDFDocument(url: movedPDF)?.pageCount == 1)
        #expect(try Data(contentsOf: movedPDF) == bytes)
        #expect(try Data(contentsOf: copiedPDF) == bytes)
    }

    private func pair(_ json: Data, root: UUID, path: String) throws -> CatalogueAssociation.Pair {
        let record = try CatalogueRecord(json: json)
        let occurrence = CatalogueAssociation.Occurrence(rootInstanceID: root, relativePath: path)
        let proof = CatalogueAssociation.VerifiedPDF(occurrence: occurrence, fileID: record.fileID,
                                                      contentRevision: record.contentRevision, pageCount: record.pages.count)
        return try CatalogueAssociation.pair(record, at: occurrence, verifiedBy: proof)
    }
}
