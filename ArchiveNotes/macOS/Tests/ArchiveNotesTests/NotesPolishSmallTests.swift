import Testing
import Foundation
import AppKit
@testable import ArchiveNotes

// W49.notes-polish-small — Duplicate Note, the inspector's word/character count and the editor focus request.
// Scratch `mktemp` libraries only, never a real corpus (Prime Directive #1).

@Suite("NoteTextStats — what the inspector counts")
struct NoteTextStatsTests {

    @Test("plain prose counts words and every character but line breaks")
    func plainProse() {
        let c = NoteTextStats.counts(markdown: "Hello there, world.\nSecond line")
        #expect(c.words == 5)
        #expect(c.characters == "Hello there, world.".count + "Second line".count)
    }

    @Test("Markdown markup, images and link targets are not counted")
    func markupIsNotText() {
        let md = """
        # Heading one
        - **bold** item
        > quoted [link text](https://example.com/very/long/path)
        ![a picture](assets/photo.png)
        `code` and ==mark==
        """
        #expect(NoteTextStats.visibleText(md) == "Heading one\nbold item\nquoted link text\n\ncode and mark")
        #expect(NoteTextStats.counts(markdown: md).words == 10)
    }

    @Test("a block's provenance header is not text")
    func blockHeadersAreSkipped() {
        let block = Block(kind: .freeform, source: nil, markdown: "Two words", unknownHeaderFields: [])
        let md = BlockParser.serialize(leadingText: "Intro", blocks: [block])
        #expect(md.contains("<!--"))
        #expect(NoteTextStats.counts(markdown: md).words == 3)
    }

    @Test("an empty note is zero and zero, and the label is singular for one")
    func emptyAndSingular() {
        #expect(NoteTextStats.counts(markdown: "") == .init(words: 0, characters: 0))
        #expect(NoteInfoSection.countsText(.init(words: 1, characters: 1)) == "1 word · 1 character")
        #expect(NoteInfoSection.countsText(.init(words: 1200, characters: 2)).hasSuffix("2 characters"))
    }
}

@Suite("Duplicate Note")
@MainActor
struct DuplicateNoteTests {

    struct Env { let model: NotesModel; let org: OrganizationStore; let store: NoteStore
                 let index: NotesIndex; let root: URL }

    private func makeEnv() async throws -> Env {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-dup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = NotesIndex(url: root.appendingPathComponent("index.db"))
        try await index.open()
        let org = OrganizationStore(index: index)
        try await org.load(storeRoot: root)
        let store = NoteStore(root: root)
        let model = NotesModel(organization: org, index: index, noteStore: store)
        return Env(model: model, org: org, store: store, index: index, root: root)
    }

    private func cleanup(_ env: Env) async {
        await env.index.close()
        try? FileManager.default.removeItem(at: env.root)
    }

    /// A note with fields, a body that references an image, the image itself, filed in two folders.
    private func seededNote(_ env: Env) async throws -> (id: UUID, folders: [UUID]) {
        let id = try #require(await env.model.newItem(kind: .note, in: nil, from: nil))
        _ = try await env.store.withItem(id) { item in
            item.title = "Field visit"
            item.date = "1978-03"
            item.datePrecision = .month
            item.quality = 2
            item.tags = ["budget"]
            item.trailingBodyRaw = "Seen at the archive.\n\n![scan](assets/scan.png)\n"
        }
        _ = try await env.store.importAsset(Data([0x89, 0x50, 0x4E, 0x47]), preferredName: "scan.png", into: id)
        let a = try await env.org.createFolder(name: "A").id
        let b = try await env.org.createFolder(name: "B").id
        try await env.org.addMembership(item: id, folder: a)
        try await env.org.addMembership(item: id, folder: b)
        _ = try await env.org.removeMembership(item: id, folder: OrganizationStore.inboxFolderId)
        await env.model.reloadItems()
        return (id, [a, b])
    }

    @Test("the copy has the note's fields, body and images under a new id, in the same folders")
    func duplicateCopiesEverything() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let (id, folders) = try await seededNote(env)
        let originalURL = try await env.store.mdURL(for: id)
        let originalBytes = try Data(contentsOf: originalURL)

        let copyID = try #require(await env.model.duplicateNote(id))
        #expect(copyID != id)
        let copy = try await env.store.load(copyID)
        #expect(copy.title == "Field visit copy")
        #expect(copy.date == "1978-03")
        #expect(copy.quality == 2)
        #expect(copy.tags == ["budget"])
        #expect(copy.trailingBodyRaw?.contains("![scan](assets/scan.png)") == true)
        let image = await env.store.assetsDir(copyID).appendingPathComponent("scan.png")
        #expect(FileManager.default.fileExists(atPath: image.path), "the copy's image reference must resolve")
        #expect(Set(env.org.foldersContaining(item: copyID)) == Set(folders))
        #expect(env.model.allItems.contains { $0.id == copyID })
        // The original is only read.
        #expect(try Data(contentsOf: originalURL) == originalBytes)
        #expect(Set(env.org.foldersContaining(item: id)) == Set(folders))
    }

    @Test("an untitled note's copy is named Untitled copy and lands in the Inbox when the note is in no folder")
    func untitledUnfiled() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try #require(await env.model.newItem(kind: .note, in: nil, from: nil))
        _ = try await env.org.removeMembership(item: id, folder: OrganizationStore.inboxFolderId)
        await env.model.reloadItems()
        let copyID = try #require(await env.model.duplicateNote(id))
        #expect(try await env.store.load(copyID).title == "Untitled copy")
        #expect(env.org.foldersContaining(item: copyID) == [OrganizationStore.inboxFolderId])
    }

    @Test("the row menu offers Duplicate for one note, and it selects the copy")
    func rowMenuDuplicate() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let (id, _) = try await seededNote(env)
        let nav = NotesNavigationModel(model: env.model, defaultKind: .note)
        let registry = EditorFlushRegistry()
        let menu = try #require(NotesItemContextMenu.make(nav: nav, selection: [id], flushing: registry))
        let item = try #require(menu.items.first { $0.title == "Duplicate" })
        #expect(item.keyEquivalent == "d")
        let two = NotesItemContextMenu.make(nav: nav, selection: [id, UUID()], flushing: registry)
        #expect(two?.items.contains { $0.title == "Duplicate" } == false)

        await DuplicateNoteFlow.duplicate(id, nav: nav, flushing: registry)
        let copyID = try #require(nav.selection.first)
        #expect(copyID != id)
        #expect(try await env.store.load(copyID).title == "Field visit copy")
    }

    @Test("Open and a row double-click ask the editor for the keyboard")
    func focusRequest() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let nav = NotesNavigationModel(model: env.model, defaultKind: .note)
        let before = nav.editorFocusRequest
        nav.requestEditorFocus()
        #expect(nav.editorFocusRequest == before &+ 1)
    }
}
