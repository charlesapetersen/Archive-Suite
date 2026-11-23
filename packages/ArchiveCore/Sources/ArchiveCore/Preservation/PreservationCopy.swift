import CryptoKit
import Darwin
import Foundation

/// The exact intake files and their association with the reading PDF's catalogue source pages.
public enum PreservationCopy {
    public static let directoryName = "Preservation"
    public static let manifestName = "pages.json"

    public static func folderComponents(documentID: UUID, fileID: UUID) -> [String] {
        [directoryName, documentID.uuidString.lowercased(), fileID.uuidString.lowercased()]
    }

    /// Reserve only the suite's preservation layout, so a collection named Preservation still works.
    public static func isPayloadPath(_ relativePath: String) -> Bool {
        guard relativePath.range(of: directoryName + "/", options: .caseInsensitive) != nil else { return false }
        let components = relativePath.utf8.split(separator: UInt8(ascii: "/"))
        return zip(components, components.dropFirst()).contains { parent, child in
            isDocumentFolder(String(decoding: child, as: UTF8.self), in: String(decoding: parent, as: UTF8.self))
        }
    }

    static func isDocumentFolder(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard UUID(uuidString: name) != nil else { return false }
        return url.deletingLastPathComponent().lastPathComponent.caseInsensitiveCompare(directoryName) == .orderedSame
    }

    private static func isDocumentFolder(_ name: String, in parent: String) -> Bool {
        UUID(uuidString: name) != nil && parent.caseInsensitiveCompare(directoryName) == .orderedSame
    }

    public enum Format: String, Codable, Sendable {
        case jpeg, heic, png, tiff, pdf

        public init?(extension suffix: String) {
            switch suffix.lowercased() {
            case "jpg", "jpeg": self = .jpeg
            case "heic", "heif": self = .heic
            case "png": self = .png
            case "tif", "tiff": self = .tiff
            case "pdf": self = .pdf
            default: return nil
            }
        }
    }

    public struct Fingerprint: Codable, Equatable, Sendable {
        public let byteCount: Int64
        public let sha256: Data

        public init(bytes: Data) {
            byteCount = Int64(bytes.count)
            sha256 = Data(SHA256.hash(data: bytes))
        }

        /// Reads the already opened file in bounded chunks. The caller checks descriptor identity and stability.
        public init(reading descriptor: Int32) throws {
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            try file.seek(toOffset: 0)
            var hash = SHA256()
            var count: Int64 = 0
            while let bytes = try file.read(upToCount: 1024 * 1024), !bytes.isEmpty {
                try Task.checkCancellation()
                count += Int64(bytes.count)
                hash.update(data: bytes)
            }
            byteCount = count
            sha256 = Data(hash.finalize())
        }
    }

    public struct Source: Codable, Equatable, Sendable {
        public let name: String
        public let format: Format
        public let fingerprint: Fingerprint

        public init(name: String, format: Format, fingerprint: Fingerprint) {
            self.name = name
            self.format = format
            self.fingerprint = fingerprint
        }

        /// Ordinals prevent collisions between two intake paths with the same name.
        public func storedName(at index: Int) -> String { "source-\(index + 1).\(format.rawValue)" }
    }

    public struct Page: Codable, Equatable, Sendable {
        public let id: UUID
        public let sourceIndex: Int
        public let originalPageIndex: Int

        public init(id: UUID, sourceIndex: Int, originalPageIndex: Int) {
            self.id = id
            self.sourceIndex = sourceIndex
            self.originalPageIndex = originalPageIndex
        }
    }

    public struct Manifest: Codable, Equatable, Sendable {
        public let fileID: UUID
        public let sources: [Source]
        public let pages: [Page]

        public init(fileID: UUID, sources: [Source], pages: [Page]) {
            self.fileID = fileID
            self.sources = sources
            self.pages = pages
        }

        public func encoded() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let bytes = try encoder.encode(self)
            guard bytes.count <= CatalogueRecord.maximumBytes else { throw Failure.unverified }
            return bytes
        }

        public func digest() throws -> Data { Data(SHA256.hash(data: try encoded())) }

        public func validate(against record: CatalogueRecord) throws {
            let expected = Set(record.pages.compactMap(\.sourcePageID))
            guard fileID == record.fileID, !pages.isEmpty, pages.count == expected.count,
                  Set(pages.map(\.id)) == expected,
                  Set(pages.map(\.sourceIndex)).count == sources.count,
                  sources.allSatisfy({ !$0.name.isEmpty && !$0.name.utf8.contains(0)
                    && !$0.name.utf8.contains(UInt8(ascii: "/"))
                    && $0.fingerprint.byteCount > 0 && $0.fingerprint.sha256.count == 32 }),
                  pages.allSatisfy({ sources.indices.contains($0.sourceIndex)
                    && $0.originalPageIndex >= 0 && $0.originalPageIndex < Int.max
                    && (sources[$0.sourceIndex].format == .pdf || $0.originalPageIndex == 0) }) else {
                throw Failure.unverified
            }
        }
    }

    public enum Failure: LocalizedError, Equatable, Sendable {
        /// The PDF or its verified catalogue record does not say that an original was retained.
        case notRecorded
        case missing
        case offline
        case unverified

        public var errorDescription: String? {
            switch self {
            case .notRecorded: "No preservation copy is recorded."
            case .missing: "The preservation copy is missing."
            case .offline: "The preservation copy is currently offline."
            case .unverified: "The preservation copy could not be verified."
            }
        }
    }

    public struct Selection: Equatable, Sendable {
        public let source: Source
        public let originalPageIndex: Int
    }

    public struct Original: Sendable {
        public let selection: Selection
        /// The same bytes that were verified, read through the granted directory.
        public let bytes: Data
        public let fileURL: URL
    }

    public static func status(in reader: CatalogueReader, at occurrence: CatalogueAssociation.Occurrence,
                              physicalPageIndex: Int, expected: CataloguePDFIdentity? = nil) throws -> Selection {
        try withOriginal(in: reader, at: occurrence, physicalPageIndex: physicalPageIndex, expected: expected) { selection, _ in selection }
    }

    public static func open(in reader: CatalogueReader, at occurrence: CatalogueAssociation.Occurrence,
                            physicalPageIndex: Int, expected: CataloguePDFIdentity? = nil) throws -> Original {
        try withOriginal(in: reader, at: occurrence, physicalPageIndex: physicalPageIndex, expected: expected) { selection, entry in
            let file = FileHandle(fileDescriptor: entry.descriptor, closeOnDealloc: false)
            var bytes = Data()
            var hash = SHA256()
            while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                bytes.append(chunk)
                guard bytes.count <= selection.source.fingerprint.byteCount else { throw Failure.unverified }
                hash.update(data: chunk)
            }
            guard bytes.count == selection.source.fingerprint.byteCount,
                  Data(hash.finalize()) == selection.source.fingerprint.sha256 else { throw Failure.unverified }
            return Original(selection: selection, bytes: bytes, fileURL: URL(fileURLWithPath: entry.path))
        }
    }

    private static func withOriginal<T>(in reader: CatalogueReader, at occurrence: CatalogueAssociation.Occurrence,
                                        physicalPageIndex: Int, expected: CataloguePDFIdentity?,
                                        _ action: (Selection, CatalogueReadDirectory.Entry) throws -> T) throws -> T {
        do {
            return try reader.withOccurrence(occurrence) { _, parent, filename in
                let companion = CatalogueRecord.companionFilename(forPDFFilename: filename)
                let record: CatalogueRecord
                do {
                    record = try reader.directory.withFile(companion, in: parent, artifact: .companion,
                                                            CatalogueReader.record(in:))
                } catch ItemFacts.Unavailable.missing {
                    throw Failure.notRecorded
                }
                return try reader.withProvenPDF(filename, in: parent, at: occurrence) { _, proof in
                    if let expected, proof.fileID != expected.fileID || proof.contentRevision != expected.contentRevision {
                        throw Failure.unverified
                    }
                    _ = try CatalogueAssociation.pair(record, at: occurrence, verifiedBy: proof)
                    guard let manifestDigest = record.preservationManifestSHA256 else { throw Failure.notRecorded }
                    guard let page = record.pages.first(where: { $0.physicalIndex == physicalPageIndex }),
                          let pageID = page.sourcePageID, record.documents.count == 1 else { throw Failure.unverified }
                    let path = folderComponents(documentID: page.documentID, fileID: record.fileID)
                    return try reader.directory.withParent(path[...], in: parent) { folder in
                        let manifest = try reader.directory.withFile(manifestName, in: folder, artifact: .companion) { entry in
                            let file = FileHandle(fileDescriptor: entry.descriptor, closeOnDealloc: false)
                            let limit = CatalogueRecord.maximumBytes
                            guard entry.info.st_size <= limit else { throw Failure.unverified }
                            let data = try file.read(upToCount: limit + 1) ?? Data()
                            guard Data(SHA256.hash(data: data)) == manifestDigest else { throw Failure.unverified }
                            try CatalogueJSON.check(data, maximumBytes: limit)
                            return try JSONDecoder().decode(Manifest.self, from: data)
                        }
                        try manifest.validate(against: record)
                        guard let page = manifest.pages.first(where: { $0.id == pageID }) else { throw Failure.unverified }
                        let source = manifest.sources[page.sourceIndex]
                        let selection = Selection(source: source, originalPageIndex: page.originalPageIndex)
                        return try reader.directory.withFile(source.storedName(at: page.sourceIndex), in: folder,
                                                             artifact: .companion) { entry in
                            guard entry.info.st_size == source.fingerprint.byteCount else { throw Failure.unverified }
                            return try action(selection, entry)
                        }
                    }
                }
            }
        } catch let failure as Failure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch ItemFacts.Unavailable.missing {
            throw Failure.missing
        } catch ItemFacts.Unavailable.offline {
            throw Failure.offline
        } catch {
            throw Failure.unverified
        }
    }
}
