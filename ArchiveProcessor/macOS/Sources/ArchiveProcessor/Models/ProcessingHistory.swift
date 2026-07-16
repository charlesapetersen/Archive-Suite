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
    /// Provider display label ("Anthropic" / "Google Gemini" / "Mistral", or the gateway's name).
    var providerLabel: String
    /// Model display name (for a gateway run, the gateway model id).
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
    /// Upstream family for a gateway run (drives the estimator's image-token math); nil when not a gateway.
    let imageTokenProvider: LLMProvider?
    let model: LLMModel
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
        let est = CostEstimator.estimate(
            fileCount: fileCount,
            model: model,
            enableTagging: enableTagging,
            enableCollectionSegmentation: enableCollectionSegmentation,
            preOCRedInput: preOCRedInput,
            sendPreviousImage: sendPreviousImage,
            contextCharCount: contextCharCount,
            imageScale: imageScale,
            rotationMode: rotationMode,
            useGateway: gatewayConfig != nil,
            imageTokenProvider: imageTokenProvider
        )
        return batchMode ? est.totalBatch : est.totalStandard
    }

    var providerLabel: String { gatewayConfig?.displayName ?? provider.rawValue }

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
            modelName: model.displayName,
            fileCount: fileCount,
            succeeded: ok,
            failed: fileCount - ok,
            batchMode: batchMode,
            modeLabel: modeLabel,
            cost: estimatedCost
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

    private init() { load() }

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
        UserDefaults.standard.set(data, forKey: DefaultsKeys.processingHistory)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKeys.processingHistory),
              let decoded = try? JSONDecoder().decode([ProcessingRun].self, from: data) else { return }
        runs = decoded
    }
}
