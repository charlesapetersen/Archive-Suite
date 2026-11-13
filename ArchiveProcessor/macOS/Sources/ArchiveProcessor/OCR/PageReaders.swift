import Foundation
import VisionOCRKit

/// The one way the app reads a page (W42.int-s2): every client is a VisionOCRKit `PageReader` whose detail is the
/// app's `OCRResult`, and `PageReaders.reader` is the only place that chooses one. Process Files, Live Capture, the
/// retries, the refusal second readers, the cascade's escalation and Vision word count, and the key wizard's
/// sample read all go through it; `scripts/check-page-reader-seam.sh` fails when a client's `ocr` is called
/// anywhere else, and the switch below is exhaustive, so a new provider cannot be added without a reader.
///
/// Batch submission, the text-only completions (tagging, classification, segmentation windows) and the rotation
/// vote are not page readings and keep their own request builders.
enum PageReaders {
    /// The reader for one route. Backend precedence as before: the Local Agent CLI, then the gateway, then the direct
    /// provider (Settings makes the first two exclusive; the order is defensive). Throws for an OpenRouter model with
    /// no pinned upstream, as `pinnedOpenRouter` always has.
    static func reader(
        provider: LLMProvider, model: LLMModel, apiKey: String, thinkingLevel: ThinkingLevel?,
        gateway: GatewayConfig? = nil, localAgent: LocalAgentConfig? = nil,
        visionSettings: VisionOCRSettings = .default
    ) throws -> any PageReader<OCRResult> {
        if let localAgent { return Measured(LocalAgentClient(config: localAgent), dollars: nil) }
        if let gateway {
            return Measured(OpenAICompatibleClient.gateway(gateway), route: "Gateway|\(gateway.modelID)", dollars: nil)
        }
        let price = pagePrice(model)
        switch provider {
        case .anthropic:
            return Measured(AnthropicClient(apiKey: apiKey, model: model, thinkingLevel: thinkingLevel), dollars: price)
        case .gemini:
            return Measured(GeminiClient(apiKey: apiKey, model: model, thinkingLevel: thinkingLevel), dollars: price)
        case .mistral:
            return Measured(MistralClient(apiKey: apiKey, model: model), dollars: price)
        case .openai:
            return Measured(OpenAICompatibleClient.openAI(model: model, apiKey: apiKey, thinkingLevel: thinkingLevel),
                            route: OCRCascade.routeID(for: model), dollars: price)
        case .openrouter:
            return Measured(try OpenAICompatibleClient.pinnedOpenRouter(model: model, apiKey: apiKey),
                            route: OCRCascade.routeID(for: model), dollars: price)
        case .appleVision:
            return Measured(VisionClient(settings: visionSettings), dollars: nil)
        }
    }

    /// One page at the model's standard rate, as the refusal second readers are priced (image, prompt and output).
    static func pagePrice(_ model: LLMModel) -> Double {
        CostEstimator.secondReaderPageCost(model: model, imageScale: 1)
    }

    /// Times a client's reading and adds the route's page price. The text is the client's, unchanged.
    struct Measured<Client: PageReader>: PageReader where Client.Detail == OCRResult {
        let client: Client
        let route: String
        let dollars: Double?

        init(_ client: Client, route: String? = nil, dollars: Double?) {
            self.client = client
            self.route = route ?? client.route
            self.dollars = dollars
        }

        func read(_ page: PageReaderInput) async throws -> PageReading<OCRResult> {
            let start = ContinuousClock.now
            var reading = try await client.read(page)
            let elapsed = ContinuousClock.now - start
            reading.seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            // A failed page is not billed as a read; a provider's own 4xx/5xx costs nothing.
            reading.dollars = reading.detail.text == nil ? nil : dollars
            return reading
        }
    }

    /// The reading every client returns: its OCRResult's text, no positions (none of these clients returns words
    /// with boxes yet; Stage 5 aligns them onto Vision's lines).
    static func reading(_ result: OCRResult) -> PageReading<OCRResult> {
        PageReading(text: result.text, seconds: 0, detail: result)
    }
}

extension AnthropicClient: PageReader {
    var route: String { OCRCascade.routeID(for: model) }
    func read(_ page: PageReaderInput) async throws -> PageReading<OCRResult> {
        PageReaders.reading(try await ocr(imageURL: page.imageURL, previousText: page.previousText,
                                          previousImageURL: page.previousImageURL, customPrompt: page.customPrompt,
                                          imageScale: page.imageScale))
    }
}

extension GeminiClient: PageReader {
    var route: String { OCRCascade.routeID(for: model) }
    func read(_ page: PageReaderInput) async throws -> PageReading<OCRResult> {
        PageReaders.reading(try await ocr(imageURL: page.imageURL, previousText: page.previousText,
                                          previousImageURL: page.previousImageURL, customPrompt: page.customPrompt,
                                          imageScale: page.imageScale))
    }
}

extension MistralClient: PageReader {
    var route: String { OCRCascade.routeID(for: model) }
    /// Mistral's OCR endpoint takes no prompt and no previous image; classification is its text heuristic.
    func read(_ page: PageReaderInput) async throws -> PageReading<OCRResult> {
        PageReaders.reading(try await ocr(imageURL: page.imageURL, previousText: page.previousText,
                                          imageScale: page.imageScale))
    }
}

extension OpenAICompatibleClient: PageReader {
    /// The factory names the route (OpenAI, OpenRouter or the gateway); this is its fallback.
    var route: String { "OpenAI-compatible|\(modelID)" }
    func read(_ page: PageReaderInput) async throws -> PageReading<OCRResult> {
        PageReaders.reading(try await ocr(imageURL: page.imageURL, previousText: page.previousText,
                                          previousImageURL: page.previousImageURL, customPrompt: page.customPrompt,
                                          imageScale: page.imageScale))
    }
}

extension LocalAgentClient: PageReader {
    var route: String { "LocalAgent|\(config.tool.binaryName)" }
    func read(_ page: PageReaderInput) async throws -> PageReading<OCRResult> {
        PageReaders.reading(try await ocr(imageURL: page.imageURL, previousText: page.previousText,
                                          previousImageURL: page.previousImageURL, customPrompt: page.customPrompt,
                                          imageScale: page.imageScale))
    }
}

extension VisionClient: PageReader {
    var route: String { "\(LLMProvider.appleVision.rawValue)|macos-vision" }
    func read(_ page: PageReaderInput) async throws -> PageReading<OCRResult> {
        PageReaders.reading(try await ocr(imageURL: page.imageURL, previousText: page.previousText,
                                          previousImageURL: page.previousImageURL, customPrompt: page.customPrompt,
                                          imageScale: page.imageScale))
    }
}
