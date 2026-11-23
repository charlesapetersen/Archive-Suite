import CryptoKit
import Darwin
import Foundation

extension CatalogueReader {
    /// Local evidence about a pair previously verified together. Contains neither metadata values nor PDF data.
    public struct RememberedPair: Codable, Equatable, Sendable {
        public let relativePath: String
        public let fileID: UUID
        /// Key for retaining at most one observation per physical PDF, even if two copies share a catalogue ID.
        public var physicalKey: String {
            let id = pdfVersion.identity
            return "\(id.device):\(id.inode):\(id.birthSeconds):\(id.birthNanoseconds)"
        }
        fileprivate let contentRevision: UUID
        fileprivate let pageCount: Int
        fileprivate let rootIdentity: CatalogueReadDirectory.Identity
        fileprivate let pdfVersion: CatalogueReadDirectory.FileVersion
        fileprivate let companionVersion: CatalogueReadDirectory.FileVersion
        fileprivate let companionSHA256: Data

        init(_ facts: ItemFacts.FileFacts, relativePath: String? = nil) {
            self.relativePath = relativePath ?? facts.pair.occurrence.relativePath
            self.fileID = facts.revision.fileID
            self.contentRevision = facts.revision.content
            self.pageCount = facts.pair.record.pages.count
            self.rootIdentity = facts.rootIdentity
            self.pdfVersion = facts.pdfVersion
            self.companionVersion = facts.companionVersion
            self.companionSHA256 = facts.revision.companionSHA256
        }
    }

    public struct ReassociationCandidate: Sendable {
        public var formerRelativePath: String { remembered.relativePath }
        public var formerPair: RememberedPair { remembered }
        public let destination: CatalogueAssociation.Occurrence
        fileprivate let remembered: RememberedPair
    }

    /// A read-only probe for an explicit user offer. Revalidating under the writer lock is still required.
    /// The lookup uses the PDF identity read from the descriptor, with physical identity checked independently below.
    public func reassociationCandidate(at relativePath: String,
                                       remembered lookup: (UUID) throws -> [RememberedPair]) throws
        -> ReassociationCandidate? {
        let occurrence = CatalogueAssociation.Occurrence(rootInstanceID: rootInstanceID, relativePath: relativePath)
        return try withOccurrence(occurrence) { root, parent, filename in
            let candidates = try withProvenPDF(filename, in: parent, at: occurrence) { pdf, proof in
                let rootIdentity = CatalogueReadDirectory.Identity(root.info)
                let version = CatalogueReadDirectory.FileVersion(pdf.info)
                return try lookup(proof.fileID).filter {
                    $0.rootIdentity == rootIdentity && version.matchesAcrossRename($0.pdfVersion)
                        && !$0.relativePath.utf8.elementsEqual(relativePath.utf8)
                }
            }
            guard candidates.count == 1, let prior = candidates.first else { return nil }
            let candidate = ReassociationCandidate(destination: occurrence, remembered: prior)
            try CatalogueWriter(reader: self).verifyReassociation(candidate)
            return candidate
        }
    }
}

extension CatalogueWriter {
    public struct ReassociationReceipt: Sendable {
        public let formerPDF: CatalogueAssociation.Occurrence
        public let current: ItemFacts.FileFacts
    }

    /// Repair an adjacent companion after a same-directory PDF rename, on explicit user action.
    /// The caller supplies the last verified pair from before the rename and the observed new path.
    /// A scan of detached files cannot construct this authority from a matching UUID or filename.
    public func reassociateCompanion(from base: ItemFacts.FileFacts, to renamed: CatalogueAssociation.Occurrence)
        throws -> ReassociationReceipt {
        guard base.pair.occurrence.rootInstanceID == renamed.rootInstanceID else {
            throw ItemFacts.Unavailable.invalid(.root)
        }
        return try reassociateCompanion(.init(destination: renamed, remembered: .init(base)))
    }

    public func reassociateCompanion(_ candidate: CatalogueReader.ReassociationCandidate) throws -> ReassociationReceipt {
        let current = try moveCompanion(candidate, undo: false)
        return ReassociationReceipt(formerPDF: .init(rootInstanceID: candidate.destination.rootInstanceID,
                                                    relativePath: candidate.formerRelativePath),
                                    current: current)
    }

    /// Return the unchanged companion to its former name. The PDF remains at its new path.
    /// A changed PDF or companion, or a new occupant at the former name, refuses the undo.
    /// The result carries the refreshed file versions needed to redo this particular repair.
    @discardableResult
    public func undoReassociation(_ receipt: ReassociationReceipt) throws -> CatalogueReader.ReassociationCandidate {
        let remembered = CatalogueReader.RememberedPair(receipt.current, relativePath: receipt.formerPDF.relativePath)
        let candidate = CatalogueReader.ReassociationCandidate(destination: receipt.current.pair.occurrence,
                                                              remembered: remembered)
        let restored = try moveCompanion(candidate, undo: true)
        return .init(destination: candidate.destination,
                     remembered: .init(restored, relativePath: candidate.formerRelativePath))
    }

    fileprivate func verifyReassociation(_ candidate: CatalogueReader.ReassociationCandidate) throws {
        let names = try ReassociationNames(candidate, undo: false)
        try reader.withOccurrence(candidate.destination) { root, parent, _ in
            let (pdf, companion) = try reassociationSource(candidate, names: names, root: root, parent: parent, undo: false)
            try validateReassociationNames(names, pdf: pdf, companion: companion.version, root: root, parent: parent)
        }
    }

    private struct ReassociationNames {
        let formerPDF: String
        let renamedPDF: String
        let source: String
        let target: String
        let sourcePDF: String

        init(_ candidate: CatalogueReader.ReassociationCandidate, undo: Bool) throws {
            let former = candidate.formerRelativePath
            let renamed = candidate.destination.relativePath
            guard !former.utf8.elementsEqual(renamed.utf8),
                  let oldParts = CatalogueReader.pathComponents(former), let oldPDF = oldParts.last,
                  let newParts = CatalogueReader.pathComponents(renamed), let newPDF = newParts.last,
                  oldParts.dropLast().elementsEqual(newParts.dropLast(), by: { $0.utf8.elementsEqual($1.utf8) }) else {
                throw ItemFacts.Unavailable.invalid(.pdf)
            }
            formerPDF = oldPDF
            renamedPDF = newPDF
            let oldCompanion = CatalogueRecord.companionFilename(forPDFFilename: oldPDF)
            let newCompanion = CatalogueRecord.companionFilename(forPDFFilename: newPDF)
            source = undo ? newCompanion : oldCompanion
            target = undo ? oldCompanion : newCompanion
            sourcePDF = undo ? newPDF : oldPDF
        }
    }

    private func reassociationSource(_ candidate: CatalogueReader.ReassociationCandidate, names: ReassociationNames,
                                     root: CatalogueReadDirectory.Entry, parent: CatalogueReadDirectory.Entry,
                                     undo: Bool) throws -> (CatalogueReadDirectory.FileVersion, ReadRecord) {
        try reader.validateScope(root: root, parent: parent)
        let remembered = candidate.remembered
        guard CatalogueReadDirectory.Identity(root.info) == remembered.rootIdentity else {
            throw ItemFacts.Unavailable.invalid(.root)
        }
        let pdfVersion = try reader.withProvenPDF(names.renamedPDF, in: parent, at: candidate.destination) { pdf, proof in
            guard proof.fileID == remembered.fileID, proof.contentRevision == remembered.contentRevision,
                  proof.pageCount == remembered.pageCount else { throw ItemFacts.Unavailable.invalid(.pdf) }
            let version = CatalogueReadDirectory.FileVersion(pdf.info)
            guard undo ? version == remembered.pdfVersion : version.matchesAcrossRename(remembered.pdfVersion) else {
                throw ItemFacts.Unavailable.ambiguous(.pdf)
            }
            return version
        }
        let source = try readRecord(names.source, in: parent)
        guard source.version == remembered.companionVersion,
              Data(SHA256.hash(data: source.record.originalJSON)) == remembered.companionSHA256 else {
            throw Failure.changedDuringSave
        }
        return (pdfVersion, source)
    }

    private func validateReassociationNames(_ names: ReassociationNames, pdf: CatalogueReadDirectory.FileVersion,
                                            companion: CatalogueReadDirectory.FileVersion,
                                            root: CatalogueReadDirectory.Entry, parent: CatalogueReadDirectory.Entry) throws {
        try reader.validateScope(root: root, parent: parent)
        guard try nameVersion(names.renamedPDF, in: parent) == pdf,
              try nameVersion(names.source, in: parent) == companion else { throw Failure.changedDuringSave }
        try requireVacantOrAlias(names.formerPDF, of: pdf, in: parent, artifact: .pdf)
        try requireVacantOrAlias(names.target, of: companion, in: parent, artifact: .companion)
        try requireWritableCompanion(names.source, in: parent)
    }

    private func moveCompanion(_ candidate: CatalogueReader.ReassociationCandidate, undo: Bool) throws -> ItemFacts.FileFacts {
        let names = try ReassociationNames(candidate, undo: undo)
        let renamed = candidate.destination
        var moved = false
        do {
            return try reader.withOccurrence(renamed) { root, parent, _ in
                try withLock(on: parent) {
                    let (pdfVersion, before) = try reassociationSource(candidate, names: names, root: root, parent: parent, undo: undo)
                    try boundary(.beforeReassociation)
                    try validateReassociationNames(names, pdf: pdfVersion, companion: before.version, root: root, parent: parent)
                    try claimCompanionName(names.source, as: names.target, in: parent)
                    moved = true

                    do {
                        try boundary(.reassociated)
                        try reader.validateScope(root: root, parent: parent)
                        let after = try verifyMove(from: names.source, to: names.target, of: before, in: parent)
                        try requireVacantOrAlias(names.formerPDF, of: pdfVersion, in: parent, artifact: .pdf)
                        let verified = try reader.withProvenPDF(names.renamedPDF, in: parent, at: renamed) { pdf, proof in
                            guard CatalogueReadDirectory.FileVersion(pdf.info) == pdfVersion else { throw Failure.changedDuringSave }
                            return try reader.fileFacts(after.record, at: renamed, proof: proof, pdf: pdf,
                                                        companionVersion: after.version)
                        }
                        guard try nameVersion(names.target, in: parent) == after.version else { throw Failure.changedDuringSave }
                        try sync(parent.descriptor, operation: "flush companion reassociation")
                        return verified
                    } catch {
                        // Reverse only our exact move. Leave both names alone when an outside writer
                        // put a different companion or PDF in the way.
                        try reader.validateScope(root: root, parent: parent)
                        let current = try verifyMove(from: names.source, to: names.target, of: before, in: parent)
                        try requireVacantOrAlias(names.sourcePDF, of: pdfVersion, in: parent, artifact: .pdf)
                        guard try nameVersion(names.target, in: parent) == current.version else { throw Failure.changedDuringSave }
                        try claimCompanionName(names.target, as: names.source, in: parent)
                        _ = try verifyMove(from: names.target, to: names.source, of: before, in: parent)
                        try requireVacantOrAlias(names.sourcePDF, of: pdfVersion, in: parent, artifact: .pdf)
                        try reader.validateScope(root: root, parent: parent)
                        try sync(parent.descriptor, operation: "flush reversed companion reassociation")
                        moved = false
                        throw error
                    }
                }
            }
        } catch {
            if moved {
                throw Failure.recoveryRequired(artifact: names.target,
                                               reason: "Check both \(names.source) and \(names.target). \(error)")
            }
            throw error
        }
    }

    private func verifyMove(from source: String, to target: String, of before: ReadRecord,
                            in parent: CatalogueReadDirectory.Entry) throws -> ReadRecord {
        let current = try readRecord(target, in: parent)
        guard current.version.matchesAcrossRename(before.version),
              current.record.originalJSON == before.record.originalJSON else { throw Failure.changedDuringSave }
        try requireVacantOrAlias(source, of: current.version, in: parent, artifact: .companion)
        return current
    }

    private func nameVersion(_ name: String, in parent: CatalogueReadDirectory.Entry) throws
        -> CatalogueReadDirectory.FileVersion? {
        var info = stat()
        if fstatat(parent.descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return .init(info) }
        let code = errno
        if code == ENOENT { return nil }
        throw Failure.io(operation: "inspect reassociation name", code: code)
    }

    private func requireVacantOrAlias(_ name: String, of verified: CatalogueReadDirectory.FileVersion,
                                      in parent: CatalogueReadDirectory.Entry, artifact: ItemFacts.Artifact) throws {
        // A case-only Finder rename on a case-insensitive volume can resolve under both
        // spellings. The verified entry was opened at its exact path and has just one link.
        if let occupied = try nameVersion(name, in: parent), occupied != verified {
            throw ItemFacts.Unavailable.ambiguous(artifact)
        }
    }

    private func claimCompanionName(_ source: String, as target: String, in parent: CatalogueReadDirectory.Entry) throws {
        guard renameatx_np(parent.descriptor, source, parent.descriptor, target, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            if code == EEXIST { throw ItemFacts.Unavailable.ambiguous(.companion) }
            throw Failure.io(operation: "rename catalogue companion", code: code)
        }
    }
}
