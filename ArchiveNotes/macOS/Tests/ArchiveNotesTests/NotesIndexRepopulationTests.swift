import Testing
import Foundation
@testable import ArchiveNotes

/// W23.m9-fu2 — a repaired index must be REFILLED, not merely re-opened.
///
/// W23.m9-fu made every model-level read go through `openIndexForQuery()`, which retries the open and
/// retracts the "unavailable" banner the moment the file opens again. But nothing put the rows back:
/// they are written only by the launch-time `buildIndexFromDisk()`. So a mid-session repair — the
/// operator replaces the corrupt file, a sync client heals it, the volume returns — swapped one silent
/// wrong answer ("no matches", because nothing could be read) for another ("no matches", because
/// nothing has been written yet), this time with no banner to explain it.
///
/// The fix schedules that same from-disk pass on the `unavailable → open` EDGE. These tests pin the
/// three properties that make it safe, since each one is a way the obvious implementation goes wrong:
/// it must fire on the edge and not on the state (or a 150 ms-debounced search walks the store once per
/// keystroke), it must not block the read that noticed, and it must run one at a time.
///
/// All scratch: garbage / empty sqlite3 files plus real `.md` notes in a per-test temp dir. Never the
/// owner's real notes store, never a corpus. Read-only w.r.t. the store by design — one test asserts it.
@Suite("Post-recovery index repopulation (W23.m9-fu2)")
@MainActor
struct NotesIndexRepopulationTests {

    private func scratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesIndexRepopulation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 1 KiB of non-header bytes: SQLite opens the file, then fails on the first statement.
    private func writeGarbage(to url: URL) throws {
        try Data(repeating: 0x5A, count: 1024).write(to: url)
    }

    /// Truncating to zero bytes is a valid *empty* database — the "someone replaced the bad file"
    /// repair, and the case that matters here: it opens, and it holds nothing.
    private func repairToEmptyDatabase(at url: URL) throws {
        try Data().write(to: url)
    }

    private func makeItem(_ title: String) -> Item {
        Item(id: UUID(), kind: .note, title: title, authors: [], date: nil, datePrecision: nil,
             dateUncertain: false, quality: nil, tags: [], zotero: [], roundup: false,
             created: Date(), modified: Date(), schema: 1, blocks: [],
             unknownFrontMatter: [], trailingBodyRaw: nil)
    }

    /// A model shaped like the app path — a real driver and a real (scratch) store, sharing the one
    /// sqlite handle. The store is what the recovery pass walks, so most tests here need it.
    private func model(over index: NotesIndex, store: NoteStore? = nil) -> NotesModel {
        NotesModel(organization: OrganizationStore(index: index), index: index,
                   noteStore: store, indexer: NotesIndexer(index: index))
    }

    /// A scratch store holding `titles`, one `.md` note each.
    private func store(in dir: URL, titles: [String]) async throws -> NoteStore {
        let store = NoteStore(root: dir)
        for title in titles { _ = try await store.create(makeItem(title)) }
        return store
    }

    /// Await the rebuild the query path scheduled, rather than sleeping on it. `nil` means it either
    /// already finished or was never scheduled — which the assertions then distinguish.
    private func awaitRecovery(_ model: NotesModel) async {
        if let task = model.inFlightIndexRecoveryTask { await task.value }
    }

    // MARK: - The finding

    /// The whole item: after the repair the handle came back, but the rows did not.
    ///
    /// Also the off-the-critical-path proof — the read that *notices* the repair still answers `[]`.
    /// Had the rebuild been awaited inline it would have found the note on that very first read, so
    /// the empty first result and the populated later one are one assertion in two halves.
    @Test("a repaired index is refilled from disk, and the rows land on a later read")
    func repairedIndexIsRefilledOnALaterRead() async throws {
        let dir = try scratchDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite3")
        try writeGarbage(to: url)
        let index = NotesIndex(url: url)
        let model = model(over: index, store: try await store(in: dir, titles: ["Ptolemy", "Quintessence"]))

        await model.buildIndexFromDisk()          // launch: the index never opens, nothing is indexed
        guard case .unavailable = model.indexFailure else {
            Issue.record("precondition: the corrupt index must be reported"); return
        }

        try repairToEmptyDatabase(at: url)
        let duringRecovery = await model.search("Ptolemy")
        #expect(duringRecovery.isEmpty, "the read that notices the repair must not block on a store walk")

        await awaitRecovery(model)
        let afterRecovery = await model.search("Ptolemy")

        #expect(afterRecovery.count == 1, "a repaired index must be refilled, not just re-opened")
        #expect(model.indexFailure == nil, "and nothing is left to report")
        await index.close()
    }

    /// The other model-level read drives the same recovery — the seam is shared, so the note LIST must
    /// come back too, not only search. (`reloadItems` over a dead index publishes nothing at all, by
    /// W23.m9-fu, so pre-fix the library stayed empty for the session.)
    @Test("reloadItems after a repair republishes the rebuilt library")
    func reloadItemsAfterRepairRepublishesTheLibrary() async throws {
        let dir = try scratchDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite3")
        try writeGarbage(to: url)
        let index = NotesIndex(url: url)
        let model = model(over: index, store: try await store(in: dir, titles: ["Ptolemy", "Quintessence"]))

        await model.buildIndexFromDisk()
        #expect(model.allItems.isEmpty, "precondition: a read that never ran published nothing")

        try repairToEmptyDatabase(at: url)
        await model.reloadItems()
        await awaitRecovery(model)

        #expect(model.allItems.count == 2, "the rebuild must repopulate the visible library")
        await index.close()
    }

    // MARK: - Edge-triggered, not per-read

    /// The objection that deferred this fix: a full disk walk from a keystroke. A healthy index has no
    /// `unavailable → open` edge to cross, so no read of it may ever schedule a walk.
    @Test("searching a healthy index never schedules a rebuild")
    func healthyIndexIsNeverRebuiltByAQuery() async throws {
        let dir = try scratchDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let index = NotesIndex(url: dir.appendingPathComponent("index.sqlite3"))
        let model = model(over: index, store: try await store(in: dir, titles: ["Ptolemy"]))

        await model.buildIndexFromDisk()
        let settled = model.indexGeneration
        #expect(model.indexFailure == nil, "precondition: this index is healthy")

        for _ in 0..<3 { _ = await model.search("Ptolemy") }

        #expect(model.inFlightIndexRecoveryTask == nil, "nothing recovered, so nothing may be rebuilt")
        #expect(model.indexGeneration == settled,
                "a keystroke over a healthy index must not cost a store walk")
        await index.close()
    }

    /// One recovery, one pass — the reads that follow the first must not stack rebuilds on it. Each
    /// settled pass bumps `indexGeneration` by exactly one, so the token counts them.
    @Test("three reads after one repair run exactly one rebuild")
    func oneRecoveryKicksExactlyOneRebuild() async throws {
        let dir = try scratchDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite3")
        try writeGarbage(to: url)
        let index = NotesIndex(url: url)
        let model = model(over: index, store: try await store(in: dir, titles: ["Ptolemy"]))

        await model.buildIndexFromDisk()
        let settled = model.indexGeneration

        try repairToEmptyDatabase(at: url)
        for _ in 0..<3 { _ = await model.search("Ptolemy") }
        await awaitRecovery(model)

        #expect(model.indexGeneration == settled + 1,
                "the recovery edge is crossed once, so exactly one pass may run")
        await index.close()
    }

    /// The deliberate behaviour change this item was split out to make: the rebuild re-marks the
    /// hidden `an.status.indexReady` probe. It must move FORWARD — a probe that regressed to
    /// "building" mid-session would hang an XCUITest that had already seen it settle.
    @Test("the recovery rebuild advances the ready token and never un-readies")
    func readyNeverRegressesAcrossTheRecoveryRebuild() async throws {
        let dir = try scratchDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite3")
        try writeGarbage(to: url)
        let index = NotesIndex(url: url)
        let model = model(over: index, store: try await store(in: dir, titles: ["Ptolemy"]))

        await model.buildIndexFromDisk()
        #expect(model.isIndexReady, "precondition: settled, even though the build failed")
        let settled = model.indexGeneration

        try repairToEmptyDatabase(at: url)
        _ = await model.search("Ptolemy")
        await awaitRecovery(model)

        #expect(model.isIndexReady, "a settled index must not un-settle")
        #expect(model.indexGeneration > settled, "and a build that ran must be visible to the probe")
        await index.close()
    }

    // MARK: - The rebuild is read-only w.r.t. the store

    /// It reuses `buildIndexFromDisk()`, which prunes nothing and only reads `.md` files. The index is
    /// a disposable cache; the notes are the irreplaceable half, and a recovery pass must not touch
    /// them.
    @Test("the rebuild leaves every note on disk untouched")
    func rebuildDoesNotTouchTheNotesOnDisk() async throws {
        let dir = try scratchDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite3")
        try writeGarbage(to: url)
        let index = NotesIndex(url: url)
        let noteStore = try await store(in: dir, titles: ["Ptolemy", "Quintessence"])
        let model = model(over: index, store: noteStore)
        let before = await noteStore.allItemRefs().map(\.url.path).sorted()
        #expect(before.count == 2, "precondition: two notes on disk")

        await model.buildIndexFromDisk()
        try repairToEmptyDatabase(at: url)
        _ = await model.search("Ptolemy")
        await awaitRecovery(model)

        let after = await noteStore.allItemRefs().map(\.url.path).sorted()
        #expect(after == before, "a cache rebuild must not add, move or remove a note")
        for path in after {
            #expect(FileManager.default.fileExists(atPath: path), "\(path) must still be readable")
        }
        await index.close()
    }

    /// A recovery whose index came back WITH its rows — the volume returned rather than the file being
    /// replaced. The pass is mtime-skipped, so this must cost a directory walk and keep every row; an
    /// implementation that wiped and rebuilt would pass the tests above and fail this one.
    @Test("a recovery over an intact index keeps the rows it already had")
    func recoveryOverAnIntactIndexKeepsItsRows() async throws {
        let dir = try scratchDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite3")
        let index = NotesIndex(url: url)
        let model = model(over: index, store: try await store(in: dir, titles: ["Ptolemy", "Quintessence"]))

        await model.buildIndexFromDisk()
        #expect(await model.search("Quintessence").count == 1, "precondition: indexed and findable")

        // Take the file away and put it back, byte for byte — the volume dropping out and returning.
        await index.close()
        let stashed = dir.appendingPathComponent("stash", isDirectory: true)
        try FileManager.default.createDirectory(at: stashed, withIntermediateDirectories: true)
        let sidecars = ["", "-wal", "-shm"].map { URL(fileURLWithPath: url.path + $0) }
        for file in sidecars where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.copyItem(at: file, to: stashed.appendingPathComponent(file.lastPathComponent))
        }
        try writeGarbage(to: url)
        _ = await model.search("Quintessence")
        guard case .unavailable = model.indexFailure else {
            Issue.record("precondition: the index must be reported unavailable while it is away"); return
        }
        for file in sidecars {
            let saved = stashed.appendingPathComponent(file.lastPathComponent)
            guard FileManager.default.fileExists(atPath: saved.path) else { continue }
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.copyItem(at: saved, to: file)
        }

        _ = await model.search("Quintessence")
        await awaitRecovery(model)

        #expect(await model.search("Quintessence").count == 1, "the rows that survived must survive")
        #expect(await model.search("Ptolemy").count == 1)
        #expect(model.indexFailure == nil)
        await index.close()
    }

    // MARK: - Nothing to rebuild from

    /// A driver with no store — an app model before `bootstrap()` picked a root. The handle recovers
    /// and the banner is retracted either way; there is simply no disk to walk.
    @Test("a model with no note store recovers the handle but schedules no walk")
    func modelWithoutAStoreSchedulesNoWalk() async throws {
        let dir = try scratchDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite3")
        try writeGarbage(to: url)
        let index = NotesIndex(url: url)
        let model = model(over: index)                       // driver, but no store

        _ = await model.search("Ptolemy")
        #expect(model.indexFailure != nil, "precondition: the corrupt file is reported")

        try repairToEmptyDatabase(at: url)
        _ = await model.search("Ptolemy")

        #expect(model.indexFailure == nil, "it opened, so the claim is retracted as before")
        #expect(model.inFlightIndexRecoveryTask == nil, "with no store there is nothing to rebuild from")
        await index.close()
    }

    /// The injected-index model (tests, previews) has no driver either. Same contract.
    @Test("a driver-less model recovers the handle but schedules no walk")
    func driverlessModelSchedulesNoWalk() async throws {
        let dir = try scratchDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite3")
        try writeGarbage(to: url)
        let index = NotesIndex(url: url)
        let model = NotesModel(organization: OrganizationStore(index: index), index: index)

        _ = await model.search("Ptolemy")
        #expect(model.indexFailure != nil, "precondition: the corrupt file is reported")

        try repairToEmptyDatabase(at: url)
        _ = await model.search("Ptolemy")

        #expect(model.indexFailure == nil)
        #expect(model.inFlightIndexRecoveryTask == nil, "no driver, so no from-disk pass exists to run")
        await index.close()
    }
}
