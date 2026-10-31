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
// ============================================================================================

final class AuditLedger: @unchecked Sendable {

    static let shared = AuditLedger(fileURL: AuditLedger.defaultFileURL())

    /// The batch an entry belongs to, and the batch an undo reverses. Bound by the caller around a
    /// group of writes (`withContext`); an unbound write is its own single-entry group.
    struct Context: Sendable {
        var group: UUID
        var undoes: UUID?
    }
    @TaskLocal static var context: Context?

    /// Run `body` with every ledger entry it produces tagged with `group` (and `undoes`).
    static func withContext<T>(group: UUID, undoes: UUID? = nil, _ body: () throws -> T) rethrows -> T {
        try $context.withValue(Context(group: group, undoes: undoes), operation: body)
    }

    enum Operation: String, Codable, Sendable {
        case apply, readState, rename, undo, undoAttempt, historyBarrier
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

    /// `~/Library/Containers/com.archivereader.app/Data/Library/Application Support/ArchiveReader/
    /// audit-ledger.jsonl` in the sandboxed app. The unit-test host, and a UITest launch (which passes
    /// `-ARUITestRootPath` on the command line), get a per-process scratch file, so tests never add lines
    /// to the owner's ledger: both run as `com.archivereader.app` and share its container.
    static func defaultFileURL() -> URL {
        if ArchiveTestHost.isUnitTestHost || ProcessInfo.processInfo.arguments.contains("-ARUITestRootPath") {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("ArchiveReaderTestLedger-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
                .appendingPathComponent("audit-ledger.jsonl")
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("ArchiveReader", isDirectory: true)
            .appendingPathComponent("audit-ledger.jsonl")
    }

    // MARK: Recording

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
    func recordUnverified(_ op: Operation, _ url: URL, _ why: String) {
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
                if !fm.fileExists(atPath: url.path) {
                    // A new, empty ledger file in the app's own support directory — never a corpus path.
                    _ = fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                // Once storage recovers, persist a boundary before accepting newer actions. Never
                // expose an older inverse across a successful but unrecorded (or uncertain) change.
                let hadGap = _hasRecordingGap
                if hadGap {
                    let none = Delta(add: [], remove: [], label: nil)
                    let barrier = Entry(v: 1, timestamp: Date(), op: .historyBarrier, group: UUID(),
                        undoes: nil, path: "", bookmark: nil, file: nil, before: [], after: [],
                        beforeLabel: nil, afterLabel: nil, delta: none, inverse: none, unverified: nil)
                    var prefix = try Self.encoder.encode(barrier)
                    prefix.append(0x0A)
                    line.insert(contentsOf: prefix, at: 0)
                }
                // Append-only: seek to the end and add one line; nothing already written is touched. A
                // crash mid-append can leave a last line with no newline; start a fresh line after it, so
                // the torn fragment costs only itself and not the entry written next.
                if Self.endsMidLine(url) { line.insert(0x0A, at: 0) }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                if synchronize || hadGap { try handle.synchronize() }
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
            Self.log.error("audit ledger append failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    // MARK: Reading

    /// Every entry in file order. A line that does not decode (a torn last line after a crash) is
    /// skipped, never fatal: the rest of the history stays readable.
    func entries() -> [Entry] {
        guard let data = lock.withLock({ try? Data(contentsOf: _fileURL) }) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? Self.decoder.decode(Entry.self, from: Data($0)) }
    }

    /// Latest 100 forward actions in this archive, including consumed actions in the bound. Counting
    /// only pending actions would resurrect older history each time the most recent action was undone.
    /// Undo writes are never redo candidates. The ledger itself remains append-only and is not pruned.
    static let undoGroupLimit = 100

    func undoGroups(in root: URL) -> [[Entry]] {
        guard !hasRecordingGap else { return [] }
        let history = entries()
        var consumed = Set<UUID>()
        var order: [UUID] = []
        var groups: [UUID: [Entry]] = [:]
        for entry in history.reversed() where entry.v == 1 && entry.unverified == nil {
            if entry.op == .historyBarrier { break }
            if let undone = entry.undoes { consumed.insert(undone); continue }
            guard entry.op != .undo && entry.op != .undoAttempt,
                  (ReaderArchiveLayout.isContained(URL(fileURLWithPath: entry.path), inRootPath: root.path)
                    || Self.bookmarkURL(entry).map { ReaderArchiveLayout.isContained($0, inRootPath: root.path) } == true)
            else { continue }
            if groups[entry.group] == nil {
                guard order.count < Self.undoGroupLimit else { break }
                order.append(entry.group)
                groups[entry.group] = []
            }
            // Already reversed: undo multiple writes to the same file in reverse write order.
            groups[entry.group, default: []].append(entry)
        }
        return order.reversed().filter { !consumed.contains($0) }.compactMap { groups[$0] }
    }

    /// Consume BEFORE applying an occurrence inverse: replay can append duplicate occurrences. If the
    /// append/sync fails, the caller must refuse to write. A crash consumes the entire action; a member
    /// that failed is offered again only through `keepForRetry`, after its failure is known.
    func beginUndo(_ group: UUID) -> Bool {
        let none = Delta(add: [], remove: [], label: nil)
        return append(Entry(v: 1, timestamp: Date(), op: .undoAttempt, group: UUID(), undoes: group,
                            path: "", bookmark: nil, file: nil, before: [], after: [],
                            beforeLabel: nil, afterLabel: nil, delta: none, inverse: none,
                            unverified: nil), synchronize: true)
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
                guard !_hasRecordingGap, FileManager.default.fileExists(atPath: url.path) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                var data = lines
                if Self.endsMidLine(url) { data.insert(0x0A, at: 0) }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.synchronize()
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
