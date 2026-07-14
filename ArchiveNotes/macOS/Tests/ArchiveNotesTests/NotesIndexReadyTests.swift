import Testing
import Foundation
@testable import ArchiveNotes

/// W8-S7 §3.4 — the deterministic index-ready signal the GUI harness polls before asserting FTS /
/// relevance results (instead of racing the async background build). Covers the `NotesIndexer`
/// completion token + `awaitSettled()` primitive and the `NotesModel` app-path build wiring.
/// All file-touching tests use a `mktemp -d` scratch store/index; none touches the real store or corpus.
@Suite("Index-ready signal (§3.4)")
@MainActor
struct NotesIndexReadyTests {

    // MARK: Scratch helpers

    private func makeScratchIndex() async throws -> (NotesIndex, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesIndexReady-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let index = NotesIndex(url: tmp.appendingPathComponent("index.sqlite3"))
        try await index.open()
        return (index, tmp)
    }

    private func makeItem(_ title: String) -> Item {
        Item(id: UUID(), kind: .note, title: title, authors: [], date: nil, datePrecision: nil,
             dateUncertain: false, quality: nil, tags: [], zotero: [], roundup: false,
             created: Date(), modified: Date(), schema: 1, blocks: [],
             unknownFrontMatter: [], trailingBodyRaw: nil)
    }

    // MARK: NotesIndexer signal

    @Test("a fresh indexer is not ready and has generation 0")
    func freshIndexerNotReady() async throws {
        let (index, tmp) = try await makeScratchIndex()
        defer { Task { await index.close() }; try? FileManager.default.removeItem(at: tmp) }
        let indexer = NotesIndexer(index: index)
        #expect(indexer.isIndexReady == false)
        #expect(indexer.indexGeneration == 0)
    }

    @Test("an empty scope settles to ready (nothing to build)")
    func emptyScopeSettles() async throws {
        let (index, tmp) = try await makeScratchIndex()
        defer { Task { await index.close() }; try? FileManager.default.removeItem(at: tmp) }
        let indexer = NotesIndexer(index: index)
        indexer.startIndexing([])
        await indexer.awaitSettled()
        #expect(indexer.isIndexReady)
        #expect(indexer.indexGeneration == 1)
    }

    @Test("a build indexes rows and settles ready with a bumped generation")
    func buildSettlesAndIndexes() async throws {
        let (index, tmp) = try await makeScratchIndex()
        defer { Task { await index.close() }; try? FileManager.default.removeItem(at: tmp) }
        let store = NoteStore(root: tmp)
        let target = makeItem("Zanzibar")
        let refs = [try await store.create(target), try await store.create(makeItem("Elsewhere"))]

        let indexer = NotesIndexer(index: index)
        indexer.startIndexing(refs)
        await indexer.awaitSettled()

        #expect(indexer.isIndexReady)
        #expect(indexer.indexGeneration == 1)
        let hits = await index.search("Zanzibar")
        #expect(hits.contains(target.id), "the freshly built index resolves the item by title")
    }

    @Test("awaitSettled returns immediately when already idle")
    func awaitSettledIdleFastPath() async throws {
        let (index, tmp) = try await makeScratchIndex()
        defer { Task { await index.close() }; try? FileManager.default.removeItem(at: tmp) }
        let indexer = NotesIndexer(index: index)
        await indexer.awaitSettled()                // never kicked → idle → returns at once
        #expect(indexer.isIndexReady == false)      // no build happened, so still not ready
        #expect(indexer.indexGeneration == 0)
    }

    @Test("a coalesced chain settles exactly once")
    func coalescedChainSettlesOnce() async throws {
        let (index, tmp) = try await makeScratchIndex()
        defer { Task { await index.close() }; try? FileManager.default.removeItem(at: tmp) }
        let store = NoteStore(root: tmp)
        let refs1 = [try await store.create(makeItem("First"))]
        let refs2 = [try await store.create(makeItem("Second"))]

        let indexer = NotesIndexer(index: index)
        // Both calls run synchronously on the main actor: the first assigns `task`, so the second
        // coalesces into `pending` rather than launching a parallel pass. The chain settles once.
        indexer.startIndexing(refs1)
        indexer.startIndexing(refs2)
        await indexer.awaitSettled()
        #expect(indexer.indexGeneration == 1)
        #expect(indexer.isIndexReady)
    }

    // MARK: NotesModel app-path wiring

    @Test("buildIndexFromDisk populates the item list and flips ready")
    func modelBuildPopulatesAndReady() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesModelReady-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = NotesIndex(url: root.appendingPathComponent("index.sqlite3"))
        try await index.open()
        defer { Task { await index.close() }; try? FileManager.default.removeItem(at: root) }

        let store = NoteStore(root: root)
        _ = try await store.create(makeItem("Alpha"))
        _ = try await store.create(makeItem("Beta"))

        let org = OrganizationStore(index: index)
        try await org.load(storeRoot: root)
        let indexer = NotesIndexer(index: index)
        let model = NotesModel(organization: org, index: index, noteStore: store, indexer: indexer)

        #expect(model.isIndexReady == false)
        await model.buildIndexFromDisk()
        #expect(model.allItems.count == 2)
        #expect(model.isIndexReady)
        #expect(model.indexGeneration >= 1)
    }

    @Test("a store with no background indexer still surfaces ready")
    func modelWithoutIndexerReady() async throws {
        let (index, tmp) = try await makeScratchIndex()
        defer { Task { await index.close() }; try? FileManager.default.removeItem(at: tmp) }
        let org = OrganizationStore(index: index)
        let model = NotesModel(organization: org)   // pure injected store: no index/indexer/noteStore
        await model.buildIndexFromDisk()
        #expect(model.isIndexReady)
        #expect(model.indexGeneration >= 1)
    }
}
