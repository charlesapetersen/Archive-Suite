import Testing
import AppKit
import SwiftUI
import ArchiveCore
import ArchiveCoreUI
@testable import ArchiveNotes

/// W49.notes-suspects-small — the reproduce attempts for suspects S-012, S-016, S-010, S-011 and S-014 (phase rule
/// 5a; S-008 needs a real quit and relaunch, so it runs in the VM, `NotesWindowSizeQuitUITests`). Each takes the
/// user's own path on scratch data: the row menu's own `NSMenuItem`s fired, the real list table hosted and sorted,
/// the filter bar's tag field's own completion rules, the real resolver on a granted scratch root.
///
/// A reproduced check is a known issue: the run stays green while the defect is there and fails once it is gone,
/// when the fix removes the `withKnownIssue`. Phase rule 5a(4): a second session on another model checks each
/// reproduction before a fix item is filed (`W49.notes-suspects-small-check`).
@Suite("Notes smaller suspects — reproduce attempts (W49.notes-suspects-small)", .serialized)
@MainActor
struct NotesSmallSuspectTests {

    // MARK: - Scratch store

    private struct Env {
        let root: URL
        let index: NotesIndex
        let org: OrganizationStore
        let store: NoteStore
        let model: NotesModel
        let nav: NotesNavigationModel
    }

    private func makeEnv() async throws -> Env {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesSmallSuspectTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = NotesIndex(url: root.appendingPathComponent("index.db"))
        try await index.open()
        let org = OrganizationStore(index: index)
        try await org.load(storeRoot: root)
        let store = NoteStore(root: root)
        let model = NotesModel(organization: org, index: index, noteStore: store)
        let nav = NotesNavigationModel(model: model, defaultKind: .note)
        return Env(root: root, index: index, org: org, store: store, model: model, nav: nav)
    }

    private func cleanup(_ env: Env) async {
        await env.index.close()
        try? FileManager.default.removeItem(at: env.root)
    }

    /// The row menu's actions run in a `Task`; wait for what they change.
    private func eventually(_ timeout: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    /// Fires a menu item the way a click does: its target's action.
    private func click(_ item: NSMenuItem) throws {
        let action = try #require(item.target as? NotesMenuAction, "\(item.title) has no action")
        action.fire()
    }

    private func itemDirExists(_ env: Env, _ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: env.root.appendingPathComponent("items", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true).path)
    }

    private func body(of id: UUID, in env: Env) async throws -> String {
        let item = try await env.store.load(id)
        return BlockParser.serialize(leadingText: item.trailingBodyRaw, blocks: item.blocks)
    }

    // MARK: - S-012

    /// S-012: a tag added in the app is stored title-cased; the filter bar's tag field is typed in lower case.
    @Test("S-012: a tag added as \"intel\" is found by the filter bar's tag field typed \"intel\"")
    func s012TagFilterCase() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try #require(await env.model.newItem(kind: .note, in: nil, from: nil))
        let unrelatedID = try #require(await env.model.newItem(kind: .note, in: nil, from: nil))
        #expect(await env.model.addTag("intel", to: id))   // the tag bar's add
        #expect(await env.model.addTag("intelligence", to: unrelatedID))
        let stored = try #require(env.model.allItems.first { $0.id == id })
        #expect(stored.managedTags == ["Intel"], "the app stores the tag title-cased")
        #expect(env.nav.displayed.contains { $0.id == id })

        // The field skips the exact case-insensitive match in the completion list and fills in
        // nothing for it, so Return submits the original spelling.
        let suggestions = NoteTagChipsField.suggestions(in: env.model.allItems)
        let completions = TagEntry.completions(for: "intel", in: suggestions)
        #expect(completions == ["Intelligence"])
        #expect(TagEntry.filledInIndex(for: "intel", in: completions, among: suggestions, anyCase: true) == -1)
        env.nav.filter.tags.append("intel")

        #expect(env.nav.displayed.map(\.id) == [id])
        #expect(TagEntry.completions(for: "inte", in: suggestions).contains("Intel"))

        // Submitting just a prefix should produce an empty list.
        env.nav.filter.tags = ["inte"]
        #expect(env.nav.displayed.isEmpty)

        env.nav.filter.tags = ["intel"]
        await env.nav.saveAsSmartFolder(named: "Intel notes")
        let saved = try #require(env.org.folders.first { $0.name == "Intel notes" })
        env.nav.filter = NotesFilter()
        env.model.applySmartScope(saved.id)
        #expect(env.model.selectedSmartId == saved.id)
        #expect(env.nav.displayed.map(\.id) == [id])
    }

    // MARK: - S-016

    /// S-016: a click on a list column header sets the table's sort descriptors from the column's prototype.
    @Test("S-016: the list's table re-sorts by Title in both directions")
    func s016HeaderSort() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let stamp = Date(timeIntervalSince1970: 0)
        func summary(_ title: String, _ sortDate: Int) -> ItemSummary {
            ItemSummary(id: UUID(), title: title, kind: .note, date: nil, datePrecision: nil, dateUncertain: false,
                        sortDate: sortDate, quality: nil, created: stamp, modified: stamp, mtime: 0, managedTags: [])
        }
        env.model.replaceItems([summary("Beta", 19000101), summary("Alpha", 20000101)])
        #expect(env.nav.displayed.map(\.title) == ["Beta", "Alpha"], "the default sort is by date")

        let host = NSHostingView(rootView: NotesTableView(model: env.nav, selection: .constant([]),
                                                          onDoubleClick: {}, buildContextMenu: { _ in nil }))
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 300)
        host.layoutSubtreeIfNeeded()
        func findTable(in parent: NSView) -> NSTableView? {
            if let table = parent as? NSTableView { return table }
            return parent.subviews.lazy.compactMap { findTable(in: $0) }.first
        }
        let table = try #require(findTable(in: host))
        let title = try #require(table.tableColumns.first { $0.identifier.rawValue == NotesTableView.titleColumnID })
        let prototype = try #require(title.sortDescriptorPrototype, "the Title header is sortable")

        // The same descriptor changes AppKit makes for the first click and the direction toggle.
        table.sortDescriptors = [prototype]
        #expect(env.nav.sort.first == NoteSortDescriptor(field: .title, ascending: true))
        #expect(env.nav.displayed.map(\.title) == ["Alpha", "Beta"])

        let reversed = try #require(prototype.reversedSortDescriptor as? NSSortDescriptor)
        table.sortDescriptors = [reversed]
        #expect(env.nav.sort.first == NoteSortDescriptor(field: .title, ascending: false))
        #expect(env.nav.displayed.map(\.title) == ["Beta", "Alpha"])
    }

    // MARK: - S-010

    /// S-010: the actual row menu, with sole instances and a note already replicated in G.
    @Test("S-010: the row menu asks about every sole instance and rechecks each confirmed membership")
    func s010MultiRemove() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let f = try await env.org.createFolder(name: "F").id
        let g = try await env.org.createFolder(name: "G").id
        let a = try #require(await env.model.newItem(kind: .note, in: f, from: nil))
        let b = try #require(await env.model.newItem(kind: .note, in: f, from: nil))
        let c = try #require(await env.model.newItem(kind: .note, in: f, from: nil))
        let d = try #require(await env.model.newItem(kind: .note, in: f, from: nil))
        let titles = [a: "Survey A", b: "Survey B", d: "Survey D"]
        for (id, title) in titles { try #require(await env.model.setTitle(title, to: id)) }
        try await env.org.addMembership(item: c, folder: g)
        env.model.setFolderScope(f)

        let registry = EditorFlushRegistry()
        let menu = try #require(NotesItemContextMenu.make(nav: env.nav, selection: [a, b, c, d], flushing: registry))
        let remove = try #require(menu.items.first { $0.title == "Remove 4 Items from “F”" })
        try click(remove)

        try #require(await eventually { env.nav.pendingDeletion != nil })
        #expect(itemDirExists(env, c) && env.org.foldersContaining(item: c) == [g], "the replicant stays in G")
        for id in titles.keys {
            #expect(itemDirExists(env, id) && env.org.foldersContaining(item: id) == [f])
        }

        let first = try #require(env.nav.pendingDeletion)
        #expect(first.title == titles[first.itemId])
        try #require(await env.nav.confirmPendingDeletion(first))
        #expect(await env.store.isTrashed(first.itemId))
        #expect(!itemDirExists(env, first.itemId) && env.org.foldersContaining(item: first.itemId).isEmpty)

        let second = try #require(env.nav.pendingDeletion)
        #expect(second.title == titles[second.itemId])
        env.nav.cancelPendingDeletion(second)
        #expect(itemDirExists(env, second.itemId) && env.org.foldersContaining(item: second.itemId) == [f])

        let third = try #require(env.nav.pendingDeletion)
        #expect(third.title == titles[third.itemId])
        #expect(Set([first.itemId, second.itemId, third.itemId]) == Set(titles.keys))
        // Another window added a placement after the batch was staged. Confirm only unlinks F.
        try await env.org.addMembership(item: third.itemId, folder: g)
        #expect(await !env.nav.confirmPendingDeletion(third))
        #expect(itemDirExists(env, third.itemId) && env.org.foldersContaining(item: third.itemId) == [g])
        #expect(env.nav.pendingDeletion == nil)
    }

    // MARK: - S-011

    private struct TemplateEnv {
        let env: Env
        let templateID: UUID
        let templateDir: URL
        let registry: EditorFlushRegistry
        let editor: NoteBodyEditorModel
        let noteID: UUID
    }

    /// A note template open in the Templates pane, as `TemplateBodyEditorPane.onAppear` makes it (the pattern of
    /// `TemplateFailedSaveTests`), and one note in the list to right-click.
    private func makeTemplateEnv() async throws -> TemplateEnv {
        let env = try await makeEnv()
        let tid = try #require(await env.model.createTemplate(name: "Interview", kind: .note))
        let dir = await env.store.templateDir(tid)
        let registry = EditorFlushRegistry(vault: UnsavedDraftVault(
            directory: env.root.appendingPathComponent("vault", isDirectory: true)))
        let editor = NoteBodyEditorModel()
        editor.saveDebounce = .seconds(60)
        editor.load = { await env.model.loadTemplateBody(for: $0) }
        editor.save = { id, markdown in
            await env.model.setTemplateBody(markdown, for: id)
            registry.trackTemplateBody(id, in: env.model)
        }
        registry.register(UUID(), flush: { await editor.flushPending() })
        await editor.select(tid)
        let note = try #require(await env.model.newItem(kind: .note, in: nil, from: nil))
        return TemplateEnv(env: env, templateID: tid, templateDir: dir, registry: registry, editor: editor, noteID: note)
    }

    private func setWritable(_ url: URL, _ writable: Bool) {
        try? FileManager.default.setAttributes([.posixPermissions: writable ? 0o755 : 0o555], ofItemAtPath: url.path)
    }

    /// Right-click the note ▸ New from Template ▸ Interview; returns the new note's id.
    private func newFromTemplateInRowMenu(_ t: TemplateEnv) async throws -> UUID? {
        let before = Set(t.env.model.allItems.map(\.id))
        let menu = try #require(NotesItemContextMenu.make(nav: t.env.nav, selection: [t.noteID], flushing: t.registry))
        let sub = try #require(menu.items.first { $0.title == "New from Template" }?.submenu)
        try click(try #require(sub.items.first { $0.title == "Interview" }))
        _ = await eventually(3) { Set(t.env.model.allItems.map(\.id)) != before }
        return Set(t.env.model.allItems.map(\.id)).subtracting(before).first
    }

    @Test("S-011: the row menu's New from Template includes a template edit still waiting to save")
    func s011RowMenuSkipsFlush() async throws {
        let t = try await makeTemplateEnv(); defer { Task { await cleanup(t.env) } }
        let folder = try await t.env.org.createFolder(name: "Interviews").id
        try await t.env.org.addMembership(item: t.noteID, folder: folder)
        t.env.model.setFolderScope(folder)
        t.editor.markdown = "Questions MARKER-S011"   // typed, still inside the debounce
        t.registry.register(UUID(), flush: { [model = t.env.model] in
            model.setAllNotesScope()   // The scope can change while creation waits for a save.
            return true
        })

        let made = try #require(try await newFromTemplateInRowMenu(t), "the row menu makes a note")
        #expect(try await body(of: made, in: t.env).contains("MARKER-S011"))
        #expect(t.env.model.selectedFolderId == nil)
        #expect(t.env.org.foldersContaining(item: made) == [folder])
        #expect(await eventually { t.env.nav.selection == [made] })
    }

    @Test("S-011: the row menu's New from Template refuses a template whose body save still fails")
    func s011RowMenuSkipsFailedSaveGuard() async throws {
        let t = try await makeTemplateEnv(); defer { setWritable(t.templateDir, true); Task { await cleanup(t.env) } }
        setWritable(t.templateDir, false)
        t.editor.markdown = "Refused draft"
        await t.editor.flushPending()
        try #require(t.env.model.hasFailedTemplateBodySave(t.templateID), "the store refused the body")
        t.env.nav.select(t.noteID)

        #expect(try await newFromTemplateInRowMenu(t) == nil, "no note is made from the stale template body")
        #expect(t.env.nav.selection == [t.noteID])
        #expect(t.env.model.hasFailedTemplateBodySave(t.templateID))

        setWritable(t.templateDir, true)
        let made = try #require(try await newFromTemplateInRowMenu(t), "creation resumes once the draft can save")
        #expect(try await body(of: made, in: t.env).contains("Refused draft"))
        #expect(await eventually { t.env.nav.selection == [made] })
    }

    // MARK: - S-014

    /// S-014: the archive folder is renamed while Notes runs, after a link in it has been opened once.
    @Test("S-014: renaming the archive during a session leaves the search incomplete")
    func s014MovedRoot() async throws {
        let suiteName = "NotesSmallSuspectTests-S014-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fm = FileManager.default
        let parent = fm.temporaryDirectory.appendingPathComponent("NotesSmallSuspectTests-S014-\(UUID().uuidString)",
                                                                  isDirectory: true)
        let root = parent.appendingPathComponent("Archive", isDirectory: true)
        let moved = parent.appendingPathComponent("Archive (moved)", isDirectory: true)
        defer { try? fm.removeItem(at: parent) }
        try fm.createDirectory(at: root.appendingPathComponent("Box 1", isDirectory: true),
                               withIntermediateDirectories: true)
        let guid = UUID()
        try JSONEncoder().encode(RootMarker(guid: guid, name: "Archive", kind: .reader, createdAt: Date()))
            .write(to: root.appendingPathComponent(RootMarker.filename), options: .atomic)
        try Data("%PDF-1.4 scratch\n".utf8).write(to: root.appendingPathComponent("Box 1/doc.pdf"), options: .atomic)

        let store = ReaderRootStore(defaults: defaults)
        store.grantRoot(root)
        let resolver = ReaderLinkResolver(rootStore: store)
        let first = await resolver.resolve(rootGUID: guid, relativePath: "Box 1/doc.pdf")
        guard case .resolved = first else { Issue.record("before the move: \(first)"); return }

        try fm.moveItem(at: root, to: moved)
        let after = await resolver.resolve(rootGUID: guid, relativePath: "Box 1/doc.pdf")
        #expect(after == .searchIncomplete(scanned: 0))
        #expect(fm.fileExists(atPath: moved.appendingPathComponent("Box 1/doc.pdf").path))

        // A relaunch: a fresh store reads the bookmark, which follows the folder.
        let relaunched = await ReaderLinkResolver(rootStore: ReaderRootStore(defaults: defaults))
            .resolve(rootGUID: guid, relativePath: "Box 1/doc.pdf")
        guard case .resolved(let url) = relaunched else { Issue.record("after a relaunch: \(relaunched)"); return }
        #expect(url.path.contains("Archive (moved)"))
    }
}
