import Testing
import Foundation
@testable import ArchiveNotes

/// W40.fix-notes-failed-save-close-fu1 — a template body the store refuses must survive quit, a crash and
/// the window closing, as a note's does. Real scratch store; the refusal is made by removing write
/// permission from the template's own `Templates/<uuid>/` folder, then restored.
@Suite("Failed template save — quit, crash and close keep the body")
@MainActor
struct TemplateFailedSaveTests {
    private struct Env {
        let root: URL
        let store: NoteStore
        let model: NotesModel
        let index: NotesIndex
        let templateID: UUID
        let dir: URL
        let vault: UnsavedDraftVault
    }

    private func makeEnv() async throws -> Env {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-tplfailed-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = NotesIndex(url: root.appendingPathComponent("index.db"))
        try await index.open()
        let org = OrganizationStore(index: index)
        try await org.load(storeRoot: root)
        let store = NoteStore(root: root)
        let model = NotesModel(organization: org, index: index, noteStore: store)
        let id = try #require(await model.createTemplate(name: "Interview", kind: .note))
        let dir = await store.templateDir(id)
        let vault = UnsavedDraftVault(directory: root.appendingPathComponent("vault", isDirectory: true))
        return Env(root: root, store: store, model: model, index: index, templateID: id, dir: dir, vault: vault)
    }

    /// Synchronous, so a read-only scratch folder is writable again before the async removal runs.
    private func restore(_ env: Env) { setWritable(env.dir, true) }

    private func cleanup(_ env: Env) async {
        restore(env)
        await env.index.close()
        try? FileManager.default.removeItem(at: env.root)
    }

    private func setWritable(_ url: URL, _ writable: Bool) {
        try? FileManager.default.setAttributes([.posixPermissions: writable ? 0o755 : 0o555], ofItemAtPath: url.path)
    }

    /// The template pane's editor and registration, exactly as `TemplateBodyEditorPane.onAppear` makes them.
    private func pane(_ env: Env, _ pane: UUID, in registry: EditorFlushRegistry) -> NoteBodyEditorModel {
        let editor = NoteBodyEditorModel()
        editor.saveDebounce = .seconds(60)
        editor.load = { await env.model.loadTemplateBody(for: $0) }
        editor.save = { id, markdown in
            await env.model.setTemplateBody(markdown, for: id)
            registry.trackTemplateBody(id, in: env.model)
        }
        registry.register(pane, flush: { await editor.flushPending() })
        return editor
    }

    private func vaultTexts(_ env: Env) throws -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: env.vault.directory, includingPropertiesForKeys: nil)) ?? []
        return try files.map { try String(contentsOf: $0, encoding: .utf8) }
    }

    @Test("QUIT: a refused body is copied at once, refuses quit, is recoverable from the copy, and saves on retry")
    func quitAfterRefusedTemplateSave() async throws {
        let env = try await makeEnv(); defer { restore(env); Task { await cleanup(env) } }
        let registry = EditorFlushRegistry(vault: env.vault)
        let paneID = UUID()
        let editor = pane(env, paneID, in: registry)
        await editor.select(env.templateID)
        setWritable(env.dir, false)

        editor.markdown = "Questions"
        await editor.flushPending()
        #expect(try vaultTexts(env) == ["Questions"], "copied before any close or quit: a crash loses nothing")
        editor.markdown = "Questions to ask."
        await editor.flushPending()
        #expect(try vaultTexts(env) == ["Questions to ask."], "one copy, following the text")

        // Quit while writes are refused: the flush fails, so the coordinator asks instead of quitting.
        #expect(await registry.flushAll() == false)
        #expect(registry.unsavedDrafts().map(\.title) == ["Interview"])
        let copies = try #require(registry.writeEmergencyCopies())
        #expect(copies.count == 1)
        // "Quit" anyway, then restore: the body is in the copy even though the process (and the model's
        // memory) is gone.
        #expect(try String(contentsOf: copies[0], encoding: .utf8) == "Questions to ask.")
        let onDisk = try await env.store.loadTemplate(env.templateID)
        #expect((onDisk.trailingBodyRaw ?? "").isEmpty, "the refused write left the template untouched")

        // A retry once the folder is writable saves the body and clears the copy and the tracking.
        setWritable(env.dir, true)
        #expect(await registry.flushAll())
        registry.deregister(paneID)
        #expect(registry.isEmpty)
        #expect(try vaultTexts(env).isEmpty)
        #expect(env.model.unsavedTemplateBody(env.templateID) == nil)
        let reloaded = NotesModel(organization: OrganizationStore(index: env.index), index: env.index, noteStore: env.store)
        #expect(await reloaded.loadTemplateBody(for: env.templateID) == "Questions to ask.")
    }

    @Test("QUIT, first refusal: a body refused for the first time inside the quit flush still refuses quit")
    func firstRefusalDuringQuit() async throws {
        let env = try await makeEnv(); defer { restore(env); Task { await cleanup(env) } }
        let registry = EditorFlushRegistry(vault: env.vault)
        let editor = pane(env, UUID(), in: registry)
        await editor.select(env.templateID)
        setWritable(env.dir, false)
        // Typed within the debounce window, nothing refused yet: quit's own flush is the first save.
        editor.markdown = "Typed just before quit."
        #expect(await registry.flushAll() == false, "the template entry registered mid-flush is flushed too")
        #expect(registry.unsavedDrafts().map(\.markdown) == ["Typed just before quit."])
        #expect(try vaultTexts(env) == ["Typed just before quit."])
    }

    @Test("CLOSE: the closed template pane asks with the template's name; Retry after the fix saves it")
    func closeAfterRefusedTemplateSave() async throws {
        let env = try await makeEnv(); defer { restore(env); Task { await cleanup(env) } }
        let registry = EditorFlushRegistry(vault: env.vault)
        var asked: [(String, URL?)] = []
        registry.presentCloseFailure = { title, copy in
            asked.append((title, copy))
            if asked.count == 2 { self.setWritable(env.dir, true) }
            return .retry
        }
        let paneID = UUID()
        let editor = pane(env, paneID, in: registry)
        await editor.select(env.templateID)
        setWritable(env.dir, false)
        editor.markdown = "Saved by retry."

        // The pane's teardown: flush, drop the pane's own entry, close the template's through paneClosed.
        await editor.flushPending()
        registry.deregister(paneID)
        #expect(!registry.isEmpty, "the refused body is still tracked after its pane is gone")
        await registry.paneClosed(env.templateID)
        #expect(asked.count == 2, "it asked again while the write still failed")
        #expect(asked.first?.0 == "Interview")
        #expect(asked.first?.1 != nil, "the alert names the emergency copy")
        #expect(registry.isEmpty)
        #expect(try vaultTexts(env).isEmpty)
        #expect(await env.model.loadTemplateBody(for: env.templateID) == "Saved by retry.")
    }

    @Test("CLOSE, keep: a kept body is retained, reloaded by a new pane, and a newer save there wins")
    func keptBodyReopenedElsewhere() async throws {
        let env = try await makeEnv(); defer { restore(env); Task { await cleanup(env) } }
        let registry = EditorFlushRegistry(vault: env.vault)
        registry.presentCloseFailure = { _, _ in .keep }
        let first = pane(env, UUID(), in: registry)
        await first.select(env.templateID)
        setWritable(env.dir, false)
        first.markdown = "Older draft."
        await first.flushPending()
        await registry.paneClosed(env.templateID)
        #expect(registry.retainedPaneIDs == [env.templateID])

        // Another window opens the template: it gets the held draft, not the stale disk body.
        setWritable(env.dir, true)
        let secondID = UUID()
        let second = pane(env, secondID, in: registry)
        await second.select(env.templateID)
        #expect(second.markdown == "Older draft.")
        second.markdown = "Newer draft."
        await second.flushPending()
        #expect(registry.retainedPaneIDs.isEmpty, "the save there resolved the kept body")
        #expect(try vaultTexts(env).isEmpty)
        #expect(await registry.flushAll())
        #expect(await env.model.loadTemplateBody(for: env.templateID) == "Newer draft.",
                "the closed window never writes its older buffer over the newer save")
    }

    @Test("SWITCH: leaving a refused template for another keeps the first tracked, and quit still refuses")
    func switchAwayKeepsTracking() async throws {
        let env = try await makeEnv(); defer { restore(env); Task { await cleanup(env) } }
        let other = try #require(await env.model.createTemplate(name: "Letter", kind: .note))
        let registry = EditorFlushRegistry(vault: env.vault)
        let editor = pane(env, UUID(), in: registry)
        await editor.select(env.templateID)
        setWritable(env.dir, false)
        editor.markdown = "Left behind."
        await editor.select(nil)
        await editor.select(other)
        #expect(editor.loadedID == other, "the switch still goes through")
        #expect(await registry.flushAll() == false)
        #expect(registry.unsavedDrafts().map(\.markdown) == ["Left behind."])
        #expect(try vaultTexts(env) == ["Left behind."])
    }

    @Test("ORDER: a retry started beside a newer save waits for it, so the newer body is what stays on disk")
    func retryWaitsForNewerSave() async throws {
        let env = try await makeEnv(); defer { restore(env); Task { await cleanup(env) } }
        setWritable(env.dir, false)
        #expect(!(await env.model.setTemplateBody("Older held body.", for: env.templateID)))
        setWritable(env.dir, true)
        let newer = Task { await env.model.setTemplateBody("Newer body.", for: env.templateID) }
        let retry = Task { await env.model.retryTemplateBody(env.templateID) }
        #expect(await newer.value)
        #expect(await retry.value)
        #expect(env.model.unsavedTemplateBody(env.templateID) == nil)
        let onDisk = try await env.store.loadTemplate(env.templateID)
        #expect(BlockParser.serialize(leadingText: onDisk.trailingBodyRaw, blocks: onDisk.blocks) == "Newer body.",
                "the older held body never lands after the newer save")
    }

    @Test("a deleted template's held body no longer refuses quit, and its emergency copy stands")
    func deletedTemplateReleasesQuit() async throws {
        let env = try await makeEnv(); defer { restore(env); Task { await cleanup(env) } }
        let registry = EditorFlushRegistry(vault: env.vault)
        let paneID = UUID()
        let editor = pane(env, paneID, in: registry)
        await editor.select(env.templateID)
        setWritable(env.dir, false)
        editor.markdown = "Doomed."
        await editor.flushPending()
        setWritable(env.dir, true)
        await env.model.deleteTemplate(env.templateID)
        #expect(env.model.unsavedTemplateBody(env.templateID) == nil)
        #expect(await registry.flushAll())
        #expect(try vaultTexts(env) == ["Doomed."], "the trash holds only the old body; the copy is the text's last home")
    }

    @Test("a deleted template's copy stands when the pane's next save fails against the deleted template")
    func deletedTemplateCopySurvivesLaterSave() async throws {
        let env = try await makeEnv(); defer { restore(env); Task { await cleanup(env) } }
        let registry = EditorFlushRegistry(vault: env.vault)
        let editor = pane(env, UUID(), in: registry)
        await editor.select(env.templateID)
        setWritable(env.dir, false)
        editor.markdown = "Held."
        await editor.flushPending()
        setWritable(env.dir, true)
        await env.model.deleteTemplate(env.templateID)
        editor.markdown = "Typed after the delete."
        await editor.flushPending()   // fails: the template is gone, and nothing is held for it
        #expect(await registry.flushAll())
        #expect(try vaultTexts(env) == ["Held."])
    }
}
