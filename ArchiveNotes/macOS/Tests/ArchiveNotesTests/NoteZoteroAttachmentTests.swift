import Foundation
import Testing
@testable import ArchiveNotes

@Suite("Note-level Zotero attachment — audited scratch transactions")
@MainActor
struct NoteZoteroAttachmentTests {
    private func withScratch(_ body: (NotesModel, NoteStore, Item) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteZoteroAttachment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = NotesIndex(url: root.appendingPathComponent("index.sqlite"))
        try await index.open()
        let organization = OrganizationStore(index: index)
        try await organization.load(storeRoot: root)
        let store = NoteStore(root: root)
        let model = NotesModel(organization: organization, index: index, noteStore: store)
        defer { Task { await index.close(); try? FileManager.default.removeItem(at: root) } }
        let item = Item(id: UUID(), kind: .note, title: "Keep title", authors: ["Keep author"],
                        date: nil, datePrecision: nil, dateUncertain: false, quality: nil, tags: [],
                        zotero: [], roundup: false, created: Date(), modified: Date(), schema: 1,
                        blocks: [], unknownFrontMatter: [], trailingBodyRaw: "Keep body\n")
        _ = try await store.create(item)
        try await body(model, store, item)
    }

    @Test("attach is canonical, duplicate-safe, and preserves note content")
    func attachment() async throws {
        try await withScratch { model, store, item in
            let ref = try #require(ZoteroSelectLink.parse("zotero://select/items/1_NOTE1234"))
            async let first = model.attachZoteroReference(ref, to: item.id)
            async let duplicate = model.attachZoteroReference(ref, to: item.id)
            let results = await (first, duplicate)
            #expect(results.0 && results.1)
            let saved = try await store.load(item.id)
            #expect(saved.zotero == [ref])
            #expect(saved.title == item.title && saved.authors == item.authors)
            #expect(saved.trailingBodyRaw == item.trailingBodyRaw)
            #expect(saved.blocks.isEmpty)
            #expect(model.allItems.contains(where: { $0.id == item.id }))
            let invalid = ZoteroRef(selectLink: "https://example.com", itemKey: "NOTE1234", library: .user)
            #expect(await model.attachZoteroReference(invalid, to: item.id) == false)
            #expect(try await store.load(item.id) == saved)
        }
    }

    @Test("citation save preserves later body edits; reattach and stale response preserve new citation")
    func citationRace() async throws {
        try await withScratch { model, store, item in
            let ref = try #require(ZoteroSelectLink.parse("zotero://select/library/items/NOTE1234"))
            #expect(await model.attachZoteroReference(ref, to: item.id))
            _ = try await store.withItem(item.id) { $0.trailingBodyRaw = "Concurrent body\n" }
            #expect(await model.cacheZoteroCitation("First citation", for: ref, in: item.id))
            let first = try await store.load(item.id)
            #expect(first.zotero.first?.citation == "First citation")
            #expect(first.zotero.first?.fetchedAt != nil)
            #expect(first.trailingBodyRaw == "Concurrent body\n")
            #expect(await model.attachZoteroReference(ref, to: item.id))
            #expect(await model.cacheZoteroCitation("Stale response", for: ref, in: item.id))
            let saved = try await store.load(item.id)
            #expect(saved.zotero == first.zotero)
            #expect(saved.trailingBodyRaw == first.trailingBodyRaw)
        }
    }

    @Test("late fetch cannot reattach a removed reference or write another note")
    func removedReference() async throws {
        try await withScratch { model, store, item in
            let ref = try #require(ZoteroSelectLink.parse("zotero://select/groups/123/items/NOTE1234"))
            var other = item
            other.id = UUID()
            _ = try await store.create(other)
            let otherBefore = try await store.load(other.id)
            #expect(await model.attachZoteroReference(ref, to: item.id))
            _ = try await store.withItem(item.id) { $0.zotero = [] }
            #expect(await model.cacheZoteroCitation("Too late", for: ref, in: item.id))
            #expect(try await store.load(item.id).zotero.isEmpty)
            #expect(try await store.load(other.id) == otherBefore)
        }
    }

    @Test("auto-fill cannot erase a citation cached while its confirmation was open",
          arguments: [Optional<String>.none, "Older auto-fill citation"])
    func autoFillRace(citation: String?) async throws {
        try await withScratch { model, store, item in
            let ref = try #require(ZoteroSelectLink.parse("zotero://select/library/items/NOTE1234"))
            #expect(await model.attachZoteroReference(ref, to: item.id))
            let base = try await store.load(item.id)
            let target = ZoteroAutoFillReferenceTarget(selectLink: ref.selectLink,
                                                       noteFrontMatter: true, sourceBlocks: false)
            let csl = ZoteroCSLItem(type: nil, title: nil, author: nil,
                                   issued: .init(dateParts: [[1843]], raw: nil), itemType: nil)
            let sheet = ZoteroAutoFillModel(item: base, csl: csl, refSelectLink: ref.selectLink,
                                           citation: citation, referenceTarget: target) { resolved in
                try await model.applyZoteroAutoFill(resolved, basedOn: base, target: target)
            }
            #expect(await model.cacheZoteroCitation("New inspector citation", for: ref, in: item.id))
            let fresh = try await store.load(item.id)
            try await sheet.confirm()
            let saved = try await store.load(item.id)
            #expect(saved.zotero == fresh.zotero)
            #expect(saved.date == "1843", "selected metadata still commits")
        }
    }
}
