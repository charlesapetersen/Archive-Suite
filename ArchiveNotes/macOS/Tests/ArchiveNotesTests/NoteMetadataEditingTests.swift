import Foundation
import Testing
import AppKit
import ArchiveCore
@testable import ArchiveNotes

/// Extends the audited projector safety suite through the real model/store editing path.
@MainActor
extension NotesTagProjectorSafetyTests {
    private struct MetadataEnv {
        let root: URL
        let store: NoteStore
        let model: NotesModel
        let index: NotesIndex
        let id: UUID
    }

    private func withMetadataScratch(_ test: (MetadataEnv) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-metadata-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = NotesIndex(url: root.appendingPathComponent("index.db"))
        try await index.open()
        let org = OrganizationStore(index: index)
        try await org.load(storeRoot: root)
        let store = NoteStore(root: root)
        let model = NotesModel(organization: org, index: index, noteStore: store)
        let item = Item(id: UUID(), kind: .note, title: "Original", authors: ["Keep Author"], date: nil,
                        datePrecision: nil, dateUncertain: false, quality: nil, tags: [], zotero: [],
                        roundup: false, created: Date(), modified: Date(), schema: 1, blocks: [],
                        unknownFrontMatter: [], trailingBodyRaw: "Keep body\n")
        _ = try await store.create(item)
        do {
            try await test(MetadataEnv(root: root, store: store, model: model, index: index, id: item.id))
            await index.close()
            try FileManager.default.removeItem(at: root)
        } catch {
            await index.close()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func metadataTags(_ env: MetadataEnv) async throws -> Set<String> {
        let url = try await env.store.mdURL(for: env.id)
        return Set(try url.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? [])
    }

    @Test("rename preserves UUID, body, subjects, third-party Finder tags and label")
    func renameRetainsSubjects() async throws {
        try await withMetadataScratch { env in
            #expect(await env.model.setTags([" history ", "History", "economics"], to: env.id))
            let before = try await env.store.mdURL(for: env.id)
            try (before as NSURL).setResourceValue(["History", "Economics", "Do Not Sync"], forKey: .tagNamesKey)
            try (before as NSURL).setResourceValue(6, forKey: .labelNumberKey)
            #expect(await env.model.renameNote(env.id, to: "  Renamed Note  "))
            let after = try await env.store.mdURL(for: env.id)
            #expect(after.lastPathComponent == "Renamed Note.md")
            #expect(after.deletingLastPathComponent() == before.deletingLastPathComponent())
            #expect(!FileManager.default.fileExists(atPath: before.path))
            #expect(try await metadataTags(env) == ["History", "Economics", "Do Not Sync"])
            #expect(try after.resourceValues(forKeys: [.labelNumberKey]).labelNumber == 6)
            let saved = try await env.store.load(env.id)
            #expect(saved.title == "Renamed Note" && saved.id == env.id)
            #expect(saved.trailingBodyRaw == "Keep body\n" && saved.authors == ["Keep Author"])
            #expect(env.model.allItems.first(where: { $0.id == env.id })?.title == "Renamed Note")
            #expect(await env.model.renameNote(env.id, to: " \n ") == false)
            #expect(try await env.store.load(env.id) == saved, "blank title is a no-write")
        }
    }

    @Test("subject replacement removes old subjects, not current facets or unrelated tags")
    func subjectEditsRespectFacets() async throws {
        try await withMetadataScratch { env in
            await env.model.setDate("1968", precision: .year, for: env.id)
            await env.model.setQuality(2, for: env.id)
            #expect(await env.model.setTags(["1968", "Q2", "old subject"], to: env.id))
            let url = try await env.store.mdURL(for: env.id)
            let tags = try url.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
            try (url as NSURL).setResourceValue(tags + ["Unrelated"], forKey: .tagNamesKey)
            #expect(await env.model.setTags(["new subject", "new subject", ""], to: env.id))
            #expect(try await metadataTags(env) == ["New Subject", "1968", "Q2", "Unrelated"])
            #expect(try await env.store.load(env.id).tags == ["New Subject"])
            await env.model.setDate(nil, precision: nil, for: env.id)
            await env.model.setQuality(nil, for: env.id)
            #expect(try await metadataTags(env) == ["New Subject", "Unrelated"], "date ownership was retained")
            #expect(await env.model.removeTag("New Subject", from: env.id))
            #expect(try await metadataTags(env) == ["Unrelated"])
        }
    }

    @Test("projection failure retains removal ownership across restart and identical retry")
    func subjectProjectionRetry() async throws {
        try await withMetadataScratch { env in
            #expect(await env.model.setTags(["Old Subject"], to: env.id))
            let tx = try await env.store.withItem(env.id, projectSubjects: { _, _, _ in
                throw NoteStore.StoreError.writeFailed("injected projector failure")
            }) { $0.tags = ["New Subject"] }
            #expect(tx.subjectProjectionError != nil)
            #expect(try await metadataTags(env) == ["Old Subject"])
            #expect(try await env.store.load(env.id).tags == ["New Subject"])
            let reopened = NoteStore(root: env.root)
            let org = OrganizationStore(index: env.index)
            try await org.load(storeRoot: env.root)
            let model = NotesModel(organization: org, index: env.index, noteStore: reopened)
            #expect(await model.setTags(["New Subject"], to: env.id))
            #expect(try await metadataTags(env) == ["New Subject"])
        }
    }

    @Test("removing a subject transfers its matching date token to date ownership")
    func subjectBecomesDateFacet() async throws {
        try await withMetadataScratch { env in
            #expect(await env.model.setTags(["1968"], to: env.id))
            await env.model.setDate("1968", precision: .year, for: env.id)
            #expect(await env.model.setTags([], to: env.id))
            #expect(try await metadataTags(env) == ["1968"])
            await env.model.setDate(nil, precision: nil, for: env.id)
            let finalTags = try await metadataTags(env)
            #expect(finalTags.isEmpty)
        }
    }

    @Test("manual author edits persist, update FTS, and stay independent between notes and extracts")
    func authorEditsPersistAndIndexIndependently() async throws {
        try await withMetadataScratch { env in
            #expect(await env.model.setAuthors([" Ada Lovelace ", "", "Grace Hopper "], for: env.id))
            let note = try await env.store.load(env.id)
            #expect(note.authors == ["Ada Lovelace", "Grace Hopper"])
            #expect(await env.index.search("Lovelace") == [env.id])
            #expect(try await metadataTags(env).isEmpty, "authors remain front-matter only")

            var extract = note
            extract.id = UUID()
            extract.kind = .extract
            extract.title = "Independent extract"
            extract.authors = ["Extract Original"]
            _ = try await env.store.create(extract)

            #expect(await env.model.setAuthors(["  ExtractAuthorMarker  "], for: extract.id))
            #expect(try await env.store.load(extract.id).authors == ["ExtractAuthorMarker"])
            #expect(try await env.store.load(env.id).authors == ["Ada Lovelace", "Grace Hopper"])
            #expect(await env.index.search("ExtractAuthorMarker") == [extract.id])

            #expect(await env.model.setAuthors(["  ", "\n"], for: extract.id))
            #expect(try await env.store.load(extract.id).authors.isEmpty)
            #expect(await env.index.search("ExtractAuthorMarker").isEmpty)
        }
    }

    @Test("Copy Link writes the selected note or extract as a plain-text deep link")
    func copyOpenLinkWritesPlainTextURL() async throws {
        try await withMetadataScratch { env in
            let pasteboard = NSPasteboard(name: .init("notes-link-test-\(UUID().uuidString)"))
            #expect(pasteboard.setString("old clipboard value", forType: .string))

            #expect(env.model.copyOpenLink(for: env.id, to: pasteboard))
            let raw = try #require(pasteboard.string(forType: .string))
            let url = try #require(URL(string: raw))
            #expect(DurableLink(url: url) == .notesOpen(id: env.id, block: nil))
            #expect(pasteboard.string(forType: .string) == raw)
            #expect(env.model.statusMessage == "Copied Notes link.")

            let router = NotesDeepLinkRouter()
            router.handle(url)
            #expect(router.forwardPendingOpen(whenIndexReady: true) { request in
                env.model.openItem(id: request.id, block: request.block)
            })
            #expect(env.model.pendingOpen?.id == env.id && env.model.pendingOpen?.block == nil)

            var extract = try await env.store.load(env.id)
            extract.id = UUID()
            extract.kind = .extract
            extract.title = "Extract link target"
            _ = try await env.store.create(extract)
            #expect(env.model.copyOpenLink(for: extract.id, to: pasteboard))
            let extractRaw = try #require(pasteboard.string(forType: .string))
            let extractURL = try #require(URL(string: extractRaw))
            #expect(DurableLink(url: extractURL) == .notesOpen(id: extract.id, block: nil))
        }
    }

    @Test("removing a manually entered padded subject removes its original Finder token")
    func removePaddedSubject() async throws {
        try await withMetadataScratch { env in
            _ = try await env.store.withItem(env.id) { $0.tags = [" history "] }
            let url = try await env.store.mdURL(for: env.id)
            try (url as NSURL).setResourceValue([NotesTagVocabulary.titleCased(" history ")], forKey: .tagNamesKey)
            #expect(await env.model.removeTag(" history ", from: env.id))
            let finalItem = try await env.store.load(env.id)
            let finalTags = try await metadataTags(env)
            #expect(finalItem.tags.isEmpty)
            #expect(finalTags.isEmpty)
        }
    }

    @Test("concurrent subject deltas, rename, and body saves retain every independent edit")
    func concurrentMetadataEdits() async throws {
        try await withMetadataScratch { env in
            async let first = env.model.addTag("First", to: env.id)
            async let second = env.model.addTag("Second", to: env.id)
            async let rename = env.model.renameNote(env.id, to: "Concurrent Title")
            async let body: Void = env.model.setBody("Concurrent body\n", for: env.id)
            async let authors = env.model.setAuthors(["Concurrent Author"], for: env.id)
            let results = await (first, second, rename, body, authors)
            #expect(results.0 && results.1 && results.2 && results.4)
            let item = try await env.store.load(env.id)
            #expect(Set(item.tags) == ["First", "Second"] && item.authors == ["Concurrent Author"])
            #expect(item.title == "Concurrent Title" && item.trailingBodyRaw == "Concurrent body\n")
            #expect(try await metadataTags(env) == ["First", "Second"])
        }
    }
}
