import Foundation
import ArchiveCore

extension Notification.Name {
    /// Posted from an arbitrary thread when a *background* tag write contributed a subject name the
    /// vocabulary had never seen. Only posted on genuine growth, so an OCR run that re-uses the same
    /// subjects for 200 files posts nothing.
    static let tagVocabularyDidGrow = Notification.Name("ArchiveProcessor.tagVocabularyDidGrow")
}

/// The Processor's persisted subject vocabulary, and the two ingest paths that do not belong to the UI.
///
/// Deliberately separate from `SystemTagsProvider`: `MacOSTagger` writes from background threads, and it
/// must be able to feed the vocabulary without constructing — or publishing through — a `@MainActor`
/// `ObservableObject`. Touching a static on this enum never initialises the provider.
enum ProcessorTagVocabulary {

    /// One store per process. `TagVocabulary` is internally locked, so this is safe to hit from the
    /// walker's dedicated thread and the main actor at the same time.
    static let shared: TagVocabulary = TagVocabulary(fileURL: fileURL())

    /// Feed the vocabulary from a completed Finder-tag write.
    ///
    /// Takes the write's **verified on-disk** result (`TagWriteResult.after` / `.afterLabel`), not the
    /// intended array: that way the marker colour is recognised from the label that actually landed, and a
    /// copy-source pass-through contributes exactly the tags the source file really carries.
    static func recordWrittenTags(_ tagNames: [String], labelNumber: Int?) {
        guard shared.add(rawTags: tagNames, labelNumber: labelNumber) else { return }
        NotificationCenter.default.post(name: .tagVocabularyDidGrow, object: nil)
    }

    /// `<Application Support>/ArchiveProcessor/tag-vocabulary.json` in normal use.
    ///
    /// Under `ARCHIVEPROC_HEADLESS` (which every `scripts/test-*.sh` self-test driver sets) it moves to a
    /// scratch directory instead, so a driver's synthetic tags — "Red Scare", fixture subjects — can never
    /// land in the operator's real suggestion list. Same reasoning as `ProcessingHistoryTestDriver`'s
    /// throwaway `UserDefaults` suite. `ARCHIVEPROC_TAGVOCAB_FILE` overrides both.
    private static func fileURL() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let override = env["ARCHIVEPROC_TAGVOCAB_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let fm = FileManager.default
        let base: URL
        if env["ARCHIVEPROC_HEADLESS"] != nil {
            base = fm.temporaryDirectory.appendingPathComponent("ArchiveProcessor-TagVocabTest",
                                                                isDirectory: true)
        } else {
            base = (fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fm.temporaryDirectory).appendingPathComponent("ArchiveProcessor", isDirectory: true)
        }
        return base.appendingPathComponent("tag-vocabulary.json")
    }

    /// The one archive root the Processor knows it has been pointed at: the persisted output directory.
    ///
    /// Read straight from `UserDefaults` rather than through `ModelSelectionStore.savedOutputDirectory()`,
    /// which falls back to `~/Downloads` when nothing is persisted. That fallback is right for an output
    /// panel and wrong here — it would offer a personal-data folder as an archive root, and relying on
    /// `TagVocabulary.isHarvestableRoot` to catch it is worse than not asking.
    static func currentArchiveRoot() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: DefaultsKeys.outputDirectory),
              !path.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

/// Prefix-based autocomplete over the Finder tags already in use in the archive, for the tagging UIs.
///
/// **No Spotlight (W26.vocab).** This used to be an `NSMetadataQuery` over
/// `NSMetadataQueryUserHomeScope` with `kMDItemUserTags LIKE "*"`. The owner's 2026-08-04 directive removed
/// all reliance on Spotlight, for the reason the incident that day demonstrated: when the volume's index is
/// dead the query returns an empty result set with no error, and the operator simply gets a silently-empty
/// suggestion list. The replacement is `ArchiveCore.TagVocabulary` — a persisted set that accumulates from
/// a per-root filesystem harvest, from every tag the operator types, and from every tag write the app makes.
///
/// **What changed for the operator.** Suggestions are now scoped to the archive rather than to every tagged
/// file in the home folder, and they are *subjects* only (dates, priority, `Read`/`Unread` and the marker
/// colour are filtered out on ingest — see `TagVocabulary`). Both are improvements for this UI, and both are
/// honest narrowings: a tag that exists only on an unrelated personal file outside every archive root will
/// no longer be suggested. Widening the harvest to `~/Desktop` would recover most of that, but it needs a
/// new user-visible authorisation prompt (`NSDesktopFolderUsageDescription`) and is an owner decision, not a
/// code one — see the Daemon Report.
///
/// **Nothing here is ever a write authority.** The vocabulary suggests strings; it never decides what gets
/// written to a file.
@MainActor
final class SystemTagsProvider: ObservableObject {
    static let shared = SystemTagsProvider()

    /// The published vocabulary, ordered for display. Drives `@ObservedObject` re-render; the actual lookup
    /// in `suggestions` reads the store, so a suggestion is never stale relative to it.
    @Published private(set) var tags: [String] = []

    /// False **only** while a first-ever harvest is running with nothing to suggest yet. With a persisted
    /// vocabulary there is nothing to wait for, so this is `true` from the first `warmUp()` — the old
    /// "building tag suggestions…" state existed solely because the Spotlight gather was slow, and it now
    /// appears just once, on a genuinely cold first run.
    @Published private(set) var isReady = false

    /// A harvest is in flight (main-actor only).
    private var harvesting = false
    /// A coalesced re-publish is already queued (main-actor only).
    private var refreshScheduled = false

    private init() {
        // A background write can grow the vocabulary while a tag card is on screen; pick that up without
        // polling. Coalesced, because a run can post repeatedly and each publish sorts the whole set.
        NotificationCenter.default.addObserver(
            forName: .tagVocabularyDidGrow, object: nil, queue: nil
        ) { _ in
            Task { @MainActor in SystemTagsProvider.shared.requestCoalescedRefresh() }
        }
    }

    /// Publish the persisted vocabulary and start any harvest that is due.
    ///
    /// Cheap and safe to call on every tagging-UI appearance — which is what the call sites do. It is no
    /// longer "only the first call does anything": re-checking is how a *changed* output directory gets
    /// harvested without a relaunch, and `TagVocabulary` bounds the cost (a root is walked once, then at
    /// most once a day).
    func warmUp() {
        publishSnapshot()
        startDueHarvestIfIdle()
    }

    /// Prefix-first, then substring suggestions (case-insensitive), excluding already-chosen tags.
    /// The ranking itself lives in `ArchiveCore.TagVocabulary`, where it has tests.
    func suggestions(prefix: String, excluding: [String] = [], limit: Int = 8) -> [String] {
        ProcessorTagVocabulary.shared.suggestions(prefix: prefix, excluding: excluding, limit: limit)
    }

    /// Register tags the operator types so they appear in later suggestions — now *durably*, across
    /// relaunches, which is much of the point of the change. Flushed synchronously: a tag someone just
    /// typed is the one thing here worth not losing to a crash.
    func register(_ newTags: [String]) {
        guard ProcessorTagVocabulary.shared.add(rawTags: newTags) else { return }
        ProcessorTagVocabulary.shared.flush()
        publishSnapshot()
    }

    // MARK: - Harvest

    private func startDueHarvestIfIdle() {
        guard !harvesting else { return }
        let vocabulary = ProcessorTagVocabulary.shared
        let current = ProcessorTagVocabulary.currentArchiveRoot()
        if let current { vocabulary.noteRoot(current) }

        let due = vocabulary.rootsNeedingHarvest(current: current)
        guard !due.isEmpty else {
            isReady = true      // nothing is coming — never leave the spinner running forever
            return
        }
        // A warm vocabulary is immediately usable; only a cold first run is genuinely "building".
        isReady = !tags.isEmpty
        harvesting = true
        harvest(due, index: 0)
    }

    /// Walk the due roots one at a time, on a dedicated thread at `.utility`.
    ///
    /// Sequential, not concurrent: the walk is blocking I/O over a corpus that OCR and capture also read,
    /// and this is the lowest-value job in the app — it must never contend with them.
    private func harvest(_ roots: [URL], index: Int) {
        guard index < roots.count else {
            harvesting = false
            isReady = true
            publishSnapshot()
            return
        }
        let root = roots[index]
        let vocabulary = ProcessorTagVocabulary.shared

        CorpusWalker.scanOnDedicatedThread(
            root: root,
            // The predicate IS the sink, and it always returns false. A vocabulary harvest wants tag
            // *strings*, not a library: returning false means `CorpusWalker` accumulates no rows at all, so
            // a 100k-file corpus costs a bounded set of names instead of 100k `CorpusEntry` values held in
            // memory to build a suggestion list. Do not "fix" this to return true.
            predicate: { rawTags in
                vocabulary.add(rawTags: rawTags)
                return false
            },
            qualityOfService: .utility,
            onBatch: { _ in
                Task { @MainActor in SystemTagsProvider.shared.requestCoalescedRefresh() }
            },
            completion: { result in
                Task { @MainActor in
                    // Only a pass that COMPLETED may claim the root is covered. A cancelled or
                    // root-unreadable walk leaves the stamp alone so the next warm-up retries it; files it
                    // could not read individually are irrelevant here, since nothing is ever pruned.
                    if result.completed { vocabulary.markHarvested(root) }
                    vocabulary.flush()
                    SystemTagsProvider.shared.publishSnapshot()
                    SystemTagsProvider.shared.isReady = true
                    SystemTagsProvider.shared.harvest(roots, index: index + 1)
                }
            })
    }

    // MARK: - Publishing

    private func publishSnapshot() {
        tags = ProcessorTagVocabulary.shared.snapshot()
    }

    /// One re-publish per ~0.5 s however many growth events arrive. A harvest reports progress every 500
    /// examined files and each publish sorts the whole set, so an uncoalesced refresh would sort ~200 times
    /// on the main actor during a single corpus walk.
    private func requestCoalescedRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self.refreshScheduled = false
            self.publishSnapshot()
            if !self.tags.isEmpty { self.isReady = true }
        }
    }
}
