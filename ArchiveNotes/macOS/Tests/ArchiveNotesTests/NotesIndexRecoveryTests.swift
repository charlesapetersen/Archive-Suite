import Testing
import Foundation
@testable import ArchiveNotes

/// W23.m9 — `NotesIndex.open()` must be all-or-nothing.
///
/// `sqlite3_open_v2` is lazy: it hands back a live handle for a file it has not read yet, so a
/// corrupt/foreign DB file opens *successfully* and then fails on the first PRAGMA with "file is not
/// a database". Before this fix `open()` threw with `db` still non-nil, and since `open()`
/// short-circuits on `db != nil`, every later `open()` returned "success" without completing setup —
/// poisoning the DB until the process restarted (and, since the bad file is still there next launch,
/// on every launch after). In Notes that reaches further than in Reader: this same file holds the
/// app-owned `folders`/`memberships` tables, not just the disposable FTS cache.
///
/// All scratch: a `sqlite3` file under a per-test temp directory. No corpus, no app, no network.
@Suite struct NotesIndexRecoveryTests {

    private func scratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesIndexRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 1 KiB of non-header bytes — enough that SQLite's header check fails outright (an *empty* file
    /// is a valid empty database, so it would not reproduce anything).
    private func writeGarbage(to url: URL) throws {
        try Data(repeating: 0x5A, count: 1024).write(to: url)
    }

    private func makeRow(id: UUID, title: String, body: String) -> NoteIndexRow {
        NoteIndexRow(id: id, mtime: 1, title: title, kind: .note, tags: "", authors: "",
                     authorsJSON: "[]", body: body, date: nil, datePrecision: nil,
                     dateUncertain: false, sortDate: nil, quality: nil, created: Date(),
                     modified: Date(), managedTags: "[]", sourceCount: 0)
    }

    /// A setup failure must throw AND leave nothing behind, so the retry after the bad file is
    /// replaced actually opens. Pre-fix the second `open()` returned immediately (handle non-nil) and
    /// the batch write below then failed with "file is not a database" — RED on the search.
    @Test func setupFailureLeavesNoHalfOpenHandle() async throws {
        let dir = try scratchDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("notes-index.sqlite3")
        try writeGarbage(to: url)
        let index = NotesIndex(url: url)

        await #expect(throws: (any Error).self) { try await index.open() }

        // The FTS half is a disposable cache, so recovery is "replace the file and reopen".
        // Truncating to empty is a valid empty DB and needs no delete API.
        try Data().write(to: url)
        try await index.open()                  // pre-fix: a no-op that "succeeds" on the dead handle
        let id = UUID()
        try await index.upsertBatch([makeRow(id: id, title: "Chafee", body: "budget memorandum")])
        let hits = await index.search("memorandum")
        #expect(hits == [id], "a reopened index must be writable and searchable")
        await index.close()
    }

    /// The organizational tables are app-owned durable data living in the same file — after a failed
    /// open they must be reachable again once the file is replaced, not stuck behind a dead handle.
    @Test func organizationTablesSurviveTheRecoveredOpen() async throws {
        let dir = try scratchDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("notes-index.sqlite3")
        try writeGarbage(to: url)
        let index = NotesIndex(url: url)

        await #expect(throws: (any Error).self) { try await index.open() }

        try Data().write(to: url)
        try await index.open()
        // A folder + membership write proves the organizational schema steps actually ran on the
        // retry (pre-fix they were never created, so this threw).
        let folder = VFolder(id: UUID(), name: "Box 12", parentId: nil, sortOrder: 0,
                             kind: .normal, queryJSON: nil)
        let itemId = UUID()
        try await index.insertFolder(folder)
        try await index.insertMembership(Membership(itemId: itemId, folderId: folder.id, addedAt: Date()))
        let loadedFolders = await index.allFolders()
        let loadedMemberships = await index.allMemberships()
        #expect(loadedFolders.map(\.id) == [folder.id])
        #expect(loadedMemberships.map(\.itemId) == [itemId])
        await index.close()
    }

    /// Repeated failures must not consume the recovery: the actor stays *closed*, not open-but-broken.
    @Test func repeatedFailedOpensStillRecover() async throws {
        let dir = try scratchDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("notes-index.sqlite3")
        try writeGarbage(to: url)
        let index = NotesIndex(url: url)

        for _ in 1...3 {
            await #expect(throws: (any Error).self) { try await index.open() }
        }
        try Data().write(to: url)
        try await index.open()
        let id = UUID()
        try await index.upsertBatch([makeRow(id: id, title: "Recovered", body: "after three failures")])
        let hits = await index.search("failures")
        #expect(hits == [id])
        await index.close()
    }

    /// `close()` must be re-entrant safe and a reopen must work — the same `discardHandle()` path the
    /// failure branch uses.
    @Test func closeIsIdempotentAndReopenWorks() async throws {
        let dir = try scratchDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("notes-index.sqlite3")
        let index = NotesIndex(url: url)
        try await index.open()
        let id = UUID()
        try await index.upsertBatch([makeRow(id: id, title: "Kept", body: "across a close")])
        await index.close()
        await index.close()                     // second close must not touch a freed handle
        try await index.open()
        let hits = await index.search("across")
        #expect(hits == [id])
        await index.close()
    }
}
