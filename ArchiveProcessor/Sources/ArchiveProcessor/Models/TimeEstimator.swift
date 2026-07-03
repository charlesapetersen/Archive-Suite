import Foundation

/// Rough wall-clock estimate of *processing* time for a batch — network + LLM generation only, not
/// any human interaction (review dialogs, tagging cards, naming). Grounded in measured
/// `gemini-2.5-flash-lite` latency: ~0.45 s to first token (incl. image prefill) + ~140 output
/// tokens/s, so per-call time is driven by how much text each call generates (using the same output
/// token estimates as the cost model). Rotation is upload-bound (4 candidate images, 1 letter out)
/// at ~3 s/comparison. Models the pipeline's concurrency: OCR runs 4-wide (sequential if previous-text
/// context is used), tagging 6-wide, and rotation runs concurrently with each page's OCR.
///
/// Assumes interactive (non-batch) processing; batch mode returns asynchronously (minutes–hours).
struct TimeEstimate {
    let ocrSeconds: Double
    let rotationSeconds: Double     // overlaps OCR (shown for reference)
    let taggingSeconds: Double
    let collectionSeconds: Double
    let totalSeconds: Double

    static func fmt(_ s: Double) -> String {
        if s < 1 { return "0 sec" }
        if s < 90 { return "~\(Int((s / 5).rounded()) * 5) sec" }
        let min = s / 60
        if min < 90 { return "~\(Int(min.rounded())) min" }
        return "~\(String(format: "%.1f", min / 60)) hr"
    }
    var ocrFormatted: String { Self.fmt(ocrSeconds) }
    var rotationFormatted: String { Self.fmt(rotationSeconds) }
    var taggingFormatted: String { Self.fmt(taggingSeconds) }
    var collectionFormatted: String { Self.fmt(collectionSeconds) }
    var totalFormatted: String { Self.fmt(totalSeconds) }
}

struct TimeEstimator {
    // Measured on gemini-2.5-flash-lite.
    static let ttftSeconds: Double = 0.45            // time to first token, incl. ~2048px image prefill
    static let outputTokensPerSecond: Double = 140   // generation rate
    static let rotationAskSeconds: Double = 3.0      // one 4-image comparison (upload-bound), ~measured

    static let ocrParallelWorkers: Double = 4        // when no previous-text context
    static let tagParallelWorkers: Double = 6

    /// Per-LLM-call seconds: first-token latency + generation of `outputTokens`, scaled by model speed.
    static func callSeconds(outputTokens: Double, speed: Double) -> Double {
        ttftSeconds + (outputTokens / outputTokensPerSecond) * speed
    }

    /// Coarse generation-speed factor relative to a flash-lite-class model (bigger models are slower).
    static func speedFactor(for model: LLMModel) -> Double {
        let id = model.id.lowercased()
        if id.contains("lite") { return 1.0 }
        if id.contains("opus") { return 2.8 }
        if id.contains("sonnet") { return 1.6 }
        if id.contains("pro") { return 2.2 }
        if id.contains("flash") { return 1.2 }
        if id.contains("mistral") || id.contains("ocr") { return 1.0 }
        return 1.6
    }

    static func estimate(
        fileCount: Int,
        model: LLMModel,
        rotationMode: RotationMode = .off,
        sequentialOCR: Bool = false,
        enableTagging: Bool,
        enableCollectionSegmentation: Bool = false,
        preOCRedInput: Bool = false,
        useGateway: Bool = false,
        ocrWorkers: Int = 4
    ) -> TimeEstimate {
        let n = Double(fileCount)
        let speed = speedFactor(for: model)
        let maxWorkers = Double(max(1, ocrWorkers))

        // OCR (image → full transcription), or text-only classification for pre-OCRed input.
        var ocr = 0.0
        let w = sequentialOCR ? 1.0 : maxWorkers
        if preOCRedInput {
            if enableTagging || enableCollectionSegmentation {
                ocr = ceil(n / maxWorkers) * callSeconds(outputTokens: CostEstimator.estimatedClassificationOutputTokens, speed: speed)
            }
        } else {
            ocr = ceil(n / w) * callSeconds(outputTokens: CostEstimator.estimatedOutputTokens, speed: speed)
        }

        // Rotation — concurrent with each page's OCR (per image: `orderings` sequential comparisons).
        var rotation = 0.0
        let rotCalls = rotationMode.orderings
        if rotCalls > 0, !preOCRedInput, !useGateway, model.provider != .mistral {
            let rotSpeed = model.provider == .anthropic ? 1.6 : 1.0   // gemini rotation uses flash-lite
            rotation = ceil(n / w) * Double(rotCalls) * (rotationAskSeconds * rotSpeed)
        }

        // Tagging (text → JSON), 6-wide, ~1 call per 3 files.
        var tagging = 0.0
        if enableTagging {
            let segments = max(1.0, n / 3.0)
            tagging = ceil(segments / tagParallelWorkers) * callSeconds(outputTokens: CostEstimator.estimatedTaggingOutputTokens, speed: speed)
        }

        // Collection ID (box labels + one clustering call).
        var collection = 0.0
        if enableCollectionSegmentation {
            let boxes = max(1.0, n / 7.0)
            collection = ceil(boxes / tagParallelWorkers) * callSeconds(outputTokens: CostEstimator.estimatedCollectionOutputTokens, speed: speed)
                       + callSeconds(outputTokens: CostEstimator.estimatedClusteringOutputTokens, speed: speed)
        }

        // OCR and rotation overlap per page → the phase takes the longer of the two.
        let total = max(ocr, rotation) + tagging + collection
        return TimeEstimate(ocrSeconds: ocr, rotationSeconds: rotation,
                            taggingSeconds: tagging, collectionSeconds: collection, totalSeconds: total)
    }
}
