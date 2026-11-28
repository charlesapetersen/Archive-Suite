import Foundation
import ArchiveCore

// MARK: - Folder tree, scopes, folder mutations & Trash (W49.notes-model-split)

extension NotesModel {
    // MARK: Tree rebuild

    /// Recompute the rendered tree + counts from the current organization graph. Call after any
    /// mutation. Cheap (O(F + M)); the shared model is the single source of tree state for both windows.
    func rebuild() {
        let folders = organization.folders
        let memberships = organization.memberships
        normalTree = NotesFolderNode.buildNormalForest(folders: folders, memberships: memberships)
        smartFolders = NotesFolderNode.smartFolderNodes(
            folders: folders, excluding: [OrganizationStore.allNotesFolderId])
        refreshSmartFolderCounts()
    }

    private struct SmartCountQuery: Sendable {
        let id: UUID
        let search: NotesAdvancedSearch
    }

    /// Reuse the durable predicate used by smart-folder navigation. Capture value snapshots on the
    /// main actor; resolve subtree membership and scan items off-main. A newer update cancels the
    /// old scan, and only the current generation may publish counts.
    func refreshSmartFolderCounts() {
        smartCountGeneration &+= 1
        let generation = smartCountGeneration
        smartCountWorker?.cancel()
        smartCountApply?.cancel()
        smartFolderCounts = [:]

        // A smart folder with text rules has no count: its rules need index queries, which a count of every
        // folder on each change would multiply (as the Reader's sidebar).
        let queries: [SmartCountQuery] = smartFolders.compactMap { node in
            guard let search = Self.decodeSmartQuery(node.queryJSON), !search.hasTextRules else { return nil }
            return SmartCountQuery(id: node.id, search: search)
        }
        guard !queries.isEmpty else { return }
        let items = allItems
        let folders = organization.folders
        let memberships = organization.memberships
        let worker = Task.detached(priority: .utility) { () -> [UUID: Int]? in
            // Build the graph index once per pass. Resolving each folder-scoped smart query via
            // OrganizationStore.subtreeItemIDs on the main actor would rescan all memberships per
            // query, freezing large libraries with many saved searches.
            var childrenOf: [UUID: [UUID]] = [:]
            for (index, folder) in folders.enumerated() {
                if index.isMultiple(of: 256), Task.isCancelled { return nil }
                if let parent = folder.parentId { childrenOf[parent, default: []].append(folder.id) }
            }
            var itemsByFolder: [UUID: Set<UUID>] = [:]
            for (index, membership) in memberships.enumerated() {
                if index.isMultiple(of: 256), Task.isCancelled { return nil }
                itemsByFolder[membership.folderId, default: []].insert(membership.itemId)
            }
            var scopeItems: [UUID: Set<UUID>] = [:]
            for root in Set(queries.flatMap(\.search.folderIDs)) {
                var visited: Set<UUID> = []
                var stack = [root]
                var ids: Set<UUID> = []
                while let folderID = stack.popLast() {
                    if Task.isCancelled { return nil }
                    guard visited.insert(folderID).inserted else { continue }
                    ids.formUnion(itemsByFolder[folderID] ?? [])
                    stack.append(contentsOf: childrenOf[folderID] ?? [])
                }
                scopeItems[root] = ids
            }
            let context = NotesRuleContext(folderItems: scopeItems)
            var counts = Dictionary(uniqueKeysWithValues: queries.map { ($0.id, 0) })
            for (index, item) in items.enumerated() {
                if index.isMultiple(of: 256), Task.isCancelled { return nil }
                for query in queries {
                    if Task.isCancelled { return nil }
                    if query.search.matches(item, context) {
                        counts[query.id, default: 0] += 1
                    }
                }
            }
            return Task.isCancelled ? nil : counts
        }
        smartCountWorker = worker
        smartCountApply = Task { [weak self] in
            let counts = await worker.value
            guard !Task.isCancelled, let self, self.smartCountGeneration == generation,
                  let counts else { return }
            self.smartFolderCounts = counts
        }
    }

    /// Deterministic completion seam for headless smart-folder count regression checks.
    func waitForSmartFolderCounts() async { await smartCountApply?.value }

    // MARK: Scope selection

    /// Scope to a normal folder. `nil` or the All-Notes root clears the scope (show everything). The
    /// no-op guard (already scoped to `id`) is the second half of the sidebar selection-sync
    /// loop-breaker (the view holds the first; see Reader `SidebarView.swift:8-13`).
    func setFolderScope(_ id: UUID?) {
        guard let id, id != OrganizationStore.allNotesFolderId else { setAllNotesScope(); return }
        guard selectedFolderId != id || selectedSmartId != nil else { return }
        selectedFolderId = id
        selectedSmartId = nil
        scope = .folderScope(id)
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
        guard let search = Self.decodeSmartQuery(f.queryJSON) else {
            statusMessage = "This smart folder's saved query is unreadable."
            setAllNotesScope()
            return
        }
        selectedSmartId = id
        selectedFolderId = nil
        scope = search
    }

    /// A smart folder's saved rules, or nil when there are none or they cannot be read.
    static func decodeSmartQuery(_ json: String?) -> NotesAdvancedSearch? {
        guard let data = json?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(NotesAdvancedSearch.self, from: data)
    }

    /// The saved rules of smart folder `id`, for Edit Smart Folder….
    func smartQuery(_ id: UUID) -> NotesAdvancedSearch? {
        guard let f = organization.folders.first(where: { $0.id == id }), f.kind == .smart else { return nil }
        return Self.decodeSmartQuery(f.queryJSON)
    }

    /// Run an Advanced Search without saving it: it becomes the shared scope, with no folder selected in the
    /// sidebar, until a folder or All Notes is chosen (W40.notes-advanced-search).
    func runAdvancedSearch(_ search: NotesAdvancedSearch) {
        selectedFolderId = nil
        selectedSmartId = nil
        scope = search
    }

    /// The scope is an Advanced Search run without saving (no folder or smart folder selected).
    var scopeIsUnsavedSearch: Bool { scope != nil && selectedFolderId == nil && selectedSmartId == nil }

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
            adoptMirrorFailure()
            return created.id
        } catch { report(error, "create the folder"); return nil }
    }

    /// Create a root-level **smart** folder whose rules (`NotesAdvancedSearch`) are persisted as `queryJSON`
    /// (§16.3) — "Save as Smart Folder" from the filter bar (W6-S4) or the Advanced Search form. Name trimmed,
    /// empty rejected, sibling-deduped. Returns the new folder id.
    @discardableResult
    func createSmartFolder(name rawName: String, query: NotesAdvancedSearch) async -> UUID? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { statusMessage = "A folder needs a name."; return nil }
        let unique = uniqueSiblingName(name, parent: nil, excluding: nil)
        guard let data = try? JSONEncoder().encode(query),
              let json = String(data: data, encoding: .utf8) else {
            statusMessage = "Couldn't encode the smart folder's query."; return nil
        }
        do {
            let created = try await organization.createFolder(
                name: unique, parent: nil, kind: .smart, queryJSON: json)
            rebuild()
            adoptMirrorFailure()
            return created.id
        } catch { report(error, "create the smart folder"); return nil }
    }

    /// Replace smart folder `id`'s rules (Edit Smart Folder…). When it is the open scope, the list follows.
    func updateSmartFolder(_ id: UUID, query: NotesAdvancedSearch) async {
        guard let data = try? JSONEncoder().encode(query),
              let json = String(data: data, encoding: .utf8) else {
            statusMessage = "Couldn't encode the smart folder's query."; return
        }
        do {
            try await organization.updateSmartQuery(id, queryJSON: json)
            rebuild()
            adoptMirrorFailure()
            if selectedSmartId == id { scope = query }
        } catch { report(error, "save the smart folder") }
    }

    /// Rename a folder. Whitespace-trimmed; empty rejected; deduped against siblings (excluding self).
    func renameFolder(_ id: UUID, to rawName: String) async {
        guard !refuseSystemFolder(id) else { return }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { statusMessage = "A folder needs a name."; return }
        let parent = organization.folders.first { $0.id == id }?.parentId
        let unique = uniqueSiblingName(name, parent: parent, excluding: id)
        do { try await organization.renameFolder(id, to: unique); rebuild(); adoptMirrorFailure() }
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
        do {
            try await organization.moveFolder(id, newParent: newParent, sortOrder: index)
            rebuild(); adoptMirrorFailure()
        } catch { report(error, "move the folder") }
    }

    /// Delete a folder (never its items). `OrganizationStore.deleteFolder` reparents children to the
    /// deleted folder's parent and returns the ids of items left in **no** folder; those remain
    /// reachable under All Notes, and we surface a status message. The batched sole-instance
    /// confirmation UI is W6-S5 (delete path, Tier-2). Returns the orphaned item ids for the caller.
    @discardableResult
    func deleteFolder(_ id: UUID) async -> [UUID] {
        guard !refuseSystemFolder(id) else { return [] }
        do {
            let orphaned = try await organization.deleteFolder(id)
            if selectedFolderId == id { setAllNotesScope() }
            rebuild()
            if !orphaned.isEmpty {
                let n = orphaned.count
                statusMessage = "\(n) item\(n == 1 ? "" : "s") \(n == 1 ? "is" : "are") no longer in any folder — find \(n == 1 ? "it" : "them") under All Notes."
            }
            adoptMirrorFailure()
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
        // Before anything is trashed. The store refuses a system folder anyway, but its throw would
        // arrive after the caller had already shown a modal naming the notes it was about to delete —
        // and this method's whole job is to delete notes, so the refusal has to come first (W23.m15).
        guard !refuseSystemFolder(folderId) else { return }
        // Hold the user-confirmed candidate set before deleting the folder, and drain adds/moves that
        // already passed their guard. A placement admitted while the alert was open can rescue an item;
        // the fresh orphan set returned below then keeps that item out of Trash.
        let guarded = Array(Set(stranded))
        organization.beginHardDelete(guarded)
        defer { organization.endHardDelete(guarded) }
        do {
            for id in guarded { try await organization.drainMembershipWritesForConfirmedDelete(item: id) }
        } catch { report(error, "prepare to delete the stranded notes"); return }

        let orphaned: [UUID]
        do {
            orphaned = try await organization.deleteFolder(folderId)   // removes memberships, reparents children
        } catch { report(error, "delete the folder"); return }
        if selectedFolderId == folderId { setAllNotesScope() }
        // Trash ONLY items that (a) the user confirmed as stranded AND (b) are *actually* orphaned now
        // (0 memberships) — `deleteFolder` returns the fresh orphan set, so a replicate between the
        // modal and this confirm rescues its item from deletion (it keeps its other membership).
        let confirmed = Set(stranded)
        let toTrash = orphaned.filter { confirmed.contains($0) }
        // Trashes, drops the rows of the ones that really went, reloads, and says so when the disk
        // refused one — that refusal is what makes this method's "still discoverable" promise real.
        await trashItems(toTrash)
        rebuild()                                                      // covers the empty case
        adoptMirrorFailure()
    }

    /// Move the given items' folders to the store's Trash (Put Back — `NoteStore.delete` never
    /// `removeItem`s) and drop the index rows of the ones that are **actually gone**. The caller must
    /// have already removed the items' memberships (0 remaining) — the §3.6 guard passed. Reloads the
    /// shared item list + rebuilds the tree. Returns the ids that SURVIVED (still on disk), so a
    /// caller can react; the empty array is the all-clear.
    ///
    /// W23.m12 — this used to drop the row of every *requested* id no matter what the disk said, which
    /// broke the invariant its own callers document ("a trash failure leaves the note on disk **and**
    /// discoverable under All Notes"): `reloadItems` serves the list from the index, nothing watches
    /// the store, and the full disk rebuild only runs at bootstrap — so a note the disk refused to
    /// trash vanished from All Notes for the rest of the run while sitting safe on disk, un-findable.
    /// A row now goes only once its note is provably absent.
    ///
    /// W23.h3-fu — this is the hard-delete primitive, so it holds `OrganizationStore`'s hard-delete
    /// window for the whole call: `await noteStore.delete(id)` is a suspension point, and `@MainActor`
    /// is reentrant there, so without it the other window's drag-to-folder could file a note between
    /// the caller's "zero memberships" verdict and the note actually reaching the Trash. Guarding here
    /// rather than only at the callers means a future third caller inherits it; the refcount is what
    /// lets a caller nest a wider window around this one.
    @discardableResult
    func trashItems(_ ids: [UUID], formerFolders: [UUID: [UUID]] = [:]) async -> [UUID] {
        guard !ids.isEmpty else { return [] }
        organization.beginHardDelete(ids)
        defer { organization.endHardDelete(ids) }
        #if DEBUG
        // Test seam (W23.h3-fu): the deterministic way to run a concurrent mutation *inside* the
        // hard-delete window. Racing two tasks and hoping to hit a sub-millisecond gap is not a test.
        if let hook = hardDeleteWindowHookForTesting { await hook() }
        #endif
        var removed: [UUID] = []          // provably no longer on disk ⟹ their rows must go
        var survived: [UUID] = []         // the disk refused ⟹ still on disk, so keep them findable
        if let noteStore {
            for id in ids {
                do { try await noteStore.delete(id, formerFolders: formerFolders[id] ?? []); removed.append(id) }
                catch {
                    NotesLog.store.error("Could not move note to Trash: \(error.localizedDescription, privacy: .public)")
                    // Ask the disk instead of classifying the error: `delete` also throws when the
                    // directory was ALREADY gone (`StoreError.notFound`, e.g. the other window got
                    // there first), and keeping THAT row would strand a phantom note pointing at
                    // nothing. So the row goes whenever the item is absent, whatever the reason, and
                    // stays only while the file is genuinely still there.
                    if await noteStore.itemExists(id) { survived.append(id) } else { removed.append(id) }
                }
            }
        } else {
            removed = ids                 // injected test store with no `noteStore`: bookkeeping only
        }
        trashedNoteIDs.formUnion(removed)
        var indexWriteFailed = false
        if let index, !removed.isEmpty {
            do { try await index.deleteItems(removed) }
            catch {
                // The files ARE in the Trash but their rows outlived them, so the list still offers
                // notes that no longer exist until the next launch rebuilds from disk. Same rule as
                // above, opposite direction: don't present a half-done delete as a clean one (W23.m9).
                NSLog("NotesModel: trashed \(removed.count) note(s) but could not delete their index rows: \(error)")
                indexWriteFailed = true
            }
        }
        await reloadItems()
        await reloadTrash()
        rebuild()
        // Last, so neither `reloadItems` nor `rebuild` can outrun it. A survivor outranks a stale
        // index because the note is still there to be found; `adoptMirrorFailure()` still wins in the
        // folder-delete path, which is the m10 precedence ("a real degradation wins") — both are
        // logged, and either way the note stays listed under All Notes.
        if !survived.isEmpty {
            let n = survived.count
            statusMessage = "Couldn't move \(n) note\(n == 1 ? "" : "s") to the Trash — "
                + "\(n == 1 ? "it is" : "they are") still on disk, under All Notes."
        } else if indexWriteFailed {
            statusMessage = "Moved \(removed.count) note\(removed.count == 1 ? "" : "s") to the Trash, "
                + "but the note list couldn't be updated — it will catch up on the next launch."
        }
        return survived
    }

    func noteWasTrashed(_ id: UUID) -> Bool { trashedNoteIDs.contains(id) }

    // MARK: Trash (W40.fix-notes-delete-undo)

    func reloadTrash() async {
        guard let noteStore else { return }
        trashedNotes = await noteStore.trashedNotes()
    }

    /// Put trashed notes back in the library — the Trash view's Put Back and Edit ▸ Undo after a
    /// delete. Each note goes home to `items/`, is indexed again, and is filed in the folders that
    /// held it that still exist; one whose folders are all gone is under All Notes. Returns the ids
    /// that came back.
    @discardableResult
    func putBack(_ ids: [UUID]) async -> [UUID] {
        guard let noteStore, !ids.isEmpty else { return [] }
        // Without the folder graph a note would come home unfiled and, with no index, unlisted.
        guard !refuseWhileFoldersReadOnly("put the note back") else { return [] }
        var restored: [UUID] = []
        var refused = 0
        var lostFolders = false
        var unfiled = 0
        for id in ids {
            let folders: [UUID]
            do { folders = try await noteStore.putBack(id) }
            catch NoteStore.StoreError.notFound {
                // Already put back (the Trash view, another window) or emptied — a stale Undo. Nothing
                // is lost and nothing is still in the Trash, so it is not reported as a refusal.
                continue
            }
            catch {
                NSLog("NotesModel: could not put note \(id) back: \(error)")
                refused += 1
                continue
            }
            restored.append(id)
            trashedNoteIDs.remove(id)
            if let index, let item = try? await noteStore.load(id) {
                let mtime = (try? await noteStore.mdURL(for: id)).flatMap {
                    (try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date)?
                        .timeIntervalSinceReferenceDate
                } ?? Date().timeIntervalSinceReferenceDate
                do { try await index.upsertBatch([NoteIndexRow(item: item, mtime: mtime)]) }
                catch { NSLog("NotesModel: put note \(id) back but could not index it: \(error)") }
            }
            let existing = Set(organization.folders.filter { $0.kind == .normal }.map(\.id))
            for folder in folders {
                guard existing.contains(folder) else { lostFolders = true; continue }
                do { try await organization.addMembership(item: id, folder: folder) }
                catch {
                    NSLog("NotesModel: put note \(id) back but could not file it in \(folder): \(error)")
                    unfiled += 1
                }
            }
        }
        await reloadItems()
        await reloadTrash()
        rebuild()
        adoptMirrorFailure()
        if refused > 0 {
            statusMessage = "Couldn't put \(refused) note\(refused == 1 ? "" : "s") back — "
                + "\(refused == 1 ? "it is" : "they are") still in the Trash."
        } else if unfiled > 0 {
            statusMessage = "Put the note back, but couldn't file it in \(unfiled) of its folders — "
                + "it is under All Notes."
        } else if lostFolders {
            statusMessage = "Put back under All Notes: a folder that held the note no longer exists."
        }
        return restored
    }

    /// Empty the given trashed notes (all of them when `ids` is nil) into the Finder's Trash, where
    /// they can still be recovered by hand. Returns the ids that stayed because the disk refused.
    @discardableResult
    func emptyTrash(_ ids: [UUID]? = nil) async -> [UUID] {
        guard let noteStore else { return [] }
        let targets = ids ?? trashedNotes.map(\.id)
        var kept: [UUID] = []
        for id in targets {
            do { try await noteStore.emptyFromTrash(id) }
            catch {
                NSLog("NotesModel: could not empty note \(id) from the Trash: \(error)")
                if await noteStore.isTrashed(id) { kept.append(id) }
            }
        }
        await reloadTrash()
        if !kept.isEmpty {
            statusMessage = "Couldn't empty \(kept.count) note\(kept.count == 1 ? "" : "s") from the Trash."
        }
        return kept
    }
}
