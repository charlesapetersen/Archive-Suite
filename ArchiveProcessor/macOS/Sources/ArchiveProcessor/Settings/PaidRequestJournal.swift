import Foundation
import SQLite3

/// Stores individual requests separately from general settings. Each admission commits before
/// transport. A write transaction covers both the monthly balance check and the reservation.
@MainActor
final class PaidRequestJournal {
    private let database: OpaquePointer
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL?) throws {
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var database: OpaquePointer?
        let status = sqlite3_open_v2(url?.path ?? ":memory:", &database,
                                     SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw OCRError.networkError("The paid request journal could not be opened.")
        }
        self.database = database
        sqlite3_busy_timeout(database, 1500)
        try execute("PRAGMA synchronous = FULL")
        try execute("""
            CREATE TABLE IF NOT EXISTS paid_requests (
                id TEXT PRIMARY KEY, date REAL NOT NULL, usd REAL NOT NULL, provider TEXT NOT NULL,
                job_id TEXT, basis TEXT NOT NULL, entry BLOB NOT NULL
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS paid_requests_date ON paid_requests(date)")
        try execute("CREATE INDEX IF NOT EXISTS paid_requests_job ON paid_requests(provider, job_id)")
    }

    isolated deinit { sqlite3_close(database) }

    func transaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try operation()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func prune(before cutoff: Date) throws {
        try statement("DELETE FROM paid_requests WHERE date < ? AND basis != 'unresolved'") { stmt in
            try check(sqlite3_bind_double(stmt, 1, cutoff.timeIntervalSinceReferenceDate))
            try done(stmt)
        }
    }

    func entries(in month: DateInterval) throws -> [SettingsLedgerEntry] {
        try inMonth("SELECT entry FROM paid_requests WHERE date >= ? AND date < ? AND basis != 'declined'", month) {
            var entries: [SettingsLedgerEntry] = []
            while try row($0) { entries.append(try decode($0)) }
            return entries
        }
    }

    func amount(in month: DateInterval) throws -> Double {
        try inMonth("SELECT COALESCE(SUM(usd), 0) FROM paid_requests WHERE date >= ? AND date < ?", month) {
            guard try row($0) else { return 0 }
            return sqlite3_column_double($0, 0)
        }
    }

    func entry(id: UUID) throws -> SettingsLedgerEntry? {
        try statement("SELECT entry FROM paid_requests WHERE id = ?") {
            try bind(id.uuidString, to: $0, index: 1)
            return try row($0) ? decode($0) : nil
        }
    }

    func entry(provider: LLMProvider, jobID: String) throws -> SettingsLedgerEntry? {
        try statement("SELECT entry FROM paid_requests WHERE provider = ? AND job_id = ? LIMIT 1") {
            try bind(provider.rawValue, to: $0, index: 1)
            try bind(jobID, to: $0, index: 2)
            return try row($0) ? decode($0) : nil
        }
    }

    func save(_ entry: SettingsLedgerEntry) throws {
        guard let request = entry.request else { return }
        let data = try JSONEncoder().encode(entry)
        try statement("""
            INSERT INTO paid_requests (id, date, usd, provider, job_id, basis, entry) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET usd = excluded.usd, job_id = excluded.job_id,
                basis = excluded.basis, entry = excluded.entry
            """) { stmt in
            try bind(request.id.uuidString, to: stmt, index: 1)
            try check(sqlite3_bind_double(stmt, 2, entry.date.timeIntervalSinceReferenceDate))
            try check(sqlite3_bind_double(stmt, 3, entry.usd))
            try bind(request.provider.rawValue, to: stmt, index: 4)
            if let jobID = request.jobID { try bind(jobID, to: stmt, index: 5) }
            try bind(request.basis.rawValue, to: stmt, index: 6)
            try data.withUnsafeBytes {
                try check(sqlite3_bind_blob(stmt, 7, $0.baseAddress, Int32($0.count), Self.transient))
            }
            try done(stmt)
        }
    }

    private func inMonth<T>(_ sql: String, _ month: DateInterval, _ operation: (OpaquePointer) throws -> T) throws -> T {
        try statement(sql) {
            try check(sqlite3_bind_double($0, 1, month.start.timeIntervalSinceReferenceDate))
            try check(sqlite3_bind_double($0, 2, month.end.timeIntervalSinceReferenceDate))
            return try operation($0)
        }
    }

    private func execute(_ sql: String) throws {
        try check(sqlite3_exec(database, sql, nil, nil, nil))
    }

    private func statement<T>(_ sql: String, _ operation: (OpaquePointer) throws -> T) throws -> T {
        var stmt: OpaquePointer?
        try check(sqlite3_prepare_v2(database, sql, -1, &stmt, nil))
        guard let stmt else { throw failure() }
        defer { sqlite3_finalize(stmt) }
        return try operation(stmt)
    }

    private func bind(_ text: String, to stmt: OpaquePointer, index: Int32) throws {
        try check(sqlite3_bind_text(stmt, index, text, -1, Self.transient))
    }

    private func decode(_ stmt: OpaquePointer) throws -> SettingsLedgerEntry {
        guard let bytes = sqlite3_column_blob(stmt, 0) else { throw failure() }
        return try JSONDecoder().decode(SettingsLedgerEntry.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0))))
    }

    private func row(_ stmt: OpaquePointer) throws -> Bool {
        let result = sqlite3_step(stmt)
        if result == SQLITE_ROW { return true }
        if result == SQLITE_DONE { return false }
        throw failure()
    }

    private func done(_ stmt: OpaquePointer) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
    }

    private func check(_ result: Int32) throws {
        guard result == SQLITE_OK else { throw failure() }
    }

    private func failure() -> OCRError {
        .networkError("The paid request journal could not be updated. " + String(cString: sqlite3_errmsg(database)))
    }
}
