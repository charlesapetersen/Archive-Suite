import Foundation
import ArchiveCore

/// The Processor's vocabularies follow a rename or merge made in the Reader or Notes (W40.tag-rename-suite;
/// SPEC/tag-format.md invariant 8). The Processor keeps no library, so there is nothing to ask about: each archive it
/// knows (the output folder and the harvested roots, each taken up to the folder holding its Reader root marker) has
/// its `.archivesuite/tag-changes.json` read, and every entry not yet handled re-spells the autocomplete vocabulary
/// and the controlled subject list (`TagChangeLog.follow`). It reads the log and never writes it; it writes only its
/// own vocabulary file and settings. The pure part is ArchiveCore's, where it has tests.
enum ProcessorTagChanges {

    /// Follows every archive's log once. Returns true when a vocabulary changed. Blocking file reads: call it off the
    /// main thread.
    @discardableResult
    static func follow(vocabulary: TagVocabulary = ProcessorTagVocabulary.shared,
                       defaults: UserDefaults = .standard,
                       outputFolder: URL? = ProcessorTagVocabulary.currentArchiveRoot()) -> Bool {
        var archives: [UUID: URL] = [:]
        let folders = [outputFolder].compactMap { $0 } + vocabulary.knownRoots().map { URL(fileURLWithPath: $0.path) }
        for folder in folders {
            if let archive = TagChangeLog.archiveRoot(containing: folder) { archives[archive.guid] = archive.url }
        }
        var changed = false
        for (guid, url) in archives.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard let doc = TagChangeLog.load(root: url).document else { continue }
            let handled = TagChangeHandled(rootGUID: guid.uuidString)
            let applied = TagChangeHandled.applied(rootGUID: guid.uuidString)
            let stored = defaults.string(forKey: DefaultsKeys.tagVocabulary) ?? ""
            let list = stored.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let result = TagChangeLog.follow(doc, app: TagChangeLog.processor, handled: handled.ids,
                                             applied: applied.ids, vocabulary: vocabulary, controlled: list)
            handled.insert(result.handled)
            applied.insert(result.applied)
            handled.remove(result.unapplied)   // a later Redo applies again
            applied.remove(result.unapplied)
            if result.controlled != list {
                defaults.set(result.controlled.joined(separator: "\n"), forKey: DefaultsKeys.tagVocabulary)
            }
            changed = changed || !result.applied.isEmpty || !result.unapplied.isEmpty
        }
        if changed { vocabulary.flush() }
        return changed
    }
}
