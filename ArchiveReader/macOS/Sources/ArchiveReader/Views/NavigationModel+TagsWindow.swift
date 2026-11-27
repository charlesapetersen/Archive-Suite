import Foundation
import Combine
import ArchiveCore
import ArchiveCoreUI

// MARK: - Window ▸ Tags over the Reader's library (W40.tag-window-reader, Tier-2)
//
// The suite's shared Tags window (ArchiveCoreUI `TagsWindowModel`), fed by the files of the granted folder's main
// archive, each with its tags verbatim (in catalogue mode, its catalogue subjects), and writing a rename, merge or
// remove through `TagWriter.applyPlan` (a coordinated fresh read per file, one ledger group, one Undo) or, in
// catalogue mode, through the catalogue journal as one operation. Each change is recorded for the other apps
// (`recordTagChanges`) against that group or operation, so its Undo withdraws it and its Redo restores it.
// The window writes nothing itself. Design: execution-plans/tag-rename-suite.md §"The Tags window".

extension NavigationModel {
    /// The Tags window's model, made on first use and kept for the session.
    var tagsWindow: TagsWindowModel {
        if let model = tagsWindowModel { return model }
        let model = TagsWindowModel(inventory: TagInventory(items: []), noun: .file) { [weak self] plan in
            guard let self else { return .init(changed: 0) }
            return await applyTagPlan(plan)
        }
        tagsWindowModel = model
        // Every change to the library, the window's own included, rebuilds the list while the window shows. Delivered
        // on the next turn of the main queue: `ArchiveLibrary` bumps `filesRevision` before it replaces the rows, and
        // `@Published` sends before the change, so a list rebuilt at once read the rows from before (an Undo left the
        // window showing the undone name; seen in the VM).
        tagsWindowFollow = library.$filesRevision.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.tagsWindowVisible else { return }
                self.refreshTagsWindow()
            }
        }
        refreshTagsWindow()
        return model
    }

    /// The window shows (its view's appear and disappear): the list follows the library only while it does.
    func tagsWindowShown(_ shown: Bool) {
        tagsWindowVisible = shown
        if shown { refreshTagsWindow() }
    }

    /// The main archive's path, the only tree whose subjects the Reader changes; nil without one.
    private var tagsMainRoot: String? {
        guard let root = rootStore.root else { return nil }
        let layout = ReaderArchiveLayout(grantedRoot: root)
        return layout.needsCommonParentGrant ? nil : layout.mainRoot.path
    }

    /// Every file of the main archive as the Tags window counts it: its tags verbatim (the suite's own tokens are
    /// listed apart by `TagInventory`), or in catalogue mode its catalogue subjects, which are what a change edits there.
    nonisolated static func tagInventory(_ files: [ArchiveFile], catalogue: Bool, mainRoot: String?) -> TagInventory {
        guard let mainRoot else { return TagInventory(items: []) }
        return TagInventory(items: files.compactMap { file in
            guard ReaderArchiveLayout.isContained(file.url, inRootPath: mainRoot) else { return nil }
            return TagInventory.Item(id: file.path, tags: catalogue ? file.subjects : file.tags.raw)
        })
    }

    /// The inventory of only the files carrying `tag`, for a change another app recorded.
    func tagInventory(carrying tag: String) -> TagInventory {
        Self.tagInventory(library.files.filter { $0.hasSubject(tag) }, catalogue: library.usesCatalogue,
                          mainRoot: tagsMainRoot)
    }

    /// Rebuilds the window's list from the library, off the main actor (the corpus is ~116k files). One build at a
    /// time; a change that lands during one is built once it ends.
    func refreshTagsWindow() {
        guard let model = tagsWindowModel else { return }
        guard !tagsWindowBuilding else { tagsWindowStale = true; return }
        tagsWindowBuilding = true
        tagsWindowStale = false
        let files = library.files, catalogue = library.usesCatalogue, mainRoot = tagsMainRoot
        Task { [weak self] in
            // The Find Similar groups too: at the corpus's size they are the costly part (`TagSimilarity`).
            let (inventory, clusters) = await Task.detached(priority: .userInitiated) {
                ReaderStages.measure("tagsWindow.inventory") { () -> (TagInventory, [[TagInventory.Entry]]) in
                    let inventory = Self.tagInventory(files, catalogue: catalogue, mainRoot: mainRoot)
                    return (inventory, inventory.similarClusters())
                }
            }.value
            guard let self else { return }
            model.update(inventory, similarClusters: clusters)
            if let pending = tagsWindowPendingTag {
                tagsWindowPendingTag = nil
                if let entry = inventory.entry(for: pending) { select(entry, in: model) }
            }
            tagsWindowBuilding = false
            if tagsWindowStale { refreshTagsWindow() }
        }
    }

    /// Opens the window on `tag` (Tags ▸ Rename Tag…, the tag cloud): the list searched for it and it selected, once
    /// the list is built when the window is just opening.
    func showTagInTagsWindow(_ tag: String?) {
        let model = tagsWindow
        model.similarOnly = false
        guard let tag = tag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty else { return }
        if let entry = model.inventory.entry(for: tag) {
            tagsWindowPendingTag = nil
            select(entry, in: model)
        } else {
            model.search = tag
            tagsWindowPendingTag = tag
            refreshTagsWindow()   // a library that changed since may carry it
        }
    }

    private func select(_ entry: TagInventory.Entry, in model: TagsWindowModel) {
        model.search = entry.name
        model.selection = [entry.id]
    }

    /// Opens the window on its Find Similar list (Tags ▸ Find Similar Tags…).
    func showSimilarInTagsWindow() {
        let model = tagsWindow
        model.search = ""
        model.similarOnly = true
    }

    /// Show Files: the navigation list filtered to the tag alone.
    func showFiles(withTag tag: String) {
        filter.subjects = [tag]
    }

    /// Runs one Tags window change over the files carrying its tags: one ledger group (one Undo) through TagWriter,
    /// or one catalogue journal operation. Records it for the other apps unless `recording` is false (applying
    /// another app's change, already in the log). Returns the files changed and those that could not be.
    func applyTagPlan(_ plan: TagChangePlan, recording: Bool = true) async -> TagsWindowModel.Outcome {
        // Refused, not done: every file still carries the tag, so a caller never settles it (another app's change
        // stays offered).
        if refuseWhileTagBatchRuns() { return .init(changed: 0, failed: max(plan.itemCount, 1)) }
        let listed = Set(plan.itemIDs)
        let catalogue = library.usesCatalogue
        // The files the plan counted, and any that took one of its tags since; the fresh read decides each. In
        // catalogue mode by the catalogue subjects the list counted, not the Finder tags, and only a PDF that still
        // carries one: its documents are read from the same scan, and one with none is not changed.
        let candidates = library.files.filter { file in
            let carries = catalogue ? file.subjects.contains { plan.sourceKeys.contains(tagKey($0)) }
                                    : !file.subjectKeys.isDisjoint(with: plan.sourceKeys)
            return (carries || !catalogue && listed.contains(file.path)) && isInsideMainArchive(file.url)
        }
        let entries = recording ? plan.logEntries(app: TagChangeLog.reader) : []
        let title = Self.tagPlanTitle(plan)
        if catalogue {
            let paths = candidates.map(\.path)
            let operation = UUID()
            return await withCheckedContinuation { done in
                // Every document of a PDF that carries a source tag, as the list counted them all.
                let carries = { (subjects: [String]) in subjects.contains { plan.sourceKeys.contains(tagKey($0)) } }
                let started = editCatalogueSubjects(paths: paths, title: "Tag Change", operationID: operation,
                                                    documents: carries, completed: { [weak self] verified in
                    // Only records that changed count, and only then is the change recorded: the journal holds its
                    // Undo, which withdraws these entries (`tagChangeReversed`).
                    let changed = self?.catalogueLastSaveChanged ?? 0
                    if changed > 0 { self?.recordTagChanges(group: operation, entries) }
                    done.resume(returning: .init(changed: changed, failed: paths.count - verified.count))
                }) { subjects in plan.applied(to: subjects) ?? subjects }
                if !started { done.resume(returning: .init(changed: 0, failed: paths.count)) }
            }
        }
        let reverified = reverifyCacheRows(candidates)
        let files = reverified.files
        let rejected = reverified.rejected
        guard !files.isEmpty else {
            statusMessage = rejected > 0 ? "Could not verify \(rejected) matching file\(rejected == 1 ? "" : "s")."
                                         : "No files carry \(Self.quoted(plan))."
            announce(statusMessage)
            return .init(changed: 0, failed: rejected)
        }
        // Each file's identity now (§6), when the change is confirmed; a file replaced under its path, or no longer
        // carrying a source tag, is never written. One failure does not stop its neighbours.
        let urls = files.map(\.url)
        let identities = files.map { $0.liveIdentity() }
        let group = UUID()                                  // §12: one ledger group, as it is one undo
        return await withCheckedContinuation { done in
            runTagBatch(title, count: urls.count,
                        keys: { TagBatch.keys(path: urls[$0].path, file: AuditLedger.fileNumber(urls[$0])) },
                        group: group, files: urls, written: { $0.result },
                        lane: TagBatch.each { i -> TagBatchWrite in
                do { return .wrote(try TagWriter.applyPlan(plan, on: urls[i], expecting: identities[i])) }
                catch { return .failed }
            }) { [self] outcomes, stale in
                var changed = 0, failures = rejected, stopped = 0
                var verified: [TagWriteResult] = []
                for i in urls.indices {
                    switch outcomes[i] {
                    case .wrote(let r):
                        verified.append(r)
                        if !r.isNoOp { changed += 1 }
                    case .failed: failures += 1
                    case nil: stopped += 1
                    }
                }
                library.applyVerifiedWrites(verified.filter { !stale.contains($0.url) })
                refreshUndoHistory()   // ONE grouped undo
                statusMessage = Self.tagPlanStatus(plan, changed: changed, failed: failures) + Self.cancelledNote(stopped)
                announce(statusMessage)
                // Kept against the ledger group, so this change's Undo and Redo withdraw and restore its entries.
                if changed > 0 { recordTagChanges(group: group, entries) }
                done.resume(returning: .init(changed: changed, failed: failures + stopped))
            }
        }
    }

    nonisolated static func quoted(_ plan: TagChangePlan) -> String {
        plan.sources.count == 1 ? "“\(plan.sources[0])”" : "\(plan.sources.count) tags"
    }

    nonisolated static func tagPlanTitle(_ plan: TagChangePlan) -> String {
        switch plan.kind {
        case .rename: "Renaming \(quoted(plan))"
        case .merge: "Merging \(quoted(plan))"
        case .remove: "Removing \(quoted(plan))"
        }
    }

    nonisolated static func tagPlanStatus(_ plan: TagChangePlan, changed: Int, failed: Int) -> String {
        let on = "\(changed) file\(changed == 1 ? "" : "s")"
        let done: String
        switch plan.kind {
        case .rename: done = "Renamed \(quoted(plan)) → “\(plan.target ?? "")” on \(on)"
        case .merge: done = "Merged \(quoted(plan)) into “\(plan.target ?? "")” on \(on)"
        case .remove: done = "Removed \(quoted(plan)) from \(on)"
        }
        return done + (failed > 0 ? "; \(failed) could not update." : ".")
    }
}
