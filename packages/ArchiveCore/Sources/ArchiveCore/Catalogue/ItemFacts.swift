import Foundation

/// Shared read result for one PDF selection. File facts remain available if the selected
/// document or its enclosure cannot be resolved.
public struct ItemFacts: Sendable {
    public enum Artifact: Hashable, Sendable { case root, pdf, companion, document, owner }

    public enum Unavailable: Error, Hashable, Sendable {
        case legacy
        case offline(Artifact)
        case missing(Artifact)
        case invalid(Artifact)
        case ambiguous(Artifact)
        case newer(schema: Int)
        case incompleteInventory
    }

    public struct Revision: Hashable, Sendable {
        public let occurrence: CatalogueAssociation.Occurrence
        public let fileID: UUID
        public let content: UUID
        public let facts: UUID
        // Also detect contradictory contents claiming the same revision, even at the same mtime.
        public let companionSHA256: Data
    }

    public struct FileFacts: Sendable {
        public let pair: CatalogueAssociation.Pair
        public let revision: Revision
    }

    public struct DocumentFacts: Sendable {
        public let owner: FileFacts
        public let document: CatalogueRecord.Document
    }

    public let file: Result<FileFacts, Unavailable>
    public let page: CatalogueRecord.Page?
    public let document: Result<DocumentFacts, Unavailable>
    /// Resolved separately from Sent with. Nil indicates an assessed document with no enclosure reference,
    /// or that the document itself is unavailable (see `document`).
    public let enclosure: Result<DocumentFacts, Unavailable>?

    /// Comparable across scans, including dependencies on split-document owners and enclosure links.
    public var revision: SelectionRevision {
        SelectionRevision(file: file.map(\.revision), pageID: page?.id,
                          document: document.map { DocumentRevision(owner: $0.owner.revision, id: $0.document.id) },
                          enclosure: enclosure?.map { DocumentRevision(owner: $0.owner.revision, id: $0.document.id) })
    }

    public struct SelectionRevision: Equatable, Sendable {
        let file: Result<Revision, Unavailable>
        let pageID: UUID?
        let document: Result<DocumentRevision, Unavailable>
        let enclosure: Result<DocumentRevision, Unavailable>?
    }

    struct DocumentRevision: Equatable, Sendable {
        let owner: Revision
        let id: UUID
    }
}
