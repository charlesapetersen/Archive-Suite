import Testing
import Foundation
@testable import ArchiveNotes

/// W40.fix-notes-index-failure-empty-fu1 — a database that opens and lists its folders but fails
/// part-way through its memberships used to be adopted as the folder graph: the reads stopped at the
/// failed step and returned the rows so far, `load` took the DB-first branch for any non-empty folder
/// list, and the next mutation exported that half-graph over `organization.json`, the only good copy.
///
/// The failure is a real SQLite step error, not a hook: `memberships` is swapped for a view whose
/// second row evaluates `abs()` of the smallest integer, which SQLite reports as an integer overflow
/// while stepping. All scratch, per-test temp dirs.
@Suite("Organization reads refuse a half-read graph (W40.fix-notes-index-failure-empty-fu1)")
@MainActor
struct OrganizationPartialReadTests {

    private struct Env {
        let dir: URL
        let budget: UUID
        let mirror: Data
        var mirrorURL: URL { dir.appendingPathComponent("organization.json") }
        var indexURL: URL { dir.appendingPathComponent("index.sqlite3") }
    }

    /// A healthy store with one folder holding two notes, exported to its mirror, then closed.
    private func makeEnv() async throws -> Env {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrgPartialRead-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let index = NotesIndex(url: dir.appendingPathComponent("index.sqlite3"))
        try await index.open()
        let org = OrganizationStore(index: index)
        try await org.load(storeRoot: dir)
        let budget = try await org.createFolder(name: "Budget")
        try await org.addMembership(item: Self.first, folder: budget.id)
        try await org.addMembership(item: Self.second, folder: budget.id)
        await index.close()
        let mirror = try Data(contentsOf: dir.appendingPathComponent("organization.json"))
        return Env(dir: dir, budget: budget.id, mirror: mirror)
    }

    private static let first = UUID()
    private static let second = UUID()

    /// Reopen the store's index with `memberships` failing on the second note's row.
    private func openWithFailingMemberships(_ env: Env) async throws -> NotesIndex {
        let index = NotesIndex(url: env.indexURL)
        try await index.open()
        try await index.executeForTesting("ALTER TABLE memberships RENAME TO memberships_real;")
        try await index.executeForTesting("""
            CREATE VIEW memberships AS
            SELECT item_id, folder_id,
                   CASE WHEN item_id = '\(Self.second.uuidString)' THEN abs(-9223372036854775808)
                        ELSE added_at END AS added_at
            FROM memberships_real;
            """)
        return index
    }

    @Test("a membership read that fails part-way throws instead of returning the rows so far")
    func membershipReadThrowsOnStepError() async throws {
        let env = try await makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let index = try await openWithFailingMemberships(env)
        await #expect(throws: NotesIndex.IndexError.self) { _ = try await index.allMemberships() }
        #expect(try await index.allFolders().contains { $0.id == env.budget }, "folders still read")
        await index.close()
    }

    @Test("load refuses the half-read graph, and nothing after it overwrites the mirror")
    func loadRefusesHalfReadGraph() async throws {
        let env = try await makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let index = try await openWithFailingMemberships(env)
        let org = OrganizationStore(index: index)

        await #expect(throws: NotesIndex.IndexError.self) { try await org.load(storeRoot: env.dir) }
        // The mirror is on show instead, read-only, with both notes still filed.
        #expect(org.isReadOnlyMirror)
        #expect(Set(org.memberships.filter { $0.folderId == env.budget }.map(\.itemId))
                == [Self.first, Self.second])
        // Before the fix this mutation exported a Budget holding one of its two notes.
        await #expect(throws: OrganizationError.readOnlyWhileIndexUnavailable) {
            _ = try await org.createFolder(name: "After")
        }
        #expect(try await !index.allFolders().contains { $0.name == "After" }, "nor wrote the database")
        #expect(org.retryStaleMirrorExport() == false)
        #expect(try Data(contentsOf: env.mirrorURL) == env.mirror, "the mirror is left whole")
        await index.close()
    }

    @Test("a recovery reload that half-reads falls back to the mirror, still read-only")
    func recoveryReloadFallsBackToMirror() async throws {
        let env = try await makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let index = try await openWithFailingMemberships(env)
        let org = OrganizationStore(index: index)
        org.loadReadOnlyMirror(storeRoot: env.dir)

        await #expect(throws: NotesIndex.IndexError.self) { try await org.reloadAfterIndexRecovery() }
        #expect(org.isReadOnlyMirror, "still the mirror, not the half-read database")
        #expect(org.memberships.filter { $0.folderId == env.budget }.count == 2)
        await #expect(throws: OrganizationError.readOnlyWhileIndexUnavailable) {
            _ = try await org.createFolder(name: "Lost")
        }
        #expect(try Data(contentsOf: env.mirrorURL) == env.mirror)
        await index.close()
    }
}
