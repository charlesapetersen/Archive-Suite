import ArchiveCore
import Foundation

// MARK: - Improve OCR and Restore keep the catalogue record (W49.proc-item-fields-rerun)

/// What Improve OCR and Restore do to a file's catalogue companion (owner calls 24 and 32; `SPEC/improve-ocr.md` §5,
/// `SPEC/catalogue-fields.md` §"Processor output and history"). New text is new content, so an accepted candidate
/// carries a new content generation of the same file in its XMP identity, and after publication the companion is moved
/// to it by `CatalogueWriter.advanceContentRevision`, which changes nothing else: every correction, clear, check and
/// evidence entry the Reader wrote, before or after the run, stays as it is. Improve OCR reads text only, so it makes
/// no new field observation to add as evidence; the replaced text page keeps its old header lines, which are history.
/// Restore puts back the old bytes, which carry the old generation, and moves the companion back the same way.
///
/// A file whose PDF carries an identity but whose pair cannot be verified (companion missing, offline, damaged, newer,
/// naming another generation, or outside an adopted root the Processor can read) is improved as before: the PDF keeps
/// its identity, the companion is not touched, and the review says why.
enum ReOCRCatalogue {
    enum Plan: Equatable, Sendable {
        /// The PDF carries no catalogue identity.
        case none
        /// A verified pair: the candidate carries `step.to`, and the companion follows after publication.
        case advance(Step)
        /// The pair cannot be verified; nothing catalogue-related changes.
        case unresolved(String)

        /// Shown with the review.
        var summary: String? {
            switch self {
            case .none: nil
            case .advance: "Catalogue record: its corrections stay; it is moved to the new text when you accept."
            case .unresolved(let why): "Catalogue record not updated: \(why)."
            }
        }
    }

    /// A move of the companion at `relativePath` under `rootPath` from content generation `from` to `to`.
    struct Step: Codable, Equatable, Sendable {
        let rootPath: String
        let relativePath: String
        let fileID: UUID
        let from: UUID
        let to: UUID

        /// Restore's step: back to the generation the kept original carries.
        var reversed: Step { Step(rootPath: rootPath, relativePath: relativePath, fileID: fileID, from: to, to: from) }
    }

    enum Outcome: Codable, Equatable, Sendable {
        case updated
        /// Refused for a reason a retry cannot change (the PDF or companion is no longer the one planned): settled.
        case refused(String)
        /// Retried by launch recovery.
        case failed(String)

        var isSettled: Bool { if case .failed = self { false } else { true } }

        /// Appended to the accept or restore message; nil when the record was updated.
        var problem: String? {
            switch self {
            case .updated: nil
            case .refused(let why): "Its catalogue record was not moved to the new text (\(why))."
            case .failed(let why):
                "Its catalogue record is not moved to the new text yet (\(why)); it will be retried at the next launch."
            }
        }
    }

    /// The plan for the file at `relativePath` under `root`, whose bytes are `snapshot` (the verified copy a review
    /// reads). Reads only, without downloading anything.
    static func plan(root: URL, relativePath: String, snapshot: Data) -> Plan {
        guard let document = ReOCRPreservationCheck.document(snapshot),
              let identity = CataloguePDFIdentity.identity(in: document) else { return .none }
        let facts: Result<ItemFacts.FileFacts, ItemFacts.Unavailable>
        do {
            let reader = try CatalogueReader(grantedRoot: root, rootInstanceID: UUID(), mode: .adopted,
                                             identifyPDF: CataloguePDFIdentity.identify)
            facts = reader.snapshot(.init(relativePDFPaths: [], isComplete: false), including: [relativePath])
                .facts(at: relativePath).file
        } catch {
            return .unresolved("the archive folder could not be read")
        }
        switch facts {
        case .success(let file):
            guard file.revision.fileID == identity.fileID, file.revision.content == identity.contentRevision else {
                return .unresolved("it names another version of this file")
            }
            return .advance(Step(rootPath: root.path, relativePath: relativePath, fileID: identity.fileID,
                                 from: identity.contentRevision, to: UUID()))
        case .failure(let why):
            return .unresolved(describe(why))
        }
    }

    /// `candidate` (already verified against the original) as the step's new generation.
    static func stamp(_ candidate: Data, for step: Step) throws -> Data {
        try SearchableArchival.nextGeneration(
            of: candidate, replacing: CataloguePDFIdentity(fileID: step.fileID, contentRevision: step.from),
            with: CataloguePDFIdentity(fileID: step.fileID, contentRevision: step.to))
    }

    /// Moves the companion once the PDF at the step's path proves `step.to`. Safe to repeat.
    static func settle(_ step: Step) -> Outcome {
        do {
            let reader = try CatalogueReader(grantedRoot: URL(fileURLWithPath: step.rootPath, isDirectory: true),
                                             rootInstanceID: UUID(), mode: .adopted,
                                             identifyPDF: CataloguePDFIdentity.identify)
            let occurrence = CatalogueAssociation.Occurrence(rootInstanceID: reader.rootInstanceID,
                                                             relativePath: step.relativePath)
            _ = try CatalogueWriter(reader: reader).advanceContentRevision(at: occurrence, fileID: step.fileID,
                                                                          from: step.from, to: step.to)
            return .updated
        } catch let refusal as CatalogueWriter.ContentRevisionRefusal {
            switch refusal {
            case .pdfNotAtNewRevision: return .refused("the file is no longer the text that was put in place")
            case .companionNotAtExpectedRevision: return .refused("the record names another version of this file")
            case .pageCountChanged: return .refused("the record lists a different number of pages")
            }
        } catch let unavailable as ItemFacts.Unavailable {
            return .failed(describe(unavailable))
        } catch {
            return .failed("\(error)")
        }
    }

    static func describe(_ why: ItemFacts.Unavailable) -> String {
        switch why {
        case .legacy, .incompleteInventory: "the archive folder does not use catalogue records"
        case .offline: "it is not downloaded, and Improve OCR does not download it"
        case .missing(.companion): "its catalogue record is missing"
        case .missing: "the file or its folder is missing"
        case .invalid(.companion): "its catalogue record could not be read"
        case .invalid(.pdf): "the file does not match its catalogue record"
        case .invalid: "the archive folder could not be checked"
        case .ambiguous: "more than one file claims this record"
        case .newer: "its catalogue record was written by a newer version of the suite"
        }
    }
}
