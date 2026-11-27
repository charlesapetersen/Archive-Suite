import Foundation
import ArchiveCore
import ArchiveCoreUI

// MARK: - Window ▸ Tags over the notes and extracts (W40.tag-window-notes, Tier-2)
//
// The suite's shared Tags window (ArchiveCoreUI `TagsWindowModel`), fed by every note and extract with its subjects as
// its front matter holds them (a hand-edited lower-case spelling shows as another spelling of the tag), and writing a
// rename, merge or remove through `renameSubjects` (`applyTagsWindowPlan`): front matter first, then the Finder mirror,
// one Undo in the Tags window (its own history, so it does not depend on the Archive Notes window being open),
// recorded for the other apps (a remove as a schema 2 entry with an empty `to`). Notes title-cases what it writes, so
// the plans are spelt that way too, and a note that already carries the target under another spelling has it
// re-spelt, as Rename Tag… does. Like Rename Tag…, a change that only re-spells a tag is not recorded (Notes ignores
// other apps' re-spellings too). The window writes nothing itself.
// Design: the W40.tag-window-core entry in SUITE_TODO_DONE.md.

extension NotesModel {
    /// The Tags window's model, made on first use and kept for the session.
    var tagsWindow: TagsWindowModel {
        if let model = tagsWindowModel { return model }
        let model = TagsWindowModel(inventory: TagInventory(items: [], spell: Self.tagSpelling), noun: .note) {
            [weak self] plan in
            guard let self else { return .init(changed: 0) }
            return await applyTagsWindowPlan(plan)
        }
        tagsWindowModel = model
        refreshTagsWindow(allItems)
        return model
    }

    /// How Notes spells a subject it writes.
    nonisolated static let tagSpelling: @Sendable (String) -> String = { NotesTagVocabulary.titleCased($0) }

    /// Every note and extract as the Tags window counts it: its subjects as its front matter holds them (the suite's
    /// own tokens, a rating or a date facet, are listed apart by `TagInventory`).
    nonisolated static func tagInventory(_ items: [TagInventory.Item]) -> TagInventory {
        TagInventory(items: items, spell: tagSpelling)
    }

    /// Rebuilds the window's list from `items` (the library as it is now, or as `$allItems` delivers it), off the
    /// main actor with its Find Similar groups. A build that finishes after a newer one started is dropped.
    func refreshTagsWindow(_ items: [ItemSummary]) {
        guard let model = tagsWindowModel else { return }
        tagsWindowGeneration += 1
        let generation = tagsWindowGeneration
        let rows = items.map { TagInventory.Item(id: $0.id.uuidString, tags: $0.managedTags) }
        Task { [weak self] in
            let (inventory, clusters) = await Task.detached(priority: .userInitiated) {
                () -> (TagInventory, [[TagInventory.Entry]]) in
                let inventory = Self.tagInventory(rows)
                return (inventory, inventory.similarClusters())
            }.value
            guard let self, generation == self.tagsWindowGeneration else { return }
            model.update(inventory, similarClusters: clusters)
        }
    }

    /// Runs one Tags window change as Rename Tag… does, a remove being a rename to nothing: every note and extract
    /// carrying a source tag (any spelling) as it is now, recorded for the other apps, one Undo in the Tags window.
    /// Nil from `renameSubjects` means no note carries a source tag any more: nothing changed, nothing failed.
    func applyTagsWindowPlan(_ plan: TagChangePlan) async -> TagsWindowModel.Outcome {
        guard let outcome = await renameSubjects(plan.sources, to: plan.target ?? "") else { return .init(changed: 0) }
        if !outcome.changed.isEmpty, let undo = tagsWindowUndo() {
            registerUndoOfRename(outcome, with: undo) { [weak self] step in self?.enqueueTagsWindowHistory(step) }
        }
        return .init(changed: outcome.changed.count, failed: outcome.failed.count)
    }

    private func enqueueTagsWindowHistory(_ step: @escaping @MainActor () async -> Void) {
        let previous = tagsWindowHistoryTail
        tagsWindowHistoryTail = Task { @MainActor in
            await previous?.value
            await step()
        }
    }

    /// Waits for the Tags window's queued Undo and Redo steps to finish (tests).
    func tagsWindowHistorySettled() async { await tagsWindowHistoryTail?.value }
}
