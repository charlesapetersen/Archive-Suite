import Foundation

/// A content operation (the Processor's Improve OCR and its Restore) replaces a paired PDF's bytes with a new
/// generation. The PDF then proves the new `contentRevision` and its companion still names the old one, so the pair
/// reads as mismatched until this step moves the companion to the generation the PDF proves. Only
/// `contentRevision`, `revision` and `parents` change: every field, clear, check, evidence entry, page and extension
/// is carried byte for byte, so a correction made before or after the operation survives it.
extension CatalogueWriter {
    public enum ContentRevisionRefusal: Error, Sendable, Equatable {
        /// The PDF at the occurrence does not prove this file at the new generation.
        case pdfNotAtNewRevision
        /// The companion names another file or a generation other than the expected old or new one.
        case companionNotAtExpectedRevision(found: UUID)
        /// The PDF's page count differs from the companion's pages; a page change needs its own regrouping step.
        case pageCountChanged
    }

    public struct ContentRevisionReceipt: Sendable {
        /// The verified pair at the new generation.
        public let after: ItemFacts.FileFacts
        /// Nil when the companion already named the new generation. The named sibling keeps the exact before-image.
        public let recoveryArtifact: String?
    }

    /// Moves the companion at `occurrence` from content generation `old` to `new`, once the PDF there independently
    /// proves `fileID` at `new` with the companion's page count. Idempotent: a companion already at `new` is verified
    /// and left as it is, so a recovery can repeat the step. Runs under the same parent lock and exchange as `save`.
    public func advanceContentRevision(at occurrence: CatalogueAssociation.Occurrence, fileID: UUID,
                                       from old: UUID, to new: UUID) throws -> ContentRevisionReceipt {
        var recoveryArtifact: String?
        do {
            return try reader.withOccurrence(occurrence) { root, parent, filename in
                try withLock(on: parent) {
                    let companion = CatalogueRecord.companionFilename(forPDFFilename: filename)
                    func provenPDF() throws -> (version: CatalogueReadDirectory.FileVersion,
                                                proof: CatalogueAssociation.VerifiedPDF) {
                        try reader.validateScope(root: root, parent: parent)
                        do {
                            return try reader.withProvenPDF(filename, in: parent, at: occurrence) { entry, proof in
                                (CatalogueReadDirectory.FileVersion(entry.info), proof)
                            }
                        } catch ItemFacts.Unavailable.invalid(.pdf) {
                            throw ContentRevisionRefusal.pdfNotAtNewRevision
                        }
                    }
                    func facts(_ live: ReadRecord, pdf: CatalogueReadDirectory.FileVersion,
                               proof: CatalogueAssociation.VerifiedPDF) throws -> ItemFacts.FileFacts {
                        try reader.withProvenPDF(filename, in: parent, at: occurrence) { entry, _ in
                            guard CatalogueReadDirectory.FileVersion(entry.info) == pdf else { throw Failure.changedDuringSave }
                            return try reader.fileFacts(live.record, at: occurrence, proof: proof, pdf: entry,
                                                        companionVersion: live.version)
                        }
                    }

                    let pdf = try provenPDF()
                    guard pdf.proof.fileID == fileID, pdf.proof.contentRevision == new else {
                        throw ContentRevisionRefusal.pdfNotAtNewRevision
                    }
                    let live = try readRecord(companion, in: parent)
                    guard live.record.fileID == fileID else {
                        throw ContentRevisionRefusal.companionNotAtExpectedRevision(found: live.record.contentRevision)
                    }
                    guard live.record.pages.count == pdf.proof.pageCount else { throw ContentRevisionRefusal.pageCountChanged }
                    if live.record.contentRevision == new {
                        return ContentRevisionReceipt(after: try facts(live, pdf: pdf.version, proof: pdf.proof),
                                                      recoveryArtifact: nil)
                    }
                    guard live.record.contentRevision == old else {
                        throw ContentRevisionRefusal.companionNotAtExpectedRevision(found: live.record.contentRevision)
                    }

                    var json = try CatalogueJSON.Object(live.record.originalJSON)
                    let encoder = JSONEncoder()
                    json["contentRevision"] = try encoder.encode(new)
                    json["revision"] = try encoder.encode(UUID())
                    json["parents"] = try encoder.encode([live.record.revision])
                    let candidate = try CatalogueRecord(json: json.encoded())
                    _ = try CatalogueAssociation.pair(candidate, at: occurrence, verifiedBy: pdf.proof)

                    let artifact = CatalogueEditArtifact(filename: filename, pdf: pdf.version.identity,
                                                         before: live.record, after: candidate)
                    let staged = try stage(candidate, as: artifact.name, replacing: live.version, companion: companion,
                                           root: root, parent: parent) {
                        recoveryArtifact = artifact.name
                    }
                    try boundary(.staged)
                    let latest = try readRecord(companion, in: parent)
                    guard latest.version == live.version, latest.record.originalJSON == live.record.originalJSON,
                          try provenPDF().version == pdf.version else {
                        throw Failure.changedDuringSave
                    }
                    let candidateFile = try readRecord(artifact.name, in: parent)
                    guard candidateFile.version == staged, candidateFile.record.originalJSON == candidate.originalJSON else {
                        throw Failure.changedDuringSave
                    }
                    try boundary(.beforeExchange)
                    try reader.validateScope(root: root, parent: parent)
                    guard try version(of: filename, in: parent) == pdf.version,
                          try version(of: companion, in: parent) == live.version,
                          try version(of: artifact.name, in: parent) == staged else {
                        throw Failure.changedDuringSave
                    }
                    try exchange(artifact.name, with: companion, in: parent)
                    try boundary(.exchanged)
                    try reader.validateScope(root: root, parent: parent)

                    let published = try version(of: companion, in: parent)
                    guard published.identity == staged.identity else { throw Failure.changedDuringSave }
                    let displaced = try version(of: artifact.name, in: parent)
                    let verified: ItemFacts.FileFacts
                    do {
                        let prior = try readRecord(artifact.name, in: parent)
                        guard prior.version == displaced, prior.version.identity == live.version.identity,
                              prior.record.originalJSON == live.record.originalJSON else {
                            throw Failure.changedDuringSave
                        }
                        let now = try readRecord(companion, in: parent)
                        guard now.version == published, now.record.originalJSON == candidate.originalJSON else {
                            throw Failure.changedDuringSave
                        }
                        verified = try facts(now, pdf: pdf.version, proof: pdf.proof)
                    } catch {
                        try restore(published: published, displaced: displaced, artifact: artifact.name,
                                    companion: companion, root: root, parent: parent)
                        throw error
                    }
                    try sync(parent.descriptor, operation: "flush exchange")
                    return ContentRevisionReceipt(after: verified, recoveryArtifact: artifact.name)
                }
            }
        } catch {
            if let recoveryArtifact {
                throw Failure.recoveryRequired(artifact: recoveryArtifact, reason: String(describing: error))
            }
            throw error
        }
    }
}
