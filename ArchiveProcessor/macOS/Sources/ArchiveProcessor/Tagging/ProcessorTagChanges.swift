import Foundation
import ArchiveCore

/// The Processor's vocabularies follow a rename or merge made in the Reader or Notes (W40.tag-rename-suite;
/// SPEC/tag-format.md invariant 8). The Processor keeps no library, so there is nothing to ask about: each archive it
/// knows (the output folder and the harvested roots, each taken up to the folder holding its Reader root marker) has
/// its `.archivesuite/tag-changes.json` read, and every entry not yet handled re-spells the autocomplete vocabulary
/// and the controlled subject list (`TagChangeLog.follow`). The Processor's own Tags window records its renames and
/// merges in the same archives (`record`, `setWithdrawn`; W40.tag-window-processor), through `TagChangeLog` alone;
/// otherwise it writes only its own vocabulary file and settings. The pure part is ArchiveCore's, where it has tests.
enum ProcessorTagChanges {

    /// Every archive the Processor knows, by its root marker's guid: the output folder's and the harvested roots',
    /// each taken up to the folder holding its Reader root marker. Blocking file reads.
    static func archives(vocabulary: TagVocabulary = ProcessorTagVocabulary.shared,
                         outputFolder: URL?) -> [(guid: UUID, url: URL)] {
        var archives: [UUID: URL] = [:]
        let folders = [outputFolder].compactMap { $0 } + vocabulary.knownRoots().map { URL(fileURLWithPath: $0.path) }
        for folder in folders {
            if let archive = TagChangeLog.archiveRoot(containing: folder) { archives[archive.guid] = archive.url }
        }
        return archives.sorted { $0.key.uuidString < $1.key.uuidString }.map { (guid: $0.key, url: $0.value) }
    }

    /// Records the Tags window's change in each of `archives` (`archives(outputFolder:)`). Returns how many it went
    /// to; throws the first failure after trying them all. Blocking: call it off the main thread.
    static func record(_ entries: [TagChange], in archives: [URL]) throws -> Int {
        try each(archives) { try TagChangeLog.record(entries, root: $0) }
    }

    /// Marks the window's recorded entries withdrawn (its Undo) or not (its Redo) in each of `archives`.
    static func setWithdrawn(_ ids: Set<UUID>, _ withdrawn: Bool, in archives: [URL]) throws -> Int {
        try each(archives) { try TagChangeLog.setWithdrawn(ids, withdrawn, root: $0) }
    }

    private static func each(_ archives: [URL], _ write: (URL) throws -> Void) throws -> Int {
        var firstError: Error?
        for archive in archives {
            do { try write(archive) } catch { firstError = firstError ?? error }
        }
        if let firstError { throw firstError }
        return archives.count
    }

    /// A recording failure in the status line's words.
    static func describe(_ error: Error) -> String {
        if case ContainerWriteError.refusedExisting(let why) = error { return "the archive's change record is \(why)" }
        return "the archive folder could not be written (\(error.localizedDescription))"
    }

    /// Follows every archive's log once. Returns true when a vocabulary changed. Blocking file reads: call it off the
    /// main thread.
    @discardableResult
    static func follow(vocabulary: TagVocabulary = ProcessorTagVocabulary.shared,
                       defaults: UserDefaults = .standard,
                       outputFolder: URL? = ProcessorTagVocabulary.currentArchiveRoot()) -> Bool {
        var changed = false
        for (guid, url) in archives(vocabulary: vocabulary, outputFolder: outputFolder) {
            guard let doc = TagChangeLog.load(root: url).document else { continue }
            let handled = TagChangeHandled(rootGUID: guid.uuidString)
            let applied = TagChangeHandled.applied(rootGUID: guid.uuidString)
            let stored = defaults.string(forKey: DefaultsKeys.tagVocabulary) ?? ""
            let list = stored.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let (handledBefore, appliedBefore) = (handled.ids, applied.ids)
            let result = TagChangeLog.follow(doc, app: TagChangeLog.processor, handled: handledBefore,
                                             applied: appliedBefore, vocabulary: vocabulary, controlled: list)
            handled.insert(result.handled)
            applied.insert(result.applied)
            handled.remove(result.unapplied)   // a later Redo applies again
            applied.remove(result.unapplied)
            // The Tags window may have edited the list since it was read: apply the same entries to the fresh list
            // rather than write over its edit (against the same handled lists; the vocabulary changes repeat as no-ops).
            var controlled = result.controlled
            let fresh = defaults.string(forKey: DefaultsKeys.tagVocabulary) ?? ""
            if fresh != stored {
                let freshList = fresh.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                controlled = TagChangeLog.follow(doc, app: TagChangeLog.processor, handled: handledBefore,
                                                 applied: appliedBefore, vocabulary: vocabulary,
                                                 controlled: freshList).controlled
                if controlled != freshList {
                    defaults.set(controlled.joined(separator: "\n"), forKey: DefaultsKeys.tagVocabulary)
                }
            } else if controlled != list {
                defaults.set(controlled.joined(separator: "\n"), forKey: DefaultsKeys.tagVocabulary)
            }
            changed = changed || !result.applied.isEmpty || !result.unapplied.isEmpty
        }
        if changed { vocabulary.flush() }
        return changed
    }
}
