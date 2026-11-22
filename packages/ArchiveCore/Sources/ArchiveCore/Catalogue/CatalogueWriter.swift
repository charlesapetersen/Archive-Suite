import Darwin
import Foundation

/// The local, coordinated write boundary for existing catalogue companions. The caller holds
/// the reader's resolved root grant and selects an adopted root on a supported local filesystem.
public struct CatalogueWriter: Sendable {
    public struct Receipt: Sendable {
        /// The live record immediately before this operation, which can differ from the edit base.
        public let before: ItemFacts.FileFacts
        public let after: ItemFacts.FileFacts
        /// Nil when there was no change. The named sibling retains the exact before-image.
        public let recoveryArtifact: String?
    }

    public struct Conflict: Error, Sendable {
        public enum Reason: Sendable, Equatable {
            case overlappingFields([CatalogueEdit.Target])
            case unverifiedHistory
        }

        public let reason: Reason
        public let current: ItemFacts.FileFacts
        /// The user's intent applied to the original base, available for explicit reconciliation.
        public let proposed: CatalogueRecord
    }

    public enum Failure: Error, Sendable, Equatable {
        case unsupportedVolume
        case busy
        case io(operation: String, code: Int32)
        case changedDuringSave
        case recoveryRequired(artifact: String, reason: String)
    }

    enum Boundary { case staged, beforeExchange, exchanged }

    let reader: CatalogueReader
    let boundary: @Sendable (Boundary) throws -> Void

    public init(reader: CatalogueReader) {
        self.init(reader: reader, boundary: { _ in })
    }

    init(reader: CatalogueReader, boundary: @escaping @Sendable (Boundary) throws -> Void) {
        self.reader = reader
        self.boundary = boundary
    }

    /// Serialize saves on this parent directory, including saves from other cooperating processes.
    /// A stale edit is rebased only through verified local history and onto untouched field envelopes.
    public func save(_ edits: [CatalogueEdit], basedOn base: ItemFacts.FileFacts) throws -> Receipt {
        let occurrence = base.pair.occurrence
        let patch = CatalogueEditPatch(edits: edits)
        var recoveryArtifact: String?
        do {
            return try reader.withOccurrence(occurrence) { root, parent, filename in
                try withLock(on: parent) {
                    let scope = Scope(root: root, parent: parent, filename: filename, base: base)
                    let live = try readLive(in: scope)
                    let baseRecord = base.pair.record
                    let proposed = try patch.applying(to: baseRecord)
                    let candidate: CatalogueRecord
                    if live.facts.revision == base.revision {
                        candidate = proposed
                    } else {
                        guard try descends(live.facts.pair.record, from: baseRecord, in: scope) else {
                            throw Conflict(reason: .unverifiedHistory, current: live.facts, proposed: proposed)
                        }
                        let overlaps = try patch.conflicts(base: baseRecord, current: live.facts.pair.record)
                        guard overlaps.isEmpty else {
                            throw Conflict(reason: .overlappingFields(overlaps), current: live.facts, proposed: proposed)
                        }
                        candidate = try patch.applying(to: live.facts.pair.record)
                    }
                    guard candidate.revision != live.facts.revision.facts else {
                        return Receipt(before: live.facts, after: live.facts, recoveryArtifact: nil)
                    }
                    let artifact = CatalogueEditArtifact(filename: filename, pdf: base.pdfVersion.identity,
                                                         before: live.facts.pair.record, after: candidate)
                    let staged = try stage(candidate, as: artifact.name, replacing: live, in: scope) {
                        recoveryArtifact = artifact.name
                    }
                    try boundary(.staged)
                    let latest = try readLive(in: scope)
                    guard latest.version == live.version, latest.facts.revision == live.facts.revision else {
                        throw Failure.changedDuringSave
                    }
                    let candidateFile = try readRecord(artifact.name, in: parent)
                    guard candidateFile.version == staged, candidateFile.record.originalJSON == candidate.originalJSON else {
                        throw Failure.changedDuringSave
                    }
                    try boundary(.beforeExchange)
                    // The reads above validate contents. Check the exact entries again immediately
                    // before exchanging names, since the lock only constrains cooperating writers.
                    try reader.validateScope(root: root, parent: parent)
                    guard try version(of: scope.filename, in: parent) == base.pdfVersion,
                          try version(of: scope.companion, in: parent) == live.version,
                          try version(of: artifact.name, in: parent) == staged else {
                        throw Failure.changedDuringSave
                    }
                    try exchange(artifact.name, with: scope.companion, in: parent)
                    try boundary(.exchanged)
                    try reader.validateScope(root: root, parent: parent)

                    let published = try version(of: scope.companion, in: parent)
                    guard published.identity == staged.identity else { throw Failure.changedDuringSave }
                    let displaced = try version(of: artifact.name, in: parent)
                    let verified: (facts: ItemFacts.FileFacts, version: CatalogueReadDirectory.FileVersion)
                    do {
                        let prior = try readRecord(artifact.name, in: parent)
                        guard prior.version == displaced, prior.version.identity == live.version.identity,
                              prior.record.originalJSON == live.facts.pair.record.originalJSON else {
                            throw Failure.changedDuringSave
                        }
                        verified = try readLive(in: scope)
                        guard verified.version == published,
                              verified.facts.pair.record.originalJSON == candidate.originalJSON else {
                            throw Failure.changedDuringSave
                        }
                    } catch {
                        try restore(published: published, displaced: displaced, artifact: artifact.name, in: scope)
                        throw error
                    }
                    try sync(parent.descriptor, operation: "flush exchange")
                    return Receipt(before: live.facts, after: verified.facts, recoveryArtifact: artifact.name)
                }
            }
        } catch {
            if let recoveryArtifact {
                throw Failure.recoveryRequired(artifact: recoveryArtifact, reason: String(describing: error))
            }
            throw error
        }
    }

    struct Scope {
        let root: CatalogueReadDirectory.Entry
        let parent: CatalogueReadDirectory.Entry
        let filename: String
        let base: ItemFacts.FileFacts
        var companion: String { CatalogueRecord.companionFilename(forPDFFilename: filename) }
        var occurrence: CatalogueAssociation.Occurrence { base.pair.occurrence }
    }

    struct ReadRecord {
        let record: CatalogueRecord
        let version: CatalogueReadDirectory.FileVersion
    }

    func readRecord(_ name: String, in parent: CatalogueReadDirectory.Entry) throws -> ReadRecord {
        try reader.directory.withFile(name, in: parent, artifact: .companion) { entry in
            ReadRecord(record: try CatalogueReader.record(in: entry), version: .init(entry.info))
        }
    }

    func readLive(in scope: Scope) throws -> (facts: ItemFacts.FileFacts, version: CatalogueReadDirectory.FileVersion) {
        do {
            try reader.validateScope(root: scope.root, parent: scope.parent)
            return try reader.withProvenPDF(scope.filename, in: scope.parent, at: scope.occurrence, expectedBase: scope.base) { pdf, proof in
                let live = try readRecord(scope.companion, in: scope.parent)
                let facts = try reader.fileFacts(live.record, at: scope.occurrence, proof: proof, pdf: pdf)
                return (facts, live.version)
            }
        } catch {
            throw CatalogueReader.companionStatus(error)
        }
    }

    func withLock<T>(on parent: CatalogueReadDirectory.Entry, _ body: () throws -> T) throws -> T {
        var volume = statfs()
        guard fstatfs(parent.descriptor, &volume) == 0 else { throw Failure.io(operation: "inspect volume", code: errno) }
        guard volume.f_flags & UInt32(MNT_LOCAL) != 0 else { throw Failure.unsupportedVolume }
        let deadline = DispatchTime.now() + .seconds(5)
        while flock(parent.descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            guard code == EINTR || code == EWOULDBLOCK else { throw Failure.io(operation: "lock parent", code: code) }
            guard DispatchTime.now() < deadline else { throw Failure.busy }
            usleep(20_000)
        }
        defer { _ = flock(parent.descriptor, LOCK_UN) }
        return try body()
    }

    private func stage(_ record: CatalogueRecord, as name: String,
                       replacing live: (facts: ItemFacts.FileFacts, version: CatalogueReadDirectory.FileVersion),
                       in scope: Scope, created: () -> Void) throws -> CatalogueReadDirectory.FileVersion {
        let parent = scope.parent
        try reader.validateScope(root: scope.root, parent: parent)
        guard faccessat(parent.descriptor, scope.companion, W_OK, AT_EACCESS | AT_SYMLINK_NOFOLLOW) == 0 else {
            throw Failure.io(operation: "check companion write access", code: errno)
        }
        let fd = try createExclusive(name, in: parent)
        created()
        defer { close(fd) }
        try write(record.originalJSON, to: fd)
        // Preserve permissions, ACLs and xattrs of the existing JSON. Never open a PDF for writing.
        try reader.directory.withFile(scope.companion, in: parent, artifact: .companion) { source in
            guard CatalogueReadDirectory.FileVersion(source.info) == live.version else { throw Failure.changedDuringSave }
            guard fcopyfile(source.descriptor, fd, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else {
                throw Failure.io(operation: "copy companion filesystem metadata", code: errno)
            }
            var copy = stat()
            guard fstat(fd, &copy) == 0, copy.st_uid == source.info.st_uid,
                  copy.st_gid == source.info.st_gid, copy.st_mode == source.info.st_mode,
                  copy.st_flags == source.info.st_flags else { throw Failure.changedDuringSave }
        }
        try sync(fd, operation: "flush staged companion")
        try sync(parent.descriptor, operation: "flush staged name")
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Failure.io(operation: "inspect staged companion", code: errno) }
        return .init(info)
    }

    func createExclusive(_ name: String, in parent: CatalogueReadDirectory.Entry) throws -> Int32 {
        let fd = openat(parent.descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.io(operation: "create new catalogue file", code: errno) }
        return fd
    }

    func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.io(operation: "write new catalogue file", code: count == 0 ? EIO : errno) }
                written += count
            }
        }
    }

    private func version(of name: String, in parent: CatalogueReadDirectory.Entry) throws -> CatalogueReadDirectory.FileVersion {
        var info = stat()
        guard fstatat(parent.descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw Failure.io(operation: "inspect exchanged name", code: errno)
        }
        return .init(info)
    }

    private func restore(published: CatalogueReadDirectory.FileVersion, displaced: CatalogueReadDirectory.FileVersion,
                         artifact: String, in scope: Scope) throws {
        // Restore an external edit that won the race to the swap, even if it was unreadable.
        // Neither path is followed or deleted. If a name changed again, leave both for recovery.
        guard try version(of: scope.companion, in: scope.parent) == published,
              try version(of: artifact, in: scope.parent) == displaced else {
            throw Failure.changedDuringSave
        }
        try reader.validateScope(root: scope.root, parent: scope.parent)
        try exchange(artifact, with: scope.companion, in: scope.parent)
        try sync(scope.parent.descriptor, operation: "flush restored companion")
    }

    private func exchange(_ artifact: String, with companion: String, in parent: CatalogueReadDirectory.Entry) throws {
        guard renameatx_np(parent.descriptor, artifact, parent.descriptor, companion, UInt32(RENAME_SWAP)) == 0 else {
            throw Failure.io(operation: "exchange companion", code: errno)
        }
    }

    func sync(_ descriptor: Int32, operation: String) throws {
        while fsync(descriptor) != 0 {
            let code = errno
            guard code == EINTR else { throw Failure.io(operation: operation, code: code) }
        }
    }
}
