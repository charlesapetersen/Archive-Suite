import Foundation
import ArchiveCore

/// The UI façade every Notes view binds to (00-overview §16.1). It owns the single organization graph
/// (`OrganizationStore`) and — in the app path — the backing index + store-root, and exposes the
/// rendered folder tree + current scope as `@Published` state plus `async` mutation methods.
///
/// W6-S2 delivers the **folder-tree slice**: the rebuilt tree, folder scope selection, and the four
/// mutations (create / rename / move / delete) routed through `OrganizationStore`, whose writes are
/// already atomic (DB + `organization.json`). Later sub-tasks extend this same façade with the item
/// list (S3), search/filter/sort (S4), templates (S6), and `openItem(id:block:)` navigation (W4/W7).
///
/// Concurrency (§16.9): `@MainActor`; the actor-backed I/O it calls (`NotesIndex`, `OrganizationStore`
/// awaits) is awaited from here, and published state is only mutated on the main actor.
@MainActor
final class NotesModel: ObservableObject {
    /// The single organization graph shared by both windows. Mutations persist atomically.
    let organization: OrganizationStore

    // MARK: Rendered tree state (rebuilt after every mutation / store load)

    /// Hierarchical forest of normal folders (the "Folders" section).
    @Published private(set) var normalTree: [NotesFolderNode] = []
    /// Flat list of user smart folders (the "Smart Folders" section), excluding the All-Notes root.
    @Published private(set) var smartFolders: [NotesFolderNode] = []
    /// Distinct items across the whole store — the badge on the "All Notes" pseudo-row. (Membership-
    /// based here; the exact index-served count arrives with the item list in W6-S4.)
    @Published private(set) var allNotesCount: Int = 0

    // MARK: Item list source (W6-S3)

    /// Every indexed item (the `ItemSummary` projection, §16.5), shared by both windows. Each window's
    /// `NotesNavigationModel` filters + sorts this into its own `displayed` list, so the two windows can
    /// differ by kind/sort/selection while reading one source of truth. Loaded on bootstrap and
    /// refreshable via `reloadItems()`.
    @Published private(set) var allItems: [ItemSummary] = []

    // MARK: Templates (W6-S6)

    /// Every template on disk (id / name / kind), shared by both windows. Loaded on bootstrap and
    /// after any template mutation. Drives the folder "Template ▸" assignment menu + "New from
    /// template" (06-viewers §6). Kept out of `allItems` so templates never appear in the note list.
    @Published private(set) var templates: [Template] = []

    // MARK: Current scope (drives the item list in W6-S3/S4)

    /// The active filter scope: `nil` = All Notes (no scope). A normal folder scopes by `folderId`;
    /// a smart folder applies its decoded `NotesFilter`.
    @Published private(set) var scope: NotesFilter?
    /// Highlighted normal folder (nil when All Notes / a smart folder is selected).
    @Published private(set) var selectedFolderId: UUID?
    /// Highlighted smart folder (nil when All Notes / a normal folder is selected).
    @Published private(set) var selectedSmartId: UUID?

    /// Transient, user-facing status for degradations (cycle refused, unreadable smart query, orphaned
    /// items after a folder delete). The view surfaces it and clears it.
    @Published var statusMessage: String?

    // MARK: App-path lifecycle (nil when a test injects a pre-loaded store)

    private let ownsDataLayer: Bool
    private let index: NotesIndex?
    private let rootStore: RootFolderStore?
    /// The only file-deleting layer (W2, §16.1). Built in `bootstrap()` on the app path; injectable for
    /// tests. `delete(_:)` moves an item dir to the macOS Trash (recoverable) — never `removeItem`.
    private var noteStore: NoteStore?
    private var didBootstrap = false

    // MARK: Init

    /// Injection init (tests, previews): the caller provides an already-loaded `OrganizationStore`.
    init(organization: OrganizationStore) {
        self.organization = organization
        self.ownsDataLayer = false
        self.index = nil
        self.rootStore = nil
        rebuild()
    }

    /// Injection init with a live index — for tests that exercise FTS `search(_:)` or the W6-S5 delete
    /// path (`noteStore`). Like `init(organization:)` but routes keyword search to a real `NotesIndex`
    /// and, when a `noteStore` is supplied, the delete-last-instance path to a real (scratch) store. It
    /// still does **not** own the data layer (`bootstrap()` stays a no-op), so callers seed items via
    /// `replaceItems`.
    init(organization: OrganizationStore, index: NotesIndex, noteStore: NoteStore? = nil) {
        self.organization = organization
        self.ownsDataLayer = false
        self.index = index
        self.rootStore = nil
        self.noteStore = noteStore
        rebuild()
    }

    /// App init: build the real data layer (index + org store + store-root). The tree stays empty
    /// until `bootstrap()` runs (call it from a `.task` before first render) so no blocking I/O
    /// happens during `App` construction.
    convenience init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ArchiveNotes", isDirectory: true)
        let index = NotesIndex(url: appSupport.appendingPathComponent("notes-index-v1.sqlite3"))
        self.init(organization: OrganizationStore(index: index),
                  index: index,
                  rootStore: RootFolderStore())
    }

    private init(organization: OrganizationStore, index: NotesIndex, rootStore: RootFolderStore) {
        self.organization = organization
        self.ownsDataLayer = true
        self.index = index
        self.rootStore = rootStore
        // Tree stays empty until bootstrap().
    }

    /// App path only: open the index and load persisted organization, then rebuild. Idempotent — safe
    /// to call from a `.task` that may re-run. A no-op for an injected (test) store.
    func bootstrap() async {
        guard ownsDataLayer, !didBootstrap else { return }
        didBootstrap = true
        guard let index, let rootStore, let root = rootStore.root else { rebuild(); return }
        noteStore = NoteStore(root: root)
        do {
            try await index.open()
            try await organization.load(storeRoot: root)
        } catch {
            report(error, "open the notes store")
        }
        rebuild()
        await reloadItems()
        await reloadTemplates()
    }

    // MARK: Item list loading (W6-S3)

    /// Reload the shared item set from the index (app path). A no-op for an injected (test) store,
    /// which seeds items via `replaceItems(_:)` instead.
    func reloadItems() async {
        guard let index else { return }
        let items = await index.allSummaries()
        replaceItems(items)
    }

    /// Replace the shared item set. The app path calls this from `reloadItems()`; tests call it
    /// directly to seed synthetic summaries without a real index. Published, so each window's
    /// navigation model recomputes its `displayed` list.
    func replaceItems(_ items: [ItemSummary]) {
        allItems = items
    }

    // MARK: Keyword search (W6-S4)

    /// Full-text search over the disposable index, in bm25 relevance order (best match first). Returns
    /// `[]` for a blank query or an injected (index-less) store. The per-window `NotesNavigationModel`
    /// intersects this with its filtered set and orders by rank (06-viewers §4, §11).
    func search(_ query: String) async -> [UUID] {
        guard let index, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return await index.search(query)
    }

    // MARK: Templates (W6-S6 — §3.7, §6, §16.4)

    /// Reload the template list from the store. A no-op with no `noteStore` (an injected test store
    /// built without one); template tests inject a scratch `noteStore`.
    func reloadTemplates() async {
        guard let noteStore else { return }
        templates = await noteStore.allTemplates()
    }

    /// Templates whose kind matches `kind` — the offering set for "New from template" (§6).
    func templates(matching kind: Item.Kind) -> [Template] {
        templates.filter { $0.kind == kind }
    }

    /// Assign `templateId` to `folderId` (`nil` clears it). Persisted atomically via `OrganizationStore`
    /// (DB + organization.json). Template↔folder lives only in `template_assignments` (§16.4).
    func assignTemplate(_ templateId: UUID?, to folderId: UUID) async {
        do {
            if let templateId { try await organization.assignTemplate(templateId, to: folderId) }
            else { try await organization.removeTemplateAssignment(folder: folderId) }
        } catch { report(error, "assign the template") }
    }

    /// The effective template for `folderId`: the nearest ancestor's live assignment (self first),
    /// else `nil` ("Blank"). An assignment pointing at a deleted template is skipped **and** lazily
    /// cleared (§6 dangling edge case), off the resolve path so this stays a pure read.
    func effectiveTemplate(for folderId: UUID?) -> Template? {
        let existing = Set(templates.map(\.id))
        let (tid, dangling) = TemplateResolution.resolve(
            folderId: folderId, folders: organization.folders,
            assignments: organization.assignments, existingTemplateIDs: existing)
        if !dangling.isEmpty { Task { await clearDanglingAssignments(dangling) } }
        guard let tid else { return nil }
        return templates.first { $0.id == tid }
    }

    private func clearDanglingAssignments(_ folderIds: [UUID]) async {
        for f in folderIds { try? await organization.removeTemplateAssignment(folder: f) }
        rebuild()
    }

    /// Create a new template of `kind` named `name` (empty body). Returns the new id.
    @discardableResult
    func createTemplate(name rawName: String, kind: Item.Kind) async -> UUID? {
        guard let noteStore else { return nil }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { statusMessage = "A template needs a name."; return nil }
        let item = blankItem(kind: kind, title: uniqueTemplateName(name))
        do {
            _ = try await noteStore.createTemplate(item)
            await reloadTemplates()
            return item.id
        } catch { report(error, "create the template"); return nil }
    }

    /// Duplicate a template (fresh id + " copy" name), preserving kind + front-matter defaults + body.
    @discardableResult
    func duplicateTemplate(_ id: UUID) async -> UUID? {
        guard let noteStore else { return nil }
        do {
            var item = try await noteStore.loadTemplate(id)
            item.id = UUID()
            item.title = uniqueTemplateName("\(item.title) copy")
            item.created = Date(); item.modified = Date()
            _ = try await noteStore.createTemplate(item)
            await reloadTemplates()
            return item.id
        } catch { report(error, "duplicate the template"); return nil }
    }

    /// Rename a template (its title = its display name = its filename).
    func renameTemplate(_ id: UUID, to rawName: String) async {
        guard let noteStore else { return }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { statusMessage = "A template needs a name."; return }
        do {
            var item = try await noteStore.loadTemplate(id)
            item.title = name; item.modified = Date()
            _ = try await noteStore.saveTemplate(item)
            await reloadTemplates()
        } catch { report(error, "rename the template") }
    }

    /// Delete a template (to Trash) and clear every folder assignment that pointed at it (batched, §6).
    /// Assignments are cleared FIRST so no folder is left referencing a since-trashed template (the
    /// dangling-resolution fallback would also cover a stray, but keep the graph clean).
    func deleteTemplate(_ id: UUID) async {
        guard let noteStore else { return }
        let referencing = organization.assignments.filter { $0.templateId == id }.map(\.folderId)
        for folderId in referencing {
            try? await organization.removeTemplateAssignment(folder: folderId)
        }
        do { try await noteStore.deleteTemplate(id) }
        catch { report(error, "delete the template") }
        await reloadTemplates()
        rebuild()
    }

    // MARK: New item (blank or from a template) (W6-S6)

    /// Create a new item of `kind` in `folderId` (`nil` ⟹ the system default: Inbox for a note,
    /// Extracts for an extract, §16.6), instantiated from `templateId` when given: the template's
    /// front-matter defaults (title/date/quality/tags/authors/roundup) + body are cloned into a fresh
    /// item (new UUID, fresh created/modified). Returns the new item id (nil on failure / no store).
    @discardableResult
    func newItem(kind: Item.Kind, in folderId: UUID?, from templateId: UUID?) async -> UUID? {
        guard let noteStore else { return nil }
        var item: Item
        if let templateId {
            do { item = try await noteStore.loadTemplate(templateId) }
            catch { report(error, "read the template"); return nil }
            item.id = UUID()
            item.kind = kind
            item.created = Date(); item.modified = Date()
        } else {
            item = blankItem(kind: kind, title: "")
        }
        let target = folderId ?? (kind == .extract ? organization.extractsHomeFolderId
                                                    : OrganizationStore.inboxFolderId)
        do {
            _ = try await noteStore.create(item)
            try await organization.addMembership(item: item.id, folder: target)
            await reloadItems()
            rebuild()
            return item.id
        } catch { report(error, "create the note"); return nil }
    }

    /// A fresh, empty item shell (schema 1) — a blank new item or a new template.
    private func blankItem(kind: Item.Kind, title: String) -> Item {
        let now = Date()
        return Item(id: UUID(), kind: kind, title: title, authors: [], date: nil,
                    datePrecision: nil, dateUncertain: false, quality: nil, tags: [],
                    zotero: [], roundup: false, created: now, modified: now, schema: 1,
                    blocks: [], unknownFrontMatter: [], trailingBodyRaw: nil)
    }

    /// A name-unique template name (case-insensitive), appending " 2", " 3", … if taken.
    private func uniqueTemplateName(_ base: String) -> String {
        let taken = Set(templates.map { $0.name.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: Metadata edits (W6-S7 — dates & quality, §16.1)
    //
    // Front-matter ONLY (00-overview D2/D9): a note's date + quality live in its own `.md` YAML, never
    // in a macOS Finder tag. These methods DELIBERATELY do not touch `NotesTagProjector` — subjects are
    // the one projected facet. Each loads the item through the `NoteStore` actor, mutates a single
    // field, writes it back atomically, re-indexes that one row, and refreshes the shared `allItems` so
    // both windows' lists + the detail header update live.

    /// Set the item's date + precision (a `nil`/blank date clears the date entirely). The pair is
    /// normalized (`Item.normalizedDate`) so the stored string always matches its precision, keeping
    /// `sortDate` correct — decade → `decade * 10_000`; an uncertain date still sorts by its value
    /// (rendered italic), never dumped last.
    func setDate(_ date: String?, precision: Item.DatePrecision?, for id: UUID) async {
        let n = Item.normalizedDate(date, precision: precision)
        await mutateItem(id, "set the date") { item in
            item.date = n.date
            item.datePrecision = n.precision
        }
    }

    /// Toggle the "date uncertain" flag (the date renders italic but still sorts by its value).
    func setDateUncertain(_ uncertain: Bool, for id: UUID) async {
        await mutateItem(id, "set date uncertainty") { $0.dateUncertain = uncertain }
    }

    /// Set the quality rating (1...5, 5 highest; `nil` clears it — the "None" case). Written to the
    /// front-matter `quality` key ONLY (priority-style, D9) — never a Finder tag. Values are clamped
    /// into 1...5 defensively (the UI offers only None + 1…5).
    func setQuality(_ quality: Int?, for id: UUID) async {
        let clamped = quality.map { min(max($0, 1), 5) }
        await mutateItem(id, "set the quality") { $0.quality = clamped }
    }

    /// Shared load → mutate → atomic save → single-row re-index → publish path for the field editors
    /// above. A no-op with no `noteStore` (an injected test model built without one). The on-disk `.md`
    /// is the source of truth and the index is a rebuilt-from-disk projection, so nothing here can
    /// corrupt data; errors surface via `statusMessage` like the other mutations.
    private func mutateItem(_ id: UUID, _ action: String, _ mutate: (inout Item) -> Void) async {
        guard let noteStore else { return }
        do {
            var item = try await noteStore.load(id)
            mutate(&item)
            item.modified = Date()
            let ref = try await noteStore.save(item)
            if let index { try await index.upsertBatch([NoteIndexRow(item: item, mtime: ref.mtime)]) }
            await reloadItems()
        } catch { report(error, action) }
    }

    // MARK: Tree rebuild

    /// Recompute the rendered tree + counts from the current organization graph. Call after any
    /// mutation. Cheap (O(F + M)); the shared model is the single source of tree state for both windows.
    func rebuild() {
        let folders = organization.folders
        let memberships = organization.memberships
        normalTree = NotesFolderNode.buildNormalForest(folders: folders, memberships: memberships)
        smartFolders = NotesFolderNode.smartFolderNodes(
            folders: folders, excluding: [OrganizationStore.allNotesFolderId])
        allNotesCount = Set(memberships.map(\.itemId)).count
    }

    // MARK: Scope selection

    /// Scope to a normal folder. `nil` or the All-Notes root clears the scope (show everything). The
    /// no-op guard (already scoped to `id`) is the second half of the sidebar selection-sync
    /// loop-breaker (the view holds the first; see Reader `SidebarView.swift:8-13`).
    func setFolderScope(_ id: UUID?) {
        guard let id, id != OrganizationStore.allNotesFolderId else { setAllNotesScope(); return }
        guard selectedFolderId != id || selectedSmartId != nil else { return }
        selectedFolderId = id
        selectedSmartId = nil
        scope = NotesFilter(folderId: id)
    }

    /// Clear the scope — the "All Notes" pseudo-row.
    func setAllNotesScope() {
        guard selectedFolderId != nil || selectedSmartId != nil || scope != nil else { return }
        selectedFolderId = nil
        selectedSmartId = nil
        scope = nil
    }

    /// Apply a smart folder's saved query as the scope. An unreadable `queryJSON` degrades to All
    /// Notes with a status message (mirrors Reader's `sanitizedPathPrefix` degrade,
    /// `NavigationModel.swift:417-422`).
    func applySmartScope(_ id: UUID) {
        guard let f = organization.folders.first(where: { $0.id == id }), f.kind == .smart else { return }
        guard let json = f.queryJSON, let data = json.data(using: .utf8),
              let filter = try? JSONDecoder().decode(NotesFilter.self, from: data) else {
            statusMessage = "This smart folder's saved query is unreadable."
            setAllNotesScope()
            return
        }
        selectedSmartId = id
        selectedFolderId = nil
        scope = filter
    }

    // MARK: Mutations (routed through OrganizationStore — atomic DB + organization.json writes)

    /// Create a normal folder under `parent`. Whitespace-trimmed; empty rejected; the name is deduped
    /// against siblings with the ` 2`, ` 3` suffix logic (copied in spirit from
    /// `SavedSearchStore.uniqueName`, `SavedSearch.swift:63-69`).
    @discardableResult
    func createFolder(name rawName: String, under parent: UUID?) async -> UUID? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { statusMessage = "A folder needs a name."; return nil }
        let unique = uniqueSiblingName(name, parent: parent, excluding: nil)
        do {
            let created = try await organization.createFolder(name: unique, parent: parent, kind: .normal)
            rebuild()
            return created.id
        } catch { report(error, "create the folder"); return nil }
    }

    /// Create a root-level **smart** folder whose saved `NotesFilter` is persisted as `queryJSON`
    /// (§16.3) — the "Save as Smart Folder" action from the filter bar (W6-S4). Name trimmed, empty
    /// rejected, sibling-deduped. Returns the new folder id.
    @discardableResult
    func createSmartFolder(name rawName: String, query: NotesFilter) async -> UUID? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { statusMessage = "A smart folder needs a name."; return nil }
        let unique = uniqueSiblingName(name, parent: nil, excluding: nil)
        guard let data = try? JSONEncoder().encode(query),
              let json = String(data: data, encoding: .utf8) else {
            statusMessage = "Couldn't encode the smart folder's query."; return nil
        }
        do {
            let created = try await organization.createFolder(
                name: unique, parent: nil, kind: .smart, queryJSON: json)
            rebuild()
            return created.id
        } catch { report(error, "create the smart folder"); return nil }
    }

    /// Rename a folder. Whitespace-trimmed; empty rejected; deduped against siblings (excluding self).
    func renameFolder(_ id: UUID, to rawName: String) async {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { statusMessage = "A folder needs a name."; return }
        let parent = organization.folders.first { $0.id == id }?.parentId
        let unique = uniqueSiblingName(name, parent: parent, excluding: id)
        do { try await organization.renameFolder(id, to: unique); rebuild() }
        catch { report(error, "rename the folder") }
    }

    /// Move `id` under `newParent` at position `index`. `OrganizationStore.moveFolder` silently no-ops
    /// a cycle-creating move; we detect the same condition first so the user gets an explanation rather
    /// than a mystery no-op.
    func moveFolder(_ id: UUID, newParent: UUID?, at index: Int) async {
        if wouldCreateCycle(moving: id, to: newParent) {
            statusMessage = "You can't move a folder into itself or one of its own subfolders."
            return
        }
        do { try await organization.moveFolder(id, newParent: newParent, sortOrder: index); rebuild() }
        catch { report(error, "move the folder") }
    }

    /// Delete a folder (never its items). `OrganizationStore.deleteFolder` reparents children to the
    /// deleted folder's parent and returns the ids of items left in **no** folder; those remain
    /// reachable under All Notes, and we surface a status message. The batched sole-instance
    /// confirmation UI is W6-S5 (delete path, Tier-2). Returns the orphaned item ids for the caller.
    @discardableResult
    func deleteFolder(_ id: UUID) async -> [UUID] {
        do {
            let orphaned = try await organization.deleteFolder(id)
            if selectedFolderId == id { setAllNotesScope() }
            rebuild()
            if !orphaned.isEmpty {
                let n = orphaned.count
                statusMessage = "\(n) item\(n == 1 ? "" : "s") \(n == 1 ? "is" : "are") no longer in any folder — find \(n == 1 ? "it" : "them") under All Notes."
            }
            return orphaned
        } catch { report(error, "delete the folder"); return [] }
    }

    // MARK: Delete-last-instance path (W6-S5, Tier-2 — §3.6, 06-viewers §5)

    /// Items that would be **permanently deleted** (moved to Trash) by deleting `folderId`: those whose
    /// *only* membership is this folder. Read FRESH from the org graph at call time (no cached count),
    /// so a concurrent replicate in the other window can't cause a false positive (§5, analogous to
    /// TagWriter's fresh-read-inside-the-write rule). Empty ⟹ deleting the folder loses no note (its
    /// items live elsewhere too, and its subfolders are reparented, not deleted).
    func strandedByDeletingFolder(_ folderId: UUID) -> [UUID] {
        organization.items(in: folderId).filter { organization.membershipCount(item: $0) == 1 }
    }

    /// Titles for `ids` (from the shared item source), for the delete-confirmation copy. Missing items
    /// fall back to "Untitled".
    func titles(for ids: [UUID]) -> [String] {
        let byID = Dictionary(allItems.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        return ids.map { byID[$0].map { $0.isEmpty ? "Untitled" : $0 } ?? "Untitled" }
    }

    /// Delete `folderId` and permanently delete (to Trash) the `stranded` sole-instance notes it held.
    /// The caller has shown + confirmed the §3.6 batched modal. Order is deliberate: remove memberships
    /// (the durable org graph) FIRST via `OrganizationStore.deleteFolder`, THEN trash the files — so if
    /// a trash fails the note is still on disk *and* discoverable under All Notes (0 memberships),
    /// never silently lost. Subfolders are reparented (never deleted) by `deleteFolder`.
    func deleteFolderDeletingStranded(_ folderId: UUID, stranded: [UUID]) async {
        let orphaned: [UUID]
        do {
            orphaned = try await organization.deleteFolder(folderId)   // removes memberships, reparents children
        } catch { report(error, "delete the folder"); return }
        if selectedFolderId == folderId { setAllNotesScope() }
        // Trash ONLY items that (a) the user confirmed as stranded AND (b) are *actually* orphaned now
        // (0 memberships) — `deleteFolder` returns the fresh orphan set, so a replicate between the
        // modal and this confirm rescues its item from deletion (it keeps its other membership).
        let confirmed = Set(stranded)
        await trashItems(orphaned.filter { confirmed.contains($0) })   // trashes + drops rows + reloads
        rebuild()                                                      // covers the empty case
    }

    /// Move the given items' folders to the macOS Trash (recoverable — `NoteStore.delete` never
    /// `removeItem`s) and drop their index rows. The caller must have already removed the items'
    /// memberships (0 remaining) — the §3.6 guard passed. A per-item trash failure is logged and the
    /// rest proceed (best-effort; the org graph is already consistent). Reloads the shared item list +
    /// rebuilds the tree. A no-op with no `noteStore` (injected test store without one) beyond the
    /// index/reload bookkeeping.
    func trashItems(_ ids: [UUID]) async {
        guard !ids.isEmpty else { return }
        if let noteStore {
            for id in ids {
                do { try await noteStore.delete(id) }
                catch { NSLog("NotesModel: could not move note \(id) to Trash: \(error)") }
            }
        }
        if let index { try? await index.deleteItems(ids) }
        await reloadItems()
        rebuild()
    }

    // MARK: Pure helpers (unit-tested)

    /// Would moving `id` under `newParent` create a cycle? True if `newParent == id` or `id` is an
    /// ancestor of `newParent`. Mirrors `OrganizationStore.wouldCreateCycle` so the view can explain a
    /// refused move; a `guardCount` cap makes it total even against a corrupt graph.
    func wouldCreateCycle(moving id: UUID, to newParent: UUID?) -> Bool {
        guard let newParent else { return false }
        if newParent == id { return true }
        let byID = Dictionary(organization.folders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var cursor: UUID? = newParent
        var guardCount = 0
        while let c = cursor, guardCount < 100_000 {
            if c == id { return true }
            cursor = byID[c]?.parentId
            guardCount += 1
        }
        return false
    }

    /// A sibling-unique folder name: returns `base` if no sibling under `parent` (other than
    /// `excluding`) already uses it (case-insensitively), else `base 2`, `base 3`, … until free.
    func uniqueSiblingName(_ base: String, parent: UUID?, excluding: UUID?) -> String {
        let taken = Set(organization.folders
            .filter { $0.parentId == parent && $0.id != excluding }
            .map { $0.name.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: Private

    private func report(_ error: Error, _ action: String) {
        statusMessage = "Couldn't \(action)."
        NSLog("NotesModel: failed to \(action): \(error)")
    }
}
