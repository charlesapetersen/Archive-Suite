import Foundation

// MARK: - Value types (Sendable, Codable — cross-actor payloads per §16.9)

/// A virtual folder in the organizational graph (§3, §4).
struct VFolder: Sendable, Equatable, Identifiable, Codable {
    var id: UUID
    var name: String
    var parentId: UUID?
    var sortOrder: Int
    enum Kind: String, Sendable, Codable { case normal, smart }
    var kind: Kind
    /// Encoded `NotesFilter` for smart folders (§16.3); nil for normal folders.
    var queryJSON: String?
}

/// A membership binding an item to a folder (many-to-many replication).
struct Membership: Sendable, Equatable, Codable {
    var itemId: UUID
    var folderId: UUID
    var addedAt: Date
}

/// A template assigned to a folder; W6 resolves via ancestor walk (§16.4).
struct TemplateAssignment: Sendable, Equatable, Codable {
    var folderId: UUID
    var templateId: UUID
}

/// Result of `removeMembership`: `.removed` if the membership was deleted,
/// `.wasLastInstance` if removing would leave the item with zero memberships
/// (caller must show the §3.6 delete-last-instance confirmation), or `.notPresent` if the requested
/// `(item, folder)` pair no longer exists at all — **nothing was removed**, so the caller must treat
/// it as a no-op + refresh and never as a last instance (W23.h3).
enum RemoveResult: Sendable { case removed; case wasLastInstance; case notPresent }

/// Outcome of a **confirmed** §3.6 delete-last-instance (`removeConfirmedLastMembership`). Every case
/// is decided from the membership set the removal *actually applied to* — never from a bare count —
/// because only `.deletedLastInstance` licenses the caller to trash the note (W23.h3).
enum ConfirmedRemoveResult: Sendable {
    /// The pair existed, was removed, and the item now has **zero** memberships: really the last
    /// instance. The caller completes the deletion (trash the note + drop its index row).
    case deletedLastInstance
    /// The pair existed and was removed, but the item still holds other memberships (a concurrent
    /// replicate or move). Unlinked only — the caller must **keep** the file.
    case unlinkedNotLast
    /// The pair was already gone when the confirm arrived — a **stale** alert. Nothing was removed and
    /// the note may well be filed elsewhere; the caller must keep the file and refresh.
    case notPresent
}

/// A refusal from `OrganizationStore` — a mutation the graph will not perform, as opposed to a
/// storage failure (W23.m15).
///
/// The first two are **permanent backstops**, not the primary UX: the sidebar disables Rename/Delete on
/// a system folder, and every replicate/move target comes from the rendered tree. They exist so a future
/// caller that skips those checks gets a refusal instead of silently destroying a system folder or
/// minting a membership to a folder that does not exist. `itemBeingDeleted` is different in kind — a
/// **transient** refusal that lasts only as long as one confirmed hard delete (W23.h3-fu).
enum OrganizationError: Error, LocalizedError, Equatable {
    /// A rename/delete aimed at one of the three fixed-ID system folders (§16.6).
    case systemFolderImmutable(name: String)
    /// A membership aimed at a folder id that is not in the graph — the ghost-membership defect.
    case unknownFolder(UUID)
    /// A membership aimed at an item whose **confirmed** hard delete is already in flight. Granting it
    /// would leave a live membership row pointing at a note that is on its way to the Trash (W23.h3-fu).
    case itemBeingDeleted(UUID)

    var errorDescription: String? {
        switch self {
        case .systemFolderImmutable(let name):
            return "“\(name)” is a built-in folder — it can't be renamed or deleted."
        case .unknownFolder(let id):
            return "That folder no longer exists (\(id.uuidString))."
        case .itemBeingDeleted:
            return "That note is being deleted — it can't be filed into a folder."
        }
    }
}

/// Why `organization.json` — the durable mirror (§4/§11) — does not currently reflect committed
/// organization state (W23.m10). `nil` means it does.
enum OrganizationMirrorFailure: Sendable, Equatable {
    /// The export ran and failed: a full, read-only or vanished volume, or an encode error.
    case writeFailed(detail: String)
    /// No store root is configured, so there is nowhere to mirror to and nothing was written at all.
    case noStoreRoot

    /// One line for the sidebar status line — the same surface `NotesIndexer.Failure` uses (W23.m9).
    var message: String {
        switch self {
        case .writeFailed(let d):
            return "Folder organization couldn't be saved to organization.json (\(d)) — the change is "
                 + "live now, but rebuilding the notes index or opening this store on another Mac "
                 + "would bring the older organization back."
        case .noStoreRoot:
            return "Folder organization isn't being saved to disk — no notes store is open, so this "
                 + "change is only in memory."
        }
    }
}

// MARK: - OrganizationStore

/// Owns the folder tree, memberships, and template assignments (§16.1).
/// Persists to the index DB **and** `organization.json` (atomic) on every mutation.
/// The DB is a disposable cache; `organization.json` is the durable mirror (§11).
@MainActor final class OrganizationStore: ObservableObject {
    /// Stable system folder IDs (§16.6) — deterministic across launches.
    static let allNotesFolderId  = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let inboxFolderId     = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let extractsFolderId  = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    /// The canonical shape of every system folder — **one** definition, used both to seed a fresh
    /// store and to restore a system folder that went missing (W23.m15). Order is the sidebar order.
    ///
    /// Restoration is by **ID**, and only when the id is absent: a system folder the user renamed
    /// keeps its name, because "missing" and "not called Inbox any more" are different questions.
    static let systemFolderSeeds: [VFolder] = [
        VFolder(id: allNotesFolderId, name: "All Notes", parentId: nil,
                sortOrder: 0, kind: .smart, queryJSON: nil),
        VFolder(id: inboxFolderId, name: "Inbox", parentId: nil,
                sortOrder: 1, kind: .normal, queryJSON: nil),
        VFolder(id: extractsFolderId, name: "Extracts", parentId: nil,
                sortOrder: 2, kind: .normal, queryJSON: nil),
    ]

    /// Whether `id` is one of the three fixed-ID system folders (§16.6) — the ids the app itself files
    /// into (`newItem` → Inbox, `createExtract` → Extracts) and that the sidebar always shows.
    static func isSystemFolder(_ id: UUID) -> Bool {
        systemFolderSeeds.contains { $0.id == id }
    }

    /// The **canonical** name of a system folder id (not the user's possibly-renamed one) — for the
    /// refusal message. `nil` for a user folder.
    static func systemFolderName(_ id: UUID) -> String? {
        systemFolderSeeds.first { $0.id == id }?.name
    }

    @Published private(set) var folders: [VFolder] = []
    @Published private(set) var memberships: [Membership] = []
    @Published private(set) var assignments: [TemplateAssignment] = []

    /// Why the durable mirror is stale, when it is (`nil` = `organization.json` matches what has been
    /// committed). Published so the UI can say so, and readable by a caller **synchronously right after
    /// its `await`** (this store is `@MainActor`) to find out whether the mutation it just made actually
    /// reached disk — that is the seam W23.m13 needs for its rollback decisions.
    ///
    /// Deliberately observable STATE rather than an error thrown out of each mutation. Three reasons,
    /// all load-bearing — do not "simplify" this back into a `throws`:
    /// 1. The export is the LAST step of every mutation, so by the time it can fail the SQLite and
    ///    in-memory change has already committed. Throwing would make ~17 call sites report "Couldn't
    ///    create the folder" about a folder that *exists*, and skip the `rebuild()` that shows it — a
    ///    worse lie than the silence being fixed here.
    /// 2. Callers swallow mutation errors on exactly the paths at issue, so a thrown error would go
    ///    unseen there: `clearDanglingAssignments` still uses `try?` by design (it is a lazy background
    ///    tidy off the resolve path). W23.m13 removed the other two — `deleteTemplate` and `move`'s
    ///    source removal now report — but they report the *mutation's* failure; the mirror is a
    ///    separate degradation that outlives the call, which is the next reason.
    /// 3. Staleness persists until a later export succeeds. That is a state, not an event.
    @Published private(set) var mirrorFailure: OrganizationMirrorFailure?

    /// `true` while `organization.json` does not reflect committed organization state.
    var isMirrorStale: Bool { mirrorFailure != nil }

    private let index: NotesIndex
    private var storeRoot: URL?

    /// `true` once `load(storeRoot:)` has finished reading the graph — the precondition for a
    /// *speculative* re-export (W23.m10-fu). `load` assigns `storeRoot` before it awaits the DB, so
    /// between those two points the store has a destination but not yet the graph that belongs in it.
    /// A mutation can never fall into that window (it is what fills the graph), but an opportunistic
    /// retry fires on an app notification at an arbitrary moment, and exporting there would overwrite
    /// the user's `organization.json` with a half-built forest.
    private var didLoadGraph = false

    /// The Extracts system folder ID (§16.1 / §16.6).
    var extractsHomeFolderId: UUID { Self.extractsFolderId }

    init(index: NotesIndex) {
        self.index = index
    }

    /// Load the organizational graph from the DB; if the DB has no folders
    /// but `organization.json` exists, rebuild the DB from the JSON (§4).
    /// Seeds system folders if neither source has data.
    ///
    /// **Every path ends with all three system folders present (W23.m15).** They used to be seeded only
    /// when the whole folder table was empty, so a store that had *any* other folder came up without a
    /// deleted Inbox or Extracts — permanently, since nothing else ever recreated them while the app
    /// kept filing new notes and extracts under their fixed ids. Restoration is by id, so it is a no-op
    /// for a healthy store and cannot clobber a rename.
    func load(storeRoot: URL) async throws {
        self.storeRoot = storeRoot

        let dbFolders = await index.allFolders()
        if dbFolders.isEmpty {
            if let file = OrganizationFile.load(from: storeRoot) {
                let restored = missingSystemFolders(in: file.folders)
                folders = file.folders + restored
                // Drop graph edges that point at a folder the mirror does not define. Such an edge is
                // already invisible — no row can render it and no restore can revive it — and with the
                // memberships FK in place it would fail the import outright, turning a tidy-up into a
                // store that will not open. The system folders are restored FIRST (above), so the
                // common case — edges left behind by a deleted Inbox/Extracts — is *revived*, not lost.
                let live = Set(folders.map(\.id))
                memberships = file.memberships.filter { live.contains($0.folderId) }
                assignments = file.assignments.filter { live.contains($0.folderId) }
                let dropped = (file.memberships.count - memberships.count)
                            + (file.assignments.count - assignments.count)
                if dropped > 0 {
                    NSLog("OrganizationStore: dropped \(dropped) organization.json edge(s) with no folder")
                }
                try await index.replaceOrganization(
                    folders: folders, memberships: memberships, assignments: assignments)
                // Only when the import ADDED something (a restored system folder). A dropped edge
                // leaves the mirror alone on purpose: the DB is the live truth from here, the next
                // mutation re-exports the whole graph anyway, and a read path should not be the thing
                // that rewrites the user's durable file.
                if !restored.isEmpty { exportOrganization() }
            } else {
                folders = Self.systemFolderSeeds
                for f in folders { try await index.insertFolder(f) }
            }
        } else {
            folders = dbFolders
            memberships = await index.allMemberships()
            assignments = await index.allTemplateAssignments()

            let restored = missingSystemFolders(in: dbFolders)
            if !restored.isEmpty {
                for f in restored { try await index.insertFolder(f) }
                folders.append(contentsOf: restored)
                // Bring the mirror back in line with the restored graph immediately, rather than
                // waiting for the user's next folder mutation.
                exportOrganization()
            }
        }

        didLoadGraph = true
    }

    // MARK: - Folder operations

    @discardableResult
    func createFolder(name: String, parent: UUID? = nil, kind: VFolder.Kind = .normal,
                      queryJSON: String? = nil) async throws -> VFolder {
        let folder = VFolder(
            id: UUID(), name: name, parentId: parent,
            sortOrder: nextSortOrder(under: parent), kind: kind, queryJSON: queryJSON)
        try await index.insertFolder(folder)
        folders.append(folder)
        exportOrganization()
        return folder
    }

    func renameFolder(_ id: UUID, to name: String) async throws {
        try refuseSystemFolder(id)
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        var updated = folders[i]
        updated.name = name
        try await index.updateFolder(updated)
        folders[i] = updated
        exportOrganization()
    }

    /// Move a folder to a new parent. Refuses (no-op) if the move would create a cycle.
    func moveFolder(_ id: UUID, newParent: UUID?, sortOrder: Int) async throws {
        guard !wouldCreateCycle(moving: id, to: newParent) else { return }
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        var updated = folders[i]
        updated.parentId = newParent
        updated.sortOrder = sortOrder
        try await index.updateFolder(updated)
        folders[i] = updated
        exportOrganization()
    }

    /// Delete a folder. Children are reparented to the deleted folder's parent.
    /// Returns UUIDs of items that became orphaned (zero memberships remaining)
    /// so the caller can show the batch-delete confirmation (§3.6).
    ///
    /// **All-or-nothing, and memory never runs ahead of the disk (W23.m13).** This used to be four
    /// independent awaited writes with the in-memory reparent applied *before* its own DB update, so a
    /// SQLite failure part-way through left the graph half-deleted in memory and differently
    /// half-deleted on disk. A throw from here now means nothing changed anywhere: the DB legs are one
    /// transaction, and every in-memory mutation happens after it commits.
    ///
    /// **Refuses a system folder (W23.m15).** Inbox and Extracts are the fixed ids `newItem` and
    /// `createExtract` file into, and `load` only ever *restored* them when the folder table was
    /// entirely empty — so deleting one was permanent while the app went on writing memberships to it.
    @discardableResult
    func deleteFolder(_ id: UUID) async throws -> [UUID] {
        try refuseSystemFolder(id)
        let deletedParent = folders.first(where: { $0.id == id })?.parentId

        // Reparent children to the deleted folder's parent (or root) — as COPIES. Nothing in `folders`
        // moves until the transaction below says the whole deletion committed.
        var reparented: [VFolder] = []
        for f in folders where f.parentId == id {
            var child = f
            child.parentId = deletedParent
            reparented.append(child)
        }

        try await index.deleteFolderGraph(id: id, reparentedChildren: reparented)

        // Committed. Now — and only now — move memory to match. `affectedMemberships` is read here
        // rather than before the await so it reflects the same set the `DELETE … WHERE folder_id = ?`
        // just removed, not a snapshot taken before this actor hop.
        let affectedMemberships = memberships.filter { $0.folderId == id }
        for child in reparented {
            if let i = folders.firstIndex(where: { $0.id == child.id }) { folders[i] = child }
        }
        memberships.removeAll { $0.folderId == id }
        assignments.removeAll { $0.folderId == id }
        folders.removeAll { $0.id == id }

        // Find items left with zero memberships
        var orphaned: [UUID] = []
        for m in affectedMemberships {
            if membershipCount(item: m.itemId) == 0 {
                orphaned.append(m.itemId)
            }
        }

        exportOrganization()
        return orphaned
    }

    // MARK: - Replication

    /// File `item` into `folder`.
    ///
    /// **Refuses a folder that is not in the graph (W23.m15).** Without this the store would happily
    /// write a membership to any UUID — and the `memberships` table had no foreign key to catch it — so
    /// every note created after Inbox was deleted added a row nothing could ever render or remove.
    /// The FK now refuses the same write at the SQL layer; this guard is what makes the refusal a
    /// clear error instead of a constraint violation, and keeps memory from running ahead of the DB.
    ///
    /// **Refuses an item whose confirmed hard delete is in flight (W23.h3-fu)** — see the hard-delete
    /// guard below.
    func addMembership(item: UUID, folder: UUID) async throws {
        try requireNotHardDeleting(item)
        try requireFolderExists(folder)
        guard !memberships.contains(where: { $0.itemId == item && $0.folderId == folder }) else { return }
        let m = Membership(itemId: item, folderId: folder, addedAt: Date())
        try await index.insertMembership(m)
        memberships.append(m)
        exportOrganization()
    }

    /// Returns `.removed` if the membership was deleted, `.wasLastInstance` **without mutating** if
    /// this pair is the item's only instance (§3.6 guard), or `.notPresent` if the pair is already gone.
    ///
    /// The pair-existence check comes FIRST and is what makes the count meaningful: a bare
    /// `membershipCount <= 1` cannot tell "this is the last membership" from "this membership is stale
    /// and some *other* one is the last", and answering `.wasLastInstance` to the second question is
    /// what let a stale confirmation trash a live note (W23.h3). With the pair proven present,
    /// `count == 1` provably means *this* pair is the only one.
    func removeMembership(item: UUID, folder: UUID) async throws -> RemoveResult {
        guard memberships.contains(where: { $0.itemId == item && $0.folderId == folder }) else {
            return .notPresent
        }
        if membershipCount(item: item) <= 1 {
            return .wasLastInstance
        }
        try await index.deleteMembership(item: item, folder: folder)
        memberships.removeAll { $0.itemId == item && $0.folderId == folder }
        exportOrganization()
        return .removed
    }

    /// Complete a **confirmed** §3.6 delete-last-instance: verify the pair, remove it, and report what
    /// the removal actually applied to. The caller must trash the note only for `.deletedLastInstance`.
    ///
    /// This is deliberately ONE call rather than the old check-then-force-remove pair. `NotesIndex` is an
    /// actor, so the caller's `await` between a "was it the last instance?" question and an unconditional
    /// force-remove was a suspension point the other window could interleave at — and `@MainActor` is
    /// reentrant there. Deciding inside the store, *after* the removal, closes that window: the
    /// last-instance verdict is read from what survives, so a membership that appeared while the DB write
    /// was in flight counts too and downgrades the outcome to `.unlinkedNotLast` (keep the file).
    func removeConfirmedLastMembership(item: UUID, folder: UUID) async throws -> ConfirmedRemoveResult {
        guard memberships.contains(where: { $0.itemId == item && $0.folderId == folder }) else {
            return .notPresent
        }
        try await index.deleteMembership(item: item, folder: folder)
        memberships.removeAll { $0.itemId == item && $0.folderId == folder }
        exportOrganization()
        return membershipCount(item: item) == 0 ? .deletedLastInstance : .unlinkedNotLast
    }

    /// **Move** one item's membership from `source` to `target` as a single durable unit (W23.m13):
    /// either it ends up in `target` and out of `source`, or nothing at all changed.
    ///
    /// This exists because the caller's old shape — `addMembership` then a `try?`-swallowed
    /// `removeMembership` — reported a move while leaving the item **replicated in both folders**
    /// whenever the removal failed. Suppressing the error there was not gratuitous: the removal cannot
    /// be allowed to trip the §3.6 delete-last-instance guard, which is also why the add had to come
    /// first. Both properties survive here — the insert precedes the delete *inside* the transaction,
    /// so the item is never transiently member-less — but a failure is now honest and total.
    ///
    /// A no-op (not an error) when the item is already only in `target`, so a stale drag costs nothing.
    ///
    /// Like `addMembership`, this **mints** a membership, so it is refused for an item whose confirmed
    /// hard delete is in flight (W23.h3-fu). Nothing is lost by refusing: a guarded item is one the
    /// store just proved has zero memberships, so there is no `source` row to move.
    func moveMembership(item: UUID, from source: UUID, to target: UUID) async throws {
        guard source != target else { return try await addMembership(item: item, folder: target) }
        try requireNotHardDeleting(item)
        try requireFolderExists(target)
        let inSource = memberships.contains { $0.itemId == item && $0.folderId == source }
        let inTarget = memberships.contains { $0.itemId == item && $0.folderId == target }
        guard inSource || !inTarget else { return }

        let m = Membership(itemId: item, folderId: target, addedAt: Date())
        try await index.moveMembership(item: item, from: source, to: target, addedAt: m.addedAt)

        if !inTarget { memberships.append(m) }
        memberships.removeAll { $0.itemId == item && $0.folderId == source }
        exportOrganization()
    }

    // MARK: - Hard-delete guard (W23.h3-fu)

    /// Items whose **confirmed** hard delete is in flight, counted rather than flagged so overlapping
    /// and nested guards compose (the trash primitive holds one; its caller holds another across the
    /// wider window). A `Bool` would let the inner `end` unguard the item while the outer window is
    /// still open — exactly the gap this closes.
    private var hardDeleting: [UUID: Int] = [:]

    /// Open a hard-delete window over `ids`: `addMembership` / `moveMembership` refuse them until it
    /// closes, so no replicate or move can slip a live membership onto a note on its way to the Trash.
    ///
    /// This exists because W23.h3 closed only the *decision* — `removeConfirmedLastMembership` reads its
    /// last-instance verdict from what survives the removal, so a membership that appears during the DB
    /// write downgrades the outcome. But `@MainActor` is reentrant at every `await`, and the caller then
    /// awaits the trash itself: a replicate landing in **that** gap arrives after the verdict is already
    /// `.deletedLastInstance`, so nothing downgrades and the note is trashed with a live membership row
    /// pointing at it. The verdict has to stay true until the file is gone, which is what this window is.
    ///
    /// **Every `begin` must be balanced by an `end` on every exit path — use `defer`.**
    func beginHardDelete(_ ids: [UUID]) {
        for id in ids { hardDeleting[id, default: 0] += 1 }
    }

    /// Close one hard-delete window over `ids` (see `beginHardDelete`). Tolerates an id that is not
    /// guarded, so an unbalanced `end` can never drive the count negative and permanently unguard.
    func endHardDelete(_ ids: [UUID]) {
        for id in ids {
            guard let n = hardDeleting[id] else { continue }
            if n <= 1 { hardDeleting.removeValue(forKey: id) } else { hardDeleting[id] = n - 1 }
        }
    }

    /// Is a confirmed hard delete of `id` in flight?
    func isHardDeleting(_ id: UUID) -> Bool { hardDeleting[id] != nil }

    private func requireNotHardDeleting(_ id: UUID) throws {
        guard !isHardDeleting(id) else { throw OrganizationError.itemBeingDeleted(id) }
    }

    func foldersContaining(item: UUID) -> [UUID] {
        memberships.filter { $0.itemId == item }.map(\.folderId)
    }

    func items(in folder: UUID) -> [UUID] {
        memberships.filter { $0.folderId == folder }.map(\.itemId)
    }

    /// Every item id that is a member of `folder` **or any of its descendant folders** (the subtree
    /// union). Replicated items are counted once (a `Set`). Cycle-safe (a visited guard) and O(F + M).
    /// This is the graph analog of Reader's path-prefix scope; W6-S4 uses it to scope the item list to
    /// a selected folder (06-viewers §4, "Folder scope").
    func subtreeItemIDs(of folder: UUID) -> Set<UUID> {
        // Build the parent→children adjacency once, then walk the subtree from `folder`.
        var childrenOf: [UUID: [UUID]] = [:]
        for f in folders { if let p = f.parentId { childrenOf[p, default: []].append(f.id) } }
        var subtree: Set<UUID> = [folder]
        var stack = [folder]
        while let cur = stack.popLast() {
            for child in childrenOf[cur] ?? [] where subtree.insert(child).inserted {
                stack.append(child)
            }
        }
        var ids = Set<UUID>()
        for m in memberships where subtree.contains(m.folderId) { ids.insert(m.itemId) }
        return ids
    }

    func membershipCount(item: UUID) -> Int {
        memberships.count(where: { $0.itemId == item })
    }

    // MARK: - Templates

    func assignTemplate(_ template: UUID, to folder: UUID) async throws {
        let a = TemplateAssignment(folderId: folder, templateId: template)
        try await index.insertTemplateAssignment(a)
        if let i = assignments.firstIndex(where: { $0.folderId == folder }) {
            assignments[i] = a
        } else {
            assignments.append(a)
        }
        exportOrganization()
    }

    func removeTemplateAssignment(folder: UUID) async throws {
        try await index.deleteTemplateAssignment(folder: folder)
        assignments.removeAll { $0.folderId == folder }
        exportOrganization()
    }

    /// Clear several folders' template assignments as one durable unit, memory after the commit
    /// (W23.m13) — so a failure part-way through a template deletion cannot leave some folders
    /// pointing at the template and others not.
    func removeTemplateAssignments(folders folderIds: [UUID]) async throws {
        guard !folderIds.isEmpty else { return }
        try await index.deleteTemplateAssignments(folders: folderIds)
        let cleared = Set(folderIds)
        assignments.removeAll { cleared.contains($0.folderId) }
        exportOrganization()
    }

    /// Resolve the template for a folder by walking up ancestors (§16.4).
    func template(for folder: UUID) -> UUID? {
        if let a = assignments.first(where: { $0.folderId == folder }) {
            return a.templateId
        }
        if let f = folders.first(where: { $0.id == folder }), let parent = f.parentId {
            return template(for: parent)
        }
        return nil
    }

    // MARK: - Private helpers

    private func nextSortOrder(under parent: UUID?) -> Int {
        let siblings = folders.filter { $0.parentId == parent }
        return (siblings.map(\.sortOrder).max() ?? -1) + 1
    }

    /// Walk up from `target` via parentId; if we reach `id`, moving would create a cycle.
    private func wouldCreateCycle(moving id: UUID, to target: UUID?) -> Bool {
        guard let target else { return false }
        if target == id { return true }
        var current: UUID? = target
        var visited = Set<UUID>()
        while let c = current {
            if c == id { return true }
            if !visited.insert(c).inserted { break }
            current = folders.first(where: { $0.id == c })?.parentId
        }
        return false
    }

    /// The system folders absent from `existing`, in canonical order — what `load` must restore
    /// (W23.m15). Empty for a healthy store, which is why this is safe to run on every launch.
    private func missingSystemFolders(in existing: [VFolder]) -> [VFolder] {
        let present = Set(existing.map(\.id))
        return Self.systemFolderSeeds.filter { !present.contains($0.id) }
    }

    /// Throw if `id` names a system folder — the rename/delete backstop (W23.m15).
    private func refuseSystemFolder(_ id: UUID) throws {
        if let name = Self.systemFolderName(id) {
            throw OrganizationError.systemFolderImmutable(name: name)
        }
    }

    /// Throw unless `folder` is in the graph — the ghost-membership backstop (W23.m15).
    private func requireFolderExists(_ folder: UUID) throws {
        guard folders.contains(where: { $0.id == folder }) else {
            throw OrganizationError.unknownFolder(folder)
        }
    }

    /// Re-export the whole graph to the durable mirror and record the outcome on `mirrorFailure`
    /// (W23.m10). Never throws — see `mirrorFailure` for why that is the deliberate shape.
    ///
    /// A success CLEARS a previous failure, and does so correctly: the export is whole-graph, not
    /// incremental, so one working write brings the mirror fully back in sync — including the changes
    /// whose own exports failed. That also means a transient full disk can't leave a permanent warning.
    /// Re-export a mirror that is already known stale, so a volume that came back is picked up without
    /// waiting for the operator's next organization change (W23.m10-fu).
    ///
    /// W23.m10 clears `mirrorFailure` on the next *successful* export — and the only thing that exports
    /// is a mutation. So after a transient full disk or an unplugged volume, an operator who simply
    /// stops touching folders keeps a stale `organization.json` for the rest of the session, and into
    /// the next one (the DB wins at startup, so nothing re-syncs it on launch either). This is the
    /// retry that closes that gap; it is deliberately the same whole-graph export, so one working write
    /// recovers *everything* that missed the mirror rather than replaying a queue of changes.
    ///
    /// **Runs only while stale**, which is what makes it safe to hang off something as frequent as app
    /// activation: a healthy mirror is never rewritten, so no app switch touches the user's file.
    /// Returns whether an export was attempted — the caller reads `mirrorFailure` for the outcome.
    ///
    /// **Reentrancy is safe here, by the store's existing convention, not by luck.** Its trigger is a
    /// synchronous notification, so it can land on the main actor while a mutation is suspended at its
    /// `await` — and `@MainActor` is reentrant. Every mutation commits in the order DB transaction →
    /// memory → export, with no suspension between the last two, so the only state a retry can observe
    /// mid-mutation is the consistent *pre-mutation* graph: it writes that, and the mutation's own
    /// export overwrites it a moment later with the new one. (If that mutation instead throws, memory
    /// never moved and the pre-mutation graph was the right thing to have written.) A mutation that
    /// updated memory before its await would break that — hence this note next to the convention.
    @discardableResult
    func retryStaleMirrorExport() -> Bool {
        guard isMirrorStale, didLoadGraph else { return false }
        exportOrganization()
        return true
    }

    private func exportOrganization() {
        guard let root = storeRoot else { mirrorFailure = .noStoreRoot; return }
        do {
            try OrganizationFile.export(
                folders: folders, memberships: memberships,
                assignments: assignments, to: root)
            mirrorFailure = nil
        } catch {
            mirrorFailure = .writeFailed(detail: error.localizedDescription)
            NSLog("OrganizationStore: organization.json export failed: \(error)")
        }
    }
}
