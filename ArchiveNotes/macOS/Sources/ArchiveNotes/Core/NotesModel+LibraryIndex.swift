import Foundation
import ArchiveCore

// MARK: - Item list, index lifecycle, reload & search (W49.notes-model-split)

extension NotesModel {
    // MARK: Item list loading (W6-S3)

    /// Reload the shared item set from the index (app path). A no-op for an injected (test) store,
    /// which seeds items via `replaceItems(_:)` instead.
    ///
    /// Routed through `openIndexForQuery()`, so a read the index couldn't answer is reported instead of
    /// published: `allSummaries()` returns `[]` for an unopenable index exactly as it does for an empty
    /// one, and publishing that would erase the visible library on the strength of a query that never
    /// ran (W23.m9-fu). A *successful* read still publishes whatever it found, empty included.
    ///
    /// An index that cannot be opened at all leaves the list to the notes on disk, read directly, so
    /// the library does not look empty when it is not (W40.fix-notes-index-failure-empty). Only the
    /// `unavailable` case: an `incomplete` index opened, and its read is answered above.
    func reloadItems() async {
        guard let index = await openIndexForQuery() else {
            if case .unavailable = indexFailure, let noteStore {
                replaceItems(await noteStore.allItemSummaries())
            }
            return
        }
        let items = await index.allSummaries()
        replaceItems(items)
    }

    /// Replace the shared item set. The app path calls this from `reloadItems()`; tests call it
    /// directly to seed synthetic summaries without a real index. Published, so each window's
    /// navigation model recomputes its `displayed` list.
    func replaceItems(_ items: [ItemSummary]) {
        allItems = items
        itemsGeneration &+= 1
        refreshSmartFolderCounts()
    }

    // MARK: Initial index build + ready signal (§3.4)

    /// App-path initial build: (re)index every on-disk item into the disposable FTS index, then refresh
    /// the shared item list and flip the deterministic index-ready signal. Awaits the background build so
    /// `isIndexReady` / `indexGeneration` reflect a **settled** index — XCUITest polls the hidden
    /// `an.status.indexReady` element for this before asserting search / relevance (08-testing §3.4).
    /// The index is a disposable cache, so this is read-only w.r.t. the store (mtime-skipped upserts
    /// only; no prune here — that stays gated on a settled snapshot elsewhere).
    ///
    /// Also the mid-session recovery pass: `repopulateIndexAfterRecovery()` reuses this verbatim so a
    /// repaired index is refilled the same way a fresh one is (W23.m9-fu2).
    func buildIndexFromDisk() async {
        guard let indexer, let noteStore else {
            // Pure injected store (no background indexer/store): nothing to build — surface ready anyway.
            markIndexReady(generation: max(indexGeneration, 1))
            return
        }
        let refs = await noteStore.allItemRefs()
        indexer.startIndexing(refs)
        await indexer.awaitSettled()
        await reloadItems()
        markIndexReady(generation: indexer.indexGeneration)
        // Settled ≠ healthy: adopt whatever the build actually achieved, so a partial or unopenable
        // index is visible rather than presented as a Ready one (W23.m9).
        adoptIndexFailure(indexer.failure)
    }

    // MARK: File ▸ Reload Library (W49.notes-reload-library)

    /// File ▸ Reload Library: pick up notes and folders changed on disk outside this app (another Mac
    /// through a sync service, a Finder copy, a hand edit) without quitting.
    ///
    /// Three steps. `organization.json` is adopted when it changed outside the app
    /// (`OrganizationStore.reloadFromMirrorIfChanged`, which never loads it over this session's own
    /// changes). The index is brought up to date by the launch pass, mtime-skipped, so an unchanged note
    /// costs one `stat`. Then index rows for notes no longer on disk are dropped: a row is dropped only when
    /// the note is missing from a walk taken before the pass AND one taken after the index was read, and
    /// `itemExists` still says so; an empty walk drops nothing (the indexer's two-emission rule, here with
    /// both walks in one call); a note that is back on disk after the delete (an Undo or Put Back meanwhile)
    /// is indexed again at once.
    ///
    /// Open editors are not touched. Each already rereads its own note from disk and keeps an unsaved draft
    /// apart when the two conflict (`NoteBodyEditorModel.refreshFromDisk`, the checked save).
    func reloadLibrary() async {
        guard let indexer, let noteStore, let index, !isReloadingLibrary else { return }
        isReloadingLibrary = true
        defer { isReloadingLibrary = false }
        let before = Dictionary(allItems.map { ($0.id, $0.mtime) }, uniquingKeysWith: { a, _ in a })

        var folderLine: String?
        do {
            switch try await organization.reloadFromMirrorIfChanged() {
            case .unchanged: break
            case .adopted:
                rebuild()
                folderLine = "Folders were reloaded from organization.json."
            case .keptLocal(let reason):
                folderLine = reason
            }
        } catch {
            NotesLog.organization.error("Failed to reload organization.json: \(error.localizedDescription, privacy: .public)")
            folderLine = "organization.json couldn't be read into the library, so the folders were left as they were."
        }

        let firstWalk = Set(await noteStore.allItemRefs().map(\.id))
        await buildIndexFromDisk()
        if !firstWalk.isEmpty, indexer.failure == nil {
            let indexed = await index.allIndexedIDs()
            let secondWalk = Set(await noteStore.allItemRefs().map(\.id))
            var gone = indexed.subtracting(firstWalk).subtracting(secondWalk)
            if !secondWalk.isEmpty, !gone.isEmpty {
                for id in gone {
                    if await noteStore.itemExists(id) { gone.remove(id) }
                }
                if !gone.isEmpty {
                    do {
                        try await index.deleteItems(Array(gone))
                        // Undo or Put Back can bring a note home, and index it, between the check above
                        // and the delete. A note back on disk now is indexed again by a second pass,
                        // mtime-skipped for every other note.
                        var back = false
                        for id in gone where !back { back = await noteStore.itemExists(id) }
                        if back { await buildIndexFromDisk() } else { await reloadItems() }
                    } catch {
                        NSLog("NotesModel: Reload Library couldn't drop \(gone.count) missing note(s): \(error)")
                    }
                }
            }
        }
        await reloadTemplates()
        await reloadTrash()
        // An index failure has posted its own line through `adoptIndexFailure`.
        guard indexFailure == nil else { return }
        statusMessage = Self.reloadSummary(before: before, after: allItems, folderLine: folderLine)
    }

    /// The status line after File ▸ Reload Library: what changed among the notes, then the folders' line.
    nonisolated static func reloadSummary(before: [UUID: Double], after: [ItemSummary],
                                          folderLine: String?) -> String {
        var added = 0, changed = 0
        var seen = Set<UUID>()
        for item in after where seen.insert(item.id).inserted {
            if let mtime = before[item.id] {
                if mtime != item.mtime { changed += 1 }
            } else {
                added += 1
            }
        }
        let removed = before.keys.filter { !seen.contains($0) }.count
        let notes = added + changed + removed == 0
            ? "Library reloaded: no notes changed on disk."
            : "Library reloaded: " + [
                added > 0 ? "\(added) \(added == 1 ? "note" : "notes") added" : nil,
                changed > 0 ? "\(changed) \(changed == 1 ? "note" : "notes") changed" : nil,
                removed > 0 ? "\(removed) \(removed == 1 ? "note" : "notes") removed" : nil,
              ].compactMap { $0 }.joined(separator: ", ") + "."
        return [notes, folderLine].compactMap { $0 }.joined(separator: " ")
    }

    /// Mirror the indexer's health onto the model and, when degraded, into the sidebar status line.
    /// Never clears a message it didn't set — `statusMessage` is shared with other degradations, so
    /// clearing one this model didn't post would swallow another subsystem's report.
    ///
    /// Two properties matter now that the query paths call this per search (W23.m9-fu):
    /// a degraded index **re-posts** its line every time a read hits it, so a banner the operator
    /// dismissed comes back rather than leaving the next empty result unexplained; and the assignment
    /// to `@Published indexFailure` is change-guarded, since a 150 ms-debounced search would otherwise
    /// republish the identical value on every keystroke.
    func adoptIndexFailure(_ failure: NotesIndexer.Failure?) {
        if indexFailure != failure { indexFailure = failure }
        if let failure {
            statusMessage = failure.message
            postedIndexMessage = failure.message
        } else {
            // The claim is no longer true — retract it, but only if our own line is still the one showing.
            if let posted = postedIndexMessage, statusMessage == posted { statusMessage = nil }
            postedIndexMessage = nil
        }
    }

    /// The shared index, but only once it has actually opened — the one health-aware accessor every
    /// model-level read goes through (W23.m9-fu).
    ///
    /// `NotesIndex`'s reads answer `[]`/`nil` on a nil handle, so a read that skipped the open was
    /// indistinguishable from "nothing matches": before this, `search`/`reloadItems` queried the index
    /// directly, never attempted an open, and so never reported a dead index nor noticed a repaired one.
    ///
    /// Routed through `NotesIndexer.openForQuery()` whenever there is a driver, so the driver stays the
    /// single owner of index health and this only mirrors it. A model injected with a bare index (tests,
    /// previews) has no driver, so it opens under the same all-or-nothing contract and publishes the
    /// same typed failure itself — the report must not depend on which initializer ran.
    ///
    /// **Recovering the handle is not recovering the rows** (W23.m9-fu2). An index that opens after
    /// having been `unavailable` is queryable but, in the case that matters, EMPTY — the operator
    /// replaced the corrupt file, a sync client healed it, the volume came back. Retracting the banner
    /// on its own therefore traded one silent wrong answer ("no matches", because nothing could be read)
    /// for another ("no matches", because nothing has been written yet). The `unavailable → open` edge
    /// is what schedules the rebuild that fills it, hence reading the prior health *before* the open.
    func openIndexForQuery() async -> NotesIndex? {
        guard let index else { return nil }          // pure injected store: no index to be unhealthy
        // The driver owns `failure` when there is one; only a driver-less model answers for itself. Read
        // it from the owner, since `buildIndexFromDisk()` adopts the driver's verdict only at the end of
        // the pass — mid-pass the model's mirror can still be nil while the driver knows better.
        var wasUnavailable = false
        if case .unavailable = indexer?.failure ?? indexFailure { wasUnavailable = true }

        let opened: Bool
        if let indexer {
            opened = await indexer.openForQuery()
            adoptIndexFailure(indexer.failure)
        } else {
            do {
                try await index.open()
                // It opened, so an `unavailable` claim is now false. An `incomplete` one still stands — a
                // successful open says nothing about rows a previous pass failed to write.
                if case .unavailable = indexFailure { adoptIndexFailure(nil) }
                opened = true
            } catch {
                adoptIndexFailure(.unavailable(detail: NotesIndexer.failureDetail(error)))
                opened = false
            }
        }
        guard opened else { return nil }
        // Also when only the folders are still the read-only mirror: bootstrap's open failed but the
        // driver's has since succeeded, so `wasUnavailable` never saw the dead index. Once only: a
        // reload that failed is reported, not retried on every keystroke.
        if wasUnavailable || (organization.isReadOnlyMirror && !mirrorReloadFailed) {
            scheduleIndexRepopulationAfterRecovery()
        }
        return index
    }

    /// The in-flight post-recovery rebuild, so a test can await it rather than sleep on a task the query
    /// path scheduled. (`nil` also means "already finished" — the assertions are on the rebuilt state.)
    var inFlightIndexRecoveryTask: Task<Void, Never>? { indexRecoveryTask }

    /// Kick a from-disk rebuild after the index recovered from `unavailable`, WITHOUT making the read
    /// that noticed wait for it (W23.m9-fu2).
    ///
    /// Three properties are the whole design:
    /// - **Edge-triggered, not per-read.** Only the `unavailable → open` transition schedules it, so the
    ///   directory walk happens once per recovery rather than once per keystroke of a 150 ms-debounced
    ///   search. This is the "a full disk walk from a keystroke" objection that deferred the fix, and it
    ///   is the edge — not the failure state — that answers it.
    /// - **Off the read's critical path.** The caller returns its (still empty) result immediately and
    ///   the rows land on a later read, exactly as they do after a launch build. A search must never
    ///   block on a store walk.
    /// - **One at a time.** `buildIndexFromDisk()` re-enters `openIndexForQuery()` via `reloadItems()`,
    ///   and a file that flaps would otherwise stack rebuilds on each other.
    ///
    /// Nothing to rebuild *from* — no driver, or no store yet (an injected model, or one pre-`bootstrap`)
    /// — is a no-op: the handle recovered and the banner is retracted either way, there is simply no
    /// disk to walk.
    private func scheduleIndexRepopulationAfterRecovery() {
        guard indexer != nil, noteStore != nil, indexRecoveryTask == nil else { return }
        indexRecoveryTask = Task { [weak self] in
            await self?.repopulateIndexAfterRecovery()
            self?.indexRecoveryTask = nil
        }
    }

    /// The rebuild itself: the same from-disk pass the app runs at launch (W23.m9-fu2).
    ///
    /// Deliberately `buildIndexFromDisk()` and not a bespoke recovery path — the two cannot drift, its
    /// upserts are mtime-skipped (so a volume that came back with its rows intact costs one directory
    /// walk and no writes), and it also repairs the *partial* index a mid-pass failure leaves behind,
    /// which an "only rebuild when the index reads empty" shortcut would skip. It is read-only w.r.t.
    /// the note store and prunes nothing, so the worst case of a needless run is wasted work.
    ///
    /// It does re-mark `isIndexReady` and bump `indexGeneration` — the deliberate behaviour change this
    /// item exists to make, rather than smuggle into the LOW visibility fix it fell out of. The token's
    /// contract is "a build settled", and one did; `isIndexReady` only ever goes true, so the hidden
    /// `an.status.indexReady` probe cannot regress to "building" underneath a test.
    ///
    /// Internal so a test can drive the rebuild deterministically instead of racing the scheduler.
    func repopulateIndexAfterRecovery() async {
        guard indexer != nil, noteStore != nil else { return }
        // A graph shown read-only from the mirror becomes the real one now there is a table to hold it.
        do {
            try await organization.reloadAfterIndexRecovery()
            rebuild()
        } catch {
            mirrorReloadFailed = true
            report(error, "load the folders")
        }
        await buildIndexFromDisk()
    }

    func markIndexReady(generation: Int) {
        indexGeneration = generation
        isIndexReady = true
    }

    // MARK: Keyword search (W6-S4)

    /// Full-text search over the disposable index, in bm25 relevance order (best match first). Returns
    /// `[]` for a blank query or an injected (index-less) store. The per-window `NotesNavigationModel`
    /// intersects this with its filtered set and orders by rank (06-viewers §4, §11).
    ///
    /// An unopenable index answers `[]` too, so the read goes through `openIndexForQuery()`: an empty
    /// result then means "no matches", and a dead index says so in the sidebar instead (W23.m9-fu). The
    /// blank-query check stays first — not searching is not a failed search, and must raise no banner.
    func search(_ query: String) async -> [UUID] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        guard let index = await openIndexForQuery() else { return [] }
        return await index.search(query)
    }

    /// The items an Advanced Search text rule's FTS5 expression matches (W40.notes-advanced-search), through
    /// the same `openIndexForQuery()` as `search(_:)`.
    func search(expression: String) async -> [UUID] {
        guard !expression.isEmpty else { return [] }
        guard let index = await openIndexForQuery() else { return [] }
        return await index.search(expression: expression)
    }

    /// The index's answers for every text rule of `search`, by rule id.
    func textHits(for search: NotesAdvancedSearch) async -> [UUID: Set<UUID>] {
        var hits: [UUID: Set<UUID>] = [:]
        for rule in search.textRules {
            guard let expression = rule.ftsExpression else { continue }
            hits[rule.id] = Set(await self.search(expression: expression))
        }
        return hits
    }

    /// The items in each folder `search` names, or any folder below it.
    func folderItems(for search: NotesAdvancedSearch) -> [UUID: Set<UUID>] {
        Dictionary(uniqueKeysWithValues: search.folderIDs.map { ($0, organization.subtreeItemIDs(of: $0)) })
    }
}
