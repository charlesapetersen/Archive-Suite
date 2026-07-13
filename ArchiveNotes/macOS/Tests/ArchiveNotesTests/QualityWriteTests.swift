import Testing
import Foundation
@testable import ArchiveNotes

// W6-S7 — the quality write path. `NotesModel.setQuality` writes the front-matter `quality` key ONLY
// (priority-style, 1…5, 5 highest; nil = None) — 00-overview D9. The CRITICAL invariant this suite
// guards: quality is NEVER mirrored to a macOS Finder tag (that is the one place an implementer could
// wrongly reach for `NotesTagProjector`). Every test runs on a scratch `mktemp` store (Prime Directive
// #1 — never a real corpus) and, after the write, asserts the item's `.md` file carries no Finder tags.

@Suite("QualityWrite — front-matter only, never a Finder tag")
@MainActor
struct QualityWriteTests {

    struct Env { let model: NotesModel; let store: NoteStore; let index: NotesIndex; let root: URL }

    private func makeEnv() async throws -> Env {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-qualwrite-\(UUID().uuidString)", isDirectory: true)
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
    private func makeNote(_ env: Env, tags: [String] = []) async throws -> UUID {
        let item = Item(id: UUID(), kind: .note, title: "Note", authors: [], date: nil,
                        datePrecision: nil, dateUncertain: false, quality: nil, tags: tags, zotero: [],
                        roundup: false, created: Date(), modified: Date(), schema: 1, blocks: [],
                        unknownFrontMatter: [], trailingBodyRaw: nil)
        _ = try await env.store.create(item)
        return item.id
    }

    /// The macOS Finder tags currently on the item's `.md` file (empty when none). This is exactly the
    /// surface D2/D9 forbids the quality write from touching.
    private func finderTags(_ env: Env, _ id: UUID) async throws -> [String] {
        let url = try await env.store.mdURL(for: id)
        let values = try url.resourceValues(forKeys: [.tagNamesKey])
        return values.tagNames ?? []
    }

    @Test("setQuality writes the front-matter quality key + re-indexes")
    func writesQuality() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try await makeNote(env)
        await env.model.setQuality(4, for: id)
        let r = try await env.store.load(id)
        #expect(r.quality == 4)
        let s = await env.index.summary(for: id)
        #expect(s?.quality == 4)
        #expect(s?.qualityStars == "★★★★☆")
    }

    @Test("setQuality does NOT mutate any Finder tag (D2/D9)")
    func neverWritesFinderTag() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try await makeNote(env)
        #expect(try await finderTags(env, id).isEmpty)     // baseline: bare item has none
        await env.model.setQuality(5, for: id)
        // The front-matter carries the rating…
        #expect(try await env.store.load(id).quality == 5)
        // …and the file still has ZERO Finder tags — quality was never mirrored to the tag namespace.
        #expect(try await finderTags(env, id).isEmpty)
    }

    @Test("nil clears the rating (None); stars render as —")
    func clearQuality() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try await makeNote(env)
        await env.model.setQuality(3, for: id)
        await env.model.setQuality(nil, for: id)
        let r = try await env.store.load(id)
        #expect(r.quality == nil)
        #expect(await env.index.summary(for: id)?.qualityStars == "—")
        #expect(try await finderTags(env, id).isEmpty)
    }

    @Test("out-of-range ratings clamp into 1…5")
    func clampsRange() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try await makeNote(env)
        await env.model.setQuality(9, for: id)
        #expect(try await env.store.load(id).quality == 5)
        await env.model.setQuality(0, for: id)
        #expect(try await env.store.load(id).quality == 1)
    }
}
