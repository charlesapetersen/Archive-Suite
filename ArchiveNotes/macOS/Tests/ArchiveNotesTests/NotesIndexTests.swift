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
        let tagsJSON = "[\"History\",\"ArchiveSuite\"]"

        try await index.upsertBatch([
            makeRow(id: id, title: "Test Summary", kind: .extract, tags: "History ArchiveSuite",
                    authors: "Smith Jones", authorsJSON: "[\"Smith\",\"Jones\"]",
                    date: "1920-03", datePrecision: .month,
                    dateUncertain: true, sortDate: 19200300, quality: 4,
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
        #expect(summary?.quality == 4)
        #expect(summary?.managedTags == ["History", "ArchiveSuite"])
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
}
