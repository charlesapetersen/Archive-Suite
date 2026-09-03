import Testing
import Foundation
@testable import ArchiveNotes
import ArchiveCore

// W19.q4 — the quality write path. `NotesModel.setQuality` persists the authoritative front-matter
// `quality` value on the canonical 0...3 scale, then projects a matching Q1/Q2/Q3 Finder tag onto the
// note's OWN `.md` file. Q0/unrated writes no quality token. Every test runs on a scratch `mktemp`
// store (Prime Directive #1 — never a real corpus).

@Suite("QualityWrite — front-matter authority + canonical Q mirror")
@MainActor
struct QualityWriteTests {

    /// Holds the first setQuality call after its atomic front-matter save. The second call passes
    /// through, letting the test force the real stale-projection recovery instead of trusting task
    /// scheduling to happen to interleave that way.
    private actor FirstProjectionGate {
        private var calls = 0
        private var firstReached = false
        private var firstReachedWaiter: CheckedContinuation<Void, Never>?
        private var releaseFirstWaiter: CheckedContinuation<Void, Never>?

        func pauseFirstOnly() async {
            calls += 1
            guard calls == 1 else { return }
            firstReached = true
            firstReachedWaiter?.resume()
            firstReachedWaiter = nil
            await withCheckedContinuation { releaseFirstWaiter = $0 }
        }

        func waitUntilFirstReached() async {
            guard !firstReached else { return }
            await withCheckedContinuation { firstReachedWaiter = $0 }
        }

        func releaseFirst() {
            releaseFirstWaiter?.resume()
            releaseFirstWaiter = nil
        }
    }

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

    @Test("setQuality writes canonical front-matter quality + re-indexes")
    func writesQuality() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try await makeNote(env)
        await env.model.setQuality(3, for: id)
        let r = try await env.store.load(id)
        #expect(r.quality == 3)
        let s = await env.index.summary(for: id)
        #expect(s?.quality == 3)
        #expect(s?.qualityStars == "★★★")
        #expect(try await finderTags(env, id).contains("Q3"))
    }

    @Test("setQuality replaces stale Q, preserves unrelated Finder tags, and Q0 clears")
    func projectsCanonicalQualityTagLosslessly() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try await makeNote(env, tags: ["history"])
        let url = try await env.store.mdURL(for: id)
        try (url as NSURL).setResourceValue(["History", "Q1", "Do Not Sync"], forKey: .tagNamesKey)
        try (url as NSURL).setResourceValue(6, forKey: .labelNumberKey)

        await env.model.setQuality(3, for: id)
        #expect(try await env.store.load(id).quality == 3)
        #expect(Set(try await finderTags(env, id)) == ["History", "Q3", "Do Not Sync"])
        #expect(try await finderLabel(env, id) == 6, "a quality edit must not drift the Finder label")

        // 0 is the human unrated value: it clears the front-matter field and writes no Q token.
        await env.model.setQuality(0, for: id)
        #expect(try await env.store.load(id).quality == nil)
        #expect(Set(try await finderTags(env, id)) == ["History", "Do Not Sync"])
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
        #expect(!Set(try await finderTags(env, id)).contains(where: { ["Q1", "Q2", "Q3"].contains($0) }))
    }

    @Test("editing quality preserves the rest of the front-matter + body")
    func preservesOtherFields() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let item = Item(id: UUID(), kind: .note, title: "Keep Me", authors: ["A. Author"], date: "1968",
                        datePrecision: .year, dateUncertain: true, quality: nil, tags: ["Subject"],
                        zotero: [], roundup: false, created: Date(), modified: Date(), schema: 1,
                        blocks: [], unknownFrontMatter: [], trailingBodyRaw: "Body text")
        _ = try await env.store.create(item)
        await env.model.setQuality(3, for: item.id)
        let r = try await env.store.load(item.id)
        #expect(r.quality == 3)                       // the one field we changed…
        #expect(r.title == "Keep Me")                 // …and everything else round-trips untouched
        #expect(r.authors == ["A. Author"])
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
        #expect(!Set(try await finderTags(env, id)).contains(where: { ["Q1", "Q2", "Q3"].contains($0) }))
    }

    @Test("a stale NoteStore revision cannot overwrite a newer quality projection")
    func staleRevisionCannotOverwriteNewerQuality() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try await makeNote(env)
        let first = try await env.store.withItem(id) { item in
            item.quality = 1
            item.modified = Date()
        }
        let second = try await env.store.withItem(id) { item in
            item.quality = 3
            item.modified = Date()
        }
        let url = second.ref.url
        let itemDir = url.deletingLastPathComponent()

        // Pin the scheduling that would otherwise be nondeterministic: the Q1 save completes,
        // Q3 replaces it and projects, then Q1's now-stale actor revision is refused before its
        // closure can reach Finder metadata. This stays valid on filesystems where `replaceItemAt`
        // preserves the file-resource identifier, so it does not rely on a fragile inode change.
        let currentProjection = try await env.store.performIfCurrent(second.ref) { ref in
            _ = try NotesTagProjector.project(
                NotesTagVocabulary.facetProjectionTokens(for: second.item),
                previouslyManaged: NotesTagVocabulary.qualityTokens,
                to: url,
                itemDir: itemDir,
                orderedFacetTokens: NotesTagVocabulary.dateFacetTokens(for: second.item)
                    + (NotesTagVocabulary.qualityToken(for: second.item.quality).map { [$0] } ?? []),
                expectedIdentity: ref.identity)
        }
        #expect(currentProjection)
        let tagsBeforeStaleAttempt = try await finderTags(env, id)

        let staleProjection = try await env.store.performIfCurrent(first.ref) { ref in
            _ = try NotesTagProjector.project(
                NotesTagVocabulary.facetProjectionTokens(for: first.item),
                previouslyManaged: NotesTagVocabulary.qualityTokens,
                to: url,
                itemDir: itemDir,
                orderedFacetTokens: NotesTagVocabulary.dateFacetTokens(for: first.item)
                    + (NotesTagVocabulary.qualityToken(for: first.item.quality).map { [$0] } ?? []),
                expectedIdentity: ref.identity)
        }
        #expect(!staleProjection, "the old revision must not enter the metadata write closure")

        let item = try await env.store.load(id)
        let tags = Set(try await finderTags(env, id))
        #expect(item.quality == 3)
        #expect(tagsBeforeStaleAttempt == ["Q3"])
        #expect(tags.intersection(NotesTagVocabulary.qualityTokens) == ["Q3"])
    }

    @Test("a rejected stale projection refreshes the index and live item list")
    func staleProjectionRefreshesIndexAndLiveList() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try await makeNote(env)
        let gate = FirstProjectionGate()
        env.model.qualityProjectionTestHook = { _ in await gate.pauseFirstOnly() }
        defer { env.model.qualityProjectionTestHook = nil }

        let first = Task { @MainActor in
            await env.model.setQuality(1, for: id)
        }
        await gate.waitUntilFirstReached()

        // Q3 commits and projects while Q1 is paused after its save. Once Q1 resumes, its stale actor
        // revision must reconcile/index Q3 rather than re-upserting its stale ItemTransaction.
        await env.model.setQuality(3, for: id)
        let tagsAfterCurrentWrite = try await finderTags(env, id)
        #expect(Set(tagsAfterCurrentWrite).intersection(NotesTagVocabulary.qualityTokens) == ["Q3"],
                "the current Q3 edit must project before the paused Q1 resumes; got \(tagsAfterCurrentWrite)")
        await gate.releaseFirst()
        await first.value

        #expect(try await env.store.load(id).quality == 3)
        let liveTags = try await finderTags(env, id)
        #expect(Set(liveTags).intersection(NotesTagVocabulary.qualityTokens) == ["Q3"],
                "expected Q3 after stale recovery, got raw tags \(liveTags)")
        #expect(await env.index.summary(for: id)?.quality == 3)
        #expect(env.model.allItems.first(where: { $0.id == id })?.quality == 3)
    }

    @Test("a body save that overtakes Quality still leaves the current Q facet")
    func bodySaveOvertakingQualityReconcilesCurrentFacet() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try await makeNote(env)
        let gate = FirstProjectionGate()
        env.model.qualityProjectionTestHook = { _ in await gate.pauseFirstOnly() }
        defer { env.model.qualityProjectionTestHook = nil }

        let quality = Task { @MainActor in
            await env.model.setQuality(3, for: id)
        }
        await gate.waitUntilFirstReached()

        // This normal non-Quality edit replaces the just-saved Q3 front matter before the delayed
        // Quality projection starts. It must reconcile the current Q3 itself; once the first task
        // resumes, its stale actor revision must also reconcile that same current revision.
        await env.model.setBody("New body", for: id)
        await gate.releaseFirst()
        await quality.value

        #expect(try await env.store.load(id).quality == 3)
        #expect(try await env.store.load(id).trailingBodyRaw == "New body")
        #expect(Set(try await finderTags(env, id)).intersection(NotesTagVocabulary.qualityTokens) == ["Q3"])
        #expect(await env.index.summary(for: id)?.quality == 3)
        #expect(env.model.allItems.first(where: { $0.id == id })?.quality == 3)
    }

    @Test("Q-looking subjects survive while the intended Quality token remains last")
    func qLookingSubjectsCannotOverrideQualityFacet() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try await makeNote(env, tags: ["Q1", "Q2", "Q3", "History"])

        await env.model.setQuality(2, for: id)

        let raw = try await finderTags(env, id)
        #expect(Set(raw) == ["Q1", "Q2", "Q3"],
                "literal Q-looking subjects remain lossless")
        #expect(raw.last == "Q2", "the authoritative Q2 must be last for ArchiveCore parsing")
        #expect(DocumentTags.parse(raw: raw, labelNumber: nil).quality == 2)
    }
}
