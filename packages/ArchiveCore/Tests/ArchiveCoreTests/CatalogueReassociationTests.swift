import CoreGraphics
import Foundation
import Testing
@testable import ArchiveCore

@Suite("Guarded catalogue companion reassociation", .timeLimit(.minutes(1)))
struct CatalogueReassociationTests {
    @Test(arguments: ["Renamed.pdf", "letter.pdf"])
    func renameKeepsTheExactCorrectionAndUndoLeavesThePDFAlone(newName: String) throws {
        let fixture = try Fixture(newName: newName)
        defer { fixture.cleanUp() }
        try fixture.renamePDF()
        let detached = fixture.reader.discover().facts(at: newName)
        if newName == "Renamed.pdf" {
            #expect(throws: ItemFacts.Unavailable.missing(.companion)) { try detached.file.get() }
        } else {
            #expect(throws: ItemFacts.Unavailable.self) { try detached.file.get() }
        }

        let receipt = try fixture.reassociate()
        let current = try fixture.selection(at: newName)
        #expect(current.revision == receipt.current.revision)
        #expect(current.pair.record.originalJSON == fixture.record.originalJSON)
        #expect(try Data(contentsOf: fixture.renamedPDF) == fixture.pdfBytes)

        try fixture.writer.undoReassociation(receipt)
        #expect(throws: ItemFacts.Unavailable.self) { try fixture.selection(at: newName) }
        #expect(try Data(contentsOf: fixture.oldCompanion) == fixture.record.originalJSON)
        #expect(try Data(contentsOf: fixture.renamedPDF) == fixture.pdfBytes)
    }

    @Test func unrelatedReplacementAtTheFormerNameCannotReadTheCorrectionOrAuthorizeARepair() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.renamePDF()
        try fixture.writePDF(at: fixture.oldPDF, identity: .init(fileID: UUID(), contentRevision: UUID()))

        #expect(throws: ItemFacts.Unavailable.invalid(.pdf)) { try fixture.selection(at: "Letter.pdf") }
        #expect(throws: ItemFacts.Unavailable.ambiguous(.pdf)) { try fixture.reassociate() }
        #expect(try Data(contentsOf: fixture.oldCompanion) == fixture.record.originalJSON)
        #expect(!FileManager.default.fileExists(atPath: fixture.newCompanion.path))
    }

    @Test(arguments: [true, false])
    func substituteAtTheRenamedPathCannotBorrowTheCorrection(identicalBytes: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try FileManager.default.moveItem(at: fixture.oldPDF, to: fixture.root.appendingPathComponent("Held.pdf"))
        if identicalBytes {
            try fixture.pdfBytes.write(to: fixture.renamedPDF)
        } else {
            try fixture.writePDF(at: fixture.renamedPDF, identity: .init(fileID: UUID(), contentRevision: UUID()))
        }

        let unavailable: ItemFacts.Unavailable = identicalBytes ? .ambiguous(.pdf) : .invalid(.pdf)
        #expect(throws: unavailable) { try fixture.reassociate() }
        #expect(throws: ItemFacts.Unavailable.missing(.companion)) { try fixture.selection(at: "Renamed.pdf") }
        #expect(try Data(contentsOf: fixture.oldCompanion) == fixture.record.originalJSON)
    }

    @Test func aCompetingCompanionAndChangedSourceArePreserved() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.renamePDF()
        let writer = CatalogueWriter(reader: fixture.reader) { reached in
            if reached == .beforeReassociation {
                try fixture.record.originalJSON.write(to: fixture.newCompanion)
            }
        }
        #expect(throws: ItemFacts.Unavailable.ambiguous(.companion)) {
            try writer.reassociateCompanion(from: fixture.base, to: fixture.destination)
        }
        #expect(try Data(contentsOf: fixture.newCompanion) == fixture.record.originalJSON)

        try FileManager.default.removeItem(at: fixture.newCompanion)
        try fixture.record.originalJSON.write(to: fixture.oldCompanion, options: .atomic)
        #expect(throws: CatalogueWriter.Failure.changedDuringSave) { try fixture.reassociate() }
        #expect(try Data(contentsOf: fixture.oldCompanion) == fixture.record.originalJSON)
        #expect(!FileManager.default.fileExists(atPath: fixture.newCompanion.path))
    }

    @Test func readOnlyCompanionIsLeftInPlace() throws {
        let fixture = try Fixture(companionPermissions: 0o444)
        defer { fixture.cleanUp() }
        try fixture.renamePDF()
        do {
            _ = try fixture.reassociate()
            Issue.record("Expected the read-only companion to refuse repair")
        } catch CatalogueWriter.Failure.io(let operation, _) {
            #expect(operation == "check companion write access")
        }
        #expect(try Data(contentsOf: fixture.oldCompanion) == fixture.record.originalJSON)
        #expect(!FileManager.default.fileExists(atPath: fixture.newCompanion.path))
    }

    @Test func undoRefusesToDetachLaterCorrections() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.renamePDF()
        let receipt = try fixture.reassociate()
        let edit = CatalogueEdit(.file(.quality), .set(.rating(3)))
        let saved = try fixture.writer.save([edit], basedOn: receipt.current)

        #expect(throws: CatalogueWriter.Failure.changedDuringSave) { try fixture.writer.undoReassociation(receipt) }
        #expect(try fixture.selection(at: "Renamed.pdf").revision == saved.after.revision)
        #expect(!FileManager.default.fileExists(atPath: fixture.oldCompanion.path))
    }

    @Test func replacementDuringPublishRestoresTheCompanionWhenTheFormerNameIsVacant() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.renamePDF()
        let writer = CatalogueWriter(reader: fixture.reader) { reached in
            if reached == .reassociated {
                try fixture.pdfBytes.write(to: fixture.renamedPDF, options: .atomic)
            }
        }

        #expect(throws: CatalogueWriter.Failure.changedDuringSave) {
            try writer.reassociateCompanion(from: fixture.base, to: fixture.destination)
        }
        #expect(try Data(contentsOf: fixture.oldCompanion) == fixture.record.originalJSON)
        #expect(throws: ItemFacts.Unavailable.missing(.companion)) { try fixture.selection(at: "Renamed.pdf") }
    }

    @Test func rollbackNeverOverwritesACompetingRecord() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.renamePDF()
        let competing = Data("competing bytes".utf8)
        let writer = CatalogueWriter(reader: fixture.reader) { reached in
            if reached == .reassociated {
                try competing.write(to: fixture.oldCompanion)
            }
        }

        do {
            _ = try writer.reassociateCompanion(from: fixture.base, to: fixture.destination)
            Issue.record("Expected reassociation recovery to be required")
        } catch CatalogueWriter.Failure.recoveryRequired(let artifact, _) {
            #expect(artifact == fixture.newCompanion.lastPathComponent)
        }
        #expect(try Data(contentsOf: fixture.oldCompanion) == competing)
        #expect(try Data(contentsOf: fixture.newCompanion) == fixture.record.originalJSON)
    }

    private struct Fixture: Sendable {
        let root: URL
        let newName: String
        let reader: CatalogueReader
        let base: ItemFacts.FileFacts
        let pdfBytes: Data
        let record: CatalogueRecord

        var oldPDF: URL { root.appendingPathComponent("Letter.pdf") }
        var renamedPDF: URL { root.appendingPathComponent(newName) }
        var oldCompanion: URL { root.appendingPathComponent(CatalogueRecord.companionFilename(forPDFFilename: "Letter.pdf")) }
        var newCompanion: URL { root.appendingPathComponent(CatalogueRecord.companionFilename(forPDFFilename: newName)) }
        var writer: CatalogueWriter { CatalogueWriter(reader: reader) }
        var destination: CatalogueAssociation.Occurrence {
            .init(rootInstanceID: reader.rootInstanceID, relativePath: newName)
        }

        init(newName: String = "Renamed.pdf", companionPermissions: Int = 0o600) throws {
            self.newName = newName
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("catalogue-rename-\(UUID())")
            self.root = root
            let identity = CataloguePDFIdentity(fileID: UUID(), contentRevision: UUID())
            let document = UUID()
            let initial = try CatalogueRecord(json: Data("""
                {"schema":1,"fileID":"\(identity.fileID)","contentRevision":"\(identity.contentRevision)","revision":"\(UUID())",
                 "parents":[],"pages":[{"id":"\(UUID())","physicalIndex":0,"documentID":"\(document)","role":"searchable"}],
                 "documents":[{"id":"\(document)","ownerFileID":"\(identity.fileID)","fields":{}}],"fileFields":{}}
                """.utf8))
            record = try CatalogueEditPatch(edits: [.init(.document(document, .title), .set(.text("Corrected title")))])
                .applying(to: initial)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let pdf = root.appendingPathComponent("Letter.pdf")
            try Self.makePDF(at: pdf, identity: identity)
            pdfBytes = try Data(contentsOf: pdf)
            let companion = root.appendingPathComponent("Letter.pdf.archivesuite.json")
            try record.originalJSON.write(to: companion)
            try FileManager.default.setAttributes([.posixPermissions: companionPermissions], ofItemAtPath: companion.path)
            reader = try CatalogueReader(grantedRoot: root, rootInstanceID: UUID(), mode: .adopted,
                                         identifyPDF: CataloguePDFIdentity.identify)
            base = try reader.discover().facts(at: "Letter.pdf").file.get()
        }

        func renamePDF() throws {
            // Use the same filesystem rename for ordinary and case-only Finder changes.
            try FileManager.default.moveItem(at: oldPDF, to: renamedPDF)
        }

        func writePDF(at url: URL, identity: CataloguePDFIdentity) throws {
            try Self.makePDF(at: url, identity: identity)
        }

        func selection(at path: String) throws -> ItemFacts.FileFacts {
            try reader.discover(including: [path]).facts(at: path).file.get()
        }

        func reassociate() throws -> CatalogueWriter.ReassociationReceipt {
            try writer.reassociateCompanion(from: base, to: destination)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }

        private static func makePDF(at url: URL, identity: CataloguePDFIdentity) throws {
            let packet = Data("""
                <x:xmpmeta xmlns:x="adobe:ns:meta/">
                <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                </rdf:RDF></x:xmpmeta>
                """.utf8)
            let metadata = try #require(identity.adding(to: packet))
            var bounds = CGRect(x: 0, y: 0, width: 60, height: 60)
            let pdf = try #require(CGContext(url as CFURL, mediaBox: &bounds, nil))
            pdf.addDocumentMetadata(metadata as CFData)
            pdf.beginPDFPage(nil)
            pdf.fill(bounds.insetBy(dx: 10, dy: 10))
            pdf.endPDFPage()
            pdf.closePDF()
        }
    }
}
