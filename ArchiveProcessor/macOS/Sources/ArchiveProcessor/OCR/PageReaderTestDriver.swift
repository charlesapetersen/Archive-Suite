#if DEBUG // W40.a5: a test driver/contract, compiled out of Release
import AppKit
import CoreText
import Foundation
import VisionOCRKit

/// Headless, $0 self-test of the one way to read a page (W42.int-s2), gated by `PAGEREADER_TEST=1` (does nothing in
/// normal use). Run by `scripts/test-page-reader.sh`, which compares the journey lines with the committed
/// `scripts/page-reader-journeys.golden`, recorded on the code before the protocol existed.
///
/// What has to be true:
///   1. Every provider's journey (`performOCRCall`, the path Process Files, Live Capture and the retries take) gives
///      the text it gave before, on the two smoke pages: each cloud provider through the no-wire seam with its own
///      reply shape, the gateway, the Local Agent against the committed fake CLI, and Apple Vision for real.
///   2. Every provider has a page reader (`PageReaders`), and the reader reports the route it is.
///   3. OpenRouter's prices come from its endpoints listing: the pinned upstream's row, never another provider's,
///      and a route the listing lacks keeps the bench's price and says so.
///
/// Every request goes to `NetworkSession.testTransport`; the driver stops before any call if the seam is not active.
@MainActor
enum PageReaderTestDriver {
    nonisolated static let envKey = "PAGEREADER_TEST"
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment[envKey] == "1" else { return }
        didRun = true
        Task { @MainActor in await run() }
    }

    private static var lines: [String] = []
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { lines.append("PASS \(name)") } else {
            failures += 1
            lines.append("FAIL \(name) \(detail())")
        }
    }

    /// The two pages `scripts/live-openrouter.sh` draws, so the $0 journeys and the paid check read the same text.
    static let smokePages: [(name: String, text: String)] = [
        ("memo", "MEMORANDUM\nTo: The Secretary\nFrom: Budget Office\nSubject: Fiscal year 1958 estimates\nThe attached tables show the revised figures."),
        ("letter", "Dear Mr. Hughes,\nThank you for your letter of March 3.\nWe will reply in full next week.\nSincerely yours,\nA. Smith"),
    ]

    static func run() async {
        defer { finish() }
        check("0 seam dormant before install", !NetworkSession.testTransportIsActive)
        let current = Current()
        NetworkSession.testTransport = { request in
            let body = current.reply(for: request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
        defer { NetworkSession.testTransport = nil }
        guard NetworkSession.testTransportIsActive else {
            check("0 the injected transport is active", false, "stopping before any request")
            return
        }
        guard let dir = makeSmokePages() else { check("0 smoke pages", false); return }
        defer { try? FileManager.default.removeItem(at: dir) }

        await journeys(dir: dir, current: current)
        await seamChecks(dir: dir, current: current)
        await priceChecks(current: current)
    }

    /// The reply each provider's wire gives, for the page being read: the page's own text in that provider's shape.
    private final class Current: @unchecked Sendable {
        var text = ""
        /// The endpoints listing each model's GET gets, by model id.
        var listings: [String: String] = [:]
        func reply(for request: URLRequest) -> String {
            let host = request.url?.host ?? ""
            let path = request.url?.path ?? ""
            if path.hasSuffix("/endpoints") {
                let id = path.replacingOccurrences(of: "/api/v1/models/", with: "")
                    .replacingOccurrences(of: "/endpoints", with: "")
                return listings[id] ?? #"{"data":{"id":"\#(id)","endpoints":[]}}"#
            }
            let tagged = "[document_start]\n" + text
            func json(_ object: Any) -> String {
                String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
            }
            if host.contains("anthropic") {
                return json(["content": [["type": "text", "text": tagged]], "stop_reason": "end_turn"])
            }
            if host.contains("googleapis") {
                return json(["candidates": [["content": ["parts": [["text": tagged]]], "finishReason": "STOP"]]])
            }
            if host.contains("mistral") { return json(["pages": [["markdown": text]]]) }
            return json(["choices": [["finish_reason": "stop", "message": ["content": tagged]]]])
        }
    }

    private static func journeys(dir: URL, current: Current) async {
        let gateway = GatewayConfig(baseURL: "https://remote-gateway.invalid/v1", modelID: "gw", displayName: "GW",
                                    inputCostPer1M: 1, outputCostPer1M: 1)
        let fakeCLI = ProcessInfo.processInfo.environment["LOCALAGENT_FAKE_CLI"] ?? ""
        struct Journey { let name: String; let provider: LLMProvider; var gateway: GatewayConfig? = nil
                         var agent: LocalAgentConfig? = nil }
        var all = LLMProvider.allCases.map { Journey(name: $0.rawValue, provider: $0) }
        all.append(Journey(name: "Gateway", provider: .gemini, gateway: gateway))
        if FileManager.default.isExecutableFile(atPath: fakeCLI) {
            setenv("LOCALAGENT_FAKE_MODE", "ok", 1)
            all.append(Journey(name: "LocalAgent", provider: .anthropic,
                               agent: LocalAgentConfig(tool: .claude, binaryPath: fakeCLI)))
        } else {
            check("1 the fake Local Agent CLI is given", false, "LOCALAGENT_FAKE_CLI=\(fakeCLI)")
        }
        for journey in all {
            guard let model = journey.provider.models.first else { check("1 \(journey.name) has a model", false); continue }
            for page in smokePages {
                current.text = page.text
                let result = await OCRProcessor.performOCRCall(
                    imageURL: dir.appendingPathComponent(page.name + ".png"), provider: journey.provider, model: model,
                    thinkingLevel: nil, apiKey: "test-key", previousText: nil, previousImageURL: nil,
                    gatewayConfig: journey.gateway, localAgent: journey.agent, rotationMode: .off,
                    standardImageMB: 2, cascade: .off, refusalFallback: false)
                let text = (result.text ?? "<nil: \(result.errorMessage ?? "?")>").replacingOccurrences(of: "\n", with: "⏎")
                lines.append("JOURNEY \(journey.name) \(page.name) \(result.classification?.rawValue ?? "-") \(text)")
            }
        }
    }

    /// 2. Every provider has a reader that names its route, and the reader measures: seconds always, dollars at the
    ///    route's page price for a paid reading, none for Vision or a failed page.
    private static func seamChecks(dir: URL, current: Current) async {
        let memo = PageReaderInput(imageURL: dir.appendingPathComponent("memo.png"))
        current.text = smokePages[0].text
        for provider in LLMProvider.allCases {
            guard let model = provider.models.first,
                  let reader = try? PageReaders.reader(provider: provider, model: model, apiKey: "test-key",
                                                       thinkingLevel: nil) else {
                check("2 \(provider.rawValue) has a page reader", false); continue
            }
            check("2 \(provider.rawValue) reader names its route", reader.route.hasPrefix(provider.rawValue + "|"),
                  reader.route)
            guard let reading = try? await reader.read(memo) else { check("2 \(provider.rawValue) reads", false); continue }
            check("2 \(provider.rawValue) reading is timed", reading.seconds > 0, "\(reading.seconds)")
            check("2 \(provider.rawValue) reading text is the detail's", reading.text == reading.detail.text)
            if provider == .appleVision {
                check("2 Vision costs nothing", reading.dollars == nil, "\(String(describing: reading.dollars))")
            } else {
                let want = PageReaders.pagePrice(model)
                check("2 \(provider.rawValue) reading costs its page price", reading.dollars == want && want > 0,
                      "got \(String(describing: reading.dollars)) want \(want)")
            }
        }
        let gateway = GatewayConfig(baseURL: "https://remote-gateway.invalid/v1", modelID: "gw", displayName: "GW",
                                    inputCostPer1M: 1, outputCostPer1M: 1)
        let viaGateway = try? PageReaders.reader(provider: .gemini, model: LLMProvider.gemini.models[0], apiKey: "k",
                                                 thinkingLevel: nil, gateway: gateway)
        check("2 the gateway wins over the provider", viaGateway?.route == "Gateway|gw", viaGateway?.route ?? "nil")
        let agent = LocalAgentConfig(tool: .claude, binaryPath: "/nonexistent")
        let viaAgent = try? PageReaders.reader(provider: .gemini, model: LLMProvider.gemini.models[0], apiKey: "k",
                                               thinkingLevel: nil, gateway: gateway, localAgent: agent)
        check("2 the Local Agent wins over the gateway", viaAgent?.route.hasPrefix("LocalAgent|") == true,
              viaAgent?.route ?? "nil")
        let stray = LLMModel(id: "someone/unpinned", displayName: "x", provider: .openrouter, supportsThinking: false,
                             returnsMd: false, inputCostPer1M: 1, outputCostPer1M: 1, batchDiscount: 1)
        check("2 an unpinned OpenRouter model gets no reader",
              (try? PageReaders.reader(provider: .openrouter, model: stray, apiKey: "k", thinkingLevel: nil)) == nil)
        current.text = "failed"
    }

    /// 3. OpenRouter's listed price for the pinned upstream, through the no-wire seam into a scratch defaults suite.
    private static func priceChecks(current: Current) async {
        guard let route = OpenRouterRoute.forModel("qwen/qwen3-vl-235b-a22b-instruct"),
              let glm = OpenRouterRoute.forModel("z-ai/glm-5.3-flash") else { check("3 catalog routes", false); return }
        // The shape of the bench's cached listing (ocr-panel-cloud/catalog/qwen3-vl-235b.json), cheaper rival first.
        let listing = #"{"data":{"id":"qwen/qwen3-vl-235b-a22b-instruct","endpoints":["#
            + #"{"tag":"novita/fp8","quantization":"fp8","pricing":{"prompt":"0.0000001","completion":"0.0000005"}},"#
            + #"{"tag":"deepinfra/bf16","quantization":"bf16","pricing":{"prompt":"0.00000015","completion":"0.0000006"}},"#
            + #"{"tag":"deepinfra/fp8","quantization":"fp8","pricing":{"prompt":"0.00000022","completion":"0.0000009","input_cache_read":"0.00000011"}}]}}"#
        let price = OpenRouterPrices.parse(Data(listing.utf8), route: route)
        check("3 the pinned upstream's row, not a cheaper provider's", price?.tag == "deepinfra/fp8",
              price?.tag ?? "nil")
        check("3 per token read as per million", price?.inputPer1M == 0.22 && price?.outputPer1M == 0.9,
              "\(String(describing: price))")
        let glmListing = #"{"data":{"id":"z-ai/glm-5.3-flash","endpoints":[{"tag":"z-ai/bf16","quantization":"bf16","#
            + #""pricing":{"prompt":"0.0000003","completion":"0.000001"}},{"tag":"z-ai/fp8","quantization":"fp8","#
            + #""pricing":{"prompt":"0.00000016","completion":"0.00000052"}}]}}"#
        check("3 a provider tag finds its row at the pinned precision",
              OpenRouterPrices.parse(Data(glmListing.utf8), route: glm)?.tag == "z-ai/fp8")
        let lacking = #"{"data":{"id":"qwen/qwen3-vl-235b-a22b-instruct","endpoints":[{"tag":"novita/fp8","#
            + #""quantization":"fp8","pricing":{"prompt":"0.0000001","completion":"0.0000005"}}]}}"#
        check("3 a listing without the pinned upstream gives no price",
              OpenRouterPrices.parse(Data(lacking.utf8), route: route) == nil)
        check("3 another model's listing gives no price", OpenRouterPrices.parse(Data(glmListing.utf8), route: route) == nil)
        let free = listing.replacingOccurrences(of: "0.00000022", with: "0")
        check("3 a zero price is not a price", OpenRouterPrices.parse(Data(free.utf8), route: route) == nil)

        check("3 no listing read: the bench's price", OpenRouterPrices.priced(route, [:]) == route.model)
        if let price {
            let priced = OpenRouterPrices.priced(route, [route.model.id: price])
            check("3 the listing's price reaches the model", priced.inputCostPer1M == 0.22
                  && priced.outputCostPer1M == 0.9 && priced.id == route.model.id)
            let bench = CostEstimator.secondReaderPageCost(model: route.model, imageScale: 1)
            let listed = CostEstimator.secondReaderPageCost(model: priced, imageScale: 1)
            check("3 the estimate follows the listing", listed > bench, "listed \(listed) bench \(bench)")
        }

        // End to end through the seam, in a scratch suite so the app's own stored prices are untouched.
        let suite = "PageReaderTestDriver-\(UUID().uuidString)"
        guard let scratch = UserDefaults(suiteName: suite) else { check("3 scratch defaults", false); return }
        defer { scratch.removePersistentDomain(forName: suite) }
        current.listings = [route.model.id: listing, glm.model.id: glmListing]
        let report = await OpenRouterPrices.refreshIfStale(force: true, defaults: scratch)
        let stored = OpenRouterPrices.stored(scratch)
        check("3 refresh stores the listed rows", stored[route.model.id]?.tag == "deepinfra/fp8"
              && stored[glm.model.id]?.tag == "z-ai/fp8", report.joined(separator: "; "))
        check("3 a route the listing lacks keeps the bench's price",
              stored.count == 2 && report.filter { $0.contains("the bench's price stays") }.count
                == OpenRouterRoute.catalog.count - 2, report.joined(separator: "; "))
        let again = await OpenRouterPrices.refreshIfStale(defaults: scratch)
        check("3 a fresh price is not read again", !again.contains { $0.hasPrefix(route.model.id) },
              again.joined(separator: "; "))
        current.listings = [:]
    }

    private static func makeSmokePages() -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("page-reader-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for page in smokePages {
            let w = 700, h = 900
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            let font = CTFontCreateWithName("Helvetica" as CFString, 30, nil)
            var y = h - 70
            for line in page.text.components(separatedBy: "\n") {
                let s = CFAttributedStringCreate(nil, line as CFString, [kCTFontAttributeName: font] as CFDictionary)!
                ctx.textPosition = CGPoint(x: 50, y: CGFloat(y)); CTLineDraw(CTLineCreateWithAttributedString(s), ctx); y -= 46
            }
            guard let image = ctx.makeImage(),
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
                  (try? png.write(to: dir.appendingPathComponent(page.name + ".png"))) != nil else { return nil }
        }
        return dir
    }

    private static func finish() {
        lines.append(failures == 0 ? "ALL PASS" : "FAILURES \(failures)")
        let text = lines.joined(separator: "\n") + "\n"
        if let out = ProcessInfo.processInfo.environment["PAGEREADER_TEST_OUT"] {
            try? text.write(toFile: out, atomically: true, encoding: .utf8)
        } else {
            print(text)
        }
    }
}


#endif
