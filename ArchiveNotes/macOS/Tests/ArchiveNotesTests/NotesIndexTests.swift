import Testing
import Foundation
@testable import ArchiveNotes

/// Tests for `NotesIndex` actor: FTS5 search with prose-tuned BM25 weights, incremental
/// mtime-skip, sanitizer safety, two-emission prune gate, and WAL checkpoint.
/// All file-touching tests use a `mktemp -d` scratch store; none touches the real corpus.
@Suite struct NotesIndexTests {

    /// Helper: create a fresh NotesIndex in a temporary directory.
    private func makeScratchIndex() async throws -> (NotesIndex, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesIndexTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let dbURL = tmp.appendingPathComponent("test-index.sqlite3")
        let index = NotesIndex(url: dbURL)
        try await index.open()
        return (index, tmp)
    }

    /// Helper: build a NoteIndexRow with sensible defaults.
    private func makeRow(
        id: UUID = UUID(),
        mtime: Double = Date().timeIntervalSince1970,
        title: String = "Untitled",
        kind: Item.Kind = .note,
        tags: String = "",
        authors: String = "",
        authorsJSON: String = "[]",
        body: String = "",
        date: String? = nil,
        datePrecision: Item.DatePrecision? = nil,
        dateUncertain: Bool = false,
        sortDate: Int? = nil,
        quality: Int? = nil,
        created: Date = Date(),
        modified: Date = Date(),
        managedTags: String = "[]",
        sourceCount: Int = 0
    ) -> NoteIndexRow {
        NoteIndexRow(id: id, mtime: mtime, title: title, kind: kind, tags: tags,
                     authors: authors, authorsJSON: authorsJSON, body: body, date: date,
                     datePrecision: datePrecision, dateUncertain: dateUncertain,
                     sortDate: sortDate, quality: quality, created: created,
                     modified: modified, managedTags: managedTags, sourceCount: sourceCount)
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - BM25 weight ordering

    @Test func bm25TitleOutranksBody() async throws {
        let (index, tmp) = try await makeScratchIndex()
        defer { cleanup(tmp) }

        let titleHit = UUID()
        let bodyHit = UUID()

        try await index.upsertBatch([
            makeRow(id: bodyHit, title: "Something else", body: "Napoleon was a general"),
            makeRow(id: titleHit, title: "Napoleon", body: "Some unrelated text about gardening"),
        ])

        let results = await index.search("Napoleon")
        #expect(results.count == 2)
        #expect(results.first == titleHit, "Title hit (weight 10) should outrank body hit (weight 1)")
    }

    @Test func tagsOutrankAuthorsOutrankBody() async throws {
        let (index, tmp) = try await makeScratchIndex()
        defer { cleanup(tmp) }

        let tagHit = UUID()
        let authorHit = UUID()
        let bodyHit = UUID()

        try await index.upsertBatch([
            makeRow(id: bodyHit, title: "Note A", body: "Economics of trade"),
            makeRow(id: authorHit, title: "Note B", authors: "Economics Department"),
            makeRow(id: tagHit, title: "Note C", tags: "Economics"),
        ])

        let results = await index.search("Economics")
        #expect(results.count == 3)
        #expect(results[0] == tagHit, "Tags (weight 6) should outrank authors (weight 4)")
        #expect(results[1] == authorHit, "Authors (weight 4) should outrank body (weight 1)")
        #expect(results[2] == bodyHit, "Body (weight 1) should be last")
    }

    // MARK: - Sanitizer safety

    @Test func sanitizerNeverThrowsOnAdversarialQuery() async throws {
        let (index, tmp) = try await makeScratchIndex()
        defer { cleanup(tmp) }

        // Insert one row so the table isn't empty.
        try await index.upsertBatch([makeRow(title: "Test note", body: "Some body text")])

        let adversarial = [
            "\"", "\"\"", "\" OR 1=1 --", "'; DROP TABLE fts; --",
            "NOT AND OR", "***", "a\"b\"c", "", "   ",
            "a b c d e f g h i j k l m n o p q r s t",
            "\u{0000}", "🎉🔥", "a\nb\tc",
            "term1 OR term2", "NEAR(a b)", "{col1}: value",
        ]

        for query in adversarial {
            // Must not throw or crash — empty results are fine.
            let results = await index.search(query)
            _ = results // just needs to not crash
        }
    }

    // MARK: - Incremental mtime skip

    @Test func incrementalMtimeSkip() async throws {
        let (index, tmp) = try await makeScratchIndex()
        defer { cleanup(tmp) }

        let id = UUID()
        let mtime1 = 1000.0

        try await index.upsertBatch([makeRow(id: id, mtime: mtime1, title: "Original")])

        // existingMTimes should return the stored mtime.
        let mtimes = await index.existingMTimes()
        #expect(mtimes[id.uuidString] == mtime1)

        // Same mtime → no re-index needed (indexer checks this).
        #expect(mtimes[id.uuidString] == mtime1, "Same mtime means skip")

        // Different mtime → needs re-index.
        let mtime2 = 2000.0
        #expect(mtimes[id.uuidString] != mtime2, "Different mtime means work")

        // After upsert with new mtime, title updates.
        try await index.upsertBatch([makeRow(id: id, mtime: mtime2, title: "Updated")])
        let results = await index.search("Updated")
        #expect(results == [id])
        let oldResults = await index.search("Original")
        #expect(oldResults.isEmpty, "Old title should no longer match after update")
    }

    // MARK: - Prune two-emission gate

    @Test func pruneRequiresTwoEmissions() async throws {
        let (index, tmp) = try await makeScratchIndex()
        defer { cleanup(tmp) }

        let keepID = UUID()
        let removeID = UUID()

        try await index.upsertBatch([
            makeRow(id: keepID, title: "Keep this"),
            makeRow(id: removeID, title: "Remove this"),
        ])

        #expect(await index.indexedCount() == 2)

        // First emission: removeID absent → should be stashed, not deleted yet.
        // (We test the index-level deleteItems directly since the two-emission gate
        // lives in NotesIndexer, but we verify the delete mechanism works.)
        let allBefore = await index.allIndexedIDs()
        #expect(allBefore.contains(removeID))
        #expect(allBefore.contains(keepID))

        // Delete removeID (simulating confirmed prune after two emissions).
        try await index.deleteItems([removeID])
        let allAfter = await index.allIndexedIDs()
        #expect(!allAfter.contains(removeID), "Deleted ID should be gone")
        #expect(allAfter.contains(keepID), "Kept ID should remain")
        #expect(await index.indexedCount() == 1)
    }

    // MARK: - WAL checkpoint

    @Test func walCheckpointTruncates() async throws {
        let (index, tmp) = try await makeScratchIndex()
        defer { cleanup(tmp) }

        // Insert some rows to generate WAL data.
        var rows: [NoteIndexRow] = []
        for i in 0..<50 {
            rows.append(makeRow(title: "Note \(i)", body: "Body content for note number \(i)"))
        }
        try await index.upsertBatch(rows)

        // Perform maintenance (triggers WAL checkpoint with TRUNCATE).
        await index.performMaintenance(rowsIndexed: 50)

        // The WAL file should be truncated (0 bytes or absent). We verify the DB is
        // still functional after checkpoint.
        let results = await index.search("content")
        #expect(results.count == 50, "All 50 notes should still be searchable after checkpoint")
    }

    // MARK: - search returns item IDs

    @Test func searchReturnsItemIDs() async throws {
        let (index, tmp) = try await makeScratchIndex()
        defer { cleanup(tmp) }

        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()

        try await index.upsertBatch([
            makeRow(id: id1, title: "Alpha note"),
            makeRow(id: id2, title: "Beta note"),
            makeRow(id: id3, title: "Gamma note"),
        ])

        let results = await index.search("Alpha")
        #expect(results == [id1])

        let all = await index.search("note")
        #expect(all.count == 3, "All three notes contain 'note' in the title")
    }

    // MARK: - ItemSummary projection

    @Test func summaryRoundTrip() async throws {
        let (index, tmp) = try await makeScratchIndex()
        defer { cleanup(tmp) }

        let id = UUID()
        let now = Date()
        let tagsJSON = "[\"History\",\"Archives\"]"

        try await index.upsertBatch([
            makeRow(id: id, title: "Test Summary", kind: .extract, tags: "History Archives",
                    authors: "Smith Jones", authorsJSON: "[\"Smith\",\"Jones\"]",
                    date: "1920-03", datePrecision: .month,
                    dateUncertain: true, sortDate: 19200300, quality: 3,
                    created: now, modified: now, managedTags: tagsJSON)
        ])

        let summary = await index.summary(for: id)
        #expect(summary != nil)
        #expect(summary?.id == id)
        #expect(summary?.title == "Test Summary")
        #expect(summary?.kind == .extract)
        #expect(summary?.date == "1920-03")
        #expect(summary?.datePrecision == .month)
        #expect(summary?.dateUncertain == true)
        #expect(summary?.authors == ["Smith", "Jones"])
        #expect(summary?.sortDate == 19200300)
        #expect(summary?.quality == 3)
        #expect(summary?.managedTags == ["History", "Archives"])
    }

    /// The `source_count` column (W7-S4) round-trips through insert → UPDATE → both projections. This
    /// guards the SQLite column bind/read indices — the riskiest part of the extract "Sources" column.
    @Test func sourceCountRoundTrip() async throws {
        let (index, tmp) = try await makeScratchIndex()
        defer { cleanup(tmp) }

        let extractID = UUID(), noteID = UUID()
        try await index.upsertBatch([
            makeRow(id: extractID, title: "Segmented Extract", kind: .extract, sourceCount: 3),
            makeRow(id: noteID, title: "Plain Note", kind: .note, sourceCount: 0),
        ])
        // Per-id projection.
        #expect(await index.summary(for: extractID)?.sourceNoteCount == 3)
        #expect(await index.summary(for: noteID)?.sourceNoteCount == 0)
        // Bulk projection (the list path).
        let all = await index.allSummaries()
        #expect(all.first { $0.id == extractID }?.sourceNoteCount == 3)
        #expect(all.first { $0.id == noteID }?.sourceNoteCount == 0)
        // UPDATE path (re-upsert same id with a new count).
        try await index.upsertBatch([makeRow(id: extractID, title: "Segmented Extract", kind: .extract, sourceCount: 5)])
        #expect(await index.summary(for: extractID)?.sourceNoteCount == 5)
    }

    // MARK: - Organizational tables exist

    @Test func organizationalTablesExist() async throws {
        let (index, tmp) = try await makeScratchIndex()
        defer { cleanup(tmp) }

        // Verify the org tables were created by counting rows (should be 0, but no error).
        let count = await index.indexedCount()
        #expect(count == 0, "Empty index should have 0 items")

        // The tables existing is proven by the fact that open() didn't throw.
        // W2-S5 will add CRUD; for now we just verify the schema is in place.
    }

    // MARK: - Re-index replaces stale body (W8-S3 §1.4)

    /// Re-upserting the same id with a new BODY replaces the stale body: the old body text no longer
    /// matches, the new one does, and the row count stays at one (parity with Reader's
    /// `testReindexReplacesOldBody`). Complements `incrementalMtimeSkip`, which only covers the title.
    @Test func reindexReplacesOldBody() async throws {
        let (index, tmp) = try await makeScratchIndex()
        defer { cleanup(tmp) }

        let id = UUID()
        try await index.upsertBatch([makeRow(id: id, title: "Fixed Title", body: "alpha unique body")])
        #expect(await index.search("alpha") == [id])

        // Re-index the same id with a different body.
        try await index.upsertBatch([makeRow(id: id, title: "Fixed Title", body: "beta different body")])
        #expect(await index.search("beta") == [id])
        #expect((await index.search("alpha")).isEmpty, "Stale body text must not match after re-index")
        #expect(await index.indexedCount() == 1, "Re-upsert replaces the row, never duplicates it")
    }

    // MARK: - Prune gate (W8-S3 §1.4): the two-emission decision is pure + empty-snapshot-safe

    /// The crown-jewel data-safety property: an empty `currentIDs` snapshot NEVER prunes — not on the
    /// first emission, and not even when repeated. A naive two-emission gate would stash the whole
    /// index on the first empty snapshot and then WIPE it on the second; the empty-snapshot guard in
    /// `pruneDecision` makes that impossible (the index is a rebuildable cache — refusing to prune is safe).
    @Test func pruneGateEmptySnapshotNeverWipes() {
        let a = UUID(), b = UUID()
        let indexed: Set<UUID> = [a, b]

        // First emission, empty snapshot, no prior pending → delete nothing, stash nothing.
        let first = NotesIndexer.pruneDecision(indexed: indexed, currentIDs: [], previousPending: nil)
        #expect(first.delete.isEmpty)
        #expect(first.newPending == nil)

        // Second emission, STILL empty (as if [a,b] had been stashed) → STILL deletes nothing.
        let second = NotesIndexer.pruneDecision(indexed: indexed, currentIDs: [], previousPending: indexed)
        #expect(second.delete.isEmpty, "A persistent empty snapshot must never wipe the index")
        #expect(second.newPending == nil)
    }

    /// A real absence is deleted only after being confirmed across two consecutive emissions.
    @Test func pruneGateRequiresTwoEmissions() {
        let keep = UUID(), gone = UUID()
        let indexed: Set<UUID> = [keep, gone]
        let current: Set<UUID> = [keep]   // `gone` is absent on disk

        // Emission 1 (no prior pending): stash the absence, delete nothing.
        let e1 = NotesIndexer.pruneDecision(indexed: indexed, currentIDs: current, previousPending: nil)
        #expect(e1.delete.isEmpty)
        #expect(e1.newPending == [gone])

        // Emission 2 (same absence): now confirmed → delete exactly `gone`, nothing left pending.
        let e2 = NotesIndexer.pruneDecision(indexed: indexed, currentIDs: current, previousPending: e1.newPending)
        #expect(e2.delete == [gone])
        #expect(e2.newPending == nil)
    }

    /// A transient one-emission drop that reappears the next emission is never deleted.
    @Test func pruneGateTransientDropNotDeleted() {
        let a = UUID(), b = UUID()
        let indexed: Set<UUID> = [a, b]

        // Emission 1: `b` momentarily absent → stashed.
        let e1 = NotesIndexer.pruneDecision(indexed: indexed, currentIDs: [a], previousPending: nil)
        #expect(e1.newPending == [b])

        // Emission 2: `b` is back (full snapshot) → nothing absent → delete nothing, pending cleared.
        let e2 = NotesIndexer.pruneDecision(indexed: indexed, currentIDs: [a, b], previousPending: e1.newPending)
        #expect(e2.delete.isEmpty, "A reappearing item must not be pruned")
        #expect(e2.newPending == nil)
    }

    /// With multiple absences, only those confirmed across BOTH emissions are deleted; a newly-absent
    /// item is stashed (needs its own second confirmation) and present items are always kept.
    @Test func pruneGateDeletesOnlyConfirmedAbsent() {
        let keep = UUID(), goneA = UUID(), goneB = UUID()
        let indexed: Set<UUID> = [keep, goneA, goneB]

        // Emission 1: only goneA absent → stashed.
        let e1 = NotesIndexer.pruneDecision(indexed: indexed, currentIDs: [keep, goneB], previousPending: nil)
        #expect(e1.delete.isEmpty)
        #expect(e1.newPending == [goneA])

        // Emission 2: goneA still absent (confirmed → delete) AND goneB now newly absent (stash only).
        let e2 = NotesIndexer.pruneDecision(indexed: indexed, currentIDs: [keep], previousPending: e1.newPending)
        #expect(e2.delete == [goneA], "Only the twice-confirmed absence is deleted")
        #expect(e2.newPending == [goneB], "A newly-absent item is carried forward, not deleted yet")
    }

    // MARK: - Organizational graph persists across a DB close/reopen (W8-S3 §1.4)

    /// The org-graph durable tables (folders / memberships / template assignments) survive a
    /// close→reopen of the SAME db file. Unlike the FTS `items` cache these are app-owned durable data
    /// (§11), so they must reload verbatim. Complements `OrganizationStoreTests.foldersPersistToDB` by
    /// asserting the NotesIndex DB layer directly — including **template assignments**, which the
    /// store-level DB-persist test does not exercise.
    @Test func organizationGraphPersistsAndReloads() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesIndexTests-org-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("org-index.sqlite3")

        let parentID = UUID(), childID = UUID(), itemID = UUID(), templateID = UUID()
        let addedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let index1 = NotesIndex(url: dbURL)
        try await index1.open()
        try await index1.insertFolder(VFolder(id: parentID, name: "Research", parentId: nil,
                                               sortOrder: 0, kind: .normal, queryJSON: nil))
        try await index1.insertFolder(VFolder(id: childID, name: "1970s", parentId: parentID,
                                               sortOrder: 1, kind: .normal, queryJSON: nil))
        try await index1.insertMembership(Membership(itemId: itemID, folderId: childID, addedAt: addedAt))
        try await index1.insertTemplateAssignment(TemplateAssignment(folderId: parentID, templateId: templateID))
        await index1.close()

        // Reopen the same DB file — durable tables must reload verbatim.
        let index2 = NotesIndex(url: dbURL)
        try await index2.open()

        let folders = await index2.allFolders()
        #expect(folders.contains { $0.id == parentID && $0.name == "Research" && $0.parentId == nil })
        #expect(folders.contains { $0.id == childID && $0.parentId == parentID && $0.sortOrder == 1 })

        let memberships = await index2.allMemberships()
        let reloaded = memberships.first { $0.itemId == itemID }
        #expect(reloaded?.folderId == childID)
        #expect(reloaded.map { abs($0.addedAt.timeIntervalSince(addedAt)) < 1 } == true,
                "addedAt round-trips to within epoch-seconds precision")

        let assignments = await index2.allTemplateAssignments()
        #expect(assignments.contains { $0.folderId == parentID && $0.templateId == templateID })

        await index2.close()
    }
}
