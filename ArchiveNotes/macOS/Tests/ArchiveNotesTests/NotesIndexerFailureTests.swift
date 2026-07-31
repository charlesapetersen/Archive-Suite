import Testing
import Foundation
@testable import ArchiveNotes

/// W23.m9 (failure mode 1) — the Notes indexing driver must not settle as if a failed build succeeded.
///
/// Before this fix `launch()` opened the index with `try?` and wrote every batch with `try?`, then
/// settled like any other pass: `NotesModel` reloaded whatever the (empty) index held and marked it
/// **Ready**. A note missing from search became indistinguishable from a note that doesn't match, and
/// the note list itself came back empty with nothing said. The driver now carries a typed `Failure`
/// the model mirrors into the sidebar status line.
///
/// The `isIndexReady` signal deliberately still flips on failure — it means *settled*, and
/// `awaitSettled()` (which `bootstrap()` awaits before first paint) resumes off it. These tests are
/// also the guard on that: a bail that skipped `finish` would hang here instead of failing.
///
/// All scratch: a garbage `sqlite3` file plus real `.md` notes in a per-test temp dir. No real store.
@Suite("Index failure reporting (W23.m9)")
@MainActor
struct NotesIndexerFailureTests {

    private func scratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesIndexerFailure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 1 KiB of non-header bytes: SQLite opens the file, then fails on the first statement.
    private func writeGarbage(to url: URL) throws {
        try Data(repeating: 0x5A, count: 1024).write(to: url)
    }

    private func makeItem(_ title: String) -> Item {
        Item(id: UUID(), kind: .note, title: title, authors: [], date: nil, datePrecision: nil,
             dateUncertain: false, quality: nil, tags: [], zotero: [], roundup: false,
             created: Date(), modified: Date(), schema: 1, blocks: [],
             unknownFrontMatter: [], trailingBodyRaw: nil)
    }

    private func ref(_ id: UUID = UUID(), in dir: URL) -> ItemRef {
        ItemRef(id: id, url: dir.appendingPathComponent("\(id.uuidString).md"), mtime: 1)
    }

    // MARK: - Queries

    @Test("a search over an unopenable index reports unavailable, not 'no matches'")
    func searchOnUnopenableIndexReportsUnavailable() async throws {
        let dir = try scratchDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite3")
        try writeGarbage(to: url)
        let indexer = NotesIndexer(index: NotesIndex(url: url))

        let hits = await indexer.search("chafee")
        #expect(hits.isEmpty)
        guard case .unavailable = indexer.failure else {
            Issue.record("expected .unavailable, got \(String(describing: indexer.failure))"); return
        }
        #expect(!(indexer.failure?.message.isEmpty ?? true), "the banner needs a line to show")
    }

    @Test("a summary lookup over an unopenable index reports unavailable")
    func summaryOnUnopenableIndexReportsUnavailable() async throws {
        let dir = try scratchDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite3")
        try writeGarbage(to: url)
        let indexer = NotesIndexer(index: NotesIndex(url: url))

        let summary = await indexer.summary(for: UUID())
        #expect(summary == nil)
        guard case .unavailable = indexer.failure else {
            Issue.record("expected .unavailable, got \(String(describing: indexer.failure))"); return
        }
    }

    @Test("a healthy but empty index raises no false alarm")
    func healthyQueryLeavesNoFailure() async throws {
        let dir = try scratchDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let indexer = NotesIndexer(index: NotesIndex(url: dir.appendingPathComponent("index.sqlite3")))
        let hits = await indexer.search("chafee")
        #expect(hits.isEmpty)                 // genuinely no matches
        #expect(indexer.failure == nil)
    }

    // MARK: - Builds

    @Test("a build over an unopenable index still SETTLES, and reports unavailable")
    func buildOnUnopenableIndexSettlesAndReportsFailure() async throws {
        let dir = try scratchDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite3")
        try writeGarbage(to: url)
        let indexer = NotesIndexer(index: NotesIndex(url: url))

        indexer.startIndexing([ref(in: dir), ref(in: dir)])
        await indexer.awaitSettled()          // would hang if the bail skipped finish()

        #expect(indexer.isIndexReady, "settled must still be signalled — bootstrap awaits it")
        #expect(indexer.indexGeneration >= 1)
        #expect(indexer.progress == nil)
        guard case .unavailable = indexer.failure else {
            Issue.record("expected .unavailable, got \(String(describing: indexer.failure))"); return
        }
    }

    @Test("a build that succeeds after the bad file is replaced clears the failure")
    func successfulBuildAfterRecoveryClearsTheFailure() async throws {
        let dir = try scratchDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite3")
        try writeGarbage(to: url)
        let index = NotesIndex(url: url)
        let indexer = NotesIndexer(index: index)

        _ = await indexer.search("chafee")
        #expect(indexer.failure != nil, "precondition: the corrupt file is reported")

        // Replace the bad file (truncating to empty is a valid empty DB — no delete API needed).
        try Data().write(to: url)
        let store = NoteStore(root: dir)
        _ = try await store.create(makeItem("Alpha"))
        indexer.startIndexing(await store.allItemRefs())
        await indexer.awaitSettled()

        #expect(indexer.failure == nil, "a pass that wrote everything it extracted is healthy")
        let hits = await indexer.search("Alpha")
        #expect(hits.count == 1, "and it really indexed the note")
        await index.close()
    }

    // MARK: - The model surface

    /// The end-to-end shape of the finding: real notes on disk, a dead index. The model must still
    /// settle (Ready is the *settled* signal) but must NOT present that as a healthy index — the
    /// failure reaches `indexFailure` and the sidebar's `statusMessage`.
    @Test("the model surfaces a failed build instead of a clean Ready")
    func modelSurfacesAFailedBuild() async throws {
        let dir = try scratchDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite3")
        try writeGarbage(to: url)
        let index = NotesIndex(url: url)

        let store = NoteStore(root: dir)
        _ = try await store.create(makeItem("Alpha"))
        _ = try await store.create(makeItem("Beta"))

        let model = NotesModel(organization: OrganizationStore(index: index), index: index,
                               noteStore: store, indexer: NotesIndexer(index: index))
        await model.buildIndexFromDisk()

        #expect(model.isIndexReady, "settled must still be signalled")
        #expect(model.allItems.isEmpty, "the index is dead, so the list really is empty…")
        #expect(model.indexFailure != nil, "…and that emptiness must be reported, not presented as Ready")
        #expect(model.statusMessage?.isEmpty == false, "the sidebar banner needs a message")
    }

    /// The healthy counterpart — no false banner on a normal launch.
    @Test("a healthy model build reports no failure")
    func modelHealthyBuildReportsNoFailure() async throws {
        let dir = try scratchDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let index = NotesIndex(url: dir.appendingPathComponent("index.sqlite3"))
        try await index.open()
        let store = NoteStore(root: dir)
        _ = try await store.create(makeItem("Alpha"))

        let org = OrganizationStore(index: index)
        try await org.load(storeRoot: dir)
        let model = NotesModel(organization: org, index: index, noteStore: store,
                               indexer: NotesIndexer(index: index))
        await model.buildIndexFromDisk()

        #expect(model.isIndexReady)
        #expect(model.allItems.count == 1)
        #expect(model.indexFailure == nil)
        await index.close()
    }

    // MARK: - The mapping

    /// The outcome → published-state mapping, checked directly. There is no portable way to make
    /// SQLite fail a *write* on demand (short of corrupting an open file, which is undefined
    /// behaviour), so the `.rowsDropped` count from the two flush sites is verified here rather than
    /// through a forced mid-pass failure.
    @Test("a pass outcome maps to the state the banner shows")
    func outcomeMapsToPublishedState() {
        #expect(NotesIndexer.Outcome.ok.failure == nil, "a clean pass must clear an earlier failure")
        #expect(NotesIndexer.Outcome.rowsDropped(500).failure == .incomplete(rows: 500))
        #expect(NotesIndexer.Outcome.couldNotOpen("file is not a database").failure
                == .unavailable(detail: "file is not a database"))
    }

    @Test("failure messages read correctly")
    func failureMessagesReadCorrectly() {
        #expect(NotesIndexer.Failure.incomplete(rows: 1).message.contains("1 note couldn't"))
        #expect(NotesIndexer.Failure.incomplete(rows: 4).message.contains("4 notes couldn't"))
        #expect(NotesIndexer.Failure.unavailable(detail: "file is not a database")
            .message.contains("file is not a database"), "the SQLite reason belongs in the message")
    }
}
