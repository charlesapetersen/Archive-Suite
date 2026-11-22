import Foundation

public enum CatalogueAssociation {
    /// The root instance identifies this granted replica, even if a copied root has the same marker GUID.
    /// Discovery supplies the canonical relative path after checking scope and filesystem aliases.
    public struct Occurrence: Hashable, Sendable {
        public let rootInstanceID: UUID
        public let relativePath: String

        public init(rootInstanceID: UUID, relativePath: String) {
            self.rootInstanceID = rootInstanceID
            self.relativePath = relativePath
        }
    }

    /// Positive proof from the selected PDF's embedded Suite identity or a verified explicit association.
    /// Discovery must obtain this independently of the candidate JSON, with fresh filesystem guards.
    public struct VerifiedPDF: Sendable {
        public let occurrence: Occurrence
        public let fileID: UUID
        public let contentRevision: UUID
        public let pageCount: Int

        public init(occurrence: Occurrence, fileID: UUID, contentRevision: UUID, pageCount: Int) {
            self.occurrence = occurrence
            self.fileID = fileID
            self.contentRevision = contentRevision
            self.pageCount = pageCount
        }
    }

    public enum Unavailable: Error, Equatable {
        case missingCompanion
        case unverifiedPDF
        case mismatchedPDF
        case unknownDocument
        case missingOwner
        case ambiguousOwner
        case invalidOwner
    }

    /// A resolved pair is specific to its occurrence. Copying the pair preserves IDs on disk, while
    /// its different occurrence keeps future commits and link resolution scoped to the selected copy.
    public struct Pair: Sendable {
        public let occurrence: Occurrence
        public let record: CatalogueRecord

        fileprivate init(occurrence: Occurrence, record: CatalogueRecord) {
            self.occurrence = occurrence
            self.record = record
        }

        public func owner(of documentID: UUID, among candidates: [Pair]) throws -> Pair {
            guard let document = record.document(id: documentID) else { throw Unavailable.unknownDocument }
            return try owner(of: document.id, inFile: document.ownerFileID, among: candidates)
        }

        /// Resolve an explicit relationship, such as an enclosure, with the same ownership rules.
        public func owner(of reference: CatalogueRecord.DocumentReference, among candidates: [Pair]) throws -> Pair {
            try owner(of: reference.documentID, inFile: reference.ownerFileID, among: candidates)
        }

        private func owner(of documentID: UUID, inFile fileID: UUID, among candidates: [Pair]) throws -> Pair {
            let owner: Pair
            if fileID == record.fileID {
                owner = self
            } else {
                let matches = candidates.filter {
                    $0.occurrence.rootInstanceID == occurrence.rootInstanceID && $0.record.fileID == fileID
                }
                guard let match = matches.first else { throw Unavailable.missingOwner }
                guard matches.count == 1 else { throw Unavailable.ambiguousOwner }
                owner = match
            }
            guard let document = owner.record.document(id: documentID), document.ownerFileID == fileID else {
                throw Unavailable.invalidOwner
            }
            return owner
        }
    }

    /// This checks an already discovered candidate. It performs no I/O and cannot repair a name pair.
    public static func pair(_ record: CatalogueRecord?, at occurrence: Occurrence,
                            verifiedBy pdf: VerifiedPDF?) throws -> Pair {
        guard let record else { throw Unavailable.missingCompanion }
        guard let pdf, pdf.occurrence == occurrence else { throw Unavailable.unverifiedPDF }
        guard pdf.fileID == record.fileID, pdf.contentRevision == record.contentRevision,
              pdf.pageCount == record.pages.count else { throw Unavailable.mismatchedPDF }
        return Pair(occurrence: occurrence, record: record)
    }
}
