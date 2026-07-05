import Foundation
import SQLite3

/// A disposable, rebuildable full-text index over the OCR body text of the corpus, backed by the
/// **system SQLite** FTS5 engine (`import SQLite3` — no third-party dependency). The filesystem +
/// tags remain the source of truth; deleting this DB loses nothing (it re-indexes on next launch).
///
/// An `actor` so the SQLite connection is confined to one isolation domain (safe under Swift 6);
/// indexing runs off the main actor while the UI stays responsive.
actor ContentIndex {
    enum IndexError: Error { case open(String), sql(String) }

    private var db: OpaquePointer?
    private let url: URL

    // SQLite wants a destructor telling it to copy bound text; -1 == SQLITE_TRANSIENT.
    private let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) { self.url = url }

    func open() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw IndexError.open(lastMessage)
        }
        sqlite3_busy_timeout(db, 3000)
        // Bookkeeping table (path-indexed for fast incremental checks) + FTS5 search table.
        try exec("CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, mtime REAL);")
        try exec("CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(body, classification, name, path UNINDEXED);")
    }

    func close() {
        if db != nil { sqlite3_close(db); db = nil }
    }

    /// True if `path` is absent or its stored mtime differs (needs (re)indexing).
    func needsIndex(path: String, mtime: Double) -> Bool {
        guard let stmt = prepare("SELECT mtime FROM files WHERE path = ?;") else { return true }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, path)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_double(stmt, 0) != mtime
        }
        return true
    }

    /// Insert or replace the indexed text for one file.
    func upsert(path: String, mtime: Double, name: String, classification: String?, body: String) throws {
        try exec("BEGIN;")
        do {
            var rowid: Int64? = nil
            if let sel = prepare("SELECT rowid FROM files WHERE path = ?;") {
                bindText(sel, 1, path)
                if sqlite3_step(sel) == SQLITE_ROW { rowid = sqlite3_column_int64(sel, 0) }
                sqlite3_finalize(sel)
            }
            if let rowid {
                try run("DELETE FROM fts WHERE rowid = ?;") { sqlite3_bind_int64($0, 1, rowid) }
                try run("UPDATE files SET mtime = ? WHERE rowid = ?;") {
                    sqlite3_bind_double($0, 1, mtime); sqlite3_bind_int64($0, 2, rowid)
                }
                try insertFTS(rowid: rowid, body: body, classification: classification, name: name, path: path)
            } else {
                try run("INSERT INTO files(path, mtime) VALUES(?, ?);") {
                    self.bindText($0, 1, path); sqlite3_bind_double($0, 2, mtime)
                }
                let newRow = sqlite3_last_insert_rowid(db)
                try insertFTS(rowid: newRow, body: body, classification: classification, name: name, path: path)
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Full-text search → matching file paths. Input is tokenized and quoted so arbitrary user text
    /// can never be an FTS5 syntax error; terms are AND-combined.
    func search(_ query: String, limit: Int = 5000) -> [String] {
        let match = ftsMatchExpression(query)
        guard !match.isEmpty, let stmt = prepare("SELECT path FROM fts WHERE fts MATCH ? LIMIT ?;") else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, match)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var paths: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { paths.append(String(cString: c)) }
        }
        return paths
    }

    func indexedCount() -> Int {
        guard let stmt = prepare("SELECT count(*) FROM files;") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    /// Build a safe FTS5 MATCH expression: `"term1" "term2"` (implicit AND), doubling embedded quotes.
    nonisolated func ftsMatchExpression(_ query: String) -> String {
        query.split(whereSeparator: { $0.isWhitespace })
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            .joined(separator: " ")
    }

    // MARK: - SQLite helpers

    private func insertFTS(rowid: Int64, body: String, classification: String?, name: String, path: String) throws {
        try run("INSERT INTO fts(rowid, body, classification, name, path) VALUES(?, ?, ?, ?, ?);") { stmt in
            sqlite3_bind_int64(stmt, 1, rowid)
            self.bindText(stmt, 2, body)
            self.bindText(stmt, 3, classification ?? "")
            self.bindText(stmt, 4, name)
            self.bindText(stmt, 5, path)
        }
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? lastMessage
            sqlite3_free(err)
            throw IndexError.sql(m)
        }
    }

    private func run(_ sql: String, _ bind: (OpaquePointer) -> Void) throws {
        guard let stmt = prepare(sql) else { throw IndexError.sql(lastMessage) }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw IndexError.sql(lastMessage) }
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        return sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK ? stmt : nil
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, TRANSIENT)
    }

    private var lastMessage: String { db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown SQLite error" }
}
