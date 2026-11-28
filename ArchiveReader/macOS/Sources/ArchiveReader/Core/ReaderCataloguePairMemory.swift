import ArchiveCore
import ArchiveCoreUI
import Foundation
import SQLite3
import os

/// Reader's local evidence of previously verified pairs. Discovery still reads the filesystem;
/// the cache only helps offer a repair when the live companion cannot be found at its expected name.
actor ReaderCataloguePairMemory {
    static let shared = ReaderCataloguePairMemory(url: defaultURL)

    private static let log = Logger(subsystem: "com.archivereader.app", category: "CataloguePairMemory")
    private static var defaultURL: URL? {
        guard !ArchiveTestHost.isUnitTestHost else { return nil }
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-ARUITestRootPath") {
            // The relaunch journey constructs its own uniquely named root under the generated fixture.
            // Other fixture launches leave the owner's memory untouched.
            guard args.contains("-ARUITestRememberCataloguePairs"), args.indices.contains(index + 1) else { return nil }
            let root = URL(fileURLWithPath: args[index + 1], isDirectory: true)
            let fixture = root.deletingLastPathComponent()
            let marker = Data((#"{"guid":"a4f1c2d8-0e3b-4a71-9c55-6d8e1f2a3b40","name":"AR-GUI-Fixture","kind":"reader","createdAt":"2026-07-30T00:00:00Z"}"# + "\n").utf8)
            let values = try? fixture.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard root.lastPathComponent.hasPrefix("AR-CatalogueRepair-"),
                  UUID(uuidString: String(root.lastPathComponent.dropFirst("AR-CatalogueRepair-".count))) != nil,
                  fixture.lastPathComponent == "AR-GUI-Fixture",
                  values?.isDirectory == true, values?.isSymbolicLink == false,
                  (try? Data(contentsOf: fixture.appendingPathComponent(".archive-suite-root.json"))) == marker else {
                return nil
            }
            return fixture.appendingPathComponent(root.lastPathComponent + ".catalogue-pairs.sqlite3", isDirectory: false)
        }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ArchiveReader", isDirectory: true)
            .appendingPathComponent("catalogue-pairs-v1.sqlite3")
    }

    private let url: URL?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL?) { self.url = url }

    func remember(snapshot: CatalogueReader.Snapshot) {
        guard url != nil else { return }
        remember(snapshot.rememberablePairs, instance: snapshot.rootInstanceID)
    }

    func remember(_ pairs: [CatalogueReader.RememberedPair], instance: UUID) {
        guard !pairs.isEmpty, let db = open(create: true) else { return }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
            Self.log.error("Could not begin saving catalogue pair memory.")
            return
        }
        var committed = false
        defer { if !committed { sqlite3_exec(db, "ROLLBACK;", nil, nil, nil) } }
        let sql = """
            INSERT INTO instance_pairs (root_instance, physical_key, file_id, proof) VALUES (?, ?, ?, ?)
            ON CONFLICT(root_instance, physical_key) DO UPDATE SET file_id = excluded.file_id, proof = excluded.proof
            WHERE proof <> excluded.proof;
            """
        guard let statement = prepare(sql, in: db) else { return }
        defer { sqlite3_finalize(statement) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for pair in pairs {
            guard let data = try? encoder.encode(pair) else { return }
            sqlite3_bind_text(statement, 1, instance.uuidString, -1, transient)
            sqlite3_bind_text(statement, 2, pair.physicalKey, -1, transient)
            sqlite3_bind_text(statement, 3, pair.fileID.uuidString, -1, transient)
            let binding = data.withUnsafeBytes {
                sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32($0.count), transient)
            }
            guard binding == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
                Self.log.error("Could not save catalogue pair memory.")
                return
            }
            sqlite3_reset(statement)
        }
        committed = sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK
        if !committed { Self.log.error("Could not commit catalogue pair memory.") }
    }

    func candidate(reader: CatalogueReader, root: URL, relativePath: String) -> CatalogueReader.ReassociationCandidate? {
        guard let db = open(create: false) else { return nil }
        defer { sqlite3_close(db) }
        return try? reader.reassociationCandidate(at: relativePath) { fileID in
            let sql = """
            SELECT proof FROM instance_pairs WHERE root_instance = ? AND file_id = ?
            UNION ALL
            SELECT proof FROM pairs AS legacy WHERE root_path = ? AND file_id = ?
                AND NOT EXISTS (
                    SELECT 1 FROM instance_pairs AS current
                    WHERE current.root_instance = ? AND current.physical_key = legacy.physical_key
                );
            """
            guard let statement = prepare(sql, in: db) else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, reader.rootInstanceID.uuidString, -1, transient)
            sqlite3_bind_text(statement, 2, fileID.uuidString, -1, transient)
            sqlite3_bind_text(statement, 3, root.path, -1, transient)
            sqlite3_bind_text(statement, 4, fileID.uuidString, -1, transient)
            sqlite3_bind_text(statement, 5, reader.rootInstanceID.uuidString, -1, transient)
            let decoder = JSONDecoder()
            var results: [CatalogueReader.RememberedPair] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    let count = Int(sqlite3_column_bytes(statement, 0))
                    guard count > 0, let bytes = sqlite3_column_blob(statement, 0),
                          let proof = try? decoder.decode(CatalogueReader.RememberedPair.self,
                                                          from: Data(bytes: bytes, count: count)) else { return [] }
                    results.append(proof)
                case SQLITE_DONE:
                    return results
                default:
                    return []
                }
            }
        }
    }

    private func open(create: Bool) -> OpaquePointer? {
        guard let url else { return nil }
        if create {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
            } catch {
                Self.log.error("Could not open the catalogue pair memory folder.")
                return nil
            }
        } else if !FileManager.default.fileExists(atPath: url.path) {
            return nil
        }
        var db: OpaquePointer?
        let access = SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0)
        let flags = access | SQLITE_OPEN_NOFOLLOW
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            Self.log.error("Could not open catalogue pair memory.")
            return nil
        }
        sqlite3_busy_timeout(db, 1000)
        let schema = """
            CREATE TABLE IF NOT EXISTS pairs (
                root_path TEXT NOT NULL,
                physical_key TEXT NOT NULL,
                file_id TEXT NOT NULL,
                proof BLOB NOT NULL,
                PRIMARY KEY (root_path, physical_key)
            );
            CREATE INDEX IF NOT EXISTS pairs_by_file ON pairs (root_path, file_id);
            CREATE TABLE IF NOT EXISTS instance_pairs (
                root_instance TEXT NOT NULL,
                physical_key TEXT NOT NULL,
                file_id TEXT NOT NULL,
                proof BLOB NOT NULL,
                PRIMARY KEY (root_instance, physical_key)
            );
            CREATE INDEX IF NOT EXISTS instance_pairs_by_file ON instance_pairs (root_instance, file_id);
            """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(db)
            Self.log.error("Could not initialize catalogue pair memory.")
            return nil
        }
        return db
    }

    private func prepare(_ sql: String, in db: OpaquePointer) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            Self.log.error("Could not query catalogue pair memory.")
            return nil
        }
        return statement
    }
}
