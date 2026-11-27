import CryptoKit
import Foundation

/// A lossless pair and subset export (`SPEC/catalogue.md` §"Pair and subset export"). It copies each
/// selected PDF and its companion byte for byte into a new folder, with every file the selection's
/// documents depend on: the owner and the other members of a split document, the owner of an
/// enclosure's covering document, the verified preservation copies and the folder records the
/// container context inherits from. The folder is a dated snapshot. It is checked by reading it back
/// as its own root before it is published, and the archive is only read.
public enum CatalogueExport {
    public static let manifestName = "archivesuite-export.json"
    public static let format = "archivesuite-export"
    public static let version = 1
    static let metadataDirectory = ".archivesuite"
    /// The folder records a file's container context and collection settings are read from.
    static let contextNames = [ContainerFile.fileName, ContainerLevelMap.fileName, ContainerNames.fileName,
                               CollectionSettingsRecord.fileName]

    /// Why a file is in the export.
    public enum Role: String, Codable, Sendable {
        /// Chosen by the user.
        case selected
        /// Owns, or is another member of, a document on a file already in the export.
        case document
        /// Owns the covering document an exported document is enclosed with.
        case enclosure
    }

    public struct File: Codable, Equatable, Sendable {
        public let path: String
        public let role: Role
        public let fileID: UUID
        public let contentRevision: UUID
        public let revision: UUID
        /// Base64 SHA-256 of the exported bytes.
        public let pdfSHA256: String
        public let companionSHA256: String
        /// Preservation files copied for this PDF, relative to the export folder.
        public let preservation: [String]
    }

    public struct Manifest: Codable, Equatable, Sendable {
        public let format: String
        public let version: Int
        public let snapshot: Bool
        public let createdAt: Date
        public let note: String
        /// The archive folder's name, not its path on this Mac.
        public let originName: String
        public let originRootInstanceID: UUID
        public let files: [File]
        /// Folder records copied for container context, relative to the export folder.
        public let context: [String]

        public func encoded() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(self)
        }

        public static func decode(_ data: Data) throws -> Manifest {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Manifest.self, from: data)
        }
    }

    public enum Failure: LocalizedError, Equatable, Sendable {
        case nothingSelected
        case destinationExists
        case destinationInsideArchive
        case destinationUnavailable
        /// A file the export needs could not be read as a verified pair, or its document could not be resolved.
        case unavailable(path: String, ItemFacts.Unavailable)
        /// A file changed between the scan and the copy.
        case changed(path: String)
        case preservation(path: String)
        /// The copy did not read back as the same records.
        case verification(path: String)

        public var errorDescription: String? {
            switch self {
            case .nothingSelected: "Nothing is selected to export."
            case .destinationExists: "Something already has that name. Choose a new folder name."
            case .destinationInsideArchive: "Choose a place outside the archive. A copy inside it would make its records ambiguous."
            case .destinationUnavailable: "The export folder could not be created there."
            case .unavailable(let path, let reason):
                "\(path) cannot be exported with its catalogue record (\(Self.describe(reason)))."
            case .changed(let path): "\(path) changed, or could not be read as the same file, while it was being exported."
            case .preservation(let path): "The preserved originals for \(path) are missing or could not be verified."
            case .verification(let path): "The exported copy of \(path) did not read back the same. Nothing was exported."
            }
        }

        static func describe(_ reason: ItemFacts.Unavailable) -> String {
            switch reason {
            case .legacy: "the archive does not use catalogue records"
            case .offline: "a file is not downloaded"
            case .missing(.owner): "the file that owns its document is missing"
            case .ambiguous(.owner): "more than one file claims to own its document"
            case .invalid(.owner): "the file that owns its document does not declare it"
            case .missing: "its record is missing"
            case .ambiguous: "its record is ambiguous"
            case .invalid: "its record could not be verified"
            case .newer: "its record is from a newer version"
            case .incompleteInventory: "the archive could not be read completely"
            }
        }
    }

    /// Export `selectedPaths` (relative to the reader's root) into `destination`, a folder that must not
    /// exist yet and must lie outside the archive. Nothing is published unless every file verifies, and
    /// an existing item is never replaced. Synchronous; run it off the main actor.
    @discardableResult
    public static func export(_ selectedPaths: [String], from reader: CatalogueReader, to destination: URL,
                              now: Date = Date()) throws -> Manifest {
        guard !selectedPaths.isEmpty else { throw Failure.nothingSelected }
        try checkDestination(destination, archive: reader.root)
        let snapshot = reader.discover(including: selectedPaths)
        let plan = try closure(of: selectedPaths, in: snapshot)

        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".archivesuite-export-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        } catch {
            throw Failure.destinationUnavailable
        }
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: staging) } }

        let manifest: Manifest
        do {
            manifest = try stage(plan, from: reader, into: staging, now: now)
            try verify(manifest, at: staging, against: snapshot, identify: reader.identifyPDF)
        } catch let failure as Failure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A Cocoa error would name the hidden staging folder's path on this Mac.
            throw Failure.destinationUnavailable
        }

        let outcome = staging.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to -> Int32 in
                guard let from, let to else { return EINVAL }
                return renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
            }
        }
        guard outcome == 0 else { throw outcome == EEXIST ? Failure.destinationExists : Failure.destinationUnavailable }
        published = true
        return manifest
    }

    static func stage(_ plan: Plan, from reader: CatalogueReader, into staging: URL, now: Date) throws -> Manifest {
        var files: [File] = []
        for (path, role) in plan.order {
            try Task.checkCancellation()
            files.append(try copy(plan.facts[Data(path.utf8)]!, role: role, from: reader, into: staging))
        }
        let context = try copyContext(for: plan.order.map(\.path), from: reader, into: staging)
        let manifest = Manifest(
            format: format, version: version, snapshot: true, createdAt: now,
            note: "A snapshot of these catalogue records when they were exported. Later edits in the archive do not change it. "
                + "Each record is copied whole, including read state, flags, colour, quality and checks.",
            originName: reader.root.lastPathComponent, originRootInstanceID: reader.rootInstanceID,
            files: files, context: context)
        try write(try manifest.encoded(), to: staging.appendingPathComponent(manifestName))
        return manifest
    }

    // MARK: - What goes in

    struct Plan {
        var order: [(path: String, role: Role)] = []
        var facts: [Data: ItemFacts.FileFacts] = [:]
    }

    static func closure(of selectedPaths: [String], in snapshot: CatalogueReader.Snapshot) throws -> Plan {
        var plan = Plan()
        func add(_ path: String, _ role: Role) throws {
            let key = Data(path.utf8)
            guard plan.facts[key] == nil else { return }
            switch snapshot.facts(at: path).file {
            case .success(let facts): plan.facts[key] = facts
            case .failure(let reason): throw Failure.unavailable(path: path, reason)
            }
            plan.order.append((path, role))
        }
        func resolved(_ result: Result<ItemFacts.DocumentFacts, ItemFacts.Unavailable>, at path: String) throws
            -> ItemFacts.DocumentFacts {
            switch result {
            case .success(let document): document
            case .failure(let reason): throw Failure.unavailable(path: path, reason)
            }
        }
        for path in selectedPaths { try add(path, .selected) }

        var next = 0
        while next < plan.order.count {
            let path = plan.order[next].path
            next += 1
            let record = plan.facts[Data(path.utf8)]!.pair.record
            for page in record.pages.sorted(by: { $0.physicalIndex < $1.physicalIndex }) {
                let item = snapshot.facts(at: path, physicalPageIndex: page.physicalIndex)
                try add(try resolved(item.document, at: path).owner.pair.occurrence.relativePath, .document)
                if let enclosure = item.enclosure {
                    try add(try resolved(enclosure, at: path).owner.pair.occurrence.relativePath, .enclosure)
                }
            }
            // The other members of a split document this file owns: the document is exported whole.
            let owned = Set(record.documents.filter { $0.ownerFileID == record.fileID }.map(\.id))
            guard !owned.isEmpty else { continue }
            guard snapshot.inventory.isComplete else { throw Failure.unavailable(path: path, .incompleteInventory) }
            // A file that could not be read may be a member, so the document cannot be shown to be whole.
            // A PDF with no companion, or one that vanished (which leaves the inventory incomplete), is not one.
            for (key, result) in snapshot.files.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }) {
                switch result {
                case .success, .failure(.missing(.companion)), .failure(.legacy): continue
                case .failure(let reason): throw Failure.unavailable(path: String(decoding: key, as: UTF8.self), reason)
                }
            }
            let members = snapshot.files.values.compactMap { try? $0.get() }.filter { other in
                other.pair.record.fileID != record.fileID && other.pair.record.documents.contains {
                    owned.contains($0.id) && $0.ownerFileID == record.fileID
                }
            }
            for member in members.map(\.pair.occurrence.relativePath).sorted(by: { Data($0.utf8).lexicographicallyPrecedes(Data($1.utf8)) }) {
                try add(member, .document)
            }
        }
        return plan
    }

    // MARK: - Copying

    static func copy(_ facts: ItemFacts.FileFacts, role: Role, from reader: CatalogueReader, into staging: URL) throws -> File {
        let occurrence = facts.pair.occurrence
        let path = occurrence.relativePath
        let target = staging.appendingPathComponent(path)
        let folder = target.deletingLastPathComponent()
        do {
            return try reader.withOccurrence(occurrence) { _, parent, filename in
                try reader.withProvenPDF(filename, in: parent, at: occurrence, expectedBase: facts) { pdf, _ in
                    let companionName = CatalogueRecord.companionFilename(forPDFFilename: filename)
                    let json = try reader.directory.withFile(companionName, in: parent, artifact: .companion) {
                        try readSmall($0)
                    }
                    let companionDigest = Data(SHA256.hash(data: json))
                    guard companionDigest == facts.revision.companionSHA256 else { throw Failure.changed(path: path) }
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let pdfDigest = try copyFile(pdf, to: target, expectedSize: nil)
                    try write(json, to: folder.appendingPathComponent(companionName))
                    let preservation = try copyPreservation(of: facts.pair.record, beside: path, in: parent,
                                                            from: reader, into: staging)
                    let record = facts.pair.record
                    return File(path: path, role: role, fileID: record.fileID, contentRevision: record.contentRevision,
                                revision: record.revision, pdfSHA256: pdfDigest.base64EncodedString(),
                                companionSHA256: companionDigest.base64EncodedString(), preservation: preservation)
                }
            }
        } catch let failure as Failure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch ItemFacts.Unavailable.invalid(.pdf) {
            throw Failure.changed(path: path)
        } catch let reason as ItemFacts.Unavailable {
            throw Failure.unavailable(path: path, reason)
        }
    }

    /// The `Preservation/<document>/<file>/` map and originals beside the PDF, verified as they are copied.
    static func copyPreservation(of record: CatalogueRecord, beside path: String, in parent: CatalogueReadDirectory.Entry,
                                 from reader: CatalogueReader, into staging: URL) throws -> [String] {
        guard let digest = record.preservationManifestSHA256 else { return [] }
        let base = (path as NSString).deletingLastPathComponent
        var documents: [UUID] = []
        for page in record.pages.sorted(by: { $0.physicalIndex < $1.physicalIndex }) where !documents.contains(page.documentID) {
            documents.append(page.documentID)
        }
        var copied: [String] = []
        for document in documents {
            let components = PreservationCopy.folderComponents(documentID: document, fileID: record.fileID)
            let relativeFolder = ([base].filter { !$0.isEmpty } + components).joined(separator: "/")
            let target = staging.appendingPathComponent(relativeFolder, isDirectory: true)
            do {
                try reader.directory.withParent(components[...], in: parent) { folder in
                    let map = try reader.directory.withFile(PreservationCopy.manifestName, in: folder, artifact: .companion) {
                        try readSmall($0)
                    }
                    guard Data(SHA256.hash(data: map)) == digest else { throw Failure.preservation(path: path) }
                    let manifest: PreservationCopy.Manifest
                    do {
                        try CatalogueJSON.check(map, maximumBytes: CatalogueRecord.maximumBytes)
                        manifest = try JSONDecoder().decode(PreservationCopy.Manifest.self, from: map)
                        try manifest.validate(against: record)
                    } catch {
                        throw Failure.preservation(path: path)
                    }
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                    try write(map, to: target.appendingPathComponent(PreservationCopy.manifestName))
                    copied.append(relativeFolder + "/" + PreservationCopy.manifestName)
                    for index in manifest.sources.indices {
                        let name = manifest.storedName(at: index)
                        let fingerprint = manifest.sources[index].fingerprint
                        let written: Data
                        do {
                            written = try reader.directory.withFile(name, in: folder, artifact: .companion) {
                                try copyFile($0, to: target.appendingPathComponent(name), expectedSize: fingerprint.byteCount)
                            }
                        } catch let reason as ItemFacts.Unavailable {
                            if case .offline = reason { throw Failure.unavailable(path: path, .offline(.companion)) }
                            throw Failure.preservation(path: path)
                        }
                        guard written == fingerprint.sha256 else { throw Failure.preservation(path: path) }
                        copied.append(relativeFolder + "/" + name)
                    }
                }
            } catch ItemFacts.Unavailable.missing {
                continue
            }
        }
        guard !copied.isEmpty else { throw Failure.preservation(path: path) }
        return copied
    }

    /// Each folder record on the way from the root to every exported file, copied verbatim.
    static func copyContext(for paths: [String], from reader: CatalogueReader, into staging: URL) throws -> [String] {
        var folders: [[String]] = [[]]
        for path in paths {
            let parts = (CatalogueReader.pathComponents(path) ?? []).dropLast()
            for depth in parts.indices.map({ $0 + 1 }) {
                let prefix = Array(parts.prefix(depth))
                if !folders.contains(prefix) { folders.append(prefix) }
            }
        }
        var copied: [String] = []
        var reading = metadataDirectory
        do {
            try reader.directory.withoutDownload {
                try reader.directory.withRoot(reader.root, expected: reader.rootIdentity) { root in
                    for folder in folders {
                        reading = (folder + [metadataDirectory]).joined(separator: "/")
                        do {
                            try reader.directory.withParent((folder + [metadataDirectory])[...], in: root) { metadata in
                                for name in contextNames {
                                    reading = (folder + [metadataDirectory, name]).joined(separator: "/")
                                    do {
                                        let bytes = try reader.directory.withFile(name, in: metadata, artifact: .companion) {
                                            try readSmall($0)
                                        }
                                        let relative = (folder + [metadataDirectory, name]).joined(separator: "/")
                                        let target = staging.appendingPathComponent(relative)
                                        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                                                withIntermediateDirectories: true)
                                        try write(bytes, to: target)
                                        copied.append(relative)
                                    } catch ItemFacts.Unavailable.missing {
                                        continue
                                    }
                                }
                            }
                        } catch ItemFacts.Unavailable.missing {
                            continue
                        }
                    }
                }
            }
        } catch let reason as ItemFacts.Unavailable {
            throw Failure.unavailable(path: reading, reason)
        }
        return copied
    }

    // MARK: - Verification

    /// Read the staged folder back as its own root: the same files, records and document owners.
    static func verify(_ manifest: Manifest, at staging: URL, against source: CatalogueReader.Snapshot,
                       identify: @escaping CatalogueReader.IdentifyPDF) throws {
        let check = try CatalogueReader(grantedRoot: staging, rootInstanceID: UUID(), mode: .adopted, identifyPDF: identify)
        let copy = check.discover()
        let expected = Set(manifest.files.map { Data($0.path.utf8) })
        guard copy.inventory.isComplete, Set(copy.inventory.relativePDFPaths.map { Data($0.utf8) }) == expected else {
            throw Failure.verification(path: manifest.files.first?.path ?? "")
        }
        for file in manifest.files {
            let failure = Failure.verification(path: file.path)
            guard let exported = try? copy.facts(at: file.path).file.get(),
                  let original = try? source.facts(at: file.path).file.get(),
                  exported.revision.companionSHA256 == original.revision.companionSHA256,
                  exported.revision.fileID == original.revision.fileID,
                  exported.revision.content == original.revision.content,
                  exported.revision.facts == original.revision.facts else { throw failure }
            let record = original.pair.record
            for page in record.pages {
                let there = copy.facts(at: file.path, physicalPageIndex: page.physicalIndex)
                let here = source.facts(at: file.path, physicalPageIndex: page.physicalIndex)
                guard sameDocument(there.document, here.document) else { throw failure }
                switch (there.enclosure, here.enclosure) {
                case (nil, nil): break
                case (let a?, let b?): guard sameDocument(a, b) else { throw failure }
                default: throw failure
                }
            }
            if !file.preservation.isEmpty, record.documents.count == 1 {
                let occurrence = CatalogueAssociation.Occurrence(rootInstanceID: check.rootInstanceID, relativePath: file.path)
                for page in record.pages where page.sourcePageID != nil {
                    guard (try? PreservationCopy.status(in: check, at: occurrence, physicalPageIndex: page.physicalIndex)) != nil
                    else { throw failure }
                }
            }
        }
    }

    private static func sameDocument(_ a: Result<ItemFacts.DocumentFacts, ItemFacts.Unavailable>,
                                     _ b: Result<ItemFacts.DocumentFacts, ItemFacts.Unavailable>) -> Bool {
        guard let a = try? a.get(), let b = try? b.get() else { return false }
        return a.document.id == b.document.id && a.owner.revision.fileID == b.owner.revision.fileID
            && a.owner.revision.facts == b.owner.revision.facts
            && a.owner.revision.companionSHA256 == b.owner.revision.companionSHA256
            && Data(a.owner.pair.occurrence.relativePath.utf8) == Data(b.owner.pair.occurrence.relativePath.utf8)
    }

    // MARK: - Files

    /// The destination must be new and its folder must not be the archive or lie inside it. Ancestors are
    /// compared by device and inode, so a link, another spelling or a different letter case cannot hide the archive.
    static func checkDestination(_ destination: URL, archive: URL) throws {
        guard destination.isFileURL, !destination.lastPathComponent.isEmpty else { throw Failure.destinationUnavailable }
        var info = stat()
        guard lstat(destination.path, &info) != 0, errno == ENOENT else { throw Failure.destinationExists }
        var root = stat()
        guard stat(archive.path, &root) == 0 else { throw Failure.destinationUnavailable }
        var folder = destination.deletingLastPathComponent().resolvingSymlinksInPath()
        while true {
            var current = stat()
            guard stat(folder.path, &current) == 0 else { throw Failure.destinationUnavailable }
            if current.st_dev == root.st_dev, current.st_ino == root.st_ino { throw Failure.destinationInsideArchive }
            guard folder.path != "/" else { return }
            let up = folder.deletingLastPathComponent().resolvingSymlinksInPath()
            if up.path == folder.path { return }
            folder = up
        }
    }

    static func readSmall(_ entry: CatalogueReadDirectory.Entry) throws -> Data {
        guard entry.info.st_size <= CatalogueRecord.maximumBytes else { throw ItemFacts.Unavailable.invalid(.companion) }
        var bytes = Data()
        var offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let count = buffer.withUnsafeMutableBytes { pread(entry.descriptor, $0.baseAddress, $0.count, offset) }
            guard count >= 0 else { throw ItemFacts.Unavailable.invalid(.companion) }
            if count == 0 { break }
            bytes.append(contentsOf: buffer[0..<count])
            offset += off_t(count)
            guard bytes.count <= CatalogueRecord.maximumBytes else { throw ItemFacts.Unavailable.invalid(.companion) }
        }
        guard off_t(bytes.count) == entry.info.st_size else { throw ItemFacts.Unavailable.invalid(.companion) }
        return bytes
    }

    /// Copy from offset zero of an open, verified file into a new file. Returns the SHA-256 of what was written.
    /// A read that does not match the opened file's size reports `invalid(.pdf)`, which the caller names.
    static func copyFile(_ entry: CatalogueReadDirectory.Entry, to target: URL, expectedSize: Int64?) throws -> Data {
        if let expectedSize, entry.info.st_size != off_t(expectedSize) { throw ItemFacts.Unavailable.invalid(.pdf) }
        let output = target.withUnsafeFileSystemRepresentation { path in
            path.map { raw in open(raw, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644) } ?? -1
        }
        guard output >= 0 else { throw Failure.destinationUnavailable }
        defer { close(output) }
        var hash = SHA256()
        var offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { pread(entry.descriptor, $0.baseAddress, $0.count, offset) }
            guard count >= 0 else { throw ItemFacts.Unavailable.invalid(.pdf) }
            if count == 0 { break }
            try buffer.withUnsafeBytes { raw in
                var written = 0
                while written < count {
                    let step = Darwin.write(output, raw.baseAddress! + written, count - written)
                    guard step > 0 else { throw Failure.destinationUnavailable }
                    written += step
                }
            }
            hash.update(data: buffer[0..<count])
            offset += off_t(count)
        }
        guard offset == entry.info.st_size else { throw ItemFacts.Unavailable.invalid(.pdf) }
        guard fsync(output) == 0 else { throw Failure.destinationUnavailable }
        return Data(hash.finalize())
    }

    static func write(_ data: Data, to target: URL) throws {
        do {
            try data.write(to: target, options: [.withoutOverwriting])
        } catch {
            throw Failure.destinationUnavailable
        }
    }
}
