import Testing
import Foundation
@testable import ArchiveNotes

// W7-S1a — the note-body load/save path on `NotesModel` (`loadBody`/`setBody`). Drives it against a
// scratch `mktemp` store (Prime Directive #1 — never a real corpus) and asserts: the body round-trips
// byte-stably through serialize→parse→serialize; a source block keeps its provenance; a body edit
// persists AND re-indexes the FTS body; and a body edit never disturbs the item's front-matter
// (title/date/quality) — the write goes only through the audited `mutateItem` path (atomic .md + one-row
// re-index), so it can't corrupt metadata or touch the archival corpus.

@Suite("NotesModel body load/save — round-trip + front-matter safety")
@MainActor
struct NotesModelBodyTests {

    struct Env { let model: NotesModel; let store: NoteStore; let index: NotesIndex; let root: URL }

    private func makeEnv() async throws -> Env {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-bodywrite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = NotesIndex(url: root.appendingPathComponent("index.db"))
        try await index.open()
        let org = OrganizationStore(index: index)
        try await org.load(storeRoot: root)
        let store = NoteStore(root: root)
        let model = NotesModel(organization: org, index: index, noteStore: store)
        return Env(model: model, store: store, index: index, root: root)
    }

    private func cleanup(_ env: Env) async {
        await env.index.close()
        try? FileManager.default.removeItem(at: env.root)
    }

    @discardableResult
    private func makeNote(_ env: Env, title: String = "Note",
                          body: String? = nil, blocks: [Block] = []) async throws -> UUID {
        let item = Item(id: UUID(), kind: .note, title: title, authors: [], date: nil,
                        datePrecision: nil, dateUncertain: false, quality: nil, tags: [], zotero: [],
                        roundup: false, created: Date(), modified: Date(), schema: 1, blocks: blocks,
                        unknownFrontMatter: [], trailingBodyRaw: body)
        _ = try await env.store.create(item)
        return item.id
    }

    @Test("plain prose body round-trips idempotently through load→save→load")
    func plainBodyRoundTrip() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try await makeNote(env, body: "Hello world.")

        let md0 = await env.model.loadBody(for: id)
        #expect(md0 == "Hello world.")

        await env.model.setBody(md0 ?? "", for: id)
        let md1 = await env.model.loadBody(for: id)
        #expect(md1 == md0)

        let reloaded = try await env.store.load(id)
        #expect(reloaded.blocks.isEmpty)
        #expect(reloaded.trailingBodyRaw == "Hello world.")
    }

    @Test("a source block survives the body round-trip with its provenance intact")
    func sourceBlockRoundTrip() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let src = UUID()
        let md = """
        Intro prose.

        <!-- block: note-passage
             note: archivenotes://open?id=\(src.uuidString)#block-0
             display: "Src — 1968" -->
        Snapshotted passage text.
        """
        let id = try await makeNote(env)
        await env.model.setBody(md, for: id)

        let reloaded = try await env.store.load(id)
        #expect(reloaded.blocks.count == 1)
        #expect(reloaded.blocks.first?.kind == .notePassage)
        #expect(reloaded.blocks.first?.source?.noteRef?.contains("#block-0") == true)
        #expect(reloaded.blocks.first?.markdown.contains("Snapshotted passage text.") == true)

        // load→(already saved)→load is byte-stable (canonical header re-emit).
        let md1 = await env.model.loadBody(for: id)
        await env.model.setBody(md1 ?? "", for: id)
        let md2 = await env.model.loadBody(for: id)
        #expect(md2 == md1)
    }

    @Test("a body edit persists and re-indexes the FTS body")
    func bodyEditPersistsAndReindexes() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try await makeNote(env)
        await env.model.setBody("Body with zqxphrase inside.", for: id)

        let reloaded = try await env.store.load(id)
        #expect(reloaded.trailingBodyRaw?.contains("zqxphrase") == true)
        #expect(await env.index.search("zqxphrase").contains(id))
    }

    @Test("a body edit never disturbs the item's front-matter (title/date/quality)")
    func bodyEditPreservesFrontMatter() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try await makeNote(env, title: "Keep Me")
        await env.model.setDate("1968", precision: .year, for: id)
        await env.model.setQuality(4, for: id)

        await env.model.setBody("A totally new body.", for: id)

        let r = try await env.store.load(id)
        #expect(r.title == "Keep Me")
        #expect(r.date == "1968")
        #expect(r.datePrecision == .year)
        #expect(r.quality == 4)
        #expect(r.dateUncertain == false)
        #expect(r.trailingBodyRaw == "A totally new body.")
    }

    @Test("empty body round-trips to an empty document")
    func emptyBodyRoundTrip() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try await makeNote(env, body: "seed")
        await env.model.setBody("", for: id)
        let r = try await env.store.load(id)
        #expect(r.blocks.isEmpty)
        #expect((r.trailingBodyRaw ?? "").isEmpty)
        #expect(await env.model.loadBody(for: id) == "")
    }

    @Test("loadBody for an unknown id returns nil (no crash)")
    func loadBodyUnknownIdNil() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        #expect(await env.model.loadBody(for: UUID()) == nil)
    }
}
