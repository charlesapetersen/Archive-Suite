import Darwin
import Foundation

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
        let former = base.pair.occurrence
        let current = try moveCompanion(basedOn: base, former: former, renamed: renamed, undo: false)
        return ReassociationReceipt(formerPDF: former, current: current)
    }

    /// Return the unchanged companion to its former name. The PDF remains at its new path.
    /// A changed PDF or companion, or a new occupant at the former name, refuses the undo.
    public func undoReassociation(_ receipt: ReassociationReceipt) throws {
        _ = try moveCompanion(basedOn: receipt.current, former: receipt.formerPDF,
                              renamed: receipt.current.pair.occurrence, undo: true)
    }

    private func moveCompanion(basedOn base: ItemFacts.FileFacts, former: CatalogueAssociation.Occurrence,
                               renamed: CatalogueAssociation.Occurrence, undo: Bool) throws -> ItemFacts.FileFacts {
        guard former.rootInstanceID == renamed.rootInstanceID, former != renamed,
              let oldParts = CatalogueReader.pathComponents(former.relativePath), let oldPDF = oldParts.last,
              let newParts = CatalogueReader.pathComponents(renamed.relativePath), let newPDF = newParts.last,
              oldParts.dropLast().elementsEqual(newParts.dropLast(), by: { $0.utf8.elementsEqual($1.utf8) }) else {
            throw ItemFacts.Unavailable.invalid(.pdf)
        }
        let oldCompanion = CatalogueRecord.companionFilename(forPDFFilename: oldPDF)
        let newCompanion = CatalogueRecord.companionFilename(forPDFFilename: newPDF)
        let source = undo ? newCompanion : oldCompanion
        let target = undo ? oldCompanion : newCompanion
        let sourcePDF = undo ? newPDF : oldPDF
        let expectedRecord = base.pair.record

        var moved = false
        do {
            return try reader.withOccurrence(renamed) { root, parent, _ in
                try withLock(on: parent) {
                    try reader.validateScope(root: root, parent: parent)
                    guard CatalogueReadDirectory.Identity(root.info) == base.rootIdentity else {
                        throw ItemFacts.Unavailable.invalid(.root)
                    }
                    let pdfVersion = try reader.withProvenPDF(newPDF, in: parent, at: renamed,
                                                             expectedBase: undo ? base : nil) { pdf, proof in
                        do {
                            _ = try CatalogueAssociation.pair(expectedRecord, at: renamed, verifiedBy: proof)
                        } catch {
                            throw CatalogueReader.companionStatus(error)
                        }
                        let version = CatalogueReadDirectory.FileVersion(pdf.info)
                        guard version.matchesAcrossRename(base.pdfVersion) else {
                            throw ItemFacts.Unavailable.ambiguous(.pdf)
                        }
                        return version
                    }
                    let before = try readRecord(source, in: parent)
                    guard before.version == base.companionVersion, before.record.originalJSON == expectedRecord.originalJSON else {
                        throw Failure.changedDuringSave
                    }

                    try boundary(.beforeReassociation)
                    try reader.validateScope(root: root, parent: parent)
                    guard try nameVersion(newPDF, in: parent) == pdfVersion,
                          try nameVersion(source, in: parent) == before.version else { throw Failure.changedDuringSave }
                    try requireVacantOrAlias(oldPDF, of: pdfVersion, in: parent, artifact: .pdf)
                    try requireVacantOrAlias(target, of: before.version, in: parent, artifact: .companion)
                    try requireWritableCompanion(source, in: parent)
                    try claimCompanionName(source, as: target, in: parent)
                    moved = true

                    do {
                        try boundary(.reassociated)
                        try reader.validateScope(root: root, parent: parent)
                        let after = try verifyMove(from: source, to: target, of: before, in: parent)
                        try requireVacantOrAlias(oldPDF, of: pdfVersion, in: parent, artifact: .pdf)
                        let verified = try reader.withProvenPDF(newPDF, in: parent, at: renamed) { pdf, proof in
                            guard CatalogueReadDirectory.FileVersion(pdf.info) == pdfVersion else { throw Failure.changedDuringSave }
                            return try reader.fileFacts(after.record, at: renamed, proof: proof, pdf: pdf,
                                                        companionVersion: after.version)
                        }
                        guard try nameVersion(target, in: parent) == after.version else { throw Failure.changedDuringSave }
                        try sync(parent.descriptor, operation: "flush companion reassociation")
                        return verified
                    } catch {
                        // Reverse only our exact move. Leave both names alone when an outside writer
                        // put a different companion or PDF in the way.
                        try reader.validateScope(root: root, parent: parent)
                        let current = try verifyMove(from: source, to: target, of: before, in: parent)
                        try requireVacantOrAlias(sourcePDF, of: pdfVersion, in: parent, artifact: .pdf)
                        guard try nameVersion(target, in: parent) == current.version else { throw Failure.changedDuringSave }
                        try claimCompanionName(target, as: source, in: parent)
                        _ = try verifyMove(from: target, to: source, of: before, in: parent)
                        try requireVacantOrAlias(sourcePDF, of: pdfVersion, in: parent, artifact: .pdf)
                        try reader.validateScope(root: root, parent: parent)
                        try sync(parent.descriptor, operation: "flush reversed companion reassociation")
                        moved = false
                        throw error
                    }
                }
            }
        } catch {
            if moved {
                throw Failure.recoveryRequired(artifact: target,
                                               reason: "Check both \(source) and \(target). \(error)")
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
