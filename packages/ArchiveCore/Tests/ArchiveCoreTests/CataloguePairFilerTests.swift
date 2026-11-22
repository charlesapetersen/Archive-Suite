import CoreGraphics
import Foundation
import Testing
@testable import ArchiveCore

@Suite("Journaled catalogue pair filing", .timeLimit(.minutes(1)))
struct CataloguePairFilerTests {
    @Test(arguments: CataloguePairFiler.Boundary.allCases)
    func interruptedFilingResumesWithoutRenumberingOrTouchingInput(cut: CataloguePairFiler.Boundary) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let writer = CataloguePairFiler(reader: try fixture.reader()) { reached in
            if reached == cut { throw Stop.interrupted }
        }
        #expect(throws: Stop.interrupted) { try fixture.file(with: writer) }
        #expect(try Data(contentsOf: fixture.input) == fixture.pdfBytes)

        // Verify what really reached disk before opening a fresh reader and filer.
        let exists = FileManager.default.fileExists(atPath:)
        switch cut {
        case .companionStaged:
            #expect(exists(fixture.pendingPDF.path) && exists(fixture.pendingCompanion.path))
            #expect(!exists(fixture.journal.path) && !exists(fixture.finalPDF.path))
        case .journalFlushed:
            #expect(exists(fixture.journal.path) && exists(fixture.pendingPDF.path))
            #expect(!exists(fixture.finalPDF.path) && !exists(fixture.finalCompanion.path))
        case .pdfPublished:
            #expect(exists(fixture.journal.path) && exists(fixture.finalPDF.path))
            #expect(exists(fixture.pendingCompanion.path) && !exists(fixture.finalCompanion.path))
        case .companionPublished, .verified:
            #expect(exists(fixture.journal.path) && exists(fixture.finalPDF.path) && exists(fixture.finalCompanion.path))
            #expect(!exists(fixture.receipt.path))
        case .receiptRenamed:
            #expect(exists(fixture.receipt.path) && !exists(fixture.journal.path))
        }

        let restarted = CataloguePairFiler(reader: try fixture.reader())
        let receipt: CataloguePairFiler.Receipt
        if cut == .companionStaged {
            #expect(throws: CataloguePairFiler.Failure.journalMissing) { try fixture.recover(with: restarted) }
            receipt = try fixture.file(with: restarted)
        } else {
            receipt = try fixture.recover(with: restarted)
        }
        #expect(receipt.operationID == fixture.id)
        #expect(receipt.pdfRelativePath == fixture.occurrence.relativePath)
        #expect(receipt.companionRelativePath == "Box/" + fixture.finalCompanion.lastPathComponent)
        #expect(try fixture.recover(with: restarted) == receipt)
        #expect(try fixture.file(with: restarted) == receipt)
        #expect(try Data(contentsOf: fixture.input) == fixture.pdfBytes)
        #expect(try Data(contentsOf: fixture.finalPDF) == fixture.pdfBytes)
        #expect(try Data(contentsOf: fixture.finalCompanion) == fixture.record.originalJSON)
        #expect(!exists(fixture.pendingPDF.path) && !exists(fixture.pendingCompanion.path))
        let discovered = try fixture.reader().discover()
        #expect(try discovered.facts(at: receipt.pdfRelativePath).file.get().revision.facts == fixture.record.revision)
    }

    @Test func missingCompanionWithholdsReceiptBeforeAndAfterCompletion() throws {
        for completed in [false, true] {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            if completed {
                _ = try fixture.file()
            } else {
                try fixture.stop(at: .pdfPublished)
            }
            let companion = completed ? fixture.finalCompanion : fixture.pendingCompanion
            let held = fixture.parent.appendingPathComponent("Held companion.json")
            try FileManager.default.moveItem(at: companion, to: held)
            #expect(throws: CataloguePairFiler.Failure.self) { try fixture.recover() }
            #expect(throws: CataloguePairFiler.Failure.self) { try fixture.file() }
            #expect(!FileManager.default.fileExists(atPath: fixture.finalCompanion.path))
            #expect(try Data(contentsOf: held) == fixture.record.originalJSON)
            #expect(try Data(contentsOf: fixture.finalPDF) == fixture.pdfBytes)
            #expect(try Data(contentsOf: fixture.input) == fixture.pdfBytes)

            try FileManager.default.moveItem(at: held, to: companion)
            #expect(try fixture.recover().operationID == fixture.id)
        }
    }

    @Test func failedFinalVerificationRetainsTheJournalAndBothCandidates() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let altered = fixture.record.originalJSON + Data([10]) // Valid JSON, different exact bytes.
        let filer = CataloguePairFiler(reader: try fixture.reader()) { reached in
            if reached == .companionPublished {
                try altered.write(to: fixture.finalCompanion)
            }
        }
        #expect(throws: CataloguePairFiler.Failure.changed(fixture.finalCompanion.lastPathComponent)) {
            try fixture.file(with: filer)
        }
        #expect(throws: CataloguePairFiler.Failure.self) { try fixture.recover() }
        #expect(FileManager.default.fileExists(atPath: fixture.journal.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.receipt.path))
        #expect(try Data(contentsOf: fixture.finalCompanion) == altered)
        #expect(try Data(contentsOf: fixture.finalPDF) == fixture.pdfBytes)
        #expect(try Data(contentsOf: fixture.input) == fixture.pdfBytes)
    }

    @Test func sameByteReplacementAndForeignOccupantCannotBeAdopted() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.stop(at: .pdfPublished)
        try fixture.record.originalJSON.write(to: fixture.finalCompanion)
        #expect(throws: CataloguePairFiler.Failure.occupied(fixture.finalCompanion.lastPathComponent)) {
            try fixture.recover()
        }
        #expect(try Data(contentsOf: fixture.pendingCompanion) == fixture.record.originalJSON)
        let held = fixture.parent.appendingPathComponent("Unrelated.json")
        try FileManager.default.moveItem(at: fixture.finalCompanion, to: held)
        _ = try fixture.recover()

        try fixture.pdfBytes.write(to: fixture.finalPDF, options: .atomic)
        #expect(throws: CataloguePairFiler.Failure.occupied(fixture.finalPDF.lastPathComponent)) {
            try fixture.recover()
        }
        #expect(try Data(contentsOf: held) == fixture.record.originalJSON)
        #expect(try Data(contentsOf: fixture.input) == fixture.pdfBytes)
    }

    @Test func malformedJournalAndTornStagingStayAvailableWithoutPublishing() throws {
        for damageJournal in [false, true] {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            let path = damageJournal ? fixture.journal : fixture.pendingCompanion
            let partial = Data("{\"incomplete\":".utf8)
            try partial.write(to: path)
            #expect(throws: (any Error).self) { try fixture.file() }
            #expect(try Data(contentsOf: path) == partial)
            #expect(try Data(contentsOf: fixture.pendingPDF) == fixture.pdfBytes)
            #expect(!FileManager.default.fileExists(atPath: fixture.finalPDF.path))
            #expect(!FileManager.default.fileExists(atPath: fixture.finalCompanion.path))
        }
    }

    @Test func aDifferentRequestCannotRepointTheJournal() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.stop(at: .journalFlushed)
        let differentPath = CatalogueAssociation.Occurrence(rootInstanceID: fixture.occurrence.rootInstanceID,
                                                            relativePath: "Box/Different.PDF")
        let filer = CataloguePairFiler(reader: try fixture.reader())
        #expect(throws: CataloguePairFiler.Failure.operationMismatch) {
            try filer.recoverPair(operationID: fixture.id, at: differentPath)
        }
        let changedRecord = try CatalogueRecord(json: fixture.record.originalJSON + Data([10]))
        #expect(throws: CataloguePairFiler.Failure.operationMismatch) {
            try filer.filePair(operationID: fixture.id, at: fixture.occurrence, record: changedRecord)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.finalPDF.path))
        #expect(try fixture.recover().operationID == fixture.id)
    }

    @Test func journalRequiresTheSameGrantAndPhysicalStagedFile() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.stop(at: .journalFlushed)
        let newID = UUID()
        let otherGrant = CatalogueAssociation.Occurrence(rootInstanceID: newID, relativePath: fixture.occurrence.relativePath)
        let filer = CataloguePairFiler(reader: try fixture.reader(rootID: newID))
        #expect(throws: CataloguePairFiler.Failure.operationMismatch) {
            try filer.recoverPair(operationID: fixture.id, at: otherGrant)
        }

        let held = fixture.parent.appendingPathComponent("Held PDF")
        try FileManager.default.moveItem(at: fixture.pendingPDF, to: held)
        try FileManager.default.createSymbolicLink(at: fixture.pendingPDF, withDestinationURL: held)
        #expect(throws: CataloguePairFiler.Failure.changed(fixture.pendingPDF.lastPathComponent)) {
            try fixture.recover()
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.finalPDF.path))
        #expect(try Data(contentsOf: held) == fixture.pdfBytes)
        #expect(try Data(contentsOf: fixture.pendingCompanion) == fixture.record.originalJSON)
        #expect(try Data(contentsOf: fixture.input) == fixture.pdfBytes)
    }

    @Test func stagedPDFMustIndependentlyProveTheAssociation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let reader = try CatalogueReader(grantedRoot: fixture.root, rootInstanceID: fixture.occurrence.rootInstanceID,
                                         mode: .adopted, identifyPDF: { _, _ in nil })
        #expect(throws: ItemFacts.Unavailable.invalid(.pdf)) {
            try fixture.file(with: CataloguePairFiler(reader: reader))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.pendingCompanion.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.journal.path))
        #expect(try Data(contentsOf: fixture.pendingPDF) == fixture.pdfBytes)
    }

    @Test func leadingCombiningMarkKeepsBothPathsInTheSelectedParent() throws {
        let fixture = try Fixture(filename: "\u{301}Letter.PDF")
        defer { fixture.cleanUp() }
        let receipt = try fixture.file()
        #expect(receipt.pdfRelativePath.utf8.elementsEqual(fixture.occurrence.relativePath.utf8))
        #expect(receipt.companionRelativePath.utf8.elementsEqual(("Box/" + fixture.finalCompanion.lastPathComponent).utf8))
        #expect(try Data(contentsOf: fixture.finalPDF) == fixture.pdfBytes)
        #expect(try Data(contentsOf: fixture.finalCompanion) == fixture.record.originalJSON)
    }

    @Test func concurrentRetriesOfOneOperationShareTheReceipt() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.stop(at: .pdfPublished)
        async let first = fixture.recover()
        async let second = fixture.file()
        #expect(try await first == second)
        #expect(try Data(contentsOf: fixture.input) == fixture.pdfBytes)
    }

    private enum Stop: Error { case interrupted }

    private struct Fixture: Sendable {
        let root: URL
        let id = UUID()
        let occurrence: CatalogueAssociation.Occurrence
        let filename: String
        let pdfBytes: Data
        let record: CatalogueRecord

        var parent: URL { root.appendingPathComponent("Box") }
        var input: URL { root.appendingPathComponent("Source.pdf") }
        var pendingPDF: URL { parent.appendingPathComponent(CataloguePairFiler.stagedPDFName(for: id)) }
        var finalPDF: URL { parent.appendingPathComponent(filename) }
        var finalCompanion: URL {
            parent.appendingPathComponent(CatalogueRecord.companionFilename(forPDFFilename: finalPDF.lastPathComponent))
        }

        private var prefix: String { ".archivesuite-pair-" + id.uuidString.lowercased() }
        var pendingCompanion: URL { parent.appendingPathComponent(prefix + ".json.pending") }
        var journal: URL { parent.appendingPathComponent(prefix + ".journal") }
        var receipt: URL { parent.appendingPathComponent(prefix + ".receipt") }

        init(filename: String = "Letter.PDF") throws {
            self.filename = filename
            occurrence = CatalogueAssociation.Occurrence(rootInstanceID: UUID(), relativePath: "Box/" + filename)
            root = FileManager.default.temporaryDirectory.appendingPathComponent("catalogue-pair-\(UUID())")
            let file = UUID()
            let content = UUID()
            let document = UUID()
            record = try CatalogueRecord(json: Data("""
                {"schema":1,"fileID":"\(file)","contentRevision":"\(content)","revision":"\(UUID())","parents":[],
                 "pages":[{"id":"\(UUID())","physicalIndex":0,"documentID":"\(document)","role":"searchable"}],
                 "documents":[{"id":"\(document)","ownerFileID":"\(file)","fields":{}}],"fileFields":{}}
                """.utf8))
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Box"),
                                                    withIntermediateDirectories: true)
            let source = root.appendingPathComponent("Source.pdf")
            let packet = Data("""
                <x:xmpmeta xmlns:x="adobe:ns:meta/">
                <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                </rdf:RDF></x:xmpmeta>
                """.utf8)
            let identity = CataloguePDFIdentity(fileID: file, contentRevision: content)
            let metadata = try #require(identity.adding(to: packet))
            var bounds = CGRect(x: 0, y: 0, width: 60, height: 60)
            let pdf = try #require(CGContext(source as CFURL, mediaBox: &bounds, nil))
            pdf.addDocumentMetadata(metadata as CFData)
            pdf.beginPDFPage(nil)
            pdf.fill(bounds.insetBy(dx: 10, dy: 10))
            pdf.endPDFPage()
            pdf.closePDF()
            pdfBytes = try Data(contentsOf: source)
            try FileManager.default.copyItem(at: input, to: pendingPDF)
        }

        func reader(rootID: UUID? = nil) throws -> CatalogueReader {
            try CatalogueReader(grantedRoot: root, rootInstanceID: rootID ?? occurrence.rootInstanceID,
                                mode: .adopted, identifyPDF: CataloguePDFIdentity.identify)
        }

        func file(with filer: CataloguePairFiler? = nil) throws -> CataloguePairFiler.Receipt {
            try (filer ?? CataloguePairFiler(reader: reader())).filePair(operationID: id, at: occurrence, record: record)
        }

        func recover(with filer: CataloguePairFiler? = nil) throws -> CataloguePairFiler.Receipt {
            try (filer ?? CataloguePairFiler(reader: reader())).recoverPair(operationID: id, at: occurrence)
        }

        func stop(at cut: CataloguePairFiler.Boundary) throws {
            let filer = CataloguePairFiler(reader: try reader()) { reached in
                if reached == cut { throw Stop.interrupted }
            }
            #expect(throws: Stop.interrupted) { try file(with: filer) }
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }
}
