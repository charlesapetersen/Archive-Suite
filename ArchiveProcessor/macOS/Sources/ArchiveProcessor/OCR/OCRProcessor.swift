import Foundation
import UserNotifications


@MainActor
class OCRProcessor: ObservableObject {
    @Published var jobs: [OCRJob] = []
    @Published var isProcessing = false
    @Published var progress: Double = 0
    @Published var statusMessage = ""
    @Published var failedFiles: [String] = []
    @Published var segments: [DocumentSegment] = []
    @Published var collectionSegments: [CollectionSegment] = []

    @Published var pendingBatchInfo: String?

    /// When true, copy macOS tags from source images to output PDFs instead of LLM tagging
    var passSourceTags = false
    /// Immutable Process Files settings retained for post-run per-item retries. Fresh runs set this once
    /// before any work starts; W16.cfg5 will populate it from resume state. MainActor isolation keeps the
    /// snapshot and all retry consumers serialized.
    var activeRunConfig: SessionProcessingConfig?

    // MARK: Live Capture staging (set by LiveCaptureView, consumed by OCRView → startProcessing)
    /// Ordered captured photo URLs waiting to be loaded as the input file list.
    @Published var stagedCaptureFiles: [URL] = []
    /// Parallel to the staged/loaded files: whether each starts a new group, and its type.
    var stagedCaptureBoundaries: [Bool] = []
    var stagedCaptureTypes: [CaptureGroupType] = []
    /// Parallel minimal on-phone tags: per-photo priority ("P10"…"P7") and the group's year/month.
    var stagedCapturePriorities: [String?] = []
    var stagedCaptureYears: [Int?] = []
    var stagedCaptureMonths: [Int?] = []
    /// Mac-operator subjects per file (from the Live Capture tag card; empty entry = untagged).
    var stagedCaptureSubjects: [[String]] = []
    /// Active pre-grouped segmentation for the current run (empty = use LLM segmentation).
    var preGroupedBoundaries: [Bool] = []
    var preGroupedTypes: [CaptureGroupType] = []
    /// Active pre-grouped phone tags for the current run (parallel to the loaded files; empty = none).
    var preGroupedPriorities: [String?] = []
    var preGroupedYears: [Int?] = []
    var preGroupedMonths: [Int?] = []
    var preGroupedSubjects: [[String]] = []
    /// Live Capture: also emit each page's original image (renamed + tagged) alongside its PDF.
    var exportOriginals = false

    /// When true, merge continuation pages into single multi-page PDFs
    var mergeDocuments = false
    /// Optional controlled vocabulary for subject tags (one per line)
    var tagVocabulary: [String] = []
    /// How tags are assigned (automatic / auto-date / human / copy-source / none). Set from the UI before a run.
    /// Setting it also arms the "Unread" trailing-tag stamp for real-tagging modes (see MacOSTagger).
    var taggingMode: TaggingMode = .automatic {
        didSet { MacOSTagger.stampUnread = taggingMode.stampsUnread }
    }
    /// How image rotation is detected. Set from the UI before a run.
    var rotationMode: RotationMode = .llmSingle
    /// When true (and rotation detection is on), pause for a dedicated rotation-review pass — separate
    /// from the tagging/segmentation review, and run in every tagging mode. Set from the UI before a run.
    var reviewRotation = false
    // MARK: - Per-run configuration statics
    //
    // W16.cfg5 moved every production run/diagnostic to explicit `SessionProcessingConfig` values.
    // These compatibility fallbacks remain only for isolated drivers/legacy helper signatures and are
    // deleted by W16.cfg6; production no longer writes them at run start or resume.

    /// The active run's rotation mode, readable from the nonisolated OCR call.
    nonisolated(unsafe) static var rotationModeForRun: RotationMode = .localVision

    /// The "standard" image size (MB) the resolution slider targets.
    nonisolated(unsafe) static var standardImageMB: Double = 3.0

    /// Parallel OCR workers for the batch run (user-configurable in Settings, 1–12).
    nonisolated(unsafe) static var ocrWorkerCount: Int = 4

    /// Target size (MB) for the image embedded in each output PDF (0 = full source resolution).
    nonisolated(unsafe) static var pdfImageMB: Double = 0

    /// Number of text columns on the OCR text page (1 = single-column default, 2–4 for multi-column).
    nonisolated(unsafe) static var textColumns: Int = 1

    /// Target size (MB) for the separately-exported image file in two-file output (0 = full resolution).
    nonisolated(unsafe) static var exportedImageMB: Double = 0

    /// Compatibility helper retained for W16.cfg6 cleanup. Production uses
    /// `SessionProcessingConfig.fromProcessFilesRunStart()` instead.
    static func loadStandardImageMB() {
        let v = UserDefaults.standard.double(forKey: DefaultsKeys.standardImageSizeMB)
        standardImageMB = v.isFinite && v > 0 ? min(20, max(0.5, v)) : 3.0
        let w = UserDefaults.standard.integer(forKey: DefaultsKeys.ocrWorkerCount)
        ocrWorkerCount = w > 0 ? min(12, max(1, w)) : 4
        let p = UserDefaults.standard.double(forKey: DefaultsKeys.pdfImageSizeMB)
        pdfImageMB = p.isFinite && p > 0 ? min(20, max(0.5, p)) : 2.0
        let e = UserDefaults.standard.double(forKey: DefaultsKeys.exportedImageSizeMB)
        exportedImageMB = e.isFinite && e > 0 ? min(20, max(0.5, e)) : 3.0
        let tc = UserDefaults.standard.integer(forKey: DefaultsKeys.textColumns)
        textColumns = min(4, max(1, tc))
    }

    /// Cosmetic status suffix shown while a (typically free-tier) key is being rate-limited (429), so a
    /// paced bulk job doesn't look stalled. The actual backoff/retry is handled in NetworkSession.
    static var rateLimitSuffix: String {
        if let t = NetworkSession.lastRateLimitedAt, Date().timeIntervalSince(t) < 12 {
            return " · pacing to your key's rate limit"
        }
        return ""
    }

    /// The resolution slider is a **size target**, not a dimension %: `sizeFraction` (0–1) × the
    /// standard size gives a target file size; the dimension scale is ~√(target/actual), clamped to
    /// ≤1 (never upscale). So larger files are downscaled more; files already at/under target are
    /// left full-resolution. Returns 1.0 (full) at fraction ≥ 1 for average/small files.
    nonisolated static func targetDimensionScale(
        forFileAt url: URL,
        sizeFraction: Double,
        standardImageMB explicitStandardImageMB: Double? = nil
    ) -> Double {
        // Live Capture supplies its immutable session snapshot here. Process Files keeps using the
        // run-scoped static until its larger dependency-injection refactor is complete. Crucially,
        // a Process Files run can no longer change the size target of an in-flight Live Capture call.
        let runStandardImageMB = explicitStandardImageMB ?? standardImageMB
        let targetBytes = max(0.01, sizeFraction) * runStandardImageMB * 1_000_000
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let bytes = (attrs[.size] as? NSNumber)?.doubleValue, bytes > 0 else {
            return min(1.0, sizeFraction)   // unknown size → treat the fraction as a dimension scale
        }
        guard bytes > targetBytes else { return 1.0 }
        return min(1.0, (targetBytes / bytes).squareRoot())
    }

    /// Source URLs the user removed during segmentation review; excluded from segments, tagging, and output.
    var removedSourceURLs: Set<URL> = []

    /// Review state for collection confirmation flow
    @Published var collectionReviewItems: [CollectionReviewItem] = []
    @Published var awaitingCollectionConfirmation = false
    @Published var noBoxCollectionName: String = "Uncategorized"
    var collectionConfirmationContinuation: CheckedContinuation<Void, Never>?

    /// Document segmentation review state
    @Published var documentReviewItems: [DocumentReviewItem] = []
    @Published var awaitingDocumentReview = false
    @Published var currentReviewCollectionName: String = ""
    /// Whether the document review sheet should offer New-Document / Continuation options
    /// (only meaningful when merging or tagging by segment).
    @Published var reviewShowsDocumentClasses = true
    /// When true, the shared review sheet is the dedicated rotation-review pass: it shows ONLY the
    /// rotation control (no classification/box-folder radios). When false it's the segmentation/
    /// tagging review, which shows classification only (rotation is a separate step, applied for display).
    @Published var reviewRotationOnly = false
    var documentReviewContinuation: CheckedContinuation<Void, Never>?

    /// Final box/folder confirmation review state (shown after document segmentation review)
    @Published var boxFolderConfirmItems: [DocumentReviewItem] = []
    @Published var awaitingBoxFolderConfirmation = false
    var boxFolderConfirmContinuation: CheckedContinuation<Void, Never>?

    /// Manual (human) tagging review state — sequential, one segment at a time (autoDate mode)
    @Published var manualTagSegments: [ManualTagSegment] = []
    @Published var currentManualIndex = 0
    @Published var awaitingManualTagging = false
    var manualTaggingContinuation: CheckedContinuation<Void, Never>?

    /// Fully-manual segmentation + tagging review state (human / autoDateManualSeg modes).
    /// Progressive "consume-as-you-go": the user reviews rotation + box/folder, identifies each
    /// document segment by marking where it ends, then tags it — the tagged pages then drop out.
    /// `manualSegImages` is the immutable ordered backing store; all session state below indexes
    /// into it (array indices are stable for the session; `fileIndex` is used only at apply-back).
    @Published var manualSegImages: [ManualSegImage] = []
    /// Array indices assigned to a completed (tagged) segment — dropped from the viewer.
    @Published var manualSegConsumed: Set<Int> = []
    /// Array indices flagged for removal (file ops deferred to Finish, so restore is a pure toggle).
    @Published var manualSegRemoved: Set<Int> = []
    /// The document segments the user has already identified and tagged.
    @Published var manualSegCompleted: [CompletedManualSegment] = []
    /// The photo currently shown large (an index into `manualSegImages`).
    @Published var manualSegFocus = 0
    /// The pending segment currently open in the tag card (array-index range), or nil while browsing.
    @Published var manualSegTaggingRange: ClosedRange<Int>? = nil
    /// The editable tag data for the pending segment shown in the tag card.
    @Published var manualSegDraftTags = SegmentTagData()
    @Published var awaitingManualSegTag = false
    /// When true (autoDateManualSeg mode), each segment's date is fetched from the LLM on demand.
    @Published var manualSegAutoDate = false
    /// True while the tag card's date fetch is in flight.
    @Published var manualSegDateFetching = false
    /// Pre-OCRed run: output PDFs ARE the source files, so rotation must not regenerate them.
    var manualSegPreOCRed = false
    var manualSegContinuation: CheckedContinuation<Void, Never>?
    // LLM params captured for on-demand date fetching during manual segmentation.
    var manualSegProvider: LLMProvider = .gemini
    var manualSegModel: LLMModel?
    var manualSegThinking: ThinkingLevel?
    var manualSegApiKey: String = ""

    /// Interactive workflow pause states
    @Published var awaitingFinalReview = false           // After tagging, before completion
    enum FinalReviewAction { case complete, redoTagging }
    var finalReviewContinuation: CheckedContinuation<FinalReviewAction, Never>?

    /// Retry dialog state
    enum RetryAction {
        case retry(provider: LLMProvider, model: LLMModel, thinkingLevel: ThinkingLevel?, apiKey: String)
        case continueWithout
    }
    @Published var failedFileIndices: [Int] = []
    @Published var awaitingRetryDecision = false
    var retryContinuation: CheckedContinuation<RetryAction, Never>?

    /// Maps source image URL → output PDF URL (for tagging the output, not the source)
    var outputURLMap: [URL: URL] = [:]
    /// Cached lowercased paths of all values in `outputURLMap`, maintained by `uniqueOutputURL`
    /// and cleared alongside `outputURLMap = [:]` resets. Avoids O(n) set-rebuild per call.
    var _takenOutputPaths = Set<String>()
    /// Maps source image URL → its per-page EXPORTED original image URL (dual output), captured by
    /// `exportOriginalImages` BEFORE document merging repoints `outputURLMap` to a single merged PDF.
    /// Threaded into `CollectionSegmenter.organizeOutput` so a merged doc's per-page images get filed
    /// into the collection folder (they can't be recovered from the merged PDF's name alone).
    var exportedImageMap: [URL: URL] = [:]
    /// Maps original PDF source URL → temporary JPEG URL (for cleanup)
    var pdfToImageMap: [URL: URL] = [:]
    /// W23.m5 — output artifacts (PDF / exported JPEG / merged PDF) whose Finder-tag write THREW, by
    /// output file name. The bytes are complete and the file still counts as processed — the owner's
    /// recorded decision for the equivalent Live Capture case (W3.cap-r1): tags are re-derivable, so
    /// withholding "done" over metadata would help nobody. What a tag failure DOES cost is findability:
    /// the Reader's tag-driven triage silently omits an untagged file, so it must be said out loud at
    /// the end of the run instead of discarded into a `try?`.
    /// Names, not URLs, because `CollectionSegmenter.organizeOutput` MOVES outputs into collection
    /// folders after tagging — a recorded URL would be a stale path by the time the summary is written.
    /// Maintained by `recordTagWrite(succeeded:for:)`: a later successful re-write clears the entry, so
    /// a rotation-regen or review retry self-heals the record.
    var untaggedOutputs: [String] = []
    /// W23.h5-fu — outputs whose PDF carries the visible PLACEHOLDER image page instead of the scan
    /// (`PDFGenerator.ImagePageOutcome.placeholder`), by output file name. Unlike Live Capture this path
    /// never trashes the source image, so nothing is lost — but "didn't throw" is not "the scan is in
    /// there", and only the operator can decide to re-shoot or re-run. Same self-healing record.
    var placeholderOutputs: [String] = []
    /// The model used for the current processing run (for PDF regeneration headers)
    var currentModel: LLMModel?
    /// Gateway configuration for the current run (nil = direct API mode)
    var currentGateway: GatewayConfig?
    /// Local Agent (subscription-auth CLI) backend for the current run, or nil when using an API key /
    /// gateway. The instance-side mirror of the `localAgent` carrier in `PendingRun` / the run builder —
    /// set alongside `currentGateway` and read at the client-construction sites, which prefer it when set.
    var currentLocalAgent: LocalAgentConfig?
    var processingTask: Task<Void, Never>?

    /// Stored batch context for cancellation
    struct BatchContext: Sendable {
        let batchId: String
        let apiKey: String
        let model: LLMModel
        let thinkingLevel: ThinkingLevel?
        let provider: LLMProvider
    }
    var activeBatch: BatchContext?
    /// Durable client-side state for the active paid batch. Unlike `activeBatch` (which only carries
    /// credentials needed for cancellation), this mirrors the crash-safe on-disk journal and advances
    /// after every submitted Gemini chunk and every materialized result.
    var activePendingBatch: PendingBatch?
    /// Set true when batch polling exits WITHOUT the batch reaching a terminal state (a transient
    /// network error streak, or the safety timeout). Signals callers to KEEP the pending batch (so it
    /// stays resumable) instead of deleting it, and tells pollBatchUntilComplete not to mark every
    /// still-processing file as failed. A completed batch always resets this to false.
    var batchPollInterrupted = false

    // MARK: - Batch Persistence

    struct PendingBatch: Codable {
        static let currentLifecycleVersion = 1

        var batchId: String
        let provider: LLMProvider
        let model: LLMModel
        let thinkingLevel: ThinkingLevel?
        let fileURLs: [URL]
        let outputDirectory: URL
        let enableTagging: Bool
        let enableCollectionSegmentation: Bool
        let sendPreviousImage: Bool
        let submittedAt: Date
        let enableSegmentJSON: Bool
        let confirmCollectionIDs: Bool
        let reviewDocumentSegmentation: Bool
        let customPrompt: String?
        let taggingMode: TaggingMode
        /// Nil identifies a legacy sorted-input fingerprint. Version 2 preserves input order because
        /// provider result IDs are index-based. Unknown versions fail closed without deleting the paid job.
        let fingerprintVersion: Int?
        /// Content fingerprint of this run's identity (ordered inputs for v2; sorted inputs only for
        /// legacy manifests) + destination + settings that change what lands on disk. Lets resume reject
        /// a torn/tampered job without stranding pre-v2 paid batches.
        let runFingerprint: String?
        /// Whether this run also emits a sized original image beside each PDF (dual output). Persisted at
        /// submit time so a resume after relaunch restores the SAME dual-output behavior the run was
        /// started with, rather than reading the live @AppStorage (which the user may have toggled since).
        /// Optional for backward-compat: a manifest written before this field decodes it as nil, and resume
        /// falls back to the live setting. NOT part of `runFingerprint` — a runtime knob, not run identity.
        let exportOriginals: Bool?

        /// Version 1 turns the old submit-once manifest into a durable paid-batch journal. Nil denotes a
        /// legacy manifest, whose comma-separated `batchId` remains readable exactly as before.
        var lifecycleVersion: Int?
        /// Ordered server-side job IDs acknowledged so far. Gemini can create several paid jobs for one
        /// local run; each ID is appended and atomically saved immediately after its create response.
        var submittedChunkIds: [String]
        /// Terminal chunks whose results have been completely materialized and durably associated with
        /// their source indices. A resume skips these instead of downloading/creating their PDFs again.
        var consumedChunkIds: [String]
        /// False while a multi-chunk submission is still being constructed. A crash in that window keeps
        /// every acknowledged ID recoverable without guessing whether an unacknowledged POST succeeded.
        var submissionComplete: Bool
        /// Per-file progress is journaled before a chunk is marked consumed. This closes the crash window
        /// where half a chunk had written PDFs but the old in-memory-only Set forgot them on relaunch.
        var completedResults: [String: OCRResult]
        var completedOutputPaths: [String: String]?
        /// SHA-256 over the complete v1 journal (excluding this field). It protects the evolving
        /// ID/result/output associations in addition to the legacy immutable run fingerprint.
        var lifecycleFingerprint: String?

        init(batchId: String, provider: LLMProvider, model: LLMModel, thinkingLevel: ThinkingLevel?,
             fileURLs: [URL], outputDirectory: URL, enableTagging: Bool,
             enableCollectionSegmentation: Bool = false, sendPreviousImage: Bool, submittedAt: Date,
             enableSegmentJSON: Bool = true, confirmCollectionIDs: Bool = false,
             reviewDocumentSegmentation: Bool = false, customPrompt: String? = nil,
             taggingMode: TaggingMode = .automatic, fingerprintVersion: Int? = 2,
             runFingerprint: String? = nil,
             exportOriginals: Bool? = nil,
             lifecycleVersion: Int? = nil,
             submittedChunkIds: [String]? = nil,
             consumedChunkIds: [String] = [],
             submissionComplete: Bool = true,
             completedResults: [String: OCRResult] = [:],
             completedOutputPaths: [String: String]? = nil,
             lifecycleFingerprint: String? = nil) {
            self.batchId = batchId; self.provider = provider; self.model = model
            self.thinkingLevel = thinkingLevel; self.fileURLs = fileURLs
            self.outputDirectory = outputDirectory; self.enableTagging = enableTagging
            self.enableCollectionSegmentation = enableCollectionSegmentation
            self.sendPreviousImage = sendPreviousImage; self.submittedAt = submittedAt
            self.enableSegmentJSON = enableSegmentJSON
            self.confirmCollectionIDs = confirmCollectionIDs
            self.reviewDocumentSegmentation = reviewDocumentSegmentation
            self.customPrompt = customPrompt
            self.taggingMode = taggingMode
            self.fingerprintVersion = fingerprintVersion
            self.runFingerprint = runFingerprint
            self.exportOriginals = exportOriginals
            self.lifecycleVersion = lifecycleVersion
            self.submittedChunkIds = submittedChunkIds ?? Self.parseChunkIDs(batchId)
            self.consumedChunkIds = consumedChunkIds
            self.submissionComplete = submissionComplete
            self.completedResults = completedResults
            self.completedOutputPaths = completedOutputPaths
            self.lifecycleFingerprint = lifecycleFingerprint
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            batchId = try c.decode(String.self, forKey: .batchId)
            provider = try c.decode(LLMProvider.self, forKey: .provider)
            model = try c.decode(LLMModel.self, forKey: .model)
            thinkingLevel = try c.decodeIfPresent(ThinkingLevel.self, forKey: .thinkingLevel)
            fileURLs = try c.decode([URL].self, forKey: .fileURLs)
            outputDirectory = try c.decode(URL.self, forKey: .outputDirectory)
            enableTagging = try c.decode(Bool.self, forKey: .enableTagging)
            enableCollectionSegmentation = try c.decodeIfPresent(Bool.self, forKey: .enableCollectionSegmentation) ?? false
            sendPreviousImage = try c.decode(Bool.self, forKey: .sendPreviousImage)
            submittedAt = try c.decode(Date.self, forKey: .submittedAt)
            enableSegmentJSON = try c.decodeIfPresent(Bool.self, forKey: .enableSegmentJSON) ?? true
            confirmCollectionIDs = try c.decodeIfPresent(Bool.self, forKey: .confirmCollectionIDs) ?? false
            reviewDocumentSegmentation = try c.decodeIfPresent(Bool.self, forKey: .reviewDocumentSegmentation) ?? false
            customPrompt = try c.decodeIfPresent(String.self, forKey: .customPrompt)
            taggingMode = try c.decodeIfPresent(TaggingMode.self, forKey: .taggingMode) ?? .automatic
            fingerprintVersion = try c.decodeIfPresent(Int.self, forKey: .fingerprintVersion)
            runFingerprint = try c.decodeIfPresent(String.self, forKey: .runFingerprint)
            exportOriginals = try c.decodeIfPresent(Bool.self, forKey: .exportOriginals)
            lifecycleVersion = try c.decodeIfPresent(Int.self, forKey: .lifecycleVersion)
            submittedChunkIds = try c.decodeIfPresent([String].self, forKey: .submittedChunkIds)
                ?? Self.parseChunkIDs(batchId)
            consumedChunkIds = try c.decodeIfPresent([String].self, forKey: .consumedChunkIds) ?? []
            submissionComplete = try c.decodeIfPresent(Bool.self, forKey: .submissionComplete) ?? true
            completedResults = try c.decodeIfPresent([String: OCRResult].self, forKey: .completedResults) ?? [:]
            completedOutputPaths = try c.decodeIfPresent([String: String].self, forKey: .completedOutputPaths)
            lifecycleFingerprint = try c.decodeIfPresent(String.self, forKey: .lifecycleFingerprint)
        }

        static func parseChunkIDs(_ value: String) -> [String] {
            value.split(separator: ",", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        var effectiveChunkIds: [String] {
            lifecycleVersion == Self.currentLifecycleVersion
                ? submittedChunkIds
                : Self.parseChunkIDs(batchId)
        }
    }






    // MARK: - Non-Batch Run Persistence

    /// Versioned, immutable snapshot of every mutable/runtime knob that the standard Process Files
    /// pipeline reads after its `startProcessing` arguments have been captured. A resumed v2 run applies
    /// this snapshot before rebuilding output or making another OCR call, so relaunch-time UserDefaults
    /// and UI state cannot silently change the rest of an in-flight job.
    ///
    /// `PendingRun` retains its original flat fields for legacy manifests. This additive carrier is
    /// optional solely for backward compatibility; every newly-created standard run must include it and
    /// an identity fingerprint computed over it. Unknown future schema versions fail closed (the manifest
    /// is preserved but not resumed by an older build).
    struct PendingRunRuntimeConfig: Codable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let taggingMode: TaggingMode
        let passSourceTags: Bool
        let rotationMode: RotationMode
        let reviewRotation: Bool
        let mergeDocuments: Bool
        let tagVocabulary: [String]
        let imageScale: Double
        let exportOriginals: Bool

        /// Live Capture handoff metadata, parallel to `PendingRun.fileURLs` when populated.
        let preGroupedBoundaries: [Bool]
        let preGroupedTypes: [CaptureGroupType]
        let preGroupedPriorities: [String?]
        let preGroupedYears: [Int?]
        let preGroupedMonths: [Int?]
        let preGroupedSubjects: [[String]]

        /// UserDefaults-backed sizing/concurrency values copied after `loadStandardImageMB()` normalizes
        /// them. These affect request cost, generated PDFs/images, and scheduling, so resume must not
        /// reload potentially-changed defaults.
        let standardImageMB: Double
        let ocrWorkerCount: Int
        let pdfImageMB: Double
        let textColumns: Int
        let exportedImageMB: Double

        /// Cost-history attribution for a gateway run. It does not affect requests, but persisting it
        /// keeps the resumed run's history consistent with the estimate shown when the run began.
        let gatewayUpstreamProvider: LLMProvider?
    }

    struct PendingRun: Codable {
        let provider: LLMProvider
        let model: LLMModel
        let thinkingLevel: ThinkingLevel?
        let fileURLs: [URL]
        let outputDirectory: URL
        let enableTagging: Bool
        let enableSegmentJSON: Bool
        let enableCollectionSegmentation: Bool
        let confirmCollectionIDs: Bool
        let reviewDocumentSegmentation: Bool
        let preOCRedInput: Bool
        let previousTextCharCount: Int
        let sendPreviousImage: Bool
        let customPrompt: String?
        let startedAt: Date
        let gatewayConfig: GatewayConfig?
        /// Per-file OCR result keyed by the file's index string. Stores EVERY completed result —
        /// INCLUDING failures (`text == nil`) — because `saveResultToPendingRun` is called for every
        /// finished file. Resume therefore treats a persisted failure as "already attempted" and does
        /// NOT re-OCR it in the main pass (`remainingIndices` keys off presence in this map, not on
        /// success); a failed file is re-OCR'd only by the explicit retry loops (`retryHighUseFailures`
        /// / interactive retry) after the main pass.
        var completedResults: [String: OCRResult]
        /// The EXACT output-PDF path this run assigned to each completed index (same index string key as
        /// `completedResults`), recorded in COMPLETION order in the original pass. Resume reuses these
        /// verbatim instead of re-deriving output paths in index order — re-derivation would swap the
        /// source→output association for two inputs sharing a base filename across folders (B7): the file
        /// on disk carries one source's OCR/tags but tagging would then stamp the other source's tags onto
        /// it. Optional for backward-compat: manifests written before this field decode it as nil, and
        /// resume falls back to the legacy index-order derivation ONLY for those legacy manifests.
        var completedOutputPaths: [String: String]? = nil
        /// Integrity fingerprint. Legacy manifests hash their sorted input set + a few flat settings;
        /// v2 manifests hash ordered inputs, all persisted/runtime configuration, and the evolving
        /// index→result/output associations. Optional only for pre-fingerprint backward compatibility.
        var runFingerprint: String? = nil
        /// Whether this run also emits a sized original image beside each PDF (dual output). Persisted so a
        /// resume restores the SAME dual-output behavior the run was started with instead of reading the
        /// live @AppStorage. Optional for backward-compat: a manifest written before this field decodes as
        /// nil and resume falls back to the live setting. Duplicated inside (and covered by) the v2
        /// runtime snapshot; retained here for legacy decoding.
        var exportOriginals: Bool? = nil
        /// The Local Agent (subscription-auth CLI) backend this run started with, or nil when the run
        /// uses an API key / gateway (the normal case). Additive + optional so a manifest written
        /// before this feature decodes byte-for-byte unchanged (absent → nil) and crash-resume of an
        /// in-flight run is untouched (Design decision 2 of the local-agent plan). Trailing/defaulted,
        /// exactly like the back-compat fields above. Covered by the v2 fingerprint when present.
        var localAgent: LocalAgentConfig? = nil
        /// Complete v2 runtime snapshot. Nil only for a manifest written by an older build; legacy resumes
        /// intentionally retain the historical live-setting fallback because the original values were
        /// never recorded and cannot be reconstructed.
        var runtimeConfig: PendingRunRuntimeConfig? = nil
    }





    /// Tracks the active non-batch run for incremental saves. Nil when not running.
    var activePendingRun: PendingRun?

    /// In-memory snapshot of the CURRENT Process-Files run's parameters, captured at run start so the
    /// completion tail can log an accurate history entry (cost + counts) even on the paths that clear
    /// `activePendingRun` before the tail. Nil when not running; NEVER persisted (the history log itself
    /// lives in `ProcessingHistoryStore`). See `Models/ProcessingHistory.swift`.
    var activeRunHistory: RunHistorySnapshot?



    @Published var pendingRunInfo: String?












    // MARK: - PDF Input Conversion



    // MARK: - Pre-OCRed PDF Processing







    // MARK: - Phase 1 (Batch): Batch OCR




    // MARK: - Phase 1: OCR


    // MARK: Sequential OCR (when previous text context is needed)


    // MARK: Parallel OCR (when no previous text context is needed)


    // MARK: Shared OCR helpers






    // MARK: - Retry High-Use Failures



    // MARK: - Phase 3: Tagging



    // MARK: - Live Capture phone tags (priority + date)











    // MARK: - Fully-manual segmentation + tagging (human mode)


    // MARK: Manual segmentation — derived state






    /// Finish is allowed only when every document has been tagged or removed (boxes/folders may remain).
    var manualSegCanFinish: Bool { manualSegRemainingDocCount == 0 }

    // MARK: Manual segmentation — UI intents











    // MARK: - Segment JSON


    // MARK: - Document Merging


    // MARK: - Phase 4: Collection Segmentation





    // MARK: - Document Segmentation Review








    // MARK: - Box/Folder Final Confirmation





    // MARK: - Failed OCR Retry





    // MARK: - Log

    // MARK: - Resolution Test


    // MARK: - Notifications



}
