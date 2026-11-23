import ArchiveCore
import XCTest
@testable import ArchiveReader

@MainActor
final class CatalogueEditJournalTests: XCTestCase {
    func testReopenOffersVerifiedMemberEvenWhenAnotherMemberIsUncertain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("catalogue-journal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let rootID = UUID()
        let identities = ["First.pdf", "Second.pdf"].reduce(into: [String: CatalogueReader.PDFIdentity]()) {
            $0[$1] = .init(fileID: UUID(), contentRevision: UUID(), pageCount: 1)
        }
        let bytes = TestPDFBuilder.textPDFData(pages: ["Catalogue journal test"])
        for (path, identity) in identities {
            try writePair(bytes, path: path, identity: identity, under: root)
        }
        let url = root.appendingPathComponent("local-history.jsonl")
        let journal = CatalogueEditJournal(url: url)
        let reader = try CatalogueReader(grantedRoot: root, rootInstanceID: rootID, mode: .adopted) { _, occurrence in
            identities[occurrence.relativePath]
        }
        let writer = CatalogueWriter(reader: reader)
        func facts(_ path: String) throws -> ItemFacts.FileFacts {
            try reader.snapshot(.init(relativePDFPaths: [path], isComplete: false)).facts(at: path).file.get()
        }
        let first = try facts("First.pdf")
        let second = try facts("Second.pdf")
        let firstEdit = CatalogueEditJournal.Operation(title: "Flag Change")
        let interruptedEdit = CatalogueEditJournal.Operation(title: "Quality Change")
        try journal.withSession { session in
            for file in [first, second] {
                let occurrence = file.pair.occurrence
                try session.record(.intent(firstEdit, occurrence))
                let receipt = try writer.save([.init(.file(.flagged), .set(.flag(true)))], basedOn: file)
                try session.record(.result(firstEdit.id, occurrence, .changed(XCTUnwrap(receipt.inverse))))
            }
            try session.record(.intent(interruptedEdit, second.pair.occurrence))
            // A process interrupted after its intention might never record the result.
        }

        let reopened = CatalogueEditJournal(url: url)
        XCTAssertEqual(try reopened.read().undo?.title, "Flag Change")
        XCTAssertEqual(try reopened.read().uncertainCount, 1)
        try reopened.withSession { session in
            let undo = try XCTUnwrap(session.history.next(redo: false))
            XCTAssertEqual(undo.inverses.map(\.occurrence), [first.pair.occurrence])
            let inverse = try XCTUnwrap(undo.inverses.first)
            let attempt = CatalogueEditJournal.Operation(direction: .undo(undo.operation.id), title: undo.operation.title)
            try session.record(.intent(attempt, inverse.occurrence))
            let receipt = try writer.reverse(inverse, basedOn: facts("First.pdf"))
            try session.record(.result(attempt.id, inverse.occurrence, .changed(XCTUnwrap(receipt.inverse))))
        }

        XCTAssertNil(try reopened.read().undo)
        XCTAssertEqual(try reopened.read().redo?.title, "Flag Change")
        XCTAssertNil(try facts("First.pdf").pair.record.fileFields.flagged)
        guard case .value(true)? = try facts("Second.pdf").pair.record.fileFields.flagged?.current else {
            return XCTFail("Undo touched the uncertain file.")
        }
        for path in identities.keys {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), bytes)
        }
    }

    private func writePair(_ pdf: Data, path: String, identity: CatalogueReader.PDFIdentity, under root: URL) throws {
        let id = UUID()
        try pdf.write(to: root.appendingPathComponent(path))
        try Data("""
            {"schema":1,"fileID":"\(identity.fileID)","contentRevision":"\(identity.contentRevision)",
             "revision":"\(UUID())","parents":[],"pages":[{"id":"\(UUID())","physicalIndex":0,
             "documentID":"\(id)","role":"searchable"}],
             "documents":[{"id":"\(id)","ownerFileID":"\(identity.fileID)","fields":{}}],"fileFields":{}}
            """.utf8).write(to: root.appendingPathComponent(CatalogueRecord.companionFilename(forPDFFilename: path)))
    }
}
