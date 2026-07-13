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
        do {
            try await index.open()
            try await organization.load(storeRoot: root)
        } catch {
            report(error, "open the notes store")
        }
        rebuild()
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
