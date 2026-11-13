import ArchiveCore
import CryptoKit
import Darwin
import Foundation

// MARK: - Improve OCR: publishing an accepted candidate (W44.reocr-processor)

/// One file's recoverable Improve OCR transaction (`execution-plans/reocr/00-plan.md` §5). The only code that replaces
/// a PDF's contents for this feature; it writes nothing else in the archive.
///
/// 1. `prepare` snapshots the target under a coordinated read (identity, change time, size, SHA-256, metadata) and
///    keeps a verified complete copy of it, data and metadata, in `Versions/<operation>/original.pdf`, with a
///    `prepared` journal, before anything else happens. The only original is never renamed away.
/// 2. The candidate is built and reviewed elsewhere (`ReOCRIncrementalWriter`), outside any lock.
/// 3. `accept` coordinates a replacement and refuses a target whose identity or bytes moved since `prepare`. It writes the candidate to a sibling temporary file, stages the target's CURRENT metadata onto it
///    (extended attributes, so Finder tags and label and the resource fork; ACL, mode, flags; creation, modification
///    and date-added), verifies it, and journals `acceptReady` with the staged metadata and the temporary file's
///    inode. It checks the target once more (now its change time too, so no edit since staging slips by) and swaps the two files in one step (`RENAME_SWAP`), then confirms the
///    file it displaced is still the one it read (else swaps back), verifies the published file and journals
///    `published`. Any failure before the swap returns the journal to `prepared`.
/// 4. `recover` settles a journal a crash left behind by what is on disk. A `prepared` journal published nothing. An
///    `acceptReady` one is published only when the live file is the staged inode with the candidate's bytes and the
///    staged metadata; the original live means nothing was published; anything else is a conflict, reported and
///    touched no further. It never deletes a kept original, writes the target or re-runs a read.
///
/// The file's inode and change time do change on publication; nothing claims otherwise. Flag clearing, receipts,
/// restore and the cross-process flag lock (which `recover` must run under) are separate steps on top of `published`.
struct ReOCRFileWriter {
    /// `<Processor Application Support>/ImproveOCR/Versions`.
    let versionsRoot: URL

    enum Phase: String, Codable, Sendable { case prepared, acceptReady, published }

    /// A time as the file system keeps it, to the nanosecond.
    struct Stamp: Codable, Equatable, Sendable {
        var seconds: Int
        var nanoseconds: Int
        init(_ t: Darwin.timespec) { seconds = t.tv_sec; nanoseconds = t.tv_nsec }
        var value: Darwin.timespec { Darwin.timespec(tv_sec: seconds, tv_nsec: nanoseconds) }
    }

    struct Snapshot: Codable, Equatable, Sendable {
        let device: Int32
        let inode: UInt64
        let changed: Stamp
        let size: Int64
        let sha256: String

        /// The same file with the same bytes; the change time is left out, since a tag edit moves it.
        func sameContent(_ o: Snapshot) -> Bool { device == o.device && inode == o.inode && size == o.size && sha256 == o.sha256 }
    }

    struct Journal: Codable, Equatable, Sendable {
        let operationID: UUID
        /// The path the coordinator handed over, which every later step uses.
        let targetPath: String
        let created: Date
        let original: Snapshot
        /// The original's metadata at `prepare`, for restore.
        let originalMetadata: Metadata
        var phase: Phase
        var candidateSHA256: String?
        var candidateSize: Int64?
        /// What `acceptReady` staged: the metadata put on the candidate and the inode the swap publishes.
        var stagedMetadata: Metadata?
        var stagedInode: UInt64?
    }

    struct Operation: Equatable, Sendable {
        let journal: Journal
        var target: URL { URL(fileURLWithPath: journal.targetPath) }
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case notARegularFile(String)
        case locked
        case unreadable(String)
        case insufficientSpace(needed: Int64, available: Int64)
        case backupFailed(String)
        case targetChanged
        case candidateWriteFailed(String)
        case metadataNotPreserved(String)
        case coordination(String)
        case journal(String)
        case publishFailed(String)
        case publishedButUnverified(String)
        case publishedRecordPending(String)
        case notOwned

        var description: String {
            switch self {
            case .notARegularFile(let p): "\(p) is not a regular file"
            case .locked: "the file is locked (Finder's Locked, or append-only); unlock it to improve its text"
            case .unreadable(let why): "the file cannot be read: \(why)"
            case .insufficientSpace(let n, let a): "not enough free space (needs \(n) bytes, \(a) available)"
            case .backupFailed(let why): "the original could not be kept safely: \(why)"
            case .targetChanged: "the file changed since it was read; select it again"
            case .candidateWriteFailed(let why): "the new file could not be written: \(why)"
            case .metadataNotPreserved(let why): "the file's tags, dates or permissions could not be kept: \(why)"
            case .coordination(let why): "the file could not be locked for writing: \(why)"
            case .journal(let why): "the record of this change could not be written: \(why)"
            case .publishFailed(let why): "the new file could not be put in place: \(why)"
            case .publishedButUnverified(let why): "the new file is in place but did not verify: \(why)"
            case .publishedRecordPending(let why): "the new file is in place and verified; its record is finished at next launch (\(why))"
            case .notOwned: "the file belongs to another user or group, so its owner could not be kept"
            }
        }
    }

    /// Where a test steps in (DEBUG drivers only), in this order, each at most once per call. Throwing
    /// `InjectedCrash` stands in for a dead process, which cleans up nothing; any other error, or a closure that
    /// changes the file and returns, is a failure the transaction must handle.
    enum FaultPoint: String, CaseIterable, Sendable {
        case afterBackup, afterTemporaryWrite, afterAcceptReady, beforeSwap, justAfterSwap, afterSwap
    }
    struct InjectedCrash: Error {}
    typealias Faults = (FaultPoint) throws -> Void

    // MARK: Prepare

    func prepare(target: URL, faults: Faults = { _ in }) throws -> Operation {
        // A link is refused before coordination could resolve it.
        _ = try Self.snapshot(target.path)
        let id = UUID()
        let dir = versionsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        var made: (Snapshot, Metadata, String)?
        var failure: Error?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: Self.fresh(target), options: [], error: &coordError) { url in
            do {
                let path = url.path
                let snap = try Self.snapshot(path)
                let meta = try Self.metadata(path)
                if meta.uid != getuid() { throw Failure.notOwned }
                // The kept original here, the candidate's temporary file beside the target, and slack.
                let slack: Int64 = 16 << 20
                for (volume, needed) in [(versionsRoot, snap.size + slack), (url.deletingLastPathComponent(), snap.size * 2 + slack)] {
                    if let available = Self.availableBytes(volume), available < needed {
                        throw Failure.insufficientSpace(needed: needed, available: available)
                    }
                }
                try Self.makePrivateDirectory(versionsRoot)
                try Self.makePrivateDirectory(dir)
                let backup = dir.appendingPathComponent("original.pdf").path
                guard copyfile(path, backup, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_NOFOLLOW)) == 0 else {
                    throw Failure.backupFailed(String(cString: strerror(errno)))
                }
                guard try Self.snapshot(backup).sha256 == snap.sha256 else {
                    throw Failure.backupFailed("the copy does not match the original")
                }
                // The copy's own dates are its own; restore puts back the journal's. Everything else must match.
                if let diff = Self.metadataDifference(meta, try Self.metadata(backup), dates: false) {
                    throw Failure.backupFailed("the copy's \(diff)")
                }
                try Self.sync(backup)
                try Self.syncDirectory(dir.path)
                made = (snap, meta, path)
            } catch { failure = error }
        }
        if let coordError { throw Failure.coordination(coordError.localizedDescription) }
        if let failure { throw failure }
        guard let (snapshot, meta, path) = made else { throw Failure.unreadable("no snapshot") }
        try faults(.afterBackup)
        let journal = Journal(operationID: id, targetPath: path, created: Date(), original: snapshot,
                              originalMetadata: meta, phase: .prepared)
        try write(journal)
        return Operation(journal: journal)
    }

    /// The kept original of an operation.
    func backupURL(_ id: UUID) -> URL {
        versionsRoot.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent("original.pdf")
    }

    private static func temporaryPath(_ targetPath: String, _ id: UUID) -> String {
        (targetPath as NSString).deletingLastPathComponent
            + "/.\((targetPath as NSString).lastPathComponent).reocr-\(id.uuidString).tmp"
    }

    // MARK: Accept

    /// Publishes `candidate` at the target. On return the journal says `published` and the target holds the candidate
    /// with the metadata it had at the moment of publication. A thrown error before the swap leaves the target as it
    /// was and the journal `prepared`; `publishedButUnverified` means the swap happened and the kept original remains.
    @discardableResult
    func accept(_ op: Operation, candidate: Data, faults: Faults = { _ in }) throws -> Journal {
        var journal = try read(op.journal.operationID)
        guard journal.phase == .prepared, journal.original == op.journal.original else {
            throw Failure.journal("the operation is \(journal.phase.rawValue), not prepared")
        }
        let prepared = journal
        let candidateSHA = Self.hex(SHA256.hash(data: candidate))
        let path = journal.targetPath
        let temp = Self.temporaryPath(path, journal.operationID)
        var failure: Error?
        var result: Journal?
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: Self.fresh(op.target), options: .forReplacing, error: &coordError) { _ in
            var swapped = false
            do {
                guard let now = try? Self.snapshot(path), now.sameContent(journal.original) else { throw Failure.targetChanged }
                try Self.writeExclusive(temp, candidate)
                try faults(.afterTemporaryWrite)
                // The CURRENT metadata, read now inside coordination: a tag added since `prepare` is kept. From here on
                // the change time must not move.
                let base = try Self.snapshot(path)
                guard base.sameContent(journal.original) else { throw Failure.targetChanged }
                let meta = try Self.metadata(path)
                try Self.apply(meta, to: temp, from: path)
                try Self.sync(temp)
                let staged = try Self.snapshot(temp)
                guard staged.sha256 == candidateSHA else { throw Failure.candidateWriteFailed("it reads back differently") }
                if let diff = Self.metadataDifference(meta, try Self.metadata(temp)) { throw Failure.metadataNotPreserved(diff) }
                journal.phase = .acceptReady
                journal.candidateSHA256 = candidateSHA
                journal.candidateSize = Int64(candidate.count)
                journal.stagedMetadata = meta
                journal.stagedInode = staged.inode
                try write(journal)
                try faults(.afterAcceptReady)
                // Still the file `prepare` read, with the metadata just staged: no change time moved, no tag changed.
                guard let still = try? Self.snapshot(path), still.sameContent(journal.original), still.changed == base.changed,
                      (try? Self.metadata(path)) == meta else { throw Failure.targetChanged }
                try faults(.beforeSwap)
                guard renamex_np(temp, path, UInt32(RENAME_SWAP)) == 0 else {
                    throw Failure.publishFailed(String(cString: strerror(errno)))
                }
                swapped = true
                try faults(.justAfterSwap)
                // What was displaced is now at `temp`. A writer that slipped in after the last check changed it: put it
                // back and stop. (Its change time moved with the swap, so the bytes, inode and metadata decide.)
                guard Self.isDisplacedOriginal(temp, journal) else {
                    guard renamex_np(temp, path, UInt32(RENAME_SWAP)) == 0 else {
                        throw Failure.publishedButUnverified("another writer changed the file during publication, and "
                            + "it could not be put back: it is at \(temp)")
                    }
                    swapped = false
                    throw Failure.targetChanged
                }
                try Self.syncDirectory((path as NSString).deletingLastPathComponent)
                try faults(.afterSwap)
                let live = try Self.snapshot(path)
                guard live.inode == staged.inode, live.sha256 == candidateSHA else {
                    throw Failure.publishedButUnverified("the published file is not the candidate")
                }
                if let diff = Self.metadataDifference(meta, try Self.metadata(path)) { throw Failure.publishedButUnverified(diff) }
                journal.phase = .published
                do { try write(journal) } catch { throw Failure.publishedRecordPending("\(error)") }
                unlink(temp)   // the displaced original, checked above; the verified kept copy remains in Versions
                result = journal
            } catch {
                failure = error
                // A dead process cleans up nothing; recovery must.
                if !swapped && !(error is InjectedCrash) {
                    unlink(temp)
                    if journal.phase == .acceptReady {
                        do { try write(prepared) } catch {
                            failure = Failure.journal("the failed change could not be recorded as undone: \(error)")
                        }
                    }
                }
            }
        }
        if let coordError { throw Failure.coordination(coordError.localizedDescription) }
        if let failure { throw failure }
        guard let result else { throw Failure.publishFailed("no result") }
        return result
    }

    // MARK: Recover

    enum Recovery: Hashable, Sendable {
        /// Nothing was published: the original is live, or the operation never reached publication. Back to review.
        case notPublished(UUID)
        /// The staged candidate is live with its bytes and metadata; the journal now says `published`.
        case published(UUID)
        /// What is live cannot be explained by this operation, or the kept original is damaged. Nothing was touched.
        case conflict(UUID, String)
        case alreadyPublished(UUID)
    }

    /// Settles every journal under `versionsRoot` by what is on disk. Run at launch, under the flag lock once it
    /// exists, never beside an `accept` in flight.
    func recover() -> [Recovery] {
        let ids = ((try? FileManager.default.contentsOfDirectory(atPath: versionsRoot.path)) ?? []).compactMap(UUID.init(uuidString:))
        return ids.sorted { $0.uuidString < $1.uuidString }.compactMap { id -> Recovery? in
            guard var journal = try? read(id) else { return nil }
            let path = journal.targetPath, temp = Self.temporaryPath(path, id)
            guard let backup = try? Self.snapshot(backupURL(id).path), backup.sha256 == journal.original.sha256 else {
                return .conflict(id, "the kept original is missing or damaged")
            }
            switch journal.phase {
            case .published:
                // The displaced original, if a crash came between the record and its removal. Anything else there is
                // someone's file: left alone and reported.
                if FileManager.default.fileExists(atPath: temp) {
                    guard Self.isDisplacedOriginal(temp, journal) else { return .conflict(id, "another version was left at \(temp)") }
                    unlink(temp)
                }
                return .alreadyPublished(id)
            case .prepared:
                unlink(temp)   // an unpublished candidate copy, if a crash left one
                return .notPublished(id)
            case .acceptReady:
                let live = try? Self.snapshot(path)
                if let live, live.inode == journal.original.inode, live.sha256 == journal.original.sha256 {
                    unlink(temp)
                    journal = Self.reverted(journal)
                    do { try write(journal) } catch { return .conflict(id, "the record could not be updated: \(error)") }
                    return .notPublished(id)
                }
                guard let live else { return .conflict(id, "the file is gone") }
                guard live.inode == journal.stagedInode, live.sha256 == journal.candidateSHA256 else {
                    return .conflict(id, "the file holds neither the original nor this candidate")
                }
                guard let staged = journal.stagedMetadata, let now = try? Self.metadata(path) else {
                    return .conflict(id, "the published file's metadata cannot be read")
                }
                if let diff = Self.metadataDifference(staged, now) {
                    return .conflict(id, "the candidate is in place but its \(diff)")
                }
                // The displaced file, if the crash came before its removal: removed only when it is exactly the
                // original. An in-place write keeps the inode, so the bytes and metadata decide too.
                if FileManager.default.fileExists(atPath: temp) {
                    guard Self.isDisplacedOriginal(temp, journal) else {
                        return .conflict(id, "the file displaced at publication is not the original; it is at \(temp)")
                    }
                    unlink(temp)
                }
                journal.phase = .published
                do { try write(journal) } catch { return .conflict(id, "the record could not be updated: \(error)") }
                return .published(id)
            }
        }
    }

    /// Whether the file at `path` is the original the swap displaced: its inode, bytes and the staged metadata.
    private static func isDisplacedOriginal(_ path: String, _ j: Journal) -> Bool {
        guard let staged = j.stagedMetadata, let old = try? snapshot(path), old.inode == j.original.inode,
              old.sha256 == j.original.sha256, let meta = try? metadata(path) else { return false }
        return metadataDifference(staged, meta) == nil
    }

    private static func reverted(_ j: Journal) -> Journal {
        var j = j
        j.phase = .prepared
        j.candidateSHA256 = nil; j.candidateSize = nil; j.stagedMetadata = nil; j.stagedInode = nil
        return j
    }

    // MARK: Journal

    private func journalURL(_ id: UUID) -> URL {
        versionsRoot.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent("journal.json")
    }

    func read(_ id: UUID) throws -> Journal {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(Journal.self, from: Data(contentsOf: journalURL(id))) }
        catch { throw Failure.journal("\(error)") }
    }

    /// A new journal file each time, synced, then renamed over the old one and the folder synced: a crash leaves the
    /// old phase or the new, never a torn file.
    private func write(_ journal: Journal) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let url = journalURL(journal.operationID)
        let temp = url.path + ".\(UUID().uuidString).tmp"
        do {
            try Self.writeExclusive(temp, encoder.encode(journal))
            guard rename(temp, url.path) == 0 else { throw Failure.journal(String(cString: strerror(errno))) }
            try Self.syncDirectory(url.deletingLastPathComponent().path)
        } catch {
            unlink(temp)
            if case Failure.journal = error { throw error }
            throw Failure.journal("\(error)")
        }
    }

    // MARK: Files

    /// The same file as a new `URL` with no resource-value cache behind it, built from the file-system representation
    /// (as ArchiveCore's `URL.uncached`, which is internal to it): a reused `URL` can report a replaced file's values.
    static func fresh(_ url: URL) -> URL {
        url.withUnsafeFileSystemRepresentation { raw in
            raw.map { URL(fileURLWithFileSystemRepresentation: $0, isDirectory: false, relativeTo: nil) } ?? url
        }
    }

    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    /// Identity, change time and digest of a regular, unlocked file, opened without following a link.
    static func snapshot(_ path: String) throws -> Snapshot {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw errno == ELOOP ? Failure.notARegularFile(path) : Failure.unreadable(String(cString: strerror(errno)))
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw Failure.unreadable(String(cString: strerror(errno))) }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw Failure.notARegularFile(path) }
        if st.st_flags & UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND) != 0 { throw Failure.locked }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw Failure.unreadable(String(cString: strerror(errno)))
            }
            if n == 0 { break }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<n])) }
        }
        return Snapshot(device: st.st_dev, inode: st.st_ino, changed: Stamp(st.st_ctimespec), size: Int64(st.st_size),
                        sha256: hex(hasher.finalize()))
    }

    private static func writeExclusive(_ path: String, _ data: Data) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.candidateWriteFailed(String(cString: strerror(errno))) }
        defer { close(fd) }
        try data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw Failure.candidateWriteFailed(String(cString: strerror(errno)))
                }
                off += n
            }
        }
        guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else {
            throw Failure.candidateWriteFailed(String(cString: strerror(errno)))
        }
    }

    private static func sync(_ path: String) throws {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.candidateWriteFailed(String(cString: strerror(errno))) }
        defer { close(fd) }
        guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else {
            throw Failure.candidateWriteFailed(String(cString: strerror(errno)))
        }
    }

    private static func syncDirectory(_ path: String) throws {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.journal(String(cString: strerror(errno))) }
        defer { close(fd) }
        guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else { throw Failure.journal(String(cString: strerror(errno))) }
    }

    private static func makePrivateDirectory(_ url: URL) throws {
        if mkdir(url.path, 0o700) == 0 {
            try syncDirectory(url.deletingLastPathComponent().path)
        } else if errno != EEXIST {
            throw Failure.backupFailed(String(cString: strerror(errno)))
        }
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else {
            throw Failure.backupFailed("\(url.path) is not a private folder")
        }
    }

    private static func availableBytes(_ url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        return (try? Self.fresh(probe).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    // MARK: Metadata

    /// What publication must carry over: every extended attribute (Finder tags and label live in
    /// `com.apple.metadata:_kMDItemUserTags` and `com.apple.FinderInfo`, the resource fork in
    /// `com.apple.ResourceFork`), the permission bits, owner, the flags a user can set, the ACL, and the creation,
    /// modification and date-added times.
    struct Metadata: Codable, Equatable, Sendable {
        var xattrs: [String: Data]
        var mode: UInt16
        var uid: UInt32
        var gid: UInt32
        var flags: UInt32
        var created: Stamp
        var modified: Stamp
        var added: Stamp?
        var acl: String?
    }

    /// Attributes the system keeps for itself, compared by neither side: `com.apple.provenance` is added by the kernel
    /// to files an app writes and cannot be removed by it; `com.apple.macl` is the sandbox's per-file access list;
    /// `com.apple.lastuseddate#PS` changes whenever the file is opened. They are still copied where the system allows.
    static let systemAttributes: Set<String> = ["com.apple.provenance", "com.apple.macl", "com.apple.lastuseddate#PS"]

    /// The flags `apply` carries: those a user may set, less the ones the file system manages itself.
    static let carriedFlags = UInt32(UF_SETTABLE) & ~UInt32(UF_COMPRESSED | UF_TRACKED | UF_DATAVAULT)

    static func metadata(_ path: String) throws -> Metadata {
        var st = stat()
        guard lstat(path, &st) == 0 else { throw Failure.unreadable(String(cString: strerror(errno))) }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw Failure.notARegularFile(path) }
        return Metadata(xattrs: xattrs(path).filter { !systemAttributes.contains($0.key) }, mode: UInt16(st.st_mode & 0o7777),
                        uid: st.st_uid, gid: st.st_gid, flags: st.st_flags & carriedFlags,
                        created: Stamp(st.st_birthtimespec), modified: Stamp(st.st_mtimespec), added: addedTime(path),
                        acl: acl(path))
    }

    static func metadataDifference(_ want: Metadata, _ got: Metadata, dates: Bool = true) -> String? {
        if want.xattrs != got.xattrs {
            let names = Set(want.xattrs.keys).union(got.xattrs.keys).filter { want.xattrs[$0] != got.xattrs[$0] }
            return "extended attributes differ (\(names.sorted().joined(separator: ", ")))"
        }
        if want.mode != got.mode { return "permissions differ" }
        if want.uid != got.uid || want.gid != got.gid { return "owner differs" }
        if want.flags != got.flags { return "file flags differ" }
        if want.acl != got.acl { return "access control list differs" }
        guard dates else { return nil }
        if want.created != got.created { return "creation date differs" }
        if want.modified != got.modified { return "modification date differs" }
        if want.added != nil, want.added != got.added { return "date added differs" }
        return nil
    }

    /// Puts `meta` on `to` (whose contents stay): `from`'s extended attributes and ACL by `copyfile`, then mode and
    /// flags, then the modification date and last the creation and date-added times. Setting a modification date
    /// earlier than the creation date pulls the creation date back with it (setattrlist(2)), so creation comes after.
    private static func apply(_ meta: Metadata, to: String, from: String) throws {
        for name in xattrNames(to) where meta.xattrs[name] == nil && !systemAttributes.contains(name) {
            removexattr(to, name, XATTR_NOFOLLOW)
        }
        guard copyfile(from, to, nil, copyfile_flags_t(COPYFILE_ACL | COPYFILE_XATTR | COPYFILE_NOFOLLOW)) == 0 else {
            throw Failure.metadataNotPreserved(String(cString: strerror(errno)))
        }
        if chmod(to, mode_t(meta.mode)) != 0 { throw Failure.metadataNotPreserved("permissions: \(String(cString: strerror(errno)))") }
        var st = stat()
        guard lstat(to, &st) == 0 else { throw Failure.metadataNotPreserved(String(cString: strerror(errno))) }
        if st.st_uid != meta.uid || st.st_gid != meta.gid { throw Failure.notOwned }
        if chflags(to, (st.st_flags & ~carriedFlags) | meta.flags) != 0 {
            throw Failure.metadataNotPreserved("flags: \(String(cString: strerror(errno)))")
        }
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), meta.modified.value]
        guard utimensat(AT_FDCWD, to, &times, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw Failure.metadataNotPreserved("modification date: \(String(cString: strerror(errno)))")
        }
        try setTime(to, attrgroup_t(ATTR_CMN_CRTIME), meta.created, "creation date")
        if let added = meta.added { try setTime(to, attrgroup_t(ATTR_CMN_ADDEDTIME), added, "date added") }
    }

    private static func setTime(_ path: String, _ attr: attrgroup_t, _ stamp: Stamp, _ what: String) throws {
        var value = stamp.value
        var list = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: attr,
                            volattr: 0, dirattr: 0, fileattr: 0, forkattr: 0)
        guard setattrlist(path, &list, &value, MemoryLayout<timespec>.size, UInt32(FSOPT_NOFOLLOW)) == 0 else {
            throw Failure.metadataNotPreserved("\(what): \(String(cString: strerror(errno)))")
        }
    }

    /// The date-added time, which the volume keeps once a file has been put in a folder; nil where it has none.
    private static func addedTime(_ path: String) -> Stamp? {
        var list = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0,
                            commonattr: attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_ADDEDTIME),
                            volattr: 0, dirattr: 0, fileattr: 0, forkattr: 0)
        // u_int32_t length, attribute_set_t returned, timespec.
        var buffer = [UInt8](repeating: 0, count: 4 + MemoryLayout<attribute_set_t>.size + MemoryLayout<timespec>.size)
        let ok = buffer.withUnsafeMutableBytes { getattrlist(path, &list, $0.baseAddress, $0.count, UInt32(FSOPT_NOFOLLOW)) }
        guard ok == 0 else { return nil }
        return buffer.withUnsafeBytes { raw -> Stamp? in
            let returned = raw.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self)
            guard returned.commonattr & attrgroup_t(ATTR_CMN_ADDEDTIME) != 0 else { return nil }
            return Stamp(raw.loadUnaligned(fromByteOffset: 4 + MemoryLayout<attribute_set_t>.size, as: timespec.self))
        }
    }

    static func xattrNames(_ path: String) -> [String] {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var buf = [CChar](repeating: 0, count: size)
        let got = listxattr(path, &buf, size, XATTR_NOFOLLOW)
        guard got > 0 else { return [] }
        return buf[..<got].split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
    }

    static func xattrs(_ path: String) -> [String: Data] {
        var out: [String: Data] = [:]
        for name in xattrNames(path) {
            let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard size >= 0 else { continue }
            var data = Data(count: size)
            let got = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
            if got >= 0 { out[name] = data.prefix(got) }
        }
        return out
    }

    private static func acl(_ path: String) -> String? {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard let text = acl_to_text(acl, nil) else { return nil }
        defer { acl_free(text) }
        return String(cString: text)
    }
}
