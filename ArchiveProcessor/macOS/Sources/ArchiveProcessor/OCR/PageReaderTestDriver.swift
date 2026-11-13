#if DEBUG // W40.a5: a test driver/contract, compiled out of Release
import AppKit
import CoreText
import Foundation

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
        PageReaderSeamChecks.run(check: check)
        OpenRouterPriceChecks.run(check: check)
    }

    /// The reply each provider's wire gives, for the page being read: the page's own text in that provider's shape.
    private final class Current: @unchecked Sendable {
        var text = ""
        func reply(for request: URLRequest) -> String {
            let host = request.url?.host ?? ""
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

/// Filled in with the protocol (W42.int-s2); empty on the baseline run.
enum PageReaderSeamChecks { @MainActor static func run(check: (String, Bool, @autoclosure () -> String) -> Void) {} }
enum OpenRouterPriceChecks { @MainActor static func run(check: (String, Bool, @autoclosure () -> String) -> Void) {} }

#endif
