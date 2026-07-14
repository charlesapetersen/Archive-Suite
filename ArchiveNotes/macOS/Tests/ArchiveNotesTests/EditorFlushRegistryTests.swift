import Testing
import Foundation
@testable import ArchiveNotes

// W7-S6 — the app-terminate / window-close autosave flush that closes the force-quit data-loss window.
// The body editor autosaves on a ~600 ms debounce; a hard ⌘Q doesn't reliably fire `.onDisappear`, so an
// edit made inside that window could be lost. `EditorFlushRegistry` collects each pane's flush closure and
// `NotesAppDelegate.applicationShouldTerminate` awaits `flushAll()` under a bounded timeout (via
// `TerminateFlushCoordinator`) before the process exits. Tier-2 (data-loss-sensitive): these prove the
// registry flushes every pane, the wait is truly bounded (a wedged flush never blocks quit), and — the
// crown check — an edit made *within the debounce* is on disk after a flush, against a scratch store
// (Prime Directive #1 — never a real corpus / the real Notes store).

/// Main-actor call counter (avoids capturing a local `var` in the escaping flush/reply closures).
@MainActor
private final class Counter {
    private(set) var n = 0
    func bump() { n += 1 }
}

@Suite("EditorFlushRegistry — pane flush collection")
@MainActor
struct EditorFlushRegistryTests {

    @Test("flushAll awaits every registered flush")
    func flushAllRunsAll() async {
        let reg = EditorFlushRegistry()
        let a = Counter(), b = Counter()
        reg.register(UUID()) { a.bump() }
        reg.register(UUID()) { b.bump() }
        #expect(!reg.isEmpty)
        await reg.flushAll()
        #expect(a.n == 1)
        #expect(b.n == 1)
    }

    @Test("deregister removes a flush; it does not run on the next flushAll")
    func deregisterRemoves() async {
        let reg = EditorFlushRegistry()
        let id = UUID()
        let a = Counter()
        reg.register(id) { a.bump() }
        reg.deregister(id)
        #expect(reg.isEmpty)
        await reg.flushAll()
        #expect(a.n == 0)
    }

    @Test("re-registering the same id overwrites (onAppear twice → no duplicate flush)")
    func reRegisterIdempotent() async {
        let reg = EditorFlushRegistry()
        let id = UUID()
        let first = Counter(), second = Counter()
        reg.register(id) { first.bump() }
        reg.register(id) { second.bump() }
        await reg.flushAll()
        #expect(first.n == 0)    // replaced
        #expect(second.n == 1)   // only the latest, once
    }

    @Test("empty registry flushAll is a no-op (no crash)")
    func emptyFlushAllNoop() async {
        let reg = EditorFlushRegistry()
        #expect(reg.isEmpty)
        await reg.flushAll()
    }
}

@Suite("TerminateFlushCoordinator — bounded reply")
@MainActor
struct TerminateFlushCoordinatorTests {

    @Test("a fast flush replies exactly once, well before the timeout")
    func fastReplyOnce() async {
        let replies = Counter(), ran = Counter()
        let coord = TerminateFlushCoordinator { replies.bump() }
        coord.begin(flush: { ran.bump() }, timeout: .seconds(5))
        try? await Task.sleep(for: .milliseconds(120))   // << the 5 s timeout
        #expect(ran.n == 1)       // flush ran
        #expect(replies.n == 1)   // replied once, via the flush path (not the far-off timeout)
    }

    @Test("BOUNDED: a wedged flush does not block the reply past the timeout")
    func boundedReplyOnTimeout() async {
        let replies = Counter()
        let coord = TerminateFlushCoordinator { replies.bump() }
        // The flush "hangs" far longer than the timeout; the reply must still fire via the timeout path.
        coord.begin(flush: { try? await Task.sleep(for: .seconds(3)) }, timeout: .milliseconds(30))
        try? await Task.sleep(for: .milliseconds(250))   // >> timeout (30 ms), << wedged flush (3 s)
        #expect(replies.n == 1)   // quit proceeds after the bound, exactly once — never deadlocks
    }
}

@Suite("Editor flush — terminate persists a within-debounce edit (scratch store)")
@MainActor
struct EditorTerminateFlushTests {

    private struct Env { let model: NotesModel; let store: NoteStore; let index: NotesIndex; let root: URL }

    private func makeEnv() async throws -> Env {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-terminateflush-\(UUID().uuidString)", isDirectory: true)
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
    private func makeNote(_ env: Env, body: String?) async throws -> UUID {
        let item = Item(id: UUID(), kind: .note, title: "Note", authors: [], date: nil,
                        datePrecision: nil, dateUncertain: false, quality: nil, tags: [], zotero: [],
                        roundup: false, created: Date(), modified: Date(), schema: 1, blocks: [],
                        unknownFrontMatter: [], trailingBodyRaw: body)
        _ = try await env.store.create(item)
        return item.id
    }

    @Test("TERMINATE PATH: an edit made within the autosave debounce is on disk after flushAll")
    func editWithinDebounceFlushedToDisk() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try await makeNote(env, body: "original")

        // Bind a body editor to the scratch store, with a LONG debounce so the ONLY thing that can
        // persist the edit during this test is an explicit flush — never the idle autosave firing.
        let editor = NoteBodyEditorModel()
        editor.load = { await env.model.loadBody(for: $0) }
        editor.save = { await env.model.setBody($1, for: $0) }
        editor.saveDebounce = .seconds(30)

        await editor.select(id)
        #expect(editor.markdown == "original")
        editor.markdown = "edited just before quit"   // user edit → dirty; 30 s debounce armed (won't fire)

        // Simulate app terminate: the pane's flush closure sits in the registry; the delegate awaits it.
        let registry = EditorFlushRegistry()
        registry.register(UUID()) { await editor.flushPending() }
        await registry.flushAll()

        // The edit must be on disk even though the debounce never fired.
        let reloaded = try await env.store.load(id)
        #expect(reloaded.trailingBodyRaw == "edited just before quit")
        #expect(await env.model.loadBody(for: id) == "edited just before quit")
    }

    @Test("a clean editor (no pending edit) flushes without rewriting the body")
    func cleanEditorFlushNoWrite() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try await makeNote(env, body: "pristine")

        let editor = NoteBodyEditorModel()
        editor.load = { await env.model.loadBody(for: $0) }
        editor.save = { await env.model.setBody($1, for: $0) }
        await editor.select(id)   // loads, not dirty

        let registry = EditorFlushRegistry()
        registry.register(UUID()) { await editor.flushPending() }
        await registry.flushAll()

        #expect(try await env.store.load(id).trailingBodyRaw == "pristine")
    }
}
