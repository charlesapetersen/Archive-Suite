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

    /// Open (creating if needed) and bring the schema up to date. **All-or-nothing:** it either
    /// returns with `db` fully set up, or it throws with `db` back to nil. That nil is as load-bearing
    /// as the throw — the `guard db == nil` below is what makes this idempotent, so a handle left
    /// behind by a failed PRAGMA/migration/schema step would turn every later `open()` into a silent
    /// no-op and poison the DB for the life of the process (W23.m9). It costs more here than in
    /// Reader: this file also holds the app-owned `folders`/`memberships` tables, not only the
    /// disposable FTS cache.
    func open() throws {
        guard db == nil else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            let message = lastMessage
            discardHandle()
            throw IndexError.open(message)
        }
        do {
            try openSchema()
        } catch {
            // `sqlite3_open_v2` is lazy: a corrupt or foreign file opens cleanly and fails on the
            // FIRST statement ("file is not a database"). Drop the handle so the next open() re-reads
            // the file instead of inheriting a connection every query fails on.
            discardHandle()
            throw error
        }
    }

    /// The PRAGMA + schema half of `open()`, split out so one `catch` covers every step of it.
    private func openSchema() throws {
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
                managed_tags TEXT,
                source_count INTEGER DEFAULT 0
            );
            """)

        // Additive migration (W7-S4): a DB created before `source_count` existed keeps its rows, so
        // `CREATE TABLE IF NOT EXISTS` above is a no-op for it. The items table is a rebuildable cache,
        // so an `ADD COLUMN` (default 0) is safe + non-destructive; stale rows read 0 until their next
        // mtime-triggered re-index refreshes the count. Guarded so a fresh DB (column already present)
        // doesn't hit a duplicate-column error.
        if !itemsHasColumn("source_count") {
            try exec("ALTER TABLE items ADD COLUMN source_count INTEGER DEFAULT 0;")
        }

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
        // `folder_id` is a FOREIGN KEY (W23.m15): without it the table happily stored a membership to
        // any UUID, so every note filed after a folder was deleted added a row nothing could render,
        // empty, or restore. NO ACTION rather than ON DELETE CASCADE, deliberately — a cascade would
        // make any accidental delete of a folder row silently destroy its contents, whereas NO ACTION
        // turns the same mistake into a loud constraint failure. `deleteFolderGraph` already deletes a
        // folder's memberships before the folder itself, which is exactly what NO ACTION requires.
        try exec("""
            CREATE TABLE IF NOT EXISTS memberships(
                item_id TEXT,
                folder_id TEXT,
                added_at REAL,
                PRIMARY KEY(item_id, folder_id),
                FOREIGN KEY(folder_id) REFERENCES folders(id)
            );
            """)
        try migrateMembershipsToForeignKey()
        try exec("CREATE INDEX IF NOT EXISTS memberships_folder ON memberships(folder_id);")
        try exec("CREATE INDEX IF NOT EXISTS memberships_item   ON memberships(item_id);")
        try exec("""
            CREATE TABLE IF NOT EXISTS template_assignments(
                folder_id TEXT PRIMARY KEY,
                template_id TEXT
            );
            """)

        // Enforcement is per-connection and OFF by default, which is why every statement above — the
        // membership rebuild included — ran unconstrained. Last, so the migration could copy a legacy
        // table's pre-existing ghost rows through instead of failing on them: SQLite checks foreign
        // keys as rows are WRITTEN, so those survive here and are revived when `OrganizationStore.load`
        // restores the system folder they name. Only NEW violations are refused from now on.
        //
        // `template_assignments.folder_id` is deliberately left unconstrained: a stale assignment is
        // inert (the resolver simply finds nothing) and `clearDanglingAssignments` already tidies it,
        // so a second table rebuild would buy nothing and risk durable data.
        try exec("PRAGMA foreign_keys = ON;")
    }

    /// Give a pre-W23.m15 `memberships` table its `folder_id` foreign key — the standard SQLite
    /// rebuild, since a constraint cannot be added in place. A no-op once the FK is present, so it
    /// costs one `PRAGMA` per launch thereafter.
    ///
    /// Runs BEFORE `PRAGMA foreign_keys = ON`, which is what lets the copy carry a legacy DB's ghost
    /// memberships across. Dropping them here instead would delete durable organization data to
    /// satisfy a constraint added after the fact — and those rows are precisely what comes back to
    /// life when the system folder they name is restored.
    private func migrateMembershipsToForeignKey() throws {
        guard !membershipsHaveForeignKey() else { return }
        try exec("BEGIN IMMEDIATE;")
        do {
            try exec("""
                CREATE TABLE memberships_new(
                    item_id TEXT,
                    folder_id TEXT,
                    added_at REAL,
                    PRIMARY KEY(item_id, folder_id),
                    FOREIGN KEY(folder_id) REFERENCES folders(id)
                );
                """)
            try exec("""
                INSERT INTO memberships_new(item_id, folder_id, added_at)
                SELECT item_id, folder_id, added_at FROM memberships;
                """)
            try exec("DROP TABLE memberships;")
            try exec("ALTER TABLE memberships_new RENAME TO memberships;")
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
        // The old table's indexes went with it; the `CREATE INDEX IF NOT EXISTS` pair in `openSchema`
        // runs immediately after this and rebuilds them.
    }

    /// Whether `memberships` already declares a foreign key — the migration guard.
    private func membershipsHaveForeignKey() -> Bool {
        guard let stmt = prepare("PRAGMA foreign_key_list(memberships);") else { return false }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    func close() { discardHandle() }

    /// Release the connection and clear `db`. Uses `sqlite3_close_v2`, which — unlike `sqlite3_close`
    /// — never returns BUSY: it hands the handle back even if a statement outlived a mid-setup
    /// failure, so clearing `db` can't strand a live connection still holding the file lock.
    private func discardHandle() {
        if db != nil { sqlite3_close_v2(db); db = nil }
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
                    modified=?, managed_tags=?, source_count=? WHERE rowid=?;
                """) { stmt in
                self.bindItemColumns(stmt, row, startIndex: 1)
                sqlite3_bind_int64(stmt, 14, rowid)
            }
            try insertFTS(rowid: rowid, row: row)
        } else {
            // Insert new row.
            try run("""
                INSERT INTO items(id, mtime, title, kind, date, date_precision,
                    date_uncertain, authors, sort_date, quality, created, modified, managed_tags,
                    source_count)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
        sqlite3_bind_int(stmt, s + 12, Int32(row.sourceCount))
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
                   sort_date, quality, created, modified, mtime, managed_tags, source_count
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
                   sort_date, quality, created, modified, mtime, managed_tags, source_count
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

    /// Update an existing folder row in place.
    ///
    /// A real `UPDATE`, no longer an alias for `insertFolder`'s `INSERT OR REPLACE` (W23.m15).
    ///
    /// **The REPLACE was survivable, and the tests say so** — an early draft of this change claimed the
    /// opposite. REPLACE satisfies the conflict by deleting the existing row and inserting a new one,
    /// but SQLite checks an *immediate* foreign key at the END of the statement: deleting and
    /// re-inserting the same primary key nets the violation count back to zero, and NO ACTION means the
    /// child rows were never touched in between. Restoring the old alias reddens nothing about
    /// memberships. Two reasons this is still the right shape:
    ///
    /// 1. It is **non-upserting**, which is what "update" should mean here: a row that isn't there is a
    ///    no-op, not a resurrection from a stale in-memory copy. Both callers (`renameFolder`,
    ///    `moveFolder`) have already found the folder in the graph.
    /// 2. It removes the delete-and-reinsert entirely, so no rename's correctness rests on the FK
    ///    having been declared NO ACTION. Declare `ON DELETE CASCADE` here one day and a REPLACE
    ///    *would* silently empty the folder; an in-place UPDATE cannot.
    func updateFolder(_ f: VFolder) throws {
        try run("""
            UPDATE folders SET name = ?, parent_id = ?, sort_order = ?, kind = ?, query_json = ?
            WHERE id = ?;
            """) { stmt in
            self.bindText(stmt, 1, f.name)
            if let p = f.parentId { self.bindText(stmt, 2, p.uuidString) } else { sqlite3_bind_null(stmt, 2) }
            sqlite3_bind_int(stmt, 3, Int32(f.sortOrder))
            self.bindText(stmt, 4, f.kind.rawValue)
            if let q = f.queryJSON { self.bindText(stmt, 5, q) } else { sqlite3_bind_null(stmt, 5) }
            self.bindText(stmt, 6, f.id.uuidString)
        }
    }

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

    // MARK: - Multi-row organization transactions (W23.m13)

    // Each of these is ONE method rather than BEGIN/COMMIT exposed to the caller, for the same reason
    // `upsertBatch` is: this actor's transaction invariant is "no suspension between BEGIN and COMMIT".
    // A caller awaiting each leg across the actor boundary could let another mutation interleave inside
    // the open transaction — and `OrganizationStore` is `@MainActor`, which is reentrant at every await.

    /// Delete a folder and everything that referenced it as ONE unit: the reparented children, the
    /// folder's memberships, its template assignment, and the folder row. Either all of it lands or
    /// none of it does.
    ///
    /// Before W23.m13 these were four independent writes. The nastiest ordering was real and silent: the
    /// memberships delete commits, the folder delete then fails, and the caller's in-memory cleanup is
    /// skipped by the throw — so memory (and `organization.json`, whose export never runs) still list
    /// the memberships while the DB has none. `load()` prefers the DB whenever it holds folders, so the
    /// next launch adopts the lossy half as the durable truth and the items are orphaned with no §3.6
    /// confirmation ever shown.
    func deleteFolderGraph(id: UUID, reparentedChildren: [VFolder]) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            // `updateFolder`, not `insertFolder`: these rows already exist, so this is an update, and
            // it should not silently re-create a child that another window deleted (W23.m15).
            for child in reparentedChildren { try updateFolder(child) }
            try deleteMembershipsForFolder(id)
            try deleteTemplateAssignment(folder: id)
            try deleteFolder(id: id)
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Move one item's membership from `source` to `target` as ONE unit — the durable half of a MOVE.
    ///
    /// The insert precedes the delete inside the transaction, so the item is never transiently
    /// member-less and a move can still never trip the §3.6 delete-last-instance guard. Because it is a
    /// transaction, a failed source-removal no longer leaves the item **replicated in both folders**
    /// while the UI reports a move (W23.m13): the target add rolls back with it.
    func moveMembership(item: UUID, from source: UUID, to target: UUID, addedAt: Date) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            try insertMembership(Membership(itemId: item, folderId: target, addedAt: addedAt))
            try deleteMembership(item: item, folder: source)
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Clear several folders' template assignments as ONE unit, so a failure part-way through cannot
    /// leave some folders pointing at a template and others not (W23.m13).
    func deleteTemplateAssignments(folders: [UUID]) throws {
        guard !folders.isEmpty else { return }
        try exec("BEGIN IMMEDIATE;")
        do {
            for f in folders { try deleteTemplateAssignment(folder: f) }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    #if DEBUG
    /// Test-only fault-injection seam: run one raw statement on this index's connection.
    /// `OrganizationAtomicityTests` (W23.m13) uses it to install a `RAISE(ABORT)` trigger that breaks
    /// exactly ONE leg of a transaction, which is the only way to prove the other legs roll back.
    /// Not compiled into Release.
    func executeForTesting(_ sql: String) throws { try exec(sql) }

    /// Test-only: the index names attached to `table`. `SystemFolderIntegrityTests` (W23.m15) uses it
    /// to prove the FK migration's `DROP TABLE` didn't leave the memberships indexes behind — a loss
    /// nothing else would report, since a missing index is a silent full scan, not an error.
    func indexNamesForTesting(_ table: String) -> Set<String> {
        guard let stmt = prepare("PRAGMA index_list(\(table));") else { return [] }
        defer { sqlite3_finalize(stmt) }
        var names = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 1) { names.insert(String(cString: c)) }
        }
        return names
    }
    #endif

    // MARK: - Bulk organization replace (for JSON import on DB wipe)

    func replaceOrganization(folders: [VFolder], memberships: [Membership],
                             assignments: [TemplateAssignment]) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            // Children before parents, then parents before children on the way back in — the FK's
            // ordering, not a style choice: clearing `folders` while a membership still referenced a
            // row would be refused outright (W23.m15).
            try exec("DELETE FROM memberships;")
            try exec("DELETE FROM template_assignments;")
            try exec("DELETE FROM folders;")
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
        let sourceCount = Int(sqlite3_column_int(stmt, 13))

        return ItemSummary(id: uuid, title: title, kind: kind, date: date,
                           datePrecision: datePrecision, dateUncertain: dateUncertain,
                           authors: authors, sortDate: sortDate, quality: quality,
                           created: created, modified: modified, mtime: mtime,
                           managedTags: managedTags, sourceNoteCount: sourceCount)
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

    /// Whether the `items` table already has `column` — the additive-migration guard (W7-S4). Uses
    /// `PRAGMA table_info` so a fresh DB (new column baked into `CREATE TABLE`) skips the `ALTER`.
    private func itemsHasColumn(_ column: String) -> Bool {
        guard let stmt = prepare("PRAGMA table_info(items);") else { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 1), String(cString: c) == column { return true }
        }
        return false
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, TRANSIENT)
    }

    private var lastMessage: String {
        db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown SQLite error"
    }
}
