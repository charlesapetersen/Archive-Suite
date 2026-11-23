import Foundation

extension CatalogueWriter {
    /// A local journal reference to one verified write and the exact fields it changed.
    /// The retained companion, not this reference, provides the former values.
    public struct Inverse: Codable, Sendable {
        public let occurrence: CatalogueAssociation.Occurrence
        public let beforeRevision: UUID
        public let afterRevision: UUID
        let root: CatalogueReadDirectory.Identity
        let pdf: CatalogueReadDirectory.FileVersion
        let fileID: UUID
        let content: UUID
        let targets: [CatalogueEdit.Target]
        let artifact: String
        let beforeDigest: String
        let afterDigest: String

        init(before: ItemFacts.FileFacts, after: ItemFacts.FileFacts, targets: [CatalogueEdit.Target],
             artifact: CatalogueEditArtifact) {
            self.targets = targets
            self.artifact = artifact.name
            occurrence = after.pair.occurrence
            beforeRevision = before.revision.facts
            afterRevision = after.revision.facts
            root = after.rootIdentity
            pdf = after.pdfVersion
            fileID = after.revision.fileID
            content = after.revision.content
            beforeDigest = artifact.before
            afterDigest = artifact.after
        }
    }

    public enum UndoRefusal: Error, Equatable, Sendable {
        case changedOccurrence
        case unverifiedHistory
        case changedFields([CatalogueEdit.Target])
    }

    /// Restore only the former envelopes this operation changed. Later unrelated edits survive.
    /// The returned inverse describes exactly what Redo can reverse using the same checks.
    public func reverse(_ inverse: Inverse, basedOn base: ItemFacts.FileFacts) throws -> Receipt {
        guard base.pair.occurrence == inverse.occurrence, base.rootIdentity == inverse.root,
              base.pdfVersion.matchesAcrossRename(inverse.pdf), base.revision.fileID == inverse.fileID,
              base.revision.content == inverse.content else { throw UndoRefusal.changedOccurrence }
        guard !inverse.targets.isEmpty, Set(inverse.targets).count == inverse.targets.count else {
            throw UndoRefusal.unverifiedHistory
        }
        return try commit(targets: inverse.targets, basedOn: base) { live, scope in
            let records = try undoRecords(for: inverse, current: live.pair.record, in: scope)
            guard try CatalogueEditPatch.changedTargets(inverse.targets, before: records.before,
                                                        after: records.after) == inverse.targets else {
                throw UndoRefusal.unverifiedHistory
            }
            return try CatalogueEditPatch.restoring(inverse.targets, before: records.before, after: records.after,
                                                     current: live.pair.record)
        }
    }
}
