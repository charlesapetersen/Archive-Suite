import Foundation
import UserNotifications

// MARK: - Collection Review Item

/// Represents a single file's classification and collection assignment for user review.
struct CollectionReviewItem: Identifiable {
    let id = UUID()
    let fileIndex: Int
    let fileName: String
    let fileURL: URL
    var classification: DocumentClassification?
    var collectionName: String
    /// Whether this item was identified as a box label (and thus defines a collection boundary)
    var isBoxLabel: Bool
}

// MARK: - Document Segment Review Item

/// Represents a single file's document_start/document_continuation classification for review.
struct DocumentReviewItem: Identifiable {
    let id = UUID()
    let fileIndex: Int
    let fileName: String
    let fileURL: URL
    var classification: DocumentClassification?
    var rotationDegrees: Int = 0
    /// User flagged this photo for removal during review (extraneous image).
    var markedForRemoval: Bool = false
}

// MARK: - Manual Tag Segment

/// One image shown in the manual tagging UI, with its corrected rotation. A context image
/// is the nearest preceding box/folder label — shown for orientation but NOT tagged.
struct ManualTagImage: Identifiable {
    let id = UUID()
    let url: URL
    let rotationDegrees: Int
    let isContext: Bool
}

// MARK: - Manual Segmentation + Tagging (fully human mode)

/// The kind of a photo in the manual segmentation UI. Box/folder photos are dividers that
/// receive only a color tag; documents are grouped into tagged segments.
enum ManualPhotoKind: Hashable { case document, box, folder
    var isBoxOrFolder: Bool { self != .document }
}

/// One image in the fully-manual segmentation UI. Rotation and kind are user-editable.
struct ManualSegImage: Identifiable {
    let id = UUID()
    let fileIndex: Int          // stable index into the run's `files`/`jobs` arrays — the key
    let url: URL
    var rotationDegrees: Int
    var kind: ManualPhotoKind
}

/// A document segment the user has identified and tagged. Its pages drop out of the viewer.
struct CompletedManualSegment: Identifiable {
    let id = UUID()
    let indices: [Int]          // ordered indices into `manualSegImages`; first is the segment start
    var tags: SegmentTagData
}

/// Date + subject tags the user enters for one manually-defined segment. (The trailing "Unread"
/// tag is added automatically by `MacOSTagger.applyTags` in stamping modes, so it is not seeded here.)
struct SegmentTagData {
    var year: String = ""
    var month: String = ""      // "MM Month"
    var day: String = ""        // "Day D"
    var dateUncertain: Bool = false
    var subjectTags: [String] = []
}

/// One document segment presented for manual/human tagging (feature 6).
struct ManualTagSegment: Identifiable {
    let id = UUID()
    /// Index into the processor's `segments` array.
    let segmentIndex: Int
    /// Images to display: an optional leading box/folder context image, then the segment pages.
    let images: [ManualTagImage]
    // Editable date fields
    var year: String = ""
    var month: String = ""      // "MM Month", e.g. "03 March"
    var day: String = ""        // "Day D", e.g. "Day 15"
    var dateUncertain: Bool = false
    var subjectTags: [String] = []
    /// True while the auto-date LLM prefetch for this segment is still in flight.
    var dateLoading: Bool = false
}

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
    /// The active run's rotation mode, readable from the nonisolated OCR call. Only one run
    /// executes at a time, so a static is safe here.
    nonisolated(unsafe) static var rotationModeForRun: RotationMode = .localVision

    /// The "standard" image size (MB) the resolution slider targets. Set once per run from Settings.
    nonisolated(unsafe) static var standardImageMB: Double = 3.0

    /// Parallel OCR workers for the batch run (user-configurable in Settings, 1–12). Set once per run.
    nonisolated(unsafe) static var ocrWorkerCount: Int = 4

    /// Load run-time knobs from UserDefaults (standard size default 3 MB, OCR workers default 4) —
    /// call at run start.
    static func loadStandardImageMB() {
        let v = UserDefaults.standard.double(forKey: "standardImageSizeMB")
        standardImageMB = v > 0 ? v : 3.0
        let w = UserDefaults.standard.integer(forKey: "ocrWorkerCount")
        ocrWorkerCount = w > 0 ? min(12, w) : 4
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
    private var collectionConfirmationContinuation: CheckedContinuation<Void, Never>?

    /// Document segmentation review state
    @Published var documentReviewItems: [DocumentReviewItem] = []
    @Published var awaitingDocumentReview = false
    @Published var currentReviewCollectionName: String = ""
    /// Whether the document review sheet should offer New-Document / Continuation options
    /// (only meaningful when merging or tagging by segment).
    @Published var reviewShowsDocumentClasses = true
    private var documentReviewContinuation: CheckedContinuation<Void, Never>?

    /// Final box/folder confirmation review state (shown after document segmentation review)
    @Published var boxFolderConfirmItems: [DocumentReviewItem] = []
    @Published var awaitingBoxFolderConfirmation = false
    private var boxFolderConfirmContinuation: CheckedContinuation<Void, Never>?

    /// Manual (human) tagging review state — sequential, one segment at a time (autoDate mode)
    @Published var manualTagSegments: [ManualTagSegment] = []
    @Published var currentManualIndex = 0
    @Published var awaitingManualTagging = false
    private var manualTaggingContinuation: CheckedContinuation<Void, Never>?

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
    private var manualSegPreOCRed = false
    private var manualSegContinuation: CheckedContinuation<Void, Never>?
    // LLM params captured for on-demand date fetching during manual segmentation.
    private var manualSegProvider: LLMProvider = .gemini
    private var manualSegModel: LLMModel?
    private var manualSegThinking: ThinkingLevel?
    private var manualSegApiKey: String = ""

    /// Interactive workflow pause states
    @Published var awaitingFinalReview = false           // After tagging, before completion
    enum FinalReviewAction { case complete, redoTagging }
    private var finalReviewContinuation: CheckedContinuation<FinalReviewAction, Never>?

    /// Retry dialog state
    enum RetryAction {
        case retry(provider: LLMProvider, model: LLMModel, thinkingLevel: ThinkingLevel?, apiKey: String)
        case continueWithout
    }
    @Published var failedFileIndices: [Int] = []
    @Published var awaitingRetryDecision = false
    private var retryContinuation: CheckedContinuation<RetryAction, Never>?

    /// Maps source image URL → output PDF URL (for tagging the output, not the source)
    var outputURLMap: [URL: URL] = [:]
    /// Maps original PDF source URL → temporary JPEG URL (for cleanup)
    private var pdfToImageMap: [URL: URL] = [:]
    /// The model used for the current processing run (for PDF regeneration headers)
    private var currentModel: LLMModel?
    /// Gateway configuration for the current run (nil = direct API mode)
    private var currentGateway: GatewayConfig?
    var processingTask: Task<Void, Never>?

    /// Stored batch context for cancellation
    private struct BatchContext: Sendable {
        let batchId: String
        let apiKey: String
        let model: LLMModel
        let thinkingLevel: ThinkingLevel?
        let provider: LLMProvider
    }
    private var activeBatch: BatchContext?

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

        init(batchId: String, provider: LLMProvider, model: LLMModel, thinkingLevel: ThinkingLevel?,
             fileURLs: [URL], outputDirectory: URL, enableTagging: Bool,
             enableCollectionSegmentation: Bool = false, sendPreviousImage: Bool, submittedAt: Date,
             enableSegmentJSON: Bool = true, confirmCollectionIDs: Bool = false,
             reviewDocumentSegmentation: Bool = false, customPrompt: String? = nil) {
            self.batchId = batchId; self.provider = provider; self.model = model
            self.thinkingLevel = thinkingLevel; self.fileURLs = fileURLs
            self.outputDirectory = outputDirectory; self.enableTagging = enableTagging
            self.enableCollectionSegmentation = enableCollectionSegmentation
            self.sendPreviousImage = sendPreviousImage; self.submittedAt = submittedAt
            self.enableSegmentJSON = enableSegmentJSON
            self.confirmCollectionIDs = confirmCollectionIDs
            self.reviewDocumentSegmentation = reviewDocumentSegmentation
            self.customPrompt = customPrompt
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
        }
    }

    private static var pendingBatchURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("ArchiveProcessor")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pending_batch.json")
    }

    private static func savePendingBatch(_ batch: PendingBatch) {
        guard let data = try? JSONEncoder().encode(batch) else { return }
        try? data.write(to: pendingBatchURL)
    }

    private static func loadPendingBatch() -> PendingBatch? {
        guard let data = try? Data(contentsOf: pendingBatchURL) else { return nil }
        return try? JSONDecoder().decode(PendingBatch.self, from: data)
    }

    private static func deletePendingBatch() {
        try? FileManager.default.removeItem(at: pendingBatchURL)
    }

    /// File URLs from a pending batch (for populating the file list on resume).
    var pendingBatchFileURLs: [URL]? {
        Self.loadPendingBatch()?.fileURLs
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

    private static var pendingRunURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("ArchiveProcessor")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pending_run.json")
    }

    private static func savePendingRun(_ run: PendingRun) {
        guard let data = try? JSONEncoder().encode(run) else { return }
        try? data.write(to: pendingRunURL)
    }

    private static func loadPendingRun() -> PendingRun? {
        guard let data = try? Data(contentsOf: pendingRunURL) else { return nil }
        return try? JSONDecoder().decode(PendingRun.self, from: data)
    }

    private static func deletePendingRun() {
        try? FileManager.default.removeItem(at: pendingRunURL)
    }

    /// Tracks the active non-batch run for incremental saves. Nil when not running.
    private var activePendingRun: PendingRun?

    /// Save a completed OCR result to the pending run on disk.
    private func saveResultToPendingRun(index: Int, result: OCRResult) {
        guard var run = activePendingRun else { return }
        run.completedResults["\(index)"] = result
        activePendingRun = run
        Self.savePendingRun(run)
    }

    /// File URLs from a pending run (for populating the file list on resume).
    var pendingRunFileURLs: [URL]? {
        Self.loadPendingRun()?.fileURLs
    }

    @Published var pendingRunInfo: String?

    /// Check for persisted pending batch or run on launch.
    func checkForPendingBatch() {
        // Check for pending batch
        if let pending = Self.loadPendingBatch() {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            let dateStr = formatter.string(from: pending.submittedAt)
            pendingBatchInfo = "Pending batch from \(dateStr): \(pending.fileURLs.count) files via \(pending.provider.rawValue) \(pending.model.displayName)."
        } else {
            pendingBatchInfo = nil
        }

        // Check for pending run
        if let pending = Self.loadPendingRun() {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            let dateStr = formatter.string(from: pending.startedAt)
            let completed = pending.completedResults.count
            let total = pending.fileURLs.count
            pendingRunInfo = "Interrupted run from \(dateStr): \(completed)/\(total) files completed via \(pending.provider.rawValue) \(pending.model.displayName)."
        } else {
            pendingRunInfo = nil
        }
    }

    /// Dismiss a pending batch notification (deletes local state only — server-side batch continues).
    func dismissPendingBatch() {
        Self.deletePendingBatch()
        pendingBatchInfo = nil
    }

    /// Dismiss a pending run notification.
    func dismissPendingRun() {
        Self.deletePendingRun()
        pendingRunInfo = nil
    }

    /// Resume polling a previously submitted batch.
    func resumeBatch(apiKey: String) async {
        guard let pending = Self.loadPendingBatch() else { return }

        isProcessing = true
        pendingBatchInfo = nil
        failedFiles = []
        segments = []
        collectionSegments = []
        outputURLMap = [:]
        currentModel = pending.model
        jobs = pending.fileURLs.map { OCRJob(sourceURL: $0) }
        for i in jobs.indices { jobs[i].status = .processing }
        progress = 0
        statusMessage = "Resuming batch…"

        activeBatch = BatchContext(
            batchId: pending.batchId, apiKey: apiKey,
            model: pending.model, thinkingLevel: pending.thinkingLevel,
            provider: pending.provider
        )

        await pollBatchUntilComplete(
            batchId: pending.batchId, provider: pending.provider,
            model: pending.model, thinkingLevel: pending.thinkingLevel,
            apiKey: apiKey, fileURLs: pending.fileURLs,
            outputDirectory: pending.outputDirectory
        )

        Self.deletePendingBatch()
        activeBatch = nil

        guard !Task.isCancelled else { return }

        await retryHighUseFailures(
            fileURLs: pending.fileURLs, provider: pending.provider,
            model: pending.model, thinkingLevel: pending.thinkingLevel,
            apiKey: apiKey, outputDirectory: pending.outputDirectory
        )

        guard !Task.isCancelled else { return }

        await retryLoopForFailedFiles(
            imageURLs: pending.fileURLs,
            outputDirectory: pending.outputDirectory
        )

        guard !Task.isCancelled else { return }

        // Tagging (before collection segmentation, matching main workflow order)
        if pending.enableTagging && !passSourceTags {
            statusMessage = "Segmenting documents…"
            let segmenter = DocumentSegmenter()
            let classifications = jobs.map { $0.result?.classification }
            let texts = jobs.map { $0.result?.text ?? "" }
            segments = segmenter.segment(files: pending.fileURLs, classifications: classifications, texts: texts)
            statusMessage = "Found \(segments.count) segments. Generating tags…"

            await performTaggingPhase(
                provider: pending.provider, model: pending.model,
                thinkingLevel: pending.thinkingLevel, apiKey: apiKey,
                outputDirectory: pending.outputDirectory,
                enableSegmentJSON: pending.enableSegmentJSON
            )
        }

        guard !Task.isCancelled else { return }

        // Collection segmentation (after tagging)
        if pending.enableCollectionSegmentation {
            await performCollectionSegmentation(
                files: pending.fileURLs,
                provider: pending.provider,
                model: pending.model,
                thinkingLevel: pending.thinkingLevel,
                apiKey: apiKey,
                outputDirectory: pending.outputDirectory,
                confirmBeforeOrganizing: pending.confirmCollectionIDs,
                reviewDocumentSegmentation: pending.reviewDocumentSegmentation
            )

            applyBoxFolderLabelTags(enableTagging: pending.enableTagging)
        }

        guard !Task.isCancelled else { return }

        if mergeDocuments {
            performDocumentMerging(files: pending.fileURLs, outputDirectory: pending.outputDirectory)
        }

        // Organize into collection folders (after merge so merged PDFs get moved)
        if pending.enableCollectionSegmentation && !collectionSegments.isEmpty {
            let segmenter = CollectionSegmenter()
            statusMessage = "Organizing \(collectionSegments.count) collections into folders…"
            do {
                try segmenter.organizeOutput(
                    collections: collectionSegments,
                    outputDirectory: pending.outputDirectory,
                    outputURLMap: outputURLMap
                )
                statusMessage = "Collections organized into \(collectionSegments.count) folders."
            } catch {
                statusMessage = "Error organizing collections: \(error.localizedDescription)"
            }
        }

        guard !Task.isCancelled else { return }
        writeLogFile(outputDirectory: pending.outputDirectory)
        isProcessing = false
        let succeeded = jobs.filter { $0.status == .succeeded }.count
        statusMessage = "Done. \(succeeded) succeeded, \(failedFiles.count) failed."
        if pending.enableTagging && !passSourceTags {
            statusMessage += " \(segments.count) segments tagged."
        }
        if passSourceTags {
            statusMessage += " Source tags copied."
        }
        if pending.enableCollectionSegmentation && !collectionSegments.isEmpty {
            statusMessage += " \(collectionSegments.count) collections organized."
        }
        postCompletionNotification()
    }

    /// Resume an interrupted non-batch run.
    func resumeRun(apiKey: String) async {
        guard let pending = Self.loadPendingRun() else { return }

        isProcessing = true
        pendingRunInfo = nil
        failedFiles = []
        segments = []
        collectionSegments = []
        outputURLMap = [:]
        pdfToImageMap = [:]
        currentModel = pending.model
        currentGateway = pending.gatewayConfig
        // Restore the run-time knobs the OCR call reads (startProcessing sets these; resume must too,
        // or OCR falls back to the default Local Vision rotation — which stalls the parallel workers).
        Self.rotationModeForRun = rotationMode
        Self.loadStandardImageMB()
        removedSourceURLs = []
        jobs = pending.fileURLs.map { OCRJob(sourceURL: $0) }
        progress = 0

        // Restore the pending run tracker for incremental saves
        activePendingRun = pending

        let segmentationContext = SegmentationContext(
            previousTextCharCount: pending.previousTextCharCount,
            sendPreviousImage: pending.sendPreviousImage,
            customPrompt: pending.customPrompt
        )

        // Convert any PDF inputs
        let imageURLs = convertPDFInputs(pending.fileURLs)

        // Restore already-completed results. The original run already wrote these PDFs, so reuse
        // them when present and only regenerate genuinely-missing ones — off the main actor, since
        // embedding full-resolution images is heavy (this was causing a beachball on resume).
        let completedCount = pending.completedResults.count
        if completedCount > 0 {
            statusMessage = "Restoring \(completedCount) previously completed results…"
            let fm = FileManager.default
            // Gather on the main actor.
            var restores: [(index: Int, result: OCRResult, sourceURL: URL, outputURL: URL)] = []
            var toGenerate: [(imageURL: URL, outputURL: URL, fileName: String, result: OCRResult)] = []
            for (key, result) in pending.completedResults {
                guard let index = Int(key), index < jobs.count, index < imageURLs.count else { continue }
                let sourceURL = jobs[index].sourceURL
                let baseName = sourceURL.deletingPathExtension().lastPathComponent
                let outputURL = pending.outputDirectory.appendingPathComponent(baseName + ".pdf")
                restores.append((index, result, sourceURL, outputURL))
                if !fm.fileExists(atPath: outputURL.path) {
                    toGenerate.append((imageURLs[index], outputURL, sourceURL.lastPathComponent, result))
                }
            }
            // Regenerate only missing PDFs, off the main thread.
            if !toGenerate.isEmpty {
                let model = pending.model
                let gatewayName = currentGateway?.displayName
                statusMessage = "Rebuilding \(toGenerate.count) missing PDF\(toGenerate.count == 1 ? "" : "s")…"
                await Task.detached(priority: .utility) {
                    let gen = PDFGenerator()
                    for g in toGenerate {
                        try? gen.generate(imageURL: g.imageURL, result: g.result, model: model,
                                          outputURL: g.outputURL, originalFileName: g.fileName,
                                          gatewayDisplayName: gatewayName)
                    }
                }.value
            }
            // Apply the (cheap) state updates back on the main actor.
            for r in restores {
                jobs[r.index].result = r.result
                jobs[r.index].classification = r.result.classification
                jobs[r.index].status = r.result.text != nil ? .succeeded : .failed
                if r.result.text == nil { failedFiles.append(r.sourceURL.lastPathComponent) }
                outputURLMap[r.sourceURL] = r.outputURL
                if passSourceTags {
                    let sourceTags = MacOSTagger.readTags(from: r.sourceURL)
                    if !sourceTags.isEmpty {
                        try? MacOSTagger.applyTags(sourceTags, to: r.outputURL)
                        jobs[r.index].appliedTags = sourceTags
                    }
                }
            }
            let total = pending.fileURLs.count
            progress = Double(completedCount) / Double(total) * 0.7
            statusMessage = "Restored \(completedCount)/\(total). Resuming OCR…"
        }

        // Run OCR only on files that were NOT already completed
        let remainingIndices = (0..<pending.fileURLs.count).filter {
            pending.completedResults["\($0)"] == nil
        }

        if !remainingIndices.isEmpty {
            if pending.preOCRedInput {
                // For pre-OCRed, run the full pipeline (it's text extraction + classification, cheap)
                await performPreOCRedProcessing(
                    files: pending.fileURLs,
                    provider: pending.provider,
                    model: pending.model,
                    thinkingLevel: pending.thinkingLevel,
                    apiKey: apiKey,
                    outputDirectory: pending.outputDirectory,
                    enableTagging: pending.enableTagging,
                    enableSegmentJSON: pending.enableSegmentJSON,
                    enableCollectionSegmentation: pending.enableCollectionSegmentation,
                    confirmCollectionIDs: pending.confirmCollectionIDs,
                    reviewDocumentSegmentation: pending.reviewDocumentSegmentation,
                    customPrompt: pending.customPrompt
                )
                // Pre-OCRed path handles its own post-processing; skip to finalization
                activePendingRun = nil
                Self.deletePendingRun()
                pendingRunInfo = nil
                guard !Task.isCancelled else { return }
                writeLogFile(outputDirectory: pending.outputDirectory)
                isProcessing = false
                let succeeded = jobs.filter { $0.status == .succeeded }.count
                statusMessage = "Done. \(succeeded) succeeded, \(failedFiles.count) failed."
                postCompletionNotification()
                return
            }

            // Resume OCR for remaining files
            await performOCRPhaseForIndices(
                indices: remainingIndices,
                fileURLs: imageURLs,
                provider: pending.provider,
                model: pending.model,
                thinkingLevel: pending.thinkingLevel,
                apiKey: apiKey,
                outputDirectory: pending.outputDirectory,
                segmentationContext: segmentationContext,
                totalFiles: pending.fileURLs.count,
                alreadyCompleted: completedCount
            )
        }

        guard !Task.isCancelled else { cleanupTempFiles(); return }

        // Retry high-use failures
        await retryHighUseFailures(
            fileURLs: imageURLs,
            provider: pending.provider,
            model: pending.model,
            thinkingLevel: pending.thinkingLevel,
            apiKey: apiKey,
            outputDirectory: pending.outputDirectory
        )

        guard !Task.isCancelled else { cleanupTempFiles(); return }

        // Interactive retry
        await retryLoopForFailedFiles(
            imageURLs: imageURLs,
            outputDirectory: pending.outputDirectory
        )

        guard !Task.isCancelled else { cleanupTempFiles(); return }

        // Tagging (mode-dependent), matching the main workflow — not always automatic.
        if pending.enableTagging && !passSourceTags {
            statusMessage = "Segmenting documents…"
            let segmenter = DocumentSegmenter()
            let classifications = jobs.map { $0.result?.classification }
            let texts = jobs.map { $0.result?.text ?? "" }
            segments = segmenter.segment(files: pending.fileURLs, classifications: classifications, texts: texts)
            statusMessage = "Found \(segments.count) segments. Tagging…"

            switch taggingMode {
            case .automatic:
                await performAutomaticTaggingWithReview(
                    provider: pending.provider, model: pending.model, thinkingLevel: pending.thinkingLevel,
                    apiKey: apiKey, outputDirectory: pending.outputDirectory,
                    enableSegmentJSON: pending.enableSegmentJSON, files: pending.fileURLs
                )
            case .autoDate:
                await performManualTaggingPhase(
                    mode: taggingMode, provider: pending.provider, model: pending.model,
                    thinkingLevel: pending.thinkingLevel, apiKey: apiKey,
                    outputDirectory: pending.outputDirectory, enableSegmentJSON: pending.enableSegmentJSON
                )
            case .human, .autoDateManualSeg:
                await performManualSegmentAndTag(
                    autoDate: taggingMode.autoFillsDate,
                    provider: pending.provider, model: pending.model, thinkingLevel: pending.thinkingLevel,
                    apiKey: apiKey, outputDirectory: pending.outputDirectory,
                    enableSegmentJSON: pending.enableSegmentJSON,
                    preOCRed: pending.preOCRedInput, files: pending.fileURLs
                )
            case .none, .copySource:
                break
            }
        }

        guard !Task.isCancelled else { cleanupTempFiles(); return }

        // Collection segmentation (after tagging)
        if pending.enableCollectionSegmentation {
            await performCollectionSegmentation(
                files: pending.fileURLs,
                provider: pending.provider,
                model: pending.model,
                thinkingLevel: pending.thinkingLevel,
                apiKey: apiKey,
                outputDirectory: pending.outputDirectory,
                confirmBeforeOrganizing: pending.confirmCollectionIDs,
                reviewDocumentSegmentation: pending.reviewDocumentSegmentation
            )

            applyBoxFolderLabelTags(enableTagging: pending.enableTagging)
        }

        guard !Task.isCancelled else { cleanupTempFiles(); return }

        if mergeDocuments {
            performDocumentMerging(files: pending.fileURLs, outputDirectory: pending.outputDirectory)
        }

        // Organize into collection folders (after merge so merged PDFs get moved)
        if pending.enableCollectionSegmentation && !collectionSegments.isEmpty {
            let segmenter = CollectionSegmenter()
            statusMessage = "Organizing \(collectionSegments.count) collections into folders…"
            do {
                try segmenter.organizeOutput(
                    collections: collectionSegments,
                    outputDirectory: pending.outputDirectory,
                    outputURLMap: outputURLMap
                )
                statusMessage = "Collections organized into \(collectionSegments.count) folders."
            } catch {
                statusMessage = "Error organizing collections: \(error.localizedDescription)"
            }
        }

        cleanupTempFiles()

        guard !Task.isCancelled else { return }

        activePendingRun = nil
        Self.deletePendingRun()
        pendingRunInfo = nil

        writeLogFile(outputDirectory: pending.outputDirectory)
        isProcessing = false
        let succeeded = jobs.filter { $0.status == .succeeded }.count
        statusMessage = "Done. \(succeeded) succeeded, \(failedFiles.count) failed."
        if pending.enableTagging && !passSourceTags {
            statusMessage += " \(segments.count) segments tagged."
        }
        if passSourceTags {
            statusMessage += " Source tags copied."
        }
        if pending.enableCollectionSegmentation && !collectionSegments.isEmpty {
            statusMessage += " \(collectionSegments.count) collections organized."
        }
        postCompletionNotification()
    }

    /// Applies Red/Purple color tags to box/folder label PDFs when full LLM tagging
    /// is disabled (or when passing source tags through). When automatic tagging is enabled
    /// these tags are already applied by the normal tagging pass, so this is a no-op.
    private func applyBoxFolderLabelTags(enableTagging: Bool) {
        guard !enableTagging || passSourceTags else { return }
        applyBoxFolderLabelTagsUnconditionally()
    }

    /// Applies Red/Purple color tags to every box/folder label output PDF, unconditionally.
    /// Used by manual tagging modes, which don't run the automatic tagging pass.
    private func applyBoxFolderLabelTagsUnconditionally() {
        for job in jobs {
            guard let classification = job.result?.classification else { continue }
            let tags: GeneratedTags
            switch classification {
            case .boxLabel: tags = GeneratedTags(subjectTags: ["Box"], colorTag: "Red")
            case .folderLabel: tags = GeneratedTags(subjectTags: ["Folder"], colorTag: "Purple")
            default: continue
            }
            if let outputPDF = outputURLMap[job.sourceURL] {
                try? MacOSTagger.applyTags(tags, to: outputPDF)
            }
        }
    }

    /// Restore a previously completed result without re-saving to pending run.
    private func handleRestoredResult(_ result: OCRResult, index: Int, url: URL, model: LLMModel, outputDirectory: URL) {
        guard index >= 0 && index < jobs.count else {
            print("handleRestoredResult: index \(index) out of range (jobs.count = \(jobs.count))")
            return
        }
        let sourceURL = jobs[index].sourceURL
        jobs[index].result = result
        jobs[index].classification = result.classification
        jobs[index].status = result.text != nil ? .succeeded : .failed
        if result.text == nil {
            failedFiles.append(sourceURL.lastPathComponent)
        }
        let pdfGen = PDFGenerator()
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let outputURL = outputDirectory.appendingPathComponent(baseName + ".pdf")
        try? pdfGen.generate(imageURL: url, result: result, model: model, outputURL: outputURL, originalFileName: sourceURL.lastPathComponent, gatewayDisplayName: currentGateway?.displayName)
        outputURLMap[sourceURL] = outputURL
        // Copy source tags to output PDF if pass-through mode is enabled
        if passSourceTags {
            let sourceTags = MacOSTagger.readTags(from: sourceURL)
            if !sourceTags.isEmpty {
                try? MacOSTagger.applyTags(sourceTags, to: outputURL)
                jobs[index].appliedTags = sourceTags
            }
        }
    }

    /// OCR only specific file indices (for resuming interrupted runs).
    private func performOCRPhaseForIndices(
        indices: [Int],
        fileURLs: [URL],
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        outputDirectory: URL,
        segmentationContext: SegmentationContext,
        totalFiles: Int,
        alreadyCompleted: Int
    ) async {
        let remaining = indices.count
        let gateway = currentGateway

        if segmentationContext.previousTextCharCount == 0 {
            // Parallel: OCR only the remaining indices
            var completed = 0
            let concurrency = max(1, Self.ocrWorkerCount)
            for i in indices { jobs[i].status = .processing }
            statusMessage = "OCR 0/\(remaining) remaining… (parallel)"

            await withTaskGroup(of: (Int, OCRResult).self) { group in
                var nextSlot = 0

                for _ in 0..<min(concurrency, remaining) {
                    let index = indices[nextSlot]
                    let url = fileURLs[index]
                    let prevImageURL = (segmentationContext.sendPreviousImage && index > 0) ? fileURLs[index - 1] : nil
                    nextSlot += 1
                    let scale = segmentationContext.imageScale
                    group.addTask {
                        let result = await Self.performOCRCall(
                            imageURL: url, provider: provider, model: model,
                            thinkingLevel: thinkingLevel, apiKey: apiKey,
                            previousText: nil, previousImageURL: prevImageURL,
                            customPrompt: segmentationContext.customPrompt,
                            imageScale: scale,
                            gatewayConfig: gateway
                        )
                        return (index, result)
                    }
                }

                for await (index, result) in group {
                    guard !Task.isCancelled else { group.cancelAll(); return }
                    handleOCRResult(result, index: index, url: fileURLs[index], model: model, outputDirectory: outputDirectory)
                    completed += 1
                    progress = Double(alreadyCompleted + completed) / Double(totalFiles) * 0.7
                    statusMessage = "OCR \(alreadyCompleted + completed)/\(totalFiles) complete (parallel)"

                    if nextSlot < remaining {
                        let idx = indices[nextSlot]
                        let url = fileURLs[idx]
                        let prevImageURL = (segmentationContext.sendPreviousImage && idx > 0) ? fileURLs[idx - 1] : nil
                        nextSlot += 1
                        let scale = segmentationContext.imageScale
                        group.addTask {
                            let result = await Self.performOCRCall(
                                imageURL: url, provider: provider, model: model,
                                thinkingLevel: thinkingLevel, apiKey: apiKey,
                                previousText: nil, previousImageURL: prevImageURL,
                                customPrompt: segmentationContext.customPrompt,
                                imageScale: scale,
                                gatewayConfig: gateway
                            )
                            return (idx, result)
                        }
                    }
                }
            }
        } else {
            // Sequential: OCR remaining indices, using previous results for context
            for (attempt, index) in indices.enumerated() {
                guard !Task.isCancelled else { return }
                let url = fileURLs[index]
                jobs[index].status = .processing

                let previousText: String?
                if index > 0, let prevResult = jobs[index - 1].result, segmentationContext.previousTextCharCount > 0 {
                    previousText = prevResult.text.flatMap { String($0.suffix(segmentationContext.previousTextCharCount)) }
                } else {
                    previousText = nil
                }
                let contextImageURL = segmentationContext.sendPreviousImage && index > 0 ? fileURLs[index - 1] : nil

                statusMessage = "OCR \(alreadyCompleted + attempt + 1)/\(totalFiles)…"
                var result = await Self.performOCRCall(
                    imageURL: url, provider: provider, model: model,
                    thinkingLevel: thinkingLevel, apiKey: apiKey,
                    previousText: previousText, previousImageURL: contextImageURL,
                    customPrompt: segmentationContext.customPrompt,
                    imageScale: segmentationContext.imageScale,
                    gatewayConfig: gateway
                )

                if Self.isTimeoutError(result) {
                    statusMessage = "OCR \(alreadyCompleted + attempt + 1)/\(totalFiles)… retrying after timeout"
                    result = await Self.performOCRCall(
                        imageURL: url, provider: provider, model: model,
                        thinkingLevel: thinkingLevel, apiKey: apiKey,
                        previousText: nil, previousImageURL: nil,
                        customPrompt: segmentationContext.customPrompt,
                        imageScale: segmentationContext.imageScale,
                        gatewayConfig: gateway
                    )
                }

                handleOCRResult(result, index: index, url: url, model: model, outputDirectory: outputDirectory)
                progress = Double(alreadyCompleted + attempt + 1) / Double(totalFiles) * 0.7
                statusMessage = "OCR \(alreadyCompleted + attempt + 1)/\(totalFiles) complete"
            }
        }
    }

    func cancel() {
        processingTask?.cancel()
        processingTask = nil
        isProcessing = false
        awaitingFinalReview = false
        awaitingDocumentReview = false
        awaitingCollectionConfirmation = false
        awaitingRetryDecision = false
        documentReviewContinuation?.resume()
        documentReviewContinuation = nil
        finalReviewContinuation?.resume(returning: .complete)
        finalReviewContinuation = nil
        collectionConfirmationContinuation?.resume()
        collectionConfirmationContinuation = nil
        retryContinuation?.resume(returning: .continueWithout)
        retryContinuation = nil
        cleanupTempFiles()

        // Cancel server-side batch if active
        if let batch = activeBatch {
            activeBatch = nil
            Self.deletePendingBatch()
            Task {
                switch batch.provider {
                case .anthropic:
                    let client = AnthropicBatchClient(apiKey: batch.apiKey, model: batch.model, thinkingLevel: batch.thinkingLevel)
                    await client.cancelBatch(batchId: batch.batchId)
                case .mistral:
                    let client = MistralBatchClient(apiKey: batch.apiKey, model: batch.model)
                    await client.cancelBatch(batchId: batch.batchId)
                case .gemini:
                    let client = GeminiBatchClient(apiKey: batch.apiKey, model: batch.model, thinkingLevel: batch.thinkingLevel)
                    for singleId in batch.batchId.components(separatedBy: ",") {
                        await client.cancelBatch(batchName: singleId)
                    }
                }
            }
        }

        // If a non-batch run was active, keep the pending run file for resume
        if activePendingRun != nil {
            activePendingRun = nil
            // Refresh the pending run info banner
            checkForPendingBatch()
        }

        let succeeded = jobs.filter { $0.status == .succeeded }.count
        let pending = jobs.filter { $0.status == .processing || $0.status == .pending }.count
        statusMessage = "Cancelled. \(succeeded) succeeded, \(failedFiles.count) failed, \(pending) skipped."
        // Mark any still-processing jobs as failed
        for i in jobs.indices where jobs[i].status == .processing {
            jobs[i].status = .failed
        }
    }

    func startProcessing(
        files: [URL],
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        outputDirectory: URL,
        batchMode: Bool,
        enableTagging: Bool,
        enableSegmentJSON: Bool = true,
        enableCollectionSegmentation: Bool = false,
        confirmCollectionIDs: Bool = false,
        reviewDocumentSegmentation: Bool = false,
        preOCRedInput: Bool = false,
        segmentationContext: SegmentationContext,
        gatewayConfig: GatewayConfig? = nil
    ) async {
        guard !files.isEmpty else { return }
        isProcessing = true
        failedFiles = []
        segments = []
        collectionSegments = []
        outputURLMap = [:]
        pdfToImageMap = [:]
        removedSourceURLs = []
        Self.rotationModeForRun = rotationMode
        Self.loadStandardImageMB()
        currentModel = model
        currentGateway = gatewayConfig
        jobs = files.map { OCRJob(sourceURL: $0) }
        progress = 0

        if preOCRedInput {
            // --- Pre-OCRed PDF path: extract text, classify, skip PDF generation ---
            await performPreOCRedProcessing(
                files: files,
                provider: provider,
                model: model,
                thinkingLevel: thinkingLevel,
                apiKey: apiKey,
                outputDirectory: outputDirectory,
                enableTagging: enableTagging,
                enableSegmentJSON: enableSegmentJSON,
                enableCollectionSegmentation: enableCollectionSegmentation,
                confirmCollectionIDs: confirmCollectionIDs,
                reviewDocumentSegmentation: reviewDocumentSegmentation,
                customPrompt: segmentationContext.customPrompt
            )
        } else {
            // --- Standard image OCR path ---
            statusMessage = "Starting OCR…"

            // Convert any PDF inputs to temporary JPEG images
            let imageURLs = convertPDFInputs(files)

            // Phase 1: OCR + Classification
            if batchMode && provider.supportsBatch {
                await performBatchOCR(
                    fileURLs: imageURLs,
                    provider: provider,
                    model: model,
                    thinkingLevel: thinkingLevel,
                    apiKey: apiKey,
                    outputDirectory: outputDirectory,
                    sendPreviousImage: segmentationContext.sendPreviousImage,
                    enableTagging: enableTagging,
                    enableCollectionSegmentation: enableCollectionSegmentation,
                    enableSegmentJSON: enableSegmentJSON,
                    confirmCollectionIDs: confirmCollectionIDs,
                    reviewDocumentSegmentation: reviewDocumentSegmentation,
                    customPrompt: segmentationContext.customPrompt,
                    imageScale: segmentationContext.imageScale
                )
            } else {
                // Create pending run for resume-after-restart
                activePendingRun = PendingRun(
                    provider: provider, model: model, thinkingLevel: thinkingLevel,
                    fileURLs: files, outputDirectory: outputDirectory,
                    enableTagging: enableTagging, enableSegmentJSON: enableSegmentJSON,
                    enableCollectionSegmentation: enableCollectionSegmentation,
                    confirmCollectionIDs: confirmCollectionIDs,
                    reviewDocumentSegmentation: reviewDocumentSegmentation,
                    preOCRedInput: false,
                    previousTextCharCount: segmentationContext.previousTextCharCount,
                    sendPreviousImage: segmentationContext.sendPreviousImage,
                    customPrompt: segmentationContext.customPrompt,
                    startedAt: Date(), gatewayConfig: gatewayConfig,
                    completedResults: [:]
                )
                Self.savePendingRun(activePendingRun!)

                await performOCRPhase(
                    fileURLs: imageURLs,
                    provider: provider,
                    model: model,
                    thinkingLevel: thinkingLevel,
                    apiKey: apiKey,
                    outputDirectory: outputDirectory,
                    segmentationContext: segmentationContext
                )
            }

            guard !Task.isCancelled else { cleanupTempFiles(); return }

            // Phase 1b: Retry files that failed due to high use
            await retryHighUseFailures(
                fileURLs: imageURLs,
                provider: provider,
                model: model,
                thinkingLevel: thinkingLevel,
                apiKey: apiKey,
                outputDirectory: outputDirectory
            )

            guard !Task.isCancelled else { cleanupTempFiles(); return }

            // Phase 1c: Prompt user to retry remaining failures with different provider/model
            await retryLoopForFailedFiles(
                imageURLs: imageURLs,
                outputDirectory: outputDirectory
            )

            guard !Task.isCancelled else { cleanupTempFiles(); return }

            // Segmentation: pre-grouped from Live Capture, else the interactive LLM review.
            if preGroupedBoundaries.count == files.count && !files.isEmpty {
                // Groups were defined on the phone — apply them directly, skip LLM segmentation.
                applyPreGroupedClassifications(files: files)
                rebuildSegments(files: files)
            } else if taggingMode.usesManualSegmentationUI {
                // Manual modes: the combined segment+tag window owns rotation, box/folder, and
                // segmentation, so skip the separate review here (it rebuilds segments itself).
            } else if (enableTagging && !passSourceTags) || enableCollectionSegmentation {
                await showFullSegmentationReview(files: files)
                guard !Task.isCancelled else { cleanupTempFiles(); return }

                // Final confirmation of box/folder identifications
                await showBoxFolderConfirmation(files: files)
                guard !Task.isCancelled else { cleanupTempFiles(); return }

                // Rebuild segments from user-confirmed classifications (excluding removed files)
                rebuildSegments(files: files)
            }

            guard !Task.isCancelled else { cleanupTempFiles(); return }

            // Phase 2: Tagging (mode-dependent)
            if enableTagging && !passSourceTags {
                switch taggingMode {
                case .automatic:
                    await performAutomaticTaggingWithReview(
                        provider: provider, model: model, thinkingLevel: thinkingLevel,
                        apiKey: apiKey, outputDirectory: outputDirectory,
                        enableSegmentJSON: enableSegmentJSON, files: files
                    )
                case .autoDate:
                    await performManualTaggingPhase(
                        mode: taggingMode, provider: provider, model: model,
                        thinkingLevel: thinkingLevel, apiKey: apiKey,
                        outputDirectory: outputDirectory, enableSegmentJSON: enableSegmentJSON
                    )
                case .human, .autoDateManualSeg:
                    await performManualSegmentAndTag(
                        autoDate: taggingMode.autoFillsDate,
                        provider: provider, model: model, thinkingLevel: thinkingLevel, apiKey: apiKey,
                        outputDirectory: outputDirectory,
                        enableSegmentJSON: enableSegmentJSON, preOCRed: false, files: files
                    )
                case .none, .copySource:
                    break
                }
                guard !Task.isCancelled else { cleanupTempFiles(); return }
            }

            guard !Task.isCancelled else { cleanupTempFiles(); return }

            // Phase 3: Collection Segmentation + name review (after tagging review, last step before completion)
            if enableCollectionSegmentation {
                await performCollectionSegmentation(
                    files: files,
                    provider: provider,
                    model: model,
                    thinkingLevel: thinkingLevel,
                    apiKey: apiKey,
                    outputDirectory: outputDirectory,
                    confirmBeforeOrganizing: confirmCollectionIDs,
                    reviewDocumentSegmentation: false
                )

                applyBoxFolderLabelTags(enableTagging: enableTagging)
            }

            guard !Task.isCancelled else { cleanupTempFiles(); return }

            // Live Capture: layer per-page phone priority on top now that box/folder Red/Purple is
            // final, and before merge folds appliedTags into merged PDFs.
            applyCapturePriorityTags()

            // Live Capture dual output: write each original image next to its PDF (same base + tags),
            // before merge repoints outputURLMap and before organization moves files.
            await exportOriginalImages()

            // Phase 4: Merge multi-page documents (before collection organization moves files)
            if mergeDocuments {
                performDocumentMerging(files: files, outputDirectory: outputDirectory)
            }

            // Phase 5: Organize into collection folders (after merge so merged PDFs get moved)
            if enableCollectionSegmentation && !collectionSegments.isEmpty {
                let segmenter2 = CollectionSegmenter()
                statusMessage = "Organizing \(collectionSegments.count) collections into folders…"
                do {
                    try segmenter2.organizeOutput(
                        collections: collectionSegments,
                        outputDirectory: outputDirectory,
                        outputURLMap: outputURLMap
                    )
                    statusMessage = "Collections organized into \(collectionSegments.count) folders."
                } catch {
                    statusMessage = "Error organizing collections: \(error.localizedDescription)"
                }
            }

            cleanupTempFiles()
        }

        guard !Task.isCancelled else { return }

        // Clear pending run on successful completion
        activePendingRun = nil
        Self.deletePendingRun()
        pendingRunInfo = nil

        writeLogFile(outputDirectory: outputDirectory)
        isProcessing = false
        let succeeded = jobs.filter { $0.status == .succeeded }.count
        statusMessage = "Done. \(succeeded) succeeded, \(failedFiles.count) failed."
        if enableTagging && !passSourceTags {
            statusMessage += " \(segments.count) segments tagged."
        }
        if passSourceTags {
            statusMessage += " Source tags copied."
        }
        if enableCollectionSegmentation && !collectionSegments.isEmpty {
            statusMessage += " \(collectionSegments.count) collections organized."
        }
        postCompletionNotification()
    }

    // MARK: - PDF Input Conversion

    /// Convert any PDF files in the input list to temporary JPEG images.
    /// Returns a new array where PDF URLs have been replaced with temp JPEG URLs.
    /// Non-PDF files are returned unchanged. The jobs array still references the
    /// original source URLs for display and output naming.
    private func convertPDFInputs(_ files: [URL]) -> [URL] {
        var imageURLs = files
        var converted = 0
        for (i, url) in files.enumerated() {
            guard url.pathExtension.lowercased() == "pdf" else { continue }
            let imageURL = PDFToImageConverter.imageURL(for: url)
            if imageURL != url {
                pdfToImageMap[url] = imageURL
                imageURLs[i] = imageURL
                // Update the job's source to the temp image for API calls,
                // but keep the original URL in outputURLMap keyed by temp URL
                converted += 1
            }
        }
        if converted > 0 {
            statusMessage = "Converted \(converted) PDF\(converted == 1 ? "" : "s") to images…"
        }
        return imageURLs
    }

    /// Clean up temporary JPEG files created from PDF inputs.
    private func cleanupTempFiles() {
        for (_, tempURL) in pdfToImageMap {
            try? FileManager.default.removeItem(at: tempURL)
        }
        pdfToImageMap = [:]
    }

    // MARK: - Pre-OCRed PDF Processing

    private func performPreOCRedProcessing(
        files: [URL],
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        outputDirectory: URL,
        enableTagging: Bool,
        enableSegmentJSON: Bool = true,
        enableCollectionSegmentation: Bool,
        confirmCollectionIDs: Bool = false,
        reviewDocumentSegmentation: Bool = false,
        customPrompt: String? = nil
    ) async {
        let total = files.count
        statusMessage = "Extracting text from \(total) PDFs…"

        // Step 1: Extract text from PDFs (no API calls)
        for (index, url) in files.enumerated() {
            guard !Task.isCancelled else { return }
            jobs[index].status = .processing

            let extraction = PDFTextExtractor.extract(from: url)
            let result = OCRResult(
                text: extraction.text,
                classification: extraction.classification,
                errorMessage: extraction.text == nil ? "No text found in PDF" : nil,
                errorCode: nil
            )
            jobs[index].result = result
            jobs[index].classification = extraction.classification
            jobs[index].status = extraction.text != nil ? .succeeded : .failed
            if extraction.text == nil {
                failedFiles.append(url.lastPathComponent)
            }

            // Map the input PDF as the output (no new PDF generated)
            outputURLMap[url] = url

            progress = Double(index + 1) / Double(total) * 0.3
            statusMessage = "Extracted text \(index + 1)/\(total)"
        }

        guard !Task.isCancelled else { return }

        // Step 2: Classify files that lack classification (text-only LLM calls)
        let needsClassification = ((enableTagging && !passSourceTags) || enableCollectionSegmentation)
        let unclassifiedIndices = jobs.indices.filter {
            jobs[$0].result?.classification == nil && jobs[$0].result?.text != nil
        }

        if needsClassification && !unclassifiedIndices.isEmpty {
            statusMessage = "Classifying \(unclassifiedIndices.count) documents…"
            var previousText: String? = nil

            for (attempt, index) in unclassifiedIndices.enumerated() {
                guard !Task.isCancelled else { return }
                let text = jobs[index].result?.text ?? ""

                let prompt = OCRPrompt.buildClassificationOnly(text: text, previousText: previousText, customPrompt: customPrompt)
                let classification = await classifyViaLLM(
                    prompt: prompt, provider: provider, model: model,
                    thinkingLevel: thinkingLevel, apiKey: apiKey
                )

                jobs[index].classification = classification
                jobs[index].result = OCRResult(
                    text: jobs[index].result?.text,
                    classification: classification,
                    errorMessage: jobs[index].result?.errorMessage,
                    errorCode: nil
                )

                // Use this file's text as context for the next
                previousText = String(text.suffix(500))

                progress = 0.3 + Double(attempt + 1) / Double(unclassifiedIndices.count) * 0.2
                statusMessage = "Classified \(attempt + 1)/\(unclassifiedIndices.count)"
            }
        }

        guard !Task.isCancelled else { return }
        progress = 0.5

        // Interactive Review: document segmentation (rotation + classification) review. Manual
        // modes skip it — the combined segment+tag window owns rotation, box/folder, and segmentation.
        if taggingMode.usesManualSegmentationUI {
            // no-op: handled in the combined manual window
        } else if (enableTagging && !passSourceTags) || enableCollectionSegmentation {
            await showFullSegmentationReview(files: files)
            guard !Task.isCancelled else { return }

            // Final confirmation of box/folder identifications
            await showBoxFolderConfirmation(files: files)
            guard !Task.isCancelled else { return }

            // Rebuild segments from user-confirmed classifications (excluding removed files)
            rebuildSegments(files: files)
        }

        guard !Task.isCancelled else { return }

        // Step 3: Tagging (mode-dependent)
        if enableTagging && !passSourceTags {
            switch taggingMode {
            case .automatic:
                await performAutomaticTaggingWithReview(
                    provider: provider, model: model, thinkingLevel: thinkingLevel,
                    apiKey: apiKey, outputDirectory: outputDirectory,
                    enableSegmentJSON: enableSegmentJSON, files: files
                )
            case .autoDate:
                await performManualTaggingPhase(
                    mode: taggingMode, provider: provider, model: model,
                    thinkingLevel: thinkingLevel, apiKey: apiKey,
                    outputDirectory: outputDirectory, enableSegmentJSON: enableSegmentJSON
                )
            case .human, .autoDateManualSeg:
                await performManualSegmentAndTag(
                    autoDate: taggingMode.autoFillsDate,
                    provider: provider, model: model, thinkingLevel: thinkingLevel, apiKey: apiKey,
                    outputDirectory: outputDirectory,
                    enableSegmentJSON: enableSegmentJSON, preOCRed: true, files: files
                )
            case .none, .copySource:
                break
            }
        } else if passSourceTags {
            // For pre-OCRed input, source tags are on the input PDFs themselves
            for (index, url) in files.enumerated() {
                let sourceTags = MacOSTagger.readTags(from: url)
                if !sourceTags.isEmpty, let outputURL = outputURLMap[url] {
                    try? MacOSTagger.applyTags(sourceTags, to: outputURL)
                    jobs[index].appliedTags = sourceTags
                }
            }
        }

        guard !Task.isCancelled else { return }

        // Step 4: Collection Segmentation + name review (last step before completion)
        if enableCollectionSegmentation {
            await performCollectionSegmentation(
                files: files,
                provider: provider,
                model: model,
                thinkingLevel: thinkingLevel,
                apiKey: apiKey,
                outputDirectory: outputDirectory,
                confirmBeforeOrganizing: confirmCollectionIDs,
                reviewDocumentSegmentation: false
            )

            applyBoxFolderLabelTags(enableTagging: enableTagging)
        }

        // Organize into collection folders (after all processing)
        if enableCollectionSegmentation && !collectionSegments.isEmpty {
            let segmenter2 = CollectionSegmenter()
            statusMessage = "Organizing \(collectionSegments.count) collections into folders…"
            do {
                try segmenter2.organizeOutput(
                    collections: collectionSegments,
                    outputDirectory: outputDirectory,
                    outputURLMap: outputURLMap
                )
                statusMessage = "Collections organized into \(collectionSegments.count) folders."
            } catch {
                statusMessage = "Error organizing collections: \(error.localizedDescription)"
            }
        }
    }

    /// Classify a document using a text-only LLM call (no image).
    private func classifyViaLLM(
        prompt: String,
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String
    ) async -> DocumentClassification? {
        do {
            let response: String
            if let gateway = currentGateway {
                response = try await classifyCallGateway(prompt: prompt, gateway: gateway)
            } else {
                switch provider {
                case .anthropic:
                    response = try await classifyCallAnthropic(prompt: prompt, model: model, thinkingLevel: thinkingLevel, apiKey: apiKey)
                case .gemini:
                    response = try await classifyCallGemini(prompt: prompt, model: model, thinkingLevel: thinkingLevel, apiKey: apiKey)
                case .mistral:
                    response = try await classifyCallMistral(prompt: prompt, apiKey: apiKey)
                }
            }
            let (classification, _, _) = OCRPrompt.parseResponse(response)
            return classification
        } catch {
            return nil
        }
    }

    private nonisolated func classifyCallGateway(prompt: String, gateway: GatewayConfig) async throws -> String {
        let client = OpenAICompatibleClient(baseURL: gateway.baseURL, apiKey: gateway.apiKey, modelID: gateway.modelID)
        return try await client.textCompletion(prompt: prompt, maxTokens: 64)
    }

    private nonisolated func classifyCallAnthropic(prompt: String, model: LLMModel, thinkingLevel: ThinkingLevel?, apiKey: String) async throws -> String {
        let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
        var body: [String: Any] = [
            "model": model.id, "max_tokens": 64,
            "messages": [["role": "user", "content": prompt]]
        ]
        if let thinking = thinkingLevel {
            body["thinking"] = ["type": "enabled", "budget_tokens": thinking == .low ? 512 : 2000]
        }
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await NetworkSession.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else { return "" }
        return content.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }.joined()
    }

    private nonisolated func classifyCallGemini(prompt: String, model: LLMModel, thinkingLevel: ThinkingLevel?, apiKey: String) async throws -> String {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model.id):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else { return "" }
        var body: [String: Any] = ["contents": [["parts": [["text": prompt]]]]]
        if let thinking = thinkingLevel {
            body["generationConfig"] = ["thinkingConfig": ["thinkingBudget": thinking == .low ? 512 : 2000]]
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await NetworkSession.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return "" }
        return parts.compactMap { $0["text"] as? String }.joined()
    }

    private nonisolated func classifyCallMistral(prompt: String, apiKey: String) async throws -> String {
        let endpoint = URL(string: "https://api.mistral.ai/v1/chat/completions")!
        let body: [String: Any] = [
            "model": "mistral-small-latest",
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": 64
        ]
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await NetworkSession.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { return "" }
        return content
    }

    // MARK: - Phase 1 (Batch): Batch OCR

    private func performBatchOCR(
        fileURLs: [URL],
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        outputDirectory: URL,
        sendPreviousImage: Bool,
        enableTagging: Bool,
        enableCollectionSegmentation: Bool = false,
        enableSegmentJSON: Bool = true,
        confirmCollectionIDs: Bool = false,
        reviewDocumentSegmentation: Bool = false,
        customPrompt: String? = nil,
        imageScale: Double = 1.0
    ) async {
        let total = fileURLs.count

        // Mark all as processing
        for i in 0..<total { jobs[i].status = .processing }

        // Submit batch
        statusMessage = "Submitting batch (\(total) files)…"

        let batchId: String
        do {
            switch provider {
            case .anthropic:
                let client = AnthropicBatchClient(apiKey: apiKey, model: model, thinkingLevel: thinkingLevel)
                batchId = try await client.submitBatch(fileURLs: fileURLs, sendPreviousImage: sendPreviousImage, customPrompt: customPrompt, imageScale: imageScale)
            case .mistral:
                let client = MistralBatchClient(apiKey: apiKey, model: model)
                batchId = try await client.submitBatch(fileURLs: fileURLs, imageScale: imageScale)
            case .gemini:
                let client = GeminiBatchClient(apiKey: apiKey, model: model, thinkingLevel: thinkingLevel)
                batchId = try await client.submitBatch(fileURLs: fileURLs, sendPreviousImage: sendPreviousImage, customPrompt: customPrompt, imageScale: imageScale)
            }
        } catch {
            statusMessage = "Batch submission failed: \(error.localizedDescription)"
            for i in jobs.indices where jobs[i].status == .processing {
                jobs[i].status = .failed
                failedFiles.append(jobs[i].sourceURL.lastPathComponent)
            }
            return
        }

        // Store for cancellation + persist to disk for resume after relaunch
        activeBatch = BatchContext(batchId: batchId, apiKey: apiKey, model: model, thinkingLevel: thinkingLevel, provider: provider)
        Self.savePendingBatch(PendingBatch(
            batchId: batchId, provider: provider, model: model,
            thinkingLevel: thinkingLevel, fileURLs: fileURLs,
            outputDirectory: outputDirectory, enableTagging: enableTagging,
            enableCollectionSegmentation: enableCollectionSegmentation,
            sendPreviousImage: sendPreviousImage, submittedAt: Date(),
            enableSegmentJSON: enableSegmentJSON,
            confirmCollectionIDs: confirmCollectionIDs,
            reviewDocumentSegmentation: reviewDocumentSegmentation,
            customPrompt: customPrompt
        ))
        statusMessage = "Batch submitted. Waiting for results…"

        // Poll for completion
        await pollBatchUntilComplete(
            batchId: batchId, provider: provider, model: model,
            thinkingLevel: thinkingLevel, apiKey: apiKey,
            fileURLs: fileURLs, outputDirectory: outputDirectory
        )

        Self.deletePendingBatch()
        activeBatch = nil
        progress = 0.7
    }

    /// Shared polling loop used by both initial batch processing and resume.
    private func pollBatchUntilComplete(
        batchId: String,
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        fileURLs: [URL],
        outputDirectory: URL
    ) async {
        var pollCount = 0
        var batchComplete = false
        while !batchComplete {
            guard !Task.isCancelled else { return }

            // Poll every 30s for the first ~5 min (few batches finish faster), then back off to 60s.
            let interval: Duration = pollCount < 10 ? .seconds(30) : .seconds(60)
            try? await Task.sleep(for: interval)
            pollCount += 1

            guard !Task.isCancelled else { return }

            do {
                switch provider {
                case .anthropic:
                    let client = AnthropicBatchClient(apiKey: apiKey, model: model, thinkingLevel: thinkingLevel)
                    let status = try await client.checkStatus(batchId: batchId)
                    progress = Double(status.completed) / Double(max(1, status.total)) * 0.7
                    statusMessage = "Batch processing… \(status.completed)/\(status.total) complete"

                    if status.isComplete {
                        if let url = status.resultsURL {
                            statusMessage = "Retrieving batch results…"
                            let results = try await client.retrieveResults(resultsURL: url)
                            await processBatchResults(results, fileURLs: fileURLs, model: model, apiKey: apiKey, outputDirectory: outputDirectory)
                        } else {
                            statusMessage = "Batch completed but no results available"
                            for i in jobs.indices where jobs[i].status == .processing {
                                jobs[i].status = .failed
                                failedFiles.append(jobs[i].sourceURL.lastPathComponent)
                            }
                        }
                        batchComplete = true
                    }

                case .mistral:
                    let client = MistralBatchClient(apiKey: apiKey, model: model)
                    let status = try await client.checkStatus(batchId: batchId)
                    progress = Double(status.completedRequests) / Double(max(1, status.totalRequests)) * 0.7
                    statusMessage = "Batch processing… \(status.completedRequests)/\(status.totalRequests) complete"

                    if status.isComplete {
                        if status.status == "SUCCESS", let fileId = status.outputFileId {
                            statusMessage = "Retrieving batch results…"
                            let results = try await client.retrieveResults(outputFileId: fileId)
                            await processBatchResults(results, fileURLs: fileURLs, model: model, apiKey: apiKey, outputDirectory: outputDirectory)
                        } else {
                            statusMessage = "Batch \(status.status.lowercased())"
                            for i in jobs.indices where jobs[i].status == .processing {
                                jobs[i].status = .failed
                                failedFiles.append(jobs[i].sourceURL.lastPathComponent)
                            }
                        }
                        batchComplete = true
                    }

                case .gemini:
                    let client = GeminiBatchClient(apiKey: apiKey, model: model, thinkingLevel: thinkingLevel)
                    // Gemini may have multiple batch IDs (comma-separated) for large batches
                    let geminiBatchIds = batchId.components(separatedBy: ",")
                    var allComplete = true
                    var anyFailed = false
                    var stateDisplays: [String] = []

                    for singleBatchId in geminiBatchIds {
                        let status = try await client.checkStatus(batchName: singleBatchId)
                        let stateDisplay = status.state
                            .replacingOccurrences(of: "BATCH_STATE_", with: "")
                            .replacingOccurrences(of: "JOB_STATE_", with: "")
                            .lowercased()
                        stateDisplays.append(stateDisplay)

                        if !status.isComplete {
                            allComplete = false
                        } else {
                            let succeeded = status.state == "BATCH_STATE_SUCCEEDED" || status.state == "JOB_STATE_SUCCEEDED"
                            if succeeded {
                                if let inlineResults = status.inlineResults {
                                    await processBatchResults(inlineResults, fileURLs: fileURLs, model: model, apiKey: apiKey, outputDirectory: outputDirectory)
                                } else if let fileName = status.resultFileName {
                                    let results = try await client.retrieveResults(resultFileName: fileName)
                                    await processBatchResults(results, fileURLs: fileURLs, model: model, apiKey: apiKey, outputDirectory: outputDirectory)
                                }
                            } else {
                                anyFailed = true
                            }
                        }
                    }

                    if geminiBatchIds.count > 1 {
                        let completedCount = stateDisplays.filter { $0 == "succeeded" || $0 == "failed" || $0 == "cancelled" || $0 == "expired" }.count
                        statusMessage = "Batch processing… \(completedCount)/\(geminiBatchIds.count) chunks (\(stateDisplays.first ?? "unknown"))"
                    } else {
                        statusMessage = "Batch processing… (\(stateDisplays.first ?? "unknown"))"
                    }

                    if allComplete {
                        if anyFailed {
                            for i in jobs.indices where jobs[i].status == .processing {
                                jobs[i].status = .failed
                                failedFiles.append(jobs[i].sourceURL.lastPathComponent)
                            }
                        }
                        batchComplete = true
                    }
                }
            } catch {
                statusMessage = "Error checking batch: \(error.localizedDescription). Retrying…"
            }
        }
    }

    private func processBatchResults(
        _ results: [String: OCRResult],
        fileURLs: [URL],
        model: LLMModel,
        apiKey: String,
        outputDirectory: URL
    ) async {
        for (customId, result) in results {
            let indexStr = customId.replacingOccurrences(of: "file-", with: "")
            guard let index = Int(indexStr), index < fileURLs.count else { continue }
            let url = fileURLs[index]
            // The batch path has no live network call to overlap with, but rotation is still
            // detected per the run's mode and merged before applying.
            let correction = await Self.detectRotation(
                imageURL: url, provider: model.provider, apiKey: apiKey,
                mode: Self.rotationModeForRun, gatewayConfig: currentGateway
            )
            let resolved = Self.mergeRotation(into: result, correction: correction)
            handleOCRResult(resolved, index: index, url: url, model: model, outputDirectory: outputDirectory)
        }

        // Mark any remaining processing jobs as failed (no result returned for them).
        // Report the filename from the job itself (matches the sibling loop above) rather than
        // cross-indexing fileURLs, so this stays correct even if the arrays ever diverge.
        for i in jobs.indices where jobs[i].status == .processing {
            jobs[i].status = .failed
            failedFiles.append(jobs[i].sourceURL.lastPathComponent)
        }
    }

    // MARK: - Phase 1: OCR

    private func performOCRPhase(
        fileURLs: [URL],
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        outputDirectory: URL,
        segmentationContext: SegmentationContext
    ) async {
        if segmentationContext.previousTextCharCount == 0 {
            // No dependency on prior OCR text — can run in parallel
            await performOCRParallel(
                fileURLs: fileURLs,
                provider: provider,
                model: model,
                thinkingLevel: thinkingLevel,
                apiKey: apiKey,
                outputDirectory: outputDirectory,
                sendPreviousImage: segmentationContext.sendPreviousImage,
                customPrompt: segmentationContext.customPrompt,
                imageScale: segmentationContext.imageScale
            )
        } else {
            // Need prior page's OCR text — must be sequential
            await performOCRSequential(
                fileURLs: fileURLs,
                provider: provider,
                model: model,
                thinkingLevel: thinkingLevel,
                apiKey: apiKey,
                outputDirectory: outputDirectory,
                segmentationContext: segmentationContext
            )
        }
    }

    // MARK: Sequential OCR (when previous text context is needed)

    private func performOCRSequential(
        fileURLs: [URL],
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        outputDirectory: URL,
        segmentationContext: SegmentationContext
    ) async {
        let total = fileURLs.count
        let gateway = currentGateway
        var previousText: String? = nil
        var previousImageURL: URL? = nil

        for index in 0..<total {
            guard !Task.isCancelled else { return }
            let url = fileURLs[index]
            jobs[index].status = .processing

            let contextText: String?
            if let prev = previousText, segmentationContext.previousTextCharCount > 0 {
                let charCount = segmentationContext.previousTextCharCount
                contextText = String(prev.suffix(charCount))
            } else {
                contextText = nil
            }
            let contextImageURL = segmentationContext.sendPreviousImage ? previousImageURL : nil

            statusMessage = "OCR \(index + 1)/\(total)…"
            var result = await Self.performOCRCall(
                imageURL: url,
                provider: provider,
                model: model,
                thinkingLevel: thinkingLevel,
                apiKey: apiKey,
                previousText: contextText,
                previousImageURL: contextImageURL,
                customPrompt: segmentationContext.customPrompt,
                imageScale: segmentationContext.imageScale,
                gatewayConfig: gateway
            )

            // If timed out, retry once without context
            if Self.isTimeoutError(result) {
                statusMessage = "OCR \(index + 1)/\(total)… retrying after timeout"
                result = await Self.performOCRCall(
                    imageURL: url,
                    provider: provider,
                    model: model,
                    thinkingLevel: thinkingLevel,
                    apiKey: apiKey,
                    previousText: nil,
                    previousImageURL: nil,
                    customPrompt: segmentationContext.customPrompt,
                    imageScale: segmentationContext.imageScale,
                    gatewayConfig: gateway
                )
            }

            handleOCRResult(result, index: index, url: url, model: model, outputDirectory: outputDirectory)
            previousText = result.text
            previousImageURL = url

            progress = Double(index + 1) / Double(total) * 0.7
            statusMessage = "OCR \(index + 1)/\(total) complete"
        }
    }

    // MARK: Parallel OCR (when no previous text context is needed)

    private func performOCRParallel(
        fileURLs: [URL],
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        outputDirectory: URL,
        sendPreviousImage: Bool,
        customPrompt: String? = nil,
        imageScale: Double = 1.0
    ) async {
        let total = fileURLs.count
        let gateway = currentGateway
        let concurrency = max(1, Self.ocrWorkerCount)
        var completed = 0

        // Mark all as processing
        for i in 0..<total { jobs[i].status = .processing }
        statusMessage = "OCR 0/\(total)… (parallel, \(concurrency) workers)"

        await withTaskGroup(of: (Int, OCRResult).self) { group in
            var nextIndex = 0

            // Seed initial batch
            for _ in 0..<min(concurrency, total) {
                let index = nextIndex
                let url = fileURLs[index]
                let prevImageURL = (sendPreviousImage && index > 0) ? fileURLs[index - 1] : nil
                nextIndex += 1
                group.addTask {
                    let result = await Self.performOCRCall(
                        imageURL: url, provider: provider, model: model,
                        thinkingLevel: thinkingLevel, apiKey: apiKey,
                        previousText: nil, previousImageURL: prevImageURL,
                        customPrompt: customPrompt, imageScale: imageScale,
                        gatewayConfig: gateway
                    )
                    return (index, result)
                }
            }

            // Collect results and feed new tasks
            for await (index, result) in group {
                guard !Task.isCancelled else { group.cancelAll(); return }
                let url = fileURLs[index]
                handleOCRResult(result, index: index, url: url, model: model, outputDirectory: outputDirectory)

                completed += 1
                progress = Double(completed) / Double(total) * 0.7
                statusMessage = "OCR \(completed)/\(total) complete (parallel)"

                // Add next task if available
                if nextIndex < total {
                    let idx = nextIndex
                    let nextURL = fileURLs[idx]
                    let prevImageURL = (sendPreviousImage && idx > 0) ? fileURLs[idx - 1] : nil
                    nextIndex += 1
                    group.addTask {
                        let result = await Self.performOCRCall(
                            imageURL: nextURL, provider: provider, model: model,
                            thinkingLevel: thinkingLevel, apiKey: apiKey,
                            previousText: nil, previousImageURL: prevImageURL,
                            customPrompt: customPrompt, imageScale: imageScale,
                            gatewayConfig: gateway
                        )
                        return (idx, result)
                    }
                }
            }
        }
    }

    // MARK: Shared OCR helpers

    private func handleOCRResult(_ result: OCRResult, index: Int, url: URL, model: LLMModel, outputDirectory: URL) {
        guard index >= 0 && index < jobs.count else {
            print("handleOCRResult: index \(index) out of range (jobs.count = \(jobs.count))")
            return
        }
        let sourceURL = jobs[index].sourceURL
        jobs[index].result = result
        jobs[index].classification = result.classification
        jobs[index].status = result.text != nil ? .succeeded : .failed
        if result.text == nil {
            failedFiles.append(sourceURL.lastPathComponent)
        }
        let pdfGen = PDFGenerator()
        // Use original source name for output PDF naming
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let outputURL = outputDirectory.appendingPathComponent(baseName + ".pdf")
        // Use the provided url (may be temp JPEG) for the image page
        try? pdfGen.generate(imageURL: url, result: result, model: model, outputURL: outputURL, originalFileName: sourceURL.lastPathComponent, gatewayDisplayName: currentGateway?.displayName)
        // Map by original source URL so tagging/collection segmentation can find it
        outputURLMap[sourceURL] = outputURL
        // Copy source tags to output PDF if pass-through mode is enabled
        if passSourceTags {
            let sourceTags = MacOSTagger.readTags(from: sourceURL)
            if !sourceTags.isEmpty {
                try? MacOSTagger.applyTags(sourceTags, to: outputURL)
                jobs[index].appliedTags = sourceTags
            }
        }
        // Persist result for resume-after-restart
        saveResultToPendingRun(index: index, result: result)
    }

    private static func isTimeoutError(_ result: OCRResult) -> Bool {
        if result.errorMessage?.lowercased().contains("timed out") == true
            || result.errorCode?.lowercased().contains("timeout") == true { return true }
        // Providers also surface timeouts as HTTP 408 (Request Timeout) / 504 (Gateway Timeout)
        // without those words. Excludes 503 (overload) — NetworkSession already retries/backs those off,
        // and this drives a bare one-shot retry (max one extra attempt per file), so no double-counting.
        if let code = result.errorCode, code == "408" || code == "504" { return true }
        return false
    }

    /// Single-image OCR + concurrent rotation detection, merged into one result. Reused by the
    /// Live Capture streaming coordinator (reads `rotationModeForRun`, set before the run).
    nonisolated static func performOCRCall(
        imageURL: URL,
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        previousText: String?,
        previousImageURL: URL?,
        customPrompt: String? = nil,
        imageScale: Double = 1.0,
        gatewayConfig: GatewayConfig? = nil
    ) async -> OCRResult {
        // Start rotation detection concurrently with the network OCR call. Both are async, so
        // the extra rotation work overlaps the OCR round-trip and adds little wall-clock time.
        // The detected correction overrides the OCR prompt's own rotation guess.
        async let rotationCorrection = detectRotation(
            imageURL: imageURL, provider: provider, apiKey: apiKey,
            mode: rotationModeForRun, gatewayConfig: gatewayConfig
        )

        // The incoming `imageScale` is the size-target slider fraction; convert to a per-file
        // dimension scale (larger files reduced more; average/small files left full-res).
        let scale = targetDimensionScale(forFileAt: imageURL, sizeFraction: imageScale)

        let networkResult: OCRResult
        do {
            if let gateway = gatewayConfig {
                let client = OpenAICompatibleClient(baseURL: gateway.baseURL, apiKey: gateway.apiKey, modelID: gateway.modelID)
                networkResult = try await client.ocr(imageURL: imageURL, previousText: previousText, previousImageURL: previousImageURL, customPrompt: customPrompt, imageScale: scale)
            } else {
                switch provider {
                case .anthropic:
                    let client = AnthropicClient(apiKey: apiKey, model: model, thinkingLevel: thinkingLevel)
                    networkResult = try await client.ocr(imageURL: imageURL, previousText: previousText, previousImageURL: previousImageURL, customPrompt: customPrompt, imageScale: scale)
                case .gemini:
                    let client = GeminiClient(apiKey: apiKey, model: model, thinkingLevel: thinkingLevel)
                    networkResult = try await client.ocr(imageURL: imageURL, previousText: previousText, previousImageURL: previousImageURL, customPrompt: customPrompt, imageScale: scale)
                case .mistral:
                    let client = MistralClient(apiKey: apiKey, model: model)
                    networkResult = try await client.ocr(imageURL: imageURL, previousText: previousText, imageScale: scale)
                }
            }
        } catch {
            _ = await rotationCorrection  // let the concurrent task finish
            return OCRResult(text: nil, classification: nil, errorMessage: error.localizedDescription, errorCode: nil)
        }

        // Override rotation with the detected correction when OCR produced text and a
        // correction was found; otherwise keep the LLM prompt's parsed rotation.
        return mergeRotation(into: networkResult, correction: await rotationCorrection)
    }

    /// Detect the clockwise correction for an image per the run's rotation mode, with LLM
    /// modes falling back to local Vision when unavailable. Runs off the main actor.
    nonisolated static func detectRotation(
        imageURL: URL,
        provider: LLMProvider,
        apiKey: String,
        mode: RotationMode,
        gatewayConfig: GatewayConfig?
    ) async -> Int? {
        switch mode {
        case .off:
            return nil
        case .localVision:
            return await RotationDetector.detectCorrection(imageURL: imageURL)
        case .llmSingle, .llmMajority:
            if let c = await LLMRotationDetector.detectCorrection(
                imageURL: imageURL, provider: provider, apiKey: apiKey,
                orderings: mode.orderings, gatewayConfig: gatewayConfig
            ) {
                return c
            }
            // Fall back to local Vision if the LLM path is unavailable or fails.
            return await RotationDetector.detectCorrection(imageURL: imageURL)
        }
    }

    /// Replace a result's rotation with the detected correction when the result has text and
    /// a correction was found; otherwise return the result unchanged.
    private nonisolated static func mergeRotation(into result: OCRResult, correction: Int?) -> OCRResult {
        guard result.text != nil, let rot = correction else { return result }
        return OCRResult(
            text: result.text,
            classification: result.classification,
            rotationDegrees: rot,
            errorMessage: result.errorMessage,
            errorCode: result.errorCode
        )
    }

    // MARK: - Retry High-Use Failures

    private func isRetryableError(_ result: OCRResult?) -> Bool {
        guard let result = result, result.text == nil else { return false }
        let code = result.errorCode ?? ""
        let msg = (result.errorMessage ?? "").lowercased()
        return code == "503" || code == "429" || code == "529"
            || msg.contains("high use") || msg.contains("high demand")
            || msg.contains("unavailable") || msg.contains("overloaded")
            || msg.contains("rate limit")
    }

    private func retryHighUseFailures(
        fileURLs: [URL],
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        outputDirectory: URL
    ) async {
        let retryIndices = jobs.indices.filter { isRetryableError(jobs[$0].result) }
        guard !retryIndices.isEmpty else { return }
        let gateway = currentGateway

        statusMessage = "Waiting to retry \(retryIndices.count) file\(retryIndices.count == 1 ? "" : "s") (model was busy)…"
        try? await Task.sleep(for: .seconds(10))
        guard !Task.isCancelled else { return }

        for (attempt, index) in retryIndices.enumerated() {
            guard !Task.isCancelled else { return }
            let url = fileURLs[index]
            jobs[index].status = .processing
            statusMessage = "Retrying \(attempt + 1)/\(retryIndices.count): \(url.lastPathComponent)…"

            let result = await Self.performOCRCall(
                imageURL: url,
                provider: provider,
                model: model,
                thinkingLevel: thinkingLevel,
                apiKey: apiKey,
                previousText: nil,
                previousImageURL: nil,
                gatewayConfig: gateway
            )

            // Update failed files list if retry succeeded
            if result.text != nil {
                let sourceFileName = jobs[index].sourceURL.lastPathComponent
                failedFiles.removeAll { $0 == sourceFileName }
            }
            handleOCRResult(result, index: index, url: url, model: model, outputDirectory: outputDirectory)
        }
    }

    // MARK: - Phase 3: Tagging

    /// Rebuild `segments` from current job classifications, excluding user-removed files.
    private func rebuildSegments(files: [URL]) {
        let segmenter = DocumentSegmenter()
        var activeFiles: [URL] = []
        var classifications: [DocumentClassification?] = []
        var texts: [String] = []
        for (i, url) in files.enumerated() {
            if removedSourceURLs.contains(url) { continue }
            activeFiles.append(url)
            classifications.append(i < jobs.count ? jobs[i].result?.classification : nil)
            texts.append(i < jobs.count ? (jobs[i].result?.text ?? "") : "")
        }
        segments = segmenter.segment(files: activeFiles, classifications: classifications, texts: texts)
    }

    /// Apply Live-Capture group boundaries/types to job classifications, so segmentation uses
    /// the phone's grouping instead of the LLM. Boundaries → documentStart/continuation;
    /// box/folder types → the corresponding label classification.
    private func applyPreGroupedClassifications(files: [URL]) {
        for i in files.indices where i < jobs.count {
            let type = i < preGroupedTypes.count ? preGroupedTypes[i] : .document
            let isStart = i < preGroupedBoundaries.count ? preGroupedBoundaries[i] : true
            let cls: DocumentClassification
            switch type {
            case .box: cls = .boxLabel
            case .folder: cls = .folderLabel
            case .document: cls = isStart ? .documentStart : .documentContinuation
            }
            jobs[i].classification = cls
            if let r = jobs[i].result {
                jobs[i].result = OCRResult(text: r.text, classification: cls,
                                           rotationDegrees: r.rotationDegrees,
                                           errorMessage: r.errorMessage, errorCode: nil)
            }
        }
    }

    // MARK: - Live Capture phone tags (priority + date)

    private static let englishMonthNames = ["January", "February", "March", "April", "May", "June",
                                            "July", "August", "September", "October", "November", "December"]

    /// Phone-supplied year for the file at `index`, as a "YYYY" tag; nil if none.
    private func phoneYearTag(at index: Int) -> String? {
        guard index >= 0, index < preGroupedYears.count, let y = preGroupedYears[index] else { return nil }
        return String(y)
    }

    /// Phone-supplied month for the file at `index`, as an "MM Month" tag (e.g. "03 March"); nil if none.
    private func phoneMonthTag(at index: Int) -> String? {
        guard index >= 0, index < preGroupedMonths.count,
              let m = preGroupedMonths[index], (1...12).contains(m) else { return nil }
        return String(format: "%02d %@", m, Self.englishMonthNames[m - 1])
    }

    /// Live Capture: layer each page's phone-set priority ("P10"…"P7") onto whatever the tagging
    /// phase applied. macOS tag application replaces, so read → append → re-apply; also record it in
    /// the job's appliedTags so document merging carries it. No-op outside a pre-grouped run.
    private func applyCapturePriorityTags() {
        guard !preGroupedPriorities.isEmpty else { return }
        for i in jobs.indices where i < preGroupedPriorities.count {
            guard let raw = preGroupedPriorities[i]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
                  let outputPDF = outputURLMap[jobs[i].sourceURL] else { continue }
            var tags = MacOSTagger.readTags(from: outputPDF)
            if !tags.contains(raw) {
                tags.append(raw)
                try? MacOSTagger.applyTags(tags, to: outputPDF)
            }
            if !jobs[i].appliedTags.contains(raw) { jobs[i].appliedTags.append(raw) }
        }
    }

    /// Live Capture dual output: write each page's original image next to its PDF (same base name),
    /// tagged identically, so the final folder holds BOTH the image and the PDF. Runs before merge/
    /// organization so `outputURLMap` is still per-page; `organizeOutput` moves the sibling image too.
    private func exportOriginalImages() async {
        guard exportOriginals else { return }
        // Snapshot the work on the main actor…
        let work: [(src: URL, img: URL, pdf: URL)] = jobs.compactMap { job in
            guard let pdfURL = outputURLMap[job.sourceURL],
                  FileManager.default.fileExists(atPath: job.sourceURL.path) else { return nil }
            let ext = job.sourceURL.pathExtension.isEmpty ? "jpg" : job.sourceURL.pathExtension
            return (src: job.sourceURL, img: pdfURL.deletingPathExtension().appendingPathExtension(ext), pdf: pdfURL)
        }
        guard !work.isEmpty else { return }
        // …then copy the (full-resolution) originals + mirror the PDF's tags OFF the main thread,
        // so the UI never stalls on large files.
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            for w in work {
                try? fm.removeItem(at: w.img)
                guard (try? fm.copyItem(at: w.src, to: w.img)) != nil else { continue }
                // Mirror the PDF's tags onto the image (applyTags re-stamps the trailing "Unread"
                // in real-tagging modes, so the image always matches the PDF, ending with "Unread").
                let tags = MacOSTagger.readTags(from: w.pdf)
                try? MacOSTagger.applyTags(tags, to: w.img)
            }
        }.value
    }

    /// Automatic (LLM) tagging with the redo-review loop. Extracted so the standard and
    /// pre-OCRed pipelines share one implementation.
    private func performAutomaticTaggingWithReview(
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        outputDirectory: URL,
        enableSegmentJSON: Bool,
        files: [URL]
    ) async {
        var shouldRedoTagging = true
        while shouldRedoTagging {
            statusMessage = "Found \(segments.count) segments. Generating tags…"

            await performTaggingPhase(
                provider: provider,
                model: model,
                thinkingLevel: thinkingLevel,
                apiKey: apiKey,
                outputDirectory: outputDirectory,
                enableSegmentJSON: enableSegmentJSON
            )

            guard !Task.isCancelled else { return }

            // Interactive Review Point 2: Pause for final review after tagging
            statusMessage = "Review tags and segmentation. Click Complete to finalize, or Redo to re-tag."
            isProcessing = false
            awaitingFinalReview = true

            let action: FinalReviewAction = await withCheckedContinuation { continuation in
                finalReviewContinuation = continuation
            }

            guard !Task.isCancelled else { return }
            isProcessing = true

            switch action {
            case .complete:
                shouldRedoTagging = false
            case .redoTagging:
                rebuildSegments(files: files)
                for i in jobs.indices { jobs[i].appliedTags = [] }
            }
        }
    }

    /// Manual (human-in-the-loop) tagging. Presents each non-box/folder segment sequentially
    /// for the user to enter subject tags (and, in `.human` mode, the date). In `.autoDate`
    /// mode the date is prefetched from the LLM while the user tags, so they never wait on
    /// the network. Box/folder segments still receive their Red/Purple color tags.
    private func performManualTaggingPhase(
        mode: TaggingMode,
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        outputDirectory: URL,
        enableSegmentJSON: Bool
    ) async {
        // Apply Red/Purple color tags to box/folder segments (they aren't manually tagged).
        applyBoxFolderLabelTagsUnconditionally()

        // Build one manual-tag entry per taggable (non-box/folder) segment.
        func rotation(for url: URL) -> Int {
            jobs.first(where: { $0.sourceURL == url })?.result?.rotationDegrees ?? 0
        }
        var manual: [ManualTagSegment] = []
        for (i, seg) in segments.enumerated() where !seg.isBox && !seg.isFolder {
            var images: [ManualTagImage] = []
            // Context: the nearest preceding box/folder label (shown first, never tagged).
            if let ctxSeg = segments[0..<i].last(where: { $0.isBox || $0.isFolder }),
               let ctxURL = ctxSeg.pdfURLs.first {
                images.append(ManualTagImage(url: ctxURL, rotationDegrees: rotation(for: ctxURL), isContext: true))
            }
            for url in seg.pdfURLs {
                images.append(ManualTagImage(url: url, rotationDegrees: rotation(for: url), isContext: false))
            }
            // Pre-fill the phone's date (Live Capture); when present, skip the LLM date prefetch.
            let phoneFileIdx = seg.pdfURLs.first.flatMap { url in jobs.firstIndex(where: { $0.sourceURL == url }) }
            let phoneYear = phoneFileIdx.flatMap { phoneYearTag(at: $0) }
            let phoneMonth = phoneFileIdx.flatMap { phoneMonthTag(at: $0) }
            manual.append(ManualTagSegment(
                segmentIndex: i,
                images: images,
                year: phoneYear ?? "",
                month: phoneMonth ?? "",
                subjectTags: ["Unread"],
                dateLoading: mode == .autoDate && phoneYear == nil && phoneMonth == nil
            ))
        }
        guard !manual.isEmpty else { return }

        manualTagSegments = manual
        currentManualIndex = 0

        // Prefetch dates for .autoDate while the user works (in-order, so early segments fill first).
        var dateTask: Task<Void, Never>? = nil
        if mode == .autoDate {
            dateTask = Task { [weak self] in
                await self?.prefetchManualDates(
                    provider: provider, model: model,
                    thinkingLevel: thinkingLevel, apiKey: apiKey
                )
            }
        }

        statusMessage = "Manual tagging: \(manual.count) segment\(manual.count == 1 ? "" : "s")."
        isProcessing = false
        awaitingManualTagging = true

        await withCheckedContinuation { continuation in
            manualTaggingContinuation = continuation
        }

        dateTask?.cancel()
        guard !Task.isCancelled else { return }
        isProcessing = true

        // Apply the user's tags to each segment's output PDF(s) and write JSON.
        for m in manualTagSegments where m.segmentIndex < segments.count {
            let seg = segments[m.segmentIndex]
            var tags = GeneratedTags()
            tags.year = m.year.isEmpty ? nil : m.year
            tags.month = m.month.isEmpty ? nil : m.month
            tags.day = m.day.isEmpty ? nil : m.day
            tags.dateUncertain = m.dateUncertain
            tags.subjectTags = m.subjectTags

            for sourceURL in seg.pdfURLs {
                if let outputPDF = outputURLMap[sourceURL] {
                    try? MacOSTagger.applyTags(tags, to: outputPDF)
                }
                if let jobIndex = jobs.firstIndex(where: { $0.sourceURL == sourceURL }) {
                    jobs[jobIndex].appliedTags = tags.allTags
                }
            }
            if enableSegmentJSON {
                writeSegmentJSON(segment: seg, tags: tags, outputDirectory: outputDirectory)
            }
        }
    }

    /// Sequentially prefetch LLM date estimates for the manual-tag segments, filling any
    /// date fields the user hasn't already edited.
    private func prefetchManualDates(
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String
    ) async {
        let generator = TagGenerator()
        // Gather segments still needing a date (main actor); skip already-dated ones (incl. Live
        // Capture pre-fills).
        var work: [(idx: Int, segment: DocumentSegment, nearby: [DocumentSegment])] = []
        for idx in manualTagSegments.indices {
            let segIndex = manualTagSegments[idx].segmentIndex
            guard segIndex < segments.count else { continue }
            if !manualTagSegments[idx].year.isEmpty {
                manualTagSegments[idx].dateLoading = false
                continue
            }
            let nearby = Array(
                segments[max(0, segIndex - 3)..<segIndex]
                + segments[min(segIndex + 1, segments.count)..<min(segIndex + 4, segments.count)]
            )
            work.append((idx, segments[segIndex], nearby))
        }
        guard !work.isEmpty else { return }
        let gateway = currentGateway
        let maxConcurrent = min(6, work.count)

        // Fetch dates concurrently (bounded), skipping thinking, and apply each result on the main
        // actor as it arrives (only filling fields the user hasn't already set).
        await withTaskGroup(of: (Int, GeneratedTags).self) { group in
            var next = 0
            while next < maxConcurrent {
                let w = work[next]
                group.addTask {
                    let date = await generator.generateDateOnly(
                        for: w.segment, nearbySegments: w.nearby,
                        provider: provider, model: model, thinkingLevel: nil,
                        apiKey: apiKey, gatewayConfig: gateway
                    )
                    return (w.idx, date)
                }
                next += 1
            }
            for await (idx, date) in group {
                if Task.isCancelled { break }
                if idx < manualTagSegments.count {
                    if manualTagSegments[idx].year.isEmpty { manualTagSegments[idx].year = date.year ?? "" }
                    if manualTagSegments[idx].month.isEmpty { manualTagSegments[idx].month = date.month ?? "" }
                    if manualTagSegments[idx].day.isEmpty { manualTagSegments[idx].day = date.day ?? "" }
                    manualTagSegments[idx].dateUncertain = date.dateUncertain
                    manualTagSegments[idx].dateLoading = false
                }
                if next < work.count {
                    let w = work[next]
                    group.addTask {
                        let date = await generator.generateDateOnly(
                            for: w.segment, nearbySegments: w.nearby,
                            provider: provider, model: model, thinkingLevel: nil,
                            apiKey: apiKey, gatewayConfig: gateway
                        )
                        return (w.idx, date)
                    }
                    next += 1
                }
            }
        }
    }

    /// UI: advance to the next manual-tag segment, or finish if on the last one.
    func advanceManualSegment() {
        if currentManualIndex < manualTagSegments.count - 1 {
            currentManualIndex += 1
        } else {
            finishManualTagging()
        }
    }

    /// UI: go back to the previous manual-tag segment.
    func previousManualSegment() {
        if currentManualIndex > 0 { currentManualIndex -= 1 }
    }

    /// UI: finish manual tagging and resume the pipeline.
    func finishManualTagging() {
        awaitingManualTagging = false
        manualTaggingContinuation?.resume()
        manualTaggingContinuation = nil
    }

    // MARK: - Fully-manual segmentation + tagging (human mode)

    /// Present the progressive manual segmentation + tagging window (human / autoDateManualSeg).
    /// The user reviews rotation + box/folder, walks the photos in order, marks where each document
    /// segment ends and tags it (the tagged pages then drop out of the viewer). On Finish, the
    /// identified segments are translated back into job classifications, corrected rotations are
    /// baked into the output PDFs, and each segment's tags are applied.
    private func performManualSegmentAndTag(
        autoDate: Bool,
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        outputDirectory: URL,
        enableSegmentJSON: Bool,
        preOCRed: Bool,
        files: [URL]
    ) async {
        // Capture params for on-demand LLM date fetching from the UI.
        manualSegAutoDate = autoDate
        manualSegProvider = provider
        manualSegModel = model
        manualSegThinking = thinkingLevel
        manualSegApiKey = apiKey
        manualSegPreOCRed = preOCRed

        // Build the ordered image list (excluding already-removed files). Kind + rotation seed from
        // the OCR classifications; both are user-editable in the UI.
        var images: [ManualSegImage] = []
        for (i, url) in files.enumerated() {
            guard !removedSourceURLs.contains(url), i < jobs.count else { continue }
            let cls = jobs[i].result?.classification
            let kind: ManualPhotoKind = cls == .boxLabel ? .box : (cls == .folderLabel ? .folder : .document)
            images.append(ManualSegImage(
                fileIndex: i,
                url: url,
                rotationDegrees: jobs[i].result?.rotationDegrees ?? 0,
                kind: kind
            ))
        }
        guard !images.isEmpty else { return }

        manualSegImages = images
        manualSegConsumed = []
        manualSegRemoved = []
        manualSegCompleted = []
        manualSegTaggingRange = nil
        manualSegDraftTags = SegmentTagData()
        manualSegDateFetching = false
        manualSegFocus = manualSegPendingStart ?? 0

        statusMessage = "Manual segmentation & tagging: \(images.count) image\(images.count == 1 ? "" : "s")."
        isProcessing = false
        awaitingManualSegTag = true

        await withCheckedContinuation { continuation in
            manualSegContinuation = continuation
        }

        guard !Task.isCancelled else { return }
        isProcessing = true

        // (a) Removals: drop flagged photos from output, tagging, and segmentation.
        for idx in manualSegRemoved where idx < manualSegImages.count {
            let fileIndex = manualSegImages[idx].fileIndex
            guard fileIndex < jobs.count else { continue }
            let sourceURL = jobs[fileIndex].sourceURL
            removedSourceURLs.insert(sourceURL)
            if let outputURL = outputURLMap[sourceURL] {
                try? FileManager.default.removeItem(at: outputURL)
                let jsonURL = outputURL.deletingPathExtension().appendingPathExtension("json")
                try? FileManager.default.removeItem(at: jsonURL)
                outputURLMap[sourceURL] = nil
            }
            jobs[fileIndex].status = .removed
        }

        // (b) Rotation: bake any corrected rotation into the output PDF by regenerating it. Skipped
        // for pre-OCRed input, where the "output" IS the user's original source PDF (regen would
        // overwrite it). Must run before merge (which deletes per-page PDFs) and before tag apply
        // (regen overwrites the PDF, which would clobber freshly-applied Finder tags).
        if !preOCRed, let model = currentModel {
            for idx in manualSegImages.indices where !manualSegRemoved.contains(idx) {
                let img = manualSegImages[idx]
                let fileIndex = img.fileIndex
                guard fileIndex < jobs.count, let existing = jobs[fileIndex].result,
                      img.rotationDegrees != existing.rotationDegrees else { continue }
                let updated = OCRResult(text: existing.text, classification: existing.classification,
                                        rotationDegrees: img.rotationDegrees,
                                        errorMessage: existing.errorMessage, errorCode: nil)
                jobs[fileIndex].result = updated
                if let outputURL = outputURLMap[jobs[fileIndex].sourceURL] {
                    let imageURL = pdfToImageMap[img.url] ?? img.url
                    try? PDFGenerator().generate(
                        imageURL: imageURL, result: updated, model: model, outputURL: outputURL,
                        originalFileName: jobs[fileIndex].sourceURL.lastPathComponent,
                        gatewayDisplayName: currentGateway?.displayName
                    )
                }
            }
        }

        // (c) Write classifications from the user's kinds + completed-segment membership.
        var startArrayIndices = Set<Int>()
        for seg in manualSegCompleted { if let first = seg.indices.first { startArrayIndices.insert(first) } }
        for idx in manualSegImages.indices where !manualSegRemoved.contains(idx) {
            let img = manualSegImages[idx]
            let fileIndex = img.fileIndex
            guard fileIndex < jobs.count else { continue }
            let newCls: DocumentClassification
            switch img.kind {
            case .box: newCls = .boxLabel
            case .folder: newCls = .folderLabel
            case .document: newCls = startArrayIndices.contains(idx) ? .documentStart : .documentContinuation
            }
            jobs[fileIndex].classification = newCls
            if let r = jobs[fileIndex].result {
                jobs[fileIndex].result = OCRResult(text: r.text, classification: newCls,
                                                   rotationDegrees: r.rotationDegrees,
                                                   errorMessage: r.errorMessage, errorCode: nil)
            }
        }

        // (d) Rebuild segments from the corrected classifications; apply box/folder color tags.
        rebuildSegments(files: files)
        applyBoxFolderLabelTagsUnconditionally()

        // (e) Apply each identified segment's tags to its output PDFs, keyed by the segment's
        // first-page URL (a stable key that survives consumption).
        var tagsByFirstURL: [URL: SegmentTagData] = [:]
        for seg in manualSegCompleted {
            guard let first = seg.indices.first, first < manualSegImages.count else { continue }
            tagsByFirstURL[manualSegImages[first].url] = seg.tags
        }

        for seg in segments where !seg.isBox && !seg.isFolder {
            guard let firstURL = seg.pdfURLs.first else { continue }
            let data = tagsByFirstURL[firstURL] ?? SegmentTagData()
            var gtags = GeneratedTags()
            gtags.year = data.year.isEmpty ? nil : data.year
            gtags.month = data.month.isEmpty ? nil : data.month
            gtags.day = data.day.isEmpty ? nil : data.day
            gtags.dateUncertain = data.dateUncertain
            gtags.subjectTags = data.subjectTags

            for sourceURL in seg.pdfURLs {
                if let outputPDF = outputURLMap[sourceURL] {
                    try? MacOSTagger.applyTags(gtags, to: outputPDF)
                }
                if let jobIndex = jobs.firstIndex(where: { $0.sourceURL == sourceURL }) {
                    jobs[jobIndex].appliedTags = gtags.allTags
                }
            }
            if enableSegmentJSON {
                writeSegmentJSON(segment: seg, tags: gtags, outputDirectory: outputDirectory)
            }
        }
    }

    // MARK: Manual segmentation — derived state

    /// First array index that is an un-consumed, un-removed document — the start of the pending segment.
    var manualSegPendingStart: Int? {
        manualSegImages.indices.first {
            manualSegImages[$0].kind == .document && !manualSegConsumed.contains($0) && !manualSegRemoved.contains($0)
        }
    }

    /// The last index of the contiguous document run beginning at `start` (stops at a box/folder or a
    /// consumed image; removed images are skipped transparently).
    func manualSegRunEnd(from start: Int) -> Int {
        var end = start
        var k = start
        while k < manualSegImages.count {
            if manualSegConsumed.contains(k) { break }
            if manualSegImages[k].kind != .document { break }
            if !manualSegRemoved.contains(k) { end = k }
            k += 1
        }
        return end
    }

    /// The last index of the pending segment given the current focus (clamped into the run).
    var manualSegPendingEnd: Int? {
        guard let s = manualSegPendingStart else { return nil }
        return min(max(manualSegFocus, s), manualSegRunEnd(from: s))
    }

    /// The array-index range currently highlighted as the pending segment (nil while none).
    var manualSegPendingRange: ClosedRange<Int>? {
        guard let s = manualSegPendingStart, let e = manualSegPendingEnd, s <= e else { return nil }
        return s...e
    }

    /// Number of document photos still awaiting tagging.
    var manualSegRemainingDocCount: Int {
        manualSegImages.indices.filter {
            manualSegImages[$0].kind == .document && !manualSegConsumed.contains($0) && !manualSegRemoved.contains($0)
        }.count
    }

    /// Finish is allowed only when every document has been tagged or removed (boxes/folders may remain).
    var manualSegCanFinish: Bool { manualSegRemainingDocCount == 0 }

    // MARK: Manual segmentation — UI intents

    /// Move the viewer focus to the next/previous non-consumed photo.
    func manualSegAdvanceFocus(_ delta: Int) {
        guard !manualSegImages.isEmpty, delta != 0 else { return }
        var i = manualSegFocus + delta
        while i >= 0 && i < manualSegImages.count {
            if !manualSegConsumed.contains(i) { manualSegFocus = i; return }
            i += delta
        }
    }

    /// Set the focused photo's kind (Box / Folder / Document). No-op on consumed photos.
    func manualSegSetKind(_ kind: ManualPhotoKind, at idx: Int) {
        guard idx >= 0, idx < manualSegImages.count, !manualSegConsumed.contains(idx) else { return }
        manualSegImages[idx].kind = kind
    }

    /// Rotate the focused photo 90° clockwise (live in the UI; baked into the PDF at Finish).
    func manualSegRotate(at idx: Int) {
        guard idx >= 0, idx < manualSegImages.count else { return }
        manualSegImages[idx].rotationDegrees = (((manualSegImages[idx].rotationDegrees + 90) % 360) + 360) % 360
    }

    /// Toggle whether the focused photo is flagged for removal (file ops applied at Finish).
    func manualSegToggleRemoved(at idx: Int) {
        guard idx >= 0, idx < manualSegImages.count, !manualSegConsumed.contains(idx) else { return }
        if manualSegRemoved.contains(idx) { manualSegRemoved.remove(idx) } else { manualSegRemoved.insert(idx) }
    }

    /// Open the tag card for the current pending segment, seeding the phone date (Live Capture).
    func manualSegEndAndTag() {
        guard manualSegTaggingRange == nil, let range = manualSegPendingRange else { return }
        var seed = SegmentTagData()
        let firstFileIndex = manualSegImages[range.lowerBound].fileIndex
        if let y = phoneYearTag(at: firstFileIndex) { seed.year = y }
        if let mo = phoneMonthTag(at: firstFileIndex) { seed.month = mo }
        manualSegDraftTags = seed
        manualSegTaggingRange = range
    }

    /// Dismiss the tag card without committing (back to browsing to adjust the segment end).
    func manualSegCancelTagging() {
        manualSegTaggingRange = nil
        manualSegDateFetching = false
    }

    /// Commit the pending segment with the drafted tags — its document pages are consumed (drop out).
    func manualSegCommitPendingSegment() {
        guard let range = manualSegTaggingRange else { return }
        let indices = range.filter { manualSegImages[$0].kind == .document && !manualSegRemoved.contains($0) }
        manualSegTaggingRange = nil
        manualSegDateFetching = false
        guard !indices.isEmpty else { return }
        manualSegCompleted.append(CompletedManualSegment(indices: indices, tags: manualSegDraftTags))
        manualSegConsumed.formUnion(indices)
        manualSegDraftTags = SegmentTagData()
        if let next = manualSegPendingStart {
            manualSegFocus = next
        } else if let firstVisible = manualSegImages.indices.first(where: { !manualSegConsumed.contains($0) }) {
            manualSegFocus = firstVisible
        }
    }

    func confirmManualSegTag() {
        awaitingManualSegTag = false
        manualSegContinuation?.resume()
        manualSegContinuation = nil
    }

    /// UI (autoDateManualSeg mode): fetch the LLM date for the pending segment's pages and fill any
    /// empty date fields in the draft. Idempotent — skips if a date is present or a fetch is in flight.
    func fetchManualSegDate(forIndices indices: [Int]) async {
        guard manualSegAutoDate, let model = manualSegModel else { return }
        guard manualSegDraftTags.year.isEmpty, !manualSegDateFetching else { return }

        var urls: [URL] = []
        var texts: [String] = []
        for i in indices where i >= 0 && i < manualSegImages.count && manualSegImages[i].kind == .document {
            let url = manualSegImages[i].url
            urls.append(url)
            texts.append(jobs.first { $0.sourceURL == url }?.result?.text ?? "")
        }
        guard !urls.isEmpty else { return }

        manualSegDateFetching = true
        let segment = DocumentSegment(pdfURLs: urls, texts: texts)
        let date = await TagGenerator().generateDateOnly(
            for: segment, nearbySegments: [],
            provider: manualSegProvider, model: model,
            thinkingLevel: manualSegThinking, apiKey: manualSegApiKey,
            gatewayConfig: currentGateway
        )
        manualSegDateFetching = false

        guard !Task.isCancelled else { return }
        if manualSegDraftTags.year.isEmpty { manualSegDraftTags.year = date.year ?? "" }
        if manualSegDraftTags.month.isEmpty { manualSegDraftTags.month = date.month ?? "" }
        if manualSegDraftTags.day.isEmpty { manualSegDraftTags.day = date.day ?? "" }
        manualSegDraftTags.dateUncertain = date.dateUncertain
    }

    private func performTaggingPhase(
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        outputDirectory: URL,
        enableSegmentJSON: Bool = true
    ) async {
        let generator = TagGenerator()
        let snapshot = segments
        let total = snapshot.count
        guard total > 0 else { return }
        // Capture immutable inputs for the concurrent tasks.
        let vocabulary = tagVocabulary
        let gateway = currentGateway
        let maxConcurrent = min(6, total)

        // Precompute neighbor context per segment on the main actor, so the concurrent tasks capture
        // only immutable, Sendable inputs.
        let nearbyBySeg: [[DocumentSegment]] = (0..<total).map { i in
            Array(snapshot[max(0, i - 3)..<i] + snapshot[min(i + 1, total)..<min(i + 4, total)])
        }
        // Subjects the Mac operator entered during Live Capture (per segment). Non-empty → apply
        // directly and skip the LLM tag call for that segment.
        let macSubjectsBySeg: [[String]] = snapshot.map { seg in
            guard let firstURL = seg.pdfURLs.first,
                  let fileIdx = jobs.firstIndex(where: { $0.sourceURL == firstURL }),
                  fileIdx < preGroupedSubjects.count else { return [] }
            return preGroupedSubjects[fileIdx]
        }

        // Tag segments concurrently (bounded pool) instead of one-at-a-time. Each call is small,
        // text-only, and independent, so overlapping the network round-trips is a big speedup.
        // Tagging is a simple text→JSON task, so we skip thinking (`thinkingLevel: nil`).
        var completed = 0
        await withTaskGroup(of: (Int, GeneratedTags).self) { group in
            var next = 0
            while next < maxConcurrent {
                let i = next
                group.addTask {
                    if !macSubjectsBySeg[i].isEmpty {
                        return (i, GeneratedTags(subjectTags: macSubjectsBySeg[i]))   // Mac-tagged → no LLM
                    }
                    let tags = await generator.generateTags(
                        for: snapshot[i], nearbySegments: nearbyBySeg[i],
                        provider: provider, model: model, thinkingLevel: nil,
                        apiKey: apiKey, vocabulary: vocabulary, gatewayConfig: gateway
                    )
                    return (i, tags)
                }
                next += 1
            }
            for await (i, rawTags) in group {
                if Task.isCancelled { break }
                applyGeneratedTags(rawTags, toSegmentAt: i, in: snapshot,
                                   enableSegmentJSON: enableSegmentJSON, outputDirectory: outputDirectory)
                completed += 1
                progress = 0.7 + (Double(completed) / Double(total)) * 0.3
                statusMessage = "Tagging \(completed)/\(total)…"
                if next < total {
                    let j = next
                    group.addTask {
                        if !macSubjectsBySeg[j].isEmpty {
                            return (j, GeneratedTags(subjectTags: macSubjectsBySeg[j]))   // Mac-tagged → no LLM
                        }
                        let tags = await generator.generateTags(
                            for: snapshot[j], nearbySegments: nearbyBySeg[j],
                            provider: provider, model: model, thinkingLevel: nil,
                            apiKey: apiKey, vocabulary: vocabulary, gatewayConfig: gateway
                        )
                        return (j, tags)
                    }
                    next += 1
                }
            }
        }
    }

    /// Apply generated tags to one segment's output PDFs, layering the Live Capture phone date on top
    /// and writing the segment JSON. Runs on the main actor (called from the tagging task group).
    private func applyGeneratedTags(_ rawTags: GeneratedTags, toSegmentAt i: Int, in snapshot: [DocumentSegment],
                                    enableSegmentJSON: Bool, outputDirectory: URL) {
        guard i < snapshot.count else { return }
        let segment = snapshot[i]
        var tags = rawTags
        // Live Capture: the phone's in-the-room date wins over the LLM's inferred date.
        if let firstURL = segment.pdfURLs.first,
           let fileIdx = jobs.firstIndex(where: { $0.sourceURL == firstURL }) {
            if let y = phoneYearTag(at: fileIdx) { tags.year = y; tags.dateUncertain = false }
            if let mo = phoneMonthTag(at: fileIdx) { tags.month = mo }
        }
        for sourceURL in segment.pdfURLs {
            if let outputPDF = outputURLMap[sourceURL] {
                try? MacOSTagger.applyTags(tags, to: outputPDF)
            }
            if let jobIndex = jobs.firstIndex(where: { $0.sourceURL == sourceURL }) {
                jobs[jobIndex].appliedTags = tags.allTags
            }
        }
        if enableSegmentJSON && !segment.isBox && !segment.isFolder {
            writeSegmentJSON(segment: segment, tags: tags, outputDirectory: outputDirectory)
        }
    }

    // MARK: - Segment JSON

    private func writeSegmentJSON(segment: DocumentSegment, tags: GeneratedTags, outputDirectory: URL) {
        guard let firstFile = segment.pdfURLs.first else { return }
        // Write JSON next to the output PDF, using its base name so they match
        let jsonURL: URL
        if let outputPDF = outputURLMap[firstFile] {
            jsonURL = outputPDF.deletingPathExtension().appendingPathExtension("json")
        } else {
            let baseName = firstFile.deletingPathExtension().lastPathComponent
            jsonURL = outputDirectory.appendingPathComponent(baseName + ".json")
        }

        // Build body text with image markers
        var bodyParts: [String] = []
        for (i, url) in segment.pdfURLs.enumerated() {
            let text = i < segment.texts.count ? segment.texts[i] : ""
            bodyParts.append("[Image: \(url.lastPathComponent)]")
            if !text.isEmpty {
                bodyParts.append(text)
            }
        }
        let bodyText = bodyParts.joined(separator: "\n\n")

        // Build JSON dictionary
        var dict: [String: Any] = [:]
        if let date = tags.machineDate {
            dict["date"] = date
        }
        dict["date_uncertain"] = tags.dateUncertain
        dict["subjects"] = tags.subjectTags.map { GeneratedTags.capitalizeFirstLetters($0) }

        if let v = tags.format { dict["format"] = v }
        if let v = tags.authorName { dict["author_name"] = v }
        if let v = tags.recipientName { dict["recipient_name"] = v }
        if let v = tags.authorLocation { dict["author_location"] = v }
        if let v = tags.recipientLocation { dict["recipient_location"] = v }
        if let v = tags.publicationName { dict["publication_name"] = v }

        if segment.isBox { dict["format"] = "box_label" }
        if segment.isFolder { dict["format"] = "folder_label" }

        dict["files"] = segment.pdfURLs.map { $0.lastPathComponent }
        dict["body"] = bodyText

        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: jsonURL, options: .atomic)
    }

    // MARK: - Document Merging

    /// Merge multi-page document segments into single PDFs.
    /// Each segment with >1 page gets combined. Single-page segments are left as-is.
    private func performDocumentMerging(files: [URL], outputDirectory: URL) {
        // Build segments from current classifications if not already built
        let segs: [DocumentSegment]
        if segments.isEmpty {
            let segmenter = DocumentSegmenter()
            let classifications = jobs.map { $0.result?.classification }
            let texts = jobs.map { $0.result?.text ?? "" }
            segs = segmenter.segment(files: files, classifications: classifications, texts: texts)
        } else {
            segs = segments
        }

        let multiPageSegments = segs.filter { $0.pdfURLs.count > 1 && !$0.isBox && !$0.isFolder }
        guard !multiPageSegments.isEmpty else { return }

        statusMessage = "Merging \(multiPageSegments.count) multi-page documents…"
        let pdfGen = PDFGenerator()

        for (segIdx, segment) in multiPageSegments.enumerated() {
            // Collect the individual output PDFs for this segment
            let sourcePDFs = segment.pdfURLs.compactMap { outputURLMap[$0] }
            guard sourcePDFs.count > 1 else { continue }

            // Name the merged PDF after the first page
            let firstSource = segment.pdfURLs[0]
            let baseName = firstSource.deletingPathExtension().lastPathComponent
            let mergedURL = outputDirectory.appendingPathComponent(baseName + "_merged.pdf")

            do {
                try pdfGen.mergeDocumentPDFs(sourcePDFs: sourcePDFs, outputURL: mergedURL)

                // Apply tags from the first page's individual PDF to the merged PDF
                if let firstJob = jobs.first(where: { $0.sourceURL == firstSource }) {
                    if !firstJob.appliedTags.isEmpty {
                        try? MacOSTagger.applyTags(firstJob.appliedTags, to: mergedURL)
                    }
                }

                // Delete the individual PDFs that were merged
                for pdfURL in sourcePDFs {
                    try? FileManager.default.removeItem(at: pdfURL)
                }

                // Rename the JSON file to match the merged PDF name
                let originalJSONURL = outputDirectory.appendingPathComponent(baseName + ".json")
                let mergedJSONURL = outputDirectory.appendingPathComponent(baseName + "_merged.json")
                if FileManager.default.fileExists(atPath: originalJSONURL.path) {
                    try? FileManager.default.moveItem(at: originalJSONURL, to: mergedJSONURL)
                }

                // Update outputURLMap: point all source URLs in this segment to the merged PDF
                for sourceURL in segment.pdfURLs {
                    outputURLMap[sourceURL] = mergedURL
                }

                statusMessage = "Merged document \(segIdx + 1)/\(multiPageSegments.count): \(baseName) (\(sourcePDFs.count) pages)"
            } catch {
                statusMessage = "Failed to merge \(baseName): \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Phase 4: Collection Segmentation

    private func performCollectionSegmentation(
        files: [URL],
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        outputDirectory: URL,
        confirmBeforeOrganizing: Bool = false,
        reviewDocumentSegmentation: Bool = false
    ) async {
        statusMessage = "Identifying collections from box labels…"

        let classifications = jobs.map { $0.result?.classification }
        let texts = jobs.map { $0.result?.text ?? "" }

        let segmenter = CollectionSegmenter()
        collectionSegments = await segmenter.segment(
            files: files,
            classifications: classifications,
            texts: texts,
            provider: provider,
            model: model,
            thinkingLevel: thinkingLevel,
            apiKey: apiKey,
            gatewayConfig: currentGateway,
            onStatus: { [weak self] msg in
                self?.statusMessage = msg
            }
        )

        guard !collectionSegments.isEmpty, !Task.isCancelled else { return }

        // If confirmation is requested, build review items and wait for user
        if confirmBeforeOrganizing {
            let hasBoxes = classifications.contains(where: { $0 == .boxLabel })
            buildReviewItems(files: files, classifications: classifications)
            if !hasBoxes {
                noBoxCollectionName = collectionSegments.first?.collectionName ?? "Uncategorized"
            }
            statusMessage = "Review collection names before proceeding."
            awaitingCollectionConfirmation = true

            // Suspend until the user confirms
            await withCheckedContinuation { continuation in
                collectionConfirmationContinuation = continuation
            }

            guard !Task.isCancelled else { return }

            if !hasBoxes {
                // No boxes — apply user-provided collection name
                let name = noBoxCollectionName.trimmingCharacters(in: .whitespacesAndNewlines)
                collectionSegments = [CollectionSegment(collectionName: name.isEmpty ? "Uncategorized" : name, fileURLs: files)]
            } else {
                // Apply user edits: rebuild collectionSegments from reviewItems
                applyReviewEdits(files: files)
            }
        }

        guard !collectionSegments.isEmpty, !Task.isCancelled else { return }

        // Document segmentation review: present per-collection dialogs sequentially
        if reviewDocumentSegmentation {
            await performDocumentSegmentationReview(files: files, outputDirectory: outputDirectory)
            guard !Task.isCancelled else { return }
        }

    }

    /// Build review items from current classifications and collection segments.
    /// Only includes box labels — segmentation is already finalized at this point.
    private func buildReviewItems(files: [URL], classifications: [DocumentClassification?]) {
        // Build a map from file URL to collection name using the current segments
        var fileToCollection: [URL: String] = [:]
        for segment in collectionSegments {
            for url in segment.fileURLs {
                fileToCollection[url] = segment.collectionName
            }
        }

        // Only include box labels for collection name review
        collectionReviewItems = files.enumerated().compactMap { (index, url) in
            let cls = index < classifications.count ? classifications[index] : nil
            guard cls == .boxLabel else { return nil }
            let collection = fileToCollection[url] ?? "Uncategorized"
            return CollectionReviewItem(
                fileIndex: index,
                fileName: url.lastPathComponent,
                fileURL: url,
                classification: cls,
                collectionName: collection,
                isBoxLabel: true
            )
        }
    }

    /// Apply user edits from review items back into collectionSegments.
    /// Rebuilds segmentation from scratch using the confirmed box/folder identifications.
    /// Also updates macOS Finder tags to reflect reclassifications.
    private func applyReviewEdits(files: [URL]) {
        // Build a lookup from file index to the reviewed item
        var reviewByIndex: [Int: CollectionReviewItem] = [:]
        for item in collectionReviewItems {
            reviewByIndex[item.fileIndex] = item
        }

        // Update job classifications and re-tag files whose classification changed
        for item in collectionReviewItems {
            if item.fileIndex < jobs.count {
                let oldClassification = jobs[item.fileIndex].classification
                let newClassification = item.classification
                jobs[item.fileIndex].classification = newClassification
                if let existingResult = jobs[item.fileIndex].result {
                    jobs[item.fileIndex].result = OCRResult(
                        text: existingResult.text,
                        classification: newClassification,
                        rotationDegrees: existingResult.rotationDegrees,
                        errorMessage: existingResult.errorMessage,
                        errorCode: nil
                    )
                }

                // Re-tag the output file if classification changed
                if oldClassification != newClassification,
                   let outputURL = outputURLMap[item.fileURL] {
                    let colorTag: String? = {
                        switch newClassification {
                        case .boxLabel: return "Red"
                        case .folderLabel: return "Purple"
                        default: return nil
                        }
                    }()
                    // Build updated tags: keep existing non-color tags, replace color
                    var existingTags = jobs[item.fileIndex].appliedTags
                    existingTags.removeAll { $0 == "Red" || $0 == "Purple" || $0 == "Box" || $0 == "Folder" }
                    if let color = colorTag {
                        existingTags.append(color)
                    }
                    if newClassification == .boxLabel {
                        if !existingTags.contains("Box") { existingTags.insert("Box", at: 0) }
                    } else if newClassification == .folderLabel {
                        if !existingTags.contains("Folder") { existingTags.insert("Folder", at: 0) }
                    }
                    try? MacOSTagger.applyTags(existingTags, to: outputURL)
                    jobs[item.fileIndex].appliedTags = existingTags
                }
            }
        }

        // Find box labels in order (user may have reclassified some)
        let boxIndices = collectionReviewItems
            .filter { $0.classification == .boxLabel }
            .sorted { $0.fileIndex < $1.fileIndex }

        guard !boxIndices.isEmpty else {
            // No boxes left — put everything in one collection
            collectionSegments = [CollectionSegment(collectionName: "Uncategorized", fileURLs: files)]
            return
        }

        // Walk all files, assigning each to the collection of the preceding box label
        var currentCollection = boxIndices[0].collectionName
        var collectionOrder: [String] = []
        var collectionFiles: [String: [URL]] = [:]

        for i in 0..<files.count {
            if let reviewed = reviewByIndex[i], reviewed.classification == .boxLabel {
                currentCollection = reviewed.collectionName
            }
            if collectionFiles[currentCollection] == nil {
                collectionOrder.append(currentCollection)
                collectionFiles[currentCollection] = []
            }
            collectionFiles[currentCollection]!.append(files[i])
        }

        collectionSegments = collectionOrder.map { name in
            CollectionSegment(collectionName: name, fileURLs: collectionFiles[name] ?? [])
        }
    }

    /// Called by the UI when the user confirms the collection review.
    func confirmCollectionReview() {
        awaitingCollectionConfirmation = false
        collectionConfirmationContinuation?.resume()
        collectionConfirmationContinuation = nil
    }

    // MARK: - Document Segmentation Review

    /// Present document segmentation review dialogs for each collection sequentially.
    private func performDocumentSegmentationReview(files: [URL], outputDirectory: URL) async {
        var needsCollectionRebuild = false

        // Iterate over a snapshot of collections (may change if user reclassifies)
        let collectionsSnapshot = collectionSegments

        for collection in collectionsSnapshot {
            guard !Task.isCancelled else { return }

            let classifications = jobs.map { $0.result?.classification }

            // Build review items for all files in this collection (skip box/folder labels)
            let items: [DocumentReviewItem] = collection.fileURLs.compactMap { url in
                guard let idx = files.firstIndex(of: url) else { return nil }
                let cls = idx < classifications.count ? classifications[idx] : nil
                guard cls != .boxLabel && cls != .folderLabel else { return nil }
                let rot = idx < jobs.count ? (jobs[idx].result?.rotationDegrees ?? 0) : 0
                return DocumentReviewItem(
                    fileIndex: idx,
                    fileName: url.lastPathComponent,
                    fileURL: url,
                    classification: cls,
                    rotationDegrees: rot
                )
            }

            guard !items.isEmpty else { continue }

            documentReviewItems = items.sorted { $0.fileIndex < $1.fileIndex }
            currentReviewCollectionName = collection.collectionName
            statusMessage = "Review document segmentation for \"\(collection.collectionName)\"."
            awaitingDocumentReview = true

            await withCheckedContinuation { continuation in
                documentReviewContinuation = continuation
            }

            guard !Task.isCancelled else { return }

            // Apply changes from review
            let changed = applyDocumentReviewEdits(outputDirectory: outputDirectory)
            if changed { needsCollectionRebuild = true }
        }

        // If any files were reclassified as box/folder, rebuild collection segments
        if needsCollectionRebuild {
            rebuildCollectionSegments(files: files)
        }
    }

    /// Called by the UI when the user confirms document segmentation review for a collection.
    func confirmDocumentReview() {
        awaitingDocumentReview = false
        documentReviewContinuation?.resume()
        documentReviewContinuation = nil
    }

    /// Called by the UI when the user completes the final review.
    func confirmFinalReview() {
        awaitingFinalReview = false
        finalReviewContinuation?.resume(returning: .complete)
        finalReviewContinuation = nil
    }

    /// Called by the UI when the user wants to redo segmentation and tagging.
    func redoTagging() {
        awaitingFinalReview = false
        finalReviewContinuation?.resume(returning: .redoTagging)
        finalReviewContinuation = nil
    }

    /// Update classification for a single file (used by inline editing from the file pane).
    func updateClassification(at index: Int, to newClassification: DocumentClassification) {
        guard index < jobs.count else { return }
        let oldClassification = jobs[index].classification
        jobs[index].classification = newClassification
        if let existingResult = jobs[index].result {
            jobs[index].result = OCRResult(
                text: existingResult.text,
                classification: newClassification,
                rotationDegrees: existingResult.rotationDegrees,
                errorMessage: existingResult.errorMessage,
                errorCode: nil
            )
        }
        // Update tags on the output file
        if oldClassification != newClassification,
           let outputURL = outputURLMap[jobs[index].sourceURL] {
            let colorTag: String? = {
                switch newClassification {
                case .boxLabel: return "Red"
                case .folderLabel: return "Purple"
                default: return nil
                }
            }()
            var existingTags = jobs[index].appliedTags
            existingTags.removeAll { $0 == "Red" || $0 == "Purple" || $0 == "Box" || $0 == "Folder" }
            if let color = colorTag { existingTags.append(color) }
            if newClassification == .boxLabel {
                if !existingTags.contains("Box") { existingTags.insert("Box", at: 0) }
            } else if newClassification == .folderLabel {
                if !existingTags.contains("Folder") { existingTags.insert("Folder", at: 0) }
            }
            try? MacOSTagger.applyTags(existingTags, to: outputURL)
            jobs[index].appliedTags = existingTags
        }
    }

    /// Show the document segmentation review dialog for all files at once.
    /// Populates documentReviewItems with every file and suspends until user confirms.
    private func showFullSegmentationReview(files: [URL]) async {
        documentReviewItems = files.enumerated().map { (index, url) in
            let cls = index < jobs.count ? jobs[index].result?.classification : nil
            let rot = index < jobs.count ? (jobs[index].result?.rotationDegrees ?? 0) : 0
            return DocumentReviewItem(
                fileIndex: index,
                fileName: url.lastPathComponent,
                fileURL: url,
                classification: cls,
                rotationDegrees: rot
            )
        }

        // New-Document / Continuation options are only meaningful when merging or when an
        // LLM-segmented tagging mode is used. In manual-segmentation modes the dedicated
        // grouping UI owns segmentation, so the rotation review shows only rotation + box/folder.
        reviewShowsDocumentClasses = mergeDocuments || taggingMode.showsDocumentClassesInReview
        currentReviewCollectionName = "All Files"
        statusMessage = "Review document segmentation."
        awaitingDocumentReview = true

        await withCheckedContinuation { continuation in
            documentReviewContinuation = continuation
        }

        guard !Task.isCancelled else { return }

        // Apply classification, rotation, and removal changes back to jobs
        for item in documentReviewItems {
            guard item.fileIndex < jobs.count else { continue }

            // Removal: drop this photo from output, tagging, and segments
            if item.markedForRemoval {
                removedSourceURLs.insert(item.fileURL)
                if let outputURL = outputURLMap[jobs[item.fileIndex].sourceURL] {
                    try? FileManager.default.removeItem(at: outputURL)
                    let jsonURL = outputURL.deletingPathExtension().appendingPathExtension("json")
                    try? FileManager.default.removeItem(at: jsonURL)
                    outputURLMap[jobs[item.fileIndex].sourceURL] = nil
                }
                jobs[item.fileIndex].status = .removed
                continue
            }

            let newCls = item.classification
            let newRot = item.rotationDegrees
            let oldRot = jobs[item.fileIndex].result?.rotationDegrees ?? 0
            jobs[item.fileIndex].classification = newCls
            if let existingResult = jobs[item.fileIndex].result {
                jobs[item.fileIndex].result = OCRResult(
                    text: existingResult.text,
                    classification: newCls,
                    rotationDegrees: newRot,
                    errorMessage: existingResult.errorMessage,
                    errorCode: nil
                )
            }
            // Regenerate output PDF if rotation changed
            if newRot != oldRot, let result = jobs[item.fileIndex].result,
               let outputURL = outputURLMap[jobs[item.fileIndex].sourceURL],
               let model = currentModel {
                let pdfGen = PDFGenerator()
                // Use temp JPEG if this was a PDF input, otherwise the original file
                let imageURL = pdfToImageMap[item.fileURL] ?? item.fileURL
                try? pdfGen.generate(
                    imageURL: imageURL,
                    result: result,
                    model: model,
                    outputURL: outputURL,
                    originalFileName: jobs[item.fileIndex].sourceURL.lastPathComponent,
                    gatewayDisplayName: currentGateway?.displayName
                )
            }
        }
    }

    // MARK: - Box/Folder Final Confirmation

    /// Present a final confirmation of every box/folder identification (after the rotation
    /// review). Reclassifications are written back into jobs, updating Red/Purple tags.
    private func showBoxFolderConfirmation(files: [URL]) async {
        let items: [DocumentReviewItem] = files.enumerated().compactMap { (index, url) in
            guard !removedSourceURLs.contains(url), index < jobs.count else { return nil }
            let cls = jobs[index].result?.classification
            guard cls == .boxLabel || cls == .folderLabel else { return nil }
            return DocumentReviewItem(
                fileIndex: index,
                fileName: url.lastPathComponent,
                fileURL: url,
                classification: cls,
                rotationDegrees: jobs[index].result?.rotationDegrees ?? 0
            )
        }

        // Nothing to confirm — skip the sheet entirely.
        guard !items.isEmpty else { return }

        boxFolderConfirmItems = items
        statusMessage = "Confirm box and folder identifications."
        awaitingBoxFolderConfirmation = true

        await withCheckedContinuation { continuation in
            boxFolderConfirmContinuation = continuation
        }

        guard !Task.isCancelled else { return }

        // Apply any reclassifications (updateClassification handles Red/Purple tag updates).
        for item in boxFolderConfirmItems where item.fileIndex < jobs.count {
            let newCls = item.classification ?? .documentStart
            if jobs[item.fileIndex].classification != newCls {
                updateClassification(at: item.fileIndex, to: newCls)
            }
        }
    }

    /// Called by the UI when the user confirms the box/folder review.
    func confirmBoxFolderReview() {
        awaitingBoxFolderConfirmation = false
        boxFolderConfirmContinuation?.resume()
        boxFolderConfirmContinuation = nil
    }

    /// Update rotation for a single file (used by inline editing from the file pane).
    func updateRotation(at index: Int, degrees: Int) {
        guard index < jobs.count, let existingResult = jobs[index].result else { return }
        let normalized = ((degrees % 360) + 360) % 360
        jobs[index].result = OCRResult(
            text: existingResult.text,
            classification: existingResult.classification,
            rotationDegrees: normalized,
            errorMessage: existingResult.errorMessage,
            errorCode: nil
        )
    }

    /// Rebuild collection segments from current job classifications after document review changes.
    /// Reuses existing collection names from collectionSegments where available.
    private func rebuildCollectionSegments(files: [URL]) {
        let classifications = jobs.map { $0.result?.classification }

        // Build a map of file URL to existing collection name
        var existingFileToCollection: [URL: String] = [:]
        for segment in collectionSegments {
            for url in segment.fileURLs {
                existingFileToCollection[url] = segment.collectionName
            }
        }

        // Find box labels and their collection names
        var boxMap: [Int: String] = [:]
        for (i, cls) in classifications.enumerated() {
            if cls == .boxLabel {
                // Prefer existing collection name if available
                if let existing = existingFileToCollection[files[i]] {
                    boxMap[i] = existing
                } else {
                    let text = jobs[i].result?.text ?? ""
                    let name = CollectionSegmenter.normalizeCollectionName(
                        text.components(separatedBy: .newlines).first ?? "Uncategorized"
                    )
                    boxMap[i] = name.isEmpty ? "Uncategorized" : name
                }
            }
        }

        guard !boxMap.isEmpty else {
            collectionSegments = [CollectionSegment(collectionName: "Uncategorized", fileURLs: files)]
            return
        }

        // Find the first box's collection name as the starting collection
        let sortedBoxIndices = boxMap.keys.sorted()
        var currentCollection = boxMap[sortedBoxIndices[0]]!
        var collectionOrder: [String] = []
        var collectionFiles: [String: [URL]] = [:]

        for i in 0..<files.count {
            if let name = boxMap[i] {
                currentCollection = name
            }
            if collectionFiles[currentCollection] == nil {
                collectionOrder.append(currentCollection)
                collectionFiles[currentCollection] = []
            }
            collectionFiles[currentCollection]!.append(files[i])
        }

        collectionSegments = collectionOrder.map { name in
            CollectionSegment(collectionName: name, fileURLs: collectionFiles[name] ?? [])
        }
    }

    /// Apply document segmentation review edits: update job classifications, re-tag, and rebuild collection segments if needed.
    /// Returns true if any files were reclassified as box or folder (requiring collection re-segmentation).
    @discardableResult
    private func applyDocumentReviewEdits(outputDirectory: URL) -> Bool {
        var collectionChanged = false

        for item in documentReviewItems {
            guard item.fileIndex < jobs.count else { continue }
            let oldClassification = jobs[item.fileIndex].classification
            let newClassification = item.classification

            jobs[item.fileIndex].classification = newClassification
            if let existingResult = jobs[item.fileIndex].result {
                jobs[item.fileIndex].result = OCRResult(
                    text: existingResult.text,
                    classification: newClassification,
                    rotationDegrees: item.rotationDegrees,
                    errorMessage: existingResult.errorMessage,
                    errorCode: nil
                )
            }

            if oldClassification != newClassification,
               let outputURL = outputURLMap[item.fileURL] {
                var existingTags = jobs[item.fileIndex].appliedTags
                // Remove old color/subject tags
                existingTags.removeAll { $0 == "Red" || $0 == "Purple" || $0 == "Box" || $0 == "Folder" }
                // Apply new tags based on classification
                switch newClassification {
                case .boxLabel:
                    existingTags.append("Red")
                    existingTags.insert("Box", at: 0)
                case .folderLabel:
                    existingTags.append("Purple")
                    existingTags.insert("Folder", at: 0)
                default:
                    break
                }
                try? MacOSTagger.applyTags(existingTags, to: outputURL)
                jobs[item.fileIndex].appliedTags = existingTags
            }

            // Track if any file was reclassified to/from box/folder
            if oldClassification != newClassification &&
               (newClassification == .boxLabel || newClassification == .folderLabel ||
                oldClassification == .boxLabel || oldClassification == .folderLabel) {
                collectionChanged = true
            }
        }

        // Re-run document segmentation with updated classifications
        let allFiles = jobs.map { $0.sourceURL }
        let updatedClassifications = jobs.map { $0.result?.classification }
        let texts = jobs.map { $0.result?.text ?? "" }
        let segmenter = DocumentSegmenter()
        segments = segmenter.segment(files: allFiles, classifications: updatedClassifications, texts: texts)

        return collectionChanged
    }

    // MARK: - Failed OCR Retry

    /// Called by UI when user chooses to retry failed files with a different provider/model.
    func retryFailedFiles(provider: LLMProvider, model: LLMModel, thinkingLevel: ThinkingLevel?, apiKey: String) {
        awaitingRetryDecision = false
        retryContinuation?.resume(returning: .retry(provider: provider, model: model, thinkingLevel: thinkingLevel, apiKey: apiKey))
        retryContinuation = nil
    }

    /// Called by UI when user chooses to continue without retrying.
    func continueWithoutRetry() {
        awaitingRetryDecision = false
        retryContinuation?.resume(returning: .continueWithout)
        retryContinuation = nil
    }

    /// Present retry dialog and wait for user decision. Returns the action chosen.
    private func promptRetryForFailedFiles() async -> RetryAction {
        failedFileIndices = jobs.indices.filter { jobs[$0].status == .failed }.sorted()
        guard !failedFileIndices.isEmpty else { return .continueWithout }

        statusMessage = "\(failedFileIndices.count) file(s) failed OCR. Review and retry or continue."
        awaitingRetryDecision = true

        return await withCheckedContinuation { continuation in
            retryContinuation = continuation
        }
    }

    /// Retry loop: keeps presenting the retry dialog until all files succeed or user continues.
    private func retryLoopForFailedFiles(
        imageURLs: [URL],
        outputDirectory: URL
    ) async {
        while true {
            guard !Task.isCancelled else { return }

            let failedCount = jobs.filter { $0.status == .failed }.count
            guard failedCount > 0 else { return }

            let action = await promptRetryForFailedFiles()

            switch action {
            case .continueWithout:
                return
            case .retry(let provider, let model, let thinkingLevel, let apiKey):
                let indicesToRetry = failedFileIndices
                statusMessage = "Retrying \(indicesToRetry.count) files with \(provider.rawValue) \(model.displayName)…"

                for (attempt, index) in indicesToRetry.enumerated() {
                    guard !Task.isCancelled else { return }
                    jobs[index].status = .processing

                    let url = imageURLs[index]
                    let result = await Self.performOCRCall(
                        imageURL: url,
                        provider: provider,
                        model: model,
                        thinkingLevel: thinkingLevel,
                        apiKey: apiKey,
                        previousText: nil,
                        previousImageURL: nil,
                        gatewayConfig: currentGateway
                    )

                    handleOCRResult(result, index: index, url: url, model: model, outputDirectory: outputDirectory)

                    if result.text != nil {
                        failedFiles.removeAll { $0 == jobs[index].sourceURL.lastPathComponent }
                    }

                    progress = Double(attempt + 1) / Double(indicesToRetry.count)
                    statusMessage = "Retried \(attempt + 1)/\(indicesToRetry.count)"
                }
            }
            // Loop back — if there are still failures, the dialog will appear again
        }
    }

    // MARK: - Log

    // MARK: - Resolution Test

    /// Run a single OCR call at a given image scale for resolution testing. Public so the UI can call it.
    nonisolated static func performResolutionTestCall(
        imageURL: URL, provider: LLMProvider, model: LLMModel,
        thinkingLevel: ThinkingLevel?, apiKey: String,
        imageScale: Double,
        gatewayConfig: GatewayConfig? = nil
    ) async -> OCRResult {
        await performOCRCall(
            imageURL: imageURL, provider: provider, model: model,
            thinkingLevel: thinkingLevel, apiKey: apiKey,
            previousText: nil, previousImageURL: nil,
            imageScale: imageScale,
            gatewayConfig: gatewayConfig
        )
    }

    // MARK: - Notifications

    /// Request notification permission (call once at app launch).
    static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Post a local notification summarizing the completed run.
    private func postCompletionNotification() {
        let succeeded = jobs.filter { $0.status == .succeeded }.count
        let failed = failedFiles.count
        let content = UNMutableNotificationContent()
        content.title = "Processing Complete"
        content.body = "\(succeeded) succeeded, \(failed) failed."
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func writeLogFile(outputDirectory: URL) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "d MMMM yyyy HH:mm"
        let dateStr = dateFormatter.string(from: Date())

        var lines = ["Archive Processor — OCR Log", "Date: \(dateStr)", ""]
        let removedCount = jobs.filter { $0.status == .removed }.count
        lines.append("Total files: \(jobs.count)")
        lines.append("Succeeded: \(jobs.filter { $0.status == .succeeded }.count)")
        lines.append("Failed: \(failedFiles.count)")
        if removedCount > 0 { lines.append("Removed during review: \(removedCount)") }
        if !segments.isEmpty {
            lines.append("Document segments: \(segments.count)")
        }
        lines.append("")

        if failedFiles.isEmpty {
            lines.append("All files processed successfully.")
        } else {
            lines.append("Files that did not produce OCR text:")
            for f in failedFiles {
                let job = jobs.first { $0.sourceURL.lastPathComponent == f }
                let reason = job?.result?.errorMessage ?? "Unknown error"
                let code = job?.result?.errorCode.map { " [\($0)]" } ?? ""
                lines.append("  \u{2022} \(f)\(code): \(reason)")
            }
        }

        let content = lines.joined(separator: "\n")
        let timestamp = Int(Date().timeIntervalSince1970)
        let logURL = outputDirectory.appendingPathComponent("ArchiveProcessor_Log_\(timestamp).txt")
        try? content.write(to: logURL, atomically: true, encoding: .utf8)
    }
}
