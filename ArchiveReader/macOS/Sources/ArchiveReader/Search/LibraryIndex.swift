import Foundation
import SQLite3
import ArchiveCore

/// Durable identity for one Reader root in the disposable discovery cache.
///
/// Path alone is insufficient: nested roots legitimately contain the same absolute file paths, and a
/// replacement root mounted at an old pathname is not the same archive. The cache key is therefore the
/// conjunction required by the W26 plan: resolved byte-exact path + durable root-marker GUID.
struct LibraryIndexRoot: Sendable, Hashable {
    let path: String
    let markerGUID: UUID
}

/// Swift `String` equality is canonically equivalent, which is normally helpful but wrong for a
/// filesystem index: `café.pdf` and `cafe\u{301}.pdf` are distinct byte spellings and SQLite's BINARY
/// path key preserves both. Keep that property after loading rows into memory as well.
struct LibraryIndexPath: Sendable, Hashable {
    let value: String
    private let utf8: [UInt8]

    init(_ value: String) {
        self.value = value
        self.utf8 = Array(value.utf8)
    }

    init(_ url: URL) {
        self.init(url.withUnsafeFileSystemRepresentation { raw in
            raw.map(String.init(cString:)) ?? url.path
        })
    }

    var fileURL: URL {
        value.withCString {
            URL(fileURLWithFileSystemRepresentation: $0, isDirectory: false, relativeTo: nil)
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.utf8 == rhs.utf8 }
    func hash(into hasher: inout Hasher) { hasher.combine(utf8) }

    /// Byte-level path-component containment. Swift string prefix/equality is Unicode-canonical;
    /// cache trust boundaries must compare the filesystem spelling and require a `/` boundary.
    func isContained(in root: LibraryIndexPath) -> Bool {
        guard utf8.first == UInt8(ascii: "/"), root.utf8.first == UInt8(ascii: "/"),
              !hasTraversalComponent, !root.hasTraversalComponent else { return false }
        var rootBytes = root.utf8
        while rootBytes.count > 1, rootBytes.last == UInt8(ascii: "/") { rootBytes.removeLast() }
        guard utf8.starts(with: rootBytes) else { return false }
        if utf8.count == rootBytes.count { return true }
        if rootBytes == [UInt8(ascii: "/")] { return true }
        return utf8[rootBytes.count] == UInt8(ascii: "/")
    }

    private var hasTraversalComponent: Bool {
        utf8.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false).contains {
            $0 == [UInt8(ascii: ".")] || $0 == [UInt8(ascii: "."), UInt8(ascii: ".")]
        }
    }
}

/// One persisted regular file. Raw tags stay raw; `DocumentTags.parse` remains the only facet parser.
struct LibraryIndexEntry: Sendable, Equatable {
    let path: String
    let name: String
    let pathExtension: String
    let tagNames: [String]
    let labelNumber: Int?
    let fingerprint: CorpusFileFingerprint
    let tracked: Bool
    let verified: Bool

    func corpusEntry() -> CorpusEntry {
        CorpusEntry(url: LibraryIndexPath(path).fileURL,
                    tagNames: tagNames,
                    labelNumber: labelNumber,
                    contentModified: Date(timeIntervalSince1970: fingerprint.mtime),
                    contentTypeIdentifier: nil,
                    isDataless: fingerprint.isDataless,
                    fingerprint: fingerprint)
    }
}

struct LibraryIndexSnapshot: Sendable {
    let entries: [LibraryIndexPath: LibraryIndexEntry]
    /// Non-nil only when the newest scan finished cleanly and every loaded row is verified/decodable.
    let asOf: Date?
}

struct LibraryIndexScan: Sendable, Equatable {
    let rootID: Int64
    let scanID: Int64
}

struct LibraryIndexScanVerdict: Sendable {
    let finishedAt: Date
    let filesSeen: Int
    let directoryErrors: Int
    let outcome: String          // complete | partial | failed
    let absenceIsAuthoritative: Bool
}

/// Disposable SQLite cache for corpus discovery. The filesystem/xattrs are always the sole truth.
///
/// This is deliberately a sibling of `ContentIndex`, not an extension of it: discovery must produce
/// rows before content extraction can begin. SQLite's C API is the only persistence surface here; the
/// Reader's write-surface lint bans ordinary file-content writes throughout the app target.
actor LibraryIndex {
    enum IndexError: Error, Equatable {
        case open(String)
        case sql(String)
        case encode(String)
    }

    private var db: OpaquePointer?
    private let url: URL
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    /// Lets a regression test hold the actor at a committed batch boundary, cancel the caller, and
    /// prove a superseded 150k-row pass yields promptly instead of monopolising SQLite to completion.
    private let batchDidCommitForTesting: (@Sendable (Int) -> Void)?

    init(url: URL, batchDidCommitForTesting: (@Sendable (Int) -> Void)? = nil) {
        self.url = url
        self.batchDidCommitForTesting = batchDidCommitForTesting
    }

    func open() throws {
        guard db == nil else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            let message = lastMessage
            discardHandle()
            throw IndexError.open(message)
        }
        do {
            sqlite3_busy_timeout(db, 3000)
            try exec("PRAGMA journal_mode = WAL;")
            try exec("PRAGMA synchronous = NORMAL;")
            try exec("PRAGMA foreign_keys = ON;")
            try exec("""
                CREATE TABLE IF NOT EXISTS root (
                  id          INTEGER PRIMARY KEY,
                  path        TEXT COLLATE BINARY NOT NULL,
                  marker_guid TEXT NOT NULL,
                  UNIQUE(path, marker_guid)
                );
                """)
            try exec("""
                CREATE TABLE IF NOT EXISTS scan (
                  id          INTEGER PRIMARY KEY AUTOINCREMENT,
                  root_id     INTEGER NOT NULL REFERENCES root(id),
                  started     REAL NOT NULL,
                  finished    REAL,
                  dirs_seen   INTEGER NOT NULL DEFAULT 0,
                  files_seen  INTEGER NOT NULL DEFAULT 0,
                  dir_errors  INTEGER NOT NULL DEFAULT 0,
                  outcome     TEXT
                );
                """)
            try exec("""
                CREATE TABLE IF NOT EXISTS entry (
                  root_id      INTEGER NOT NULL REFERENCES root(id),
                  path         TEXT COLLATE BINARY NOT NULL,
                  name         TEXT NOT NULL,
                  ext          TEXT NOT NULL DEFAULT '',
                  mtime        REAL NOT NULL,
                  ctime        REAL NOT NULL,
                  size         INTEGER NOT NULL DEFAULT 0,
                  ino          INTEGER NOT NULL DEFAULT 0,
                  tags_raw     TEXT NOT NULL,
                  label        INTEGER,
                  tracked      INTEGER NOT NULL,
                  verified     INTEGER NOT NULL,
                  is_dataless  INTEGER NOT NULL DEFAULT 0,
                  last_scan_id INTEGER NOT NULL,
                  PRIMARY KEY(root_id, path)
                );
                """)
            try exec("CREATE INDEX IF NOT EXISTS entry_root_tracked ON entry(root_id, tracked);")
            try exec("""
                CREATE TABLE IF NOT EXISTS jpeg_partner_scan (
                  root_id      INTEGER NOT NULL REFERENCES root(id),
                  subtree_path TEXT COLLATE BINARY NOT NULL,
                  scanned_at   REAL NOT NULL,
                  files_seen   INTEGER NOT NULL,
                  clean        INTEGER NOT NULL,
                  PRIMARY KEY(root_id, subtree_path)
                );
                """)
            try exec("""
                CREATE TABLE IF NOT EXISTS jpeg_partner (
                  root_id           INTEGER NOT NULL REFERENCES root(id),
                  subtree_path      TEXT COLLATE BINARY NOT NULL,
                  stem              TEXT COLLATE BINARY NOT NULL,
                  path              TEXT COLLATE BINARY NOT NULL,
                  collection_context TEXT COLLATE BINARY NOT NULL,
                  mtime             REAL NOT NULL,
                  ctime             REAL NOT NULL,
                  size              INTEGER NOT NULL,
                  ino               INTEGER NOT NULL,
                  is_dataless       INTEGER NOT NULL,
                  PRIMARY KEY(root_id, subtree_path, path)
                );
                """)
            try exec("CREATE INDEX IF NOT EXISTS jpeg_partner_stem ON jpeg_partner(root_id, subtree_path, stem);")
        } catch {
            discardHandle()
            throw error
        }
    }

    func close() { discardHandle() }

    /// Revalidate the persisted JPEG stem table against a fresh fingerprint walk, then warm-start from
    /// SQLite when every candidate path and fingerprint still matches. A partial/denied pass revokes the
    /// clean marker and preserves prior rows, but always returns an index whose lookups are `unknown`.
    func revalidatedJPEGPartnerIndex(for root: LibraryIndexRoot, jpegRoot: URL,
                                     scan: CorpusFingerprintScanResult,
                                     scannedAt: Date = Date()) throws -> JPEGPartnerIndex {
        let fresh = JPEGPartnerIndex(jpegRoot: jpegRoot, scan: scan)
        guard fresh.isClean else {
            try storeJPEGPartnerIndex(fresh, for: root, scannedAt: scannedAt)
            return fresh
        }
        if let cached = try cachedJPEGPartnerIndex(for: root, jpegRoot: jpegRoot),
           cached.candidates == fresh.candidates {
            return cached
        }
        try storeJPEGPartnerIndex(fresh, for: root, scannedAt: scannedAt)
        return fresh
    }

    /// Persist the JPEG stem index in the same disposable DB as the Reader's discovery cache. A partial
    /// or denied walk revokes the clean marker but preserves old rows for a later revalidation pass.
    private func storeJPEGPartnerIndex(_ partnerIndex: JPEGPartnerIndex, for root: LibraryIndexRoot,
                                       scannedAt: Date) throws {
        try open()
        guard let rootID = try rootID(for: root, create: true) else {
            throw IndexError.sql("could not create LibraryIndex root for JPEG partner scan")
        }
        let subtreePath = LibraryIndexPath(partnerIndex.jpegRootPath).value
        try exec("BEGIN IMMEDIATE;")
        do {
            if partnerIndex.isClean {
                try run("DELETE FROM jpeg_partner WHERE root_id = ? AND subtree_path = ?;") {
                    sqlite3_bind_int64($0, 1, rootID)
                    bindText($0, 2, subtreePath)
                }
                for candidate in partnerIndex.candidates {
                    try run("""
                        INSERT INTO jpeg_partner(
                          root_id, subtree_path, stem, path, collection_context,
                          mtime, ctime, size, ino, is_dataless
                        ) VALUES(?,?,?,?,?,?,?,?,?,?);
                        """) { stmt in
                        sqlite3_bind_int64(stmt, 1, rootID)
                        bindText(stmt, 2, subtreePath)
                        bindText(stmt, 3, candidate.stem)
                        bindText(stmt, 4, LibraryIndexPath(candidate.path).value)
                        bindText(stmt, 5, candidate.collectionContext)
                        sqlite3_bind_double(stmt, 6, candidate.fingerprint.mtime)
                        sqlite3_bind_double(stmt, 7, candidate.fingerprint.ctime)
                        sqlite3_bind_int64(stmt, 8, candidate.fingerprint.size)
                        sqlite3_bind_int64(stmt, 9, Int64(bitPattern: candidate.fingerprint.inode))
                        sqlite3_bind_int(stmt, 10, candidate.fingerprint.isDataless ? 1 : 0)
                    }
                }
            }
            try run("""
                INSERT INTO jpeg_partner_scan(root_id,subtree_path,scanned_at,files_seen,clean)
                VALUES(?,?,?,?,?)
                ON CONFLICT(root_id,subtree_path) DO UPDATE SET
                  scanned_at=excluded.scanned_at, files_seen=excluded.files_seen, clean=excluded.clean;
                """) {
                sqlite3_bind_int64($0, 1, rootID)
                bindText($0, 2, subtreePath)
                sqlite3_bind_double($0, 3, scannedAt.timeIntervalSince1970)
                sqlite3_bind_int64($0, 4, Int64(partnerIndex.filesSeen))
                sqlite3_bind_int($0, 5, partnerIndex.isClean ? 1 : 0)
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Load only a stem table established by a clean fingerprint walk. Nil means the partner state is
    /// unknown (no walk yet, or the latest walk was incomplete), not that a PDF has no partner.
    private func cachedJPEGPartnerIndex(for root: LibraryIndexRoot,
                                        jpegRoot: URL) throws -> JPEGPartnerIndex? {
        try open()
        guard let rootID = try rootID(for: root, create: false) else { return nil }
        let subtreePath = LibraryIndexPath(jpegRoot).value
        var filesSeen = 0
        guard let scan = prepare("""
            SELECT files_seen, clean FROM jpeg_partner_scan WHERE root_id = ? AND subtree_path = ?;
            """) else { throw IndexError.sql(lastMessage) }
        sqlite3_bind_int64(scan, 1, rootID)
        bindText(scan, 2, subtreePath)
        let scanResult = sqlite3_step(scan)
        if scanResult == SQLITE_ROW {
            filesSeen = Int(sqlite3_column_int64(scan, 0))
            guard sqlite3_column_int(scan, 1) != 0 else {
                sqlite3_finalize(scan)
                return nil
            }
        } else {
            sqlite3_finalize(scan)
            if scanResult != SQLITE_DONE { throw IndexError.sql(lastMessage) }
            return nil
        }
        sqlite3_finalize(scan)

        guard let stmt = prepare("""
            SELECT stem,path,collection_context,mtime,ctime,size,ino,is_dataless
            FROM jpeg_partner WHERE root_id = ? AND subtree_path = ?;
            """) else { throw IndexError.sql(lastMessage) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, rootID)
        bindText(stmt, 2, subtreePath)
        var candidates: [JPEGPartnerCandidate] = []
        while true {
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw IndexError.sql(lastMessage) }
            guard let stem = text(stmt, 0), let path = text(stmt, 1),
                  let context = text(stmt, 2) else {
                throw IndexError.sql("malformed JPEG partner row")
            }
            candidates.append(JPEGPartnerCandidate(
                stem: stem, path: path, collectionContext: context,
                fingerprint: CorpusFileFingerprint(
                    mtime: sqlite3_column_double(stmt, 3), ctime: sqlite3_column_double(stmt, 4),
                    size: sqlite3_column_int64(stmt, 5),
                    inode: UInt64(bitPattern: sqlite3_column_int64(stmt, 6)),
                    isDataless: sqlite3_column_int(stmt, 7) != 0)))
        }
        return JPEGPartnerIndex(jpegRootPath: subtreePath, candidates: candidates,
                                isClean: true, filesSeen: filesSeen)
    }

    /// Load a root's complete cache in one query. A partial/crashed newest scan still returns rows,
    /// but with `asOf == nil`; callers must render them as cache/unverified and stay non-settled.
    func snapshot(for root: LibraryIndexRoot) throws -> LibraryIndexSnapshot {
        try Task.checkCancellation()
        try open()
        guard let rootID = try rootID(for: root, create: false) else {
            return LibraryIndexSnapshot(entries: [:], asOf: nil)
        }

        var asOf: Date?
        if let stmt = prepare("""
            SELECT finished, outcome, dir_errors
            FROM scan WHERE root_id = ? ORDER BY id DESC LIMIT 1;
            """) {
            sqlite3_bind_int64(stmt, 1, rootID)
            if sqlite3_step(stmt) == SQLITE_ROW,
               sqlite3_column_type(stmt, 0) != SQLITE_NULL,
               text(stmt, 1) == "complete",
               sqlite3_column_int(stmt, 2) == 0 {
                asOf = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
            }
            sqlite3_finalize(stmt)
        }

        guard let stmt = prepare("""
            SELECT path,name,ext,mtime,ctime,size,ino,tags_raw,label,tracked,verified,is_dataless
            FROM entry WHERE root_id = ?;
            """) else { throw IndexError.sql(lastMessage) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, rootID)

        var rows: [LibraryIndexPath: LibraryIndexEntry] = [:]
        var everyRowVerifiedAndDecodable = true
        var rowNumber = 0
        while true {
            if rowNumber.isMultiple(of: 500) { try Task.checkCancellation() }
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw IndexError.sql(lastMessage) }
            rowNumber += 1
            guard let path = text(stmt, 0), let name = text(stmt, 1),
                  let ext = text(stmt, 2), let raw = text(stmt, 7),
                  let tags = Self.decodeTags(raw) else {
                everyRowVerifiedAndDecodable = false
                continue
            }
            let verified = sqlite3_column_int(stmt, 10) != 0
            everyRowVerifiedAndDecodable = everyRowVerifiedAndDecodable && verified
            let fingerprint = CorpusFileFingerprint(
                mtime: sqlite3_column_double(stmt, 3),
                ctime: sqlite3_column_double(stmt, 4),
                size: sqlite3_column_int64(stmt, 5),
                inode: UInt64(bitPattern: sqlite3_column_int64(stmt, 6)),
                isDataless: sqlite3_column_int(stmt, 11) != 0
            )
            rows[LibraryIndexPath(path)] = LibraryIndexEntry(
                path: path,
                name: name,
                pathExtension: ext,
                tagNames: tags,
                labelNumber: sqlite3_column_type(stmt, 8) == SQLITE_NULL
                    ? nil : Int(sqlite3_column_int(stmt, 8)),
                fingerprint: fingerprint,
                tracked: sqlite3_column_int(stmt, 9) != 0,
                verified: verified
            )
        }
        if !everyRowVerifiedAndDecodable { asOf = nil }
        return LibraryIndexSnapshot(entries: rows, asOf: asOf)
    }

#if DEBUG
    /// Force a deterministic SQLite step error in tests; production never changes connection limits.
    func setLengthLimitForTesting(_ bytes: Int32) throws -> Int32 {
        try open()
        return sqlite3_limit(db, SQLITE_LIMIT_LENGTH, bytes)
    }
#endif

    /// Record scan provenance before filesystem work starts, and mark carried rows unverified. If the
    /// process quits before `completeScan`, `finished` remains NULL and the next warm start cannot claim
    /// currency for a partially rewritten cache.
    func beginScan(root: LibraryIndexRoot, startedAt: Date = Date()) throws -> LibraryIndexScan {
        try Task.checkCancellation()
        try open()
        let rootID = try rootID(for: root, create: true)!
        try exec("BEGIN IMMEDIATE;")
        do {
            try run("INSERT INTO scan(root_id,started) VALUES(?,?);") {
                sqlite3_bind_int64($0, 1, rootID)
                sqlite3_bind_double($0, 2, startedAt.timeIntervalSince1970)
            }
            let scanID = sqlite3_last_insert_rowid(db)
            try run("UPDATE entry SET verified = 0 WHERE root_id = ?;") {
                sqlite3_bind_int64($0, 1, rootID)
            }
            try exec("COMMIT;")
            return LibraryIndexScan(rootID: rootID, scanID: scanID)
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Persist every readable regular file from one pass in 500-row transactions, then atomically
    /// apply absence only for an authoritative pass and finish its provenance row.
    func completeScan(_ scan: LibraryIndexScan, entries: [CorpusEntry],
                      verdict: LibraryIndexScanVerdict) throws {
        try Task.checkCancellation()
        try open()
        var usable: [(CorpusEntry, CorpusFileFingerprint, String)] = []
        usable.reserveCapacity(entries.count)
        for (offset, entry) in entries.enumerated() {
            if offset.isMultiple(of: 500) { try Task.checkCancellation() }
            guard let fingerprint = entry.fingerprint else {
                throw IndexError.encode("missing stat fingerprint for \(entry.url.path)")
            }
            usable.append((entry, fingerprint, try Self.encodeTags(entry.tagNames)))
        }

        let batchSize = 500
        for start in stride(from: 0, to: usable.count, by: batchSize) {
            try Task.checkCancellation()
            let batch = usable[start..<min(start + batchSize, usable.count)]
            try exec("BEGIN IMMEDIATE;")
            do {
                for (entry, fingerprint, rawTags) in batch {
                    try upsert(entry, fingerprint: fingerprint, rawTags: rawTags, scan: scan)
                }
                try exec("COMMIT;")
                batchDidCommitForTesting?(start / batchSize)
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }

        // A canceled pass deliberately leaves its scan unfinished and any committed rows unverified.
        // The next warm start may reuse their raw metadata only after a fresh fingerprint match; it
        // may never claim authoritative absence or a settled as-of date for this partial rewrite.
        try Task.checkCancellation()
        try exec("BEGIN IMMEDIATE;")
        do {
            if verdict.absenceIsAuthoritative {
                try run("DELETE FROM entry WHERE root_id = ? AND last_scan_id != ?;") {
                    sqlite3_bind_int64($0, 1, scan.rootID)
                    sqlite3_bind_int64($0, 2, scan.scanID)
                }
                try run("UPDATE entry SET verified = 1 WHERE root_id = ? AND last_scan_id = ?;") {
                    sqlite3_bind_int64($0, 1, scan.rootID)
                    sqlite3_bind_int64($0, 2, scan.scanID)
                }
            }
            try run("""
                UPDATE scan SET finished = ?, files_seen = ?, dir_errors = ?, outcome = ? WHERE id = ?;
                """) {
                sqlite3_bind_double($0, 1, verdict.finishedAt.timeIntervalSince1970)
                sqlite3_bind_int64($0, 2, Int64(verdict.filesSeen))
                sqlite3_bind_int64($0, 3, Int64(verdict.directoryErrors))
                bindText($0, 4, verdict.outcome)
                sqlite3_bind_int64($0, 5, scan.scanID)
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
        try? exec("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    private func upsert(_ entry: CorpusEntry, fingerprint: CorpusFileFingerprint,
                        rawTags: String, scan: LibraryIndexScan) throws {
        let path = LibraryIndexPath(entry.url)
        try run("""
            INSERT INTO entry(root_id,path,name,ext,mtime,ctime,size,ino,tags_raw,label,tracked,
                              verified,is_dataless,last_scan_id)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(root_id,path) DO UPDATE SET
              name=excluded.name, ext=excluded.ext, mtime=excluded.mtime, ctime=excluded.ctime,
              size=excluded.size, ino=excluded.ino, tags_raw=excluded.tags_raw, label=excluded.label,
              tracked=excluded.tracked, verified=0, is_dataless=excluded.is_dataless,
              last_scan_id=excluded.last_scan_id;
            """) { stmt in
            sqlite3_bind_int64(stmt, 1, scan.rootID)
            bindText(stmt, 2, path.value)
            bindText(stmt, 3, (path.value as NSString).lastPathComponent)
            bindText(stmt, 4, (path.value as NSString).pathExtension)
            sqlite3_bind_double(stmt, 5, fingerprint.mtime)
            sqlite3_bind_double(stmt, 6, fingerprint.ctime)
            sqlite3_bind_int64(stmt, 7, fingerprint.size)
            sqlite3_bind_int64(stmt, 8, Int64(bitPattern: fingerprint.inode))
            bindText(stmt, 9, rawTags)
            if let label = entry.labelNumber { sqlite3_bind_int(stmt, 10, Int32(label)) }
            else { sqlite3_bind_null(stmt, 10) }
            sqlite3_bind_int(stmt, 11, CorpusWalker.tracksReadState(entry.tagNames) ? 1 : 0)
            sqlite3_bind_int(stmt, 12, 0)
            sqlite3_bind_int(stmt, 13, fingerprint.isDataless ? 1 : 0)
            sqlite3_bind_int64(stmt, 14, scan.scanID)
        }
    }

    private func rootID(for root: LibraryIndexRoot, create: Bool) throws -> Int64? {
        if let stmt = prepare("SELECT id FROM root WHERE path = ? AND marker_guid = ?;") {
            bindText(stmt, 1, root.path)
            bindText(stmt, 2, root.markerGUID.uuidString.lowercased())
            if sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                sqlite3_finalize(stmt)
                return id
            }
            sqlite3_finalize(stmt)
        }
        guard create else { return nil }
        try run("INSERT INTO root(path,marker_guid) VALUES(?,?);") {
            bindText($0, 1, root.path)
            bindText($0, 2, root.markerGUID.uuidString.lowercased())
        }
        return sqlite3_last_insert_rowid(db)
    }

    private static func encodeTags(_ tags: [String]) throws -> String {
        let data = try JSONEncoder().encode(tags)
        guard let value = String(data: data, encoding: .utf8) else {
            throw IndexError.encode("tag array did not encode as UTF-8")
        }
        return value
    }

    private static func decodeTags(_ raw: String) -> [String]? {
        raw.data(using: .utf8).flatMap { try? JSONDecoder().decode([String].self, from: $0) }
    }

    private func discardHandle() {
        if db != nil { sqlite3_close_v2(db); db = nil }
    }

    private func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? lastMessage
            sqlite3_free(error)
            throw IndexError.sql(message)
        }
    }

    private func run(_ sql: String, _ bind: (OpaquePointer) -> Void) throws {
        guard let stmt = prepare(sql) else { throw IndexError.sql(lastMessage) }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        let result = sqlite3_step(stmt)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw IndexError.sql(lastMessage) }
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        return sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK ? stmt : nil
    }

    private func bindText(_ stmt: OpaquePointer?, _ column: Int32, _ value: String) {
        sqlite3_bind_text(stmt, column, value, -1, transient)
    }

    private func text(_ stmt: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(stmt, column).map { String(cString: $0) }
    }

    private var lastMessage: String {
        db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown SQLite error"
    }
}
