import CryptoKit
import Foundation

/// A read boundary for one granted root instance. The caller keeps its resolved, non-stale
/// security scope active while constructing the reader and taking snapshots.
public struct CatalogueReader: Sendable {
    public enum Mode: Sendable { case legacy, adopted }

    public struct PDFIdentity: Codable, Sendable {
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
    let mode: Mode
    let rootIdentity: CatalogueReadDirectory.Identity
    private let identifyPDF: IdentifyPDF
    let directory: CatalogueReadDirectory

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
    /// `memory` from an earlier pass of this root instance lets unchanged files skip their parse.
    public func discover(including selectedPaths: [String] = [], remembering memory: ReadMemory? = nil) -> Snapshot {
        snapshot(including: selectedPaths, remembered: usable(memory)) { rootEntry in
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
    /// `memory` lets a file whose PDF and companion versions are unchanged skip the PDF identity parse
    /// and the companion decode; every file is still opened and checked (`RememberedRead`).
    public func snapshot(_ inventory: Inventory, including selectedPaths: [String] = [],
                         remembering memory: ReadMemory? = nil) -> Snapshot {
        snapshot(including: selectedPaths, remembered: usable(memory), carrying: nil, rereading: []) { _ in inventory }
    }

    /// A snapshot that carries every file of `previous` not named in `rereading` without opening it, and
    /// reads the named ones, and any path `previous` did not hold, from the filesystem. For a caller
    /// with a file-system event stream: it names every path that changed, and a missed event is its
    /// cue for a full `snapshot(_:)`. Owners are resolved again across the whole inventory, so a moved
    /// or removed owner still updates the documents that depend on it. A `previous` from another
    /// instance or root directory, or one that could not read the root, is not carried.
    public func snapshot(revising previous: Snapshot, inventory: Inventory, rereading: Set<String>) -> Snapshot {
        let carried = previous.rootInstanceID == rootInstanceID && previous.rootIdentity == rootIdentity
            && previous.isAdopted ? previous : nil
        return snapshot(including: [], remembered: carried?.reads ?? [:], carrying: carried,
                        rereading: Set(rereading.map { Data($0.utf8) })) { _ in inventory }
    }

    private func snapshot(including selectedPaths: [String], remembered: [Data: RememberedRead] = [:],
                          carrying previous: Snapshot? = nil, rereading: Set<Data> = [],
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
                    var reads: [Data: RememberedRead] = [:]
                    var owners: [UUID: [Snapshot.FileResult]] = [:]
                    var isComplete = inventory.isComplete
                    // Swift String equality folds Unicode spellings. Retain filesystem byte spelling.
                    for path in inventory.relativePDFPaths + selectedPaths {
                        let key = Data(path.utf8)
                        guard files[key] == nil else { continue }
                        let result: Snapshot.FileResult
                        let read: RememberedRead?
                        if let previous, !rereading.contains(key), let prior = previous.files[key] {
                            result = prior
                            read = previous.reads[key]
                        } else {
                            (result, read) = readFile(path: path, in: root, remembered: remembered[key])
                        }
                        files[key] = result
                        if let read { reads[key] = read }
                        if let fileID = read?.identity?.fileID {
                            owners[fileID, default: []].append(result)
                        } else if case .failure(.missing(.pdf)) = result, discovered.contains(key) {
                            isComplete = false
                        }
                    }
                    return Snapshot(rootInstanceID: rootInstanceID, mode: mode,
                                    inventory: Inventory(relativePDFPaths: inventory.relativePDFPaths, isComplete: isComplete),
                                    rootIdentity: rootIdentity, files: files, owners: owners, reads: reads)
                }
            }
        } catch {
            return Snapshot(rootInstanceID: rootInstanceID, mode: mode, inventory: unavailable,
                            rootFailure: error as? ItemFacts.Unavailable ?? .invalid(.root))
        }
    }

    /// One file's facts and what the read proved. The PDF identity is reused when the opened PDF's
    /// version equals the remembered one, and the companion record when the opened companion's does.
    private func readFile(path: String, in root: CatalogueReadDirectory.Entry, remembered: RememberedRead?)
        -> (result: Result<ItemFacts.FileFacts, ItemFacts.Unavailable>, read: RememberedRead?) {
        guard let parts = Self.pathComponents(path), let filename = parts.last else {
            return (.failure(.invalid(.pdf)), RememberedRead(pdfVersion: nil, identity: nil, companionVersion: nil,
                                                             record: nil, failure: .invalid(.pdf)))
        }
        let occurrence = CatalogueAssociation.Occurrence(rootInstanceID: rootInstanceID, relativePath: path)
        do {
            return try directory.withParent(parts.dropLast(), in: root) { parent in
                try directory.withFile(filename, in: parent, artifact: .pdf) { pdf in
                    let pdfVersion = CatalogueReadDirectory.FileVersion(pdf.info)
                    let observed: PDFIdentity?
                    if let remembered, remembered.pdfVersion == pdfVersion {
                        observed = remembered.identity
                    } else {
                        observed = try identifyPDF(pdf.descriptor, occurrence)
                    }
                    let companionName = CatalogueRecord.companionFilename(forPDFFilename: filename)
                    var companionVersion: CatalogueReadDirectory.FileVersion?
                    var companionRecord: CatalogueRecord?
                    do {
                        let facts = try directory.withFile(companionName, in: parent, artifact: .companion) { companion in
                            let version = CatalogueReadDirectory.FileVersion(companion.info)
                            let record: CatalogueRecord
                            if let remembered, remembered.companionVersion == version, let kept = remembered.record {
                                record = kept
                            } else {
                                record = try Self.record(in: companion)
                            }
                            companionVersion = version
                            companionRecord = record
                            let proof = observed.map {
                                CatalogueAssociation.VerifiedPDF(occurrence: occurrence, fileID: $0.fileID,
                                                                 contentRevision: $0.contentRevision, pageCount: $0.pageCount)
                            }
                            return try fileFacts(record, at: occurrence, proof: proof, pdf: pdf,
                                                 companionVersion: .init(companion.info))
                        }
                        return (.success(facts), RememberedRead(pdfVersion: pdfVersion, identity: observed,
                                                                companionVersion: companionVersion, record: companionRecord,
                                                                failure: nil))
                    } catch {
                        let status = Self.companionStatus(error)
                        return (.failure(status), RememberedRead(pdfVersion: pdfVersion, identity: observed,
                                                                 companionVersion: nil, record: nil, failure: status))
                    }
                }
            }
        } catch {
            let status = error as? ItemFacts.Unavailable ?? .invalid(.pdf)
            return (.failure(status), RememberedRead(pdfVersion: nil, identity: nil, companionVersion: nil,
                                                     record: nil, failure: status))
        }
    }

    func fileFacts(_ record: CatalogueRecord, at occurrence: CatalogueAssociation.Occurrence,
                   proof: CatalogueAssociation.VerifiedPDF?, pdf: CatalogueReadDirectory.Entry,
                   companionVersion: CatalogueReadDirectory.FileVersion) throws -> ItemFacts.FileFacts {
        try fileFacts(record, at: occurrence, proof: proof, pdfVersion: .init(pdf.info), companionVersion: companionVersion)
    }

    func fileFacts(_ record: CatalogueRecord, at occurrence: CatalogueAssociation.Occurrence,
                   proof: CatalogueAssociation.VerifiedPDF?, pdfVersion: CatalogueReadDirectory.FileVersion,
                   companionVersion: CatalogueReadDirectory.FileVersion) throws -> ItemFacts.FileFacts {
        let pair = try CatalogueAssociation.pair(record, at: occurrence, verifiedBy: proof)
        let revision = ItemFacts.Revision(occurrence: occurrence, fileID: record.fileID, content: record.contentRevision,
                                          facts: record.revision, companionSHA256: Data(SHA256.hash(data: record.originalJSON)))
        return ItemFacts.FileFacts(pair: pair, revision: revision, rootIdentity: rootIdentity,
                                   pdfVersion: pdfVersion, companionVersion: companionVersion)
    }

    static func companionStatus(_ error: any Error) -> ItemFacts.Unavailable {
        switch error {
        case CatalogueRecord.Invalid.unsupportedSchema(let schema) where schema > CatalogueRecord.schema:
            .newer(schema: schema)
        case CatalogueAssociation.Unavailable.unverifiedPDF, CatalogueAssociation.Unavailable.mismatchedPDF:
            .invalid(.pdf)
        case let unavailable as ItemFacts.Unavailable:
            unavailable
        default:
            .invalid(.companion)
        }
    }

    func withOccurrence<T>(_ occurrence: CatalogueAssociation.Occurrence,
                           _ body: (CatalogueReadDirectory.Entry, CatalogueReadDirectory.Entry, String) throws -> T) throws -> T {
        guard mode == .adopted else { throw ItemFacts.Unavailable.legacy }
        guard occurrence.rootInstanceID == rootInstanceID else { throw ItemFacts.Unavailable.invalid(.root) }
        guard let parts = Self.pathComponents(occurrence.relativePath), let filename = parts.last else {
            throw ItemFacts.Unavailable.invalid(.pdf)
        }
        return try directory.withoutDownload {
            try directory.withRoot(root, expected: rootIdentity) { root in
                try directory.withParent(parts.dropLast(), in: root) { parent in
                    try body(root, parent, filename)
                }
            }
        }
    }

    func validateScope(root rootEntry: CatalogueReadDirectory.Entry, parent: CatalogueReadDirectory.Entry) throws {
        try directory.validateRoot(root, identity: rootIdentity, entry: rootEntry)
        guard CatalogueReadDirectory.hasPath(parent.descriptor, parent.path) else {
            throw ItemFacts.Unavailable.invalid(.pdf)
        }
    }

    func withProvenPDF<T>(_ filename: String, in parent: CatalogueReadDirectory.Entry,
                          at occurrence: CatalogueAssociation.Occurrence, expectedBase: ItemFacts.FileFacts? = nil,
                          _ body: (CatalogueReadDirectory.Entry, CatalogueAssociation.VerifiedPDF) throws -> T) throws -> T {
        if let expectedBase, expectedBase.rootIdentity != rootIdentity {
            throw ItemFacts.Unavailable.invalid(.root)
        }
        return try directory.withFile(filename, in: parent, artifact: .pdf) { entry in
            if let expectedBase, CatalogueReadDirectory.FileVersion(entry.info) != expectedBase.pdfVersion {
                throw ItemFacts.Unavailable.invalid(.pdf)
            }
            let observed: PDFIdentity
            do {
                guard let identity = try identifyPDF(entry.descriptor, occurrence) else {
                    throw ItemFacts.Unavailable.invalid(.pdf)
                }
                observed = identity
            } catch {
                throw error as? ItemFacts.Unavailable ?? .invalid(.pdf)
            }
            let proof = CatalogueAssociation.VerifiedPDF(occurrence: occurrence, fileID: observed.fileID,
                                                         contentRevision: observed.contentRevision, pageCount: observed.pageCount)
            if let expectedBase,
               observed.fileID != expectedBase.revision.fileID
                || observed.contentRevision != expectedBase.revision.content
                || observed.pageCount != expectedBase.pair.record.pages.count {
                throw ItemFacts.Unavailable.invalid(.pdf)
            }
            return try body(entry, proof)
        }
    }

    static func pathComponents(_ path: String) -> [String]? {
        guard path.utf8.count < MAXPATHLEN, !path.utf8.contains(0) else { return nil }
        // The filesystem splits on the slash byte even when Swift sees a single grapheme
        // made of a slash followed by a combining mark.
        let parts = path.utf8.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        guard let filename = parts.last, filename.lowercased().hasSuffix(".pdf"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return parts
    }

    static func record(in entry: CatalogueReadDirectory.Entry) throws -> CatalogueRecord {
        guard entry.info.st_size <= CatalogueRecord.maximumBytes else { throw CatalogueRecord.Invalid.inputLimit }
        let file = FileHandle(fileDescriptor: entry.descriptor, closeOnDealloc: false)
        let bytes = try file.read(upToCount: CatalogueRecord.maximumBytes + 1) ?? Data()
        return try CatalogueRecord(json: bytes)
    }
}
