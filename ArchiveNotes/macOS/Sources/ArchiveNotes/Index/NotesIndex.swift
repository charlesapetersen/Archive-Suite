import Foundation
import SQLite3

/// A disposable, rebuildable full-text index over Archive Notes items, backed by the
/// **system SQLite** FTS5 engine. The filesystem + front-matter remain the source of truth;
/// deleting this DB loses nothing (it re-indexes on next launch).
///
/// Forked from Reader's `ContentIndex`, adapted for UUID-keyed items with prose-tuned
/// BM25 weights (title=10, tags=6, authors=4, body=1) per §16.5 of the overview.
///
/// An `actor` so the SQLite connection is confined to one isolation domain (safe under Swift 6);
/// indexing runs off the main actor while the UI stays responsive.
actor NotesIndex {
    enum IndexError: Error { case open(String), sql(String) }

    private var db: OpaquePointer?
    private let url: URL

    private let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) { self.url = url }

    func open() throws {
        guard db == nil else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            let message = lastMessage
            sqlite3_close(db); db = nil
            throw IndexError.open(message)
        }
        sqlite3_busy_timeout(db, 3000)
        try exec("PRAGMA journal_mode = WAL;")
        try exec("PRAGMA synchronous = NORMAL;")

        // Non-FTS items table: carries every field the list/sort UI needs without
        // reading .md files (§16.5 ItemSummary projection).
        try exec("""
            CREATE TABLE IF NOT EXISTS items(
                id TEXT PRIMARY KEY,
                mtime REAL,
                title TEXT,
                kind TEXT,
                date TEXT,
                date_precision TEXT,
                date_uncertain INTEGER,
                authors TEXT,
                sort_date INTEGER,
                quality INTEGER,
                created REAL,
                modified REAL,
                managed_tags TEXT
            );
            """)

        // FTS5 search table: prose-tuned columns. `id` is UNINDEXED (lookup key, not searchable).
        try exec("CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(title, tags, authors, body, id UNINDEXED);")

        // Organizational tables (app-owned durable data — NOT pruned by mtime).
        try exec("""
            CREATE TABLE IF NOT EXISTS folders(
                id TEXT PRIMARY KEY,
                name TEXT,
                parent_id TEXT,
                sort_order INTEGER,
                kind TEXT DEFAULT 'normal',
                query_json TEXT
            );
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS memberships(
                item_id TEXT,
                folder_id TEXT,
                added_at REAL,
                PRIMARY KEY(item_id, folder_id)
            );
            """)
        try exec("CREATE INDEX IF NOT EXISTS memberships_folder ON memberships(folder_id);")
        try exec("CREATE INDEX IF NOT EXISTS memberships_item   ON memberships(item_id);")
        try exec("""
            CREATE TABLE IF NOT EXISTS template_assignments(
                folder_id TEXT PRIMARY KEY,
                template_id TEXT
            );
            """)
    }

    func close() {
        if db != nil { sqlite3_close(db); db = nil }
    }

    // MARK: - Mtime checks (incremental indexing)

    /// All stored (uuid-string, mtime) pairs in one query — the indexer pulls this once to
    /// partition items into work (mtime differs) vs skipped.
    func existingMTimes() -> [String: Double] {
        guard let stmt = prepare("SELECT id, mtime FROM items;") else { return [:] }
        defer { sqlite3_finalize(stmt) }
        var map: [String: Double] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) {
                map[String(cString: c)] = sqlite3_column_double(stmt, 1)
            }
        }
        return map
    }

    // MARK: - Upsert

    /// Batch-insert multiple rows in one transaction. All extraction must be done BEFORE calling
    /// this — no `await`/suspension between BEGIN and COMMIT (actor-reentrancy invariant).
    func upsertBatch(_ rows: [NoteIndexRow]) throws {
        guard !rows.isEmpty else { return }
        try exec("BEGIN IMMEDIATE;")
        do {
            for row in rows { try upsertRow(row) }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// The body of a single-item upsert. Called inside an already-open transaction — fully
    /// synchronous (no await) to preserve the actor-reentrancy invariant.
    private func upsertRow(_ row: NoteIndexRow) throws {
        let idStr = row.id.uuidString
        var rowid: Int64? = nil

        if let sel = prepare("SELECT rowid FROM items WHERE id = ?;") {
            bindText(sel, 1, idStr)
            if sqlite3_step(sel) == SQLITE_ROW { rowid = sqlite3_column_int64(sel, 0) }
            sqlite3_finalize(sel)
        }

        if let rowid {
            // Update existing: delete old FTS row, update items row, insert new FTS row.
            try run("DELETE FROM fts WHERE rowid = ?;") { sqlite3_bind_int64($0, 1, rowid) }
            try run("""
                UPDATE items SET mtime=?, title=?, kind=?, date=?, date_precision=?,
                    date_uncertain=?, authors=?, sort_date=?, quality=?, created=?,
                    modified=?, managed_tags=? WHERE rowid=?;
                """) { stmt in
                self.bindItemColumns(stmt, row, startIndex: 1)
                sqlite3_bind_int64(stmt, 13, rowid)
            }
            try insertFTS(rowid: rowid, row: row)
        } else {
            // Insert new row.
            try run("""
                INSERT INTO items(id, mtime, title, kind, date, date_precision,
                    date_uncertain, authors, sort_date, quality, created, modified, managed_tags)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """) { stmt in
                self.bindText(stmt, 1, idStr)
                self.bindItemColumns(stmt, row, startIndex: 2)
            }
            let newRow = sqlite3_last_insert_rowid(db)
            try insertFTS(rowid: newRow, row: row)
        }
    }

    private func bindItemColumns(_ stmt: OpaquePointer?, _ row: NoteIndexRow, startIndex s: Int32) {
        sqlite3_bind_double(stmt, s, row.mtime)
        bindText(stmt, s + 1, row.title)
        bindText(stmt, s + 2, row.kind.rawValue)
        if let d = row.date { bindText(stmt, s + 3, d) } else { sqlite3_bind_null(stmt, s + 3) }
        if let dp = row.datePrecision { bindText(stmt, s + 4, dp.rawValue) } else { sqlite3_bind_null(stmt, s + 4) }
        sqlite3_bind_int(stmt, s + 5, row.dateUncertain ? 1 : 0)
        bindText(stmt, s + 6, row.authorsJSON)
        if let sd = row.sortDate { sqlite3_bind_int(stmt, s + 7, Int32(sd)) } else { sqlite3_bind_null(stmt, s + 7) }
        if let q = row.quality { sqlite3_bind_int(stmt, s + 8, Int32(q)) } else { sqlite3_bind_null(stmt, s + 8) }
        sqlite3_bind_double(stmt, s + 9, row.created.timeIntervalSince1970)
        sqlite3_bind_double(stmt, s + 10, row.modified.timeIntervalSince1970)
        bindText(stmt, s + 11, row.managedTags)
    }

    private func insertFTS(rowid: Int64, row: NoteIndexRow) throws {
        try run("INSERT INTO fts(rowid, title, tags, authors, body, id) VALUES(?, ?, ?, ?, ?, ?);") { stmt in
            sqlite3_bind_int64(stmt, 1, rowid)
            self.bindText(stmt, 2, row.title)
            self.bindText(stmt, 3, row.tags)
            self.bindText(stmt, 4, row.authors)
            self.bindText(stmt, 5, row.body)
            self.bindText(stmt, 6, row.id.uuidString)
        }
    }

    // MARK: - Search

    /// Full-text search -> matching item UUIDs in **bm25 relevance order** (best match first).
    /// Column weights (FTS5 column order: title, tags, authors, body): title=10, tags=6,
    /// authors=4, body=1 — prose-tuned per §16.5.
    func search(_ query: String, limit: Int? = nil) -> [UUID] {
        let match = ftsMatchExpression(query)
        guard !match.isEmpty else { return [] }
        let sql = limit == nil
            ? "SELECT id FROM fts WHERE fts MATCH ? ORDER BY bm25(fts, 10.0, 6.0, 4.0, 1.0);"
            : "SELECT id FROM fts WHERE fts MATCH ? ORDER BY bm25(fts, 10.0, 6.0, 4.0, 1.0) LIMIT ?;"
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, match)
        if let limit { sqlite3_bind_int(stmt, 2, Int32(limit)) }
        var ids: [UUID] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0), let uuid = UUID(uuidString: String(cString: c)) {
                ids.append(uuid)
            }
        }
        return ids
    }

    // MARK: - ItemSummary projection

    /// Load an ItemSummary for a specific UUID from the items table.
    func summary(for id: UUID) -> ItemSummary? {
        guard let stmt = prepare("""
            SELECT id, title, kind, date, date_precision, date_uncertain, authors,
                   sort_date, quality, created, modified, mtime, managed_tags
            FROM items WHERE id = ?;
            """) else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return readSummaryRow(stmt)
    }

    /// Load every indexed item as an `ItemSummary` (the item-list projection, §16.5). Used by the
    /// browser to render the list without touching `.md` files. Ordering is left to the UI
    /// (`NotesSort`); rows that fail to decode (corrupt UUID) are skipped rather than aborting.
    func allSummaries() -> [ItemSummary] {
        guard let stmt = prepare("""
            SELECT id, title, kind, date, date_precision, date_uncertain, authors,
                   sort_date, quality, created, modified, mtime, managed_tags
            FROM items;
            """) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [ItemSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let row = readSummaryRow(stmt) { out.append(row) }
        }
        return out
    }

    /// All indexed item IDs as a set.
    func allIndexedIDs() -> Set<UUID> {
        guard let stmt = prepare("SELECT id FROM items;") else { return [] }
        defer { sqlite3_finalize(stmt) }
        var set = Set<UUID>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0), let uuid = UUID(uuidString: String(cString: c)) {
                set.insert(uuid)
            }
        }
        return set
    }

    func indexedCount() -> Int {
        guard let stmt = prepare("SELECT count(*) FROM items;") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    // MARK: - Pruning

    /// Delete items by UUID from both the items and FTS tables. Batches of 500 rows per
    /// transaction. Fully synchronous within each transaction (no await between BEGIN/COMMIT).
    func deleteItems(_ ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        let batchSize = 500
        for start in stride(from: 0, to: ids.count, by: batchSize) {
            let end = min(start + batchSize, ids.count)
            let batch = ids[start..<end]
            try exec("BEGIN IMMEDIATE;")
            do {
                for id in batch {
                    let idStr = id.uuidString
                    if let sel = prepare("SELECT rowid FROM items WHERE id = ?;") {
                        bindText(sel, 1, idStr)
                        if sqlite3_step(sel) == SQLITE_ROW {
                            let rowid = sqlite3_column_int64(sel, 0)
                            sqlite3_finalize(sel)
                            try run("DELETE FROM fts WHERE rowid = ?;") { sqlite3_bind_int64($0, 1, rowid) }
                            try run("DELETE FROM items WHERE rowid = ?;") { sqlite3_bind_int64($0, 1, rowid) }
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

    // MARK: - Maintenance

    /// Post-pass maintenance: merge FTS segments and truncate the WAL.
    func performMaintenance(rowsIndexed: Int) {
        if rowsIndexed > 5000 {
            try? exec("INSERT INTO fts(fts) VALUES('optimize');")
        } else if rowsIndexed > 0 {
            try? exec("INSERT INTO fts(fts, rank) VALUES('merge', 500);")
        }
        try? exec("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    // MARK: - FTS match expression

    /// Build a safe FTS5 MATCH expression: `"term1" "term2"*` (implicit AND), doubling embedded
    /// quotes. Last token gets `*` prefix-wildcard if >2 chars for as-you-type matching.
    nonisolated func ftsMatchExpression(_ query: String) -> String {
        let tokens = query.split(whereSeparator: { $0.isWhitespace })
        guard !tokens.isEmpty else { return "" }
        return tokens.enumerated()
            .map { (i, tok) in
                let quoted = "\"" + tok.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                if i == tokens.count - 1 && tok.count > 2 {
                    return quoted + "*"
                }
                return quoted
            }
            .joined(separator: " ")
    }

    // MARK: - Folder CRUD (organizational tables — app-owned, NOT pruned by mtime)

    func allFolders() -> [VFolder] {
        guard let stmt = prepare("SELECT id, name, parent_id, sort_order, kind, query_json FROM folders;") else { return [] }
        defer { sqlite3_finalize(stmt) }
        var result: [VFolder] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let c0 = sqlite3_column_text(stmt, 0),
                  let uuid = UUID(uuidString: String(cString: c0)) else { continue }
            let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let parentId: UUID? = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil :
                sqlite3_column_text(stmt, 2).flatMap { UUID(uuidString: String(cString: $0)) }
            let sortOrder = Int(sqlite3_column_int(stmt, 3))
            let kindStr = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "normal"
            let kind = VFolder.Kind(rawValue: kindStr) ?? .normal
            let queryJSON: String? = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil :
                sqlite3_column_text(stmt, 5).map { String(cString: $0) }
            result.append(VFolder(id: uuid, name: name, parentId: parentId,
                                  sortOrder: sortOrder, kind: kind, queryJSON: queryJSON))
        }
        return result
    }

    func insertFolder(_ f: VFolder) throws {
        try run("""
            INSERT OR REPLACE INTO folders(id, name, parent_id, sort_order, kind, query_json)
            VALUES(?, ?, ?, ?, ?, ?);
            """) { stmt in
            self.bindText(stmt, 1, f.id.uuidString)
            self.bindText(stmt, 2, f.name)
            if let p = f.parentId { self.bindText(stmt, 3, p.uuidString) } else { sqlite3_bind_null(stmt, 3) }
            sqlite3_bind_int(stmt, 4, Int32(f.sortOrder))
            self.bindText(stmt, 5, f.kind.rawValue)
            if let q = f.queryJSON { self.bindText(stmt, 6, q) } else { sqlite3_bind_null(stmt, 6) }
        }
    }

    func updateFolder(_ f: VFolder) throws { try insertFolder(f) }

    func deleteFolder(id: UUID) throws {
        try run("DELETE FROM folders WHERE id = ?;") { self.bindText($0, 1, id.uuidString) }
    }

    // MARK: - Membership CRUD

    func allMemberships() -> [Membership] {
        guard let stmt = prepare("SELECT item_id, folder_id, added_at FROM memberships;") else { return [] }
        defer { sqlite3_finalize(stmt) }
        var result: [Membership] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let c0 = sqlite3_column_text(stmt, 0),
                  let itemId = UUID(uuidString: String(cString: c0)),
                  let c1 = sqlite3_column_text(stmt, 1),
                  let folderId = UUID(uuidString: String(cString: c1)) else { continue }
            let addedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            result.append(Membership(itemId: itemId, folderId: folderId, addedAt: addedAt))
        }
        return result
    }

    func insertMembership(_ m: Membership) throws {
        try run("INSERT OR IGNORE INTO memberships(item_id, folder_id, added_at) VALUES(?, ?, ?);") { stmt in
            self.bindText(stmt, 1, m.itemId.uuidString)
            self.bindText(stmt, 2, m.folderId.uuidString)
            sqlite3_bind_double(stmt, 3, m.addedAt.timeIntervalSince1970)
        }
    }

    func deleteMembership(item: UUID, folder: UUID) throws {
        try run("DELETE FROM memberships WHERE item_id = ? AND folder_id = ?;") { stmt in
            self.bindText(stmt, 1, item.uuidString)
            self.bindText(stmt, 2, folder.uuidString)
        }
    }

    func deleteMembershipsForFolder(_ folderId: UUID) throws {
        try run("DELETE FROM memberships WHERE folder_id = ?;") { self.bindText($0, 1, folderId.uuidString) }
    }

    func deleteMembershipsForItem(_ itemId: UUID) throws {
        try run("DELETE FROM memberships WHERE item_id = ?;") { self.bindText($0, 1, itemId.uuidString) }
    }

    // MARK: - Template assignment CRUD

    func allTemplateAssignments() -> [TemplateAssignment] {
        guard let stmt = prepare("SELECT folder_id, template_id FROM template_assignments;") else { return [] }
        defer { sqlite3_finalize(stmt) }
        var result: [TemplateAssignment] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let c0 = sqlite3_column_text(stmt, 0),
                  let folderId = UUID(uuidString: String(cString: c0)),
                  let c1 = sqlite3_column_text(stmt, 1),
                  let templateId = UUID(uuidString: String(cString: c1)) else { continue }
            result.append(TemplateAssignment(folderId: folderId, templateId: templateId))
        }
        return result
    }

    func insertTemplateAssignment(_ a: TemplateAssignment) throws {
        try run("INSERT OR REPLACE INTO template_assignments(folder_id, template_id) VALUES(?, ?);") { stmt in
            self.bindText(stmt, 1, a.folderId.uuidString)
            self.bindText(stmt, 2, a.templateId.uuidString)
        }
    }

    func deleteTemplateAssignment(folder: UUID) throws {
        try run("DELETE FROM template_assignments WHERE folder_id = ?;") { self.bindText($0, 1, folder.uuidString) }
    }

    // MARK: - Bulk organization replace (for JSON import on DB wipe)

    func replaceOrganization(folders: [VFolder], memberships: [Membership],
                             assignments: [TemplateAssignment]) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            try exec("DELETE FROM folders;")
            try exec("DELETE FROM memberships;")
            try exec("DELETE FROM template_assignments;")
            for f in folders { try insertFolder(f) }
            for m in memberships { try insertMembership(m) }
            for a in assignments { try insertTemplateAssignment(a) }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    // MARK: - SQLite helpers

    private func readSummaryRow(_ stmt: OpaquePointer?) -> ItemSummary? {
        guard let c0 = sqlite3_column_text(stmt, 0),
              let uuid = UUID(uuidString: String(cString: c0)) else { return nil }

        let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
        let kindStr = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "note"
        let kind = Item.Kind(rawValue: kindStr) ?? .note
        let date: String? = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil :
            sqlite3_column_text(stmt, 3).map { String(cString: $0) }
        let dpStr = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil :
            sqlite3_column_text(stmt, 4).map { String(cString: $0) }
        let datePrecision = dpStr.flatMap { Item.DatePrecision(rawValue: $0) }
        let dateUncertain = sqlite3_column_int(stmt, 5) != 0
        let authorsJSON = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? "[]"
        let authors = (try? JSONDecoder().decode([String].self, from: Data(authorsJSON.utf8))) ?? []
        let sortDate: Int? = sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil :
            Int(sqlite3_column_int(stmt, 7))
        let quality: Int? = sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil :
            Int(sqlite3_column_int(stmt, 8))
        let created = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))
        let modified = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10))
        let mtime = sqlite3_column_double(stmt, 11)
        let tagsJSON = sqlite3_column_text(stmt, 12).map { String(cString: $0) } ?? "[]"
        let managedTags = (try? JSONDecoder().decode([String].self, from: Data(tagsJSON.utf8))) ?? []

        return ItemSummary(id: uuid, title: title, kind: kind, date: date,
                           datePrecision: datePrecision, dateUncertain: dateUncertain,
                           authors: authors, sortDate: sortDate, quality: quality,
                           created: created, modified: modified, mtime: mtime,
                           managedTags: managedTags)
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

    private var lastMessage: String {
        db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown SQLite error"
    }
}
