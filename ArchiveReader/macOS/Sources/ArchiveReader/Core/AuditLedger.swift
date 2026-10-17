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
        case apply, readState, rename, undo
    }

    struct Delta: Codable, Equatable, Sendable {
        var add: [String]
        var remove: [String]
        /// The Finder label number to set, when the change sets one; nil = label untouched.
        var label: Int?
    }

    struct FileNumber: Codable, Equatable, Sendable {
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
    }

    private let lock = NSLock()
    private var _fileURL: URL
    private var _lastError: String?
    private static let log = Logger(subsystem: "com.archivereader.app", category: "AuditLedger")

    init(fileURL: URL) { _fileURL = fileURL }

    var fileURL: URL {
        get { lock.withLock { _fileURL } }
        set { lock.withLock { _fileURL = newValue } }
    }

    /// The last append failure, nil once an append succeeds.
    var lastError: String? { lock.withLock { _lastError } }

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
    func record(_ op: Operation, _ r: TagWriteResult) {
        guard !r.isNoOp else { return }
        let ctx = Self.context ?? Context(group: UUID(), undoes: nil)
        let entry = Entry(
            v: 1, timestamp: Date(), op: op, group: ctx.group, undoes: ctx.undoes,
            path: r.url.path,
            bookmark: try? r.url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
            file: Self.fileNumber(r.url),
            before: r.before, after: r.after, beforeLabel: r.beforeLabel, afterLabel: r.afterLabel,
            delta: Self.forwardDelta(r),
            inverse: Delta(add: r.occurrenceInverse.add, remove: r.occurrenceInverse.remove,
                           label: Self.label(of: r.occurrenceInverse.color)),
            unverified: nil)
        append(entry)
    }

    /// Append one line for a write that failed its post-write re-read (`.verificationFailed`).
    func recordUnverified(_ op: Operation, _ url: URL, _ why: String) {
        let ctx = Self.context ?? Context(group: UUID(), undoes: nil)
        let none = Delta(add: [], remove: [], label: nil)
        append(Entry(
            v: 1, timestamp: Date(), op: op, group: ctx.group, undoes: ctx.undoes, path: url.path,
            bookmark: try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
            file: Self.fileNumber(url), before: [], after: [], beforeLabel: nil, afterLabel: nil,
            delta: none, inverse: none, unverified: why))
    }

    func append(_ entry: Entry) {
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
                // Append-only: seek to the end and add one line; nothing already written is touched. A
                // crash mid-append can leave a last line with no newline; start a fresh line after it, so
                // the torn fragment costs only itself and not the entry written next.
                if Self.endsMidLine(url) { line.insert(0x0A, at: 0) }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                _lastError = nil
            }
        } catch {
            lock.withLock { _lastError = String(describing: error) }
            Self.log.error("audit ledger append failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Reading

    /// Every entry in file order. A line that does not decode (a torn last line after a crash) is
    /// skipped, never fatal: the rest of the history stays readable.
    func entries() -> [Entry] {
        guard let data = lock.withLock({ try? Data(contentsOf: _fileURL) }) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? Self.decoder.decode(Entry.self, from: Data($0)) }
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
    private static func fileNumber(_ url: URL) -> FileNumber? {
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
