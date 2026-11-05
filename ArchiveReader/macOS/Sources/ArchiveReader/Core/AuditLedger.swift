import Foundation
import ArchiveCore
import os

// ============================================================================================
//  AuditLedger — Safety Protocol §12: an append-only record of every tag change the Reader makes.
//
//  One JSON line per VERIFIED, non-no-op `TagWriter` result, appended after the write returns.
//  Written to the Reader's own container (Application Support), never inside the archive: the
//  ledger's location is derived from the app's support directory and nothing else, so no scanned
//  URL can steer it. A failed write throws before it gets here, so the ledger holds only changes
//  that are on disk. A ledger that cannot be appended to never fails the tag write that already
//  happened; the error is logged and kept in `lastError`.
//
//  Each line carries what the durable undo source needs (§9: undo is the inverse DELTA applied to a
//  fresh read, never a stored full array): the path, a bookmark, the file's device/inode at write
//  time, before/after tags and labels, the forward occurrence delta, its inverse, and a `group` so a
//  bulk action stays one undo step. An undo is itself a change and gets its own line, naming the
//  group it undoes in `undoes`.
//
//  Durability (W40.fix-reader-ledger-durability). A forward action is write-ahead journalled: before
//  its first tag write, a synchronized `actionIntent` line names the group; once every record of the
//  action has been appended, a synchronized `actionDone` closes it. The records between them are not
//  synchronized one by one: the closing `fsync` makes them durable together. An intent with no
//  `actionDone` after it (the process or the machine died mid-action, or a record could not be
//  appended) is a history barrier: neither that action nor anything older is offered as undo, since a
//  change may be on disk with no record. The live file is closed off as a numbered segment beside it
//  once it passes `segmentByteLimit`; segments are kept (the record stays append-only) and undo reads
//  them newest first only as far as its 100-group window needs.
// ============================================================================================

final class AuditLedger: @unchecked Sendable {

    static let shared = AuditLedger(fileURL: AuditLedger.defaultFileURL())

    /// The batch an entry belongs to, and the batch an undo reverses. Bound by the caller around a
    /// group of writes (`withContext`); an unbound write is its own single-entry group.
    struct Context: Sendable {
        var group: UUID
        var undoes: UUID?
        var journal: ActionJournal? = nil
    }
    @TaskLocal static var context: Context?

    /// Run `body` with every ledger entry it produces tagged with `group` (and `undoes`). A forward
    /// action is journalled (`writeAhead`); an undo is not, because `beginUndo` consumed its group
    /// durably first and an undo write is never itself an undo source.
    static func withContext<T>(group: UUID, undoes: UUID? = nil, _ body: () throws -> T) rethrows -> T {
        // Nested inside the same action: keep its journal, so one `actionDone` cannot close the other's intent.
        if let outer = context, outer.group == group, outer.undoes == undoes { return try body() }
        let journal = undoes == nil ? ActionJournal(group: group) : nil
        defer { journal?.close() }
        return try $context.withValue(Context(group: group, undoes: undoes, journal: journal), operation: body)
    }

    /// The write-ahead state of one forward action: whether its intent is durable, and whether any of
    /// its records failed (then the action is never closed, and its intent stays a barrier).
    final class ActionJournal: @unchecked Sendable {
        let group: UUID
        private let openLock = NSLock()
        private let stateLock = NSLock()
        private var ledger: AuditLedger?
        private var incomplete = false

        init(group: UUID) { self.group = group }

        /// Held across the append, so a second write of the same action cannot start before the intent
        /// is synchronized.
        func open(on ledger: AuditLedger) {
            openLock.withLock {
                guard stateLock.withLock({ self.ledger == nil && !incomplete }) else { return }
                if ledger.append(AuditLedger.marker(.actionIntent, group: group), synchronize: true,
                                 recordsChange: true) {
                    stateLock.withLock { self.ledger = ledger }
                } else {
                    markIncomplete()
                }
            }
        }

        func markIncomplete() { stateLock.withLock { incomplete = true } }

        /// A failed close leaves the intent open, which is the safe direction: it reads as a barrier.
        /// A write after close (a task that outlived the action) writes a new intent that is never
        /// closed: a barrier, never a record outside any journalled action.
        func close() {
            let ledger: AuditLedger? = stateLock.withLock {
                defer { self.ledger = nil }
                return incomplete ? nil : self.ledger
            }
            ledger?.append(AuditLedger.marker(.actionDone, group: group), synchronize: true)
        }
    }

    enum Operation: String, Codable, Sendable {
        case apply, readState, rename, undo, undoAttempt, historyBarrier, actionIntent, actionDone
    }

    struct Delta: Codable, Equatable, Sendable {
        var add: [String]
        var remove: [String]
        /// The Finder label number to set, when the change sets one; nil = label untouched.
        var label: Int?
    }

    struct FileNumber: Codable, Hashable, Sendable {
        var device: Int64
        var inode: UInt64
    }

    struct Entry: Codable, Equatable, Sendable {
        var v: Int
        var timestamp: Date
        var op: Operation
        var group: UUID
        var undoes: UUID?
        var path: String
        var bookmark: Data?
        var file: FileNumber?
        var before: [String]
        var after: [String]
        var beforeLabel: Int?
        var afterLabel: Int?
        var delta: Delta
        var inverse: Delta
        /// Set when the write failed its post-write verification: the tags may or may not have changed,
        /// `before`/`after`/`delta`/`inverse` are empty, and the entry is never an undo source.
        var unverified: String?
        /// Set on a forward entry re-recorded by `keepForRetry`: the group whose undo failed for this
        /// file, and which attempt the next undo of it will be (the original undo was attempt 1).
        var retryOf: UUID?
        var attempt: Int?
    }

    private let lock = NSLock()
    private var _fileURL: URL
    private var _lastError: String?
    private var _hasRecordingGap = false
    private var _recordingFailureCount: UInt64 = 0
    private var _segmentByteLimit: UInt64 = 4 << 20
    private static let log = Logger(subsystem: "com.archivereader.app", category: "AuditLedger")

    init(fileURL: URL) { _fileURL = fileURL }

    var fileURL: URL {
        get { lock.withLock { _fileURL } }
        set { lock.withLock { _fileURL = newValue; _hasRecordingGap = false } }
    }

    /// The last append failure, nil once an append succeeds.
    var lastError: String? { lock.withLock { _lastError } }

    /// A successful change missing from the ledger makes older inverses unsafe to offer as “last”.
    var hasRecordingGap: Bool { lock.withLock { _hasRecordingGap } }
    var recordingFailureCount: UInt64 { lock.withLock { _recordingFailureCount } }

    /// Size past which the live file becomes a numbered segment before the next append. About 4,000
    /// changes; it bounds what one undo refresh decodes, not what the disk keeps.
    var segmentByteLimit: UInt64 {
        get { lock.withLock { _segmentByteLimit } }
        set { lock.withLock { _segmentByteLimit = newValue } }
    }

    /// `~/Library/Containers/com.archivereader.app/Data/Library/Application Support/ArchiveReader/
    /// audit-ledger.jsonl` in the sandboxed app. The unit-test host, and a UITest launch (which passes
    /// `-ARUITestRootPath` on the command line), get a per-launch scratch file, so tests never add lines
    /// to the owner's ledger: both run as `com.archivereader.app` and share its container.
    /// The process ID alone is not unique: the container's tmp outlives the process, and a VM booted the
    /// same way each time hands the app the same PID again, so a fresh launch inherited an older run's
    /// undoable history (W40.fix-reader-vm-nav-red). Fixed for the life of the process. A UITest that
    /// relaunches the app and needs its history back passes its own `-ARUITestLedgerID` (DEBUG only), as
    /// `UndoFocusUITests` does to press ⌘Z straight after a relaunch (W40.fix-reader-undo-focus).
    static let testLaunchID: String = {
#if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-ARUITestRootPath"), let i = args.firstIndex(of: "-ARUITestLedgerID"), i + 1 < args.count {
            let id = args[i + 1].filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            if !id.isEmpty { return "shared-\(id)" }
        }
#endif
        return "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)"
    }()

    static func defaultFileURL() -> URL {
        if ArchiveTestHost.isUnitTestHost || ProcessInfo.processInfo.arguments.contains("-ARUITestRootPath") {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("ArchiveReaderTestLedger-\(testLaunchID)", isDirectory: true)
                .appendingPathComponent("audit-ledger.jsonl")
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("ArchiveReader", isDirectory: true)
            .appendingPathComponent("audit-ledger.jsonl")
    }

    // MARK: Recording

    /// Called by `TagWriter` before each write of a forward action: the first one of the action
    /// synchronizes the action's intent. A failure to write it warns and disables older undo like a
    /// failed record, and the write still goes ahead.
    func writeAhead() {
        Self.context?.journal?.open(on: self)
    }

    static func marker(_ op: Operation, group: UUID) -> Entry {
        let none = Delta(add: [], remove: [], label: nil)
        return Entry(v: 1, timestamp: Date(), op: op, group: group, undoes: nil, path: "", bookmark: nil,
                     file: nil, before: [], after: [], beforeLabel: nil, afterLabel: nil, delta: none,
                     inverse: none, unverified: nil)
    }

    /// Append one line for a verified write. A no-op result records nothing.
    func record(_ op: Operation, _ r: TagWriteResult, file: FileNumber?) {
        guard !r.isNoOp else { return }
        let ctx = Self.context ?? Context(group: UUID(), undoes: nil)
        let entry = Entry(
            v: 1, timestamp: Date(), op: op, group: ctx.group, undoes: ctx.undoes,
            path: r.url.path,
            bookmark: try? r.url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
            file: file,
            before: r.before, after: r.after, beforeLabel: r.beforeLabel, afterLabel: r.afterLabel,
            delta: Self.forwardDelta(r),
            inverse: Delta(add: r.occurrenceInverse.add, remove: r.occurrenceInverse.remove,
                           label: Self.label(of: r.occurrenceInverse.color)),
            unverified: nil)
        append(entry, recordsChange: true)
    }

    /// Append one line for a write that failed its post-write re-read (`.verificationFailed`).
    /// The change may or may not be on disk, so the action is never closed: its intent stays a barrier
    /// and no older inverse is offered across it.
    func recordUnverified(_ op: Operation, _ url: URL, _ why: String) {
        Self.context?.journal?.markIncomplete()
        let ctx = Self.context ?? Context(group: UUID(), undoes: nil)
        let none = Delta(add: [], remove: [], label: nil)
        append(Entry(
            v: 1, timestamp: Date(), op: op, group: ctx.group, undoes: ctx.undoes, path: url.path,
            bookmark: try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
            file: Self.fileNumber(url), before: [], after: [], beforeLabel: nil, afterLabel: nil,
            delta: none, inverse: none, unverified: why), recordsChange: true)
    }

    @discardableResult
    func append(_ entry: Entry, synchronize: Bool = false, recordsChange: Bool = false) -> Bool {
        do {
            var line = try Self.encoder.encode(entry)
            line.append(0x0A)
            try lock.withLock {
                let url = _fileURL
                let fm = FileManager.default
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                closeSegmentIfFull(url)
                if !fm.fileExists(atPath: url.path) {
                    // A new, empty ledger file in the app's own support directory — never a corpus path.
                    _ = fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                // Once storage recovers, persist a boundary before accepting newer actions. Never
                // expose an older inverse across a successful but unrecorded (or uncertain) change.
                let hadGap = _hasRecordingGap
                if hadGap {
                    var prefix = try Self.encoder.encode(Self.marker(.historyBarrier, group: UUID()))
                    prefix.append(0x0A)
                    line.insert(contentsOf: prefix, at: 0)
                }
                // Append-only: seek to the end and add one line; nothing already written is touched. A
                // crash mid-append can leave a last line with no newline; start a fresh line after it, so
                // the torn fragment costs only itself and not the entry written next.
                if Self.endsMidLine(url) { line.insert(0x0A, at: 0) }
                let handle = try Self.appendHandle(url)
                defer { try? handle.close() }
                try handle.write(contentsOf: line)
                if synchronize || hadGap { try Self.flushToStorage(handle) }
                _hasRecordingGap = false
                _lastError = nil
            }
            return true
        } catch {
            lock.withLock {
                _lastError = String(describing: error)
                if recordsChange {
                    _hasRecordingGap = true
                    _recordingFailureCount &+= 1
                }
            }
            if recordsChange { Self.context?.journal?.markIncomplete() }
            Self.log.error("audit ledger append failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    // MARK: Reading

    /// Every entry in file order, segments included, without the write-ahead journal's markers. A line
    /// that does not decode (a torn last line after a crash) is skipped, never fatal: the rest of the
    /// history stays readable.
    func entries() -> [Entry] {
        allEntries().filter { $0.op != .actionIntent && $0.op != .actionDone }
    }

    /// `entries()` with the journal's `actionIntent` / `actionDone` markers.
    func allEntries() -> [Entry] {
        historyFilesNewestFirst().reversed().flatMap { Self.decodeEntries($0) ?? [] }
    }

    /// The live file first, then its segments from the newest.
    private func historyFilesNewestFirst() -> [URL] {
        let url = fileURL
        return [url] + Self.segments(of: url).reversed().map(\.url)
    }

    /// nil when a file that exists cannot be read: skipping it would expose older history across it.
    private static func decodeEntries(_ url: URL) -> [Entry]? {
        guard let data = try? Data(contentsOf: url) else {
            return FileManager.default.fileExists(atPath: url.path) ? nil : []
        }
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(Entry.self, from: Data($0)) }
    }

    /// Latest 100 forward actions in this archive, including consumed actions in the bound. Counting
    /// only pending actions would resurrect older history each time the most recent action was undone.
    /// Undo writes are never redo candidates. The ledger itself remains append-only and is not pruned:
    /// a full file is closed off as a segment and kept, and undo stops reading once the window is full.
    static let undoGroupLimit = 100

    func undoGroups(in root: URL) -> [[Entry]] {
        guard !hasRecordingGap else { return [] }
        var consumed = Set<UUID>()
        var closed = Set<UUID>()
        var order: [UUID] = []
        var groups: [UUID: [Entry]] = [:]
        let files = historyFilesNewestFirst()
        history: for file in files {
          guard let lines = Self.decodeEntries(file) else { return [] }
          for entry in lines.reversed() where entry.v == 1 && entry.unverified == nil {
            if entry.op == .historyBarrier { break history }
            if entry.op == .actionDone { closed.insert(entry.group); continue }
            if entry.op == .actionIntent {
                if closed.contains(entry.group) { continue }
                // Unclosed: some change of this action may be on disk unrecorded. Offer neither this
                // action (it may be incomplete) nor anything older.
                groups[entry.group] = nil
                order.removeAll { $0 == entry.group }
                break history
            }
            if let undone = entry.undoes { consumed.insert(undone); continue }
            guard entry.op != .undo && entry.op != .undoAttempt,
                  (ReaderArchiveLayout.isContained(URL(fileURLWithPath: entry.path), inRootPath: root.path)
                    || Self.bookmarkURL(entry).map { ReaderArchiveLayout.isContained($0, inRootPath: root.path) } == true)
            else { continue }
            if groups[entry.group] == nil {
                guard order.count < Self.undoGroupLimit else { break history }
                order.append(entry.group)
                groups[entry.group] = []
            }
            // Already reversed: undo multiple writes to the same file in reverse write order.
            groups[entry.group, default: []].append(entry)
          }
        }
        // Another running copy cut a segment while this one read: the files read may have skipped its
        // newest lines. Offer nothing; the next refresh reads the settled files.
        guard historyFilesNewestFirst() == files else { return [] }
        return order.reversed().filter { !consumed.contains($0) }.compactMap { groups[$0] }
    }

    /// Consume BEFORE applying an occurrence inverse: replay can append duplicate occurrences. If the
    /// append/sync fails, the caller must refuse to write. A crash consumes the entire action; a member
    /// that failed is offered again only through `keepForRetry`, after its failure is known.
    func beginUndo(_ group: UUID) -> Bool {
        var attempt = Self.marker(.undoAttempt, group: UUID())
        attempt.undoes = group
        return append(attempt, synchronize: true)
    }

    /// How many times one file's undo is attempted before it is dropped. Each retry sits on top of the
    /// history, so a cause that never passes would otherwise block every older undo behind it.
    static let undoAttemptLimit = 3

    /// Whether an undo member that failed with `error` may be offered again. Never an identity refusal:
    /// the file at the path is not the one recorded (or has gone, or is outside the archive), and a retry
    /// could tag a replacement (§6). Any other failure may pass (a lock, a coordination timeout, a
    /// concurrent edit seen at verification), and a retry is safe even if the failed write partly
    /// landed: `TagWriter.applyOccurrence(undoing:)` never moves a token past its count before the
    /// change and restores the label only while it still reads as the change left it, so a second
    /// application of the same inverse writes nothing it has already written (W45.undo-still-applied).
    static func undoMayBeRetried(after error: Error, attempt: Int) -> Bool {
        if case TagWriteError.identityMismatch = error { return false }
        return attempt < undoAttemptLimit
    }

    /// Per-member durable accounting for a partly failed undo: re-record each retryable failed member as
    /// a forward entry in ONE new group, so the next undo offers exactly those files and nothing that was
    /// already reversed. Called only AFTER `beginUndo` consumed `group` and the members were tried, so a
    /// crash in between loses the retry (the safe direction) and can never replay a reversed member.
    /// Returns false when the ledger could not record it; the caller reports the files as lost.
    func keepForRetry(_ failed: [Entry], of group: UUID) -> Bool {
        guard !failed.isEmpty else { return true }
        let retryGroup = UUID()
        var lines = Data()
        do {
            for var entry in failed {
                entry.timestamp = Date()
                entry.group = retryGroup
                entry.undoes = nil
                entry.retryOf = group
                entry.attempt = (entry.attempt ?? 1) + 1
                lines.append(try Self.encoder.encode(entry))
                lines.append(0x0A)
            }
        } catch {
            Self.log.error("audit ledger retry encode failed: \(String(describing: error), privacy: .public)")
            return false
        }
        // One write for the whole group, so a torn append can drop members but never split the group's
        // decodable lines between two undo steps (a torn last line does not decode and is skipped).
        return appendLines(lines)
    }

    /// Append pre-encoded lines in one synchronized write. Like `append`, it never edits an existing line.
    private func appendLines(_ lines: Data) -> Bool {
        do {
            try lock.withLock {
                let url = _fileURL
                let fm = FileManager.default
                guard !_hasRecordingGap, fm.fileExists(atPath: url.path) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                closeSegmentIfFull(url)
                if !fm.fileExists(atPath: url.path) {
                    _ = fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                var data = lines
                if Self.endsMidLine(url) { data.insert(0x0A, at: 0) }
                let handle = try Self.appendHandle(url)
                defer { try? handle.close() }
                try handle.write(contentsOf: data)
                try Self.flushToStorage(handle)
                _lastError = nil
            }
            return true
        } catch {
            lock.withLock { _lastError = String(describing: error) }
            Self.log.error("audit ledger append failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// A bookmark is a locator, never authority to tag a different object. An existing recorded path
    /// must still identify the recorded file. If it moved, a resolvable bookmark may locate it inside
    /// the current archive; if bookmark resolution is unavailable, path + device/inode is the fallback.
    static func undoTarget(_ entry: Entry) throws -> (url: URL, identity: FileIdentity) {
        guard let expected = entry.file else {
            throw TagWriteError.identityMismatch("ledger has no recorded file identity")
        }
        let path = URL(fileURLWithPath: entry.path)
        let bookmarked = bookmarkURL(entry)
        let atPath = fileNumber(path)
        if let atPath, atPath != expected {
            throw TagWriteError.identityMismatch("file at the recorded path has been replaced")
        }
        if let bookmarked, fileNumber(bookmarked) != expected {
            throw TagWriteError.identityMismatch("bookmark disagrees with the recorded identity")
        }
        let target = atPath == expected ? path : (bookmarked ?? path)
        // Capture BETWEEN two persisted-identity reads. A swap before capture fails the second stat;
        // a swap after capture fails the shared writer's in-coordination FileIdentity check (§6).
        guard fileNumber(target) == expected, let identity = FileIdentity.capture(target),
              fileNumber(target) == expected else {
            throw TagWriteError.identityMismatch("recorded file is missing or its identity changed")
        }
        return (target, identity)
    }

    private static func bookmarkURL(_ entry: Entry) -> URL? {
        var stale = false
        return entry.bookmark.flatMap {
            try? URL(resolvingBookmarkData: $0, options: [.withoutUI, .withoutMounting],
                     relativeTo: nil, bookmarkDataIsStale: &stale)
        }
    }

    // MARK: Helpers

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Caller holds `lock`. Renames the full live file to the next numbered segment beside it
    /// (`audit-ledger.000001.jsonl`, …), so the next append starts a fresh live file. Nothing is
    /// rewritten or deleted. A group may span the cut; undo reads across it.
    /// A cut that fails (another running copy took the name first) is only logged: appending to the
    /// live file goes on, and the next append tries again.
    private func closeSegmentIfFull(_ url: URL) {
        var st = stat()
        guard stat(url.path, &st) == 0, UInt64(st.st_size) >= _segmentByteLimit else { return }
        let next = (Self.segments(of: url).last?.number ?? 0) + 1
        let segment = Self.segmentURL(of: url, number: next)
        do {
            try FileManager.default.moveItem(at: url, to: segment)
        } catch {
            Self.log.error("audit ledger segment cut failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// `O_APPEND`: every write lands at the end of the file as it is at that moment, so two running
    /// copies sharing the container's ledger never write over each other's lines.
    private static func appendHandle(_ url: URL) throws -> FileHandle {
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    static func segmentURL(of url: URL, number: Int) -> URL {
        let stem = url.deletingPathExtension().lastPathComponent
        let name = "\(stem).\(String(format: "%06d", number)).\(url.pathExtension)"
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// The live file's closed segments, oldest first.
    static func segments(of url: URL) -> [(number: Int, url: URL)] {
        let stem = url.deletingPathExtension().lastPathComponent + "."
        let ext = "." + url.pathExtension
        let dir = url.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { name -> (number: Int, url: URL)? in
            guard name.hasPrefix(stem), name.hasSuffix(ext), name.count > stem.count + ext.count else { return nil }
            let middle = name.dropFirst(stem.count).dropLast(ext.count)
            guard middle.allSatisfy(\.isASCII), middle.allSatisfy(\.isNumber), let n = Int(middle) else { return nil }
            return (n, dir.appendingPathComponent(name))
        }.sorted { $0.number < $1.number }
    }

    /// `F_FULLFSYNC`, so a synchronized line survives power loss and not only process death: plain
    /// `fsync(2)` on macOS leaves it in the drive's cache. Falls back to `fsync` where the file system
    /// does not support it.
    private static func flushToStorage(_ handle: FileHandle) throws {
        guard fcntl(handle.fileDescriptor, F_FULLFSYNC) == -1 else { return }
        let code = errno
        guard code == ENOTSUP || code == EINVAL else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        try handle.synchronize()
    }

    private static func endsMidLine(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let end = try? h.seekToEnd(), end > 0 else { return false }
        try? h.seek(toOffset: end - 1)
        return (try? h.read(upToCount: 1)) != Data([0x0A])
    }

    /// `stat(2)`, not `URLResourceValues`: a reused `URL` answers from its resource-value cache.
    static func fileNumber(_ url: URL) -> FileNumber? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return FileNumber(device: Int64(st.st_dev), inode: UInt64(st.st_ino))
    }

    /// after − before, as multisets: what the write added and removed, each occurrence counted.
    static func forwardDelta(_ r: TagWriteResult) -> Delta {
        var remaining: [String: Int] = [:]
        for t in r.before { remaining[t, default: 0] += 1 }
        var add: [String] = []
        for t in r.after {
            if let n = remaining[t], n > 0 { remaining[t] = n - 1 } else { add.append(t) }
        }
        var removeBudget = remaining
        var remove: [String] = []
        for t in r.before {
            if let n = removeBudget[t], n > 0 { remove.append(t); removeBudget[t] = n - 1 }
        }
        let labelChanged = normalizedLabel(r.beforeLabel) != normalizedLabel(r.afterLabel)
        return Delta(add: add, remove: remove, label: labelChanged ? (r.afterLabel ?? 0) : nil)
    }

    private static func label(of color: TagDelta.ColorChange?) -> Int? {
        switch color {
        case .restoreLabel(let lbl): return lbl ?? 0
        case .set(let c): return c.labelNumber
        case .clear: return 0
        case nil: return nil
        }
    }
}
