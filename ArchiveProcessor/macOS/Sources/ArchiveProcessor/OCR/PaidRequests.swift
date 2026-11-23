import CoreFoundation
import Foundation

/// One durable transport attempt. A timeout or a crash leaves the admission estimate in place.
struct PaidRequestRecord: Codable, Equatable, Sendable {
    enum Basis: String, Codable, Sendable {
        case unresolved, estimate, reported, declined
    }

    let id: UUID
    let provider: LLMProvider
    let count: Int
    let estimate: Double?
    var basis: Basis = .unresolved
    var jobID: String?
    var batchUsage: [String: Double]?
    var batchUnbilled: Int?
}

struct PaidRequests: Sendable {
    @TaskLocal static var context: PaidRequests?
    @TaskLocal static var imageScale = 1.0

    let id: UUID
    let runID: UUID
    let outputDirectory: URL?
    let limit: Double?
    let store: SettingsLayerStore
    let onDeclined: (@MainActor @Sendable (Double?) -> Void)?
    @MainActor private final class Admission {
        var stopped = false
    }
    private let admission: Admission

    @MainActor
    init(id: UUID = UUID(), runID: UUID = UUID(), outputDirectory: URL?, limit: Double? = nil,
         store: SettingsLayerStore = .shared, onDeclined: (@MainActor @Sendable (Double?) -> Void)? = nil) {
        self.id = id
        self.runID = runID
        self.outputDirectory = outputDirectory
        self.limit = limit
        self.store = store
        self.onDeclined = onDeclined
        self.admission = Admission()
    }

    @MainActor
    func run<T>(denyDataCollection: Bool, operation: @MainActor () async throws -> T) async rethrows -> T {
        try await Self.$context.withValue(self) {
            try await OpenRouterDataPolicy.$denyDataCollection.withValue(denyDataCollection) {
                try await operation()
            }
        }
    }

    struct Price: Sendable {
        let input: Double
        let output: Double
        let imageProvider: LLMProvider
        let outputTokens: Double
        let perPage: Double?
        let multiplier: Double

        init(input: Double, output: Double, imageProvider: LLMProvider, outputTokens: Double = 850,
             perPage: Double? = nil, multiplier: Double = 1) {
            self.input = input
            self.output = output
            self.imageProvider = imageProvider
            self.outputTokens = outputTokens
            self.perPage = perPage
            self.multiplier = multiplier
        }

        init(model: LLMModel, imageProvider: LLMProvider? = nil, outputTokens: Double = 850) {
            self.init(input: model.inputCostPer1M, output: model.outputCostPer1M,
                      imageProvider: imageProvider ?? model.measuredModel.provider,
                      outputTokens: outputTokens + CostEstimator.estimatedThinkingTokens(for: model))
        }

        private func amount(inputTokens: Double, outputTokens: Double, extra: Double = 0) -> Double? {
            PaidRequests.nonnegative((inputTokens * input + outputTokens * output + extra) * multiplier / 1_000_000)
        }

        func estimate(forJSON body: [String: Any]) -> Double? {
            if let perPage { return PaidRequests.nonnegative(perPage * multiplier) }
            var textBytes = 0
            var images = 0
            func count(_ content: Any) {
                switch content {
                case let text as String:
                    textBytes += text.utf8.count
                case let elements as [Any]:
                    for element in elements { count(element) }
                case let part as [String: Any]:
                    if part["image_url"] != nil || part["inlineData"] != nil || part["inline_data"] != nil
                        || part["type"] as? String == "image" {
                        images += 1
                    } else {
                        for field in ["text", "content", "parts"] {
                            if let value = part[field] { count(value) }
                        }
                    }
                default: break
                }
            }
            for key in ["messages", "contents", "system", "systemInstruction"] {
                if let value = body[key] { count(value) }
            }
            let inputTokens = Double(textBytes) / 4 + 30
                + Double(images) * CostEstimator.estimatedImageTokens(for: imageProvider)
                    * max(0.01, min(1, PaidRequests.imageScale))
            let outputLimit = PaidRequests.number(body["max_tokens"] ?? body["max_completion_tokens"]) ?? outputTokens
            return amount(inputTokens: inputTokens, outputTokens: min(outputTokens, outputLimit))
        }

        /// Usage-derived amounts still use list prices. Save a returned dollar figure separately.
        func amount(forJSON json: [String: Any]) -> Double? {
            if let perPage {
                let info = json["usage_info"] as? [String: Any]
                let pageCount = PaidRequests.number(info?["pages_processed"])
                    ?? (json["pages"] as? [[String: Any]]).map { Double($0.count) }
                return pageCount.flatMap { PaidRequests.nonnegative($0 * perPage * multiplier) }
            }
            if let gemini = json["usageMetadata"] as? [String: Any],
               let prompt = PaidRequests.number(gemini["promptTokenCount"]) {
                let reply = (PaidRequests.number(gemini["candidatesTokenCount"]) ?? 0)
                    + (PaidRequests.number(gemini["thoughtsTokenCount"]) ?? 0)
                let total = PaidRequests.number(gemini["totalTokenCount"])
                guard reply > 0 || total != nil || gemini["candidatesTokenCount"] != nil else { return nil }
                return amount(inputTokens: prompt, outputTokens: max(reply, (total ?? 0) - prompt))
            }
            guard let usage = json["usage"] as? [String: Any] else { return nil }
            if let prompt = PaidRequests.number(usage["prompt_tokens"]),
               let reply = PaidRequests.number(usage["completion_tokens"]) {
                return amount(inputTokens: prompt,
                              outputTokens: max(reply, (PaidRequests.number(usage["total_tokens"]) ?? 0) - prompt))
            }
            if let prompt = PaidRequests.number(usage["input_tokens"]),
               let reply = PaidRequests.number(usage["output_tokens"]) {
                let cached = PaidRequests.number(usage["cache_read_input_tokens"]) ?? 0
                let creation = PaidRequests.number(usage["cache_creation_input_tokens"]) ?? 0
                let longLived = min(creation, PaidRequests.number(
                    (usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"]) ?? 0)
                return amount(inputTokens: prompt, outputTokens: reply,
                              extra: input * (cached * 0.1 + (creation - longLived) * 1.25 + longLived * 2))
            }
            return nil
        }
    }

    struct Billing: Sendable {
        let provider: LLMProvider
        let price: Price?
        var fallback: Double? = nil
    }

    struct Attempt: Sendable {
        let context: PaidRequests
        let id: UUID

        @MainActor
        func settle(_ basis: PaidRequestRecord.Basis, amount: Double? = nil, jobID: String? = nil) {
            context.store.settlePaidRequest(id: id, basis: basis, amount: amount, jobID: jobID)
        }
    }

    struct BatchLinkFailure: LocalizedError {
        let attemptID: UUID
        let jobID: String

        var errorDescription: String? {
            "The provider accepted a batch, but its paid request entry could not be updated. The job ID was kept for recovery."
        }
    }

    @MainActor
    func admit(provider: LLMProvider, estimate: Double?, count: Int = 1) throws -> Attempt {
        try Task.checkCancellation()
        guard !admission.stopped else { throw ProcessFilesMonthlySpend.ReadingDeclined() }
        let record = PaidRequestRecord(id: UUID(), provider: provider, count: count, estimate: Self.nonnegative(estimate))
        do {
            try store.beginPaidRequest(record, runID: runID, outputDirectory: outputDirectory, limit: limit)
        } catch is ProcessFilesMonthlySpend.ReadingDeclined {
            admission.stopped = true
            onDeclined?(estimate)
            throw ProcessFilesMonthlySpend.ReadingDeclined()
        }
        return Attempt(context: self, id: record.id)
    }

    @MainActor
    static func admitClaudeCLI(billing: ClaudeCLIBilling, modelID: String?, prompt: String,
                               imageCount: Int = 0) throws -> Attempt? {
        guard billing != .subscription, let context else { return nil }
        let model = LLMModel.anthropicModels.first { $0.id == modelID }
        let price = model.map { Price(model: $0) }
        let content: [[String: Any]] = [["text": prompt]]
            + Array(repeating: ["type": "image"], count: imageCount)
        let estimate = price?.estimate(forJSON: ["messages": [["content": content]]])
        return try context.admit(provider: .anthropic, estimate: estimate)
    }

    @MainActor
    static func settleClaudeCLI(_ attempt: Attempt?, usageUSD: Double?, byAPIKey: Bool, byPlan: Bool, spawnFailed: Bool) {
        if spawnFailed || byPlan {
            attempt?.settle(.declined, amount: 0)
        } else if byAPIKey {
            let amount = nonnegative(usageUSD)
            if let attempt {
                attempt.settle(amount == nil ? .unresolved : .estimate, amount: amount)
            } else if let context {
                // A plan sign-in can switch after the auth probe. Record that observed API call too.
                let request = PaidRequestRecord(id: UUID(), provider: .anthropic, count: 1, estimate: amount,
                                                basis: amount == nil ? .unresolved : .estimate)
                do {
                    try context.store.beginPaidRequest(request, runID: context.runID,
                                                       outputDirectory: context.outputDirectory, limit: nil)
                } catch {
                    NSLog("ArchiveProcessor: Claude CLI paid request could not be recorded: %@", error.localizedDescription)
                }
            }
        }
    }

    /// Native model endpoints used by both OCR and the independent stages. Other chat endpoints opt in
    /// using the caller's gateway configuration. File uploads, batch polls, plan and loopback traffic are excluded.
    @MainActor
    static func billing(for request: URLRequest) -> Billing? {
        guard request.httpMethod == "POST", let url = request.url else { return nil }
        let provider: LLMProvider
        let modelID: String?
        switch (url.host, url.path) {
        case ("api.anthropic.com", "/v1/messages"):
            provider = .anthropic
            modelID = jsonObject(request.httpBody)["model"] as? String
        case ("generativelanguage.googleapis.com", let path) where path.hasSuffix(":generateContent"):
            provider = .gemini
            modelID = url.lastPathComponent.components(separatedBy: ":").first
        case ("api.mistral.ai", "/v1/ocr"):
            return Billing(provider: .mistral, price: Price(input: 0, output: 0, imageProvider: .mistral, perPage: 0.004))
        case ("api.mistral.ai", "/v1/chat/completions"):
            let rates = LLMTextClient.mistralTextRates
            return Billing(provider: .mistral, price: Price(input: rates.input, output: rates.output, imageProvider: .mistral))
        case ("api.openai.com", "/v1/chat/completions"):
            provider = .openai
            modelID = jsonObject(request.httpBody)["model"] as? String
        case ("openrouter.ai", "/api/v1/chat/completions"):
            provider = .openrouter
            modelID = jsonObject(request.httpBody)["model"] as? String
        default: return nil
        }
        let model = modelID.flatMap { id in provider.models.first { $0.id == id } }
        let priced = model.flatMap { OpenRouterRoute.isUnpriced($0) ? nil : $0 }
        let price = priced.map { model in
            Price(model: model, outputTokens: CostEstimator.estimatedOutputTokens)
        } ?? fixedPrice(modelID)
        return Billing(provider: provider, price: price)
    }

    static func fixedPrice(_ model: String?) -> Price? {
        switch model {
        case "gemini-3.7-flash":
            // The measured gateway routes use the successor's standard list rate as the estimate.
            return LLMModel.geminiModels.first { $0.id == "gemini-3.8-flash" }.map { Price(model: $0) }
        case ContainerLabelCapture.gatewayModel:
            return Price(input: ContainerLabelCapture.gatewayInputPer1M, output: ContainerLabelCapture.gatewayOutputPer1M,
                         imageProvider: .openai)
        case "gemini-2.5-flash-lite":
            let rates = CostEstimator.rotationModelCost(for: .gemini)
            return rates.map { Price(input: $0.0, output: $0.1, imageProvider: .gemini) }
        default: return nil
        }
    }

    @MainActor
    static func gateway(_ config: GatewayConfig, modelID: String, fallback: Double? = nil) -> Billing? {
        guard !config.isLocalModel else { return nil }
        let provider = OCRProcessor.gatewayUpstreamProviderFromDefaults()
        let price: Price?
        if modelID == config.modelID,
           let input = nonnegative(config.inputCostPer1M), let output = nonnegative(config.outputCostPer1M) {
            price = Price(input: input, output: output, imageProvider: provider)
        } else {
            price = fixedPrice(modelID)
        }
        return Billing(provider: provider, price: price, fallback: fallback)
    }

    static func responseAmount(data: Data, response: URLResponse, billing: Billing) -> (PaidRequestRecord.Basis, Double?) {
        let http = response as? HTTPURLResponse
        let json = jsonObject(data)
        let usage = json["usage"] as? [String: Any]
        if let amount = number(usage?["cost"]) { return (.reported, amount) }
        if let header = http?.value(forHTTPHeaderField: "x-litellm-response-cost"),
           let amount = nonnegative(Double(header)), amount > 0 { return (.reported, amount) }
        if let amount = billing.price?.amount(forJSON: json) { return (.estimate, amount) }
        guard let code = http?.statusCode else { return (.unresolved, nil) }
        if explicitlyRejected(code) { return (.declined, 0) }
        let hasResult = ["choices", "candidates", "content", "pages", "text"].contains { json[$0] != nil }
        if (200..<300).contains(code), hasResult, json["error"] == nil,
           billing.price != nil || billing.fallback != nil {
            return (.estimate, nil)
        }
        return (.unresolved, nil)
    }

    static func explicitlyRejected(_ code: Int) -> Bool {
        [400, 401, 402, 403, 404, 405, 413, 415, 422, 429].contains(code)
    }

    static func jsonObject(_ data: Data?) -> [String: Any] {
        guard let data else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    static func nonnegative(_ number: Double?) -> Double? {
        guard let number, number.isFinite, number >= 0 else { return nil }
        return number
    }

    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return nonnegative(number.doubleValue)
    }

    static func recordBatch(_ request: URLRequest, estimate: Double, count: Int, provider: LLMProvider,
                            parseID: @escaping @Sendable (Data) -> String?) async throws -> (Data, URLResponse) {
        try await NetworkSession.data(for: request, policy: .nonIdempotent,
                                      paidBatch: .init(provider: provider, estimate: estimate, count: count, parseID: parseID))
    }

    @MainActor
    static func reconcileBatch(provider: LLMProvider, jobID: String, usage: [String: Double],
                               confirmedNoCharge: Int) throws {
        try (context?.store ?? .shared).reconcilePaidBatch(provider: provider, jobID: jobID, usage: usage,
                                                       confirmedNoCharge: confirmedNoCharge)
    }
}
