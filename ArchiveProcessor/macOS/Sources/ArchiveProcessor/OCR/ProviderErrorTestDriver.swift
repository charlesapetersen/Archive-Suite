#if DEBUG // W40.a5: a test driver/contract, compiled out of Release
import Foundation

/// Headless, $0 self-test of how a provider's HTTP 402 reads (W40.fix-processor-gemini-402-message), gated by
/// `PROVIDER_ERROR_TEST=1` (does nothing in normal use). Pure parsing of canned reply bodies: no request, no key, no
/// Keychain read, no window, never the corpus. Run by `scripts/test-provider-errors.sh`.
///
/// What has to be true:
///   1. Gemini's 402 RESOURCE_EXHAUSTED ("prepayment credits are depleted") says the account needs credit or
///      billing, names Gemini and its billing page, keeps Google's words, and is not a rate limit; its 429
///      RESOURCE_EXHAUSTED still is.
///   2. The same for the OpenAI-compatible (OpenAI, OpenRouter, a gateway), Anthropic and Mistral clients.
///   3. No 402 message carries a word `isRetryableError` reads as transient, and Anthropic's code is "402".
///   4. In segmentation a 402 fails every window (fatal), where a 429 RESOURCE_EXHAUSTED is the usage limit.
@MainActor
enum ProviderErrorTestDriver {
    nonisolated static let envKey = "PROVIDER_ERROR_TEST"
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment[envKey] == "1" else { return }
        didRun = true
        run()
    }

    private static var lines: [String] = []
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { lines.append("PASS \(name)") } else {
            failures += 1
            lines.append("FAIL \(name) \(detail())")
        }
    }

    /// The words `OCRProcessor.isRetryableError` reads in a message as a transient failure.
    private static let transientWords = ["rate limit", "high use", "high demand", "unavailable", "overloaded"]

    /// A 402 message: billing, the provider and its page named, the provider's words kept, nothing transient.
    private static func checkBilling(_ name: String, _ message: String, provider: String?, page: String?,
                                     detail: String?) {
        let lower = message.lowercased()
        check("\(name) says credit or billing", lower.contains("out of credit or needs billing"), message)
        if let provider { check("\(name) names \(provider)", message.contains("Your \(provider) account"), message) }
        if let page { check("\(name) names the billing page", message.contains(page), message) }
        if let detail { check("\(name) keeps the provider's words", message.contains(detail), message) }
        check("\(name) reads as nothing transient", !transientWords.contains { lower.contains($0) }, message)
    }

    private static func body(_ s: String) -> Data { Data(s.utf8) }

    static func run() {
        defer { finish() }
        let depleted = "Your prepayment credits are depleted. Please go to AI Studio to manage your project and billing."
        let gemini402 = body(#"{"error":{"code":402,"message":"\#(depleted)","status":"RESOURCE_EXHAUSTED"}}"#)
        let gemini429 = body(#"{"error":{"code":429,"message":"You exceeded your current quota.","status":"RESOURCE_EXHAUSTED"}}"#)

        // 1. Gemini.
        checkBilling("1 gemini 402", GeminiClient.parseErrorResponse(data: gemini402, statusCode: 402),
                     provider: "Gemini", page: "ai.google.dev/gemini-api/docs/billing", detail: depleted)
        checkBilling("1 gemini 402 empty body", GeminiClient.parseErrorResponse(data: Data(), statusCode: 402),
                     provider: "Gemini", page: "ai.google.dev", detail: nil)
        check("1 gemini 429 RESOURCE_EXHAUSTED is the rate limit",
              GeminiClient.parseErrorResponse(data: gemini429, statusCode: 429) == "Rate limit exceeded. Try again later.")

        // 2. OpenAI-compatible: by endpoint, and the OpenRouter 200-with-error code.
        let credits = body(#"{"error":{"code":402,"message":"Insufficient credits"}}"#)
        checkBilling("2 openai 402", OpenAICompatibleClient.parseErrorResponse(data: credits, statusCode: 402, provider: .openai),
                     provider: "OpenAI", page: "platform.openai.com/settings/organization/billing", detail: "Insufficient credits")
        let openAI = OpenAICompatibleClient.openAI(model: LLMModel.openaiModels[0], apiKey: "k")
        check("2 the OpenAI endpoint names OpenAI", openAI.billingProvider == .openai)
        if let route = OpenRouterRoute.catalog.first,
           let router = OpenAICompatibleClient.openRouter(model: route.model, apiKey: "k") {
            check("2 the OpenRouter endpoint names OpenRouter", router.billingProvider == .openrouter)
        } else {
            check("2 an OpenRouter client exists", false)
        }
        checkBilling("2 openrouter 402", OpenAICompatibleClient.parseErrorResponse(data: credits, statusCode: 402, provider: .openrouter),
                     provider: "OpenRouter", page: "openrouter.ai/settings/credits", detail: "Insufficient credits")
        let gateway = OpenAICompatibleClient(baseURL: "https://gateway.example/v1", apiKey: "k", modelID: "m")
        check("2 a gateway names no provider", gateway.billingProvider == nil)
        checkBilling("2 gateway 402", OpenAICompatibleClient.parseErrorResponse(data: Data(), statusCode: 402, provider: nil),
                     provider: nil, page: nil, detail: nil)
        check("2 openai-compatible 429 is the rate limit",
              OpenAICompatibleClient.parseErrorResponse(data: credits, statusCode: 429, provider: .openai)
                == "Rate limit exceeded. Try again later.")

        // 3. Anthropic and Mistral.
        let anthropicBody = body(#"{"type":"error","error":{"type":"billing_error","message":"Your credit balance is too low."}}"#)
        let anthropic = AnthropicClient.parseErrorResponse(data: anthropicBody, statusCode: 402)
        checkBilling("3 anthropic 402", anthropic.message, provider: "Anthropic",
                     page: "platform.claude.com/settings/billing", detail: "Your credit balance is too low.")
        check("3 anthropic 402 code is 402", anthropic.code == "402", anthropic.code)
        let anthropic429 = AnthropicClient.parseErrorResponse(
            data: body(#"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#), statusCode: 429)
        check("3 anthropic 429 is the rate limit", anthropic429.message == "Rate limit exceeded. Try again later.")
        checkBilling("3 mistral 402", MistralClient.parseErrorResponse(data: body(#"{"message":"Payment required"}"#), statusCode: 402),
                     provider: "Mistral", page: "admin.mistral.ai", detail: "Payment required")

        // 4. Segmentation windows.
        do {
            _ = try APIWindowTransport.replyText(.gemini, data: gemini402, status: 402)
            check("4 gemini 402 window throws", false)
        } catch let WindowTransportError.fatal(message) {
            check("4 gemini 402 fails every window", message.contains("out of credit or needs billing"), message)
        } catch {
            check("4 gemini 402 is fatal, not \(error)", false)
        }
        do {
            _ = try APIWindowTransport.replyText(.gemini, data: gemini429, status: 429)
            check("4 gemini 429 window throws", false)
        } catch WindowTransportError.usageLimit {
            check("4 gemini 429 RESOURCE_EXHAUSTED is the usage limit", true)
        } catch {
            check("4 gemini 429 is the usage limit, not \(error)", false)
        }
    }

    private static func finish() {
        lines.append(failures == 0 ? "ALL PASS" : "FAILURES \(failures)")
        let text = lines.joined(separator: "\n") + "\n"
        if let out = ProcessInfo.processInfo.environment["PROVIDER_ERROR_TEST_OUT"] {
            try? text.write(toFile: out, atomically: true, encoding: .utf8)
        } else {
            print(text)
        }
    }
}
#endif
