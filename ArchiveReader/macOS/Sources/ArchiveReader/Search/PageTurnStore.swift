import Foundation
import SQLite3
import os
import ArchiveCore

/// W40.reader-view-rotate (owner's Reader notes, 2026-11-10, point 7): a page turned in the viewer, remembered in
/// the Reader's own store and never in the file. The Core Directive forbids changing a file's bytes, so a turn is
/// a way of showing the page: `PDFPaneController.show` turns its private copy of the page, and nothing here or
/// there opens the file for writing.
///
/// The turns live in the library index's database (`ArchiveLibrary.defaultLibraryIndexURL`), in a table of their
/// own that no walk reads or rebuilds. Unlike the rest of that file they are the reader's choices, not a cache, so
/// deleting the database forgets them. A turn is kept per file and image page, with the file's size and
/// modification time: a file rewritten since (a Processor re-run) shows upright again, because the turn described
/// the old scan. Turning a page back to upright, or Reset Rotation, deletes its row.
///
/// Each row also records a page the Processor left sideways (`W46.rotation-default`), which is why the rows say how
/// far the reader turned it: `turnedPages()` lists them, so they can later serve as rotation truth.
///
/// Writes go to the database on a private serial queue, so a long index commit never holds the main thread; the
/// rows are read once, at first use. Unit-test hosts and UI-test fixture launches keep the turns in memory only,
/// so no test reaches the owner's real database.
@MainActor
final class PageTurnStore {
    /// One turned page. `turns` is quarter turns clockwise, 1…3.
    struct Turn: Equatable, Sendable {
        let path: String
        let page: Int
        let turns: Int
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let turnedAt: Date
    }

    static let shared: PageTurnStore = {
        let args = ProcessInfo.processInfo.arguments
        if ArchiveTestHost.isUnitTestHost || args.contains("-ARUITestRootPath") { return PageTurnStore(url: nil) }
        return PageTurnStore(url: ArchiveLibrary.defaultLibraryIndexURL)
    }()

    private struct Key: Hashable {
        let path: LibraryIndexPath
        let page: Int
    }

    private var rows: [Key: Turn] = [:]
    private let database: PageTurnDatabase?

    /// `url` nil keeps the turns in memory only.
    init(url: URL?) {
        database = url.map(PageTurnDatabase.init(url:))
        for turn in database?.loadAll() ?? [] {
            rows[Key(path: LibraryIndexPath(turn.path), page: turn.page)] = turn
        }
    }

    /// Quarter turns clockwise for this page, 0…3: 0 when it was never turned, or when the file has changed since.
    func turns(path: String, page: Int) -> Int {
        guard let turn = rows[Key(path: LibraryIndexPath(path), page: page)],
              let stamp = Self.stamp(path), stamp == (turn.size, turn.modifiedSeconds, turn.modifiedNanoseconds)
        else { return 0 }
        return turn.turns
    }

    /// Remember `turns` (any integer; taken modulo 4) for the page. Upright deletes the row. A file that cannot be
    /// read for its size and date is not remembered, since the turn could never be matched to it again.
    func set(_ turns: Int, path: String, page: Int) {
        let key = Key(path: LibraryIndexPath(path), page: page)
        let quarter = ((turns % 4) + 4) % 4
        guard quarter != 0, let stamp = Self.stamp(path) else {
            if rows.removeValue(forKey: key) != nil { database?.delete(path: path, page: page) }
            return
        }
        let turn = Turn(path: path, page: page, turns: quarter, size: stamp.size, modifiedSeconds: stamp.seconds,
                        modifiedNanoseconds: stamp.nanoseconds, turnedAt: Date())
        rows[key] = turn
        database?.upsert(turn)
    }

    /// Every page the reader has turned, whether or not its file has changed since, in path and page order.
    func turnedPages() -> [Turn] {
        rows.values.sorted { ($0.path, $0.page) < ($1.path, $1.page) }
    }

    /// How many pages are turned: the count of rotation-truth candidates.
    var turnedPageCount: Int { rows.count }

    /// Wait for the queued writes (tests).
    func flush() { database?.flush() }

    /// `stat(2)`, not `URLResourceValues`: a reused `URL` answers from its resource-value cache.
    private static func stamp(_ path: String) -> (size: Int64, seconds: Int, nanoseconds: Int)? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return (Int64(st.st_size), st.st_mtimespec.tv_sec, st.st_mtimespec.tv_nsec)
    }
}

/// The SQLite side of `PageTurnStore`. Its handle is used only on `queue`, which is what makes it safe to send.
private final class PageTurnDatabase: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.archivereader.app", category: "PageTurnStore")
    private let url: URL
    private let queue = DispatchQueue(label: "ArchiveReader.pageTurns", qos: .utility)
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) { self.url = url }

    deinit { if db != nil { sqlite3_close_v2(db) } }

    func loadAll() -> [PageTurnStore.Turn] {
        queue.sync {
            guard open(), let stmt = prepare("""
                SELECT path, page, turns, size, mtime_s, mtime_ns, turned_at FROM page_turn;
                """) else { return [] }
            defer { sqlite3_finalize(stmt) }
            var turns: [PageTurnStore.Turn] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let path = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }) else { continue }
                let quarter = Int(sqlite3_column_int64(stmt, 2))
                guard (1...3).contains(quarter) else { continue }
                turns.append(PageTurnStore.Turn(
                    path: path, page: Int(sqlite3_column_int64(stmt, 1)), turns: quarter,
                    size: sqlite3_column_int64(stmt, 3), modifiedSeconds: Int(sqlite3_column_int64(stmt, 4)),
                    modifiedNanoseconds: Int(sqlite3_column_int64(stmt, 5)),
                    turnedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))))
            }
            return turns
        }
    }

    func upsert(_ turn: PageTurnStore.Turn) {
        queue.async { [self] in
            guard open(), let stmt = prepare("""
                INSERT INTO page_turn (path, page, turns, size, mtime_s, mtime_ns, turned_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(path, page) DO UPDATE SET turns = excluded.turns, size = excluded.size,
                  mtime_s = excluded.mtime_s, mtime_ns = excluded.mtime_ns, turned_at = excluded.turned_at;
                """) else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, turn.path, -1, transient)
            sqlite3_bind_int64(stmt, 2, Int64(turn.page))
            sqlite3_bind_int64(stmt, 3, Int64(turn.turns))
            sqlite3_bind_int64(stmt, 4, turn.size)
            sqlite3_bind_int64(stmt, 5, Int64(turn.modifiedSeconds))
            sqlite3_bind_int64(stmt, 6, Int64(turn.modifiedNanoseconds))
            sqlite3_bind_double(stmt, 7, turn.turnedAt.timeIntervalSince1970)
            step(stmt, "remember a turn")
        }
    }

    func delete(path: String, page: Int) {
        queue.async { [self] in
            guard open(), let stmt = prepare("DELETE FROM page_turn WHERE path = ? AND page = ?;") else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, path, -1, transient)
            sqlite3_bind_int64(stmt, 2, Int64(page))
            step(stmt, "forget a turn")
        }
    }

    func flush() { queue.sync {} }

    /// A refused write (the library index holding the lock past the busy timeout) loses that one turn on disk; it
    /// is still shown this session. Logged, since nothing else would say so.
    private func step(_ stmt: OpaquePointer, _ what: String) {
        let result = sqlite3_step(stmt)
        guard result != SQLITE_DONE else { return }
        Self.log.error("could not \(what, privacy: .public): SQLite \(result)")
    }

    /// Open the database and make the table, once. The library index opens the same file on its own connection;
    /// WAL lets the two read side by side, and the busy timeout waits out one of its batch commits.
    private func open() -> Bool {
        if db != nil { return true }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close_v2(db); db = nil }
            Self.log.error("the page-turn database is unavailable")
            return false
        }
        sqlite3_busy_timeout(db, 3000)
        let schema = """
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS page_turn (
              path      TEXT COLLATE BINARY NOT NULL,
              page      INTEGER NOT NULL,
              turns     INTEGER NOT NULL,
              size      INTEGER NOT NULL,
              mtime_s   INTEGER NOT NULL,
              mtime_ns  INTEGER NOT NULL,
              turned_at REAL NOT NULL,
              PRIMARY KEY(path, page)
            );
            """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            Self.log.error("could not make the page-turn table")
            sqlite3_close_v2(db); db = nil
            return false
        }
        return true
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        return sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK ? stmt : nil
    }
}
