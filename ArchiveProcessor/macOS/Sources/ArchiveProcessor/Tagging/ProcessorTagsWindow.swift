import Combine
import SwiftUI
import ArchiveCore
import ArchiveCoreUI

/// The Processor's Tags window (W40.tag-window-processor; design: the W40.tag-window-core entry in
/// SUITE_TODO_DONE.md), the suite's shared window over the Processor's two lists, since it keeps no library: the suggestions it
/// offers while a tag is typed (the autocomplete vocabulary) and the subject list Automatic tagging chooses from
/// (Settings ▸ Output). Rename, merge and remove edit both as one Undo step. Each is recorded in each archive the
/// Processor knows (`ProcessorTagChanges.archives`), so the Reader offers it for the files and Notes for the notes;
/// the changes those apps record reach these lists by themselves (`ProcessorTagChanges.follow`). It never
/// writes an output file: those files are the Reader's library.
@MainActor
final class ProcessorTagsController: ObservableObject {
    static let suggestions = "Suggestions", subjectList = "Subject list"
    static let shared = ProcessorTagsController(defaults: ProcessorTagsController.subjectListDefaults())

    let model: TagsWindowModel
    /// What the last change could not do beyond the lists: the other apps not told, the subject list left as it was.
    @Published private(set) var note: String?
    /// The window's, set by the view, so Edit ▸ Undo takes back the last change.
    weak var undoManager: UndoManager?

    private let vocabulary: TagVocabulary
    private let defaults: UserDefaults
    private var observers: [NSObjectProtocol] = []
    private var tagsSubscription: AnyCancellable?
    /// The subject list's stored text when the window last read it.
    private var shownSubjects: String?

    /// One change as made, kept for Undo and Redo.
    private struct Step {
        let summary: String
        let suggestions: TagSpellingChange?
        let subjects: TagSpellingChange?
        let recorded: Set<UUID>
        /// The archives the change was recorded in, found once when it was made: its Undo and Redo go to the same.
        let archives: ArchiveTargets
    }

    /// The archives a change went to, filled by its record write and read by its Undo and Redo writes, which run
    /// after it on the one write chain.
    final class ArchiveTargets: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        var value: [URL] {
            get { lock.lock(); defer { lock.unlock() }; return urls }
            set { lock.lock(); urls = newValue; lock.unlock() }
        }
    }

    /// The archive writes, one after another in the order the changes were made, so an Undo pressed at once never
    /// withdraws an entry before it is recorded.
    private var writeChain: Task<Void, Never>?
    /// Counts changes, so a late note from an earlier change's write is dropped.
    private var generation = 0

    init(vocabulary: TagVocabulary = ProcessorTagVocabulary.shared, defaults: UserDefaults = .standard) {
        self.vocabulary = vocabulary
        self.defaults = defaults
        final class Box { weak var controller: ProcessorTagsController? }
        let box = Box()
        model = TagsWindowModel(inventory: TagInventory(items: []), noun: .vocabularyList) { plan in
            box.controller?.perform(plan) ?? .init(changed: 0, failed: 0)
        }
        box.controller = self
        model.itemsLabel = { entry in
            entry.itemIDs.count > 1 ? "Both" : entry.itemIDs.first ?? ""
        }
        refresh()
        // The lists change under the window: the provider republishes the suggestions when a tag is typed or written
        // or another app's rename is followed, and the Output tab or a followed rename edits the subject list.
        tagsSubscription = SystemTagsProvider.shared.$tags.dropFirst().sink { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.defaults.string(forKey: DefaultsKeys.tagVocabulary) != self.shownSubjects
                    else { return }
                    self.refresh()
                }
            })
    }

    /// Reads both lists afresh. Cheap unless the subject list or the vocabulary changed.
    func refresh() {
        shownSubjects = defaults.string(forKey: DefaultsKeys.tagVocabulary)
        let items = Self.items(suggestions: vocabulary.snapshot(), subjects: subjectList())
        guard items != model.inventory.items else { return }
        model.update(TagInventory(items: items))
    }

    /// The window was opened: follow the other apps' changes first (`SystemTagsProvider.warmUp` does, off the main
    /// thread, and republishes), then show the lists.
    func windowAppeared() {
        SystemTagsProvider.shared.warmUp()
        refresh()
    }

    static func items(suggestions: [String], subjects: [String]) -> [TagInventory.Item] {
        [TagInventory.Item(id: Self.suggestions, tags: suggestions), TagInventory.Item(id: Self.subjectList, tags: subjects)]
    }

    /// The subject list, one tag per line, as Automatic tagging and `ProcessorTagChanges.follow` read it.
    private func subjectList() -> [String] {
        (defaults.string(forKey: DefaultsKeys.tagVocabulary) ?? "").components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func setSubjectList(_ list: [String]) {
        defaults.set(list.joined(separator: "\n"), forKey: DefaultsKeys.tagVocabulary)
    }

    // MARK: Changes

    /// The window's writer: the plan on both lists as they are now, one Undo step, recorded for the other apps.
    private func perform(_ plan: TagChangePlan) -> TagsWindowModel.Outcome {
        generation += 1
        note = nil
        let suggestionsNow = vocabulary.snapshot()
        let suggestions = plan.applied(to: suggestionsNow).flatMap { TagSpellingChange(from: suggestionsNow, to: $0) }
        let subjectsNow = subjectList()
        var subjects = plan.applied(to: subjectsNow).flatMap { TagSpellingChange(from: subjectsNow, to: $0) }
        var failed = 0
        // An empty subject list means free-form tagging: taking the last tags off it would quietly lift the limit.
        if let change = subjects, change.applied(to: subjectsNow).isEmpty {
            subjects = nil
            failed = 1
            appendNote(Self.subjectListKept)
        }
        if let suggestions { vocabulary.apply(suggestions); vocabulary.flush() }
        if let subjects { setSubjectList(subjects.applied(to: subjectsNow)) }
        let changed = (suggestions == nil ? 0 : 1) + (subjects == nil ? 0 : 1)
        guard changed > 0 else { return .init(changed: 0, failed: failed) }
        SystemTagsProvider.shared.republish()

        let entries = plan.logEntries(app: TagChangeLog.processor)
        let step = Step(summary: Self.words(plan), suggestions: suggestions, subjects: subjects,
                        recorded: Set(entries.map(\.id)), archives: ArchiveTargets())
        registerUndo(step, undoing: true)
        refresh()
        if !entries.isEmpty {
            let folder = Self.outputFolder()
            let targets = step.archives
            write(reportsNoArchive: true) {
                targets.value = ProcessorTagChanges.archives(outputFolder: folder).map(\.url)
                return try ProcessorTagChanges.record(entries, in: targets.value)
            }
        }
        return .init(changed: changed, failed: failed)
    }

    private static let subjectListKept = "The subject list was left as it is: without any tags in it, Automatic "
        + "tagging would choose subjects freely. Edit it in Settings ▸ Output."

    /// Undo (`undoing`) or Redo of `step` is registered; running it registers the other.
    private func registerUndo(_ step: Step, undoing: Bool) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated { controller.replay(step, undo: undoing) }
        }
        undoManager.setActionName(step.summary)
    }

    private func replay(_ step: Step, undo: Bool) {
        generation += 1
        note = nil
        if let change = step.suggestions {
            vocabulary.apply(undo ? change.inverse : change)
            vocabulary.flush()
        }
        if let change = step.subjects {
            // Only a list that has tags keeps them here: an emptied list (free-form) is not filled again, and a list
            // is never emptied.
            let now = subjectList()
            let new = (undo ? change.inverse : change).applied(to: now)
            if !now.isEmpty, !new.isEmpty {
                setSubjectList(new)
            } else if new != now {
                appendNote(Self.subjectListKept)
            }
        }
        SystemTagsProvider.shared.republish()
        registerUndo(step, undoing: !undo)
        refresh()
        if !step.recorded.isEmpty {
            let (ids, targets) = (step.recorded, step.archives)
            write(reportsNoArchive: false) { try ProcessorTagChanges.setWithdrawn(ids, undo, in: targets.value) }
        }
    }

    /// Runs an archive write off the main thread after every earlier one, and says when the other apps were not told.
    private func write(reportsNoArchive: Bool, _ work: @escaping @Sendable () throws -> Int) {
        let previous = writeChain
        let generation = generation
        writeChain = Task {
            await previous?.value
            let problem: String? = await Task.detached(priority: .userInitiated) {
                do {
                    return try work() == 0 && reportsNoArchive
                        ? "No archive was found above the output folder (a folder the Reader opens), so the other "
                          + "apps were not told."
                        : nil
                } catch {
                    return "The other apps were not told: \(ProcessorTagChanges.describe(error))."
                }
            }.value
            if let problem, generation == self.generation { self.appendNote(problem) }
        }
    }

    private func appendNote(_ text: String) {
        note = [note, text].compactMap { $0 }.joined(separator: " ")
    }

    private static func words(_ plan: TagChangePlan) -> String {
        switch plan.kind {
        case .rename: return "Rename Tag"
        case .merge: return "Merge Tags"
        case .remove: return "Remove Tag"
        }
    }

    /// Where the subject list is read and written: the app's settings, or a UI test's scratch suite under DEBUG, so a
    /// test run on this Mac never replaces the real list.
    static func subjectListDefaults() -> UserDefaults {
#if DEBUG
        if let scratch = ProcessorUITestConfiguration.tagListsDefaults { return scratch }
#endif
        return .standard
    }

    /// The output folder the archives are found from; a UI test's scratch one under DEBUG.
    nonisolated static func outputFolder() -> URL? {
#if DEBUG
        if let folder = ProcessorUITestConfiguration.outputDirectory { return folder }
#endif
        return ProcessorTagVocabulary.currentArchiveRoot()
    }
}

/// Window ▸ Tags (SwiftUI lists the `Window` scene in the Window menu itself).
struct ProcessorTagsWindow: View {
    @ObservedObject private var controller = ProcessorTagsController.shared
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        TagsWindowView(model: controller.model) {
            VStack(alignment: .leading, spacing: 4) {
                Text("The tags the Processor offers as you type (Suggestions) and the subject list Automatic tagging "
                     + "chooses from. Renames, merges and removals made here are passed to the Reader and Notes for "
                     + "the files and notes; theirs reach these lists by themselves. A tag still on files in the output "
                     + "folder returns to Suggestions when the folder is next read.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = controller.note {
                    Label(note, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("ap.tags.note")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top], 10)
        }
        .onAppear {
            controller.undoManager = undoManager
            controller.windowAppeared()
        }
        .onChange(of: undoManager) { _, manager in controller.undoManager = manager }
    }
}

extension ProcessorTagsWindow {
    static let id = "processor-tags"
}
