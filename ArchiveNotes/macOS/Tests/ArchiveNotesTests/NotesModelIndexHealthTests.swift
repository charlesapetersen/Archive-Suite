import Testing
import Foundation
@testable import ArchiveNotes

/// W23.m9-fu — the model's OWN index reads must report an unavailable index, not answer `[]`.
///
/// W23.m9 gave `NotesIndexer` a health-aware `openForQuery()` seam plus a typed `Failure` the sidebar
/// shows, but `NotesModel.search(_:)` and `reloadItems()` queried the shared `NotesIndex` **directly**:
/// they never attempted an open, so they never noticed a dead index and never set a `Failure`. Once the
/// launch banner was dismissed, a session whose index died answered every search with `[]` and said
/// nothing more — and if the bad file was replaced while the app ran, nothing ever retried the open.
///
/// All scratch: garbage / empty sqlite3 files plus real `.md` notes in a per-test temp dir. Never the
/// owner's real notes store, never a corpus.
@Suite("Model-level index health (W23.m9-fu)")
@MainActor
struct NotesModelIndexHealthTests {

    private func scratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesModelIndexHealth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 1 KiB of non-header bytes: SQLite opens the file, then fails on the first statement.
    private func writeGarbage(to url: URL) throws {
        try Data(repeating: 0x5A, count: 1024).write(to: url)
    }

    /// A model over `index` shaped like the app path — a real driver sharing the one sqlite handle.
    private func model(over index: NotesIndex, store: NoteStore? = nil) -> NotesModel {
        NotesModel(organization: OrganizationStore(index: index), index: index,
                   noteStore: store, indexer: NotesIndexer(index: index))
    }

    private func summary(_ title: String) -> ItemSummary {
        ItemSummary(id: UUID(), title: title, kind: .note, date: nil, datePrecision: nil,
                    dateUncertain: false, authors: [], sortDate: nil, quality: nil,
                    created: Date(), modified: Date(), mtime: 1, managedTags: [])
    }

    private func makeItem(_ title: String) -> Item {
        Item(id: UUID(), kind: .note, title: title, authors: [], date: nil, datePrecision: nil,
             dateUncertain: false, quality: nil, tags: [], zotero: [], roundup: false,
             created: Date(), modified: Date(), schema: 1, blocks: [],
             unknownFrontMatter: [], trailingBodyRaw: nil)
    }

    // MARK: - search(_:)

    /// The finding itself: the model's own search over a dead index.
    @Test("a model-level search over an unopenable index reports unavailable, not 'no matches'")
    func modelSearchOverDeadIndexReportsUnavailable() async throws {
        let dir = try scratchDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite3")
        try writeGarbage(to: url)
        let model = model(over: NotesIndex(url: url))

        let hits = await model.search("chafee")

        #expect(hits.isEmpty)
        guard case .unavailable = model.indexFailure else {
            Issue.record("expected .unavailable, got \(String(describing: model.indexFailure))"); return
        }
        #expect(model.statusMessage?.isEmpty == false, "the sidebar banner needs a line to show")
    }

    /// The lived symptom: the banner was dismissed, and every later search said nothing.
    @Test("a dismissed banner re-arms on the next search")
    func dismissedBannerReArmsOnTheNextSearch() async throws {
        let dir = try scratchDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite3")
        try writeGarbage(to: url)
        let store = NoteStore(root: dir)
        _ = try await store.create(makeItem("Alpha"))
        let model = model(over: NotesIndex(url: url), store: store)

        await model.buildIndexFromDisk()                  // launch: the failure is surfaced
        #expect(model.statusMessage?.isEmpty == false, "precondition: the launch banner shows")
        model.statusMessage = nil                         // the operator taps it away

        _ = await model.search("alpha")

        #expect(model.statusMessage?.isEmpty == false,
                "a search that found nothing BECAUSE the index is dead must say so again")
    }

    /// A blank query is not a query — it must not open anything or raise a banner.
    @Test("a blank query over a dead index raises no banner")
    func blankQueryRaisesNoBanner() async throws {
        let dir = try scratchDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite3")
        try writeGarbage(to: url)
        let model = model(over: NotesIndex(url: url))

        #expect(await model.search("   ").isEmpty)
        #expect(model.indexFailure == nil)
        #expect(model.statusMessage == nil)
    }

    /// The other half of the residual: nothing ever retried the open, so a file repaired mid-session
    /// stayed dead for the rest of it.
    @Test("a search after the bad file is replaced recovers, and retracts the banner it posted")
    func searchAfterRecoveryClearsTheFailure() async throws {
        let dir = try scratchDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite3")
        try writeGarbage(to: url)
        let index = NotesIndex(url: url)
        let model = model(over: index)

        _ = await model.search("chafee")
        #expect(model.indexFailure != nil, "precondition: the corrupt file is reported")

        // Truncating to empty is a valid empty DB — no delete API needed.
        try Data().write(to: url)
        let hits = await model.search("chafee")

        #expect(hits.isEmpty, "an empty index genuinely has no matches")
        #expect(model.indexFailure == nil, "it opened; the 'unavailable' claim is no longer true")
        #expect(model.statusMessage == nil, "and the line it posted is retracted, not left lying")
        await index.close()
    }

    /// The must-not-over-report guard: a healthy index that simply holds no match.
    @Test("a healthy but empty index raises no false alarm")
    func healthyEmptyIndexRaisesNoFalseAlarm() async throws {
        let dir = try scratchDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let index = NotesIndex(url: dir.appendingPathComponent("index.sqlite3"))
        let model = model(over: index)

        let hits = await model.search("chafee")

        #expect(hits.isEmpty)
        #expect(model.indexFailure == nil)
        #expect(model.statusMessage == nil)
        await index.close()
    }

    /// A status line another subsystem owns must survive: the model may only retract its own.
    @Test("recovery does not swallow another subsystem's status line")
    func recoveryLeavesAnotherSubsystemsMessageAlone() async throws {
        let dir = try scratchDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite3")
        try writeGarbage(to: url)
        let index = NotesIndex(url: url)
        let model = model(over: index)

        _ = await model.search("chafee")
        #expect(model.indexFailure != nil, "precondition: the corrupt file is reported")
        model.statusMessage = "Couldn't move 2 notes to the Trash."   // a different degradation reports

        try Data().write(to: url)
        _ = await model.search("chafee")

        #expect(model.indexFailure == nil)
        #expect(model.statusMessage == "Couldn't move 2 notes to the Trash.",
                "the index recovering says nothing about the trash failure")
        await index.close()
    }

    // MARK: - reloadItems()

    /// `allSummaries()` over a dead index returns `[]` for the same reason `search` does — publishing
    /// it would erase the visible list on the strength of a query that never ran.
    @Test("reloadItems over a dead index keeps the list it has, and reports")
    func reloadItemsOverDeadIndexKeepsTheList() async throws {
        let dir = try scratchDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite3")
        try writeGarbage(to: url)
        let model = model(over: NotesIndex(url: url))
        model.replaceItems([summary("Alpha"), summary("Beta")])

        await model.reloadItems()

        #expect(model.allItems.count == 2, "a failed read must not be published as an empty library")
        guard case .unavailable = model.indexFailure else {
            Issue.record("expected .unavailable, got \(String(describing: model.indexFailure))"); return
        }
    }

    /// …and the guard must not freeze the list: a healthy read of a genuinely empty index still lands.
    @Test("reloadItems over a healthy index still publishes what it read")
    func reloadItemsOverHealthyIndexStillReplaces() async throws {
        let dir = try scratchDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let index = NotesIndex(url: dir.appendingPathComponent("index.sqlite3"))
        let model = model(over: index)
        model.replaceItems([summary("Stale")])

        await model.reloadItems()

        #expect(model.allItems.isEmpty, "an empty index really is empty — that must still publish")
        #expect(model.indexFailure == nil)
        await index.close()
    }

    // MARK: - The driver-less injection path

    /// The test/preview init supplies an index with no driver. It must still search a healthy index…
    @Test("a model injected without a driver still searches a healthy index")
    func driverlessModelSearchesHealthyIndex() async throws {
        let dir = try scratchDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let index = NotesIndex(url: dir.appendingPathComponent("index.sqlite3"))
        let store = NoteStore(root: dir)
        _ = try await store.create(makeItem("Zanzibar"))
        let builder = NotesIndexer(index: index)
        builder.startIndexing(await store.allItemRefs())
        await builder.awaitSettled()

        let model = NotesModel(organization: OrganizationStore(index: index), index: index)
        let hits = await model.search("Zanzibar")

        #expect(hits.count == 1, "routing the read through an open attempt must not break the plain path")
        #expect(model.indexFailure == nil)
        await index.close()
    }

    /// …and report a dead one the same way the app path does, rather than depending on which init ran.
    @Test("a model injected without a driver reports a dead index too")
    func driverlessModelReportsDeadIndex() async throws {
        let dir = try scratchDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite3")
        try writeGarbage(to: url)
        let model = NotesModel(organization: OrganizationStore(index: NotesIndex(url: url)),
                              index: NotesIndex(url: url))

        let hits = await model.search("chafee")

        #expect(hits.isEmpty)
        guard case .unavailable(let detail) = model.indexFailure else {
            Issue.record("expected .unavailable, got \(String(describing: model.indexFailure))"); return
        }
        #expect(!detail.isEmpty, "the SQLite reason belongs in the message")
    }

    /// A model with no index at all (the pure injected store) answers empty and reports nothing —
    /// there is no index to be unhealthy.
    @Test("a model with no index at all raises no banner")
    func indexlessModelRaisesNoBanner() async throws {
        let dir = try scratchDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite3")
        try writeGarbage(to: url)   // even so: the model holds no index, so it never looks
        let model = NotesModel(organization: OrganizationStore(index: NotesIndex(url: url)))

        #expect(await model.search("chafee").isEmpty)
        #expect(model.indexFailure == nil)
        #expect(model.statusMessage == nil)
    }
}
