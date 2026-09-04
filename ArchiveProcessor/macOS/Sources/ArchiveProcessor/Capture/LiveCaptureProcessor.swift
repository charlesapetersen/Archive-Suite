import Foundation
import AppKit
import ArchiveCore
import CryptoKit

/// Streams processing during Live Capture: OCRs each page **as it arrives**, and finalizes each
/// segment (tagging + PDF + dual-output + optional merge) into a durable staging area as the operator
/// resolves its Mac tag card — overlapping the expensive OCR with capture. End-of-session finalization
/// (Phase 3/4) moves the staged outputs into named collection folders with continuing numbering.
///
/// Reuses the app's tested primitives: `OCRProcessor.performOCRCall` (OCR + rotation), `PDFGenerator`,
/// `TagGenerator`, and `MacOSTagger`. Segmentation is supplied by the phone, so no batch segmentation
/// pass is needed here; a segment's collection is the most-recent preceding **Box** marker.
@MainActor
final class LiveCaptureProcessor: ObservableObject {

    /// Live per-segment status for the UI.
    struct SegmentStatus: Identifiable {
        let id: String                 // groupId
        var index: Int
        var type: CaptureGroupType
        var pageCount: Int
        var phase: Phase
        /// A1: failure/label detail, populated at finalize. `failureKind` distinguishes the causes the
        /// old single `.failed` collapsed; `errorMessage/errorCode` surface the OCR reason (previously
        /// dropped). These are labeling only — they never affect any finalize/deletion decision.
        var failureKind: FailureKind? = nil
        var errorMessage: String? = nil
        var errorCode: String? = nil
        /// `succeededNoText`: a document that OCR'd to no text but WAS filed as a complete image-only PDF
        /// (amber warning, not a hard failure). It is staged + filed exactly as before — only its label
        /// differs, so bulk "Retry failed" stops over-counting a successfully-filed image-only doc.
        enum Phase: String {
            case ocr = "OCR…", tagging = "Tagging…", staged = "Staged"
            case succeededNoText = "Filed (image-only)"
            /// W23.h5: filed, but at least one page's PDF holds the placeholder instead of the scan. Amber,
            /// not red — the document IS filed and its text is real; what's missing is the image, and the
            /// source photo is deliberately kept in the Backup Folder so the page can be re-run.
            case succeededPlaceholderImage = "Filed (scan MISSING)"
            case failed = "Failed"
        }
    }

    /// A staged, fully-processed segment awaiting end-of-session finalization (this is the manifest).
    struct StagedSegment: Codable {
        let groupId: String
        let type: String               // CaptureGroupType.rawValue
        var collectionKey: String      // most-recent Box groupId, or "__unfiled__"
        var order: Int
        var pdfURLs: [URL]
        var imageURLs: [URL]
        var jsonURL: URL?
        var boxLabelText: String?
        /// Did EVERY source page produce a PDF on disk? `false` ⇒ a page's generation was silently dropped,
        /// so the segment is INCOMPLETE and finalize must NOT file it (deleting its sources would lose the
        /// page that has no output). `nil` ⇒ legacy manifest (older builds never dropped a page) → complete.
        var pagesComplete: Bool?
        /// W23.h5 — source photos whose staged PDF carries a PLACEHOLDER image page instead of the scan
        /// (`PDFGenerator.ImagePageOutcome.placeholder`, or a `generate` that threw yet still left a file on
        /// disk). The segment IS still filed — the bytes are real and it can be regenerated — but for these
        /// pages the source photo is the ONLY surviving copy of the image, so finalize must not retire it.
        /// `nil`/empty ⇒ nothing withheld (also the legacy-manifest reading, matching old behaviour).
        var placeholderSources: [URL]?
        /// W3.cap-r1 — staged ARTIFACTS (PDF / exported JPEG / merged PDF) whose Finder-tag write threw.
        /// The bytes are complete and the segment IS still filed — that is the owner's recorded decision:
        /// tags are re-derivable, and withholding "filed" over metadata would strand the source photo for a
        /// recoverable problem. What a tag failure DOES cost is findability: the Reader's tag-driven triage
        /// silently omits an untagged file, so this must be said out loud at finalize instead of discarded.
        /// `nil`/empty ⇒ every artifact was tagged (also the legacy-manifest reading).
        var untaggedOutputs: [URL]?
    }

    @Published private(set) var statuses: [SegmentStatus] = []
    @Published private(set) var staged: [StagedSegment] = []
    /// A failed staging-manifest verification is a recovery stop, not an empty session. This notice is
    /// deliberately separate from `CaptureSession.statusMessage`: normal status updates may replace that
    /// transient line, while the operator must keep seeing this recovery instruction.
    @Published private(set) var stagingRecoveryNotice: String?
    var stagingRecoveryBlocked: Bool { stagingManifestBlocked }

    /// End-of-session rotation review (opt-in) — a dedicated pass over every captured page, shown at
    /// Finish before collection naming. One editable row per staged page.
    struct RotationReviewPage: Identifiable {
        let id = UUID()
        let groupId: String
        let pageIndex: Int        // index within its segment's pages
        let order: Int            // segment capture order (for stable sorting)
        let sourceURL: URL
        var rotationDegrees: Int
    }
    @Published var showRotationReview = false
    @Published var rotationReviewPages: [RotationReviewPage] = []

    /// End-of-session finalization state (Phase 3/4).
    @Published var drafts: [CollectionDraft] = []
    @Published var showFinalizeSheet = false
    /// True after the operator hit "Finish session" while segments are still being OCR'd/tagged: we hold
    /// off the rotation review / collection naming until every segment is staged, so none are missed.
    @Published private(set) var pendingFinish = false
    /// Segments still being processed (OCR or tagging) **that can still resolve** — the count behind the
    /// pending-finish row's "(N left)" and the capture panel's "Processing…" spinner.
    ///
    /// The `session.groups` term is not a refinement; it is the difference between the panel describing the
    /// wait and the panel inventing one. A `.ocr`/`.tagging` row whose group has LEFT the session — every page
    /// deleted with the thumbnail ✕, or reclassified away by `X-Replaces` — cannot resolve *while it is gone*:
    /// no group means no tag card and no `finalizeSegment`, and `photoRemoved` cancels the page's task while
    /// leaving the row. `proceedToFinishIfReady` has always excluded exactly those rows from the hold; this is
    /// that same predicate, in ONE place, so the finish cannot wait on one set while the UI names another.
    ///
    /// ⚠️ "While it is gone" is deliberate, and an earlier draft of this said "can NEVER resolve" — which an
    /// adversarial pass refuted. A re-paired phone re-uploads its retained captures (`phoneDidDisconnect`), so
    /// `ingest` can bring the group back, and `photoRemoved` already dropped the `pageTasks` entry, so
    /// `photoIngested` is free to buy a fresh call and `upsertStatus` reuses this very row. The predicate is
    /// evaluated live, so the code is right either way; the absolute phrasing was not. (The same wording sits
    /// on `proceedToFinishIfReady` and predates this item.)
    ///
    /// Fixed here as part of `W3.cap-r3-fu12` rather than filed for later, because that item is what makes it
    /// VISIBLE: the disagreement was survivable only while the Captured pane hid its whole control cluster in
    /// the very state that produces an orphaned row (pane emptied), and fu12 draws the cluster there. Left
    /// unfiltered it would have become a "Processing…" spinner that can never stop.
    ///
    /// ⚠️ THE GROUP-ID SET IS NOT A MICRO-OPTIMISATION. `session.groups` is a COMPUTED property that builds a
    /// dictionary over every photo, sorts each group's pages and then sorts the groups — so the obvious
    /// spelling (`session.groups.contains { … }` inside the filter) rebuilds all of that once PER STATUS ROW.
    /// This is read from `LiveCaptureView`'s header body, which re-evaluates on every published change
    /// including the `statusMessage` write that every arriving photo performs, so on a 100-group session that
    /// ~100 dictionary-builds-and-sorts per render, twice over. Hoisted once instead. (Found by the same pass;
    /// `filter{}.count` also gives up the short-circuit that `proceedToFinishIfReady`'s old `contains` had,
    /// which is why the cheap set matters there too.)
    var processingCount: Int {
        let live = Set(session.groups.map(\.id))
        return statuses.filter { ($0.phase == .ocr || $0.phase == .tagging) && live.contains($0.id) }.count
    }
    /// `W3.cap-r3-fu12`'s adversarial pass — can **Finish** actually DO anything right now? Distinct from
    /// `hasUnfiledWork` below, and the two come apart in a state the first version of that item shipped a
    /// primary button into.
    ///
    /// `finishSession` is gated on **`staged`**, while `pendingFinish` is cleared one level ABOVE it (in
    /// `proceedToFinishIfReady`, the line before the call). So a Finish pressed with an empty `staged` and
    /// nothing that will ever stage is a silent no-op: `requestFinish` arms the flag, spawns a watchdog Task,
    /// `proceedToFinishIfReady` finds every hold open, lowers the flag again, and `finishSession` returns on
    /// its guard. No sheet, no status line, no state change — one orphaned watchdog per press. That state is
    /// reachable exactly where fu12 newly draws the cluster: the ✕ on the last page of a document still in OCR
    /// leaves a roster with an orphaned row and nothing staged, so `hasUnfiledWork` is true (the operator does
    /// still need **Clear**) while Finish has nothing to file.
    ///
    /// `!session.groups.isEmpty` is the second disjunct rather than something narrower because it preserves the
    /// documented reason Finish is enabled before anything stages — it also RECOVERS an un-ended/un-tagged
    /// segment via `completeAllOpenDocGroups`, and that case always has groups. With no groups at all, Finish
    /// can only file `staged`, so `staged` is the whole question.
    ///
    /// This is the operator-facing half only (`LiveCaptureView` puts it in Finish's `.disabled`, so the
    /// affordance is visibly off rather than silently ignored — `W3.cap-r3-fu11`'s shape). The model half is
    /// `finishSession`'s guard, which already refuses; it just refuses without saying so.
    var canFinish: Bool { !staged.isEmpty || !session.groups.isEmpty }
    /// `W3.cap-r3-fu12` — does this session still hold work that **Finish** would file, or **Clear** abandon?
    /// The Captured pane's control cluster (Clear + Finish) is gated on this whenever the pane itself is
    /// empty; see `LiveCaptureView`'s header for the decision and how to undo it.
    ///
    /// Named on the model for the reason `isFinishingScrimUp` was: a headless driver can read a model
    /// property and cannot read a `View`'s predicate, so putting the gate here is what makes it measurable at
    /// all (recovery driver Test 25). The view leg — that the cluster actually DRAWS on it — stays
    /// `W21.vmgui-d`'s to close, exactly as `W3.cap-r3-fu9-fu1`'s M1/M6 recorded for its own button.
    ///
    /// `statuses` rather than `staged`, and the WIDER of the two on purpose: it is the session's segment
    /// roster. A row exists from the moment OCR starts until the segment's group is actually FILED (`finalize`
    /// drops filed groups from `statuses` and `staged` together), so this covers the staged-but-unfiled
    /// segments the item is named for, a segment that FAILED to file (still unfiled — still needs the
    /// buttons), and an orphaned in-flight row. A fully successful finish empties it, so the cluster does not
    /// linger over the "Session complete" summary. That width is MEASURED rather than merely argued: Test 25's
    /// check 7 holds an orphaned row with nothing staged, and weakening this to `!staged.isEmpty` fails it (M2).
    ///
    /// The `pendingFinish` disjunct should be implied — `requestFinish` is only reachable from a button
    /// disabled on `statuses.isEmpty` — and is kept anyway, because `W3.cap-r3-fu9-fu1` ships a renderer that
    /// draws on `pendingFinish` ALONE and this gate must not be what takes an armed finish's only escape
    /// hatch away again.
    var hasUnfiledWork: Bool { !statuses.isEmpty || pendingFinish }
    @Published private(set) var isFinalizing = false
    /// W3.cap-r3-fu10 — the window in which the Live Capture panel is DELIBERATELY blocked to the pointer.
    /// `LiveCaptureView`'s "Finishing — processing segments…" overlay is up for exactly this predicate, and
    /// its scrim absorbs clicks on purpose; the decision, and what it does and does not buy, is written at
    /// the overlay itself (`LiveCaptureView`'s `.overlay`).
    ///
    /// Named here rather than left inline in the view for two reasons. The triple was restated in four
    /// places — the view, this file's `retryFailed` comment, and twice in the recovery driver, once of them
    /// as a hand-copied assertion — so the driver could have gone on passing while the view's own condition
    /// drifted out from under it. And it makes the COVERAGE half of the decision (WHEN the panel is blocked)
    /// measurable from a headless driver, which the hit-test half can never be.
    ///
    /// `!showRotationReview` is redundant on every path that exists today, but ⚠️ **not for the reason the
    /// first draft of this comment gave.** It said `finishSession` refuses to raise the flag while finalizing;
    /// `finishSession` contains no such guard (its only guard is `!staged.isEmpty`), and the adversarial pass
    /// caught it. The real argument is two steps further out, and worth writing down because a reader who
    /// checks the easy version finds nothing there: `showRotationReview = true` has exactly ONE writer,
    /// `finishSession`, whose single caller is `proceedToFinishIfReady` — which is `guard pendingFinish` and
    /// clears `pendingFinish` on the line before the call. `requestFinish` reaches `finishSession` only
    /// through that function, and carries `guard !showFinalizeSheet, !showRotationReview, !isFinalizing`
    /// itself. (⚠️ This sentence used to say `finishSession` had TWO callers, `requestFinish` among them;
    /// `requestFinish` calls `proceedToFinishIfReady`, not `finishSession`. Corrected by `W3.cap-r3-fu9-fu1`'s
    /// pass, which needed this note as the authority for its own `pendingFinish ∧ isFinalizing` argument —
    /// the conclusion was right, the cited chain was not.) `applyRotationReviewAndFinalize` then clears the flag on the line before
    /// `isFinalizing = true`. So the state is unreachable because of `requestFinish`'s guard, NOT because of
    /// anything local to `finishSession`; remove that guard and this term stops being redundant.
    ///
    /// Kept because the rule the overlay implements is "the finish flow's own two modals are not doubled up
    /// with a scrim", and naming both is what makes that readable. ⚠️ It is NOT "no sheet is over the panel":
    /// the view attaches FIVE `.sheet` modifiers, and the other three (the tag card, the model-choice sheet,
    /// the text viewer) can each be up in this window, floating ABOVE the scrim. Those are precisely the
    /// entries the model-layer guards exist for — see `retryFailed`.
    var isFinishingScrimUp: Bool { isFinalizing && !showFinalizeSheet && !showRotationReview }
#if DEBUG
    /// DEBUG-only UI seam for the off-screen VM test. It exposes the same no-sheet regeneration state the
    /// view branches on without starting OCR, a receiver, or any file-writing finalize path.
    func _uiTestShowFinishingScrim() {
        isFinalizing = true
        showFinalizeSheet = false
        showRotationReview = false
    }
#endif
    @Published private(set) var finalizeSummary: String?
    /// Document segments whose OCR produced no text (filed as image-only PDFs; retryable).
    @Published private(set) var failedGroupIds: Set<String> = []

    // MARK: Per-item sheet targets (W3.cap-r3-fu9)

    /// One segment's "Retry with model" / "Rotate & re-run" sheet.
    struct ModelChoiceTarget: Identifiable, Equatable {
        let groupId: String
        let includeRotation: Bool
        var id: String { groupId + (includeRotation ? "-rot" : "-mdl") }
    }
    /// One segment's "View text" sheet.
    struct SegmentTextTarget: Identifiable, Equatable { let id: String }

    /// The Processing list's two PER-ITEM sheets — "Retry with model" / "Rotate & re-run", and
    /// "View text". Owned HERE rather than in `LiveCaptureView`'s `@State` since `W3.cap-r3-fu9`, because
    /// **the finish flow has to be able to see them.**
    ///
    /// `finishSession` is the ONE writer of `showRotationReview`, and one of its two callers —
    /// `proceedToFinishIfReady` — fires from BACKGROUND events (a segment staging, a phone heartbeat, the
    /// 5 s watchdog) with no operator click anywhere in the chain. So the review can be raised at a moment
    /// when one of these sheets is already on screen, and the app then depends on what SwiftUI does with a
    /// second concurrent presentation — five `.sheet` modifiers are chained on one view. That behaviour was
    /// NOT observed (a headless driver cannot see presentation at all, and the Processor has no VM GUI lane
    /// yet — `W21.vmgui-d`), and all three possibilities are bad in a different way:
    ///
    ///   • SUPPRESSED (the new presentation is dropped) — the review is silently SKIPPED, and because
    ///     `requestFinish` guards `!showRotationReview` while the only writers that clear it are the
    ///     invisible sheet's own buttons, **Finish is then dead for the rest of the session** with staged
    ///     output nobody can file. This is the hazard `W3.cap-r3-fu9` was filed for.
    ///   • QUEUED (shown after the first sheet closes) — the deferred Apply's `retryFailed` runs first and
    ///     sets `retained[gid] = nil`, so the review that then appears describes pages from a segment being
    ///     re-OCR'd, and `applyRotationReviewAndFinalize`'s `guard var seg = retained[…]` silently DROPS
    ///     that group's rotation edits.
    ///   • STACKED (both presented, review on top) — benign for the review, but dismissing it drops the
    ///     operator back onto a still-presented model sheet whose Apply now lands inside `isFinalizing`,
    ///     which is the one entry `W3.cap-r3-fu7`'s `retryFailed` guard is the whole defence for (and where
    ///     its refusal is silent).
    ///
    /// So the fix is NOT to guess which one happens: `proceedToFinishIfReady` refuses to START the finish
    /// flow while either sheet is up, which makes the concurrent-presentation state unreachable in all
    /// three. That guard needs this state to be model state — a second copy published out of the view would
    /// be exactly the two-records-one-fact shape `W3.cap-r3-fu1`/`-fu6` were filed for. It also means the
    /// wiring is COMPILE-enforced rather than test-enforced: the view has no per-item `@State` left to fall
    /// back to, so it cannot silently stop feeding this.
    ///
    /// Writable on purpose — `.sheet(item:)` clears its binding on dismissal, and that write is exactly the
    /// signal `perItemSheetDidChange` needs.
    @Published var modelChoiceTarget: ModelChoiceTarget? {
        didSet { perItemSheetDidChange(wasUp: oldValue != nil) }
    }
    @Published var textViewerTarget: SegmentTextTarget? {
        didSet { perItemSheetDidChange(wasUp: oldValue != nil) }
    }

    /// How long after the last per-item sheet target is cleared the finish stays held anyway.
    ///
    /// ⚠️ THE MOST DELICATE PART OF `W3.cap-r3-fu9`, and it exists because a cleared target is NOT the sheet
    /// leaving the screen. `.sheet(item:)` — and `ModelChoiceSheet`'s own `onApply`/`onCancel` and
    /// `SegmentTextViewerSheet`'s `onDismiss` — write nil while AppKit is still animating the sheet OUT,
    /// ~0.2–0.4 s. The first version of this fix advanced the finish one MainActor turn after that write
    /// (microseconds), which raised the rotation review DURING the outgoing sheet's teardown and so made the
    /// concurrent-presentation state this item exists to prevent the ORDINARY path rather than a rare race.
    /// An adversarial pass caught it before it shipped. 1.5 s is a 4–5× margin over a macOS sheet dismissal.
    ///
    /// Deliberately a bounded OVER-hold rather than a presentation callback (`.onDisappear` on the sheet
    /// body), and the asymmetry is the argument: releasing too EARLY re-opens a hazard whose worst outcome is
    /// unrecoverable — a dropped presentation leaves `showRotationReview` true with no sheet on screen, its
    /// only writers are that sheet's own buttons, and `clearSessionState` does not clear it, so Finish would
    /// be dead for the rest of the session — whereas holding too LONG costs seconds and expires by itself. A
    /// signal fed from the view could also leak and then hold forever; a deadline cannot.
    static let perItemSheetGrace: TimeInterval = 1.5

    /// When the last per-item sheet target was cleared. Only ever read through `perItemSheetUp`.
    private var perItemSheetClearedAt: Date?

    /// True while one of the two per-item sheets is on screen — or may still be, for `perItemSheetGrace`
    /// after its target was cleared. Read by `proceedToFinishIfReady`.
    var perItemSheetUp: Bool {
        if modelChoiceTarget != nil || textViewerTarget != nil { return true }
        if let t = perItemSheetClearedAt, Date().timeIntervalSince(t) < Self.perItemSheetGrace { return true }
        return false
    }

    /// A per-item sheet's target was cleared — it is dismissing. Start the grace, and if a Finish is waiting
    /// on it, re-evaluate once that grace has expired.
    ///
    /// The delayed re-evaluation is LATENCY, not correctness: `startFinishWatchdog` re-evaluates every 5 s
    /// regardless, so dropping this only means the operator waits up to that long to see the review after
    /// closing a sheet. It must never be shortened below the grace, which is the entire point of the hop.
    /// ⚠️ The condition is the raw targets, NOT `!perItemSheetUp` — during the grace that property is
    /// deliberately still true, so testing it here would mean this never fires at all.
    private func perItemSheetDidChange(wasUp: Bool) {
        guard wasUp, modelChoiceTarget == nil, textViewerTarget == nil else { return }
        perItemSheetClearedAt = Date()
        guard pendingFinish else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((Self.perItemSheetGrace + 0.1) * 1_000_000_000))
            self?.proceedToFinishIfReady()
        }
    }

    private unowned let session: CaptureSession
    private var config: SessionProcessingConfig?
    private var stagingDir: URL?
    /// A rejected manifest must not be replaced by normal resume/retry/finalize persistence.
    private var stagingManifestBlocked = false

    /// Stable identity of a captured PAGE, and the key for everything that must be started exactly once
    /// per page. **Not** `CapturedPhoto.id` (W3.cap-r2): that is a fresh `UUID()` minted in the initializer,
    /// so the idempotent re-upload path — `CaptureSession.ingest` REPLACES a same-`(groupId, seq)` photo
    /// with a new value on a phone auto-retry after a dropped ack — hands us a different `id` for the very
    /// same page, and the "already started" guard let it through into a SECOND paid OCR call (with the
    /// first Task orphaned). `(groupId, seq)` is the identity the phone assigns and the identity `ingest`
    /// itself de-duplicates on, so keying here on it makes the guard mean what it says.
    struct PageKey: Hashable {
        let groupId: String
        let seq: Int
        init(_ photo: CapturedPhoto) { groupId = photo.groupId; seq = photo.seq }
    }

    /// Every page's OCR call, and — since W3.cap-r3-fu1 — the ONLY record of which pages have started one.
    /// There used to be a second one (a `startedPages: Set<PageKey>` inserted beside the Task), and it went
    /// stale the way a duplicated fact does: three paths freed the Task and left the key armed. See the guard
    /// in `photoIngested` for what that cost and why presence-of-Task is the right question to ask.
    private var pageTasks: [PageKey: Task<OCRResult, Never>] = [:]
    private var finalizedGroups: Set<String> = []
    /// Bumped by `clearSessionState()`. A `finalizeSegment` that SUSPENDED at an `await` before the operator
    /// hit Clear captures this at its start and re-checks it after each await; if it changed, the session was
    /// cleared out from under it, so finalize bails cleanly — no re-added state, no stale manifest, no orphan
    /// output PDF repopulating the just-cleared Processing pane (B8). A no-op when Clear was never pressed.
    private var clearGeneration = 0
    /// Everything `writeSegmentFiles` needs, retained per finalized segment so the end-of-session
    /// rotation review can regenerate a segment's staged PDF/JPG with corrected rotation. In-memory
    /// for the current run only (rotation review is a same-session step, before finalization).
    private var retained: [String: RetainedSegment] = [:]
    private var currentCollectionKey = "__unfiled__"
    /// Each group's collection, pinned when its first photo arrives (in capture order) so it's
    /// independent of the order segments happen to finalize in.
    private var groupCollectionKey: [String: String] = [:]

    /// Optional per-group OCR override from a per-item "retry with model" / "rotate & re-run". Threaded
    /// into that group's re-OCR (provider/model) and finalize (forced rotation), then cleared once consumed
    /// so a later normal re-finalize doesn't reuse it. Absent for the common (session-config) path.
    struct OCROverride {
        let provider: LLMProvider
        let model: LLMModel
        let thinkingLevel: ThinkingLevel?
        let apiKey: String
        let rotation: Int?
    }
    private var groupOCROverride: [String: OCROverride] = [:]

    init(session: CaptureSession) { self.session = session }

    // MARK: - Lifecycle

    /// Where a session's processed outputs are staged before end-of-session finalize. As of the **Recovery
    /// Core Directive** this lives INSIDE the session's VISIBLE backup folder —
    /// `~/Pictures/Archive Processor Live Capture/<session>/_processed/` — so the staged PDFs/JPGs/JSON
    /// (with tags) sit right next to the raw source photos and are recoverable in Finder if the app fails
    /// before finalize. Co-locating them there also removes a whole class of failure (Application-Support
    /// unavailable, staging pruned out from under the run, session-id mismatch after relaunch) that could
    /// strand or drop already-processed output. Recovery of both sources + processed output is now unified:
    /// one session folder, recovered together.
    static func stagingDir(for session: CaptureSession) -> URL {
        session.incomingFolder.appendingPathComponent("_processed", isDirectory: true)
    }

    /// Legacy flat staging parent used by pre-2026-07 builds (`Application Support/ArchiveProcessor/
    /// LiveStaging/<session>`). Retained ONLY so a session staged by an older build can still resume from
    /// there, and so orphaned leftovers can be cleaned up. New sessions always stage under the visible
    /// backup folder (see `stagingDir(for:)`).
    static var legacyStagingRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? CaptureSession.backupRoot
        return base.appendingPathComponent("ArchiveProcessor/LiveStaging", isDirectory: true)
    }

    /// Best-effort cleanup of orphaned staging dirs left in the LEGACY flat location by older builds. A
    /// legacy staging dir is orphaned when its session's backup folder no longer exists (finalized or
    /// abandoned). NEVER removes one whose backup folder still exists (it may still be resumed from there),
    /// so it cannot discard resumable work. New sessions stage inside the backup folder, where an empty
    /// session folder (its `_processed` included) is pruned by `CaptureSession.pruneEmptySessions`.
    private static func pruneLegacyStaging() {
        let fm = FileManager.default
        guard let subdirs = try? fm.contentsOfDirectory(at: legacyStagingRoot, includingPropertiesForKeys: nil) else { return }
        for dir in subdirs {
            let backup = CaptureSession.backupRoot.appendingPathComponent(dir.lastPathComponent, isDirectory: true)
            if !fm.fileExists(atPath: backup.path) { try? fm.removeItem(at: dir) }
        }
    }

    /// Arm the coordinator for a `.live` session. Called from `CaptureSession.chooseLive`.
    func activate(config: SessionProcessingConfig) {
        self.config = config
        stagingManifestBlocked = false
        stagingRecoveryNotice = nil
        let fm = FileManager.default
        // Primary (Recovery Core Directive): stage inside the session's VISIBLE backup folder, so processed
        // PDFs/JPGs (with tags) are recoverable next to the raw sources if the app fails before finalize.
        let primary = Self.stagingDir(for: session)
        // Back-compat resume: a session staged by an OLDER build lives under the flat Application-Support
        // staging root, and an older-still one under the output folder. If the primary has no manifest yet
        // but a legacy location does, keep using that legacy dir IN PLACE so its already-staged outputs
        // aren't orphaned (or needlessly re-OCR'd). New sessions always use `primary`.
        let legacyAppSupport = Self.legacyStagingRoot.appendingPathComponent(session.sessionId, isDirectory: true)
        let legacyOutput = config.outputDirectory
            .appendingPathComponent(".ArchiveProcessor-LiveStaging", isDirectory: true)
            .appendingPathComponent(session.sessionId, isDirectory: true)
        func hasManifest(_ d: URL) -> Bool { fm.fileExists(atPath: d.appendingPathComponent("staging-manifest.json").path) }
        let dir: URL = hasManifest(primary) ? primary
            : (hasManifest(legacyAppSupport) ? legacyAppSupport
               : (hasManifest(legacyOutput) ? legacyOutput : primary))
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        stagingDir = dir
        Self.pruneLegacyStaging()   // best-effort: drop orphaned staging left by older builds
        guard loadStagingManifest() else { return }   // preserve failed recovery state; never resume as empty
        // Process photos already received (resume after a crash, or "chose live after some capture").
        for photo in session.photos { photoIngested(photo) }
        for group in session.groups where group.type == .document
            && session.resolvedGroupIds.contains(group.id) && !finalizedGroups.contains(group.id) {
            let gid = group.id
            Task { [weak self] in await self?.finalizeSegment(groupId: gid) }
        }
    }

    /// Resume only a versioned, fingerprint-verified manifest. A bad record is quarantine-worthy evidence,
    /// not an empty list that normal processing may silently replace.
    @discardableResult
    private func loadStagingManifest() -> Bool {
        guard let stagingDir else { return true }
        let url = stagingDir.appendingPathComponent("staging-manifest.json")
        let fm = FileManager.default
        // Quarantine is durable recovery state. The canonical filename is absent by design after a rejection,
        // so treating that absence as a fresh session on the next launch would silently resume and overwrite
        // the evidence the previous launch deliberately preserved.
        do {
            if let quarantined = try existingQuarantinedManifest(in: stagingDir) {
                blockStagingRecovery(at: url, reason: "was previously quarantined after a failed integrity check",
                                     existingQuarantine: quarantined)
                return false
            }
        } catch {
            blockStagingRecovery(at: url, reason: "could not be inspected for a previous quarantine")
            return false
        }
        guard fm.fileExists(atPath: url.path) else { return true }
        guard let data = try? Data(contentsOf: url) else {
            blockStagingRecovery(at: url, reason: "could not be read")
            return false
        }
        let decoder = JSONDecoder()
        guard let manifest = try? decoder.decode(StagingManifest.self, from: data) else {
            // No migration path: no app data exists to preserve, and accepting an unversioned/partial object
            // would recreate the silent-open recovery failure this manifest is meant to prevent.
            blockStagingRecovery(at: url, reason: "is malformed or uses an unsupported schema")
            return false
        }
        guard manifest.schemaVersion == StagingManifest.currentSchemaVersion else {
            blockStagingRecovery(at: url, reason: "uses an unknown schema version")
            return false
        }
        guard manifest.hasValidFingerprint else {
            blockStagingRecovery(at: url, reason: "did not pass its integrity check")
            return false
        }
        let restored = manifest.staged
        for r in manifest.retained { retained[r.groupId] = r }   // enables the rotation review after resume
        staged = restored
        for s in restored {
            finalizedGroups.insert(s.groupId)
            groupCollectionKey[s.groupId] = s.collectionKey
            let type = CaptureGroupType(rawValue: s.type) ?? .document
            let saved = retained[s.groupId]
            // A failed record can have zero output URLs, and a merged N-page record has one PDF. The retained
            // inputs are the exact source-page count for a current manifest — use them so a resumed retry's
            // row and model-choice cost estimate do not claim 0p/1p. Legacy records keep the old output count.
            let pageCount = max(saved?.pages.count ?? 0, max(s.imageURLs.count, s.pdfURLs.count))
            if !statuses.contains(where: { $0.id == s.groupId }) {
                statuses.append(SegmentStatus(id: s.groupId, index: statuses.count + 1,
                    type: type,
                    pageCount: pageCount, phase: .staged))
            }
            // W3.cap-r3-fu8 — a current manifest carries the exact per-page OCR results beside its staged
            // record, so resume owes the same label as both write paths. The old hardcoded `.staged` made a
            // `.noOutput` / `.incompleteOutput` record look successful and left it outside `failedGroupIds`:
            // finalize still (correctly) refused to file it, but the operator saw no failure and had no retry
            // action. Relabelling makes the existing bulk retry AVAILABLE; it does not run it, so relaunch
            // spends nothing until the operator explicitly asks.
            //
            // A verified record can still lack matching retained write inputs. Do not approximate from
            // filenames: passing an empty result list would mislabel a complete text-bearing document as
            // image-only. Preserve the `.staged` fallback when the evidence is absent; recovery data stays
            // visible and untouched either way.
            if let saved {
                labelStagedRecord(s.groupId, type: type, outcome: s, results: saved.pages.map(\.result))
            }
        }
        // Restore the "current collection" so subsequent captures file under the right Box.
        if let lastBox = restored.filter({ $0.type == CaptureGroupType.box.rawValue }).max(by: { $0.order < $1.order }) {
            currentCollectionKey = lastBox.groupId
        }
        return true
    }

    /// Preserve the rejected bytes and leave every staged artifact alone. If the rename itself fails, the
    /// original remains in place; this path never overwrites or deletes either version.
    private func existingQuarantinedManifest(in directory: URL) throws -> URL? {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("staging-manifest.corrupt-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }

    private func blockStagingRecovery(
        at manifestURL: URL, reason: String, existingQuarantine: URL? = nil
    ) {
        stagingManifestBlocked = true
        let fm = FileManager.default
        var quarantinedURL = existingQuarantine
        if quarantinedURL == nil {
            let milliseconds = Int(Date().timeIntervalSince1970 * 1_000)
            var attempt = 0
            while quarantinedURL == nil {
                let suffix = attempt == 0 ? "" : "-\(attempt)"
                let candidate = manifestURL.deletingLastPathComponent()
                    .appendingPathComponent("staging-manifest.corrupt-\(milliseconds)\(suffix).json")
                guard !fm.fileExists(atPath: candidate.path) else { attempt += 1; continue }
                do {
                    try fm.moveItem(at: manifestURL, to: candidate)
                    quarantinedURL = candidate
                } catch {
                    break
                }
            }
        }
        let preservation: String
        if let quarantinedURL {
            preservation = "Its exact bytes were preserved as \(quarantinedURL.lastPathComponent)."
        } else {
            preservation = "Its original file could not be renamed and remains at staging-manifest.json."
        }
        let notice = "Live Capture recovery stopped: the staging manifest \(reason). \(preservation) Staged files remain untouched in the Backup Folder; recover them before starting another session."
        stagingRecoveryNotice = notice
        session.statusMessage = notice
    }

    /// Re-run OCR for a set of segments, then re-finalize them. Defaults to the full failed set (the bulk
    /// "Retry failed" / G1 case); pass a single-element set for a per-item retry. `override` (optional)
    /// re-OCRs those segments with a chosen provider/model and/or forces their output rotation instead of
    /// the session's locked config. The body is unchanged from the original bulk retry — it just iterates
    /// the passed set — so the data-safety sequence (delete stale staged output → drop finalized/failed
    /// bookkeeping → persist the cleaned manifest BEFORE re-processing → re-ingest) is identical. A
    /// `.staged`/`.succeededNoText` segment is retryable too: old output is deleted first, so it's safe.
    func retryFailed(groupIds: Set<String>? = nil, override: OCROverride? = nil) {
        guard !stagingManifestBlocked, session.processingMode == .live else { return }
        // W3.cap-r3-fu7 — refuse while a finish is regenerating, and refuse HERE rather than only in the UI.
        // `applyRotationReviewAndFinalize` sets `isFinalizing` and then writes each changed segment's files
        // from a DETACHED task, so for the length of that write the Live Capture panel is on screen with no
        // sheet over it (`isFinishingScrimUp` above is that state, and `LiveCaptureView`'s throbber overlay is
        // up for exactly it).
        //
        // ⚠️ ON SCREEN is not the same as REACHABLE, and the item that filed this — plus the first draft of
        // this very comment — conflated the two. An independent adversarial pass caught it and filed the
        // question as `W3.cap-r3-fu10`; **fu10 has now been decided: that throbber's scrim is MEANT to block
        // the pointer** (the grounds, and the limits of what was observed rather than reasoned, are at the
        // overlay). So "on screen" is settled — but the answer is NOT that these gates are spare, and the
        // first draft's guess that they were is the part that was wrong. A scrim stops the pointer and
        // nothing else, so the three entries split three ways:
        //
        //   • The bulk "Retry N failed" button and the expanded row's per-item retry, TO THE MOUSE: covered
        //     twice. The scrim eats the click and the `.disabled`/withheld-action edits grey them out. This
        //     is the only leg that is genuinely defence-in-depth, and it is the leg the first draft
        //     generalized from.
        //   • The same two buttons, TO THE KEYBOARD OR TO VOICEOVER: covered ONCE, here and in the view — not
        //     by the scrim. Hit-testing is neither focus nor accessibility; with macOS "Keyboard navigation"
        //     on (off by default) ⇥ still reaches a control behind an overlay, and there is no
        //     `.accessibilityAddTraits(.isModal)` on the overlay to stop an AX client either. `.disabled` is
        //     what removes the control from both. (Reasoned from the code, NOT observed — see the overlay.)
        //   • The deferred `modelChoiceTarget` sheet Apply: covered ONCE, and only HERE. A presented sheet
        //     floats ABOVE the overlay — the scrim's predicate does not mention `modelChoiceTarget`, so that
        //     sheet is up with the scrim uselessly behind it — and its Apply fires whenever the operator gets
        //     round to it. This guard is the whole defence on that path (its reachability rides on
        //     `W3.cap-r3-fu9`).
        //
        // Which is the same conclusion the paragraph below reaches from the deferred-callback argument alone:
        // the model layer is where the refusal has to be true. fu10 narrows what the VIEW edits are for
        // (the keyboard, and telling the operator the affordance is off) without making them optional.
        //
        // A retry landing in that window deletes the segment's
        // staged output, releases it, drops `retained` and re-ingests every page — buying its OCR a second
        // time — and then the regeneration's `staged[idx] = fresh` overwrites whatever the re-run appended
        // with a record pointing at files the retry had already deleted. Data-safe (the record is then
        // unfilable, so `executePlans` skips it and its sources stay in the backup folder) but the money is
        // spent and the operator is left with a record describing neither write.
        //
        // The model layer is the load-bearing gate, not the two `.disabled`/withheld-action edits that ship
        // with it, because this is the ONE place all three entry points converge — and one of them is
        // deferred: `LiveCaptureView`'s `modelChoiceTarget` sheet captures a group when it opens and calls
        // back on Apply, which can be an arbitrary time later, so no enabled-ness computed when the button
        // was drawn can speak for the moment the retry actually runs. The UI edits are there so the operator
        // is not offered something that would be refused; this is what makes the refusal true.
        //
        // The accepted limit, stated rather than hidden: that same deferred Apply is the one path where the
        // refusal is SILENT — `onApply` calls this, gets nothing, and then clears `modelChoiceTarget`
        // unconditionally, so the sheet closes taking the operator's provider, model, thinking level, ROTATION
        // choice and freshly TYPED API KEY with it. (The first draft of this note said "a second press", which
        // undersold it — the adversarial pass priced it properly.) It is accepted rather than fixed because the
        // alternative is a new operator-facing error channel for a path that may not be reachable at all
        // (`W3.cap-r3-fu9`); if fu9 confirms it is, the right fix is to keep the sheet OPEN on a refusal, not
        // to widen this guard. The button paths do not have the problem — they are disabled/withheld for the
        // length of the window, so the state is visible before the press.
        //
        // Scoped to `isFinalizing` DELIBERATELY, and not widened to `requestFinish`'s
        // `!showFinalizeSheet, !showRotationReview` triple. Those two states put a modal sheet over the
        // panel, so the panel's own retry affordances are unreachable in them — the only entry that survives
        // a sheet is the deferred `modelChoiceTarget` Apply above, and reaching it needs a SECOND sheet to
        // have been suppressed by the first (SwiftUI presents one sheet per view). That is a distinct claim
        // about the presentation layer with a distinct fix, filed as `W3.cap-r3-fu9`, not something to
        // absorb into a money-path refusal that no test here drives.
        //
        // The window has NO TRAILING HOLE, and that rests on two adjacent-line facts worth naming because a
        // reorder would silently open one. `applyRotationReviewAndFinalize` does `isFinalizing = false` and
        // `beginFinalize()` with no await between them, and `finalize` does `showFinalizeSheet = false` and
        // `isFinalizing = false` likewise — so there is no MainActor turn in which the panel is exposed AND
        // this guard is already down. Put an await between either pair and the hazard comes back in the gap.
        // (`beginFinalize`'s own `guard !staged.isEmpty` can leave no sheet up, but then there is nothing
        // staged for a retry to race.)
        guard !isFinalizing else { return }
        let targets = groupIds ?? failedGroupIds
        let fm = FileManager.default
        var toReprocess: [String] = []
        for gid in Array(targets) {
            guard let group = session.groups.first(where: { $0.id == gid }) else { failedGroupIds.remove(gid); continue }
            // Delete the old staged output + retained state first, so we don't orphan files
            // on disk or re-review stale rotation for a segment we're about to regenerate.
            if let old = staged.first(where: { $0.groupId == gid }) {
                for u in old.pdfURLs { try? fm.removeItem(at: u) }
                for u in old.imageURLs { try? fm.removeItem(at: u) }
                if let j = old.jsonURL { try? fm.removeItem(at: j) }
            }
            releaseFinalizedGroup(gid)
            staged.removeAll { $0.groupId == gid }
            retained[gid] = nil
            // W3.cap-r3-fu2 — cancel before dropping, in the order `photoRemoved` uses. A retry is a decision
            // to buy this group's OCR again: the old calls' every output is deleted just above (staged files,
            // `retained`) and the re-ingest below replaces each entry, so a call left running here is spend
            // nobody can read. Dropping the entry is precisely what makes it unreachable, so the cancel has to
            // come first or not at all.
            //
            // It is a NO-OP as the code stands, and that is worth stating rather than implying a live bug was
            // fixed. No group that reaches here can still hold a running call: `finalizeSegment` awaits every
            // page and clears these same entries (its `// free memory` loop, below) BEFORE `markFailed` adds it to
            // `failedGroupIds` — the bulk button's whole input — and the per-item menu offers a retry only for
            // `.failed`/`.succeededNoText`/`.succeededPlaceholderImage`, all of them past that same clear
            // (`.ocr`/`.tagging` render as `.processing`, whose `actions(for:)` is `[]`). A page arriving for
            // such a group afterwards cannot start one either: the group is still in `finalizedGroups`, so
            // `photoIngested` takes the late-page branch. That last leg rests on `failedGroupIds` never
            // outliving `finalizedGroups` — which `W3.cap-r3-fu5` made structural: both exits from
            // `finalizedGroups` (`releaseFinalizedGroup` here, `releaseAllFinalizedGroups` for Clear) clear
            // the two sets together. See that helper for what "structural" does and does not cover.
            //
            // ⚠️ If a future edit DOES make this reachable while a `finalizeSegment` is suspended on the group,
            // the fix is to refuse the retry (`guard !finalizedGroups.contains(gid)`), NOT to copy
            // `photoRemoved`'s mid-finalize carve-out. Two reasons. First, the cancel is genuinely worse than
            // the drop for the ONE page finalize is parked on: finalize re-reads `pageTasks` per page, so
            // dropping costs it only the pages it has not reached yet, but that page's Task was dereferenced
            // before it suspended and cancelling destroys a call it already bought (the trade Test 17
            // scenario 5 measures). Second, `finalizedGroups.remove(gid)` above plus the `segmentResolved`
            // below would start a SECOND `finalizeSegment` for the group while the first is still suspended,
            // and both would `staged.append` — a carve-out here would leave that untouched.
            //
            // The symmetry is the point: no entry leaves `pageTasks` with a RUNNING call behind it. (The
            // `// free memory` loop drops without cancelling, and correctly so — it runs after finalize has
            // awaited every one of those pages, so there is nothing left to cancel.) That way the next edit
            // which makes a retry reachable mid-flight cannot inherit a paid leak.
            for p in group.photos {
                let k = PageKey(p)
                pageTasks[k]?.cancel()
                pageTasks[k] = nil
            }
            groupOCROverride[gid] = override    // nil clears any prior override
            setStatusDetail(gid, kind: nil, error: nil)   // clear the stale reason line
            setPhase(gid, .ocr)
            toReprocess.append(gid)
        }
        // Persist the cleaned state BEFORE re-processing, so a crash mid-retry leaves a consistent
        // manifest (failed segments removed) rather than a half-updated one.
        persistManifest()
        for gid in toReprocess {
            guard let group = session.groups.first(where: { $0.id == gid }) else { continue }
            for p in group.photos { photoIngested(p) }
            if group.type == .document { segmentResolved(groupId: gid) }
        }
    }

    /// Whether a group has been finalized (staged) this session — the Mac uses this to avoid removing
    /// a reclassified photo's source out from under an already-staged live segment.
    func isFinalized(_ groupId: String) -> Bool { finalizedGroups.contains(groupId) }

    /// The PER-GROUP way out of `finalizedGroups` (`W3.cap-r3-fu5`) — and it takes that group's
    /// `failedGroupIds` entry with it. Together with `releaseAllFinalizedGroups` (the whole-session Clear)
    /// that is BOTH exits, and both clear the pair, which is what `failedGroupIds ⊆ finalizedGroups` rests
    /// on rather than every future caller remembering to pair two removals.
    ///
    /// Scope of "by construction", stated exactly, because an earlier draft of this comment overstated it
    /// and an independent adversarial pass caught it. (a) These are the only two exits *today*;
    /// `finalizedGroups` is a bare `private var Set<String>`, so `.subtract` / `.filter` / a whole-set
    /// assignment would bypass either helper with no compiler help. (b) `retryFailed` releases the group
    /// SYNCHRONOUSLY but re-arms it only through `segmentResolved`'s `Task`, so a `finalizeSegment`
    /// suspended on that group could resume inside the gap and `markFailed` it while it is out of
    /// `finalizedGroups`. That is unreachable today for exactly the reason `retryFailed`'s cancel loop is a
    /// no-op — nothing offers a retry for a segment mid-flight — a mild circularity worth naming rather
    /// than hiding, since the cancel loop's own latency argument leans on this subset in turn.
    ///
    /// Why the subset is worth keeping: `markFailed` is the only writer that INSERTS, and it runs inside
    /// `finalizeSegment` after that group is already finalized, so the failed set can only ever be a subset
    /// — *provided* nothing drops the finalized entry alone. `retryFailed` always paired them; `finalize`
    /// did not, and that unpaired `remove` is what this closes. Several of this subsystem's latency
    /// arguments lean on the subset, most recently `retryFailed`'s cancel loop: a failed group cannot be
    /// holding a live call, because it is still finalized and so a late page for it takes `photoIngested`'s
    /// late-page branch instead of buying OCR.
    ///
    /// It is also right on its own merits at both call sites, invariant aside. A group being re-processed is
    /// not a failed one (it is about to be re-OCR'd), and a group whose every PDF reached its collection is
    /// not a failed one either.
    private func releaseFinalizedGroup(_ groupId: String) {
        finalizedGroups.remove(groupId)
        failedGroupIds.remove(groupId)
    }

    /// The whole-session counterpart, for Clear. Same pairing for the same reason: the guarantee is that
    /// there are exactly two exits and both clear both sets. Before `W3.cap-r3-fu5` this was two adjacent
    /// `removeAll`s that happened to agree — the same "remember to keep them together" hazard `finalize`
    /// had already lost, just with the two lines next to each other instead of one of them missing.
    private func releaseAllFinalizedGroups() {
        finalizedGroups.removeAll()
        failedGroupIds.removeAll()
    }

    /// OCR text retained for a segment (joined across its pages), for the shared row's text viewer.
    /// Nil when nothing usable was captured (e.g. an image-only / failed segment).
    func retainedText(for groupId: String) -> String? {
        guard let seg = retained[groupId] else { return nil }
        let joined = seg.texts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// Staged output files (PDFs + exported images) for a segment, for "Reveal in Finder".
    func stagedURLs(for groupId: String) -> [URL] {
        guard let s = staged.first(where: { $0.groupId == groupId }) else { return [] }
        return s.pdfURLs + s.imageURLs
    }

    // MARK: - Triggers (called by CaptureSession)

    /// A photo landed. Start its OCR immediately (max overlap). Box/Folder markers (single image,
    /// no tag card) also finalize right away.
    func photoIngested(_ photo: CapturedPhoto) {
        let key = PageKey(photo)
        // W3.cap-r3-fu1 — the started-once guard asks `pageTasks`, not a second set of its own. It used to ask
        // a `startedPages` set, and that set outlived the work it was guarding on three paths that free the
        // Task without retiring the key: `finalizeSegment` clears `pageTasks` for the pages it staged,
        // `finalize`'s straggler / partial branches leave keys armed for groups they just dropped out of
        // `finalizedGroups`, and `photoRemoved`'s mid-finalize carve-out deliberately keeps the key. A page
        // the phone re-sent after its group finalized therefore returned HERE, above the late-page branch
        // below: it bought no call, raised no warning, and — once `finalize` had filed the group and dropped
        // it from `finalizedGroups` — a later finalize read `pageTasks[key] == nil` as "OCR not started" and
        // filed a silently text-less archival document.
        //
        // Presence-of-Task is the question the guard was always for, and it is strictly stronger than
        // started-ness for the whole life of a page: a COMPLETED Task stays in the map until finalize clears
        // it, so W3.cap-r2's dedup of a dropped-ack re-upload is unchanged, and the mid-finalize carve-out
        // still de-duplicates a re-arrival rather than letting it overwrite the entry finalize is suspended
        // on. That last part is exactly why retiring the key inside the carve-out would have been the WRONG
        // fix — it would have let a re-arrival double-buy the page finalize was about to read. A page with no
        // Task and no finalize behind it is a page whose OCR is genuinely gone, and it is free to buy one.
        guard !stagingManifestBlocked, session.processingMode == .live, let config,
              pageTasks[key] == nil else { return }   // not live / this page's call is already ours → silent
        if finalizedGroups.contains(photo.groupId) {
            // A page arrived for a document already finalized on the Mac — e.g. the operator kept shooting the
            // SAME document after it was force-completed at Finish, instead of starting a new segment. It can't
            // join that finished collection; it stays in the backup folder. Surface it (don't drop silently).
            session.statusMessage = "A late page arrived for an already-finished document — kept in the Backup Folder, not this collection. Tap Box or End segment to start a NEW segment."
            return
        }

        // New capture arrived while a Finish is pending: treat it as another segment to include — the
        // pending finish KEEPS waiting and will complete once this segment is tagged + processed too (it's
        // not dropped or force-completed). Just note it. If the operator never ends this new segment, the
        // Finish button stays tappable (see LiveCaptureView) so they can re-issue the recovery.
        if pendingFinish {
            session.statusMessage = "Added to this session — Finish will complete after the new segment is processed too."
        }

        // Pin collection membership now, in capture order (a Box starts a new collection).
        if photo.type == .box {
            currentCollectionKey = photo.groupId
            // Back-fill: on relay transport, docs captured AFTER this box may have arrived first
            // and been pinned to the wrong (previous) collection. Re-assign using capture-seq order.
            backfillCollections()
        }
        if groupCollectionKey[photo.groupId] == nil {
            groupCollectionKey[photo.groupId] = (photo.type == .box) ? photo.groupId : currentCollectionKey
        }

        // A per-item "retry with model" override (if any) re-OCRs this group with the chosen provider/model
        // via a direct API call (no gateway); otherwise use the session's locked config.
        let ov = groupOCROverride[photo.groupId]
        if let stub = Self._recoveryTestOCRStub {
            // $0 recovery driver ONLY (never set in production): stand in for the PAID call and record the
            // start, so W3.cap-r2's dedup can be proven on the real ingest path without buying an OCR.
            // W3.cap-r5 — the optional gate, captured per page at ingest, lets the driver hold THIS page's
            // result (and therefore its segment's `finalizeSegment`) suspended while it delivers a Box.
            Self._recoveryTestOCRStarts.append(key)
            let gate = Self._recoveryTestOCRGate
            let stubTask = Task<OCRResult, Never> { await gate?(); return stub }
            pageTasks[key] = stubTask
            Self._recoveryTestOCRTasks[key] = stubTask   // W3.cap-r3: a handle that survives the removal
        } else {
            pageTasks[key] = Self.ocrTask(
                imageURL: photo.url,
                provider: ov?.provider ?? config.provider,
                model: ov?.model ?? config.model,
                thinkingLevel: ov.map { $0.thinkingLevel } ?? config.thinkingLevel,
                apiKey: ov?.apiKey ?? config.apiKey,
                customPrompt: config.customOCRPrompt.isEmpty ? nil : config.customOCRPrompt,
                imageScale: config.imageScale, gateway: ov == nil ? config.gateway : nil,
                localAgent: ov == nil ? config.localAgent : nil,
                rotationMode: config.rotationMode, standardImageMB: config.standardImageMB,
                visionSettings: config.visionSettings,
                visionTextLLM: ov == nil ? config.visionTextLLM : nil)
        }

        let pageCount = session.groups.first(where: { $0.id == photo.groupId })?.photos.count ?? 1
        upsertStatus(groupId: photo.groupId, type: photo.type, pageCount: pageCount,
                     phase: photo.type == .document ? .ocr : .tagging)

        if photo.type != .document {   // Box/Folder marker → finalize now
            Task { [weak self] in await self?.finalizeSegment(groupId: photo.groupId) }
        }
    }

    /// A page LEFT the session (W3.cap-r3) — the operator deleted it in the Captured pane, or the phone
    /// reclassified it into a new group and the Mac tombstoned the old copy (`X-Replaces`). Cancel that
    /// page's in-flight OCR and forget the page, so a call for a page that no longer exists is dropped
    /// instead of running to completion with its Task and its result stranded in `pageTasks` for the rest of
    /// the session. Nothing else would drop that one entry: `finalizeSegment` only clears the pages of the
    /// segment it just staged, `retryFailed` only the group being re-run, and `clearSessionState` only when
    /// the operator clears everything — so before this, deleting a page mid-OCR leaked both the spend and
    /// the entry.
    ///
    /// What the cancel actually saves, stated honestly, because "stops the paid call" is only sometimes the
    /// whole truth: `NetworkSession` honours cancellation at four points — `RequestLimiter.acquire`, the
    /// `checkCancellation` before the send, the `Task.isCancelled` guard between retry attempts, and the
    /// `URLSession` task itself. A call still QUEUED behind the limiter (the common state in a capture
    /// burst, where pages arrive faster than five concurrent requests drain) or parked in 429 backoff is
    /// never sent at all: the whole charge is saved. A call the provider has already ACCEPTED may well be
    /// billed anyway — closing the socket does not un-bill a generation, which is the same assumption
    /// `NetworkSession`'s no-repeat-after-timeout rule already rests on. There cancelling still frees a
    /// limiter slot for a page that WILL be read, and never costs more than letting it run.
    ///
    /// Deliberately a NO-OP while this segment is being finalized. From `finalizeSegment`'s
    /// `finalizedGroups.insert` until it clears the entry itself, finalize IS this task's consumer: it took a
    /// snapshot of the group before its awaits and is going to read this page's result into the segment's
    /// text. The call is already bought there, so cancelling would discard paid output rather than save
    /// anything — and it cannot strand the entry either, because finalize's only other exits are the B8
    /// clear-generation guards and `clearSessionState` empties `pageTasks` wholesale.
    ///
    /// Dropping the entry retires the started-once guard with it (W3.cap-r3-fu1 made `pageTasks` the only
    /// record of it): this page's OCR is now GONE, so if the same `(groupId, seq)` ever arrives again it has
    /// to be allowed to buy a call. Leaving W3.cap-r2's guard armed over an absent task would spend nothing
    /// and instead file that page as "OCR not started" — a silently text-less archival document, which is the
    /// worse of the two failures. The reclassify path can't reach that trade at all: both callers skip
    /// `rg == groupId`, so the key retired here is never the key just ingested. The mid-finalize carve-out
    /// above keeps the entry, so it keeps the guard too — a re-arrival in that window is de-duplicated rather
    /// than allowed to overwrite the Task finalize is suspended on.
    func photoRemoved(_ photo: CapturedPhoto) {
        guard session.processingMode == .live, !finalizedGroups.contains(photo.groupId) else { return }
        let key = PageKey(photo)
        pageTasks[key]?.cancel()
        pageTasks[key] = nil
    }

    /// A document segment's Mac tag card was resolved (Save/Skip) → finalize it.
    func segmentResolved(groupId: String) {
        guard !stagingManifestBlocked, session.processingMode == .live else { return }
        Task { [weak self] in await self?.finalizeSegment(groupId: groupId) }
    }

    /// Where a group is filed RIGHT NOW — the single reader of collection membership outside finalize
    /// (W3.cap-r4). `groupCollectionKey` is the live map `backfillCollections` corrects; its staged record
    /// is the same value written out, and is the fallback for a group finalized while the map was empty
    /// (see `finalizeSegment`). `currentCollectionKey` only backstops a group that is neither — unreachable
    /// for a staged segment, and the same default a first capture would get.
    private func liveCollectionKey(for groupId: String) -> String {
        groupCollectionKey[groupId]
            ?? staged.first { $0.groupId == groupId }?.collectionKey
            ?? currentCollectionKey
    }

    /// Re-assign collection keys for not-yet-finalized groups (and already-staged segments) using the
    /// phone's capture sequence as the source of truth. Called when a Box arrives out of relay order so
    /// documents that landed before their Box get corrected before (or after) finalize.
    private func backfillCollections() {
        let boxes = session.groups
            .filter { $0.type == .box }
            .sorted { $0.order < $1.order }
        guard !boxes.isEmpty else { return }

        // For a given capture-order, the correct box is the one with the highest order ≤ docOrder.
        func correctBox(forOrder docOrder: Int) -> CaptureGroup? {
            boxes.last { $0.order <= docOrder }
        }

        // Back-fill every group whose staged record hasn't been written yet — the not-yet-finalized ones
        // and, W3.cap-r5, the IN-FLIGHT one. A group is in flight from the moment `finalizeSegment` inserts
        // it into `finalizedGroups` until it appends its `StagedSegment`, and in between it suspends for
        // seconds at the per-page OCR awaits, the LLM tagging call and the off-main file write. Skipping
        // `finalizedGroups` here was the whole defect: for that whole window the group was invisible to this
        // loop (already finalized) AND to the staged loop below (not yet staged), so a Box arriving out of
        // relay order in that window could never re-pin it and the document was filed into the previous
        // collection. Only an already-STAGED group is skipped now — the loop below owns those, records and
        // all. `finalizeSegment` re-reads `groupCollectionKey` after its last await, so a correction made
        // here still lands on the record it is about to write.
        for group in session.groups where group.type != .box {
            guard !staged.contains(where: { $0.groupId == group.id }) else { continue }
            if let box = correctBox(forOrder: group.order) {
                groupCollectionKey[group.id] = box.id
            }
        }

        // Fix already-staged segments whose collectionKey was pinned before their box arrived
        var didFixStaged = false
        for i in staged.indices where staged[i].type != CaptureGroupType.box.rawValue {
            if let box = correctBox(forOrder: staged[i].order), staged[i].collectionKey != box.id {
                staged[i].collectionKey = box.id
                groupCollectionKey[staged[i].groupId] = box.id
                didFixStaged = true
            }
        }
        if didFixStaged { persistManifest() }

        // Keep currentCollectionKey = the highest-seq box (not just the most-recently-arrived one)
        if let latest = boxes.last { currentCollectionKey = latest.id }
    }

    // MARK: - Finalize one segment

    private func finalizeSegment(groupId: String) async {
        guard !stagingManifestBlocked, session.processingMode == .live, let config, let stagingDir,
              !finalizedGroups.contains(groupId),
              let group = session.groups.first(where: { $0.id == groupId }) else { return }
        finalizedGroups.insert(groupId)
        session.lockSettings()   // first finalize locks the session's settings
        // B8: snapshot the clear-generation BEFORE any await. Every await below (box-label OCR, LLM tagging,
        // the off-main file write) suspends for seconds; if Clear runs during any of them, `clearGeneration`
        // advances and each post-await guard bails us out cleanly. No await has happened yet at this point.
        let startedGeneration = clearGeneration

        // W3.cap-r5 — this is the key as it stands BEFORE any await. It is what the write below is handed,
        // but it is NOT what gets recorded: an out-of-order Box can still correct this group while finalize
        // is suspended, so the value that reaches `staged` is re-read after the last await (see the
        // `outcome.collectionKey` assignment). Kept as the fallback for the case where the session was cleared.
        let collectionKey = groupCollectionKey[groupId] ?? (group.type == .box ? group.id : currentCollectionKey)
        setPhase(groupId, .tagging)

        // Await the OCR results for this segment's pages (started on arrival). A per-item "rotate & re-run"
        // override forces this group's output rotation (the re-OCR itself doesn't re-detect it).
        var results: [OCRResult] = []
        var texts: [String] = []
        let rotationOverride = groupOCROverride[groupId]?.rotation
        for photo in group.photos {
            var r = await pageTasks[PageKey(photo)]?.value
                ?? OCRResult(text: nil, classification: nil, errorMessage: "OCR not started", errorCode: nil)
            if let rot = rotationOverride {
                r = OCRResult(text: r.text, classification: r.classification,
                              rotationDegrees: ((rot % 360) + 360) % 360,
                              errorMessage: r.errorMessage, errorCode: r.errorCode)
            }
            results.append(r)
            texts.append(r.text ?? "")
        }
        // B8: the per-page OCR awaits above can suspend for seconds (box-label OCR). If Clear ran in that
        // window the session was reset — bail before touching any (now-cleared) state or making the LLM call.
        guard clearGeneration == startedGeneration else { return }
        groupOCROverride[groupId] = nil   // consumed

        // Tags: Mac subjects skip the LLM; automatic mode calls the LLM; box/folder → color tag.
        let mac = session.macTags[groupId]
        let segment = DocumentSegment(pdfURLs: group.photos.map { $0.url },
                                      isBox: group.type == .box, isFolder: group.type == .folder, texts: texts)
        var tags = await computeTags(group: group, segment: segment, mac: mac, config: config)
        // Phone's in-the-room date wins (Mac override beats the phone value).
        if let y = mac?.year ?? group.year { tags.year = String(y); tags.dateUncertain = false }
        if let m = mac?.month ?? group.month, let mt = GeneratedTags.monthTag(m) {
            tags.month = mt
        }
        // A saved Mac tag card is the operator's explicit Quality decision, including 0/unrated.
        // The phone's Q input is only the default when the card was skipped.
        if let mac { tags.quality = mac.quality }

        // Snapshot Sendable per-page work for the off-main file writes.
        let pages: [PageWork] = group.photos.enumerated().map { (i, p) in
            let quality = mac.flatMap { DocumentTags.qualityTag(for: $0.quality) } ?? p.quality
            return PageWork(sourceURL: p.url, result: results[i], quality: quality)
        }
        let gType = group.type, gOrder = group.order
        let baseTags = tags.allTags
        let doMerge = config.mergeDocuments && gType == .document && pages.count > 1
        let model = config.model, gatewayName = config.gateway?.displayName
        let localAgentDisplayName = config.localAgent?.provenanceDisplayName
        let localAgentModelName = config.localAgent?.provenanceModelName
        let writeJSON = config.enableSegmentJSON && gType == .document
        let jsonTags = tags
        let outputImageFile = config.outputImageFile, pdfImageMB = config.pdfImageMB, exportedImageMB = config.exportedImageMB, textColumns = config.textColumns
        let taggingMode = config.taggingMode
        let stampUnread = config.taggingMode.stampsUnread

        // B8: `computeTags` above may have suspended on an LLM tagging call. Re-check BEFORE writing the
        // output PDF, so a Clear during OCR/tagging bails here and never leaves an orphan PDF in the cleared
        // session's `_processed/`. (The write is the last unavoidable-before-check step; see the guard below.)
        guard clearGeneration == startedGeneration else { return }

        var outcome = await Task.detached(priority: .userInitiated) { () -> StagedSegment in
            Self.writeSegmentFiles(groupId: groupId, type: gType, collectionKey: collectionKey, order: gOrder,
                                   pages: pages, baseTags: baseTags, doMerge: doMerge, model: model,
                                   gatewayName: gatewayName, localAgentDisplayName: localAgentDisplayName,
                                   localAgentModelName: localAgentModelName, stagingDir: stagingDir, writeJSON: writeJSON,
                                   jsonTags: jsonTags, texts: texts,
                                   boxLabelText: gType == .box ? texts.first : nil,
                                   outputImageFile: outputImageFile, pdfImageMB: pdfImageMB,
                                   exportedImageMB: exportedImageMB, textColumns: textColumns,
                                   taggingMode: taggingMode,
                                   stampUnread: stampUnread)
        }.value

        // B8: the off-main write itself can straddle a Clear. If the session was cleared while it ran, do NOT
        // re-add staged/retained state, set a phase, or persist a stale one-entry manifest — the pane must
        // stay empty. Bailing deletes nothing (Recovery Directive): any file just written stays recoverable
        // in `_processed/`; we only decline to re-populate cleared in-memory state.
        guard clearGeneration == startedGeneration else { return }

        // W3.cap-r5 — bind the collection key HERE, not at the pin before the awaits. Every await above
        // suspends for seconds, and a relay Box that arrives out of capture order during one of them re-pins
        // this group through `backfillCollections` (which no longer skips a finalized-but-not-yet-staged
        // group). Re-reading now is both safe and the LAST point a correction can still land: the key is
        // metadata about WHERE the segment gets filed, never an input to the bytes or the paths —
        // `writeSegmentFiles` only carries it into the record it returns — and from here to the assignment
        // below there is no await for a Box to slip through. End-of-session collection grouping reads it off
        // that record (`staged[].collectionKey`); W3.cap-r4 retired the second copy that used to live on
        // `retained[]`, so rotation-review regeneration now re-reads the live map instead of replaying a
        // snapshot of it. Falls back to the pinned value if the map was emptied.
        outcome.collectionKey = groupCollectionKey[groupId] ?? collectionKey

        staged.append(outcome)
        // Retain the write inputs so an end-of-session rotation review can regenerate this segment.
        retained[groupId] = RetainedSegment(
            groupId: groupId, type: gType, order: gOrder,
            pages: pages, baseTags: baseTags, doMerge: doMerge, model: model, gatewayName: gatewayName,
            localAgentDisplayName: localAgentDisplayName, localAgentModelName: localAgentModelName,
            writeJSON: writeJSON, jsonTags: jsonTags, texts: texts,
            boxLabelText: gType == .box ? texts.first : nil,
            outputImageFile: outputImageFile, pdfImageMB: pdfImageMB,
            exportedImageMB: exportedImageMB, textColumns: textColumns,
            taggingMode: taggingMode,
            stampUnread: stampUnread)
        persistManifest()
        for p in group.photos { pageTasks[PageKey(p)] = nil }   // free memory
        labelStagedRecord(groupId, type: gType, outcome: outcome, results: results)
        proceedToFinishIfReady()   // if the operator hit Finish mid-processing, this staged segment may be the last
    }

    /// A1 — the discriminated failure/label taxonomy for ONE freshly-written staged record (labeling ONLY;
    /// the data-safety gate is unchanged). The `outcome` (pdfURLs / pagesComplete) is the record that just
    /// went into `staged`, and finalize/deletion keys off `executePlans`' filedGroupIds + `pagesComplete`,
    /// NEVER off `failedGroupIds`. So splitting the label here — and un-conflating the filed image-only doc
    /// into `.succeededNoText` — cannot change when/what gets deleted; it only fixes what the operator sees
    /// and what bulk-retry re-runs.
    ///
    /// W3.cap-r3-fu6 / fu8 — extracted so there is exactly ONE labeller for all THREE sites that publish a
    /// record's status. `finalizeSegment` calls it on the first write; `applyRotationReviewAndFinalize`
    /// replaces the record WHOLESALE; and `loadStagingManifest` reconstructs the row after a relaunch from
    /// the persisted record + retained page results. The latter two used to leave or manufacture `.staged`
    /// independently, so the record and row could disagree in both directions: a `.noOutput` segment that
    /// regenerated cleanly stayed `.failed` (inviting a paid retry of good output), while a `.staged` segment
    /// that regenerated or resumed with nothing kept a success label over a record finalize silently declined.
    ///
    /// `results` is the per-page OCR, in page order. All three callers have it EXACTLY, not approximately:
    /// `finalizeSegment` passes what it awaited, while regeneration and current-manifest resume pass
    /// `RetainedSegment.pages`' `result`s — the same values, since a rotation edit rebuilds `OCRResult` preserving `text`,
    /// `errorMessage` and `errorCode` (and `PageWork` is Codable, so they survive a manifest resume). Note
    /// this is why the regeneration must NOT reach for `RetainedSegment.texts` instead: `texts` maps a nil
    /// text to `""`, so `anyText` computed from it would conflate "OCR returned nothing" with "OCR returned
    /// an empty string" — the one distinction `.succeededNoText` exists to draw.
    private func labelStagedRecord(_ groupId: String, type: CaptureGroupType,
                                   outcome: StagedSegment, results: [OCRResult]) {
        let producedOutput = !outcome.pdfURLs.isEmpty
        let pagesComplete = outcome.pagesComplete ?? true
        let anyText = results.contains { $0.text != nil }
        let firstError = results.first(where: { $0.errorMessage != nil })
        if !producedOutput {
            // No PDF at all (incl. a true document OCR-empty with no usable PDF). Retryable; sources kept.
            markFailed(groupId, .noOutput, firstError)
        } else if !pagesComplete {
            // Some page produced no PDF → incomplete; finalize won't file it, so it never partially deletes
            // a multi-page segment's sources. Retryable.
            markFailed(groupId, .incompleteOutput, firstError)
        } else if !(outcome.placeholderSources ?? []).isEmpty {
            // W23.h5 — every page produced a PDF, but at least one of them carries the PLACEHOLDER image
            // page instead of the scan. It IS staged and WILL be filed (the bytes and the OCR text are
            // real); what finalize must not do is retire that page's source photo, and that decision is
            // made from `placeholderSources`, not from this label. Ranked above `.succeededNoText`: a
            // missing IMAGE is the more serious of the two, and it's the one that holds a photo back.
            failedGroupIds.remove(groupId)
            setStatusDetail(groupId, kind: nil, error: firstError)
            setPhase(groupId, .succeededPlaceholderImage)
        } else if type == .document && !anyText {
            // Complete image-only PDF (every page produced a PDF, but no OCR text). It IS staged and WILL be
            // filed by executePlans exactly as before — this is a WARNING, not a hard failure. Drop it from
            // failedGroupIds so bulk "Retry failed" stops over-counting a successfully-filed doc.
            failedGroupIds.remove(groupId)
            setStatusDetail(groupId, kind: nil, error: firstError)
            setPhase(groupId, .succeededNoText)
        } else {
            failedGroupIds.remove(groupId)
            setStatusDetail(groupId, kind: nil, error: nil)
            setPhase(groupId, .staged)
        }
    }

    /// Compute the segment's subject/color tags (may hit the LLM). Date/quality are layered on later.
    private func computeTags(group: CaptureGroup, segment: DocumentSegment,
                             mac: MacSegmentTags?, config: SessionProcessingConfig) async -> GeneratedTags {
        if group.type != .document {
            // Box/Folder → color tag (TagGenerator returns Box/Red or Folder/Purple with no LLM call).
            return await TagGenerator().generateTags(for: segment, nearbySegments: [], provider: config.textProvider,
                                                     model: config.textModel, thinkingLevel: nil, apiKey: config.textAPIKey,
                                                     vocabulary: [], gatewayConfig: config.textGateway, localAgent: config.textLocalAgent)
        }
        if let subs = mac?.subjects, !subs.isEmpty { return GeneratedTags(subjectTags: subs) }   // Mac-tagged → no LLM
        if config.taggingMode == .automatic {
            return await TagGenerator().generateTags(for: segment, nearbySegments: [], provider: config.textProvider,
                                                     model: config.textModel, thinkingLevel: nil, apiKey: config.textAPIKey,
                                                     vocabulary: config.tagVocabulary, gatewayConfig: config.textGateway, localAgent: config.textLocalAgent)
        }
        return GeneratedTags()   // manual mode, no Mac subjects → date/quality only
    }

    // MARK: - Off-main file writing (nonisolated static; only touches the filesystem)

    private struct PageWork: Sendable, Codable {
        let sourceURL: URL
        let result: OCRResult
        let quality: String?
    }

    /// All inputs to `writeSegmentFiles` for one finalized segment, retained so the end-of-session
    /// rotation review can regenerate it with corrected page rotation. Persisted in the staging
    /// manifest so the review still works after a crash/relaunch resume.
    ///
    /// W3.cap-r4 — deliberately NO `collectionKey`. Which collection a segment belongs to is not a write
    /// input at all (`writeSegmentFiles` only carries it into the record it returns); it is *live* state that
    /// `backfillCollections` corrects whenever a Box arrives out of relay order. Keeping a second copy here
    /// was the defect: the correction reached `staged[]` and `groupCollectionKey` but never this record, and
    /// the rotation-review regeneration then wrote the stale key straight back over the corrected one —
    /// silently filing the document into the previous collection. There is now exactly one reader,
    /// `liveCollectionKey(for:)`, so there is nothing left to drift.
    private struct RetainedSegment: Sendable, Codable {
        let groupId: String
        let type: CaptureGroupType
        let order: Int
        var pages: [PageWork]        // var: page rotation is updated before regeneration
        let baseTags: [String]
        let doMerge: Bool
        let model: LLMModel
        let gatewayName: String?
        let localAgentDisplayName: String?
        let localAgentModelName: String?
        let writeJSON: Bool
        let jsonTags: GeneratedTags
        let texts: [String]
        let boxLabelText: String?
        let outputImageFile: Bool
        let pdfImageMB: Double
        let exportedImageMB: Double
        let textColumns: Int
        /// Exact policy captured at staging time. Rotation regeneration must use this rather than whatever
        /// the operator selects in Settings after the segment was staged.
        let taggingMode: TaggingMode
        let stampUnread: Bool

        // Memberwise init (matches the synthesized one the callers already use).
        init(groupId: String, type: CaptureGroupType, order: Int,
             pages: [PageWork], baseTags: [String], doMerge: Bool, model: LLMModel, gatewayName: String?,
             localAgentDisplayName: String?, localAgentModelName: String?,
             writeJSON: Bool, jsonTags: GeneratedTags, texts: [String], boxLabelText: String?,
             outputImageFile: Bool, pdfImageMB: Double, exportedImageMB: Double, textColumns: Int,
             taggingMode: TaggingMode,
             stampUnread: Bool) {
            self.groupId = groupId; self.type = type; self.order = order
            self.pages = pages; self.baseTags = baseTags; self.doMerge = doMerge; self.model = model
            self.gatewayName = gatewayName
            self.localAgentDisplayName = localAgentDisplayName; self.localAgentModelName = localAgentModelName
            self.writeJSON = writeJSON; self.jsonTags = jsonTags
            self.texts = texts; self.boxLabelText = boxLabelText; self.outputImageFile = outputImageFile
            self.pdfImageMB = pdfImageMB; self.exportedImageMB = exportedImageMB; self.textColumns = textColumns
            self.taggingMode = taggingMode
            self.stampUnread = stampUnread
        }
    }

    nonisolated private static func writeSegmentFiles(
        groupId: String, type: CaptureGroupType, collectionKey: String, order: Int,
        pages: [PageWork], baseTags: [String], doMerge: Bool, model: LLMModel, gatewayName: String?,
        localAgentDisplayName: String?, localAgentModelName: String?,
        stagingDir: URL, writeJSON: Bool, jsonTags: GeneratedTags, texts: [String], boxLabelText: String?,
        outputImageFile: Bool, pdfImageMB: Double, exportedImageMB: Double, textColumns: Int,
        taggingMode: TaggingMode,
        stampUnread: Bool
    ) -> StagedSegment {
        let fm = FileManager.default
        let pdfGen = PDFGenerator()
        var pdfURLs: [URL] = []
        var imageURLs: [URL] = []
        var placeholderSources: [URL] = []
        var untaggedOutputs: [URL] = []
        // W3.cap-r1 — the app's OWN colour for this segment (Red = box, Purple = folder, nil = document),
        // passed to every tag write below so a *subject* string is never mistaken for one. See
        // `tagStagedArtifact`.
        let appColor = jsonTags.colorTag

        for page in pages {
            let base = page.sourceURL.deletingPathExtension().lastPathComponent
            let stagedPDF = stagingDir.appendingPathComponent(base + ".pdf")
            let imagePage = try? pdfGen.generate(imageURL: page.sourceURL, result: page.result, model: model,
                                                 outputURL: stagedPDF, originalFileName: page.sourceURL.lastPathComponent,
                                                 gatewayDisplayName: gatewayName,
                                                 localAgentDisplayName: localAgentDisplayName,
                                                 localAgentModelName: localAgentModelName,
                                                 pdfImageMB: pdfImageMB, textColumns: textColumns)
            // Only record a PDF we can PROVE is on disk. `generate` is `try?`, so a swallowed failure would
            // otherwise append a phantom URL — and finalize keys "safe to delete the source photo" off the
            // PDF actually reaching the destination. A phantom would let a never-written output masquerade as
            // filed, and the irreplaceable source would be deleted (the original data-loss bug). So skip a
            // page whose PDF didn't write: its source stays in the backup folder and the segment is surfaced
            // as failed (retryable) because it produced no output.
            guard fm.fileExists(atPath: stagedPDF.path) else { continue }
            // W23.h5 — the PDF exists, but does it hold the SCAN? `.placeholder` means it doesn't, so this
            // page's source photo is the only copy of the image and finalize must keep it. A nil outcome
            // (generate threw yet still left a file on disk) is UNKNOWN, and unknown resolves the safe way:
            // withhold the deletion. Erring here keeps a photo we could have deleted; erring the other way
            // destroys an irreplaceable page.
            if imagePage != .embedded { placeholderSources.append(page.sourceURL) }
            switch taggingMode {
            case .none:
                // No tagging means no Finder metadata write whatsoever, including the phone boundary.
                break
            default:
                let tagList = tagsByApplyingPhoneQuality(baseTags, quality: page.quality)
                if !tagStagedArtifact(tagList, at: stagedPDF, appColor: appColor, stampUnread: stampUnread) {
                    untaggedOutputs.append(stagedPDF)
                }
            }
            pdfURLs.append(stagedPDF)

            // Two-file output: a .jpg next to its PDF, sized to the exported-image target + identical tags.
            if outputImageFile {
                let stagedImg = stagingDir.appendingPathComponent(base + ".jpg")
                if ImageEncoding.writeSizedJPEG(from: page.sourceURL, to: stagedImg, targetMB: exportedImageMB, rotationDegrees: page.result.rotationDegrees) {
                    switch taggingMode {
                    case .none:
                        break
                    default:
                        let tagList = tagsByApplyingPhoneQuality(baseTags, quality: page.quality)
                        if !tagStagedArtifact(tagList, at: stagedImg, appColor: appColor, stampUnread: stampUnread) {
                            untaggedOutputs.append(stagedImg)
                        }
                    }
                    imageURLs.append(stagedImg)
                }
            }
        }

        // Did EVERY source page produce a PDF on disk? Computed BEFORE merge collapses `pdfURLs`. If a page's
        // generation was silently dropped above, the segment is incomplete — finalize will keep ALL its
        // sources (never delete a page whose output doesn't exist) and surface it as failed for retry.
        let pagesComplete = (pdfURLs.count == pages.count)

        // Segment JSON (documents only), written from source page names before any merge.
        var jsonURL: URL? = nil
        if writeJSON, type == .document, let firstPDF = pdfURLs.first {
            let jurl = firstPDF.deletingPathExtension().appendingPathExtension("json")
            writeSegmentJSON(pageURLs: pages.map { $0.sourceURL }, texts: texts, tags: jsonTags, to: jurl)
            if fm.fileExists(atPath: jurl.path) { jsonURL = jurl }   // only record it if it actually wrote
        }

        if doMerge, pdfURLs.count > 1 {
            let base = pdfURLs[0].deletingPathExtension().lastPathComponent
            let mergedURL = stagingDir.appendingPathComponent(base + "_merged.pdf")
            do {
                try pdfGen.mergeDocumentPDFs(sourcePDFs: pdfURLs, outputURL: mergedURL)
                // The per-page PDFs are about to be deleted, so a tag failure recorded against one of them is
                // moot — the merged file replaces them and carries its own verdict. Drop them BEFORE tagging
                // the merged output so the warning only ever names artifacts that still exist.
                let constituents = Set(pdfURLs)
                untaggedOutputs.removeAll { constituents.contains($0) }
                switch taggingMode {
                case .none:
                    break
                default:
                    // Q3 is a page-level override, so a later page can outrank the group's first-page
                    // default on the merged artifact. A saved Mac card has already normalized every page
                    // to the same Q value, so this also preserves its decision.
                    let mergedQuality = pages.first(where: { $0.quality == "Q3" })?.quality ?? pages.first?.quality
                    let tagList = tagsByApplyingPhoneQuality(baseTags, quality: mergedQuality)
                    if !tagStagedArtifact(tagList, at: mergedURL, appColor: appColor, stampUnread: stampUnread) {
                        untaggedOutputs.append(mergedURL)
                    }
                }
                for u in pdfURLs { try? fm.removeItem(at: u) }
                pdfURLs = [mergedURL]
            } catch { /* keep the individual PDFs if merge fails */ }
        }

        return StagedSegment(groupId: groupId, type: type.rawValue, collectionKey: collectionKey, order: order,
                             pdfURLs: pdfURLs, imageURLs: imageURLs, jsonURL: jsonURL, boxLabelText: boxLabelText,
                             pagesComplete: pagesComplete, placeholderSources: placeholderSources,
                             untaggedOutputs: untaggedOutputs)
    }

    /// Phone quality is a user rating intent, not a source Finder tag. In enabled tagging modes, apply
    /// its canonical Q token once before every staged-PDF/image/merge write. The Mac-only `Q0` clear
    /// marker removes a generated/base rating here instead of reaching copy-source output. `TaggingMode.none`
    /// never calls this helper. Existing non-rating `baseTags` are otherwise untouched.
    nonisolated private static func tagsByApplyingPhoneQuality(_ baseTags: [String], quality raw: String?) -> [String] {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces) else {
            return baseTags
        }
        var tags = baseTags
        if raw == "Q0" {
            tags.removeAll { DocumentTags.isRatingToken($0) }
            return tags
        }
        guard ["Q1", "Q2", "Q3"].contains(raw) else { return tags }
        tags.removeAll { DocumentTags.isRatingToken($0) }
        tags.append(raw)
        return tags
    }

    /// W3.cap-r1 — apply this segment's Finder tags to ONE staged artifact and report whether the write
    /// actually landed. Two defects lived on the same three lines, so both are fixed here, together:
    ///
    /// 1. **The colour was inferred from the text.** Passing a raw `[String]` made `applyTags` *detect*
    ///    "Red"/"Purple" anywhere in the array, so a document whose subject is literally "Red" (the Red
    ///    Scare, the Red Cross) was promoted to a Finder red label and lost "Red" as a searchable subject.
    ///    The app assigns exactly one colour — Red = box, Purple = folder, none = document — so that colour
    ///    is passed explicitly and `colorIsAuthoritative` is fixed `true` here: this seam never guesses.
    /// 2. **The write result was discarded.** `_ = try? applyTags(…)` swallowed every xattr / coordination /
    ///    identity / permission failure, and the segment was then staged and finalized as though tagged.
    ///    The caller now records the artifact so `finalize` can say so.
    ///
    /// Returns `true` when the write succeeded (including a legitimate no-op — tags already correct, or
    /// copy-source mode with nothing to write); `false` only when the primitive threw.
    nonisolated private static func tagStagedArtifact(
        _ tags: [String], at url: URL, appColor: String?, stampUnread: Bool
    ) -> Bool {
        do {
            _ = try MacOSTagger.applyTags(tags, to: url, appColor: appColor,
                                          colorIsAuthoritative: true, stampUnread: stampUnread)
            return true
        } catch {
            NSLog("LiveCapture: Finder-tag write FAILED for \(url.lastPathComponent) — \(error)")
            return false
        }
    }

    /// Writes the metadata sidecar (OCR body + fields) via the shared `SegmentJSONBuilder`. This path
    /// is documents-only, so it passes no box/folder label format override.
    nonisolated private static func writeSegmentJSON(pageURLs: [URL], texts: [String], tags: GeneratedTags, to jsonURL: URL) {
        guard let data = SegmentJSONBuilder.buildData(fileURLs: pageURLs, texts: texts, tags: tags) else { return }
        try? data.write(to: jsonURL, options: .atomic)
    }

    nonisolated private static func ocrTask(
        imageURL: URL, provider: LLMProvider, model: LLMModel, thinkingLevel: ThinkingLevel?,
        apiKey: String, customPrompt: String?, imageScale: Double, gateway: GatewayConfig?,
        localAgent: LocalAgentConfig?, rotationMode: RotationMode, standardImageMB: Double,
        visionSettings: VisionOCRSettings, visionTextLLM: LLMTextConfiguration?
    ) -> Task<OCRResult, Never> {
        Task.detached(priority: .userInitiated) {
            let ocrResult = await OCRProcessor.performOCRCall(
                imageURL: imageURL, provider: provider, model: model, thinkingLevel: thinkingLevel,
                apiKey: apiKey, previousText: nil, previousImageURL: nil,
                customPrompt: customPrompt, imageScale: imageScale, gatewayConfig: gateway,
                localAgent: localAgent, rotationMode: rotationMode, standardImageMB: standardImageMB,
                visionSettings: visionSettings)
            return await OCRProcessor.applyingVisionTextClassification(
                to: ocrResult, previousText: nil, customPrompt: customPrompt,
                configuration: provider == .appleVision ? visionTextLLM : nil)
        }
    }

    // MARK: - Manifest + status

    /// On-disk staging manifest: staged segments plus the per-segment write inputs needed to
    /// regenerate a segment during the end-of-session rotation review after a crash/relaunch.
    private struct StagingManifest: Codable {
        static let currentSchemaVersion = 1
        let schemaVersion: Int
        var staged: [StagedSegment]
        var retained: [RetainedSegment]
        let fingerprint: String

        init(staged: [StagedSegment], retained: [RetainedSegment]) {
            self.schemaVersion = Self.currentSchemaVersion
            self.staged = staged
            self.retained = retained
            // An encoding failure must leave a record that fails closed on reload, never a valid digest for
            // placeholder bytes. The outer persist then also declines to write if those same values cannot
            // encode, but this keeps the integrity rule total.
            self.fingerprint = Self.fingerprint(schemaVersion: schemaVersion, staged: staged, retained: retained) ?? ""
        }

        var hasValidFingerprint: Bool {
            guard let expected = Self.fingerprint(schemaVersion: schemaVersion, staged: staged, retained: retained) else {
                return false
            }
            return fingerprint == expected
        }

        private struct FingerprintPayload: Encodable {
            let schemaVersion: Int
            let staged: [StagedSegment]
            let retained: [RetainedSegment]
        }

        private static func fingerprint(
            schemaVersion: Int, staged: [StagedSegment], retained: [RetainedSegment]
        ) -> String? {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let payload = FingerprintPayload(schemaVersion: schemaVersion, staged: staged, retained: retained)
            guard let data = try? encoder.encode(payload) else { return nil }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    private func persistManifest() {
        guard !stagingManifestBlocked, let stagingDir else { return }
        let url = stagingDir.appendingPathComponent("staging-manifest.json")
        // Dictionaries do not promise a stable iteration order. The fingerprint identifies durable data,
        // not whichever order retained records happened to be visited in this process.
        let retainedRecords = retained.values.sorted { $0.groupId < $1.groupId }
        let manifest = StagingManifest(staged: staged, retained: retainedRecords)
        if let data = try? JSONEncoder().encode(manifest) { try? data.write(to: url, options: .atomic) }
    }

    private func upsertStatus(groupId: String, type: CaptureGroupType, pageCount: Int, phase: SegmentStatus.Phase) {
        if let idx = statuses.firstIndex(where: { $0.id == groupId }) {
            statuses[idx].pageCount = pageCount
            if statuses[idx].phase != .staged { statuses[idx].phase = phase }
        } else {
            statuses.append(SegmentStatus(id: groupId, index: statuses.count + 1, type: type,
                                          pageCount: pageCount, phase: phase))
        }
    }

    private func setPhase(_ groupId: String, _ phase: SegmentStatus.Phase) {
        if let idx = statuses.firstIndex(where: { $0.id == groupId }) { statuses[idx].phase = phase }
    }

    /// Mark a segment failed with a discriminated reason (labeling only — see finalizeSegment). Adds it to
    /// `failedGroupIds` (retry set) and records the reason for the shared row's failure line.
    private func markFailed(_ groupId: String, _ kind: FailureKind, _ error: OCRResult?) {
        failedGroupIds.insert(groupId)
        setStatusDetail(groupId, kind: kind, error: error)
        setPhase(groupId, .failed)
    }

    /// Record a segment's failure/label detail (reason + provider error) for the UI.
    private func setStatusDetail(_ groupId: String, kind: FailureKind?, error: OCRResult?) {
        guard let idx = statuses.firstIndex(where: { $0.id == groupId }) else { return }
        statuses[idx].failureKind = kind
        statuses[idx].errorMessage = error?.errorMessage
        statuses[idx].errorCode = error?.errorCode
    }

    // MARK: - End-of-session finalization (Phase 3/4)

    /// One collection awaiting the operator's name/append confirmation.
    struct CollectionDraft: Identifiable {
        let id: String                 // collectionKey
        var finalName: String          // editable candidate name
        var existingFolders: [URL]     // all existing collection folders (for the picker)
        var suggestedFolders: [URL]    // fuzzy top matches (shown first)
        var chosenExisting: URL?       // nil → create a new folder; else append to this one
        var segmentCount: Int
        var photoCount: Int
    }

    // MARK: - End-of-session rotation review (opt-in)

    /// "Finish session" button entry point. Two jobs before the review can start:
    ///  1) RECOVER any document that never got a Mac tag card — one the operator ended but whose
    ///     completion signal never landed, OR never tapped End segment on — by force-completing all still-
    ///     open doc groups so their cards surface now. This replaces the removed phone "Finish" fallback.
    ///  2) WAIT for in-flight processing: if any segment is still OCR'ing/tagging (or a tag card is still
    ///     pending), don't proceed yet — otherwise those segments are missing from the rotation review.
    /// Once everything is staged, `proceedToFinishIfReady` runs `finishSession`.
    func requestFinish() {
        guard !stagingManifestBlocked, !showFinalizeSheet, !showRotationReview, !isFinalizing else { return }   // a finish is already in progress
        guard session.completeAllOpenDocGroups() else {
            // A prior Finish may already have armed the watchdog. Cancel it too; otherwise it could later
            // advance after this re-tap rolled a newly-open group's undurable completion back.
            pendingFinish = false
            session.statusMessage = "Could not save session completion — check the backup folder and try Finish again."
            return
        }
        let wasPending = pendingFinish
        pendingFinish = true
        if !wasPending { startFinishWatchdog() }   // one watchdog per pending-finish episode
        proceedToFinishIfReady()
    }

    /// While a Finish is pending, re-evaluate periodically so it auto-advances even when nothing else
    /// re-triggers it — in particular when a phone that was still sending goes silent and its heartbeat
    /// lapses to stale (`phonePendingActive` flips false at 20s) with no further event to notice it.
    private func startFinishWatchdog() {
        Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, self.pendingFinish else { return }
                self.proceedToFinishIfReady()
            }
        }
    }

    /// The operator's escape from a pending Finish: un-arm the WAIT that `requestFinish` armed, so the
    /// session drops back to ordinary capture instead of sitting on a hold with no way out.
    ///
    /// ⚠️ `W3.cap-r3-fu9-fu1` — **until this item, this method had no caller in the shipped UI at all.** It
    /// existed and did the right thing, but the only thing that called it was `ManifestPersistenceTestDriver`,
    /// which is why `proceedToFinishIfReady`'s comment describing it as "the operator's escape" was false
    /// (an adversarial pass on `W3.cap-r3-fu9` caught the claim). The actual escape was **Clear**, which
    /// Trashes every source photo of the session — a wildly disproportionate price for "I pressed Finish too
    /// early". Re-tapping Finish is not one either: `requestFinish` just re-arms. `LiveCaptureView`'s
    /// "Cancel finish" button, in `pendingFinishRow`, is now the caller.
    ///
    /// ⚠️ It does NOT cover all four holds, and the view says which — a finish held by an outstanding Mac
    /// tag card or by a live per-item sheet is held *by a modal over the panel the button lives in*, so the
    /// button is unreachable there and dismissing the sheet is itself the exit. This serves the in-flight-OCR
    /// and phone-drain holds. Both of those were previously exit-less, which is the gap that mattered: they
    /// are the two that can last indefinitely with nothing on screen to resolve.
    ///
    /// WHAT IT DELIBERATELY DOES **NOT** DO:
    ///  • **It does not roll back `requestFinish`'s `completeAllOpenDocGroups()`.** That force-completion is a
    ///    durable RECOVERY — it surfaces the Mac tag card for a doc group the operator never ended — and it
    ///    is not part of the wait. There is also no supported way to undo it: `completeAllOpenDocGroups`
    ///    rolls a completion back only when its own `writeManifest()` FAILED, i.e. only one that never
    ///    reached disk. Cancel un-arms the wait; it does not rewind the session.
    ///  • **It cancels no OCR, drops no `staged`/`retained`, and touches no file.** Nothing already paid for
    ///    is discarded and nothing on disk moves. That is the whole difference from Clear, and the reason
    ///    this needs no `isFinalizing`-style refusal: there is no write it can interrupt.
    ///  • **It does not tear down `startFinishWatchdog`'s sleeping Task.** The watchdog is `guard
    ///    pendingFinish` and returns at its next 5 s wake. A re-tap of Finish inside that window starts a
    ///    SECOND poller (`requestFinish` sees `wasPending == false`), which is harmless: every tick runs on
    ///    the MainActor through the idempotent, guarded `proceedToFinishIfReady`, so the loser of a tick
    ///    returns having done nothing, and each stale loop exits the first wake it sees `pendingFinish`
    ///    false. Pre-existing and unchanged in kind — `clearSessionState` has always cleared `pendingFinish`
    ///    behind the watchdog's back the same way.
    ///
    /// `guard pendingFinish` so a call with nothing armed cannot overwrite the status line with a message
    /// about something that was not happening. The view renders the button inside that same predicate, so
    /// this is the `W3.cap-r3-fu11` shape: the view decides what the operator is OFFERED, the model decides
    /// what actually happens.
    ///
    /// ⚠️ THE GUARD DOES NOT MAKE THE STATUS WRITE SAFE IN GENERAL, and an earlier draft of this comment
    /// implied it did. `statusMessage` is one shared line with many writers, and a cancel while a finish IS
    /// armed can still overwrite one that mattered — reachably, the late-page notice ("A late page arrived
    /// for an already-finished document — kept in the Backup Folder, not this collection"), which can land
    /// while the finish waits on another group's OCR. Kept anyway, because that line is inherently transient:
    /// every arriving photo already overwrites it with "Received N photos", so a cancel is not a new class of
    /// loss — and an explicit operator action deserves explicit feedback. What the guard buys is narrower and
    /// worth having: a cancel that does NOTHING says nothing.
    func cancelPendingFinish() {
        guard pendingFinish else { return }
        pendingFinish = false
        session.statusMessage =
            "Finish cancelled — the session is still open. Tap Finish session again when you're ready."
    }

    /// The phone's un-sent count changed (a `POST /phone/status` heartbeat). Re-evaluate a pending Finish
    /// so it advances the moment the phone has drained (and processing is done).
    func phoneStatusChanged() { guard !stagingManifestBlocked else { return }; proceedToFinishIfReady() }

    /// Advance a pending Finish once no tag card is outstanding and nothing is still being processed.
    /// Called after each segment stages and whenever a card is resolved, so a Finish requested mid-run
    /// waits for processing to complete instead of dropping unstaged segments from the review.
    private func proceedToFinishIfReady() {
        guard !stagingManifestBlocked, pendingFinish else { return }
        // Only count segments that still EXIST — a status left at .ocr/.tagging for a group whose photos
        // were deleted (thumbnail X) or reclassified away (X-Replaces) can never resolve (no group → no tag
        // card, no finalizeSegment), so it must not block the finish forever. Finalized groups are .staged/.failed.
        //
        // W3.cap-r3-fu12 — this predicate IS `processingCount`, and reads it rather than restating it. It used
        // to be spelled out twice: here, and unfiltered in the property the UI shows, so the panel could name
        // a page the finish had already stopped waiting for. One definition, so the wait and the message
        // describing it cannot come apart again.
        let stillProcessing = processingCount > 0
        // Also wait while a FRESH phone heartbeat says it still has photos to send, so a segment whose pages
        // are all still in flight isn't omitted. A stale heartbeat (phone disconnected) does NOT block — the
        // Finish button stays tappable as the escape.
        // W3.cap-r3-fu9 — and wait while one of the Processing list's PER-ITEM sheets is up. Same class as
        // the `pendingTagGroup` term beside it: a modal the operator has open, which the finish must not
        // walk into. The difference is that this one is not the finish flow's own, so raising the rotation
        // review here would put two concurrent `.sheet` presentations on one view — see `modelChoiceTarget`
        // for the three things SwiftUI might then do and why none of them is acceptable in a money path.
        // Refusing here rather than in `finishSession` is load-bearing: `pendingFinish` is cleared on the
        // line below, so a refusal one level in would DISCARD the finish (nothing re-arms it) instead of
        // holding it. Held, this is self-healing on a timer — `startFinishWatchdog` re-evaluates every 5 s and
        // `perItemSheetDidChange` re-evaluates once its grace expires. The operator ALSO has an explicit way
        // out — `cancelPendingFinish()`, wired to the "Cancel finish" button since `W3.cap-r3-fu9-fu1`. ⚠️ It
        // is not what makes this hold safe, and an earlier draft of this comment leaned on it as if it were:
        // when that was written the method had no caller in the shipped UI at all (an adversarial pass caught
        // the claim), so the only way out was Clear, which Trashes the session's sources. The self-healing
        // timer above is the argument; the button is the operator's convenience on top of it.
        guard session.pendingTagGroup == nil, !stillProcessing, !session.phonePendingActive,
              !perItemSheetUp else { return }
        pendingFinish = false
        finishSession()
    }

    /// Finish-session entry point. If "Review rotation" is on, present a dedicated rotation-review
    /// pass over every captured page first; otherwise go straight to collection naming. "Review
    /// rotation" is read LIVE (not from the locked session config): it's a Finish-time choice, so
    /// enabling it after capture started still applies. Pages seed from each page's detected rotation
    /// (0 if detection was off), and the operator can correct any of them.
    func finishSession() {
        guard !stagingManifestBlocked, !staged.isEmpty else { return }
        let wantReview = UserDefaults.standard.bool(forKey: DefaultsKeys.reviewRotation)
        guard wantReview else { beginFinalize(); return }
        var pages: [RotationReviewPage] = []
        for seg in retained.values {
            for (i, p) in seg.pages.enumerated() {
                pages.append(RotationReviewPage(groupId: seg.groupId, pageIndex: i, order: seg.order,
                                                sourceURL: p.sourceURL,
                                                rotationDegrees: p.result.rotationDegrees))
            }
        }
        pages.sort { ($0.order, $0.pageIndex) < ($1.order, $1.pageIndex) }
        guard !pages.isEmpty else { beginFinalize(); return }
        rotationReviewPages = pages
        showRotationReview = true
    }

    /// Dismiss the rotation review without finalizing (back to capture).
    func cancelRotationReview() {
        showRotationReview = false
        rotationReviewPages = []
    }

    /// Apply the reviewed rotations: regenerate each changed segment's staged PDF/JPG, then proceed
    /// to collection naming. Unchanged pages are left untouched.
    func applyRotationReviewAndFinalize() {
        guard !stagingManifestBlocked else { return }
        showRotationReview = false
        var changedGroups: Set<String> = []
        for page in rotationReviewPages {
            guard var seg = retained[page.groupId], page.pageIndex < seg.pages.count else { continue }
            let old = seg.pages[page.pageIndex].result.rotationDegrees
            let new = ((page.rotationDegrees % 360) + 360) % 360
            guard new != old else { continue }
            let pw = seg.pages[page.pageIndex]
            // `with` rather than a hand-retyped five-field init — it is the shared "change only the rotation,
            // preserve text/errorMessage/errorCode" seam, and it exists because a re-type here is exactly how
            // `errorCode` was silently dropped once before (W9.1). It matters more now that `labelStagedRecord`
            // re-reads `text`/`errorMessage` off these results below.
            seg.pages[page.pageIndex] = PageWork(
                sourceURL: pw.sourceURL,
                result: pw.result.with(classification: pw.result.classification, rotationDegrees: new),
                quality: pw.quality)
            retained[page.groupId] = seg
            changedGroups.insert(page.groupId)
        }
        rotationReviewPages = []
        // Only regenerate segments whose source photos ALL still exist on disk. Regenerating from a
        // missing source (e.g. the operator hit "Clear" before Finish, deleting the originals) would
        // overwrite good staged output with an image-less/broken file — so keep the existing output.
        let fm = FileManager.default
        let segsToRegen = changedGroups
            .compactMap { retained[$0] }
            .filter { seg in seg.pages.allSatisfy { fm.fileExists(atPath: $0.sourceURL.path) } }
        guard !segsToRegen.isEmpty, let stagingDir else { beginFinalize(); return }
        // W3.cap-r4 — the collection is read live, never replayed from the retained record. The value that
        // COUNTS is re-read after the detached write, on the way into `staged` (below) — the same
        // last-possible-moment discipline `finalizeSegment` uses, because that write suspends and an
        // out-of-order Box can re-pin a segment while it runs. This snapshot only keeps the record the write
        // returns from carrying a placeholder in the meantime; it cannot reach `staged` or disk, and the
        // `??` branch is unreachable (the map is built from this very array).
        let regenKeys: [String: String] = Dictionary(
            uniqueKeysWithValues: segsToRegen.map { ($0.groupId, liveCollectionKey(for: $0.groupId)) })
        // W3.cap-r3-fu6 — the write INPUTS, keyed by group, so the label below is re-derived from exactly
        // what the regeneration was handed rather than from `retained` re-read after the suspension. Same
        // last-possible-moment discipline as `regenKeys`, inverted on purpose: the collection is live state
        // and must be re-read late, whereas the OCR is an input to these very bytes and must NOT drift from
        // them. (`retained[gid]` happens to be identical today — nothing on this path mutates it while the
        // detached write runs — but that is a property of the surroundings, not of this line.)
        let regenInputs: [String: RetainedSegment] = Dictionary(
            uniqueKeysWithValues: segsToRegen.map { ($0.groupId, $0) })
        isFinalizing = true
        Task { [weak self] in
            let regenerated: [StagedSegment] = await Task.detached { () -> [StagedSegment] in
                segsToRegen.map { seg in
                    Self.writeSegmentFiles(groupId: seg.groupId, type: seg.type,
                                           collectionKey: regenKeys[seg.groupId] ?? "__unfiled__",
                                           order: seg.order, pages: seg.pages, baseTags: seg.baseTags,
                                           doMerge: seg.doMerge, model: seg.model, gatewayName: seg.gatewayName,
                                           localAgentDisplayName: seg.localAgentDisplayName,
                                           localAgentModelName: seg.localAgentModelName,
                                           stagingDir: stagingDir, writeJSON: seg.writeJSON, jsonTags: seg.jsonTags,
                                           texts: seg.texts, boxLabelText: seg.boxLabelText,
                                           outputImageFile: seg.outputImageFile, pdfImageMB: seg.pdfImageMB,
                                           exportedImageMB: seg.exportedImageMB, textColumns: seg.textColumns,
                                           taggingMode: seg.taggingMode,
                                           stampUnread: seg.stampUnread)
                }
            }.value
            guard let self else { return }
            for outcome in regenerated {
                guard let idx = self.staged.firstIndex(where: { $0.groupId == outcome.groupId }) else { continue }
                // W3.cap-r4 — regeneration replaces the staged RECORD, so it must not carry a stale
                // collection with it: rotation is the only thing this pass is allowed to change. Re-read
                // rather than keep `outcome.collectionKey`, which was fixed before the write above suspended.
                var fresh = outcome
                fresh.collectionKey = self.liveCollectionKey(for: outcome.groupId)
                self.staged[idx] = fresh
                // W3.cap-r3-fu6 — the record is new, so its LABEL has to be re-derived too. Replacing the
                // record and keeping the old label let the two disagree in both directions (see
                // `labelStagedRecord`). `regenInputs` is non-nil for every element of `regenerated` (both are
                // built from `segsToRegen`), so the `if let` is a total function written defensively rather
                // than a branch with a second behaviour.
                //
                // ⚠️ Inside the `guard let idx` on purpose, and that placement is load-bearing rather than
                // tidy. This is the FIRST site that can `markFailed` a group outside `finalizeSegment`, and
                // `markFailed` INSERTS into `failedGroupIds` — so it has to hold HERE that the group is still
                // in `finalizedGroups`, or this would break the `failedGroupIds ⊆ finalizedGroups` subset
                // `W3.cap-r3-fu5` made structural (and which `retryFailed`'s cancel-loop latency argument
                // rests on in turn). It does, because every exit from `finalizedGroups` also drops the group
                // from `staged`. Since `W3.cap-r3-fu7`, TWO of the three cannot even be entered while this loop
                // is pending: `retryFailed` now refuses while `isFinalizing`, and `finalize` already did
                // (`guard config != nil, let stagingDir, !isFinalizing`). Since `W3.cap-r3-fu11` the THIRD
                // refuses too — `clearSessionState` is `private` behind `clearSession()`, which carries the
                // same guard — so all three entrants are now closed by refusal and not one of them can be
                // entered while this loop is pending. The enumeration below is kept WHOLE anyway, because it
                // is the synchronicity and not the refusals that makes the argument sound:
                // `retryFailed` releases then `staged.removeAll`, `clearSessionState` does
                // `staged.removeAll()` then `releaseAllFinalizedGroups`, and `finalize` drops the filed groups
                // from `staged` a line before releasing them — each pair synchronous on the MainActor with no
                // await between, so this loop cannot resume inside the gap. Being staged therefore IMPLIES
                // being finalized, and the guard is what buys it. The reverse window (finalized but not yet
                // staged, between `finalizeSegment`'s insert and its append) is the harmless direction. Move
                // this call outside the guard and the subset stops being sound. The other reason for the
                // placement is the plain one: if the staged record is gone, this pass wrote nothing that
                // needs describing.
                if let input = regenInputs[outcome.groupId] {
                    self.labelStagedRecord(outcome.groupId, type: input.type, outcome: fresh,
                                           results: input.pages.map(\.result))
                }
            }
            self.persistManifest()
            self.isFinalizing = false
            self.beginFinalize()
        }
    }

    /// Build collection drafts (candidate names + fuzzy-matched existing folders) and show the sheet.
    /// The output folder to file collections into, read LIVE from Settings at finalize time (not the
    /// session's locked config). The output folder is only used at the final move, so honoring a change
    /// made mid-session — via the Live Capture "Output folder" picker or Process Files — is safe and
    /// expected: both the "Add to" existing-folder list and the destination track the current choice.
    /// Falls back to the locked config's directory, then Downloads.
    private var currentOutputDirectory: URL {
        // Test isolation (data safety): the headless LiveCaptureTestDriver sets LIVECAPTURE_TESTOUT, so
        // finalize writes into an ISOLATED scratch folder and NEVER the operator's real output corpus. The
        // move reads THIS, not the driver's `config.outputDirectory`, so without this guard a test run would
        // silently file into the real folder. Env-only; unset in production. Mirrors LIVECAPTURE_TRANSPORT/
        // RELAYDIR overrides elsewhere.
        if let testOut = ProcessInfo.processInfo.environment["LIVECAPTURE_TESTOUT"], !testOut.isEmpty {
            return URL(fileURLWithPath: testOut)
        }
        if let path = UserDefaults.standard.string(forKey: DefaultsKeys.outputDirectory),
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return config?.outputDirectory
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    func beginFinalize() {
        guard !stagingManifestBlocked, config != nil, !staged.isEmpty else { return }
        let existing = Self.existingCollectionFolders(in: currentOutputDirectory)
        let byKey = Dictionary(grouping: staged, by: { $0.collectionKey })
        let orderedKeys = byKey.keys.sorted {
            (byKey[$0]?.map(\.order).min() ?? .max) < (byKey[$1]?.map(\.order).min() ?? .max)
        }
        drafts = orderedKeys.map { key in
            let segs = byKey[key] ?? []
            let candidate = Self.candidateName(segments: segs)
            return CollectionDraft(id: key, finalName: candidate, existingFolders: existing,
                                   suggestedFolders: Self.fuzzyMatches(candidate, in: existing, limit: 3),
                                   chosenExisting: nil, segmentCount: segs.count,
                                   photoCount: segs.reduce(0) { $0 + $1.imageURLs.count })
        }
        showFinalizeSheet = true
    }

    /// Move staged outputs into their (new or existing) collection folders, continuing numbering.
    func finalize(_ decided: [CollectionDraft]) {
        guard !stagingManifestBlocked, config != nil, let stagingDir, !isFinalizing else { return }
        isFinalizing = true
        let outputDir = currentOutputDirectory   // live output folder (matches the "Add to" list built above)
        let byKey = Dictionary(grouping: staged, by: { $0.collectionKey })
        let plans: [MovePlan] = decided.map { d in
            let segs = (byKey[d.id] ?? []).sorted { $0.order < $1.order }
            let name = d.chosenExisting?.lastPathComponent ?? Self.sanitize(d.finalName)
            let folder = d.chosenExisting ?? outputDir.appendingPathComponent(name, isDirectory: true)
            return MovePlan(folder: folder, name: name, appending: d.chosenExisting != nil, segments: segs)
        }
        Task { [weak self] in
            let outcome = await Task.detached { Self.executePlans(plans) }.value
            guard let self else { return }
            self.showFinalizeSheet = false
            self.isFinalizing = false

            // DATA-SAFETY GATE (the never-lose-a-photo invariant). Delete a source photo ONLY for a segment
            // whose processed output actually REACHED its destination collection — `outcome.filedGroupIds`,
            // confirmed on disk. A segment whose PDF was missing (a swallowed generation failure) or whose
            // move failed is NOT filed: its source photos AND its staged outputs stay in the visible backup
            // folder, so an irreplaceable page is never lost — even when finalize "succeeds" with 0 files
            // moved (the original data-loss bug: a folder was created, nothing moved, every source deleted).
            // Deletions go to the Trash (recoverable), never a hard rm.
            //
            // W23.h5 — SECOND gate, on top of "did it reach the destination": did the PDF actually capture
            // the IMAGE? A page whose image couldn't be embedded gets a deliberate placeholder page, so the
            // PDF is valid, 2-page and filed — but it holds no scan, which makes the source photo the only
            // surviving copy. Those sources are withheld from the deletion set (and only those: a sibling
            // page that embedded fine is still retired normally). Computed BEFORE the `staged` cleanup below,
            // which drops exactly these segments.
            let filedGroups = outcome.filedGroupIds
            let placeholderByGroup = Dictionary(
                self.staged.compactMap { seg -> (String, [URL])? in
                    guard let held = seg.placeholderSources, !held.isEmpty else { return nil }
                    return (seg.groupId, held)
                }, uniquingKeysWith: { $0 + $1 })
            let filedSources = Self.sourcesSafeToRetire(
                filedGroups: filedGroups,
                sourcesByGroup: self.retained.values.reduce(into: [String: [URL]]()) { acc, r in
                    acc[r.groupId, default: []] += r.pages.map { $0.sourceURL }
                },
                placeholderSourcesByGroup: placeholderByGroup)
            let keptForPlaceholder = placeholderByGroup
                .filter { filedGroups.contains($0.key) }
                .values.reduce(0) { $0 + $1.count }
            // W3.cap-r1 — how many FILED artifacts went out carrying no Finder tags. Counted here, beside
            // the placeholder tally and for the same reason: `staged` is about to lose exactly the filed
            // segments. Unlike a placeholder this withholds nothing — the owner's decision is that a tag
            // failure still counts as filed — so the ONLY remedy is telling the operator, who otherwise
            // learns about it the day a tag search comes back short.
            let filedUntagged = self.staged
                .filter { filedGroups.contains($0.groupId) }
                .reduce(0) { $0 + ($1.untaggedOutputs?.count ?? 0) }

            // Drop bookkeeping for the fully-filed segments only; keep any unfiled segment staged for retry.
            self.staged.removeAll { filedGroups.contains($0.groupId) }
            self.statuses.removeAll { filedGroups.contains($0.id) }
            // W3.cap-r3-fu5 — `releaseFinalizedGroup`, not a bare `finalizedGroups.remove`: a group that
            // FILED must leave the failed set too. A `.noOutput`/`.incompleteOutput` segment is still
            // appended to `staged` and `retained` (both happen before the label branch), so it reaches the
            // end-of-session rotation review — and a regeneration that succeeded where the first write
            // failed replaced the staged record wholesale, making the group filable while it was still
            // counted failed. The entry this used to leave behind outlived every row that explained it: the
            // status row is dropped one line above, so the operator got a "Retry 1 failed" button with
            // nothing under it — and the collection sheet's "N segment(s) failed … NOT filed" warning —
            // pointed at a document already in the collection. Pressing it usually cost nothing (the filed
            // sources are retired below, `session.groups` is derived from `photos`, so the group is GONE and
            // `retryFailed`'s `else { failedGroupIds.remove(gid) }` self-clears the phantom on first press);
            // it cost MONEY in the placeholder case, where the withheld source keeps the group alive and the
            // retry really does re-ingest and re-buy.
            //
            // ⚠️ `W3.cap-r3-fu6` then closed the one chain that reached this. Regeneration now re-derives the
            // label from the record it just wrote, so a group cannot be filable and failed at the same time,
            // and no OTHER path inserts into `failedGroupIds` over a record `executePlans` will file:
            // `markFailed` is the only writer that inserts, it only fires for `.noOutput` (no PDFs) or
            // `.incompleteOutput` (`pagesComplete == false`), and `executePlans` skips both. So this pairing
            // is now belt-and-braces at THIS call site rather than the fix for a live defect — kept because
            // it is right on its own merits (a group whose every PDF reached its collection is not a failed
            // one) and because the invariant it maintains, `failedGroupIds ⊆ finalizedGroups`, is load-bearing
            // elsewhere: `retryFailed`'s cancel-loop latency argument rests on it. Do NOT read the two
            // together as "fu5 was unnecessary" — the defect was real and shipped; fu6 removed its reachability
            // afterwards. What that DOES mean is measured, not asserted: Test 19's mutant M1 (this line back
            // to a bare `finalizedGroups.remove`) reads 0 RED as of fu6, where it read 2 RED before. The
            // pairing's remaining coverage is Test 17 via `retryFailed` (fu5's M2, 9 RED).
            for gid in filedGroups { self.retained[gid] = nil; self.releaseFinalizedGroup(gid) }
            self.drafts.removeAll()

            // W3.cap-r6 — how many segments are STILL staged, asked after the filed ones were dropped just
            // above. This, not `outcome.allFiled`, is what decides whether the staging directory may be
            // reclaimed; see `stagingSafeToReclaim`.
            let stillStaged = self.staged.count
            if Self.stagingSafeToReclaim(allPlannedFiled: outcome.allFiled, segmentsStillStaged: stillStaged) {
                // Everything landed and nothing arrived behind it → staging holds nothing recoverable.
                // Trash it and reset the session.
                CaptureSession.trashOrRemove(stagingDir)
                // No started-once state to reset here since W3.cap-r3-fu1: `pageTasks` is that record, and
                // the filed groups' entries were already freed by their own `finalizeSegment`. The set this
                // line used to empty was emptied WHOLESALE, which also disarmed any page still mid-OCR in a
                // group this batch never planned — so a re-upload of one could buy its call twice. Asking
                // presence-of-Task keeps that page de-duplicated and still lets a genuinely task-less one
                // (every page of a filed group) buy the call it needs.
                self.rotationReviewPages.removeAll()
                self.currentCollectionKey = "__unfiled__"
                self.finalizeSummary = outcome.summary
            } else if outcome.allFiled {
                // W3.cap-r6 — every PLANNED segment filed, but a straggler finished processing during the
                // move and is not part of this batch. Its freshly written output is in the staging dir, so
                // the dir must survive; persist the reduced manifest (the straggler's own `persistManifest`
                // still listed the now-filed segments) so a crash right now leaves a consistent state, and
                // do NOT reset the session — it is still live and the straggler still needs filing.
                self.persistManifest()
                self.finalizeSummary = outcome.summary
                    + " ⚠️ \(stillStaged) segment\(stillStaged == 1 ? "" : "s") finished processing while this batch was being filed, so \(stillStaged == 1 ? "it was" : "they were") NOT part of it. Nothing was deleted — \(stillStaged == 1 ? "its" : "their") processed files and original photos are KEPT in the Backup Folder. Click Finish again to file \(stillStaged == 1 ? "it" : "them")."
            } else {
                // Partial/failed: KEEP the unfiled segments staged (their outputs remain in the backup
                // folder's `_processed`) and KEEP their source photos, for recovery/retry. Persist the
                // reduced manifest so a crash right now leaves a consistent state.
                self.persistManifest()
                let kept = self.staged.count
                if kept > 0 {
                    self.finalizeSummary = outcome.summary
                        + " ⚠️ \(kept) segment\(kept == 1 ? "" : "s") could NOT be filed — their original photos and processed files are KEPT in the Backup Folder (nothing deleted). Check the output folder (permissions / free space / a missing output), then Finish again or recover from the Backup Folder."
                } else {
                    // Every document filed, but a secondary file (an exported image or JSON sidecar) couldn't
                    // be moved. No source was deleted for it; the leftover sits in the Backup Folder.
                    self.finalizeSummary = outcome.summary
                        + " ⚠️ All documents were filed, but a secondary file (an image or JSON sidecar) couldn't be moved — check the output folder; the leftover is in the Backup Folder."
                }
            }
            // W23.h5 — say so when a filed PDF carries no scan. Silence here is the whole bug: the operator
            // would see a plain "Finalized …", never learn the document has a placeholder where its image
            // should be, and never know a photo was (correctly) left behind in the Backup Folder.
            if keptForPlaceholder > 0 {
                let n = keptForPlaceholder
                self.finalizeSummary = (self.finalizeSummary ?? outcome.summary)
                    + " ⚠️ \(n) page\(n == 1 ? "" : "s") could NOT embed the original scan — \(n == 1 ? "its PDF was" : "their PDFs were") filed with a placeholder image page, so the original photo\(n == 1 ? " was" : "s were") KEPT in the Backup Folder (nothing deleted). Re-run \(n == 1 ? "that page" : "those pages") from the Backup Folder to get the image into the archive."
            }
            // W3.cap-r1 — say so when a filed file went out untagged. Nothing was lost and nothing is being
            // withheld, but the file is now invisible to every tag-driven search in the Reader, and this
            // summary is the only moment the operator can still connect it to the session that made it.
            if filedUntagged > 0 {
                let n = filedUntagged
                self.finalizeSummary = (self.finalizeSummary ?? outcome.summary)
                    + " ⚠️ \(n) filed file\(n == 1 ? "" : "s") could NOT be tagged — \(n == 1 ? "it is" : "they are") in the collection, but \(n == 1 ? "it carries" : "they carry") NO Finder tags, so tag searches in the Reader will not find \(n == 1 ? "it" : "them"). Re-tag \(n == 1 ? "it" : "them") from the output folder (Process Files → re-tag), or check the folder's permissions before the next session."
            }
            // Clear ONLY the confirmed-filed source photos (to the Trash); every unfiled or straggler page
            // stays in the backup folder + Captured pane, recoverable.
            self.session.clearFiled(filedSources)
        }
    }

    /// Clear the "Finalized …" summary (called when new capture begins, or on a manual Clear).
    func clearFinalizeSummary() { if finalizeSummary != nil { finalizeSummary = nil } }

    /// The Captured-pane **Clear** button, whole: Trash the received source photos AND reset the Processing
    /// pane that describes them. THE one door — `clearSessionState` below is `private` precisely so this is
    /// the only way in, because the two halves have to succeed or refuse together (see the guard).
    ///
    /// W3.cap-r3-fu11 — refuse while a finish is regenerating, at the MODEL layer, for the same reason
    /// `retryFailed` does (read its comment for the shape of the window and how it is held open).
    /// `applyRotationReviewAndFinalize` sets `isFinalizing` and then writes each changed segment's files from
    /// a DETACHED task; for the length of that write the Live Capture panel is on screen with no sheet over
    /// it (`isFinishingScrimUp`). A Clear landing there is strictly worse than the retry `W3.cap-r3-fu7`
    /// refused, in the identical window: `session.clear()` Trashes the source photos the in-flight
    /// `writeSegmentFiles` is still reading, and the state reset empties `staged`/`retained` under the loop
    /// that is about to `staged.firstIndex` them — so the regeneration's `guard let idx` finds nothing, its
    /// partially-rewritten `_processed` files are orphaned, and the sources are in the Trash. Recoverable
    /// (Trash, per the Recovery Core Directive), which is why this is LOW and not MED.
    ///
    /// WHY THE GUARD IS HERE AND NOT ONLY ON THE BUTTON — two separate reasons, neither sufficient alone:
    ///  • ATOMICITY. The button used to be `session.clear(); liveProc.clearSessionState()`, two calls a
    ///    refusal could split. Gating only the state half is the WORST outcome available — the sources go to
    ///    the Trash while `staged` still lists the segments that point at them. One call, one guard, so the
    ///    pair cannot disagree.
    ///  • REACHABILITY. `W3.cap-r3-fu10` decided the throbber's scrim is MEANT to freeze the panel, so no
    ///    MOUSE path to Clear survives the window; the view's `.disabled` covers the keyboard/VoiceOver
    ///    routes a scrim does not (`W3.cap-r3-fu10-fu1`). But a `.disabled` computed when the button was
    ///    drawn is a statement about the draw, not about the press — the same argument `retryFailed` makes
    ///    about its deferred sheet Apply — and this is the one place every route converges. The view edit is
    ///    there so the operator is not offered something that would be refused; this is what makes the
    ///    refusal true.
    ///
    /// SCOPED to `isFinalizing` deliberately, and NOT widened to `requestFinish`'s
    /// `!showFinalizeSheet, !showRotationReview` triple — the same scope decision, on the same grounds, as
    /// `retryFailed`. Those two states put a modal sheet over the panel, and clearing from under a collection
    /// sheet the operator has not confirmed yet is a legitimate abort with no write in flight, not a hazard.
    /// (`isFinalizing` is also true for the finalize MOVE itself, where `showFinalizeSheet` is up — that is
    /// covered here, and rightly: a Clear during the move races `executePlans`.) Driver Test 22 check 4
    /// measures the refusal and check 6 measures its WIDTH.
    ///
    /// The refusal is SILENT (the button is disabled, so the state is visible before the press) and is a
    /// WINDOW, not a ban: the window is the length of one regeneration write, and Clear works again after it.
    /// This is the LAST entrant to the `staged`-implies-`finalized` argument at
    /// `applyRotationReviewAndFinalize` — with `retryFailed` and `finalize` already refusing, that
    /// enumeration is now closed by refusals rather than only by MainActor synchronicity.
    ///
    /// ⚠️ THE ONE ASYMMETRY WITH `retryFailed`, named because gating Clear is not the same decision as
    /// gating a retry even though the guard is identical. **Clear is the operator's escape hatch** — the way
    /// out of a session that has gone wrong — so a stuck `isFinalizing` costs more here than there: a retry
    /// that stays disabled is an annoyance, a Clear that stays disabled strands the session. This was
    /// checked rather than assumed, and the flag has no reachable stick: it is set true in exactly two
    /// places, and both clear it immediately after their single `await`, with no branch, no `throw` and no
    /// early `return` in between (`applyRotationReviewAndFinalize`'s Task tail, and `finalize`'s
    /// `showFinalizeSheet = false; isFinalizing = false`). Neither `writeSegmentFiles` nor `executePlans`
    /// is throwing, so neither await can unwind past its reset; the only non-clearing exit is
    /// `guard let self else`, where a deallocated processor makes the flag moot. **What would break that:
    /// adding any early `return` between one of those awaits and its `isFinalizing = false`.** If that ever
    /// happens, this guard needs a timeout or a force-clear affordance, and `retryFailed`'s does not.
    /// (Reasoned from the code — but from Swift control flow, not from hit-testing, which is the kind of
    /// code read `W3.cap-r3-fu10` had to walk back.)
    func clearSession() {
        guard !stagingManifestBlocked, !isFinalizing else { return }
        session.clear()
        clearSessionState()
    }

    /// Reconcile the Processing pane with a Captured-pane **Clear** (B1): reset the in-memory/UI state that
    /// drives the Processing list so both panes empty as one. This is the processing-side mirror of
    /// `CaptureSession.clear()` (which sends the received source photos to the Trash — recoverable).
    ///
    /// `private` since `W3.cap-r3-fu11`: its ONLY caller is `clearSession()` above, which is where the
    /// `isFinalizing` refusal lives. Do not add a second caller — call `clearSession()`, or move the guard.
    ///
    /// DATA SAFETY (Recovery Core Directive, unchanged): this is a **pure in-memory/UI reset** — it performs
    /// **no** on-disk deletion. Any already-staged processed output stays exactly where it was, in the
    /// visible backup folder's `_processed/` subfolder (recoverable in Finder), and the staging manifest is
    /// left untouched on disk. So Clear never hard-deletes a staged/un-filed page: it only forgets the
    /// segments in memory so the pane agrees with the (now-cleared) Captured pane. In-flight OCR `pageTasks`
    /// are dropped (their results are simply discarded); a fresh capture after Clear starts a new segment.
    private func clearSessionState() {
        // B8: advance the generation so any in-flight `finalizeSegment` that suspended at an await before this
        // Clear bails at its next post-await guard instead of repopulating the just-cleared pane / writing a
        // stale manifest. And CANCEL each outstanding OCR task before dropping it, so its work stops rather
        // than running to completion after the session was cleared (its result is discarded either way).
        clearGeneration &+= 1
        for task in pageTasks.values { task.cancel() }
        statuses.removeAll()
        staged.removeAll()
        releaseAllFinalizedGroups()   // W3.cap-r3-fu5 — the pair, together; see the helper
        retained.removeAll()
        groupCollectionKey.removeAll()
        groupOCROverride.removeAll()
        pageTasks.removeAll()
        rotationReviewPages.removeAll()
        currentCollectionKey = "__unfiled__"
        pendingFinish = false
        // W3.cap-r3-fu9 — the per-item sheet targets are session state too, and they are now an INPUT to the
        // finish gate (`perItemSheetUp`), so a survivor is not merely a sheet over an empty pane: a target
        // left set names a group that no longer exists and would hold the NEXT session's Finish indefinitely.
        // Latent rather than live (reaching Clear needs the window-modal sheet down), and cleared here for
        // the same reason everything above it is.
        modelChoiceTarget = nil
        textViewerTarget = nil
        clearFinalizeSummary()
    }

    private struct MovePlan: Sendable {
        let folder: URL; let name: String; let appending: Bool; let segments: [StagedSegment]
    }

    /// Outcome of moving staged files into their collection folders. `filedGroupIds` is the set of segments
    /// whose *every* PDF output actually reached its destination collection — the ONLY segments whose source
    /// photos are safe to delete. `failedMoves > 0` (a real move error) or a segment absent from
    /// `filedGroupIds` (its output was missing/failed) means the caller must KEEP that segment's staging +
    /// source photos. `allFiled` is true only when every staged segment fully filed with no failures.
    private struct FinalizeOutcome: Sendable {
        let summary: String
        let failedMoves: Int
        let movedFiles: Int
        let filedGroupIds: Set<String>
        let allFiled: Bool
    }

    private enum MoveResult { case moved, absent, failed }

    nonisolated private static func executePlans(_ plans: [MovePlan]) -> FinalizeOutcome {
        let fm = FileManager.default
        var movedFiles = 0
        var failedMoves = 0
        var filedGroupIds = Set<String>()
        var totalSegments = 0
        // Move one file; returns true iff it actually LANDED at the destination — so a segment can tell
        // whether ALL of its authoritative PDF outputs were filed (the gate for deleting its source photo).
        func doMove(_ src: URL, to dest: URL) -> Bool {
            switch move(src, to: dest, fm: fm) {
            case .moved: movedFiles += 1; return true
            case .absent: return false           // nothing staged for this slot (e.g. a page whose gen failed)
            case .failed: failedMoves += 1; return false   // a real move error — the output is still in staging
            }
        }
        for plan in plans {
            try? fm.createDirectory(at: plan.folder, withIntermediateDirectories: true)
            // ALWAYS continue numbering from the folder's existing max (not only when appending). A "new
            // collection" whose folder already holds numbered files — e.g. a Finish-again retry after a
            // partial finalize, or the operator reusing a name — must NOT restart at 00001 and collide with
            // (and overwrite) an already-filed file. `appending` no longer affects numbering; both paths are
            // now collision-proof.
            var seq = CollectionNumbering.highestLeadingNumber(in: plan.folder)
            for seg in plan.segments {
                totalSegments += 1
                // An INCOMPLETE segment (a source page produced no PDF) is NEVER filed: skip it entirely so no
                // partial output scatters to the destination and none of its source pages are deleted. Its
                // staged files stay in `_processed` and it's marked failed (retryable) in finalizeSegment.
                if seg.pagesComplete == false { continue }
                // PDFs are the authoritative output. A segment counts as "filed" (its source photos safe to
                // delete) ONLY if it staged at least one PDF and EVERY one reached the destination. Exported
                // images / JSON are secondary and do NOT gate deletion.
                var pdfExpected = 0, pdfLanded = 0
                var firstNum: Int?
                if seg.imageURLs.isEmpty {
                    // One-file output (PDF only): number by PDF (a merged doc is already a single PDF).
                    for pdf in seg.pdfURLs {
                        seq += 1
                        if firstNum == nil { firstNum = seq }
                        let numStr = String(format: "%05d", seq)
                        pdfExpected += 1
                        if doMove(pdf, to: plan.folder.appendingPathComponent("\(numStr) \(plan.name).pdf")) { pdfLanded += 1 }
                    }
                } else if seg.pdfURLs.count == 1 && seg.imageURLs.count > 1 {
                    // Merged multi-page document: one PDF for many page images. Number each image, then the
                    // single merged PDF at the first number.
                    for img in seg.imageURLs {
                        seq += 1
                        if firstNum == nil { firstNum = seq }
                        let numStr = String(format: "%05d", seq)
                        let ext = img.pathExtension.isEmpty ? "jpg" : img.pathExtension
                        _ = doMove(img, to: plan.folder.appendingPathComponent("\(numStr) \(plan.name).\(ext)"))
                    }
                    if let fn = firstNum, let pdf = seg.pdfURLs.first {
                        pdfExpected += 1
                        if doMove(pdf, to: plan.folder.appendingPathComponent("\(String(format: "%05d", fn)) \(plan.name).pdf")) { pdfLanded += 1 }
                    }
                } else {
                    // Two-file output, one PDF per page. The PDF list is authoritative (always page-complete);
                    // an exported image can be missing for a page whose JPEG write failed, so do NOT pair by
                    // positional index (that off-by-one mispairs pages and orphans the trailing PDF, which
                    // finalize then deletes). Iterate PDFs and attach the image sharing each PDF's base name.
                    let imgByBase = Dictionary(seg.imageURLs.map { ($0.deletingPathExtension().lastPathComponent, $0) },
                                               uniquingKeysWith: { first, _ in first })
                    for pdf in seg.pdfURLs {
                        seq += 1
                        if firstNum == nil { firstNum = seq }
                        let numStr = String(format: "%05d", seq)
                        if let img = imgByBase[pdf.deletingPathExtension().lastPathComponent] {
                            let ext = img.pathExtension.isEmpty ? "jpg" : img.pathExtension
                            _ = doMove(img, to: plan.folder.appendingPathComponent("\(numStr) \(plan.name).\(ext)"))
                        }
                        pdfExpected += 1
                        if doMove(pdf, to: plan.folder.appendingPathComponent("\(numStr) \(plan.name).pdf")) { pdfLanded += 1 }
                    }
                }
                if let json = seg.jsonURL, let fn = firstNum {
                    let jf = plan.folder.appendingPathComponent("JSON Output", isDirectory: true)
                    try? fm.createDirectory(at: jf, withIntermediateDirectories: true)
                    _ = doMove(json, to: jf.appendingPathComponent("\(String(format: "%05d", fn)) \(plan.name).json"))
                }
                // Filed iff it produced ≥1 PDF and ALL of them landed. (No PDF → never filed → source kept.)
                if pdfExpected > 0 && pdfLanded == pdfExpected { filedGroupIds.insert(seg.groupId) }
            }
        }
        let allFiled = failedMoves == 0 && filedGroupIds.count == totalSegments
        let summary = "Finalized \(plans.count) collection\(plans.count == 1 ? "" : "s") · \(movedFiles) files moved."
        return FinalizeOutcome(summary: summary, failedMoves: failedMoves, movedFiles: movedFiles,
                               filedGroupIds: filedGroupIds, allFiled: allFiled)
    }

    /// THE source-retirement decision, as a pure function so it can be proven headlessly (W23.h5).
    ///
    /// A source photo may be sent to the Trash only when BOTH hold:
    ///   1. its segment is in `filedGroups` — every one of that segment's PDFs was confirmed on disk at the
    ///      destination (`executePlans`), and
    ///   2. its own page's PDF carries the real scan — i.e. the source is NOT listed in that segment's
    ///      `placeholderSources`. A placeholder image page means the PDF holds no image, so deleting the
    ///      source photo would destroy the only copy of that page.
    ///
    /// Withholding is PER PAGE, not per segment: a sibling page that embedded normally is still retired, so
    /// one unreadable page doesn't strand a whole session's photos. A group absent from `sourcesByGroup`
    /// contributes nothing (there is no source to retire), and an unknown group in
    /// `placeholderSourcesByGroup` is simply never consulted.
    nonisolated static func sourcesSafeToRetire(
        filedGroups: Set<String>,
        sourcesByGroup: [String: [URL]],
        placeholderSourcesByGroup: [String: [URL]]
    ) -> Set<URL> {
        var safe = Set<URL>()
        for (groupId, sources) in sourcesByGroup where filedGroups.contains(groupId) {
            let withheld = Set(placeholderSourcesByGroup[groupId] ?? [])
            safe.formUnion(sources.filter { !withheld.contains($0) })
        }
        return safe
    }

    /// THE staging-reclamation decision (W3.cap-r6), as a pure function so it can be proven headlessly.
    ///
    /// `finalize` may send the whole staging directory to the Trash only when it holds nothing recoverable.
    /// The tempting test — "did every planned move succeed?" — is NOT that question. `plans` is snapshotted
    /// BEFORE the `executePlans` await, and that await runs for as long as the moves take; a segment whose
    /// processing finished inside that window (`finalizeSegment` resumes on the MainActor while the move is
    /// off it) writes fresh output into this same directory and appends itself to `staged` without ever
    /// having been in `plans`. `allPlannedFiled` reports only on the planned segments, so it stays true —
    /// and trashing on it alone discards the straggler's processed output while leaving a `staged` entry
    /// pointing into the Trash.
    ///
    /// So ask the honest question instead: is anything STILL staged once the filed segments have been
    /// dropped? Every staged segment's outputs live in this directory, so a single survivor — a straggler,
    /// or a segment the finalize sheet simply never planned — means the directory still holds files that
    /// exist nowhere else. Reclaim only when there are none.
    nonisolated static func stagingSafeToReclaim(allPlannedFiled: Bool, segmentsStillStaged: Int) -> Bool {
        allPlannedFiled && segmentsStillStaged == 0
    }

    /// Test-only ($0, no OCR/session): stage a real segment from real image files and report which source
    /// photos came back flagged as placeholder-backed (W23.h5). This closes the last link the two pure
    /// tests can't reach on their own — that `writeSegmentFiles` actually POPULATES `placeholderSources`
    /// from `PDFGenerator`'s outcome, so the detection and the retirement gate are really connected rather
    /// than two correct halves wired to nothing. No OCR, no network: the OCR result is supplied.
    ///
    /// W3.cap-r1 extends it: the same staging run also reports which artifacts came back UNTAGGED, and the
    /// tag inputs (`type`/`baseTags`/`pageQuality`/`jsonTags`/`stampUnread`/`taggingMode`) are injectable
    /// so a test can drive colour-authority, Quality-canonicalization and no-tagging decisions. The
    /// optional image mirror is injectable too, so the same test can prove it receives the identical tags.
    /// defaults reproduce the original W23.h5 call exactly.
    nonisolated static func _recoveryTestStageSegment(
        sources: [URL], stagingDir: URL, model: LLMModel,
        type: CaptureGroupType = .document, baseTags: [String] = [],
        pageQuality: String? = nil, jsonTags: GeneratedTags = GeneratedTags(),
        stampUnread: Bool = false, taggingMode: TaggingMode? = nil, doMerge: Bool = false,
        outputImageFile: Bool = false, pageQualities: [String?]? = nil
    ) -> (pdfCount: Int, pagesComplete: Bool?, placeholderSources: [URL],
          untaggedOutputs: [URL], pdfURLs: [URL], imageURLs: [URL]) {
        let pages = sources.enumerated().map { index, source in
            let quality: String?
            if let pageQualities, pageQualities.indices.contains(index) {
                quality = pageQualities[index]
            } else {
                quality = pageQuality
            }
            return PageWork(sourceURL: source,
                            result: OCRResult(text: "text", classification: nil, errorMessage: nil, errorCode: nil),
                            quality: quality)
        }
        let effectiveTaggingMode = taggingMode ?? (stampUnread ? .automatic : .copySource)
        let seg = writeSegmentFiles(groupId: "T", type: type, collectionKey: "T", order: 0,
                                    pages: pages, baseTags: baseTags, doMerge: doMerge, model: model,
                                    gatewayName: nil, localAgentDisplayName: nil, localAgentModelName: nil,
                                    stagingDir: stagingDir, writeJSON: false,
                                    jsonTags: jsonTags, texts: [], boxLabelText: nil,
                                    outputImageFile: outputImageFile, pdfImageMB: 0, exportedImageMB: 0,
                                    textColumns: 1, taggingMode: effectiveTaggingMode,
                                    stampUnread: stampUnread)
        return (seg.pdfURLs.count, seg.pagesComplete, seg.placeholderSources ?? [],
                seg.untaggedOutputs ?? [], seg.pdfURLs, seg.imageURLs)
    }

    /// Test-only ($0): the production per-artifact tag step (W3.cap-r1), so a driver can prove the failure
    /// verdict on an artifact it has made genuinely un-writable — without also having to break PDF
    /// generation to get there. Returns exactly what `writeSegmentFiles` keys `untaggedOutputs` off.
    nonisolated static func _recoveryTestTagArtifact(
        _ tags: [String], at url: URL, appColor: String?, stampUnread: Bool
    ) -> Bool {
        tagStagedArtifact(tags, at: url, appColor: appColor, stampUnread: stampUnread)
    }

    /// Test-only ($0, no OCR/network/GUI): arm a processor with a scratch staging dir + a set of
    /// already-staged segments, so a headless driver can drive the REAL `finalize`. That is the only way to
    /// reach the staging-reclamation WIRING (W3.cap-r6): the decision is a pure function, but *whether
    /// `finalize` consults it* lives in the post-await continuation, which no pure test can enter. Never
    /// called in production — nothing outside the recovery driver references it.
    func _recoveryTestArm(stagingDir: URL, config: SessionProcessingConfig, staged: [StagedSegment]) {
        self.stagingDir = stagingDir
        self.config = config
        self.staged = staged
    }

    /// Test-only ($0, W3.cap-r3-fu8): write the current manifest after a driver-created transient staging
    /// failure has cleared. The real failure path persists before it labels, while the directory is still
    /// deliberately unwritable; this second write creates the crash/relaunch input without fabricating the
    /// processor's private `RetainedSegment` representation in the test.
    func _recoveryTestPersistManifest() { persistManifest() }

    /// Test-only ($0, W3.cap-r3-fu8): enter the REAL manifest loader without `activate`'s legacy-root prune.
    /// A recovery test redirects `CaptureSession.backupRoot`, so the production prune would misclassify any
    /// genuine legacy dirs outside that scratch root as orphaned. This seam keeps the test scratch-only while
    /// exercising the exact decode + status reconstruction that runs after a relaunch.
    func _recoveryTestLoadManifest(stagingDir: URL, config: SessionProcessingConfig) {
        self.stagingDir = stagingDir
        self.config = config
        loadStagingManifest()
    }

    /// Test-only (W3.cap-r6): THE straggler. Appends a staged segment exactly as `finalizeSegment` does, so
    /// a driver can inject one into the window between `finalize` snapshotting `plans` and the move
    /// finishing — the interleaving that produced the bug.
    func _recoveryTestAppendStaged(_ seg: StagedSegment) { staged.append(seg) }

    /// Test-only ($0, W3.cap-r2): when set, `photoIngested` starts THIS canned result instead of a paid
    /// OCR call, and appends the page it started to `_recoveryTestOCRStarts`. The dedup guard's whole claim
    /// is that a re-upload does not spend money, so a test that let the real call through would have to
    /// spend it to find out; this is the seam that lets the driver count PAID starts for $0. Nil in
    /// production — only the recovery driver ever assigns it, and it clears it again when done.
    static var _recoveryTestOCRStub: OCRResult?
    /// Test-only (W3.cap-r2): every page `photoIngested` started an OCR for while the stub was installed,
    /// in order. One entry per paid call the operator would have been billed for.
    static var _recoveryTestOCRStarts: [PageKey] = []

    /// Test-only ($0, W3.cap-r5): when set, the stub OCR Task awaits this before returning its result, so a
    /// driver can hold a `finalizeSegment` SUSPENDED at its per-page OCR await and deliver an out-of-order
    /// relay Box into exactly that window. The misfile only exists inside that window — a group already in
    /// `finalizedGroups` but not yet in `staged` — so a test that could not enter it could not prove the fix
    /// (a pure-function test would pass on both the broken and the fixed code). Captured PER PAGE at ingest,
    /// so the driver arms it for the one page it wants held and clears it again immediately. Nil in
    /// production — only the recovery driver ever assigns it.
    static var _recoveryTestOCRGate: (@Sendable () async -> Void)?

    /// Test-only ($0, W3.cap-r3): every stub OCR Task `photoIngested` started, kept reachable OUTSIDE
    /// `pageTasks`. The fix's whole effect is that the page's entry is gone from `pageTasks` afterwards,
    /// which is precisely what makes the Task unreachable from every other vantage — so this second handle is
    /// the only way a driver can tell a genuine `cancel()` from a silent drop (both leave `pageTasks` empty,
    /// but only one stops the paid call). Never read in production; the recovery driver clears it when done.
    static var _recoveryTestOCRTasks: [PageKey: Task<OCRResult, Never>] = [:]

    /// Test-only ($0, W3.cap-r3): whether `pageTasks` still holds this page — WITHOUT awaiting it.
    /// `_recoveryTestPageOCRText` cannot answer this: a page parked on the test gate has no value to await
    /// yet, so on the unfixed code (entry still present) that probe would HANG instead of failing.
    func _recoveryTestHasPageTask(for photo: CapturedPhoto) -> Bool { pageTasks[PageKey(photo)] != nil }

    /// Test-only ($0, W3.cap-r2): the OCR result `finalizeSegment` would await for this page, looked up the
    /// way finalize looks it up (`pageTasks[PageKey(photo)]`). Counting starts alone cannot catch a fix that
    /// de-duplicates correctly but files the surviving Task under a key nobody reads: this asks the
    /// REPLACEMENT `CapturedPhoto` the re-upload minted for its page's result and gets the first call's.
    func _recoveryTestPageOCRText(for photo: CapturedPhoto) async -> String? {
        await pageTasks[PageKey(photo)]?.value.text
    }

    /// Test-only ($0, W3.cap-r5 / W3.cap-r4): the collection the rotation review will regenerate this segment
    /// into — the LIVE map, which W3.cap-r4 made the only copy of the decision (the retained record used to
    /// keep a second one, and it went stale). Asserting the `staged` record alone would let a fix that
    /// corrects the visible record while leaving regeneration pointed at the previous collection pass.
    /// `groupCollectionKey` is private, so the driver asks for the one value it must check.
    func _recoveryTestLiveCollectionKey(for groupId: String) -> String? { groupCollectionKey[groupId] }

    /// Test-only ($0, no OCR/session): run the finalize move/gate on synthetic staged files so a headless
    /// driver can assert the data-safety invariant — a segment whose PDF is MISSING must NOT be reported as
    /// filed (otherwise finalize would delete its irreplaceable source). Mirrors what `finalize` consumes.
    nonisolated static func _recoveryTestFinalizeMove(
        _ plans: [(folder: URL, name: String, appending: Bool,
                   segments: [(groupId: String, pdfURLs: [URL], imageURLs: [URL], jsonURL: URL?, complete: Bool)])]
    ) -> (movedFiles: Int, failedMoves: Int, filedGroupIds: Set<String>, allFiled: Bool) {
        let mapped: [MovePlan] = plans.map { p in
            MovePlan(folder: p.folder, name: p.name, appending: p.appending,
                     segments: p.segments.map { s in
                         StagedSegment(groupId: s.groupId, type: CaptureGroupType.document.rawValue,
                                       collectionKey: s.groupId, order: 0, pdfURLs: s.pdfURLs,
                                       imageURLs: s.imageURLs, jsonURL: s.jsonURL, boxLabelText: nil,
                                       pagesComplete: s.complete) })
        }
        let o = executePlans(mapped)
        return (o.movedFiles, o.failedMoves, o.filedGroupIds, o.allFiled)
    }

    /// Legacy staging-manifest migration (KNOWN_ISSUES #1 — "rotation review skips legacy-manifest segments").
    /// A **legacy** manifest is the bare `[StagedSegment]` array written before per-segment `retained` inputs
    /// were persisted (pre-`c0312f4`): it restores `staged` but carries **no** `retained`, so `finishSession`
    /// — which builds the rotation review from `retained.values` — would silently EXCLUDE those segments from
    /// the review. We can't safely regenerate a legacy segment in place (its original `rotationDegrees` is
    /// gone; seeding 0° would UN-rotate an auto-rotated page — strictly worse), so instead we DROP each such
    /// segment and let the normal resume path re-process it from scratch (re-OCR + re-tag → a proper
    /// `retained` → a COMPLETE rotation review).
    ///
    /// SAFETY (Recovery Core Directive): only drop a segment we can actually re-process — one whose source
    /// photos ALL still exist (`sourcesPresent(groupId)`). If any source is gone (e.g. the operator hit Clear
    /// before recovering), KEEP the legacy segment as-is (staged, un-reviewable — today's behavior) rather
    /// than delete regenerable output we can no longer rebuild. A dropped segment's stale staged output is
    /// deleted here so it isn't orphaned on disk; the raw sources stay in the visible backup folder, so a
    /// dropped-then-not-yet-reprocessed segment is always recoverable. Returns the segments to KEEP (restore
    /// into `staged`) plus the output files actually deleted (so the $0 self-test can assert on-disk effects).
    nonisolated static func migrateLegacyManifestSegments(
        _ legacy: [StagedSegment], sourcesPresent: (String) -> Bool
    ) -> (keep: [StagedSegment], deleted: [URL]) {
        let fm = FileManager.default
        var keep: [StagedSegment] = []
        var deleted: [URL] = []
        for s in legacy {
            guard sourcesPresent(s.groupId) else { keep.append(s); continue }   // no sources → can't regen → keep
            for u in s.pdfURLs where fm.fileExists(atPath: u.path) { try? fm.removeItem(at: u); deleted.append(u) }
            for u in s.imageURLs where fm.fileExists(atPath: u.path) { try? fm.removeItem(at: u); deleted.append(u) }
            if let j = s.jsonURL, fm.fileExists(atPath: j.path) { try? fm.removeItem(at: j); deleted.append(j) }
        }
        return (keep, deleted)
    }

    /// Move `src` to `dest`, reporting the outcome so the caller can tell a real failure (output stuck in
    /// staging) apart from a nothing-to-move slot. A missing source is `.absent`, not `.failed`.
    nonisolated private static func move(_ src: URL, to dest: URL, fm: FileManager) -> MoveResult {
        guard fm.fileExists(atPath: src.path) else { return .absent }
        // Overwriting an existing destination is now collision-proof (numbering continues from the folder's
        // max), so this should be unreachable in practice — but if a name ever does collide, send the old
        // file to the Trash (recoverable), never a hard delete.
        if fm.fileExists(atPath: dest.path) { CaptureSession.trashOrRemove(dest, fm) }
        do { try fm.moveItem(at: src, to: dest); return .moved } catch { return .failed }
    }


    nonisolated private static func existingCollectionFolders(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return items.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            && !$0.lastPathComponent.hasPrefix(".")
            && $0.lastPathComponent != "JSON Output"
        }.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    nonisolated private static func candidateName(segments: [StagedSegment]) -> String {
        if let box = segments.first(where: { $0.type == CaptureGroupType.box.rawValue }), let label = box.boxLabelText {
            let line = label.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .first(where: { !$0.isEmpty }) ?? ""
            return sanitize(String(line.prefix(80)))
        }
        return ""   // no Box marker → operator must name it
    }

    nonisolated private static func sanitize(_ name: String) -> String {
        var cleaned = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespaces)
        // A dot-only name (".", "..") would resolve via appendingPathComponent to the output dir's parent
        // and write OUTSIDE the intended tree — this name is auto-derived from box-label OCR and
        // auto-accepted in the headless path, so reject it. (Empty also satisfies allSatisfy → fallback.)
        if cleaned.allSatisfy({ $0 == "." }) { cleaned = "" }
        return cleaned.isEmpty ? "Untitled Collection" : cleaned
    }

    /// Fuzzy-rank existing folders against a candidate name (case-insensitive Levenshtein + substring).
    nonisolated private static func fuzzyMatches(_ candidate: String, in folders: [URL], limit: Int) -> [URL] {
        let c = candidate.lowercased().trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty, !folders.isEmpty else { return [] }
        return folders.map { (url: $0, score: similarity(c, $0.lastPathComponent.lowercased())) }
            .filter { $0.score >= 0.34 }
            .sorted { $0.score > $1.score }
            .prefix(limit).map { $0.url }
    }

    nonisolated private static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        if !a.isEmpty && !b.isEmpty && (a.contains(b) || b.contains(a)) { return 0.9 }
        let dist = levenshtein(Array(a), Array(b))
        let maxLen = max(a.count, b.count)
        return maxLen == 0 ? 0 : 1.0 - Double(dist) / Double(maxLen)
    }

    nonisolated private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = a[i - 1] == b[j - 1] ? prev[j - 1] : Swift.min(prev[j - 1], prev[j], cur[j - 1]) + 1
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}
