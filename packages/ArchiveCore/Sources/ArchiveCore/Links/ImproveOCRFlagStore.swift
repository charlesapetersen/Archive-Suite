// ImproveOCRFlagStore.swift — the shared "OCR Poor" flag generations for Improve OCR (ArchiveCore)
//
// `SPEC/improve-ocr.md` §3. The Reader flags and unflags a file; the Processor clears the flag when the
// person accepts a better reading, and puts it back on a restore. Both apps record each such action here, in the
// connected shared support folder, so an acceptance can tell whether the flag it reviewed is still the flag on the
// file: every action advances the file's generation, even when the tag already had the requested value.
//
// Protocol, for every suite action that changes `OCR Poor`:
//   1. take the file's lock (`withLock`) — always BEFORE any NSFileCoordinator, never from inside a coordinator block;
//   2. `begin` the action: an intent file naming the next generation and the wanted value, synced, before the tag moves;
//   3. change the tag through the app's audited tag writer;
//   4. `commit` with the value actually read back: the intent becomes a numbered event, and the intent goes.
// A crash between 2 and 4 leaves the intent as a barrier: `begin` refuses until `reconcile` records what the tag
// really is now. No JSON is ever read, changed and written back; events are created once, exclusively.
//
// Limit (stated, not hidden): this covers cooperating suite actions. Finder or another tool can remove and re-add the
// tag with no event, and a boolean tag cannot show that; callers re-read the actual tag inside coordination.
// The store holds no OCR text, no credentials and no corpus paths beyond the relative path in each `key.json`.
// Every file is published by `link(2)` from a synced temporary, so none is ever seen half-written. `withLock` waits
// up to `lockTimeout` and must not be called on the main thread; nor nested on one key (it would time out on itself).
// The support folder must be on a local volume, not synced (iCloud and the like copy conflicts instead of locking),
// and not inside an archive root. The caller holds any security scope it needs.
import CryptoKit
import Darwin
import Foundation

public struct ImproveOCRFlagStore: Sendable {
    /// The connected shared support folder (`~/Library/Application Support/ArchiveSuite/ImproveOCR` by default).
    public let support: URL
    /// How long `withLock` waits for another app's action on the same file before giving up.
    public let lockTimeout: TimeInterval

    public init(support: URL, lockTimeout: TimeInterval = 10) {
        self.support = support
        self.lockTimeout = lockTimeout
    }

    public static let folder = "Flags"

    /// One file of one archive: its root's GUID and its path inside that root, NFC-normalised (Unicode composition
    /// only; letter case is kept, since a case-sensitive volume holds both spellings).
    public struct FileKey: Hashable, Codable, Sendable {
        public let rootGUID: UUID
        public let relativePath: String

        init(rootGUID: UUID, relativePath: String) {
            self.rootGUID = rootGUID
            self.relativePath = relativePath.precomposedStringWithCanonicalMapping
        }

        /// The key for `file` inside the root folder `root`, built the same way by every app: both paths resolved
        /// (links, `/var` and `/private/var`), the file required to lie inside the root, and each component spelled
        /// as the volume stores it, so a hand-off path, a case-only difference on a case-insensitive volume or a
        /// different Unicode composition all name one key.
        public init(rootGUID: UUID, root: URL, file: URL) throws {
            guard let rootPath = ImproveOCRFlagStore.resolved(root.path), let filePath = ImproveOCRFlagStore.resolved(file.path) else {
                throw StoreError.notInRoot
            }
            let r = (rootPath as NSString).pathComponents, f = (filePath as NSString).pathComponents
            guard f.count > r.count, Array(f.prefix(r.count)) == r else { throw StoreError.notInRoot }
            var path = rootPath, parts: [String] = []
            for component in f.dropFirst(r.count) {
                path = (path as NSString).appendingPathComponent(component)
                guard let stored = ImproveOCRFlagStore.storedName(path) else { throw StoreError.notInRoot }
                parts.append(stored)
            }
            self.init(rootGUID: rootGUID, relativePath: parts.joined(separator: "/"))
        }

        /// The folder name: a digest, so no path text becomes a file name.
        var digest: String {
            let bytes = Data((rootGUID.uuidString.lowercased() + "\u{0}" + relativePath).utf8)
            return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
    }

    public enum Origin: String, Codable, Sendable {
        /// A person flagged or unflagged the file (Reader).
        case flag, unflag
        /// Accepting a better reading cleared the flag (Processor).
        case acceptedClear
        /// Restoring the old text put the flag back (Processor).
        case restored
        /// After a crash, the tag as it actually was.
        case reconciled
    }

    public struct Intent: Codable, Equatable, Sendable {
        public let operationID: UUID
        public let generation: UUID
        public let flagged: Bool
        public let origin: Origin
        public let app: String
        public let date: Date
    }

    public struct Event: Codable, Equatable, Sendable {
        public let sequence: Int
        public let operationID: UUID
        public let generation: UUID
        /// What the tag was read back as when the action finished, not merely what was asked for.
        public let flagged: Bool
        public let requested: Bool?
        public let origin: Origin
        public let app: String
        public let date: Date
    }

    public struct State: Equatable, Sendable {
        /// The latest finished action's generation; nil when no suite action was ever recorded.
        public let generation: UUID?
        public let flagged: Bool?
        /// An action that began and did not finish: a barrier until `reconcile`.
        public let pending: Intent?
        /// An unfinished action whose record cannot be read; also a barrier until `reconcile`.
        public let pendingUnreadable: Bool
        /// The operation and origin of the latest finished action, so a caller can tell its own earlier attempt.
        public let lastOperationID: UUID?
        public let lastOrigin: Origin?

        public init(generation: UUID?, flagged: Bool?, pending: Intent?, pendingUnreadable: Bool = false,
                    lastOperationID: UUID? = nil, lastOrigin: Origin? = nil) {
            self.generation = generation; self.flagged = flagged; self.pending = pending
            self.pendingUnreadable = pendingUnreadable
            self.lastOperationID = lastOperationID; self.lastOrigin = lastOrigin
        }

        public var isPending: Bool { pending != nil || pendingUnreadable }
    }

    public enum StoreError: Error, Equatable, Sendable {
        case busy
        case pendingAction(UUID)
        case noPendingAction
        case notOurIntent
        case notPrivate(String)
        case notInRoot
        case unsuitableFolder(String)
        case generationChanged
        case io(String)
    }

    /// Runs `body` while holding the file's lock, shared by every app on this Mac through `flock(2)` on the store's
    /// lock file. The lock is released when `body` returns or throws.
    public func withLock<T>(_ key: FileKey, app: String, _ body: (Locked) throws -> T) throws -> T {
        try checkSuitable()
        let dir = try prepareFolder(key)
        let lockPath = dir.appendingPathComponent("lock").path
        let fd = open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StoreError.io("lock: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        let deadline = Date().addingTimeInterval(lockTimeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { throw StoreError.io("lock: \(String(cString: strerror(errno)))") }
            if Date() >= deadline { throw StoreError.busy }
            usleep(20_000)
        }
        defer { flock(fd, LOCK_UN) }
        return try body(Locked(directory: dir, app: app))
    }

    /// The file's state without taking the lock: for display only, never for a decision. Nil when no suite action
    /// was ever recorded; throws when the record cannot be read.
    public func peek(_ key: FileKey) throws -> State? {
        let dir = support.appendingPathComponent(Self.folder, isDirectory: true).appendingPathComponent(key.digest, isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        return try Locked(directory: dir, app: "").state()
    }

    /// Operations on one file, valid only inside `withLock`.
    public struct Locked {
        let directory: URL
        let app: String

        private var intentURL: URL { directory.appendingPathComponent("intent.json") }
        private var eventsURL: URL { directory.appendingPathComponent("events", isDirectory: true) }

        public func state() throws -> State {
            let events = try eventFiles()
            let last = try events.last.map { try ImproveOCRFlagStore.decode(Event.self, from: eventsURL.appendingPathComponent($0)) }
            let pending = FileManager.default.fileExists(atPath: intentURL.path)
                ? Optional(try? ImproveOCRFlagStore.decode(Intent.self, from: intentURL)) : nil
            return State(generation: last?.generation, flagged: last?.flagged, pending: pending ?? nil,
                         pendingUnreadable: pending.map { $0 == nil } ?? false,
                         lastOperationID: last?.operationID, lastOrigin: last?.origin)
        }

        /// Records that an action is about to set the tag to `flagged`, with a new generation. Refuses while another
        /// action is unfinished.
        public func begin(flagged: Bool, origin: Origin, operationID: UUID = UUID()) throws -> Intent {
            try begin(flagged: flagged, origin: origin, operationID: operationID, expecting: nil)
        }

        /// `begin`, only when the file's generation is still `generation`: the check an acceptance makes before it
        /// clears the flag it reviewed (nil: no suite action recorded when it was reviewed).
        public func begin(flagged: Bool, origin: Origin, ifGenerationIs generation: UUID?, operationID: UUID = UUID()) throws -> Intent {
            try begin(flagged: flagged, origin: origin, operationID: operationID, expecting: .some(generation))
        }

        private func begin(flagged: Bool, origin: Origin, operationID: UUID, expecting: UUID??) throws -> Intent {
            let now = try state()
            if let pending = now.pending { throw StoreError.pendingAction(pending.operationID) }
            if now.pendingUnreadable { throw StoreError.pendingAction(UUID(uuidString: "00000000-0000-0000-0000-000000000000")!) }
            if let expecting, now.generation != expecting { throw StoreError.generationChanged }
            let intent = Intent(operationID: operationID, generation: UUID(), flagged: flagged, origin: origin, app: app,
                                date: ImproveOCRFlagStore.now())
            try ImproveOCRFlagStore.createExclusive(intentURL, ImproveOCRFlagStore.encode(intent))
            return intent
        }

        /// Finishes `intent` with the tag as it was read back after the change.
        @discardableResult
        public func commit(_ intent: Intent, observedFlagged: Bool) throws -> Event {
            guard let pending = try state().pending else { throw StoreError.noPendingAction }
            guard pending.operationID == intent.operationID, pending.generation == intent.generation else {
                throw StoreError.notOurIntent
            }
            return try finish(pending, flagged: observedFlagged, requested: pending.flagged, origin: pending.origin)
        }

        /// After a crash: records the tag as it actually is under the unfinished intent's generation, and lifts the
        /// barrier. Nil when nothing was pending.
        @discardableResult
        public func reconcile(observedFlagged: Bool) throws -> Event? {
            let now = try state()
            if let pending = now.pending {
                return try finish(pending, flagged: observedFlagged, requested: pending.flagged, origin: .reconciled)
            }
            guard now.pendingUnreadable else { return nil }
            // What was asked is lost with the record; a new generation still marks that something happened.
            let lost = Intent(operationID: UUID(), generation: UUID(), flagged: observedFlagged, origin: .reconciled,
                              app: app, date: ImproveOCRFlagStore.now())
            return try finish(lost, flagged: observedFlagged, requested: nil, origin: .reconciled)
        }

        private func finish(_ intent: Intent, flagged: Bool, requested: Bool?, origin: Origin) throws -> Event {
            let files = try eventFiles()
            // A retry after the event was made durable but before the intent went: only remove the intent.
            if let lastName = files.last,
               let last = try? ImproveOCRFlagStore.decode(Event.self, from: eventsURL.appendingPathComponent(lastName)),
               last.operationID == intent.operationID, last.generation == intent.generation {
                try removeIntent()
                return last
            }
            let next = (files.last.flatMap { Int($0.prefix(10)) } ?? 0) + 1
            let event = Event(sequence: next, operationID: intent.operationID, generation: intent.generation,
                              flagged: flagged, requested: requested, origin: origin, app: app, date: ImproveOCRFlagStore.now())
            try ImproveOCRFlagStore.makePrivateFolder(eventsURL)
            try ImproveOCRFlagStore.createExclusive(eventsURL.appendingPathComponent(String(format: "%010d.json", next)),
                                                    ImproveOCRFlagStore.encode(event))
            try removeIntent()
            return event
        }

        private func removeIntent() throws {
            guard unlink(intentURL.path) == 0 || errno == ENOENT else { throw StoreError.io("intent: \(String(cString: strerror(errno)))") }
            try ImproveOCRFlagStore.syncDirectory(directory)
        }

        private func eventFiles() throws -> [String] {
            guard FileManager.default.fileExists(atPath: eventsURL.path) else { return [] }
            do {
                return try FileManager.default.contentsOfDirectory(atPath: eventsURL.path)
                    .filter { $0.count == 15 && $0.hasSuffix(".json") && Int($0.prefix(10)) != nil }.sorted()
            } catch { throw StoreError.io("events: \(error)") }
        }
    }

    // MARK: Files

    /// Refuses a support folder on a network or synced volume, or inside an archive root (marked by
    /// `RootMarker.filename` in it or any folder above it).
    public func checkSuitable() throws {
        var fs = statfs()
        guard statfs(support.path, &fs) == 0 else { throw StoreError.unsuitableFolder("it cannot be read") }
        guard fs.f_flags & UInt32(MNT_LOCAL) != 0 else { throw StoreError.unsuitableFolder("it is not on a local disk") }
        if (try? support.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true {
            throw StoreError.unsuitableFolder("it is synced to the cloud")
        }
        var dir = Self.resolved(support.path) ?? support.path
        while true {
            if FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(RootMarker.filename)) {
                throw StoreError.unsuitableFolder("it is inside an archive")
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { break }
            dir = parent
        }
    }

    static func resolved(_ path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    /// The name the volume stores for the last component of `path` (its own case and composition).
    static func storedName(_ path: String) -> String? {
        var list = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: attrgroup_t(ATTR_CMN_NAME),
                            volattr: 0, dirattr: 0, fileattr: 0, forkattr: 0)
        var buffer = [UInt8](repeating: 0, count: 4 + MemoryLayout<attrreference_t>.size + Int(NAME_MAX) * 3 + 1)
        let ok = buffer.withUnsafeMutableBytes { getattrlist(path, &list, $0.baseAddress, $0.count, UInt32(FSOPT_NOFOLLOW)) }
        guard ok == 0 else { return nil }
        return buffer.withUnsafeBytes { raw -> String? in
            let ref = raw.loadUnaligned(fromByteOffset: 4, as: attrreference_t.self)
            let start = 4 + Int(ref.attr_dataoffset), length = Int(ref.attr_length)
            guard length > 0, start + length <= raw.count else { return nil }
            let bytes = raw[start..<(start + length)].prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    private func prepareFolder(_ key: FileKey) throws -> URL {
        let flags = support.appendingPathComponent(Self.folder, isDirectory: true)
        try Self.makePrivateFolder(flags)
        let dir = flags.appendingPathComponent(key.digest, isDirectory: true)
        try Self.makePrivateFolder(dir)
        let keyURL = dir.appendingPathComponent("key.json")
        // Which file this folder is for, for a person or a repair; written once, and only informational.
        if !FileManager.default.fileExists(atPath: keyURL.path) { try? Self.createExclusive(keyURL, Self.encode(key)) }
        return dir
    }

    static func makePrivateFolder(_ url: URL) throws {
        if mkdir(url.path, 0o700) != 0 && errno != EEXIST { throw StoreError.io("\(url.lastPathComponent): \(String(cString: strerror(errno)))") }
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid(), st.st_mode & 0o077 == 0 else {
            throw StoreError.notPrivate(url.path)
        }
    }

    /// Writes `data` to a temporary in the same folder, syncs it, then publishes it at `url` with `link(2)`, which
    /// fails rather than replace an existing file; the temporary is then removed and the folder synced. A crash leaves
    /// either no file at `url` or the whole one, never a part (a stray temporary is ignored by every reader).
    static func createExclusive(_ url: URL, _ data: Data) throws {
        let dir = url.deletingLastPathComponent()
        let temp = dir.appendingPathComponent(".tmp-\(UUID().uuidString)").path
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StoreError.io("\(url.lastPathComponent): \(String(cString: strerror(errno)))") }
        defer { unlink(temp) }
        let ok = data.withUnsafeBytes { raw -> Bool in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 { if errno == EINTR { continue }; return false }
                off += n
            }
            return true
        }
        let synced = ok && (fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0)
        close(fd)
        guard synced else { throw StoreError.io("\(url.lastPathComponent): \(String(cString: strerror(errno)))") }
        guard link(temp, url.path) == 0 else { throw StoreError.io("\(url.lastPathComponent): \(String(cString: strerror(errno)))") }
        try syncDirectory(dir)
    }

    static func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw StoreError.io("\(url.lastPathComponent): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else { throw StoreError.io("sync: \(String(cString: strerror(errno)))") }
    }

    /// Whole seconds, as ISO 8601 keeps them, so a value reads back equal to the one written.
    static func now() -> Date { Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)) }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        do { return try e.encode(value) } catch { throw StoreError.io("encode: \(error)") }
    }

    static func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        do { return try d.decode(type, from: Data(contentsOf: url)) } catch { throw StoreError.io("\(url.lastPathComponent): \(error)") }
    }
}
