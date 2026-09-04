import Foundation

// Processing history: a persistent log of completed Process-Files runs, so the operator can see
// what was processed, when, with which model, and roughly what it cost.
//
// Design notes:
// - "Cost" is computed from `CostEstimator` on each run's ACTUAL parameters (real file count, model,
//   batch mode, resolution, rotation/tagging settings). No provider returns per-call token usage, so
//   this is the SAME per-model pricing math the pre-run estimator shows — applied to what actually ran,
//   not a fixed 1,000-file sample. It is a close estimate of real spend, NOT a billed figure; the UI
//   labels it accordingly.
// - Storage mirrors `ProcessingProfileStore`: a JSON-encoded array under a single `DefaultsKeys` string
//   in UserDefaults (never the corpus, never a real file). The log is bounded (`maxRuns`) so it can't
//   grow without limit; the oldest entries drop off.
// - This records the **Process Files** pipeline only (the batch "run" with a file list + estimate).
//   Live Capture is a streaming session, not a file-count run, and lives behind the Tier-2 `Capture/`
//   path — session-level history would be a separate follow-up.

/// One completed Process-Files run, persisted for the processing-history view.
struct ProcessingRun: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// When the run started.
    var date: Date
    /// Provider display label (a direct provider, a gateway name, or the Local Agent CLI).
    var providerLabel: String
    /// Model display name (a gateway model id or Local Agent override when applicable).
    var modelName: String
    var fileCount: Int
    var succeeded: Int
    var failed: Int
    var batchMode: Bool
    /// Short human label for the pipeline path: "Standard" / "Batch" / "Pre-OCRed" / "Re-OCR PDF".
    var modeLabel: String
    /// USD, estimator-derived on the run's actual parameters (see file header). A close estimate, not billed.
    var cost: Double
}

/// Parameters captured at the START of a Process-Files run so the pipeline's completion tails can
/// record an accurate history entry regardless of which terminal path they take (some paths clear
/// `activePendingRun` before the tail, so the config can't be read back there). Purely in-memory.
struct RunHistorySnapshot {
    let startedAt: Date
    let provider: LLMProvider
    let gatewayConfig: GatewayConfig?
    /// The subscription-authenticated CLI that actually produced this run, if any.
    let localAgent: LocalAgentConfig?
    /// Upstream family for a gateway run (drives the estimator's image-token math); nil when not a gateway.
    let imageTokenProvider: LLMProvider?
    let model: LLMModel
    /// A direct LLM used only after Apple Vision transcribed the image locally. Kept separate from
    /// `model` so history never prices the Vision leg as a cloud image request.
    let visionTextProvider: LLMProvider?
    let visionTextModel: LLMModel?
    let batchMode: Bool
    let enableTagging: Bool
    let enableCollectionSegmentation: Bool
    let preOCRedInput: Bool
    let reOCRMultiPagePDF: Bool
    let sendPreviousImage: Bool
    let contextCharCount: Int
    let imageScale: Double
    let rotationMode: RotationMode
    let fileCount: Int

    /// Cost of this run using the exact same per-model math the pre-run estimator uses (standard vs
    /// batch total picked by `batchMode`).
    var estimatedCost: Double {
        // A Local Agent consumes the operator's CLI subscription, never this app's API budget.
        guard localAgent == nil else { return 0 }
        let costModel = visionTextModel ?? model
        let est = CostEstimator.estimate(
            fileCount: fileCount,
            model: costModel,
            enableTagging: enableTagging,
            enableCollectionSegmentation: enableCollectionSegmentation,
            preOCRedInput: preOCRedInput,
            sendPreviousImage: sendPreviousImage,
            contextCharCount: contextCharCount,
            imageScale: imageScale,
            rotationMode: rotationMode,
            useGateway: gatewayConfig != nil,
            imageTokenProvider: imageTokenProvider,
            visionTextOnly: visionTextModel != nil
        )
        return batchMode ? est.totalBatch : est.totalStandard
    }

    var providerLabel: String {
        if let localAgent { return localAgent.provenanceDisplayName }
        if let visionTextProvider { return "Apple Vision + \(visionTextProvider.rawValue)" }
        return gatewayConfig?.displayName ?? provider.rawValue
    }

    var modelName: String {
        if let localAgent { return localAgent.provenanceModelName }
        return visionTextModel.map { "Vision + \($0.displayName)" } ?? model.displayName
    }

    var modeLabel: String {
        if reOCRMultiPagePDF { return "Re-OCR PDF" }
        if preOCRedInput { return "Pre-OCRed" }
        return batchMode ? "Batch" : "Standard"
    }

    /// Build the persisted record for this run given its final success count. `failed` is derived so
    /// succeeded + failed always equals the file count (a run either produces output or is a failure).
    func makeRun(succeeded: Int) -> ProcessingRun {
        let ok = max(0, min(succeeded, fileCount))
        return ProcessingRun(
            date: startedAt,
            providerLabel: providerLabel,
            modelName: modelName,
            fileCount: fileCount,
            succeeded: ok,
            failed: fileCount - ok,
            batchMode: batchMode,
            modeLabel: modeLabel,
            cost: estimatedCost
        )
    }
}

extension RunHistorySnapshot {
    /// Build a history snapshot for a RESUMED non-batch run. V2 callers pass values restored from the
    /// immutable runtime snapshot; legacy callers pass the historical live-setting fallbacks because old
    /// manifests never recorded them. `fileCount` is the WHOLE run: resume never
    /// re-charges files already completed, but the recorded cost is the full run's estimate, matching the
    /// pre-run pane the operator saw. Tagging is keyed off the supplied effective mode.
    init(resuming run: OCRProcessor.PendingRun, taggingMode: TaggingMode,
         rotationMode: RotationMode, imageScale: Double, imageTokenProvider: LLMProvider?) {
        self.init(
            startedAt: run.startedAt,
            provider: run.provider,
            gatewayConfig: run.gatewayConfig,
            localAgent: run.localAgent,
            imageTokenProvider: run.gatewayConfig != nil ? imageTokenProvider : nil,
            model: run.model,
            visionTextProvider: run.runtimeConfig?.visionTextProvider,
            visionTextModel: run.runtimeConfig?.visionTextModel,
            batchMode: false,
            enableTagging: taggingMode.llmTags,
            enableCollectionSegmentation: run.enableCollectionSegmentation,
            preOCRedInput: run.preOCRedInput,
            reOCRMultiPagePDF: false,
            sendPreviousImage: run.sendPreviousImage,
            contextCharCount: run.previousTextCharCount,
            imageScale: imageScale,
            rotationMode: rotationMode,
            fileCount: run.fileURLs.count
        )
    }

    /// Build a history snapshot for a RESUMED batch run from its persisted manifest plus the live
    /// image-scale + rotation mode. A batch run is never a gateway run (the gateway path forces
    /// `batchMode = false`) and carries no previous-text context, so those inputs are fixed.
    init(resuming batch: OCRProcessor.PendingBatch, rotationMode: RotationMode, imageScale: Double) {
        self.init(
            startedAt: batch.submittedAt,
            provider: batch.provider,
            gatewayConfig: nil,
            localAgent: nil,
            imageTokenProvider: nil,
            model: batch.model,
            visionTextProvider: nil,
            visionTextModel: nil,
            batchMode: true,
            enableTagging: batch.taggingMode.llmTags,
            enableCollectionSegmentation: batch.enableCollectionSegmentation,
            preOCRedInput: false,
            reOCRMultiPagePDF: false,
            sendPreviousImage: batch.sendPreviousImage,
            contextCharCount: 0,
            imageScale: imageScale,
            rotationMode: rotationMode,
            fileCount: batch.fileURLs.count
        )
    }
}

/// Durable, bounded log of completed Process-Files runs (JSON in UserDefaults; never the corpus).
/// Mirrors `ProcessingProfileStore`'s storage shape.
final class ProcessingHistoryStore: ObservableObject, @unchecked Sendable {
    static let shared = ProcessingHistoryStore()

    /// Most-recent run first.
    @Published private(set) var runs: [ProcessingRun] = []

    /// Cap so the log can't grow without bound; the oldest runs drop off once exceeded.
    static let maxRuns = 200

    /// Backing store. Production uses `.standard`; the headless self-test injects a throwaway suite so it
    /// never touches the operator's real history (see `ProcessingHistoryTestDriver`).
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// Append a finished run (newest-first) and persist. Trims to `maxRuns`.
    func record(_ run: ProcessingRun) {
        runs.insert(run, at: 0)
        if runs.count > Self.maxRuns {
            runs.removeLast(runs.count - Self.maxRuns)
        }
        persist()
    }

    func clear() {
        runs = []
        persist()
    }

    var totalCost: Double { runs.reduce(0) { $0 + $1.cost } }
    var totalFiles: Int { runs.reduce(0) { $0 + $1.fileCount } }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(runs) else { return }
        defaults.set(data, forKey: DefaultsKeys.processingHistory)
    }

    private func load() {
        guard let data = defaults.data(forKey: DefaultsKeys.processingHistory),
              let decoded = try? JSONDecoder().decode([ProcessingRun].self, from: data) else { return }
        runs = decoded
    }
}
