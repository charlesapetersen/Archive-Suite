import Testing
import Foundation
@testable import ArchiveNotes
import ArchiveCore

// W19.q4 + W49.storage-finder-drop-mirror — the quality write path. `NotesModel.setQuality` persists
// the authoritative front-matter `quality` value on the canonical 0...3 scale and updates the index,
// without writing or disturbing Finder tags on the `.md` file. Every test runs on a scratch `mktemp`
// store (Prime Directive #1 — never a real corpus).

@Suite("QualityWrite — front-matter authority (no Finder-tag mirror)")
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
        let item = Item(id: UUID(), kind: .note, title: "Note", date: nil,
                        datePrecision: nil, dateUncertain: false, quality: nil, tags: tags, zotero: [],
                        roundup: false, created: Date(), modified: Date(), schema: 1, blocks: [],
                        unknownFrontMatter: [], trailingBodyRaw: nil)
        _ = try await env.store.create(item)
        return item.id
    }

    /// The macOS Finder tags currently on the item's own `.md` file (empty when none).
    private func finderTags(_ env: Env, _ id: UUID) async throws -> [String] {
        let url = try await env.store.mdURL(for: id)
        let values = try url.resourceValues(forKeys: [.tagNamesKey])
        return values.tagNames ?? []
    }

    private func finderLabel(_ env: Env, _ id: UUID) async throws -> Int? {
        let url = try await env.store.mdURL(for: id)
        return try url.resourceValues(forKeys: [.labelNumberKey]).labelNumber
    }

    @Test("setQuality writes canonical front-matter quality + re-indexes without writing Finder tags")
    func writesQuality() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try await makeNote(env)
        await env.model.setQuality(3, for: id)
        let r = try await env.store.load(id)
        #expect(r.quality == 3)
        let s = await env.index.summary(for: id)
        #expect(s?.quality == 3)
        #expect(s?.qualityStars == "★★★")
        #expect(try await finderTags(env, id).isEmpty)
    }

    @Test("setQuality leaves existing Finder tags and labels untouched, and Q0 clears front-matter quality")
    func leavesFinderTagsAndLabelUntouched() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try await makeNote(env, tags: ["history"])
        let url = try await env.store.mdURL(for: id)
        try (url as NSURL).setResourceValue(["Do Not Sync"], forKey: .tagNamesKey)
        try (url as NSURL).setResourceValue(6, forKey: .labelNumberKey)

        await env.model.setQuality(3, for: id)
        #expect(try await env.store.load(id).quality == 3)
        #expect(Set(try await finderTags(env, id)) == ["Do Not Sync"])
        #expect(try await finderLabel(env, id) == 6, "a quality edit must not drift the Finder label")

        // 0 is the human unrated value: it clears the front-matter field.
        await env.model.setQuality(0, for: id)
        #expect(try await env.store.load(id).quality == nil)
        #expect(Set(try await finderTags(env, id)) == ["Do Not Sync"])
        #expect(try await finderLabel(env, id) == 6, "clearing Quality must not drift the Finder label")
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

    @Test("editing quality preserves the rest of the front-matter + body")
    func preservesOtherFields() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let item = Item(id: UUID(), kind: .note, title: "Keep Me", date: "1968",
                        datePrecision: .year, dateUncertain: true, quality: nil, tags: ["Subject"],
                        zotero: [], roundup: false, created: Date(), modified: Date(), schema: 1,
                        blocks: [], unknownFrontMatter: [], trailingBodyRaw: "Body text")
        _ = try await env.store.create(item)
        await env.model.setQuality(3, for: item.id)
        let r = try await env.store.load(item.id)
        #expect(r.quality == 3)
        #expect(r.title == "Keep Me")
        #expect(r.date == "1968" && r.datePrecision == .year && r.dateUncertain == true)
        #expect(r.tags == ["Subject"])
        #expect(r.trailingBodyRaw == "Body text")
    }

    @Test("out-of-range ratings normalize to unrated")
    func normalizesInvalidRangeToUnrated() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try await makeNote(env)
        await env.model.setQuality(9, for: id)
        #expect(try await env.store.load(id).quality == nil)
        #expect(try await finderTags(env, id).isEmpty)
    }

    @Test("a subject spelled ArchiveSuite survives a body save in front matter without writing Finder tags")
    func archiveSuiteSubjectSurvivesBodySave() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try await makeNote(env)

        #expect(await env.model.setTags(["ArchiveSuite"], to: id))
        await env.model.setBody("edited", for: id)

        #expect(try await env.store.load(id).tags == ["ArchiveSuite"])
        #expect(try await finderTags(env, id).isEmpty)

        #expect(await env.model.removeTag("ArchiveSuite", from: id))
        #expect(try await env.store.load(id).tags.isEmpty)
        #expect(try await finderTags(env, id).isEmpty)
    }
}
