import Foundation

extension CatalogueReader {
    /// An immutable view of one scoped scan. It keeps each file's state and the independently
    /// identified owner occurrences, including owners with unreadable companions.
    public struct Snapshot: Sendable {
        typealias FileResult = Result<ItemFacts.FileFacts, ItemFacts.Unavailable>
        public let rootInstanceID: UUID
        private let mode: Mode
        public let inventory: Inventory
        private let rootFailure: ItemFacts.Unavailable?
        /// The root directory the files were read under; nil when the root could not be read.
        let rootIdentity: CatalogueReadDirectory.Identity?
        let files: [Data: FileResult]
        private let owners: [UUID: [FileResult]]
        let reads: [Data: RememberedRead]

        init(rootInstanceID: UUID, mode: Mode, inventory: Inventory, rootFailure: ItemFacts.Unavailable? = nil,
             rootIdentity: CatalogueReadDirectory.Identity? = nil,
             files: [Data: FileResult] = [:], owners: [UUID: [FileResult]] = [:], reads: [Data: RememberedRead] = [:]) {
            self.rootInstanceID = rootInstanceID
            self.mode = mode
            self.inventory = inventory
            self.rootFailure = rootFailure
            self.rootIdentity = rootFailure == nil ? rootIdentity : nil
            self.files = files
            self.owners = owners
            self.reads = reads
        }

        var isAdopted: Bool { mode == .adopted && rootFailure == nil && rootIdentity != nil }

        /// What this snapshot's reads proved, for `snapshot(_:remembering:)` or a launch's
        /// `rememberedSnapshot(_:)`. Nil when the root could not be read.
        public var memory: ReadMemory? {
            guard isAdopted, let rootIdentity else { return nil }
            return ReadMemory(rootInstanceID: rootInstanceID, rootIdentity: rootIdentity,
                              inventoryPaths: inventory.relativePDFPaths, isComplete: inventory.isComplete, reads: reads)
        }

        /// Only pairs whose PDF identity and adjacent companion both verified in this scan.
        public var rememberablePairs: [CatalogueReader.RememberedPair] {
            files.values.compactMap { result in
                (try? result.get()).map { CatalogueReader.RememberedPair($0) }
            }
        }

        /// `rememberablePairs` for the named paths only: what a revision read again.
        public func rememberablePairs(at relativePaths: some Sequence<String>) -> [CatalogueReader.RememberedPair] {
            relativePaths.compactMap { path in
                files[Data(path.utf8)].flatMap { try? $0.get() }.map { CatalogueReader.RememberedPair($0) }
            }
        }

        public func facts(at relativePath: String, physicalPageIndex: Int? = nil) -> ItemFacts {
            let file: FileResult
            if let rootFailure {
                file = .failure(rootFailure)
            } else if CatalogueReader.pathComponents(relativePath) == nil {
                file = .failure(.invalid(.pdf))
            } else if mode == .legacy {
                file = .failure(.legacy)
            } else {
                let absent: ItemFacts.Unavailable = inventory.isComplete ? .missing(.pdf) : .incompleteInventory
                file = files[Data(relativePath.utf8)] ?? .failure(absent)
            }

            switch file {
            case .failure(let failure):
                return ItemFacts(file: file, page: nil, document: .failure(failure), enclosure: nil)
            case .success(let facts):
                let record = facts.pair.record
                let page = physicalPageIndex.flatMap { index in
                    record.pages.first { $0.physicalIndex == index }
                }
                let document: Result<ItemFacts.DocumentFacts, ItemFacts.Unavailable>
                if let page, let membership = record.document(id: page.documentID) {
                    document = owner(of: membership.id, ownerFileID: membership.ownerFileID, from: facts)
                } else if physicalPageIndex != nil {
                    document = .failure(.missing(.document))
                } else if let only = record.documents.first, record.documents.count == 1 {
                    document = owner(of: only.id, ownerFileID: only.ownerFileID, from: facts)
                } else {
                    document = .failure(.ambiguous(.document))
                }
                let enclosure = (try? document.get()).flatMap { resolved in
                    resolved.document.enclosedWith.map {
                        owner(of: $0.documentID, ownerFileID: $0.ownerFileID, from: resolved.owner)
                    }
                }
                return ItemFacts(file: file, page: page, document: document, enclosure: enclosure)
            }
        }

        private func owner(of id: UUID, ownerFileID: UUID, from file: ItemFacts.FileFacts)
            -> Result<ItemFacts.DocumentFacts, ItemFacts.Unavailable> {
            let candidate: ItemFacts.FileFacts
            if file.pair.record.fileID == ownerFileID {
                candidate = file
            } else {
                guard inventory.isComplete else { return .failure(.incompleteInventory) }
                let matches = owners[ownerFileID, default: []]
                guard let match = matches.first else { return .failure(.missing(.owner)) }
                guard matches.count == 1 else { return .failure(.ambiguous(.owner)) }
                switch match {
                case .success(let facts):
                    candidate = facts
                case .failure(.offline):
                    return .failure(.offline(.owner))
                case .failure(.missing):
                    return .failure(.missing(.owner))
                case .failure(.newer(let schema)):
                    return .failure(.newer(schema: schema))
                case .failure:
                    return .failure(.invalid(.owner))
                }
            }
            guard let document = candidate.pair.record.document(id: id),
                  document.ownerFileID == ownerFileID, document.fields != nil else {
                return .failure(.invalid(.owner))
            }
            return .success(ItemFacts.DocumentFacts(owner: candidate, document: document))
        }
    }
}
