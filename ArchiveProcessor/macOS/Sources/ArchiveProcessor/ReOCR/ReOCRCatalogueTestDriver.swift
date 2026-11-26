#if DEBUG // a test driver, compiled out of Release
import ArchiveCore
import Foundation
import PDFKit

/// Part of `ReOCRJobTestDriver` (`scripts/test-reocr-job.sh`), $0 and scratch-only: Improve OCR and Restore keep the
/// catalogue record (W49.proc-item-fields-rerun, owner calls 24 and 32). Each fixture is a real catalogue filing
/// (`ReOCRImageInputTestDriver.fixture`) whose companion the Reader's own `CatalogueWriter.save` corrects.
///
///   19a. A correction, a clear and a check made before the run survive acceptance; the PDF and the companion both
///        name the new content generation, and nothing else in the record changes.
///   19b. A correction made after acceptance survives Restore; Restore puts the original bytes back and moves the
///        companion back to the old generation.
///   19c. A file whose companion is missing is improved as before: the review says why, the PDF keeps its identity.
///   19d. A companion move that fails after publication is retried by launch recovery, which reports it; until then
///        History keeps the operation's record.
@MainActor
enum ReOCRCatalogueTestDriver {
    typealias Check = ReOCRImageInputTestDriver.Check

    private static let model = LLMModel.geminiModels[0]

    static func run(in base: URL, check: Check) async {
        do {
            try await runCases(in: base, check: check)
        } catch {
            check("19 catalogue fixtures", false, "\(error)")
        }
    }

    /// The pair's facts as the Reader sees them; one reader per fixture, since an edit's selection names its root instance.
    private static func facts(_ reader: CatalogueReader) throws -> ItemFacts.FileFacts {
        try reader.snapshot(.init(relativePDFPaths: ["Letter.pdf"], isComplete: true)).facts(at: "Letter.pdf").file.get()
    }

    private static func reader(_ dir: URL) throws -> CatalogueReader {
        try CatalogueReader(grantedRoot: dir, rootInstanceID: UUID(), mode: .adopted,
                            identifyPDF: CataloguePDFIdentity.identify)
    }

    private static func identity(_ url: URL) -> CataloguePDFIdentity? {
        (try? Data(contentsOf: url)).flatMap(ReOCRPreservationCheck.document).flatMap(CataloguePDFIdentity.identity(in:))
    }

    /// Every top-level key of the two records but the three a content move owns, compared as canonical JSON.
    private static func sameExceptGeneration(_ a: CatalogueRecord, _ b: CatalogueRecord) -> Bool {
        let owned: Set<String> = ["contentRevision", "revision", "parents"]
        guard let x = try? JSONSerialization.jsonObject(with: a.originalJSON) as? [String: Any],
              let y = try? JSONSerialization.jsonObject(with: b.originalJSON) as? [String: Any],
              Set(x.keys) == Set(y.keys) else { return false }
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .fragmentsAllowed]
        return x.keys.filter { !owned.contains($0) }.allSatisfy { key in
            (try? JSONSerialization.data(withJSONObject: x[key]!, options: options))
                == (try? JSONSerialization.data(withJSONObject: y[key]!, options: options))
        }
    }

    private static func runCases(in base: URL, check report: Check) async throws {
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") { report(name, ok, ok ? "" : detail()) }
        let fm = FileManager.default
        func fixture(_ name: String, seed: Int) throws -> ReOCRImageInputTestDriver.Fixture {
            let dir = base.appendingPathComponent("19-\(name)", isDirectory: true)
            let intake = dir.appendingPathComponent("intake", isDirectory: true)
            try fm.createDirectory(at: intake, withIntermediateDirectories: true)
            guard let picture = ReOCRImageInputTestDriver.picture(seed: seed, width: 600, height: 800) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let original = intake.appendingPathComponent("IMG.jpg")
            try ReOCRImageInputTestDriver.writeJPEG(picture, to: original)
            return try ReOCRImageInputTestDriver.fixture(dir, pages: [(original, original, 0)])
        }

        // 19a. Corrections before the run survive acceptance.
        let a = try fixture("accept", seed: 21)
        let originalBytes = try Data(contentsOf: a.file)
        let readerA = try reader(a.dir)
        let filed = try facts(readerA)
        let oldIdentity = identity(a.file)
        let writer = CatalogueWriter(reader: readerA)
        guard let document = filed.pair.record.documents.first?.id else { throw CocoaError(.fileReadCorruptFile) }
        let title = CatalogueEdit.Target.document(document, .title)
        let corrected = try writer.save([.init(title, .set(.text("Corrected title"))),
                                         .init(.document(document, .recipientPlaces), .clear)], basedOn: filed)
        let checked = try writer.save([.init(title, .check(true))], basedOn: corrected.after)
        let before = checked.after.pair.record

        let review = try await a.job.start(file: a.file, root: a.root, model: model, read: ReOCRImageInputTestDriver.Reader().read)
        guard case .advance(let step) = review.catalogue else {
            check("19a a verified pair plans a move of its record", false, "\(review.catalogue)"); return
        }
        check("19a the move starts at the filed generation", step.from == before.contentRevision && step.fileID == before.fileID)
        check("19a the review says the corrections stay", review.catalogue.summary?.contains("corrections stay") == true)
        check("19a the file is unchanged before accept", (try? Data(contentsOf: a.file)) == originalBytes)
        let done = try a.job.accept(review)
        check("19a the record is moved", done.catalogue == .updated, "\(String(describing: done.catalogue))")
        check("19a the new text is published",
              PDFDocument(url: a.file)?.page(at: 1)?.string?.contains("Read from the original of page 1.") == true)
        check("19a the PDF names the new generation of the same file",
              identity(a.file) == CataloguePDFIdentity(fileID: step.fileID, contentRevision: step.to),
              "\(String(describing: identity(a.file)))")
        let accepted = try facts(readerA)
        let after = accepted.pair.record
        check("19a the record names the new generation", after.contentRevision == step.to && after.parents == [before.revision])
        check("19a every correction, clear, check and evidence entry is unchanged", sameExceptGeneration(before, after))
        check("19a the title's check stays", after.documents.first?.fields?.title?.isChecked == true)

        // 19b. A correction after acceptance survives Restore.
        let later = try writer.save([.init(.file(.quality), .set(.rating(2)))], basedOn: accepted)
        let restored = try a.job.restore(done.journal.operationID)
        check("19b the record is moved back", restored.catalogue == .updated, "\(String(describing: restored.catalogue))")
        check("19b the original bytes are back", (try? Data(contentsOf: a.file)) == originalBytes)
        check("19b the PDF names the old generation again", identity(a.file) == oldIdentity)
        let back = try facts(readerA).pair.record
        check("19b the record names the old generation", back.contentRevision == before.contentRevision)
        check("19b the later correction and the earlier ones stay", sameExceptGeneration(later.after.pair.record, back))
        if case .value(2)? = back.fileFields.quality?.current {} else { check("19b the later rating stays", false) }

        // 19c. No companion: improved as before, the PDF keeps its identity, the review says why.
        let c = try fixture("missing", seed: 22)
        let cIdentity = identity(c.file)
        try fm.removeItem(at: c.dir.appendingPathComponent(CatalogueRecord.companionFilename(forPDFFilename: "Letter.pdf")))
        let reviewC = try await c.job.start(file: c.file, root: c.root, model: model, read: ReOCRImageInputTestDriver.Reader().read)
        check("19c a missing record is named", reviewC.catalogue == .unresolved("its catalogue record is missing"),
              "\(reviewC.catalogue)")
        let doneC = try c.job.accept(reviewC)
        check("19c no record move is attempted", doneC.catalogue == nil)
        check("19c the PDF keeps its identity", cIdentity != nil && identity(c.file) == cIdentity)

        // 19d. A move cut off after publication: the companion read-only, then launch recovery finishes it.
        let d = try fixture("recover", seed: 23)
        let dIdentity = identity(d.file)
        let companion = d.dir.appendingPathComponent(CatalogueRecord.companionFilename(forPDFFilename: "Letter.pdf"))
        let reviewD = try await d.job.start(file: d.file, root: d.root, model: model, read: ReOCRImageInputTestDriver.Reader().read)
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: companion.path)
        let doneD = try d.job.accept(reviewD)
        let failed: Bool = { if case .failed? = doneD.catalogue { true } else { false } }()
        check("19d a move that cannot be made now is left for recovery", failed, "\(String(describing: doneD.catalogue))")
        let history = ReOCRHistory(writer: d.job.writer)
        let pending = history.entries().first { $0.id == doneD.journal.operationID }
        check("19d History keeps the pending move's record", pending?.catalogueUnsettled == true && pending?.canRemove == false)
        do { try history.remove(doneD.journal.operationID); check("19d Remove is refused while the move is pending", false) }
        catch { check("19d Remove is refused while the move is pending",
                      (error as? ReOCRHistory.Failure) == .catalogueUnsettled, "\(error)") }
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: companion.path)
        let recoveries = d.job.recover()
        check("19d recovery reports the move", recoveries.first { $0.operationID == doneD.journal.operationID }?.catalogue == .updated,
              "\(recoveries.map(\.catalogue))")
        check("19d a settled move can be removed from History",
              history.entries().first { $0.id == doneD.journal.operationID }?.canRemove == true)
        check("19d a second recovery does not try it again",
              d.job.recover().first { $0.operationID == doneD.journal.operationID }?.catalogue == nil)
        let recovered = try facts(reader(d.dir)).pair.record
        check("19d launch recovery moves the record", identity(d.file)?.contentRevision == recovered.contentRevision
              && recovered.contentRevision != dIdentity?.contentRevision, "\(recovered.contentRevision)")
    }
}
#endif
