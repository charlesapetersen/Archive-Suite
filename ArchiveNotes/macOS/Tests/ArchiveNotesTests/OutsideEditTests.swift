import Testing
import Foundation
@testable import ArchiveNotes

/// W40.fix-notes-outside-edit-overwrite — real scratch .md edits, outside NoteStore's actor/revisions.
@Suite("Outside edits — original and in-app draft both survive")
@MainActor
struct OutsideEditTests {
    private struct Env {
        let root: URL
        let store: NoteStore
        let model: NotesModel
        let index: NotesIndex
        let item: Item
        let file: URL
    }

    private func makeEnv() async throws -> Env {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-outside-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = NotesIndex(url: root.appendingPathComponent("index.db"))
        try await index.open()
        let org = OrganizationStore(index: index)
        try await org.load(storeRoot: root)
        let store = NoteStore(root: root)
        let item = Item(id: UUID(), kind: .note, title: "Original", authors: [], date: nil,
                        datePrecision: nil, dateUncertain: false, quality: nil, tags: [], zotero: [],
                        roundup: false, created: Date(), modified: Date(), schema: 1, blocks: [],
                        unknownFrontMatter: [], trailingBodyRaw: "Original paragraph.")
        let ref = try await store.create(item)
        try await org.addMembership(item: item.id, folder: OrganizationStore.inboxFolderId)
        let model = NotesModel(organization: org, index: index, noteStore: store)
        return Env(root: root, store: store, model: model, index: index, item: item, file: ref.url)
    }

    private func cleanup(_ env: Env) async {
        await env.index.close()
        try? FileManager.default.removeItem(at: env.root)
    }

    private func editor(_ env: Env) -> NoteBodyEditorModel {
        let editor = NoteBodyEditorModel()
        editor.saveDebounce = .seconds(60)
        editor.load = { await env.model.loadBody(for: $0) }
        editor.checkedSave = { await env.model.saveEditorBody($1, basedOn: $2, for: $0) }
        return editor
    }

    @Test("a clean editor reloads outside body changes without writing the original")
    func cleanReload() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let editor = editor(env)
        await editor.select(env.item.id)
        let outside = try String(contentsOf: env.file, encoding: .utf8) + "\nOutside paragraph.\n"
        try Data(outside.utf8).write(to: env.file)
        await editor.refreshFromDisk()
        #expect(editor.markdown.contains("Outside paragraph."))
        #expect(editor.externalChangeMessage != nil)
        #expect(editor.reloadGeneration == 1)
        await editor.flushPending()
        #expect(try Data(contentsOf: env.file) == Data(outside.utf8))
        #expect(await env.store.allItemIDs().count == 1)
    }

    @Test("dirty editor preserves original bytes, full draft, assets and discoverability", arguments: [false, true])
    func conflictPreservesBoth(atomic: Bool) async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let editor = editor(env)
        await editor.select(env.item.id)
        let image = Data([137, 80, 78, 71, 7, 8])
        let assetPath = try await env.store.importAsset(image, preferredName: "scan.png", into: env.item.id)
        let draft = "My unsaved draft.\n\n![scan](\(assetPath))"
        editor.markdown = draft
        let outside = try String(contentsOf: env.file, encoding: .utf8)
            .replacingOccurrences(of: "title: Original", with: "title: Outside title\nexternal_key: keep me")
            + "\nExternaluniquetoken paragraph.\n"
        try Data(outside.utf8).write(to: env.file, options: atomic ? [.atomic] : [])
        await editor.refreshFromDisk()  // must not replace the dirty draft
        #expect(editor.markdown == draft)
        await editor.flushPending()   // same path as selection, close and quit
        #expect(try Data(contentsOf: env.file) == Data(outside.utf8), "the original is byte-identical")
        let ids = await env.store.allItemIDs().filter { $0 != env.item.id }
        let recoveryID = try #require(ids.first)
        #expect(ids.count == 1)
        let recovery = try await env.store.load(recoveryID)
        #expect(recovery.title.contains("Recovered draft"))
        #expect(BlockParser.serialize(leadingText: recovery.trailingBodyRaw, blocks: recovery.blocks) == draft)
        let copiedAsset = NoteStore.itemDir(root: env.root, id: recoveryID).appendingPathComponent(assetPath)
        #expect(try Data(contentsOf: copiedAsset) == image)
        #expect(env.model.organization.memberships.contains { $0.itemId == recoveryID })
        #expect(await env.index.search("unsaved").contains(recoveryID))
        #expect(await env.index.search("Externaluniquetoken").contains(env.item.id))
        #expect(editor.markdown.contains("Externaluniquetoken"))
        #expect(!editor.markdown.contains("My unsaved draft"))
        #expect(env.model.statusMessage?.contains("Recovered draft") == true)
        // The baseline advances to the reloaded original. Future edits save normally, without another copy.
        editor.markdown += "\nAfter recovery."
        await editor.flushPending()
        #expect(await env.store.allItemIDs().count == 2)
        #expect(await env.model.loadBody(for: env.item.id)?.contains("Externaluniquetoken") == true)
        #expect(await env.model.loadBody(for: env.item.id)?.contains("After recovery.") == true)
    }

    @Test("a recovery materializes contained asset symlinks without reading escaping ones")
    func recoveryAssetLinks() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let asset = NoteStore.assetsDir(root: env.root, id: env.item.id).appendingPathComponent("scan.png")
        let bytes = Data([1, 2, 3, 4])
        try bytes.write(to: asset)
        let alias = asset.deletingLastPathComponent().appendingPathComponent("alias.png")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: asset)
        let escape = asset.deletingLastPathComponent().appendingPathComponent("blocked.png")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: env.root.appendingPathComponent("missing.png"))
        let editor = editor(env)
        await editor.select(env.item.id)
        editor.markdown = "![scan](assets/alias.png)"
        let outside = try String(contentsOf: env.file, encoding: .utf8) + "\nExternal."
        try Data(outside.utf8).write(to: env.file)
        await editor.flushPending()
        let ids = await env.store.allItemIDs().filter { $0 != env.item.id }
        let id = try #require(ids.first)
        let recoveredAsset = NoteStore.assetsDir(root: env.root, id: id).appendingPathComponent("alias.png")
        #expect(try Data(contentsOf: recoveredAsset) == bytes)
        #expect(recoveredAsset.resolvingSymlinksInPath() == recoveredAsset)
        if case .resolved = AssetPathResolver.resolve("assets/alias.png", inItemDirectory: NoteStore.itemDir(root: env.root, id: id)) {
        } else { Issue.record("recovered asset must resolve inside the recovery item") }
        #expect(try Data(contentsOf: env.file) == Data(outside.utf8))
    }

    @Test("a pending pasted asset is awaited before a conflict snapshot")
    func pendingAssetBeforeRecovery() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let editor = editor(env)
        let assets = ItemAssetStore(store: env.store, root: env.root, itemID: env.item.id)
        editor.prepareSave = { await assets.awaitPendingWrites() }
        await editor.select(env.item.id)
        let bytes = Data([9, 8, 7, 6])
        let path = try assets.addAsset(bytes, preferredName: "pending.png")
        editor.markdown = "![pending](\(path))"
        let outside = try String(contentsOf: env.file, encoding: .utf8) + "\nExternal."
        try Data(outside.utf8).write(to: env.file)
        await editor.flushPending()
        let ids = await env.store.allItemIDs().filter { $0 != env.item.id }
        let id = try #require(ids.first)
        #expect(try Data(contentsOf: NoteStore.itemDir(root: env.root, id: id).appendingPathComponent(path)) == bytes)
    }

    @Test("outside front matter edits do not conflict with body typing")
    func metadataOnly() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let editor = editor(env)
        await editor.select(env.item.id)
        var outside = try await env.store.load(env.item.id)
        outside.authors = ["Outside Author"]
        outside.unknownFrontMatter = [UnknownKey(key: "external_key", rawLines: ["external_key: preserved"])]
        try Data(FrontMatterCodec.encode(outside).utf8).write(to: env.file)
        editor.markdown = "Typed paragraph."
        await editor.flushPending()
        let saved = try await env.store.load(env.item.id)
        #expect(saved.authors == ["Outside Author"])
        #expect(saved.unknownFrontMatter == outside.unknownFrontMatter)
        #expect(saved.trailingBodyRaw == "Typed paragraph.")
        #expect(await env.store.allItemIDs().count == 1)
    }

    @Test("two editors hold independent baselines, including another in-app body edit")
    func independentEditors() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let first = editor(env), second = editor(env)
        await first.select(env.item.id)
        await second.select(env.item.id)
        first.markdown = "First editor's version."
        await first.flushPending()
        second.markdown = "Second editor's version."
        await second.flushPending()
        #expect(await env.model.loadBody(for: env.item.id) == "First editor's version.")
        let ids = await env.store.allItemIDs().filter { $0 != env.item.id }
        #expect(ids.count == 1)
        #expect(await env.model.loadBody(for: try #require(ids.first)) == "Second editor's version.")
    }

    @Test("failed recovery retains the dirty buffer through selection and retries successfully")
    func recoveryFailureRetainsDraft() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let editor = editor(env)
        await editor.select(env.item.id)
        editor.markdown = "Draft must survive failure."
        let outside = try String(contentsOf: env.file, encoding: .utf8) + "\nOutside edit.\n"
        try Data(outside.utf8).write(to: env.file)
        let items = env.root.appendingPathComponent("items")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: items.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: items.path) }
        await editor.select(nil)
        #expect(editor.loadedID == env.item.id)
        #expect(editor.markdown == "Draft must survive failure.")
        #expect(try Data(contentsOf: env.file) == Data(outside.utf8))
        #expect(env.model.statusMessage?.contains("Couldn't save") == true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: items.path)
        await editor.select(nil)
        #expect(editor.loadedID == nil)
        let ids = await env.store.allItemIDs().filter { $0 != env.item.id }
        #expect(ids.count == 1)
        #expect(await env.model.loadBody(for: try #require(ids.first)) == "Draft must survive failure.")
    }
}
