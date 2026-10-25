import Testing
import Foundation
import AppKit
import SwiftUI
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

    @Test("disabling for a slow switch flushes earlier typing but refuses input in the gap")
    func slowSwitchPreservesOnlyAcceptedInput() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let a = try await makeNote(env, title: "A", body: "A body")
        let b = try await makeNote(env, title: "B", body: String(repeating: "Large B body. ", count: 80_000))
        let editor = NoteBodyEditorModel()
        editor.saveDebounce = .seconds(60)
        editor.checkedSave = { await env.model.saveEditorBody($1, basedOn: $2, for: $0) }
        var release: CheckedContinuation<Void, Never>?
        var started: AsyncStream<Void>.Continuation!
        let stream = AsyncStream<Void> { started = $0 }
        var events = stream.makeAsyncIterator()
        editor.load = { id in
            if id == b {
                started.yield(())
                await withCheckedContinuation { release = $0 }
            }
            return await env.model.loadBody(for: id)
        }
        await editor.select(a)
        let view = MarkdownEditorView(markdown: Binding(
            get: { editor.markdown }, set: { editor.acceptEditorMarkdown($0, for: a) }), isRaw: .constant(true))
        let coordinator = view.makeCoordinator()
        let tv = EditorTextView()
        tv.applyRawMode(true, fontSize: 14)
        tv.string = editor.markdown
        coordinator.textView = tv
        coordinator.recordAppliedSerialization()
        editor.flushEditor = { coordinator.flushWriteBack() }
        tv.setSelectedRange(NSRange(location: tv.string.utf16.count, length: 0))
        tv.insertPlainText(" before switch")   // still in TextKit's buffer when selection changes
        tv.isEditable = false
        let switching = Task { await editor.select(b) }
        _ = await events.next()
        #expect(editor.loadedID == a)
        #expect(await env.model.loadBody(for: a) == "A body before switch")
        let aFile = try await env.store.mdURL(for: a)
        let bFile = try await env.store.mdURL(for: b)
        let beforeA = try Data(contentsOf: aFile), beforeB = try Data(contentsOf: bFile)
        tv.insertText("rejected keystroke", replacementRange: tv.selectedRange())
        tv.insertPlainText("rejected paste")
        await editor.flushPending()
        release?.resume()
        await switching.value
        await editor.flushPending()
        #expect(editor.loadedID == b)
        #expect(try Data(contentsOf: aFile) == beforeA)
        #expect(try Data(contentsOf: bFile) == beforeB)
        #expect(tv.string == "A body before switch")
        editor.flushEditor = {}
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
        await env.model.setQuality(3, for: id)

        await env.model.setBody("A totally new body.", for: id)

        let r = try await env.store.load(id)
        #expect(r.title == "Keep Me")
        #expect(r.date == "1968")
        #expect(r.datePrecision == .year)
        #expect(r.quality == 3)
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

    // W3.notes-chip-header-needs-a-line-break — the functional half of the fix, on a scratch store.
    // The unit tests in `BlockChipTests` stop at the string `MarkdownBridge.serialize` produces; this
    // one carries it the rest of the way to disk — serialize → `setBody` → `BlockParser.parse` →
    // atomic `.md` → reload — because that is where the loss actually landed. A header glued to the
    // previous body line is not a header to `BlockParser.parse`, so the second block was absorbed into
    // the first as literal text and its provenance anchor was gone for good.
    //
    // Scope, stated so it is not over-read: this drives the same two pure functions plus the real
    // store, NOT `MarkdownEditorView.writeBack` (an AppKit coordinator, out of reach of a unit test).
    // The raw-mode branch of `writeBack`, which commits `textView.string` verbatim, stays untested.

    @Test("editor write-back of a two-block body keeps BOTH blocks' provenance on disk")
    func editorWriteBackKeepsBothBlocksOnDisk() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let src = UUID()
        let item = Item(id: UUID(), kind: .note, title: "WriteBack", authors: [], date: nil,
                        datePrecision: nil, dateUncertain: false, quality: nil, tags: [], zotero: [],
                        roundup: false, created: Date(), modified: Date(), schema: 1, blocks: [],
                        unknownFrontMatter: [], trailingBodyRaw: nil)
        let ref = try await env.store.create(item)

        // A pasted passage whose body does not end in a newline, followed by the operator's own
        // freeform block — the exact shape `W3.notes-passage-paste-at-caret` produces.
        let editorMarkdown = """
        <!-- block: note-passage
             note: archivenotes://open?id=\(src.uuidString)#block-0
             display: "Src — 1968" -->
        …an early egalitarian culture.
        <!-- block: freeform -->
        My own commentary.
        """
        // What the editor hands `setBody` after rendering that body and serializing it back.
        let writtenBack = MarkdownBridge.serialize(MarkdownBridge.parse(markdown: editorMarkdown))
        await env.model.setBody(writtenBack, for: item.id)

        let reloaded = try await env.store.load(item.id)
        #expect(reloaded.blocks.count == 2)
        #expect(reloaded.blocks.first?.kind == .notePassage)
        #expect(reloaded.blocks.first?.source?.noteRef?.contains(src.uuidString) == true)
        #expect(reloaded.blocks.first?.markdown.contains("egalitarian culture") == true)
        #expect(reloaded.blocks.last?.kind == .freeform)
        #expect(reloaded.blocks.last?.markdown.contains("My own commentary") == true)

        // The literal-text failure mode, asserted against the bytes actually written.
        let onDisk = try String(contentsOf: ref.url, encoding: .utf8)
        #expect(!onDisk.contains("culture.<!-- block:"))

        // And the loop is stable: a second write-back of what the editor renders changes nothing.
        let md1 = await env.model.loadBody(for: item.id) ?? ""
        let writtenBack2 = MarkdownBridge.serialize(MarkdownBridge.parse(markdown: md1))
        await env.model.setBody(writtenBack2, for: item.id)
        #expect(await env.model.loadBody(for: item.id) == md1)
    }

    // W3.notes-editor-blankline-collapse — the Tier-2 functional half, on a scratch `mktemp` store.
    // The item was filed as "possibly intended", with one instruction: establish whether the REAL
    // path loses the break, because the raw measurement had called the bridge bare. It does. Measured
    // on `deba3a9` through exactly this path, the two paragraphs reached disk as `Para one.Para two.`
    // — the blank line AND the word boundary gone, on the first autosave of any two-paragraph note.
    //
    // Two save cycles deliberately: this defect's neighbour in the same family
    // (`W3.notes-cr-line-start-fu1`) decayed PROGRESSIVELY, so one cycle is not evidence of a fixed
    // point.

    @Test("a two-paragraph body keeps its blank line through the editor write-back to disk")
    func twoParagraphBodySurvivesWriteBackToDisk() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try await makeNote(env, body: "Para one.\n\nPara two.\n")

        // What the editor renders on load and hands back to `setBody` on the first autosave.
        let loaded = await env.model.loadBody(for: id) ?? ""
        await env.model.setBody(MarkdownBridge.serialize(MarkdownBridge.parse(markdown: loaded)), for: id)

        let afterOne = try await env.store.load(id).trailingBodyRaw ?? ""
        #expect(afterOne == "Para one.\n\nPara two.",
                "the paragraph break did not survive one save: \(afterOne.debugDescription)")

        // A second cycle: no decay, and no growth either.
        let reloaded = await env.model.loadBody(for: id) ?? ""
        await env.model.setBody(MarkdownBridge.serialize(MarkdownBridge.parse(markdown: reloaded)), for: id)
        let afterTwo = try await env.store.load(id).trailingBodyRaw ?? ""
        #expect(afterTwo == afterOne, "the body decayed on the second save: \(afterTwo.debugDescription)")
    }

    @Test("a mixed-block body keeps every block boundary through the write-back to disk")
    func mixedBlockBodySurvivesWriteBackToDisk() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let body = "Opening prose.\n\n- first\n- second\n\n> A quote.\n\nClosing prose."
        let id = try await makeNote(env, body: body)

        let loaded = await env.model.loadBody(for: id) ?? ""
        await env.model.setBody(MarkdownBridge.serialize(MarkdownBridge.parse(markdown: loaded)), for: id)

        let onDisk = try await env.store.load(id).trailingBodyRaw ?? ""
        #expect(onDisk == body, "block boundaries changed on save: \(onDisk.debugDescription)")
    }
}
