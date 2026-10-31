import Foundation
import SQLite3
import ArchiveCore

/// A row of extracted content ready for batch insertion. `Sendable` so task-group children
/// can return it safely.
struct IndexRow: Sendable {
    let path: String
    let mtime: Double
    let name: String
    let classification: String?
    let body: String
    let pageCount: Int
    let hasText: Bool
    let readable: Bool
}

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

    /// Open (creating if needed) and bring the schema up to date. **All-or-nothing:** it either
    /// returns with `db` fully set up, or it throws with `db` back to nil. That nil is as load-bearing
    /// as the throw — the `guard db == nil` below is what makes this idempotent, so a handle left
    /// behind by a failed PRAGMA/schema step would turn every later `open()` into a silent no-op and
    /// poison the index for the life of the process (W23.m9).
    func open() throws {
        guard db == nil else { return }   // idempotent — callers open() before every use
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            let message = lastMessage
            discardHandle()               // SQLite may allocate a handle even on failure — free it so a retry works
            throw IndexError.open(message)
        }
        do {
            sqlite3_busy_timeout(db, 3000)
            // WAL + relaxed sync: cheaper batched writes, fewer fsyncs. Safe because the DB is a
            // disposable cache — a crash just means re-indexing. performMaintenance truncates the
            // -wal/-shm sidecars after each pass.
            try exec("PRAGMA journal_mode = WAL;")
            try exec("PRAGMA synchronous = NORMAL;")
            // Bookkeeping table (path-indexed for fast incremental checks) + FTS5 search table.
            // `page_count`/`has_text`/`readable` carry the non-standard-PDF detection (display + triage);
            // a fresh v2 DB filename (see ContentIndexer) means every row is written with these columns.
            try exec("CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, mtime REAL, page_count INTEGER, has_text INTEGER, readable INTEGER);")
            try exec("CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(body, classification, name, path UNINDEXED);")
        } catch {
            // `sqlite3_open_v2` is lazy: a corrupt or foreign file opens cleanly and fails on the
            // FIRST statement ("file is not a database"). Drop the handle so the next open() re-reads
            // the file instead of inheriting a connection every query fails on.
            discardHandle()
            throw error
        }
    }

    func close() { discardHandle() }

    /// Release the connection and clear `db`. Uses `sqlite3_close_v2`, which — unlike `sqlite3_close`
    /// — never returns BUSY: it hands the handle back even if a statement outlived a mid-setup
    /// failure, so clearing `db` can't strand a live connection still holding the file lock.
    private func discardHandle() {
        if db != nil { sqlite3_close_v2(db); db = nil }
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

    /// All stored (path, mtime) pairs in one query — the indexer pulls this once to partition
    /// files into work (mtime differs) vs skipped, instead of a serialized `needsIndex` per file.
    func existingMTimes() -> [String: Double] {
        guard let stmt = prepare("SELECT path, mtime FROM files;") else { return [:] }
        defer { sqlite3_finalize(stmt) }
        var map: [String: Double] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) {
                map[String(cString: c)] = sqlite3_column_double(stmt, 1)
            }
        }
        return map
    }

    /// Insert or replace the indexed text + format-detection flags for one file. `readable=false`
    /// records an unreadable/non-PDF file (empty body) so it can still be surfaced as needing attention.
    func upsert(path: String, mtime: Double, name: String, classification: String?, body: String,
                pageCount: Int = 0, hasText: Bool = true, readable: Bool = true) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            try upsertRow(path: path, mtime: mtime, name: name, classification: classification,
                          body: body, pageCount: pageCount, hasText: hasText, readable: readable)
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Batch-insert multiple rows in one transaction. All extraction must be done BEFORE calling
    /// this — no `await`/suspension between BEGIN and COMMIT (actor-reentrancy invariant: the
    /// synchronous exec/prepare/run/insertFTS calls must not be interleaved by another actor call).
    func upsertBatch(_ rows: [IndexRow]) throws {
        guard !rows.isEmpty else { return }
        try exec("BEGIN IMMEDIATE;")
        do {
            for row in rows {
                try upsertRow(path: row.path, mtime: row.mtime, name: row.name,
                              classification: row.classification, body: row.body,
                              pageCount: row.pageCount, hasText: row.hasText, readable: row.readable)
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// The body of a single-file upsert. Called inside an already-open transaction — no
    /// BEGIN/COMMIT here. Fully synchronous (no await) to preserve the actor-reentrancy invariant.
    private func upsertRow(path: String, mtime: Double, name: String, classification: String?,
                           body: String, pageCount: Int, hasText: Bool, readable: Bool) throws {
        var rowid: Int64? = nil
        if let sel = prepare("SELECT rowid FROM files WHERE path = ?;") {
            bindText(sel, 1, path)
            if sqlite3_step(sel) == SQLITE_ROW { rowid = sqlite3_column_int64(sel, 0) }
            sqlite3_finalize(sel)
        }
        if let rowid {
            try run("DELETE FROM fts WHERE rowid = ?;") { sqlite3_bind_int64($0, 1, rowid) }
            try run("UPDATE files SET mtime = ?, page_count = ?, has_text = ?, readable = ? WHERE rowid = ?;") {
                sqlite3_bind_double($0, 1, mtime)
                sqlite3_bind_int($0, 2, Int32(pageCount))
                sqlite3_bind_int($0, 3, hasText ? 1 : 0)
                sqlite3_bind_int($0, 4, readable ? 1 : 0)
                sqlite3_bind_int64($0, 5, rowid)
            }
            try insertFTS(rowid: rowid, body: body, classification: classification, name: name, path: path)
        } else {
            try run("INSERT INTO files(path, mtime, page_count, has_text, readable) VALUES(?, ?, ?, ?, ?);") {
                self.bindText($0, 1, path); sqlite3_bind_double($0, 2, mtime)
                sqlite3_bind_int($0, 3, Int32(pageCount))
                sqlite3_bind_int($0, 4, hasText ? 1 : 0)
                sqlite3_bind_int($0, 5, readable ? 1 : 0)
            }
            let newRow = sqlite3_last_insert_rowid(db)
            try insertFTS(rowid: newRow, body: body, classification: classification, name: name, path: path)
        }
    }

    /// Full-text search → matching file paths. Input is tokenized and quoted so arbitrary user text
    /// can never be an FTS5 syntax error; terms are AND-combined.
    ///
    /// Returns **all** matching paths by default (`limit == nil`), ordered by **bm25 relevance**
    /// (best match first). Column weights: name=10, classification=5, body=1 — so a filename or
    /// classification hit outranks a body-only hit, and the order is explainable from what the user
    /// can see. `limit` remains available for callers/tests that deliberately want a bounded result.
    func search(_ query: String, limit: Int? = nil) -> [String] {
        rankedHits(query, limit: limit).map { $0.path }
    }

    /// `search`'s hits with their FTS rowids, which `snippetMap` seeks by.
    private func rankedHits(_ query: String, limit: Int? = nil) -> [(rowid: Int64, path: String)] {
        let match = ftsMatchExpression(query)
        guard !match.isEmpty else { return [] }
        // bm25 weights in FTS5 column order (body, classification, name): name hits rank
        // highest (10), then classification (5), then body (1). bm25 returns negative scores
        // (more negative = more relevant); ORDER BY ascending puts the best matches first.
        let sql = limit == nil
            ? "SELECT rowid, path FROM fts WHERE fts MATCH ? ORDER BY bm25(fts, 1.0, 5.0, 10.0);"
            : "SELECT rowid, path FROM fts WHERE fts MATCH ? ORDER BY bm25(fts, 1.0, 5.0, 10.0) LIMIT ?;"
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, match)
        if let limit { sqlite3_bind_int(stmt, 2, Int32(limit)) }
        var hits: [(rowid: Int64, path: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 1) {
                hits.append((sqlite3_column_int64(stmt, 0), String(cString: c)))
            }
        }
        return hits
    }

    /// A ranked full-text result: **every** matching path (bm25 order, best first) plus keyword-in-context
    /// `snippet()` previews for the top-ranked matches. `Sendable` so it crosses the actor boundary.
    struct RankedSearch: Sendable {
        /// All matching paths, best match first — the caller intersects this with tag facets and uses
        /// the order for `.relevance` sorting, so it must NOT be truncated (a bound here would drop hits).
        let paths: [String]
        /// Marked KWIC snippet (see `SearchSnippet`) per path, for the top `snippetLimit` matches only.
        /// Absent for deeper matches (rows past the limit simply show no preview — a graceful degrade).
        let snippets: [String: String]
    }

    /// Full-text search returning both the complete ranked path list (as `search`) and bounded
    /// keyword-in-context snippets. Snippet extraction reads each matched document's body, so it is
    /// deliberately capped at the top `snippetLimit` hits: a broad query at 150k scale computes a
    /// fragment for a few hundred rows, not for every match, and stops at `snippetBudget` seconds of
    /// snippet work, so one query cannot hold the actor for long (W40.fix-reader-fts-snippet-stall).
    func searchRanked(_ query: String, snippetLimit: Int = 300,
                      snippetBudget: TimeInterval = SearchSnippet.timeBudget) -> RankedSearch {
        let hits = rankedHits(query)
        guard !hits.isEmpty else { return RankedSearch(paths: [], snippets: [:]) }
        let top = Array(hits.prefix(max(0, snippetLimit)))
        return RankedSearch(paths: hits.map { $0.path },
                            snippets: snippetMap(query: query, hits: top, budget: snippetBudget))
    }

    /// KWIC `snippet()` of the **body** column (index 0) for each of `hits`, keyed by path. One prepared
    /// statement, MATCH plus `rowid = ?`, which FTS5 answers by seeking the doclists to that row, so
    /// `snippet()` (which reads the stored body) runs only for these rows. Best match first, checking the
    /// clock before each row: rows left when `budget` runs out get no snippet. The expression is
    /// `snippetMatchExpression`, which every hit satisfies. Empty snippets (e.g. an image-only doc with no
    /// body text) are dropped. Terms are wrapped in `SearchSnippet` marks for the UI to emphasise.
    private func snippetMap(query: String, hits: [(rowid: Int64, path: String)],
                            budget: TimeInterval) -> [String: String] {
        let match = snippetMatchExpression(query)
        guard !match.isEmpty, !hits.isEmpty else { return [:] }
        let sql = "SELECT snippet(fts, 0, ?, ?, ?, ?) FROM fts WHERE fts MATCH ? AND rowid = ?;"
        guard let stmt = prepare(sql) else { return [:] }
        defer { sqlite3_finalize(stmt) }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, budget) * 1e9)
        var out: [String: String] = [:]
        for hit in hits {
            guard DispatchTime.now().uptimeNanoseconds < deadline else { break }
            sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
            // Placeholder order: 1–4 = snippet marks/ellipsis/tokens, 5 = MATCH expr, 6 = the rowid.
            bindText(stmt, 1, SearchSnippet.openMark)
            bindText(stmt, 2, SearchSnippet.closeMark)
            bindText(stmt, 3, SearchSnippet.ellipsis)
            sqlite3_bind_int(stmt, 4, Int32(SearchSnippet.tokenCount))
            bindText(stmt, 5, match)
            sqlite3_bind_int64(stmt, 6, hit.rowid)
            guard sqlite3_step(stmt) == SQLITE_ROW else { continue }
            let snip = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            if !snip.isEmpty { out[hit.path] = snip }
        }
        return out
    }

    func classifications(for paths: [String]) -> [String: String] {
        guard !paths.isEmpty,
              let stmt = prepare("SELECT classification FROM fts WHERE rowid = "
                                 + "(SELECT rowid FROM files WHERE path = ?) LIMIT 1;") else { return [:] }
        defer { sqlite3_finalize(stmt) }
        var out: [String: String] = [:]
        for path in paths {
            sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
            bindText(stmt, 1, path)
            if sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) {
                let value = String(cString: c)
                if !value.isEmpty { out[path] = value }
            }
        }
        return out
    }

    /// Per-path non-standard-PDF status (readable / has-text → `PDFFormatStatus`), for the paths that
    /// are indexed. Unindexed paths are simply absent from the map. One prepared statement, reset per
    /// path, so it scales to the whole corpus.
    func formatFlags(for paths: [String]) -> [String: PDFFormatStatus] {
        guard !paths.isEmpty, let stmt = prepare("SELECT readable, has_text FROM files WHERE path = ?;") else { return [:] }
        defer { sqlite3_finalize(stmt) }
        var out: [String: PDFFormatStatus] = [:]
        for p in paths {
            sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
            bindText(stmt, 1, p)
            if sqlite3_step(stmt) == SQLITE_ROW {
                let readable = sqlite3_column_int(stmt, 0) != 0
                let hasText  = sqlite3_column_int(stmt, 1) != 0
                out[p] = PDFFormatStatus.classify(readable: readable, hasText: hasText)
            }
        }
        return out
    }

    /// Count of indexed files that need attention: unreadable OR opened-but-no-text. Corpus-wide over
    /// the entire (never-pruned, root-shared) index — see `needsAttentionCount(among:)` for the
    /// current-library-scoped count the UI badge uses.
    func needsAttentionCount() -> Int {
        guard let stmt = prepare("SELECT count(*) FROM files WHERE readable = 0 OR has_text = 0;") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    /// Count of files needing attention (unreadable OR opened-but-no-text) **among `paths`** — the
    /// current library's path set. The index is shared across roots and never pruned, so a corpus-wide
    /// count over-reports after a root switch (rows for other roots / removed files); scoping to the
    /// live path set keeps the badge in step with the path-scoped `needsAttentionOnly` filter it drives.
    /// One prepared statement, reset per path (like `formatFlags`), so it scales to the whole corpus.
    func needsAttentionCount(among paths: [String]) -> Int {
        guard !paths.isEmpty, let stmt = prepare("SELECT readable, has_text FROM files WHERE path = ?;") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        var count = 0
        for p in paths {
            sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
            bindText(stmt, 1, p)
            if sqlite3_step(stmt) == SQLITE_ROW {
                let readable = sqlite3_column_int(stmt, 0) != 0
                let hasText  = sqlite3_column_int(stmt, 1) != 0
                if !readable || !hasText { count += 1 }
            }
        }
        return count
    }

    func indexedCount() -> Int {
        guard let stmt = prepare("SELECT count(*) FROM files;") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    /// All stored paths as a set — one query, used by the pruner to diff against the live library.
    func allPaths() -> Set<String> {
        guard let stmt = prepare("SELECT path FROM files;") else { return [] }
        defer { sqlite3_finalize(stmt) }
        var set = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { set.insert(String(cString: c)) }
        }
        return set
    }

    /// Delete a batch of paths from both the bookkeeping and FTS tables. Batches of ~500 rows per
    /// transaction (mirrors `upsertBatch`'s discipline). Fully synchronous within each transaction
    /// (no await between BEGIN and COMMIT) to preserve the actor-reentrancy invariant.
    func deletePaths(_ paths: [String]) throws {
        guard !paths.isEmpty else { return }
        let batchSize = 500
        for start in stride(from: 0, to: paths.count, by: batchSize) {
            let end = min(start + batchSize, paths.count)
            let batch = paths[start..<end]
            try exec("BEGIN IMMEDIATE;")
            do {
                for path in batch {
                    // Look up the rowid so we can delete the matching FTS row (FTS5 content tables
                    // are keyed by rowid, not by a column value).
                    if let sel = prepare("SELECT rowid FROM files WHERE path = ?;") {
                        bindText(sel, 1, path)
                        if sqlite3_step(sel) == SQLITE_ROW {
                            let rowid = sqlite3_column_int64(sel, 0)
                            sqlite3_finalize(sel)
                            try run("DELETE FROM fts WHERE rowid = ?;") { sqlite3_bind_int64($0, 1, rowid) }
                            try run("DELETE FROM files WHERE rowid = ?;") { sqlite3_bind_int64($0, 1, rowid) }
                        } else {
                            sqlite3_finalize(sel)
                        }
                    }
                }
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    /// Post-pass maintenance: merge FTS segments and truncate the WAL. Actor-isolated so the
    /// sqlite3 handle is never touched off-actor. Skips on zero-row passes. Prefers incremental
    /// merge on small passes; full optimize only on bulk builds (rewrites the entire index —
    /// multi-second on 150k, blocks search for its duration, so it must not fire each pass).
    func performMaintenance(rowsIndexed: Int) {
        if rowsIndexed > 5000 {
            try? exec("INSERT INTO fts(fts) VALUES('optimize');")
        } else if rowsIndexed > 0 {
            try? exec("INSERT INTO fts(fts, rank) VALUES('merge', 500);")
        }
        // Checkpoint: reclaim WAL space. TRUNCATE shrinks the -wal file; single-connection
        // design means no concurrent reader can leave it partial. Busy result is non-fatal.
        // Always runs (even after prune-only deletes with rowsIndexed == 0).
        try? exec("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    /// Build a safe FTS5 MATCH expression: `"term1" "term2"*` (implicit AND), doubling embedded
    /// quotes. The LAST token gets a `*` prefix-wildcard so partial words match while typing
    /// (e.g. "news" → matches "newspaper"). Short tokens (≤2 chars) skip the wildcard because
    /// prefix expansion on 1–2-char terms is too broad (performance + relevance).
    nonisolated func ftsMatchExpression(_ query: String) -> String {
        matchTerms(query).map { $0.term }.joined(separator: " ")
    }

    /// The expression `snippet()` is given: `ftsMatchExpression` without its `SearchSnippet.stopWords`
    /// terms, or all of it when every term is one. Dropping AND-ed terms only widens the match, so every
    /// hit of the full expression still matches this one; the dropped words are just not highlighted.
    nonisolated func snippetMatchExpression(_ query: String) -> String {
        let terms = matchTerms(query)
        let kept = terms.filter { !SearchSnippet.stopWords.contains($0.token.lowercased().trimmingCharacters(in: .punctuationCharacters)) }
        return (kept.isEmpty ? terms : kept).map { $0.term }.joined(separator: " ")
    }

    /// Each whitespace-separated query token with its quoted (and, for the last, wildcarded) FTS5 term.
    private nonisolated func matchTerms(_ query: String) -> [(token: Substring, term: String)] {
        let tokens = query.split(whereSeparator: { $0.isWhitespace })
        return tokens.enumerated().map { (i, tok) in
            let quoted = "\"" + tok.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            return (tok, i == tokens.count - 1 && tok.count > 2 ? quoted + "*" : quoted)
        }
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
