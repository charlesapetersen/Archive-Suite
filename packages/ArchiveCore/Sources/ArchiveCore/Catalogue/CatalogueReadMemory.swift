import Foundation

extension CatalogueReader {
    /// What one read proved about one relative path, kept so a later read of the same unchanged bytes
    /// need not parse them again (W49.reader-catalogue-scale).
    ///
    /// Reuse is keyed by the complete `FileVersion` of a freshly opened descriptor (inode, birth time,
    /// size, mode, links, flags, and nanosecond mtime and ctime), never by a path or a timestamp alone.
    /// Any write to the PDF or its companion, including a Finder tag change that only moves ctime,
    /// changes the version and forces a full read. The PDF identity is reused only because
    /// `CataloguePDFIdentity.identify` depends on the PDF's bytes alone.
    public struct RememberedRead: Codable, Sendable {
        let pdfVersion: CatalogueReadDirectory.FileVersion?
        let identity: PDFIdentity?
        let companionVersion: CatalogueReadDirectory.FileVersion?
        let record: CatalogueRecord?
        /// The read's failure, so a snapshot made from memory alone can show it until the disk answers.
        let failure: ItemFacts.Unavailable?

        init(pdfVersion: CatalogueReadDirectory.FileVersion?, identity: PDFIdentity?,
             companionVersion: CatalogueReadDirectory.FileVersion?, record: CatalogueRecord?,
             failure: ItemFacts.Unavailable?) {
            self.pdfVersion = pdfVersion
            self.identity = identity
            self.companionVersion = record == nil ? nil : companionVersion
            self.record = record
            self.failure = failure
        }

        private enum CodingKeys: String, CodingKey { case pdfVersion, identity, companionVersion, companionJSON, failure }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            pdfVersion = try container.decodeIfPresent(CatalogueReadDirectory.FileVersion.self, forKey: .pdfVersion)
            identity = try container.decodeIfPresent(PDFIdentity.self, forKey: .identity)
            let json = try container.decodeIfPresent(Data.self, forKey: .companionJSON)
            // A record that no longer decodes (a newer build changed the schema) is simply not reused.
            let decoded = json.flatMap { try? CatalogueRecord(json: $0) }
            record = decoded
            companionVersion = decoded == nil
                ? nil : try container.decodeIfPresent(CatalogueReadDirectory.FileVersion.self, forKey: .companionVersion)
            let failure = try container.decodeIfPresent(ItemFacts.Unavailable.self, forKey: .failure)
            self.failure = failure ?? (json != nil && decoded == nil ? .invalid(.companion) : nil)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(pdfVersion, forKey: .pdfVersion)
            try container.encodeIfPresent(identity, forKey: .identity)
            try container.encodeIfPresent(companionVersion, forKey: .companionVersion)
            try container.encodeIfPresent(record?.originalJSON, forKey: .companionJSON)
            try container.encodeIfPresent(failure, forKey: .failure)
        }
    }

    /// Every read of one snapshot, for one root instance and root directory. A memory for another
    /// instance or another directory is ignored, never partly used.
    public struct ReadMemory: Codable, Sendable {
        public let rootInstanceID: UUID
        let rootIdentity: CatalogueReadDirectory.Identity
        public let inventoryPaths: [String]
        public let isComplete: Bool
        let reads: [Data: RememberedRead]

        public var count: Int { reads.count }
    }

    func usable(_ memory: ReadMemory?) -> [Data: RememberedRead] {
        guard let memory, memory.rootInstanceID == rootInstanceID, memory.rootIdentity == rootIdentity else { return [:] }
        return memory.reads
    }

    /// A snapshot made from memory alone, with no file opened, for showing a warm list at launch.
    /// Its facts are as of the memory: never write from it, and replace it with a disk snapshot.
    /// Nil when the memory belongs to another instance or another root directory.
    public func rememberedSnapshot(_ memory: ReadMemory) -> Snapshot? {
        guard mode == .adopted, memory.rootInstanceID == rootInstanceID, memory.rootIdentity == rootIdentity else {
            return nil
        }
        var files: [Data: Snapshot.FileResult] = [:]
        var owners: [UUID: [Snapshot.FileResult]] = [:]
        for (key, read) in memory.reads {
            let result: Snapshot.FileResult
            if let failure = read.failure {
                result = .failure(failure)
            } else if let record = read.record, let pdfVersion = read.pdfVersion, let companionVersion = read.companionVersion {
                let occurrence = CatalogueAssociation.Occurrence(rootInstanceID: rootInstanceID,
                                                                 relativePath: String(decoding: key, as: UTF8.self))
                let proof = read.identity.map {
                    CatalogueAssociation.VerifiedPDF(occurrence: occurrence, fileID: $0.fileID,
                                                     contentRevision: $0.contentRevision, pageCount: $0.pageCount)
                }
                do {
                    result = .success(try fileFacts(record, at: occurrence, proof: proof, pdfVersion: pdfVersion,
                                                    companionVersion: companionVersion))
                } catch {
                    result = .failure(Self.companionStatus(error))
                }
            } else {
                result = .failure(.invalid(.companion))
            }
            files[key] = result
            if let fileID = read.identity?.fileID { owners[fileID, default: []].append(result) }
        }
        return Snapshot(rootInstanceID: rootInstanceID, mode: mode,
                        inventory: Inventory(relativePDFPaths: memory.inventoryPaths, isComplete: memory.isComplete),
                        rootIdentity: rootIdentity, files: files, owners: owners, reads: memory.reads)
    }
}
