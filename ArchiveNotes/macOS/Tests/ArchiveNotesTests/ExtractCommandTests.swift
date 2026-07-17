import Testing
import Foundation
import ArchiveCore
@testable import ArchiveNotes

// W7-S2 (c) — the model-level Create / Append-Extract actions the Extract-menu commands drive. Runs
// against a scratch `mktemp` store (Prime Directive #1 — never a real store or corpus) and asserts the
// new/updated extract is persisted through the audited NoteStore, filed into the Extracts home folder,
// indexed so it appears in `allItems` (the Extracts window features it), and that an empty selection
// is a safe no-op with a status hint. Reuses `FakeSelectionSource` from ExtractBuilderTests.

@Suite("NotesModel extracts — create / append / list (W7-S2)")
@MainActor
struct ExtractCommandTests {

    struct Env { let model: NotesModel; let store: NoteStore; let index: NotesIndex; let root: URL }

    private func makeEnv() async throws -> Env {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-extractcmd-\(UUID().uuidString)", isDirectory: true)
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

    /// A selection of the first `length` UTF-16 units of `text`, treated as one source block `ordinal`.
    private func source(_ text: String, length: Int, ordinal: Int = 0,
                        title: String = "Src Note", date: String = "1968") -> FakeSelectionSource {
        FakeSelectionSource(sourceNoteId: UUID(), sourceTitle: title, sourceDateDisplay: date,
                            fullText: text,
                            selectedRanges: [NSRange(location: 0, length: length)],
                            blockRanges: [(ordinal, NSRange(location: 0, length: (text as NSString).length))])
    }

    @Test("createExtract persists a note-passage extract, files it in Extracts, and lists it")
    func createFilesAndLists() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let src = source("Hello World", length: 5, ordinal: 3)
        let id = try #require(await env.model.createExtract(from: src))

        // Appears in the shared item source as an extract (both windows observe this).
        let summary = try #require(env.model.allItems.first { $0.id == id })
        #expect(summary.kind == .extract)

        // Filed into the Extracts home folder (§16.6).
        #expect(env.model.organization.memberships
            .contains { $0.itemId == id && $0.folderId == OrganizationStore.extractsFolderId })

        // On disk: one note-passage block, snapshot markdown, anchored to the covered ordinal.
        let onDisk = try await env.store.load(id)
        #expect(onDisk.kind == .extract)
        #expect(onDisk.blocks.count == 1)
        #expect(onDisk.blocks.first?.kind == .notePassage)
        #expect(onDisk.blocks.first?.markdown == "Hello")
        #expect(onDisk.blocks.first?.source?.notePassageTarget?.block == 3)
    }

    @Test("createExtract into an explicit folder files it there, not in Extracts home")
    func createIntoExplicitFolder() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let folder = try await env.model.organization.createFolder(name: "Project").id
        let id = try #require(await env.model.createExtract(from: source("Text here", length: 4), into: folder))
        #expect(env.model.organization.foldersContaining(item: id) == [folder])
    }

    @Test("empty selection → nil, no extract created, status hint set")
    func emptySelectionNoOp() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let src = FakeSelectionSource(fullText: "abc",
                                      selectedRanges: [NSRange(location: 0, length: 0)],
                                      blockRanges: [(0, NSRange(location: 0, length: 3))])
        #expect(await env.model.createExtract(from: src) == nil)
        #expect(env.model.allItems.isEmpty)
        #expect(env.model.statusMessage != nil)
    }

    @Test("appendToExtract adds a cross-note segment to an existing extract")
    func appendSegment() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try #require(await env.model.createExtract(from: source("From A here", length: 6, ordinal: 0)))
        await env.model.appendToExtract(id, from: source("Second passage", length: 6, ordinal: 2,
                                                          title: "Note B", date: "1972"))
        let onDisk = try await env.store.load(id)
        #expect(onDisk.blocks.count == 2)
        // Bodies survive the round-trip; a non-newline-terminated middle body gains the separating
        // newline `serialize` inserts so the next header stays on its own line (no silent merge).
        #expect(onDisk.blocks[0].markdown.trimmingCharacters(in: .newlines) == "From A")
        #expect(onDisk.blocks[1].markdown.trimmingCharacters(in: .newlines) == "Second")
        #expect(onDisk.blocks.allSatisfy { $0.kind == .notePassage })
        // The two segments link to different source notes (segmentation, §D7).
        #expect(onDisk.blocks[0].source?.notePassageTarget?.id != onDisk.blocks[1].source?.notePassageTarget?.id)
    }

    @Test("createExtract routes the new extract through the open channel (select + raise, W14.4 b)")
    func createPublishesOpenRequest() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try #require(await env.model.createExtract(from: source("Open me", length: 4)))
        // The Extracts window observes pendingOpen → selects (and raises) the new extract.
        #expect(env.model.pendingOpen?.id == id)
        #expect(env.model.pendingOpen?.block == nil)
    }

    @Test("appendToExtract surfaces the appended-to extract via the open channel (W14.4 b)")
    func appendPublishesOpenRequest() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try #require(await env.model.createExtract(from: source("Base", length: 4, ordinal: 0)))
        env.model.consumeOpen()   // clear the create's request so we prove APPEND re-publishes it
        await env.model.appendToExtract(id, from: source("More", length: 4, ordinal: 1, title: "Note B"))
        #expect(env.model.pendingOpen?.id == id)
    }

    @Test("existingExtracts lists only extracts, sorted by localized title")
    func listsExtractsSorted() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        _ = try #require(await env.model.createExtract(from: source("Zebra note", length: 5)))
        _ = try #require(await env.model.createExtract(from: source("Apple note", length: 5)))
        let list = env.model.existingExtracts
        #expect(list.count == 2)
        #expect(list.map(\.title) == ["Apple", "Zebra"])
    }
}
