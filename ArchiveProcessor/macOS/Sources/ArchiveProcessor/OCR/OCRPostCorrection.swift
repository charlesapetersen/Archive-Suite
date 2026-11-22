import Foundation

/// W47.wh-post-correction. The measured image prompt, with one paid attempt and the original on failure.
struct OCRPostCorrection: Sendable {
    static let model = OpenRouterRoute.forModel("qwen/qwen3.6-27b")?.model
    static let tokenLimit = 8192
    static let instruction = "Below is an OCR reading of the page in the image. Correct the reading against the image: fix characters and "
        + "words that were misread, restore words that were dropped, and remove text that is not on the page. Do not "
        + "translate, modernise, normalise spelling, rephrase or add anything that is not visible on the page. Keep the "
        + "reading's line breaks and order wherever they are right. If the reading is already correct, return it unchanged. "
        + "Reply with the corrected transcription only.\n\nOCR reading:\n"

    let apiKey: String
    private let spendID = UUID()

    @MainActor static func policyReason(at directory: URL?, store: SettingsLayerStore) -> String? {
        guard let directory else { return policyReason(store.resolver(for: nil).resolveAll()) }
        switch CollectionSettingsFile.read(in: directory) {
        case .document(let document): return policyReason(store.resolver(for: document).resolveAll())
        case .missing: return policyReason(store.resolver(for: nil).resolveAll())
        case .unreadable, .refused: return "The output collection's sharing settings could not be read."
        }
    }

    static func policyReason(_ values: [String: ResolvedSetting]?) -> String? {
        if let staysOnMac = values?[SettingsKey.staysOnMac.rawValue],
           staysOnMac.layer != nil, staysOnMac.value.bool == true {
            return "These pages are set to stay on this Mac."
        }
        // Chutes may train on prompts (SettingsTraining); skip before sending anything to OpenRouter.
        if values?[SettingsKey.noTraining.rawValue]?.value.bool == true {
            return "These pages are set to go only to providers that do not train on them."
        }
        let exclusions = values?[SettingsKey.excludedModelFamilies.rawValue]?.value.strings ?? []
        if let model, exclusions.contains(where: { family in
            !family.isEmpty && "\(model.id) \(model.provider.rawValue) \(model.displayName)"
                .localizedCaseInsensitiveContains(family)
        }) {
            return "This collection excludes the correction model."
        }
        return nil
    }

    /// The benchmark used 4,232 median input tokens, including the first reading. Use the app's standard 850 output
    /// tokens for the advance estimate. A reply with usage is priced using its own input and output tokens.
    static func estimatedCost(model: LLMModel) -> Double {
        cost(model: model, input: 4232, output: Int(CostEstimator.estimatedOutputTokens))
    }

    private static func cost(model: LLMModel, input: Int, output: Int) -> Double {
        (Double(input) * model.inputCostPer1M + Double(output) * model.outputCostPer1M) / 1_000_000
    }

    func apply(to result: OCRResult, imageURL: URL, scale: Double, spend: NewspaperReadingSpend?) async -> OCRResult {
        guard let model = Self.model, let reading = result.text,
              !reading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              result.errorCode == nil, result.errorMessage == nil, result.imported == nil,
              result.newspaperLayout == nil, result.classification != .boxLabel, result.classification != .folderLabel,
              !Task.isCancelled, !apiKey.isEmpty else { return result }
        do {
            guard let reply = try await PageReaders.correctPage(imageURL, prompt: Self.instruction + reading,
                                                              scale: scale, apiKey: apiKey, model: model) else {
                return result
            }
            // Cut-offs can still be billed. Record the extra attempt even when the original text is kept.
            spend?.add(reply.cost(model: model), id: spendID, source: imageURL, baseAllowance: false)
            guard !Task.isCancelled, let text = reply.text else { return result }
            return result.withImageCorrection(text)
        } catch {
            return result
        }
    }

    struct Reply {
        let text: String?
        private let input: Int?
        private let output: Int?

        init(data: Data) {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let usage = json?["usage"] as? [String: Any]
            input = usage?["prompt_tokens"] as? Int
            output = usage?["completion_tokens"] as? Int
            let choice = (json?["choices"] as? [[String: Any]])?.first
            let message = choice?["message"] as? [String: Any]
            let content = (message?["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let refusal = message?["refusal"] as? String
            if json?["error"] == nil, refusal?.isEmpty != false, choice?["finish_reason"] as? String == "stop",
               let content, !content.isEmpty, !content.contains("<think>") {
                text = content
            } else {
                text = nil
            }
        }

        func cost(model: LLMModel) -> Double {
            guard let input, let output, input >= 0, output >= 0 else {
                return OCRPostCorrection.estimatedCost(model: model)
            }
            return OCRPostCorrection.cost(model: model, input: input, output: output)
        }
    }
}
