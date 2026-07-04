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
    /// The active run's rotation mode, readable from the nonisolated OCR call. Only one run
    /// executes at a time, so a static is safe here.
    nonisolated(unsafe) static var rotationModeForRun: RotationMode = .localVision

    /// The "standard" image size (MB) the resolution slider targets. Set once per run from Settings.
    nonisolated(unsafe) static var standardImageMB: Double = 3.0

    /// Parallel OCR workers for the batch run (user-configurable in Settings, 1–12). Set once per run.
    nonisolated(unsafe) static var ocrWorkerCount: Int = 4

    /// Target size (MB) for the image embedded in each output PDF (0 = full source resolution).
    /// Independent of the LLM/OCR image size. Set once per run from Settings.
    nonisolated(unsafe) static var pdfImageMB: Double = 0

    /// Target size (MB) for the separately-exported image file in two-file output (0 = full resolution).
    /// Independent of the camera/source size. Set once per run from Settings.
    nonisolated(unsafe) static var exportedImageMB: Double = 0

    /// Load run-time knobs from UserDefaults (standard size 3 MB, OCR workers 4, PDF-image 2 MB,
    /// exported-image 3 MB) — call at run start.
    static func loadStandardImageMB() {
        let v = UserDefaults.standard.double(forKey: "standardImageSizeMB")
        standardImageMB = v > 0 ? v : 3.0
        let w = UserDefaults.standard.integer(forKey: "ocrWorkerCount")
        ocrWorkerCount = w > 0 ? min(12, w) : 4
        let p = UserDefaults.standard.double(forKey: "pdfImageSizeMB")
        pdfImageMB = p > 0 ? p : 2.0
        let e = UserDefaults.standard.double(forKey: "exportedImageSizeMB")
        exportedImageMB = e > 0 ? e : 3.0
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
    nonisolated static func targetDimensionScale(forFileAt url: URL, sizeFraction: Double) -> Double {
        let targetBytes = max(0.01, sizeFraction) * standardImageMB * 1_000_000
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
    /// Maps original PDF source URL → temporary JPEG URL (for cleanup)
    var pdfToImageMap: [URL: URL] = [:]
    /// The model used for the current processing run (for PDF regeneration headers)
    var currentModel: LLMModel?
    /// Gateway configuration for the current run (nil = direct API mode)
    var currentGateway: GatewayConfig?
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
    /// Set true when batch polling exits WITHOUT the batch reaching a terminal state (a transient
    /// network error streak, or the safety timeout). Signals callers to KEEP the pending batch (so it
    /// stays resumable) instead of deleting it, and tells pollBatchUntilComplete not to mark every
    /// still-processing file as failed. A completed batch always resets this to false.
    var batchPollInterrupted = false

    // MARK: - Batch Persistence

    struct PendingBatch: Codable {
        let batchId: String
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

        init(batchId: String, provider: LLMProvider, model: LLMModel, thinkingLevel: ThinkingLevel?,
             fileURLs: [URL], outputDirectory: URL, enableTagging: Bool,
             enableCollectionSegmentation: Bool = false, sendPreviousImage: Bool, submittedAt: Date,
             enableSegmentJSON: Bool = true, confirmCollectionIDs: Bool = false,
             reviewDocumentSegmentation: Bool = false, customPrompt: String? = nil,
             taggingMode: TaggingMode = .automatic) {
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
        }
    }






    // MARK: - Non-Batch Run Persistence

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
        /// Per-file OCR results keyed by file index. Only succeeded files are stored.
        var completedResults: [String: OCRResult]
    }





    /// Tracks the active non-batch run for incremental saves. Nil when not running.
    var activePendingRun: PendingRun?



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

    static let englishMonthNames = ["January", "February", "March", "April", "May", "June",
                                            "July", "August", "September", "October", "November", "December"]











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
