import Foundation

struct CostEstimate {
    let ocrCost: Double
    let classificationCost: Double
    let taggingCost: Double
    let collectionCost: Double
    let rotationCost: Double
    let batchOcrCost: Double
    let fileCount: Int
    let model: LLMModel
    /// W49.proc-fix-s041: the dating route's calls a document (`DateRoute.run`) and the item-field call
    /// (`ItemFieldExtractor.extract`), which go out after tagging and are never batched.
    var datingCost: Double = 0
    var itemFieldCost: Double = 0
    var namesCost: Double = 0

    private var afterOCR: Double {
        classificationCost + taggingCost + collectionCost + rotationCost + datingCost + itemFieldCost + namesCost
    }
    var totalStandard: Double { ocrCost + afterOCR }
    var totalBatch: Double { batchOcrCost + afterOCR }

    /// Dollars and cents from $1 up ("$34.65"); four decimals below it, where a page's cost lives ("$0.0012").
    static func money(_ v: Double) -> String { "$" + String(format: abs(v) >= 1 ? "%.2f" : "%.4f", v) }
    var ocrFormatted: String { Self.money(ocrCost) }
    var classificationFormatted: String { Self.money(classificationCost) }
    var taggingFormatted: String { Self.money(taggingCost) }
    var collectionFormatted: String { Self.money(collectionCost) }
    var rotationFormatted: String { Self.money(rotationCost) }
    var datingFormatted: String { Self.money(datingCost) }
    var itemFieldFormatted: String { Self.money(itemFieldCost) }
    var namesFormatted: String { Self.money(namesCost) }
    var totalStandardFormatted: String { Self.money(totalStandard) }
}

struct CostEstimator {
    // OCR: image tokens + prompt (including classification instruction + context) + output (OCR text + classification tag)
    static let estimatedPromptTokens: Double = 400       // classification prompt + context text
    static let estimatedOutputTokens: Double = 850       // OCR text + classification tag

    // Image token estimates per provider (calibrated from actual API costs).
    // Gemini tiles high-res images extensively (~40k tokens per archival photo).
    // Anthropic uses a more compact image encoding (~6k tokens per photo).
    // Mistral OCR endpoint has flat per-page pricing, reflected as equivalent tokens at its $1 per million: OCR 4.1
    // (what `mistral-ocr-latest` resolved to) is $4 per 1,000 pages (`settings-routes.json`, W43.app-guide-refresh),
    // so 2,750 image tokens plus the prompt's 400 and the output's 850.
    static func estimatedImageTokens(for provider: LLMProvider) -> Double {
        switch provider {
        case .gemini: return 40_000
        case .anthropic: return 6_000
        case .mistral: return 2_750
        case .openai: return 1_500   // OpenAI bills images as tokens via tiling; ~1.5k ≈ a full-page high-detail scan. Refine if the keyed live smoke shows drift.
        case .appleVision: return 0   // runs in-process; it has no billable image-token accounting
        // W41.app-openrouter: the OCR panel's logged prompt tokens on its pinned providers, less the ~400-token
        // prompt: Qwen3-VL 235B 4,091 a page, Qwen3.6 27B 3,351 (99 and 135 calls, 2,400 px pages). The larger.
        // A maker's model through OpenRouter is priced by its maker's tokens (`LLMModel.measuredModel`).
        case .openrouter: return 3_700
        }
    }

    /// Thinking tokens a model spends per OCR page, billed at its output rate. Gemini 3.8 Flash thinks even
    /// with no thinking level set: ~117 a page in the W41 pilot (W41.app-ocr-default-fu1).
    /// GLM-5.3 Flash reasons at minimal on OpenRouter: 153 tokens a call over the Deaver windows (cheap-models.md).
    /// A maker's model through OpenRouter counts as itself (W41.app-openrouter-any), as its image tokens do.
    static func estimatedThinkingTokens(for model: LLMModel) -> Double {
        switch model.measuredModel.id {
        case "gemini-3.8-flash": return 117
        case "z-ai/glm-5.3-flash": return 153
        // W41.app-openrouter-unmeasured: an unmeasured OpenRouter model that reasons, at the room its request is given.
        default:
            return model.provider == .openrouter && model.supportsThinking && OpenRouterRoute.forModel(model.id) == nil
                ? Double(OpenAICompatibleClient.openRouterReasoningAllowance) : 0
        }
    }

    /// One page read by a second reader (`OCRRefusalFallback`) at that model's standard rate: image, prompt
    /// and output, no context, no previous image. A claude-by-plan route is not money and is never priced here.
    static func secondReaderPageCost(model: LLMModel, imageScale: Double) -> Double {
        estimate(fileCount: 1, model: model, enableTagging: false, sendPreviousImage: false,
                 contextCharCount: 0, imageScale: imageScale).ocrCost
    }

    // Tagging: text-only, ~1 call per segment (~3 files/segment average)
    static let estimatedTaggingInputTokens: Double = 1500
    static let estimatedTaggingOutputTokens: Double = 200

    /// Documents a run's tagging, dating and item-field calls go to: ~3 files a document. The W40.d1 paid run on
    /// the RG 165 box made 41 of each for 113 photos (2.8 a document).
    static func estimatedDocuments(_ fileCount: Int) -> Double { max(1.0, Double(fileCount) / 3.0) }

    // Dating (W49.proc-fix-s041): the trace call goes to every document a run tags, on the run's own text route, or on
    // the measured route where that runs (`DateRoute.Backend.measured`, a remote gateway). Its prompt is ~1,100
    // characters of template, 3,000 of the document's text and up to 600 of each of six neighbours (~2,000 tokens);
    // the reply is the date with its evidence.
    static let estimatedDateTraceInputTokens: Double = 2000
    static let estimatedDateTraceOutputTokens: Double = 300
    /// The measured route's calls on Gemini 3.7 Flash through the gateway, the mean per call over the W46.date-route-
    /// pipeline ledger at 3.8's list price as a ceiling (the gateway's own figure was 1.00 times it):
    /// trace 362 calls, $0.00220; the image pass on the first two pages, 366 calls, $0.00284
    /// (`segbench-results/date-route-pipeline.md`, "Cost and time").
    static let gatewayDateTraceCallCost = 0.00220
    static let gatewayDateImageCallCost = 0.00284
    /// The image pass runs where the document's own text has no year: 32% of the owner's mix in the same report.
    /// With "date image on every document" on, every document.
    static let dateImageShare = 0.32
    /// The item-field call (measured route only, sidecars on) sends every page's image at 1,600 px (the first 8 and
    /// last 2 of a longer document) and their text. Its bench run was the same call: drafts/gemini, $1.00 over 299
    /// documents of 627 pages (`segbench-results/item-fields-retruth.md`, "Spend"), so it is priced by the page.
    static let gatewayItemFieldPageCost = 1.00 / 627

    // One names call on the run's text route. W46's 3,000-character prompt averaged 924 input tokens on
    // Gemini 3.8 Flash, whose reasoning averaged 820 tokens (ent-8k-paired.md). Allow 100 for the JSON reply.
    static let estimatedNamesInputTokens = 925.0
    static let estimatedNamesOutputTokens = 100.0

    // Collection segmentation: text-only calls (~500 input + 50 output per box, plus one clustering call)
    static let estimatedCollectionInputTokens: Double = 500
    static let estimatedCollectionOutputTokens: Double = 50
    static let estimatedClusteringInputTokens: Double = 800
    static let estimatedClusteringOutputTokens: Double = 200

    // Text-only classification: prompt (~600 tokens) + short output (~10 tokens)
    static let estimatedClassificationInputTokens: Double = 600
    static let estimatedClassificationOutputTokens: Double = 10

    // Rotation (LLM comparative call): 4 downscaled (~800px) candidate images + a short prompt,
    // one letter of output. `.llmSingle` = 1 call/file, `.llmMajority` = 3 calls/file. Always runs
    // on a fixed cheap model (gemini-2.5-flash-lite for Gemini, claude-sonnet-4-6 for Anthropic,
    // gpt-5.4-mini for OpenAI); Gateway/Mistral fall back to free local Vision.
    static let estimatedRotationPromptTokens: Double = 90
    /// One comparative call to Gemini 3.7 Flash through the gateway, at list: W46.rotation-routes' llmSingle row,
    /// $0.0037 a page (an estimate; the gateway returns no bill per call).
    static let gatewayRotationCallCost = 0.0037
    /// Gateway rotation calls a page: the orderings for the LLM modes, the escalated share for the agreement rule.
    static func gatewayRotationCalls(_ mode: RotationMode) -> Double {
        mode == .agreement ? RotationMode.agreementEscalationShare : Double(mode.orderings)
    }
    static let estimatedRotationOutputTokens: Double = 5
    static func estimatedRotationCandidateTokens(for provider: LLMProvider) -> Double {
        switch provider {                       // per 800px candidate image
        case .anthropic: return 650
        case .openai: return 765                // ~85 base + tiled 800px (OpenAI bills images as tokens)
        default: return 600
        }
    }
    /// (inputCostPer1M, outputCostPer1M) of the fixed model used for rotation, or nil if rotation
    /// is free/unavailable for this provider.
    static func rotationModelCost(for provider: LLMProvider) -> (Double, Double)? {
        switch provider {
        case .gemini: return (0.0375, 0.15)     // gemini-2.5-flash-lite
        case .anthropic: return (3.0, 15.0)     // claude-sonnet-4-6
        case .mistral: return nil               // no LLM rotation path → local Vision (free)
        case .openai: return (0.75, 4.50)       // gpt-5.4-mini; verified 2026-09-26 against OpenAI's model page.
        case .appleVision: return nil
        case .openrouter: return nil            // no LLM rotation route measured → local Vision (free)
        }
    }

    static func estimate(
        fileCount: Int,
        model: LLMModel,
        enableTagging: Bool,
        enableCollectionSegmentation: Bool = false,
        preOCRedInput: Bool = false,
        sendPreviousImage: Bool,
        contextCharCount: Int,
        imageScale: Double = 1.0,
        rotationMode: RotationMode = .off,
        useGateway: Bool = false,
        imageTokenProvider: LLMProvider? = nil,
        /// Apple Vision supplied the OCR text locally; `model` prices only the following text-only
        /// classification/tagging/collection calls. This is intentionally a separate flag rather than
        /// treating Vision as an image-token provider, which would make it easy to bill image OCR again.
        visionTextOnly: Bool = false,
        /// In pre-OCRed runs, manual tagging still classifies text without existing classification.
        classifyPreOCRedInput: Bool? = nil,
        /// The run's rotation calls go to a remote gateway's `LLMRotationDetector.gatewayModel` (not a model on this
        /// Mac, not Apple Vision): priced at the measured per-call figure (W46.rotation-default).
        gatewayRotation: Bool = false,
        /// The run's backend is a remote gateway (`DateRoute.measuredRoute`): the dating route's calls go to its
        /// measured model, the image pass with them, and the item-field call runs.
        measuredRoute: Bool = false,
        /// The Dates card's "image on every document" switch (`SettingsKey.dateImageEveryDocument`).
        dateImageEveryDocument: Bool = false,
        /// The run writes JSON sidecars, which hold the item fields and correspondence names.
        sidecars: Bool = false,
        /// Fraction of tagged documents expected to make the names call (`EntityRunPolicy.estimatedCallShare`).
        namesCallShare: Double = 0
    ) -> CostEstimate {
        // Apple Vision is an in-process macOS framework. It never calls a provider and the V1 backend
        // exposes only transcription / source-tag copying, so every estimated dollar component is $0.
        if model.provider == .appleVision && !visionTextOnly {
            return CostEstimate(ocrCost: 0, classificationCost: 0, taggingCost: 0, collectionCost: 0,
                                rotationCost: 0, batchOcrCost: 0, fileCount: fileCount, model: model)
        }
        // OCR cost (zero when using pre-OCRed PDFs).
        // `imageScale` is the size-target slider fraction; for a standard-size file it equals the
        // image *area* fraction (target size ∝ area), so image tokens scale linearly with it.
        var ocrCost: Double = 0
        var batchOcrCost: Double = 0
        if !preOCRedInput && !visionTextOnly {
            let scaleArea = max(0.01, min(1.0, imageScale))   // defensive clamp against stale/out-of-range values
            // For a gateway, model.provider is a stand-in (.anthropic); use the caller-supplied upstream
            // family so a Gemini-behind-gateway isn't under-estimated ~6.7×.
            let imgTokens = estimatedImageTokens(for: imageTokenProvider ?? model.measuredModel.provider) * scaleArea
            let contextTokens = Double(contextCharCount) / 4.0 // ~4 chars per token
            let inputPerFile = estimatedPromptTokens + imgTokens + contextTokens
                + (sendPreviousImage ? imgTokens : 0)
            let totalOcrInput = Double(fileCount) * inputPerFile
            let totalOcrOutput = Double(fileCount) * (estimatedOutputTokens + estimatedThinkingTokens(for: model))
            ocrCost = (totalOcrInput / 1_000_000) * model.inputCostPer1M
                    + (totalOcrOutput / 1_000_000) * model.outputCostPer1M
            batchOcrCost = ocrCost * model.batchDiscount
        }

        // Vision judgement reads each page's text. Pre-OCRed inputs classify only for tagging or Collection ID.
        var classificationCost: Double = 0
        if visionTextOnly || (preOCRedInput && (classifyPreOCRedInput ?? (enableTagging || enableCollectionSegmentation))) {
            let classInput = Double(fileCount) * estimatedClassificationInputTokens
            let classOutput = Double(fileCount) * estimatedClassificationOutputTokens
            classificationCost = (classInput / 1_000_000) * model.inputCostPer1M
                               + (classOutput / 1_000_000) * model.outputCostPer1M
        }

        // Tagging cost
        var taggingCost: Double = 0
        var datingCost: Double = 0
        var itemFieldCost: Double = 0
        var namesCost: Double = 0
        if enableTagging {
            let estimatedSegments = estimatedDocuments(fileCount)
            let tagInput = estimatedSegments * estimatedTaggingInputTokens
            let tagOutput = estimatedSegments * estimatedTaggingOutputTokens
            taggingCost = (tagInput / 1_000_000) * model.inputCostPer1M
                        + (tagOutput / 1_000_000) * model.outputCostPer1M
            if sidecars, namesCallShare > 0 {
                let namesCalls = estimatedSegments * namesCallShare
                let reasoning = model.measuredModel.id == "gemini-3.8-flash" ? 820.0 : 0
                let rates = model.provider == .mistral
                    ? LLMTextClient.mistralTextRates : (input: model.inputCostPer1M, output: model.outputCostPer1M)
                namesCost = namesCalls * (estimatedNamesInputTokens * rates.input
                    + (estimatedNamesOutputTokens + reasoning) * rates.output) / 1_000_000
            }
            // Each tagged document's date, then its item fields (`performTaggingPhase`).
            if measuredRoute {
                let imageShare = dateImageEveryDocument ? 1.0 : dateImageShare
                datingCost = estimatedSegments * (gatewayDateTraceCallCost + imageShare * gatewayDateImageCallCost)
                if sidecars { itemFieldCost = Double(fileCount) * gatewayItemFieldPageCost }
            } else {
                datingCost = estimatedSegments * (estimatedDateTraceInputTokens / 1_000_000 * model.inputCostPer1M
                                                  + estimatedDateTraceOutputTokens / 1_000_000 * model.outputCostPer1M)
            }
        }

        // Collection segmentation cost
        var collectionCost: Double = 0
        if enableCollectionSegmentation {
            let estimatedBoxes = max(1.0, Double(fileCount) / 7.0)
            let boxInput = estimatedBoxes * estimatedCollectionInputTokens
            let boxOutput = estimatedBoxes * estimatedCollectionOutputTokens
            let clusterInput = estimatedClusteringInputTokens
            let clusterOutput = estimatedClusteringOutputTokens
            collectionCost = ((boxInput + clusterInput) / 1_000_000) * model.inputCostPer1M
                           + ((boxOutput + clusterOutput) / 1_000_000) * model.outputCostPer1M
        }

        // Rotation cost (LLM modes only; free for Gateway/Mistral/local Vision/off; none for pre-OCRed).
        var rotationCost: Double = 0
        let rotCalls = rotationMode.orderings
        if gatewayRotation, !preOCRedInput {
            rotationCost = Double(fileCount) * gatewayRotationCalls(rotationMode) * gatewayRotationCallCost
        } else if rotCalls > 0, !preOCRedInput, !visionTextOnly, !useGateway,
           let (rIn, rOut) = rotationModelCost(for: model.provider) {
            let inputPerCall = 4 * estimatedRotationCandidateTokens(for: model.provider) + estimatedRotationPromptTokens
            let calls = Double(fileCount) * Double(rotCalls)
            rotationCost = (calls * inputPerCall / 1_000_000) * rIn
                         + (calls * estimatedRotationOutputTokens / 1_000_000) * rOut
        }

        return CostEstimate(
            ocrCost: ocrCost,
            classificationCost: classificationCost,
            taggingCost: taggingCost,
            collectionCost: collectionCost,
            rotationCost: rotationCost,
            batchOcrCost: batchOcrCost,
            fileCount: fileCount,
            model: model,
            datingCost: datingCost,
            itemFieldCost: itemFieldCost,
            namesCost: namesCost
        )
    }

    /// Multi-page PDF re-OCR calls the model directly once per page, with no tagging, segmentation or
    /// Batch API. Price those pages on their own at standard rates; `runTotal` adds them to the image
    /// subset's standard or batch total. The pre-run pane and run history both use this pair.
    static func estimateDirectPDFPages(
        pageCount: Int,
        model: LLMModel,
        imageScale: Double = 1.0,
        rotationMode: RotationMode = .off,
        useGateway: Bool = false,
        imageTokenProvider: LLMProvider? = nil,
        gatewayRotation: Bool = false
    ) -> CostEstimate {
        estimate(fileCount: pageCount, model: model, enableTagging: false,
                 sendPreviousImage: false, contextCharCount: 0, imageScale: imageScale,
                 rotationMode: rotationMode, useGateway: useGateway,
                 imageTokenProvider: imageTokenProvider, gatewayRotation: gatewayRotation)
    }

    /// Whole-run total: the image subset at its batch or standard rate plus direct PDF pages at standard.
    static func runTotal(images: CostEstimate?, directPDFPages: CostEstimate?, batch: Bool) -> Double {
        (images.map { batch ? $0.totalBatch : $0.totalStandard } ?? 0) + (directPDFPages?.totalStandard ?? 0)
    }
}
