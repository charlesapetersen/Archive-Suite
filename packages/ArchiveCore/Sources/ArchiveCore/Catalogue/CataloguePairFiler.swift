import CryptoKit
import Darwin
import Foundation

/// Files a newly prepared PDF and its initial catalogue companion in one granted local directory.
public struct CataloguePairFiler: Sendable {
    public struct Receipt: Equatable, Sendable {
        public let operationID: UUID
        public let pdfRelativePath: String
        public let companionRelativePath: String
    }

    public enum Failure: Error, Equatable, Sendable {
        case journalMissing
        case journalInvalid
        case operationMismatch
        case occupied(String)
        case missing(String)
        case changed(String)
    }

    enum Boundary: CaseIterable {
        case companionStaged, journalFlushed, pdfPublished, companionPublished, verified, receiptRenamed
    }

    private let writer: CatalogueWriter
    private let boundary: @Sendable (Boundary) throws -> Void

    public init(reader: CatalogueReader) {
        self.init(reader: reader, boundary: { _ in })
    }

    init(reader: CatalogueReader, boundary: @escaping @Sendable (Boundary) throws -> Void) {
        writer = CatalogueWriter(reader: reader)
        self.boundary = boundary
    }

    /// The caller persists its operation ID and final occurrence, and stages a finished derivative
    /// under this reserved name beside the destination. The caller keeps the original input
    /// and preserves existing staging on retry. The PDF identifier must inspect the borrowed descriptor, including at staging.
    public static func stagedPDFName(for operationID: UUID) -> String {
        prefix(operationID) + ".pdf.pending"
    }

    /// Start or retry initial filing. An existing journal takes precedence over new staging.
    /// For interruption before the journal exists, retry with the same record and staged PDF.
    public func filePair(operationID: UUID, at occurrence: CatalogueAssociation.Occurrence,
                         record: CatalogueRecord) throws -> Receipt {
        try run(operationID: operationID, at: occurrence, initialRecord: record)
    }

    /// Resume a journaled operation, or reverify its completed receipt after relaunch. Missing,
    /// changed or obstructed files withhold a receipt and keep every available artifact in place.
    public func recoverPair(operationID: UUID, at occurrence: CatalogueAssociation.Occurrence) throws -> Receipt {
        try run(operationID: operationID, at: occurrence, initialRecord: nil)
    }

    private typealias Directory = CatalogueReadDirectory

    private struct Paths: Codable {
        let pdfRelativePath: String
        let companionRelativePath: String
        let pendingPDF: String
        let pendingCompanion: String
        let finalPDF: String
        let finalCompanion: String

        init(operationID: UUID, occurrence: CatalogueAssociation.Occurrence, filename: String) {
            pdfRelativePath = occurrence.relativePath
            finalPDF = filename
            finalCompanion = CatalogueRecord.companionFilename(forPDFFilename: filename)
            companionRelativePath = String(decoding: occurrence.relativePath.utf8.dropLast(filename.utf8.count), as: UTF8.self) + finalCompanion
            pendingPDF = CataloguePairFiler.stagedPDFName(for: operationID)
            pendingCompanion = CataloguePairFiler.prefix(operationID) + ".json.pending"
        }

        func matches(_ other: Paths) -> Bool {
            zip([pdfRelativePath, companionRelativePath, pendingPDF, pendingCompanion, finalPDF, finalCompanion],
                [other.pdfRelativePath, other.companionRelativePath, other.pendingPDF, other.pendingCompanion,
                 other.finalPDF, other.finalCompanion]).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
        }
    }

    private struct Member: Codable, Equatable {
        let identity: Directory.Identity
        let digest: Data
    }

    private struct Journal: Codable {
        let operationID: UUID
        let paths: Paths
        let rootInstanceID: UUID
        let root: Directory.Identity
        let parent: Directory.Identity
        let pdf: Member
        let companion: Member
    }

    private struct Scope {
        let root: Directory.Entry
        let parent: Directory.Entry
        let occurrence: CatalogueAssociation.Occurrence
        let paths: Paths
        let operationID: UUID

        var pendingJournal: String { CataloguePairFiler.prefix(operationID) + ".journal" }
        var completedJournal: String { CataloguePairFiler.prefix(operationID) + ".receipt" }
    }

    private struct Located {
        let name: String
        let version: Directory.FileVersion
        let otherName: String
        let isFinal: Bool
    }

    private var reader: CatalogueReader { writer.reader }

    private static func prefix(_ operationID: UUID) -> String {
        ".archivesuite-pair-" + operationID.uuidString.lowercased()
    }

    private func run(operationID: UUID, at occurrence: CatalogueAssociation.Occurrence,
                     initialRecord: CatalogueRecord?) throws -> Receipt {
        try reader.withOccurrence(occurrence) { root, parent, filename in
            let paths = Paths(operationID: operationID, occurrence: occurrence, filename: filename)
            guard paths.finalCompanion.utf8.count <= NAME_MAX,
                  paths.companionRelativePath.utf8.count < MAXPATHLEN else {
                throw ItemFacts.Unavailable.invalid(.companion)
            }
            let scope = Scope(root: root, parent: parent, occurrence: occurrence, paths: paths, operationID: operationID)
            return try writer.withLock(on: parent) {
                try reader.validateScope(root: root, parent: parent)
                let pending = try version(scope.pendingJournal, in: scope)
                let completed = try version(scope.completedJournal, in: scope)
                guard pending == nil || completed == nil else { throw Failure.journalInvalid }
                let journalName: String
                if completed != nil {
                    journalName = scope.completedJournal
                } else {
                    journalName = scope.pendingJournal
                    if pending == nil {
                        guard let initialRecord else { throw Failure.journalMissing }
                        try prepare(initialRecord, in: scope)
                    }
                }
                let (journal, stamp) = try readJournal(journalName, in: scope)
                if let initialRecord, Self.digest(initialRecord.originalJSON) != journal.companion.digest {
                    throw Failure.operationMismatch
                }
                // Also flush on recovery, in case the prior process stopped before its flush returned.
                try writer.sync(parent.descriptor, operation: "flush filing journal name")
                return try finish(journal, stamp: stamp, journalName: journalName, in: scope)
            }
        }
    }

    private func prepare(_ record: CatalogueRecord, in scope: Scope) throws {
        let paths = scope.paths
        for name in [paths.finalPDF, paths.finalCompanion] {
            guard try version(name, in: scope) == nil else { throw Failure.occupied(name) }
        }
        let pdf = try verifiedPDF(paths.pendingPDF, record: record, flush: true, in: scope).member
        if try version(paths.pendingCompanion, in: scope) == nil {
            try create(record.originalJSON, as: paths.pendingCompanion, in: scope)
        }
        let companion = try reader.directory.withFile(paths.pendingCompanion, in: scope.parent, artifact: .companion) { entry in
            let staged = try CatalogueReader.record(in: entry)
            guard staged.originalJSON == record.originalJSON else { throw Failure.changed(paths.pendingCompanion) }
            try writer.sync(entry.descriptor, operation: "flush pending companion")
            return Member(identity: .init(entry.info), digest: Self.digest(staged.originalJSON))
        }
        try writer.sync(scope.parent.descriptor, operation: "flush pending pair names")
        try boundary(.companionStaged)
        let journal = Journal(operationID: scope.operationID, paths: paths,
                              rootInstanceID: scope.occurrence.rootInstanceID,
                              root: .init(scope.root.info), parent: .init(scope.parent.info),
                              pdf: pdf, companion: companion)
        try create(JSONEncoder().encode(journal), as: scope.pendingJournal, in: scope)
        try writer.sync(scope.parent.descriptor, operation: "flush filing journal")
        try boundary(.journalFlushed)
    }

    private func finish(_ journal: Journal, stamp: Directory.FileVersion, journalName: String,
                        in scope: Scope) throws -> Receipt {
        let paths = scope.paths
        var (pdf, companion) = try inspect(journal, in: scope)
        if journalName == scope.pendingJournal {
            if !pdf.isFinal {
                try validate([pdf, companion], journal: journalName, stamp: stamp, in: scope)
                try claimName(pdf.name, to: paths.finalPDF, in: scope)
                try writer.sync(scope.parent.descriptor, operation: "flush filed PDF name")
                try boundary(.pdfPublished)
                (pdf, companion) = try inspect(journal, in: scope)
            }
            if !companion.isFinal {
                try validate([pdf, companion], journal: journalName, stamp: stamp, in: scope)
                try claimName(companion.name, to: paths.finalCompanion, in: scope)
                try writer.sync(scope.parent.descriptor, operation: "flush filed companion name")
                try boundary(.companionPublished)
                (pdf, companion) = try inspect(journal, in: scope)
            }
        }
        guard pdf.isFinal, companion.isFinal else { throw Failure.journalInvalid }
        let pair = [pdf, companion]
        try boundary(.verified)
        try validate(pair, journal: journalName, stamp: stamp, in: scope)
        if journalName == scope.pendingJournal {
            try claimName(journalName, to: scope.completedJournal, in: scope)
            try boundary(.receiptRenamed)
        }
        try writer.sync(scope.parent.descriptor, operation: "flush filing receipt")
        // The rename can change ctime. Re-open the receipt and confirm it is the original journal.
        let (receipt, receiptStamp) = try readJournal(scope.completedJournal, in: scope)
        guard receiptStamp.identity == stamp.identity, receipt.pdf == journal.pdf,
              receipt.companion == journal.companion else { throw Failure.journalInvalid }
        try validate(pair, journal: scope.completedJournal, stamp: receiptStamp, in: scope)
        return Receipt(operationID: scope.operationID, pdfRelativePath: paths.pdfRelativePath,
                       companionRelativePath: paths.companionRelativePath)
    }

    private func inspect(_ journal: Journal, in scope: Scope) throws -> (Located, Located) {
        let paths = scope.paths
        let pdf = try locate(journal.pdf, pending: paths.pendingPDF, final: paths.finalPDF, in: scope)
        let companion = try locate(journal.companion, pending: paths.pendingCompanion, final: paths.finalCompanion, in: scope)
        let record = try reader.directory.withFile(companion.name, in: scope.parent, artifact: .companion) { entry in
            let record = try CatalogueReader.record(in: entry)
            guard Directory.FileVersion(entry.info) == companion.version,
                  Self.digest(record.originalJSON) == journal.companion.digest else { throw Failure.changed(companion.name) }
            return record
        }
        let checked = try verifiedPDF(pdf.name, record: record, in: scope)
        guard checked.version == pdf.version, checked.member == journal.pdf else { throw Failure.changed(pdf.name) }
        return (pdf, companion)
    }

    private func locate(_ member: Member, pending: String, final: String, in scope: Scope) throws -> Located {
        let pendingVersion = try version(pending, in: scope)
        if let finalVersion = try version(final, in: scope) {
            guard finalVersion.identity == member.identity else { throw Failure.occupied(final) }
            guard pendingVersion == nil else { throw Failure.occupied(pending) }
            return Located(name: final, version: finalVersion, otherName: pending, isFinal: true)
        }
        guard let pendingVersion else { throw Failure.missing(pending) }
        guard pendingVersion.identity == member.identity else { throw Failure.changed(pending) }
        return Located(name: pending, version: pendingVersion, otherName: final, isFinal: false)
    }

    private func verifiedPDF(_ name: String, record: CatalogueRecord, flush: Bool = false, in scope: Scope)
        throws -> (member: Member, version: Directory.FileVersion) {
        try reader.withProvenPDF(name, in: scope.parent, at: scope.occurrence) { entry, proof in
            _ = try CatalogueAssociation.pair(record, at: scope.occurrence, verifiedBy: proof)
            // The PDF proof callback may have consumed the descriptor.
            let file = FileHandle(fileDescriptor: entry.descriptor, closeOnDealloc: false)
            try file.seek(toOffset: 0)
            var digest = SHA256()
            while let bytes = try file.read(upToCount: 1024 * 1024), !bytes.isEmpty {
                digest.update(data: bytes)
            }
            if flush { try writer.sync(entry.descriptor, operation: "flush pending PDF") }
            return (Member(identity: .init(entry.info), digest: Data(digest.finalize())), .init(entry.info))
        }
    }

    private func validate(_ pair: [Located], journal: String, stamp: Directory.FileVersion, in scope: Scope) throws {
        try reader.validateScope(root: scope.root, parent: scope.parent)
        let other = journal == scope.pendingJournal ? scope.completedJournal : scope.pendingJournal
        guard try version(journal, in: scope) == stamp, try version(other, in: scope) == nil else {
            throw Failure.journalInvalid
        }
        for member in pair {
            guard try version(member.name, in: scope) == member.version else { throw Failure.changed(member.name) }
            guard try version(member.otherName, in: scope) == nil else { throw Failure.occupied(member.otherName) }
        }
    }

    private func readJournal(_ name: String, in scope: Scope) throws -> (Journal, Directory.FileVersion) {
        try reader.directory.withFile(name, in: scope.parent, artifact: .companion) { entry in
            let maximumBytes = 16 * 1024
            let file = FileHandle(fileDescriptor: entry.descriptor, closeOnDealloc: false)
            guard entry.info.st_size <= maximumBytes, let bytes = try file.read(upToCount: maximumBytes + 1),
                  let journal = try? JSONDecoder().decode(Journal.self, from: bytes),
                  journal.pdf.digest.count == 32, journal.companion.digest.count == 32 else {
                throw Failure.journalInvalid
            }
            guard journal.operationID == scope.operationID, journal.paths.matches(scope.paths),
                  journal.rootInstanceID == scope.occurrence.rootInstanceID,
                  journal.root == .init(scope.root.info), journal.parent == .init(scope.parent.info) else {
                throw Failure.operationMismatch
            }
            try writer.sync(entry.descriptor, operation: "flush filing journal bytes")
            return (journal, .init(entry.info))
        }
    }

    private func create(_ data: Data, as name: String, in scope: Scope) throws {
        try reader.validateScope(root: scope.root, parent: scope.parent)
        let descriptor = try writer.createExclusive(name, in: scope.parent)
        defer { close(descriptor) }
        try writer.write(data, to: descriptor)
        try writer.sync(descriptor, operation: "flush \(name)")
    }

    private func version(_ name: String, in scope: Scope) throws -> Directory.FileVersion? {
        var info = stat()
        if fstatat(scope.parent.descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return .init(info) }
        let code = errno
        if code == ENOENT { return nil }
        throw CatalogueWriter.Failure.io(operation: "inspect \(name)", code: code)
    }

    private func claimName(_ source: String, to target: String, in scope: Scope) throws {
        let parent = scope.parent.descriptor
        guard renameatx_np(parent, source, parent, target, UInt32(RENAME_EXCL)) == 0 else {
            throw CatalogueWriter.Failure.io(operation: "file \(target)", code: errno)
        }
    }

    private static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
}
