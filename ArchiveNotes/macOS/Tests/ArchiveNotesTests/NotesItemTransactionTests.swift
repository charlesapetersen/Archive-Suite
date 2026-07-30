import Testing
import Foundation
@testable import ArchiveNotes

// W23.h2 — same-item edit transactions must never lose an update.
//
// Every note edit used to be a load-whole-item → mutate → save-whole-item pair of SEPARATE
// `NoteStore` calls. The actor serializes each individual call but not the read-modify-write
// *transaction*, and `NotesModel` is `@MainActor` yet reentrant at every `await` — so two tasks
// could both load the same old item, apply different edits, and save in either order. The later
// whole-item save silently dropped the other's body, metadata or source blocks.
//
// Measured against the pre-fix code, the raw pattern lost 23 of 24 concurrent same-item appends.
// `NoteStore.withItem` closes it by making the transaction the unit of serialization: load, mutate
// and save run in ONE actor-isolated call with no suspension point between the read and the write.
//
// Everything here runs against a scratch `mktemp` store — never the owner's real Notes store
// (Prime Directive #1).

@Suite("W23.h2 — same-item edit transactions never lose an update")
struct NotesItemTransactionTests {

    // MARK: - Scratch fixtures

    private static func scratchRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-w23h2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func blankItem(id: UUID = UUID(),
                                  kind: Item.Kind = .note,
                                  title: String = "Note",
                                  body: String? = nil,
                                  blocks: [Block] = []) -> Item {
        Item(id: id, kind: kind, title: title, authors: [], date: nil, datePrecision: nil,
             dateUncertain: false, quality: nil, tags: [], zotero: [], roundup: false,
             created: Date(), modified: Date(), schema: 1, blocks: blocks,
             unknownFrontMatter: [], trailingBodyRaw: body)
    }

    // MARK: - The hazard, pinned

    /// The PRE-FIX pattern written out explicitly — two loads, two divergent edits, two saves. No race
    /// is needed: the interleaving is spelled by hand, so this is deterministic. The second whole-item
    /// save wins wholesale and the first edit is gone from disk with no error raised anywhere.
    ///
    /// It asserts the LOSS **on purpose.** This is the premise `withItem` exists to remove, so it fails
    /// loudly if anyone ever "simplifies" an edit path back to a `load` + `save` pair.
    @Test("PINNED HAZARD: a load…save pair silently drops the other edit (why withItem exists)")
    func rawLoadSavePairLosesAnUpdate() async throws {
        let root = try Self.scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteStore(root: root)
        let id = UUID()
        _ = try await store.create(Self.blankItem(id: id, body: "Original body."))

        // Both readers see the same old item — exactly what two awaits in two tasks produce.
        var a = try await store.load(id)
        var b = try await store.load(id)
        a.quality = 3                          // e.g. the metadata inspector
        b.trailingBodyRaw = "Edited body."     // e.g. the editor's autosave
        _ = try await store.save(a)
        _ = try await store.save(b)

        let onDisk = try await store.load(id)
        #expect(onDisk.trailingBodyRaw == "Edited body.")
        #expect(onDisk.quality == nil, "the quality edit is silently lost — the W23.h2 defect")
    }

    // MARK: - The primitive: contention on ONE item

    @Test("24 concurrent withItem transactions on one item ALL survive")
    func concurrentTransactionsNeverLoseAnUpdate() async throws {
        let root = try Self.scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteStore(root: root)
        let id = UUID()
        _ = try await store.create(Self.blankItem(id: id, body: ""))

        let n = 24
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<n {
                group.addTask {
                    _ = try? await store.withItem(id) { item in
                        item.trailingBodyRaw = (item.trailingBodyRaw ?? "") + "\(i);"
                    }
                }
            }
        }

        let final = try await store.load(id)
        let landed = Set((final.trailingBodyRaw ?? "").split(separator: ";").map(String.init))
        #expect(landed.count == n)
        for i in 0..<n { #expect(landed.contains("\(i)")) }
    }

    @Test("concurrent transactions on DIFFERENT fields of one item all compose")
    func concurrentFieldEditsCompose() async throws {
        let root = try Self.scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteStore(root: root)
        let id = UUID()
        _ = try await store.create(Self.blankItem(id: id, body: "body"))

        async let a: ItemTransaction? = try? store.withItem(id) { $0.quality = 4 }
        async let b: ItemTransaction? = try? store.withItem(id) { $0.date = "1968"; $0.datePrecision = .year }
        async let c: ItemTransaction? = try? store.withItem(id) { $0.dateUncertain = true }
        _ = await (a, b, c)

        let r = try await store.load(id)
        #expect(r.quality == 4)
        #expect(r.date == "1968")
        #expect(r.datePrecision == .year)
        #expect(r.dateUncertain)
        #expect(r.trailingBodyRaw == "body")
    }

    // MARK: - The primitive: what it returns, and how it fails

    @Test("withItem returns the item exactly as written, with a fresh ref")
    func returnsWrittenItemAndRef() async throws {
        let root = try Self.scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteStore(root: root)
        let id = UUID()
        _ = try await store.create(Self.blankItem(id: id, title: "Before", body: "old"))

        let tx = try await store.withItem(id) { $0.title = "After"; $0.trailingBodyRaw = "new" }
        #expect(tx.item.title == "After")
        #expect(tx.item.trailingBodyRaw == "new")
        #expect(tx.ref.id == id)
        // The title is a projection of the filename, so the rename landed too.
        #expect(tx.ref.url.lastPathComponent == "After.md")
        let onDisk = try await store.load(id)
        #expect(onDisk.title == tx.item.title)
        #expect(onDisk.trailingBodyRaw == tx.item.trailingBodyRaw)
    }

    @Test("withItem on a missing item throws notFound and writes nothing")
    func missingItemThrows() async throws {
        let root = try Self.scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteStore(root: root)
        let ghost = UUID()

        await #expect(throws: (any Error).self) {
            _ = try await store.withItem(ghost) { $0.quality = 1 }
        }
        let dir = NoteStore.itemDir(root: store.rootURL, id: ghost)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test("a throwing mutate aborts the transaction and leaves the .md untouched")
    func throwingMutateLeavesDiskUntouched() async throws {
        struct Boom: Error {}
        let root = try Self.scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteStore(root: root)
        let id = UUID()
        _ = try await store.create(Self.blankItem(id: id, title: "Keep", body: "pristine"))

        await #expect(throws: Boom.self) {
            _ = try await store.withItem(id) { item in
                item.trailingBodyRaw = "clobbered"
                throw Boom()
            }
        }
        let r = try await store.load(id)
        #expect(r.trailingBodyRaw == "pristine")
        #expect(r.title == "Keep")
    }

    @Test("withTemplate is atomic over the Templates container too")
    func templateTransactionsAreAtomic() async throws {
        let root = try Self.scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteStore(root: root)
        let id = UUID()
        _ = try await store.createTemplate(Self.blankItem(id: id, title: "T", body: ""))

        let n = 12
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<n {
                group.addTask {
                    _ = try? await store.withTemplate(id) { item in
                        item.trailingBodyRaw = (item.trailingBodyRaw ?? "") + "\(i);"
                    }
                }
            }
        }

        let final = try await store.loadTemplate(id)
        let landed = Set((final.trailingBodyRaw ?? "").split(separator: ";").map(String.init))
        #expect(landed.count == n)
    }

    // MARK: - The reachable paths (all three RED before the fix)
    //
    // These drive the races an operator can actually hit — two windows on one item; body autosave
    // racing a metadata edit; `ExtractBuilder.append` racing an ordinary mutation — through the real
    // `NotesModel` / `ExtractBuilder` entry points, not the primitive. Each assertion is
    // order-independent: whichever transaction lands second, BOTH edits must survive.

    private struct Env {
        let model: NotesModel
        let store: NoteStore
        let index: NotesIndex
        let root: URL
    }

    @MainActor
    private static func makeEnv() async throws -> Env {
        let root = try scratchRoot()
        let index = NotesIndex(url: root.appendingPathComponent("index.db"))
        try await index.open()
        let org = OrganizationStore(index: index)
        try await org.load(storeRoot: root)
        let store = NoteStore(root: root)
        return Env(model: NotesModel(organization: org, index: index, noteStore: store),
                   store: store, index: index, root: root)
    }

    private static func tearDown(_ env: Env) async {
        await env.index.close()
        try? FileManager.default.removeItem(at: env.root)
    }

    @Test("a body autosave racing a quality edit keeps BOTH edits")
    @MainActor
    func bodyEditRacingQualityEditKeepsBoth() async throws {
        let env = try await Self.makeEnv()
        let id = UUID()
        _ = try await env.store.create(Self.blankItem(id: id, body: "before"))

        async let bodyEdit: Void = env.model.setBody("after", for: id)
        async let qualityEdit: Void = env.model.setQuality(4, for: id)
        _ = await (bodyEdit, qualityEdit)

        let r = try await env.store.load(id)
        #expect(r.trailingBodyRaw == "after")
        #expect(r.quality == 4)
        await Self.tearDown(env)
    }

    @Test("a date edit racing a quality edit keeps BOTH fields")
    @MainActor
    func dateEditRacingQualityEditKeepsBoth() async throws {
        let env = try await Self.makeEnv()
        let id = UUID()
        _ = try await env.store.create(Self.blankItem(id: id))

        async let dateEdit: Void = env.model.setDate("1968-04-15", precision: .day, for: id)
        async let qualityEdit: Void = env.model.setQuality(2, for: id)
        _ = await (dateEdit, qualityEdit)

        let r = try await env.store.load(id)
        #expect(r.date == "1968-04-15")
        #expect(r.datePrecision == .day)
        #expect(r.quality == 2)
        await Self.tearDown(env)
    }

    @Test("an extract append racing a quality edit keeps the new block AND the quality")
    @MainActor
    func extractAppendRacingQualityEditKeepsBoth() async throws {
        let env = try await Self.makeEnv()
        let id = UUID()
        let first = Block(kind: .freeform, source: nil, markdown: "one", unknownHeaderFields: [])
        _ = try await env.store.create(Self.blankItem(id: id, kind: .extract, blocks: [first]))

        let builder = ExtractBuilder(store: env.store)
        let passage = ExtractPassageBlock(
            block: Block(kind: .freeform, source: nil, markdown: "two", unknownHeaderFields: []))

        async let appendEdit: Item = try builder.append(toExtract: id, passages: [passage])
        async let qualityEdit: Void = env.model.setQuality(3, for: id)
        _ = try await (appendEdit, qualityEdit)

        let r = try await env.store.load(id)
        #expect(r.blocks.count == 2)
        #expect(r.blocks.last?.markdown.contains("two") == true)
        #expect(r.quality == 3)
        await Self.tearDown(env)
    }

    /// Hoisting the asset copies OUT of the transaction must not lose `append`'s fail-fast contract: a
    /// bad id still throws *before* any asset byte is written, so it can't leave a phantom
    /// `items/<uuid>/assets/` with no `.md` (which `allItemIDs` would list but `allItemRefs` would skip).
    /// This is the test that locks in the pre-flight `mdURL` probe.
    @Test("append to a MISSING extract writes no asset bytes and leaves no phantom dir")
    @MainActor
    func appendToMissingExtractWritesNothing() async throws {
        let env = try await Self.makeEnv()
        let ghost = UUID()
        let incoming = ExtractPassageBlock(
            block: Block(kind: .notePassage, source: nil, markdown: "Orphan.", unknownHeaderFields: []),
            pendingAssets: ["shot.png": Data([0x89, 0x50, 0x4E, 0x47])])

        await #expect(throws: (any Error).self) {
            _ = try await ExtractBuilder(store: env.store).append(toExtract: ghost, passages: [incoming])
        }

        let dir = NoteStore.itemDir(root: env.store.rootURL, id: ghost)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        await Self.tearDown(env)
    }
}
