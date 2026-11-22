import CryptoKit
import Foundation

/// A read boundary for one granted root instance. The caller keeps its resolved, non-stale
/// security scope active while constructing the reader and taking snapshots.
public struct CatalogueReader: Sendable {
    public enum Mode: Sendable { case legacy, adopted }

    public struct PDFIdentity: Sendable {
        public let fileID: UUID
        public let contentRevision: UUID
        public let pageCount: Int

        public init(fileID: UUID, contentRevision: UUID, pageCount: Int) {
            self.fileID = fileID
            self.contentRevision = contentRevision
            self.pageCount = pageCount
        }
    }

    /// Read embedded identity or a previously confirmed association independently of the JSON.
    /// The descriptor is a synchronous, read-only borrow of the selected PDF. The callback must
    /// use it directly, must not close it, and returns nil when there is no positive evidence.
    public typealias IdentifyPDF = @Sendable (Int32, CatalogueAssociation.Occurrence) throws -> PDFIdentity?

    public struct Inventory: Sendable {
        /// Canonical relative PDF candidates, before their companion and identity are validated.
        public let relativePDFPaths: [String]
        /// True only for a successful inventory of the entire granted root, including untagged PDFs.
        public let isComplete: Bool

        public init(relativePDFPaths: [String], isComplete: Bool) {
            self.relativePDFPaths = relativePDFPaths
            self.isComplete = isComplete
        }
    }

    private let root: URL
    public let rootInstanceID: UUID
    private let mode: Mode
    private let rootIdentity: CatalogueReadDirectory.Identity
    private let identifyPDF: IdentifyPDF
    private let directory: CatalogueReadDirectory

    public init(grantedRoot: URL, rootInstanceID: UUID, mode: Mode, identifyPDF: @escaping IdentifyPDF) throws {
        try self.init(grantedRoot: grantedRoot, rootInstanceID: rootInstanceID, mode: mode,
                      isDataless: { $0.st_flags & UInt32(SF_DATALESS) != 0 }, identifyPDF: identifyPDF)
    }

    init(grantedRoot: URL, rootInstanceID: UUID, mode: Mode,
         isDataless: @escaping @Sendable (stat) -> Bool, identifyPDF: @escaping IdentifyPDF) throws {
        guard grantedRoot.isFileURL else { throw ItemFacts.Unavailable.invalid(.root) }
        let directory = CatalogueReadDirectory(isDataless: isDataless)
        rootIdentity = try directory.withoutDownload {
            try directory.withRoot(grantedRoot) { CatalogueReadDirectory.Identity($0.info) }
        }
        root = grantedRoot
        self.rootInstanceID = rootInstanceID
        self.mode = mode
        self.identifyPDF = identifyPDF
        self.directory = directory
    }

    /// Discover every PDF independent of Finder tags. Run this synchronous scan off the UI actor.
    /// Existing scan loops may use `snapshot(_:including:)` with their own inventory instead.
    public func discover(including selectedPaths: [String] = []) -> Snapshot {
        snapshot(including: selectedPaths) { rootEntry in
            let scan = CorpusWalker.scanFingerprints(root: root, options: .init(enumerationOptions: []),
                                                     followFileSymlinks: false)
            guard let prefix = scan.rootPath, prefix.utf8.elementsEqual(rootEntry.path.utf8) else {
                return Inventory(relativePDFPaths: [], isComplete: false)
            }
            let rootPrefix = prefix == "/" ? prefix : prefix + "/"
            let paths = scan.entries.compactMap { entry -> String? in
                entry.url.withUnsafeFileSystemRepresentation { path in
                    guard let path = path.flatMap({ String(validatingCString: $0) }),
                          path.utf8.starts(with: rootPrefix.utf8) else { return nil }
                    return String(decoding: path.utf8.dropFirst(rootPrefix.utf8.count), as: UTF8.self)
                }
            }
            return Inventory(relativePDFPaths: paths.filter { Self.pathComponents($0) != nil },
                             isComplete: scan.isClean && scan.vanishedMidScan == 0 && paths.count == scan.entries.count)
        }
    }

    /// Refresh from the current filesystem. Path and PDF timestamps alone never key catalogue facts.
    /// Supply a fresh complete inventory to resolve foreign owners. Explicit selections may be absent
    /// from that inventory (for example a stale Notes link) and are still checked within the root.
    public func snapshot(_ inventory: Inventory, including selectedPaths: [String] = []) -> Snapshot {
        snapshot(including: selectedPaths) { _ in inventory }
    }

    private func snapshot(including selectedPaths: [String],
                          inventory readInventory: (CatalogueReadDirectory.Entry) -> Inventory) -> Snapshot {
        let unavailable = Inventory(relativePDFPaths: [], isComplete: false)
        guard mode == .adopted else {
            return Snapshot(rootInstanceID: rootInstanceID, mode: mode, inventory: unavailable)
        }
        do {
            return try directory.withoutDownload {
                try directory.withRoot(root, expected: rootIdentity) { root in
                    let inventory = readInventory(root)
                    let discovered = Set(inventory.relativePDFPaths.map { Data($0.utf8) })
                    var files: [Data: Snapshot.FileResult] = [:]
                    var owners: [UUID: [Snapshot.FileResult]] = [:]
                    var isComplete = inventory.isComplete
                    // Swift String equality folds Unicode spellings. Retain filesystem byte spelling.
                    for path in inventory.relativePDFPaths + selectedPaths {
                        let key = Data(path.utf8)
                        guard files[key] == nil else { continue }
                        let read = readFile(path: path, in: root)
                        files[key] = read.result
                        if let fileID = read.provenFileID {
                            owners[fileID, default: []].append(read.result)
                        } else if case .failure(.missing(.pdf)) = read.result, discovered.contains(key) {
                            isComplete = false
                        }
                    }
                    return Snapshot(rootInstanceID: rootInstanceID, mode: mode,
                                    inventory: Inventory(relativePDFPaths: inventory.relativePDFPaths, isComplete: isComplete),
                                    files: files, owners: owners)
                }
            }
        } catch {
            return Snapshot(rootInstanceID: rootInstanceID, mode: mode, inventory: unavailable,
                            rootFailure: error as? ItemFacts.Unavailable ?? .invalid(.root))
        }
    }

    private func readFile(path: String, in root: CatalogueReadDirectory.Entry)
        -> (result: Result<ItemFacts.FileFacts, ItemFacts.Unavailable>, provenFileID: UUID?) {
        guard let parts = Self.pathComponents(path), let filename = parts.last else {
            return (.failure(.invalid(.pdf)), nil)
        }
        let occurrence = CatalogueAssociation.Occurrence(rootInstanceID: rootInstanceID, relativePath: path)
        do {
            return try directory.withParent(parts.dropLast(), in: root) { parent in
                try directory.withFile(filename, in: parent, artifact: .pdf) { pdf in
                    let observed = try identifyPDF(pdf.descriptor, occurrence)
                    let companionName = CatalogueRecord.companionFilename(forPDFFilename: filename)
                    do {
                        let facts = try directory.withFile(companionName, in: parent, artifact: .companion) { companion in
                            let record = try Self.record(in: companion)
                            let proof = observed.map {
                                CatalogueAssociation.VerifiedPDF(occurrence: occurrence, fileID: $0.fileID,
                                                                 contentRevision: $0.contentRevision, pageCount: $0.pageCount)
                            }
                            let pair = try CatalogueAssociation.pair(record, at: occurrence, verifiedBy: proof)
                            let revision = ItemFacts.Revision(occurrence: occurrence, fileID: record.fileID,
                                                              content: record.contentRevision, facts: record.revision,
                                                              companionSHA256: Data(SHA256.hash(data: record.originalJSON)))
                            return ItemFacts.FileFacts(pair: pair, revision: revision)
                        }
                        return (.success(facts), observed?.fileID)
                    } catch {
                        let status: ItemFacts.Unavailable
                        switch error {
                        case CatalogueRecord.Invalid.unsupportedSchema(let schema) where schema > CatalogueRecord.schema:
                            status = .newer(schema: schema)
                        case CatalogueAssociation.Unavailable.unverifiedPDF, CatalogueAssociation.Unavailable.mismatchedPDF:
                            status = .invalid(.pdf)
                        case let unavailable as ItemFacts.Unavailable:
                            status = unavailable
                        default:
                            status = .invalid(.companion)
                        }
                        return (.failure(status), observed?.fileID)
                    }
                }
            }
        } catch {
            return (.failure(error as? ItemFacts.Unavailable ?? .invalid(.pdf)), nil)
        }
    }

    static func pathComponents(_ path: String) -> [String]? {
        guard path.utf8.count < MAXPATHLEN, !path.utf8.contains(0) else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let filename = parts.last, filename.lowercased().hasSuffix(".pdf"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return parts.map(String.init)
    }

    private static func record(in entry: CatalogueReadDirectory.Entry) throws -> CatalogueRecord {
        guard entry.info.st_size <= CatalogueRecord.maximumBytes else { throw CatalogueRecord.Invalid.inputLimit }
        let file = FileHandle(fileDescriptor: entry.descriptor, closeOnDealloc: false)
        let bytes = try file.read(upToCount: CatalogueRecord.maximumBytes + 1) ?? Data()
        return try CatalogueRecord(json: bytes)
    }
}
