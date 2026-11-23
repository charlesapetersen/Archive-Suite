import Darwin
import Foundation
import PDFKit
import Testing
@testable import ArchiveCore

@Suite("Guarded companion saves", .timeLimit(.minutes(1)))
struct CatalogueWriterTests {
    @Test func independentWritersPreserveThreeDisjointEditsOnOneBase() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let base = try fixture.selection()
        let edits: [CatalogueEdit] = [
            .init(.document(fixture.document, .title), .set(.text("Lettre 東京"))),
            .init(.file(.quality), .set(.rating(3))),
            .init(.file(.flagged), .set(.flag(true))),
        ]
        let revisions = try await withThrowingTaskGroup(of: UUID.self) { group in
            for edit in edits {
                group.addTask {
                    let writer = CatalogueWriter(reader: try fixture.reader())
                    return try writer.save([edit], basedOn: base).after.revision.facts
                }
            }
            var outcomes: [UUID] = []
            for try await revision in group { outcomes.append(revision) }
            return outcomes
        }
        #expect(Set(revisions).count == 3)
        let refreshed = try fixture.selection()
        #expect(try title(refreshed.pair.record) == "Lettre 東京")
        if case .value(3)? = refreshed.pair.record.fileFields.quality?.current {} else { Issue.record("Quality was lost") }
        if case .value(true)? = refreshed.pair.record.fileFields.flagged?.current {} else { Issue.record("Flag was lost") }
        let recoveries = try CatalogueWriter(reader: fixture.reader()).recoveries(at: base.pair.occurrence)
        #expect(recoveries.artifacts.map(\.state) == [.published, .published, .published])
        #expect(try Data(contentsOf: fixture.pdf) == fixture.pdfBytes)
    }

    @Test func sameFieldConflictsRetainCurrentAndProposedValues() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let writer = CatalogueWriter(reader: try fixture.reader())
        let base = try fixture.selection()
        let target = CatalogueEdit.Target.document(fixture.document, .title)
        let receipt = try writer.save([.init(target, .set(.text("First")))], basedOn: base)
        do {
            _ = try writer.save([.init(target, .set(.text("Second")))], basedOn: base)
            Issue.record("Stale change overwrote the current title")
        } catch let conflict as CatalogueWriter.Conflict {
            #expect(conflict.reason == .overlappingFields([target]))
            #expect(try title(conflict.current.pair.record) == "First")
            #expect(try title(conflict.proposed) == "Second")
        }
        #expect(try fixture.selection().revision == receipt.after.revision)
        #expect(try Data(contentsOf: fixture.pdf) == fixture.pdfBytes)
    }

    @Test func persistedInverseRestoresOnlyTouchedEnvelopeAndSupportsRedo() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let writer = CatalogueWriter(reader: try fixture.reader())
        let target = CatalogueEdit.Target.document(fixture.document, .title)
        let original = try writer.save([.init(target, .set(.text("Original")))], basedOn: fixture.selection())
        let checked = try writer.save([.init(target, .check(true))], basedOn: original.after)
        let revised = try writer.save([.init(target, .set(.text("Revised")))], basedOn: checked.after)
        let inverse = try #require(revised.inverse)
        let encoded = try JSONEncoder().encode(inverse)
        let durable = try JSONDecoder().decode(CatalogueWriter.Inverse.self, from: encoded)
        _ = try writer.save([.init(.file(.quality), .set(.rating(3)))], basedOn: revised.after)

        let reopened = CatalogueWriter(reader: try fixture.reader())
        let undo = try reopened.reverse(durable, basedOn: fixture.selection())
        #expect(try title(undo.after.pair.record) == "Original")
        let restored = try #require(undo.after.pair.record.documents.first?.fields?.title)
        let previous = try #require(checked.after.pair.record.documents.first?.fields?.title)
        #expect(restored.isChecked && restored.fieldRevision == previous.fieldRevision)
        if case .value(3)? = undo.after.pair.record.fileFields.quality?.current {} else { Issue.record("Quality was lost") }

        let redo = try reopened.reverse(#require(undo.inverse), basedOn: fixture.selection())
        #expect(try title(redo.after.pair.record) == "Revised")
        #expect(redo.after.pair.record.documents.first?.fields?.title?.isChecked == false)
        if case .value(3)? = redo.after.pair.record.fileFields.quality?.current {} else { Issue.record("Quality was lost") }
        #expect(try Data(contentsOf: fixture.pdf) == fixture.pdfBytes)
    }

    @Test func viewRotationUpdatesOnlyTheSelectedCataloguePageAndCanBeUndone() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let writer = CatalogueWriter(reader: try fixture.reader())
        let base = try fixture.selection()
        let page = try #require(base.pair.record.pages.first)
        let target = CatalogueEdit.Target.pageViewRotation(page.id)
        #expect(throws: CatalogueEdit.Invalid.incompatibleValue(target)) {
            try writer.save([.init(target, .set(.rotation(45)))], basedOn: base)
        }
        let turned = try writer.save([.init(target, .set(.rotation(90)))], basedOn: base)
        #expect(turned.after.pair.record.pages.first?.viewRotation == 90)
        let inverse = try #require(turned.inverse)
        let undo = try writer.reverse(inverse, basedOn: fixture.selection())
        #expect(undo.after.pair.record.pages.first?.viewRotation == nil)
        #expect(undo.after.pair.record.pages.first?.id == page.id)
        #expect(try Data(contentsOf: fixture.pdf) == fixture.pdfBytes)
    }

    @Test func inverseRefusesAChangedFieldAndPhysicalReplacement() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let writer = CatalogueWriter(reader: try fixture.reader())
        let target = CatalogueEdit.Target.document(fixture.document, .title)
        let first = try writer.save([.init(target, .set(.text("First")))], basedOn: fixture.selection())
        let inverse = try #require(first.inverse)
        let second = try writer.save([.init(target, .set(.text("External change")))], basedOn: first.after)
        #expect(throws: CatalogueWriter.UndoRefusal.changedFields([target])) {
            try writer.reverse(inverse, basedOn: fixture.selection())
        }
        try fixture.pdfBytes.write(to: fixture.pdf, options: .atomic)
        #expect(throws: CatalogueWriter.UndoRefusal.changedOccurrence) {
            try writer.reverse(#require(second.inverse), basedOn: fixture.selection())
        }
        #expect(try Data(contentsOf: fixture.companion) == second.after.pair.record.originalJSON)
    }

    @Test func replayedAndContradictoryRevisionsRefuseAStaleEdit() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let writer = CatalogueWriter(reader: try fixture.reader())
        let base = try fixture.selection()
        let edit = CatalogueEdit(.file(.quality), .set(.rating(3)))
        let receipt = try writer.save([edit], basedOn: base)
        try base.pair.record.originalJSON.write(to: fixture.companion, options: .atomic)
        try expectUnverifiedHistory(try writer.save([edit], basedOn: receipt.after))
        var contradictory = base.pair.record.originalJSON
        contradictory.append(32) // Same revision, different exact bytes.
        try contradictory.write(to: fixture.companion, options: .atomic)
        try expectUnverifiedHistory(try writer.save([edit], basedOn: base))
        #expect(try Data(contentsOf: fixture.companion) == contradictory)
    }

    @Test func replacementWithIdenticalPDFBytesRefusesTheOldPhysicalSelection() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let reader = try fixture.reader()
        let base = try fixture.selection()
        try fixture.pdfBytes.write(to: fixture.pdf, options: .atomic)
        let writer = CatalogueWriter(reader: reader)
        #expect(throws: ItemFacts.Unavailable.invalid(.pdf)) {
            try writer.save([.init(.file(.flagged), .set(.flag(true)))], basedOn: base)
        }
        #expect(try Data(contentsOf: fixture.companion) == base.pair.record.originalJSON)
    }

    @Test func pairedCopyAndReadOnlyCompanionRemainUntouched() throws {
        let fixture = try Fixture()
        let other = try Fixture()
        defer {
            fixture.cleanUp()
            other.cleanUp()
        }
        let base = try fixture.selection()
        try fixture.pdfBytes.write(to: other.pdf, options: .atomic)
        try base.pair.record.originalJSON.write(to: other.companion, options: .atomic)
        let copyWriter = CatalogueWriter(reader: try other.reader(rootID: fixture.rootID))
        #expect(throws: ItemFacts.Unavailable.invalid(.root)) {
            try copyWriter.save([.init(.file(.flagged), .set(.flag(true)))], basedOn: base)
        }
        let writer = CatalogueWriter(reader: try fixture.reader())
        let edit = CatalogueEdit(.file(.flagged), .set(.flag(true)))
        guard chmod(fixture.companion.path, 0o444) == 0 else { throw POSIXError(.EPERM) }
        #expect(throws: CatalogueWriter.Failure.self) { try writer.save([edit], basedOn: base) }
        #expect(try writer.recoveries(at: base.pair.occurrence).artifacts.isEmpty)
        #expect(try Data(contentsOf: fixture.companion) == base.pair.record.originalJSON)
        #expect(try Data(contentsOf: other.companion) == base.pair.record.originalJSON)
    }

    @Test func closedAndReopenedWriterFindsBothInterruptionBoundaries() throws {
        for (boundary, state): (CatalogueWriter.Boundary, CatalogueWriter.Recovery.State) in [
            (.staged, .staged), (.exchanged, .published),
        ] {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            let base = try fixture.selection()
            let cutter = CatalogueWriter(reader: try fixture.reader()) { reached in
                if reached == boundary { throw Interruption.stop }
            }
            let artifact = try recoveryArtifact(from: cutter, fixture: fixture, base: base)
            let restarted = CatalogueWriter(reader: try fixture.reader())
            let report = try restarted.recoveries(at: base.pair.occurrence)
            let entry = try #require(report.artifacts.first)
            #expect(report.artifacts.count == 1 && entry.state == state && entry.artifact == artifact)
            let retained = try restarted.retainedRecord(named: artifact, at: base.pair.occurrence)
            #expect(entry.retainedRevision == retained.revision)
            if state == .staged {
                #expect(try report.live.get().revision == base.revision)
                #expect(try title(retained) == "Revised")
            } else {
                #expect(try title(report.live.get().pair.record) == "Revised")
                #expect(retained.originalJSON == base.pair.record.originalJSON)
            }

            try FileManager.default.removeItem(at: fixture.companion)
            let missing = try restarted.recoveries(at: base.pair.occurrence)
            guard case .failure(.missing(.companion)) = missing.live else {
                Issue.record("Missing live companion went unreported")
                continue
            }
            #expect(missing.artifacts.first?.retainedRevision == retained.revision)
            #expect(try restarted.retainedRecord(named: artifact, at: base.pair.occurrence).originalJSON == retained.originalJSON)
            #expect(try Data(contentsOf: fixture.pdf) == fixture.pdfBytes)
        }
    }

    @Test func exchangeDetectsAndRetainsAWriteThatBypassedTheLock() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let base = try fixture.selection()
        let outsider = try CatalogueEditPatch(edits: [.init(.file(.ocrPoor), .set(.flag(true)))])
            .applying(to: base.pair.record)
        let writer = CatalogueWriter(reader: try fixture.reader()) { reached in
            if reached == .beforeExchange {
                try outsider.originalJSON.write(to: fixture.companion, options: .atomic)
            }
        }
        let artifact = try recoveryArtifact(from: writer, fixture: fixture, base: base)
        let report = try writer.recoveries(at: base.pair.occurrence)
        #expect(try report.live.get().pair.record.originalJSON == outsider.originalJSON)
        #expect(report.artifacts.first?.artifact == artifact)
        #expect(report.artifacts.first?.state == .diverged)
        #expect(try title(writer.retainedRecord(named: artifact, at: base.pair.occurrence)) == "Revised")
        #expect(try Data(contentsOf: fixture.pdf) == fixture.pdfBytes)
    }

    @Test(arguments: [false, true])
    func racedNewerCompanionStaysAtItsOriginalName(displacedAfterExchange: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let base = try fixture.selection()
        let newer = Data(#"{"schema":2}"#.utf8)
        let writer = CatalogueWriter(reader: try fixture.reader()) { reached in
            if displacedAfterExchange, reached == .exchanged {
                // Exercise rollback with the same occupants as a writer slipping past the last stat.
                let names = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
                let name = try #require(names.first(where: { $0.hasPrefix(".archivesuite-edit-") }))
                try newer.write(to: fixture.root.appendingPathComponent(name), options: .atomic)
            } else if !displacedAfterExchange, reached == .beforeExchange {
                try newer.write(to: fixture.companion, options: .atomic)
            }
        }
        let artifact = try recoveryArtifact(from: writer, fixture: fixture, base: base)
        let report = try writer.recoveries(at: base.pair.occurrence)
        guard case .failure(.newer(schema: 2)) = report.live else {
            Issue.record("A newer companion lost the canonical name")
            return
        }
        #expect(try Data(contentsOf: fixture.companion) == newer)
        #expect(try title(writer.retainedRecord(named: artifact, at: base.pair.occurrence)) == "Revised")
        #expect(try Data(contentsOf: fixture.pdf) == fixture.pdfBytes)
    }

    @Test func pdfReplacedDuringExchangeRollsBackAndCannotClaimOldRecovery() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let base = try fixture.selection()
        let writer = CatalogueWriter(reader: try fixture.reader()) { reached in
            if reached == .exchanged {
                try fixture.pdfBytes.write(to: fixture.pdf, options: .atomic)
            }
        }
        let artifact = try recoveryArtifact(from: writer, fixture: fixture, base: base)
        let reopened = CatalogueWriter(reader: try fixture.reader())
        #expect(try Data(contentsOf: fixture.companion) == base.pair.record.originalJSON)
        #expect(try Data(contentsOf: fixture.pdf) == fixture.pdfBytes)
        #expect(try reopened.recoveries(at: base.pair.occurrence).artifacts.isEmpty)
        #expect(throws: ItemFacts.Unavailable.invalid(.companion)) {
            try reopened.retainedRecord(named: artifact, at: base.pair.occurrence)
        }
        let savedCandidate = try CatalogueRecord(json: Data(contentsOf: fixture.root.appendingPathComponent(artifact)))
        #expect(try title(savedCandidate) == "Revised")
    }

    @Test(arguments: [false, true])
    func unreadableStagedDataCannotReplaceTheCompanion(replaceInode: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let base = try fixture.selection()
        let bad = Data("partial stage".utf8)
        let writer = CatalogueWriter(reader: try fixture.reader()) { reached in
            if reached == .beforeExchange {
                let names = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
                let artifact = try #require(names.first(where: { $0.hasPrefix(".archivesuite-edit-") }))
                try bad.write(to: fixture.root.appendingPathComponent(artifact), options: replaceInode ? .atomic : [])
            }
        }
        let artifact = try recoveryArtifact(from: writer, fixture: fixture, base: base)
        let report = try writer.recoveries(at: base.pair.occurrence)
        #expect(try report.live.get().revision == base.revision)
        #expect(report.artifacts.first?.state == .incomplete)
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent(artifact)) == bad)
    }

    @Test func movedRootRefusesExchangeInTheDetachedDirectory() throws {
        let fixture = try Fixture()
        let moved = fixture.root.appendingPathExtension("moved")
        defer {
            fixture.cleanUp()
            try? FileManager.default.removeItem(at: moved)
        }
        let base = try fixture.selection()
        let writer = CatalogueWriter(reader: try fixture.reader()) { reached in
            if reached == .beforeExchange { try FileManager.default.moveItem(at: fixture.root, to: moved) }
        }
        let artifact = try recoveryArtifact(from: writer, fixture: fixture, base: base)
        let companion = moved.appendingPathComponent(fixture.companion.lastPathComponent)
        #expect(try Data(contentsOf: companion) == base.pair.record.originalJSON)
        let candidate = try CatalogueRecord(json: Data(contentsOf: moved.appendingPathComponent(artifact)))
        #expect(try title(candidate) == "Revised")
    }

    private func expectUnverifiedHistory(_ operation: @autoclosure () throws -> CatalogueWriter.Receipt) throws {
        do {
            _ = try operation()
            Issue.record("Unexpectedly accepted an unverified base")
        } catch let conflict as CatalogueWriter.Conflict {
            #expect(conflict.reason == .unverifiedHistory)
        }
    }

    private func recoveryArtifact(from writer: CatalogueWriter, fixture: Fixture, base: ItemFacts.FileFacts) throws -> String {
        do {
            _ = try writer.save([.init(.document(fixture.document, .title), .set(.text("Revised")))], basedOn: base)
            throw Interruption.stop
        } catch CatalogueWriter.Failure.recoveryRequired(let artifact, _) {
            return artifact
        }
    }

    private func title(_ record: CatalogueRecord) throws -> String? {
        guard case .value(let value)? = record.documents.first?.fields?.title?.current else { return nil }
        return value
    }

    private enum Interruption: Error { case stop }

    private struct Fixture: Sendable {
        let root: URL
        let pdf: URL
        let companion: URL
        let pdfBytes: Data
        let rootID = UUID()
        let document = UUID()
        let path = "Letter.PDF"

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("catalogue-writer-\(UUID())")
            pdf = root.appendingPathComponent(path)
            companion = root.appendingPathComponent(CatalogueRecord.companionFilename(forPDFFilename: path))
            let file = UUID()
            let content = UUID()
            let documentPDF = PDFDocument()
            documentPDF.insert(PDFPage(), at: 0)
            documentPDF.documentAttributes = [PDFDocumentAttribute.titleAttribute: file.uuidString,
                                              PDFDocumentAttribute.subjectAttribute: content.uuidString]
            pdfBytes = try #require(documentPDF.dataRepresentation())
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try pdfBytes.write(to: pdf)
            try Data("""
            {"schema":1,"fileID":"\(file)","contentRevision":"\(content)","revision":"\(UUID())","parents":[],
             "pages":[{"id":"\(UUID())","physicalIndex":0,"documentID":"\(document)","role":"searchable"}],
             "documents":[{"id":"\(document)","ownerFileID":"\(file)","fields":{}}],"fileFields":{}}
            """.utf8).write(to: companion)
        }

        func reader(rootID: UUID? = nil) throws -> CatalogueReader {
            try CatalogueReader(grantedRoot: root, rootInstanceID: rootID ?? self.rootID, mode: .adopted) { fd, _ in
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                guard let bytes = try handle.readToEnd(), let pdf = PDFDocument(data: bytes),
                      let attributes = pdf.documentAttributes,
                      let file = attributes[PDFDocumentAttribute.titleAttribute] as? String, let fileID = UUID(uuidString: file),
                      let content = attributes[PDFDocumentAttribute.subjectAttribute] as? String, let contentID = UUID(uuidString: content) else {
                    return nil
                }
                return .init(fileID: fileID, contentRevision: contentID, pageCount: pdf.pageCount)
            }
        }

        func selection() throws -> ItemFacts.FileFacts {
            try reader().snapshot(.init(relativePDFPaths: [path], isComplete: true)).facts(at: path).file.get()
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }
}
