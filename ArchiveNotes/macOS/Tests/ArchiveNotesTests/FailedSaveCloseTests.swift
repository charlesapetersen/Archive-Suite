import Testing
import Foundation
@testable import ArchiveNotes

/// W40.fix-notes-failed-save-close — a save the store refuses must survive the editor closing and the app
/// quitting. Real scratch store; the refusal is made by removing write permission from the note's own
/// folder (normal save) or from `items/` (the outside-edit conflict's recovery note), then restored.
@Suite("Failed save — close and quit keep the draft")
@MainActor
struct FailedSaveCloseTests {
    private struct Env {
        let root: URL
        let store: NoteStore
        let model: NotesModel
        let index: NotesIndex
        let item: Item
        let file: URL
        let vault: UnsavedDraftVault
    }

    private func makeEnv() async throws -> Env {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-failedsave-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = NotesIndex(url: root.appendingPathComponent("index.db"))
        try await index.open()
        let org = OrganizationStore(index: index)
        try await org.load(storeRoot: root)
        let store = NoteStore(root: root)
        let item = Item(id: UUID(), kind: .note, title: "Field notes", authors: [], date: nil,
                        datePrecision: nil, dateUncertain: false, quality: nil, tags: [], zotero: [],
                        roundup: false, created: Date(), modified: Date(), schema: 1, blocks: [],
                        unknownFrontMatter: [], trailingBodyRaw: "Original paragraph.")
        let ref = try await store.create(item)
        try await org.addMembership(item: item.id, folder: OrganizationStore.inboxFolderId)
        let model = NotesModel(organization: org, index: index, noteStore: store)
        let vault = UnsavedDraftVault(directory: root.appendingPathComponent("vault", isDirectory: true))
        return Env(root: root, store: store, model: model, index: index, item: item, file: ref.url, vault: vault)
    }

    /// Synchronous, so a read-only scratch folder is writable again before the async removal runs.
    private func restore(_ env: Env) {
        for dir in [itemDir(env), env.root.appendingPathComponent("items"), env.vault.directory] {
            setWritable(dir, true)
        }
    }

    private func cleanup(_ env: Env) async {
        restore(env)
        await env.index.close()
        try? FileManager.default.removeItem(at: env.root)
    }

    private func itemDir(_ env: Env) -> URL { NoteStore.itemDir(root: env.root, id: env.item.id) }

    private func setWritable(_ url: URL, _ writable: Bool) {
        try? FileManager.default.setAttributes([.posixPermissions: writable ? 0o755 : 0o555], ofItemAtPath: url.path)
    }

    private func editor(_ env: Env) -> NoteBodyEditorModel {
        let editor = NoteBodyEditorModel()
        editor.saveDebounce = .seconds(60)
        editor.load = { await env.model.loadBody(for: $0) }
        editor.checkedSave = { await env.model.saveEditorBody($1, basedOn: $2, for: $0) }
        return editor
    }

    /// The pane's registration, exactly as `NoteEditorPane.onAppear` makes it.
    private func register(_ editor: NoteBodyEditorModel, _ pane: UUID, in registry: EditorFlushRegistry) {
        registry.register(pane, flush: { await editor.flushPending() }, draft: {
            guard let draft = editor.unsavedDraft else { return nil }
            return EditorDraft(itemID: draft.id, title: "Field notes", markdown: draft.markdown)
        })
    }

    private func vaultFiles(_ env: Env) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: env.vault.directory, includingPropertiesForKeys: nil)) ?? []
    }

    @Test("CLOSE, normal save: a refused write keeps every keystroke, copies it, and saves on retry at quit")
    func closeAfterFailedSave() async throws {
        let env = try await makeEnv(); defer { restore(env); Task { await cleanup(env) } }
        let editor = editor(env)
        await editor.select(env.item.id)
        let original = try Data(contentsOf: env.file)
        setWritable(itemDir(env), false)

        // Typing continues while each save is refused.
        for typed in ["F", "Fi", "Fin", "Final draft."] {
            editor.markdown = typed
            #expect(await editor.flushPending() == false)
        }
        let registry = EditorFlushRegistry(vault: env.vault)
        var asked: [(String, URL?)] = []
        registry.presentCloseFailure = { title, copy in asked.append((title, copy)); return .keep }
        let pane = UUID()
        register(editor, pane, in: registry)

        await registry.paneClosed(pane)
        #expect(!registry.isEmpty, "the closed pane's draft is retained, not dropped")
        #expect(registry.retainedPaneIDs == [pane])
        #expect(asked.count == 1)
        #expect(asked.first?.0 == "Field notes")
        let copy = try #require(asked.first?.1)
        #expect(try String(contentsOf: copy, encoding: .utf8) == "Final draft.")
        #expect(try Data(contentsOf: env.file) == original, "the refused write left the note untouched")

        // A quit while writes are still refused fails; once restored, it saves and clears everything.
        #expect(await registry.flushAll() == false)
        #expect(vaultFiles(env).count == 1, "an unchanged draft reuses its copy")
        setWritable(itemDir(env), true)
        #expect(await registry.flushAll())
        #expect(registry.isEmpty)
        #expect(registry.retainedPaneIDs.isEmpty)
        #expect(await env.model.loadBody(for: env.item.id) == "Final draft.")
        #expect(vaultFiles(env).isEmpty, "the copy is removed once the draft is saved")
    }

    @Test("LIVE pane: the first refused autosave copies the draft at once; the copy follows the text and goes when it saves")
    func refusedAutosaveCopiesImmediately() async throws {
        let env = try await makeEnv(); defer { restore(env); Task { await cleanup(env) } }
        let editor = editor(env)
        await editor.select(env.item.id)
        let registry = EditorFlushRegistry(vault: env.vault)
        let pane = UUID()
        register(editor, pane, in: registry)
        // Exactly the pane's wiring: refused → copy now, landed → drop the copy.
        editor.onSaveResult = { saved in
            if saved { registry.discardCopy(for: pane) } else { registry.copyDraft(for: pane) }
        }
        setWritable(itemDir(env), false)
        editor.markdown = "First"
        #expect(await editor.flushPending() == false)
        #expect(try vaultFiles(env).map { try String(contentsOf: $0, encoding: .utf8) } == ["First"],
                "the draft is on disk before any close or quit")
        editor.markdown = "First, then more."
        #expect(await editor.flushPending() == false)
        #expect(try vaultFiles(env).map { try String(contentsOf: $0, encoding: .utf8) } == ["First, then more."],
                "one copy, following the text")
        #expect(!registry.isEmpty && registry.retainedPaneIDs.isEmpty, "still a live pane, not a retained one")
        setWritable(itemDir(env), true)
        #expect(await editor.flushPending())
        #expect(vaultFiles(env).isEmpty, "the copy goes once the save lands")
        #expect(await env.model.loadBody(for: env.item.id) == "First, then more.")
    }

    @Test("CLOSE retry: Retry after the problem is fixed saves the draft and drops the pane")
    func closeRetrySaves() async throws {
        let env = try await makeEnv(); defer { restore(env); Task { await cleanup(env) } }
        let editor = editor(env)
        await editor.select(env.item.id)
        setWritable(itemDir(env), false)
        editor.markdown = "Saved by retry."
        let registry = EditorFlushRegistry(vault: env.vault)
        var prompts = 0
        registry.presentCloseFailure = { _, _ in
            prompts += 1
            if prompts == 2 { self.setWritable(self.itemDir(env), true) }
            return .retry
        }
        let pane = UUID()
        register(editor, pane, in: registry)
        await registry.paneClosed(pane)
        #expect(prompts == 2, "it asked again while the write still failed")
        #expect(registry.isEmpty)
        #expect(await env.model.loadBody(for: env.item.id) == "Saved by retry.")
        #expect(vaultFiles(env).isEmpty)
    }

    @Test("CLOSE, outside-edit conflict: a refused recovery note keeps the draft until it can be written")
    func closeAfterFailedRecovery() async throws {
        let env = try await makeEnv(); defer { restore(env); Task { await cleanup(env) } }
        let editor = editor(env)
        await editor.select(env.item.id)
        editor.markdown = "In-app draft during conflict."
        let outside = try String(contentsOf: env.file, encoding: .utf8) + "\nOutside paragraph.\n"
        try Data(outside.utf8).write(to: env.file)
        let items = env.root.appendingPathComponent("items")
        setWritable(items, false)

        let registry = EditorFlushRegistry(vault: env.vault)
        registry.presentCloseFailure = { _, _ in .keep }
        let pane = UUID()
        register(editor, pane, in: registry)
        await registry.paneClosed(pane)
        #expect(registry.retainedPaneIDs == [pane])
        #expect(try Data(contentsOf: env.file) == Data(outside.utf8))
        #expect(try vaultFiles(env).map { try String(contentsOf: $0, encoding: .utf8) } == ["In-app draft during conflict."])

        setWritable(items, true)
        #expect(await registry.flushAll())
        #expect(registry.isEmpty)
        #expect(try Data(contentsOf: env.file) == Data(outside.utf8), "the original stays byte-identical")
        let ids = await env.store.allItemIDs().filter { $0 != env.item.id }
        #expect(ids.count == 1)
        #expect(await env.model.loadBody(for: try #require(ids.first)) == "In-app draft during conflict.")
        #expect(vaultFiles(env).isEmpty)
    }

    @Test("a slow close does not remove a pane that registered again meanwhile")
    func reappearDuringClose() async throws {
        let registry = EditorFlushRegistry()
        let pane = UUID()
        var reregistered = false
        registry.register(pane, flush: {
            registry.register(pane, flush: { reregistered = true; return true })
            return true
        })
        await registry.paneClosed(pane)
        #expect(!registry.isEmpty)
        await registry.flushAll()
        #expect(reregistered)
    }

    @Test("emergency copies report nil when a draft has nowhere to go")
    func copiesNilWhenVaultFails() async throws {
        let env = try await makeEnv(); defer { restore(env); Task { await cleanup(env) } }
        try FileManager.default.createDirectory(at: env.vault.directory, withIntermediateDirectories: true)
        setWritable(env.vault.directory, false)
        let registry = EditorFlushRegistry(vault: env.vault)
        registry.register(UUID(), flush: { false }, draft: {
            EditorDraft(itemID: env.item.id, title: "x", markdown: "unsaved")
        })
        #expect(registry.writeEmergencyCopies() == nil)
        setWritable(env.vault.directory, true)
        #expect(registry.writeEmergencyCopies()?.count == 1)
        #expect(EditorFlushRegistry().writeEmergencyCopies() == [], "nothing unsaved needs no copy")
    }

    @Test("the vault never deletes outside its own folder")
    func vaultRemoveIsContained() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let vault = UnsavedDraftVault(directory: dir.appendingPathComponent("v"))
        let outside = dir.appendingPathComponent("keep.md")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outside)
        vault.remove(outside, ifItHolds: "keep")
        #expect(FileManager.default.fileExists(atPath: outside.path))
        let url = try vault.write(EditorDraft(itemID: UUID(), title: "a/b:c", markdown: "body"))
        #expect(url.lastPathComponent.hasPrefix("a-b-c — unsaved "))
        let hidden = try vault.write(EditorDraft(itemID: UUID(), title: ".profile", markdown: "x"))
        #expect(hidden.lastPathComponent.hasPrefix("-profile — unsaved "), "a dot title must not make a hidden copy")
        let second = try vault.write(EditorDraft(itemID: UUID(), title: "a/b:c", markdown: "other"))
        #expect(second != url)
        vault.remove(url, ifItHolds: "changed by the user")
        #expect(FileManager.default.fileExists(atPath: url.path), "a copy that no longer matches is kept")
        vault.remove(url, ifItHolds: "body")
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("a long CJK or emoji title still yields a writable copy")
    func longTitleCopy() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let vault = UnsavedDraftVault(directory: dir)
        for title in [String(repeating: "档案", count: 60), String(repeating: "👩‍👩‍👧‍👦", count: 30)] {
            let url = try vault.write(EditorDraft(itemID: UUID(), title: title, markdown: "body"))
            #expect(url.lastPathComponent.utf8.count <= 255)
            #expect(try String(contentsOf: url, encoding: .utf8) == "body")
        }
        #expect(UnsavedDraftVault.truncated("ab档", maxBytes: 4) == "ab", "never splits a character")
    }

    @Test("a copy the user edited is never deleted when the draft later saves")
    func editedCopySurvives() async throws {
        let env = try await makeEnv(); defer { restore(env); Task { await cleanup(env) } }
        let editor = editor(env)
        await editor.select(env.item.id)
        setWritable(itemDir(env), false)
        editor.markdown = "Rescued text."
        let registry = EditorFlushRegistry(vault: env.vault)
        var copy: URL?
        registry.presentCloseFailure = { _, url in copy = url; return .keep }
        let pane = UUID()
        register(editor, pane, in: registry)
        await registry.paneClosed(pane)
        let url = try #require(copy)
        try Data("Rescued text, edited by the user.".utf8).write(to: url)
        setWritable(itemDir(env), true)
        #expect(await registry.flushAll())
        #expect(try String(contentsOf: url, encoding: .utf8) == "Rescued text, edited by the user.")
    }
}

/// Main-actor recorder for the coordinator's injected seams.
@MainActor
private final class QuitLog {
    var replies: [Bool] = []
    var prompts: [[URL]?] = []
    var timedOut: [Bool] = []
    var copies = 0
}

@Suite("Failed save — quit is refused, retried or confirmed")
@MainActor
struct FailedSaveQuitTests {
    private func waitForReply(_ log: QuitLog, timeout: Duration = .seconds(3)) async {
        let clock = ContinuousClock(), end = clock.now + timeout
        while log.replies.isEmpty, clock.now < end { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func coordinator(_ log: QuitLog, copies: [URL]? = [],
                             answers: [QuitFailureChoice]) -> TerminateFlushCoordinator {
        var remaining = answers
        return TerminateFlushCoordinator(
            reply: { log.replies.append($0) },
            writeCopies: { log.copies += 1; return copies },
            prompt: { copies, timedOut in
                log.prompts.append(copies); log.timedOut.append(timedOut)
                return remaining.isEmpty ? .cancel : remaining.removeFirst()
            })
    }

    @Test("a failed flush asks after copying; Don't Quit cancels termination")
    func failedFlushCancels() async {
        let log = QuitLog()
        coordinator(log, answers: [.cancel]).begin(flush: { false }, timeout: .seconds(5))
        await waitForReply(log)
        #expect(log.replies == [false])
        #expect(log.copies == 1)
        #expect(log.prompts.count == 1)
        #expect(log.timedOut == [false], "a refusal is not reported as a slow save")
    }

    @Test("Retry re-runs the flush and quits once it succeeds")
    func retryThenQuit() async {
        let log = QuitLog()
        var attempts = 0
        coordinator(log, answers: [.retry]).begin(flush: { attempts += 1; return attempts > 1 }, timeout: .seconds(5))
        await waitForReply(log)
        #expect(log.replies == [true])
        #expect(attempts == 2)
        #expect(log.prompts.count == 1)
    }

    @Test("Quit after a failure terminates; the prompt was told whether copies exist")
    func quitAnyway() async {
        let log = QuitLog()
        coordinator(log, copies: nil, answers: [.quit]).begin(flush: { false }, timeout: .seconds(5))
        await waitForReply(log)
        #expect(log.replies == [true])
        #expect(log.prompts.count == 1)
        #expect(log.prompts.first! == nil, "no copies → the prompt must warn that quitting loses text")
    }

    @Test("BOUNDED: a wedged flush is asked about at the timeout, never awaited")
    func wedgedFlushAsks() async {
        let log = QuitLog()
        coordinator(log, answers: [.cancel])
            .begin(flush: { try? await Task.sleep(for: .seconds(3)); return true }, timeout: .milliseconds(30))
        await waitForReply(log, timeout: .milliseconds(1500))
        #expect(log.replies == [false])
        #expect(log.prompts.count == 1)
        #expect(log.timedOut == [true], "the bound is reported as still saving, not as a refusal")
    }

    @Test("a flush that finishes after the bound, while the user is asked, still ends the quit cleanly")
    func lateSuccessAfterTimeout() async {
        let log = QuitLog()
        var attempts = 0
        coordinator(log, answers: [.retry]).begin(flush: {
            attempts += 1
            if attempts == 1 { try? await Task.sleep(for: .milliseconds(200)) }
            return true
        }, timeout: .milliseconds(30))
        await waitForReply(log)
        try? await Task.sleep(for: .milliseconds(300))   // the late first flush lands after the reply
        #expect(log.replies == [true], "exactly one reply, from the retried attempt")
        #expect(log.prompts.count == 1)
    }

    @Test("QUIT, real store: refused write → copy + ask; fixed + Retry → saved and quit")
    func quitEndToEnd() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-failedquit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = NotesIndex(url: root.appendingPathComponent("index.db"))
        try await index.open()
        let org = OrganizationStore(index: index)
        try await org.load(storeRoot: root)
        let store = NoteStore(root: root)
        let model = NotesModel(organization: org, index: index, noteStore: store)
        let item = Item(id: UUID(), kind: .note, title: "Quit note", authors: [], date: nil,
                        datePrecision: nil, dateUncertain: false, quality: nil, tags: [], zotero: [],
                        roundup: false, created: Date(), modified: Date(), schema: 1, blocks: [],
                        unknownFrontMatter: [], trailingBodyRaw: "Before.")
        _ = try await store.create(item)
        let dir = NoteStore.itemDir(root: root, id: item.id)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            Task { await index.close(); try? FileManager.default.removeItem(at: root) }
        }
        let editor = NoteBodyEditorModel()
        editor.saveDebounce = .seconds(60)
        editor.load = { await model.loadBody(for: $0) }
        editor.checkedSave = { await model.saveEditorBody($1, basedOn: $2, for: $0) }
        await editor.select(item.id)
        editor.markdown = "Typed right before quit."
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)

        let vault = UnsavedDraftVault(directory: root.appendingPathComponent("vault"))
        let registry = EditorFlushRegistry(vault: vault)
        registry.register(UUID(), flush: { await editor.flushPending() }, draft: {
            editor.unsavedDraft.map { EditorDraft(itemID: $0.id, title: "Quit note", markdown: $0.markdown) }
        })
        let log = QuitLog()
        var copied: [URL] = []
        TerminateFlushCoordinator(
            reply: { log.replies.append($0) },
            writeCopies: { let urls = registry.writeEmergencyCopies(); copied = urls ?? []; return urls },
            prompt: { _, _ in
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
                return .retry
            }
        ).begin(flush: { await registry.flushAll() }, timeout: .seconds(5))
        await waitForReply(log)

        #expect(log.replies == [true])
        #expect(copied.count == 1)
        #expect(await model.loadBody(for: item.id) == "Typed right before quit.")
        #expect(!FileManager.default.fileExists(atPath: copied[0].path), "copy removed after the retry saved")
    }
}
