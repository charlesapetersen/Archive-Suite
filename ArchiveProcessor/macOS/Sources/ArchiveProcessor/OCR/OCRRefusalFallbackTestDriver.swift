import AppKit
import Foundation
import PDFKit

/// Key-free, no-network contract for W41.app-ocr-default. Drives the REAL `OCRProcessor.performOCRCall` with
/// the default Gemini model through the injected HTTP transport: Gemini answers each page with a canned
/// refusal (or a success, or a key error), and the second routes come from `OCRRefusalFallback.routesOverride`
/// instead of the Keychain. Checks that a refused page reaches the second reader and is marked, that a page no
/// route can read fails loudly, and that ordinary failures and successes never spend a second call.
///
/// Run via `scripts/test-ocr-refusal.sh`.
@MainActor
enum OCRRefusalFallbackTestDriver {
    nonisolated static let envKey = "OCRREFUSAL_TEST"
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment[envKey] == "1" else { return }
        didRun = true
        Task { await run() }
    }

    /// What the fake Gemini endpoint answers, and what each second route answers.
    private actor Script {
        var gemini: (Int, String) = (200, "")
        var anthropic: (Int, String) = (200, "")
        var openai: (Int, String) = (200, "")
        var openrouter: (Int, String) = (200, "")
        var hosts: [String] = []
        var openRouterBody: [String: Any]?
        func set(gemini: (Int, String), anthropic: (Int, String) = (200, ""), openai: (Int, String) = (200, ""),
                 openrouter: (Int, String) = (200, "")) {
            self.gemini = gemini; self.anthropic = anthropic; self.openai = openai; self.openrouter = openrouter
            hosts = []; openRouterBody = nil
        }
        func answer(_ request: URLRequest) -> (Int, String) {
            let host = request.url?.host ?? ""
            hosts.append(host)
            if host.contains("generativelanguage") { return gemini }
            if host.contains("anthropic") { return anthropic }
            if host.contains("openrouter") {
                openRouterBody = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                return openrouter
            }
            if host.contains("openai") { return openai }
            return (404, "{}")
        }
        func calls() -> [String] { hosts }
        /// The last OpenRouter request's `model`, `provider.order` and `reasoning.enabled`.
        func openRouterPin() -> (String?, [String]?, Bool?) {
            (openRouterBody?["model"] as? String, (openRouterBody?["provider"] as? [String: Any])?["order"] as? [String],
             (openRouterBody?["reasoning"] as? [String: Any])?["enabled"] as? Bool)
        }
    }

    static func run() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("APOCRRefusal-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        var results: [String] = []
        func check(_ name: String, _ condition: Bool) {
            results.append("\(condition ? "PASS" : "FAIL"): \(name)")
        }

        // The default and the two new entries.
        let gemini = LLMProvider.gemini.models
        check("the default Gemini OCR model is gemini-3.8-flash", gemini.first?.id == "gemini-3.8-flash")
        check("3.8 Flash carries its introductory price, $0.75 / $3.75 per 1M",
              gemini.first?.inputCostPer1M == 0.75 && gemini.first?.outputCostPer1M == 3.75)
        let lite = gemini.first { $0.id == "gemini-3.5-flash-lite" }
        check("gemini-3.5-flash-lite is offered at $0.30 / $2.50 per 1M",
              lite?.inputCostPer1M == 0.30 && lite?.outputCostPer1M == 2.50)
        check("the old default gemini-3.1-flash-lite is still offered", gemini.contains { $0.id == "gemini-3.1-flash-lite" })

        guard let image = makeJPEG(at: root.appendingPathComponent("page.jpg")) else {
            finish(results + ["FAIL: fixture JPEG could not be created"])
            return
        }

        let script = Script()
        check("the HTTP seam is dormant before the contract installs it", !NetworkSession.testTransportIsActive)
        NetworkSession.testTransport = { request in
            let (status, body) = await script.answer(request)
            let response = HTTPURLResponse(url: request.url ?? URL(string: "https://x.invalid")!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(body.utf8), response)
        }
        defer { NetworkSession.testTransport = nil; OCRRefusalFallback.routesOverride = nil }

        let claude = OCRRefusalFallback.Route(provider: .anthropic, model: LLMModel.anthropicModels[0],
                                              apiKey: "test-anthropic", localAgent: nil)
        let gpt = OCRRefusalFallback.Route(provider: .openai, model: LLMModel.openaiModels[0],
                                           apiKey: "test-openai", localAgent: nil)
        let qwenModel = OCRRefusalFallback.keyedModels[1]
        let qwen = OCRRefusalFallback.Route(provider: .openrouter, model: qwenModel, apiKey: "test-openrouter",
                                            localAgent: nil)
        func useRoutes(_ routes: [OCRRefusalFallback.Route]) {
            OCRRefusalFallback.routesOverride = { routes }
        }
        func ocr() async -> OCRResult {
            await OCRProcessor.performOCRCall(
                imageURL: image, provider: .gemini, model: gemini[0], thinkingLevel: .low, apiKey: "test-gemini",
                previousText: nil, previousImageURL: nil, rotationMode: .off, standardImageMB: 4, cascade: .off)
        }

        let recitation = #"{"candidates":[{"finishReason":"RECITATION"}]}"#
        let other = #"{"candidates":[{"finishReason":"OTHER","content":{"parts":[]}}]}"#
        let geminiText = #"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"[document_start]\nGEMINI-TEXT"}]}}]}"#
        let claudeText = #"{"content":[{"type":"text","text":"[document_start]\nCLAUDE-TEXT"}]}"#
        let gptText = #"{"choices":[{"message":{"content":"[document_start]\nGPT-TEXT"}}]}"#

        // 1. The refusal path reaches the second route, and the result says so.
        useRoutes([claude])
        await script.set(gemini: (200, recitation), anthropic: (200, claudeText))
        var r = await ocr()
        var calls = await script.calls()
        check("a RECITATION refusal is read by the second route (Claude)", r.text?.contains("CLAUDE-TEXT") == true)
        check("the refused page went to Gemini first, then to Anthropic",
              calls.first?.contains("generativelanguage") == true && calls.contains { $0.contains("anthropic") })
        check("the result names its second reader and Gemini's reason",
              r.secondReader?.provider == "Anthropic" && r.secondReader?.model == LLMModel.anthropicModels[0].displayName
              && r.secondReader?.firstCode == "Recitation")
        // W41.app-ocr-default-fu1 — the page carries what the keyed reader spent, for the run summary.
        let claudePage = CostEstimator.secondReaderPageCost(model: LLMModel.anthropicModels[0], imageScale: 1)
        check("a keyed second read carries its estimated cost", claudePage > 0
              && r.secondReader?.estimatedCost.map { abs($0 - claudePage) < 1e-12 } == true)
        check("a second-read page is a success: no error left on it", r.errorMessage == nil && r.errorCode == nil)

        // The mark survives what the run does to a result: persistence and reclassification.
        if let data = try? JSONEncoder().encode(r), let back = try? JSONDecoder().decode(OCRResult.self, from: data) {
            check("secondReader round-trips through the run record's Codable", back.secondReader == r.secondReader)
        } else {
            check("secondReader round-trips through the run record's Codable", false)
        }
        check("secondReader survives a reclassification (`with`)",
              r.with(classification: .documentContinuation, rotationDegrees: 90).secondReader == r.secondReader)
        // The PDF's page-2 header names the model that wrote the text, in the header's usual provenance line.
        let pdfURL = root.appendingPathComponent("page.pdf")
        _ = try? PDFGenerator().generate(imageURL: image, result: r, model: gemini[0], outputURL: pdfURL)
        let header = PDFDocument(url: pdfURL)?.page(at: 1)?.string ?? ""
        check("the PDF header credits the second reader, not Gemini",
              header.contains("Anthropic \u{00B7} \(LLMModel.anthropicModels[0].displayName)")
              && !header.contains(gemini[0].displayName))
        let legacy = #"{"text":"x","rotationDegrees":0}"#
        check("a result recorded before the field existed still decodes, unmarked",
              (try? JSONDecoder().decode(OCRResult.self, from: Data(legacy.utf8)))?.secondReader == nil)

        // 2. An empty OTHER finish, and AI Studio's bare server error, are refusals too.
        await script.set(gemini: (200, other), anthropic: (200, claudeText))
        r = await ocr()
        check("an OTHER finish with no text is read by the second route", r.text?.contains("CLAUDE-TEXT") == true)
        await script.set(gemini: (500, #"{"error":{"message":"Internal error"}}"#), anthropic: (200, claudeText))
        r = await ocr()
        check("an HTTP 500 with no text is read by the second route", r.text?.contains("CLAUDE-TEXT") == true)

        // 3. The first second route fails: the next one reads it.
        useRoutes([claude, gpt])
        await script.set(gemini: (200, recitation), anthropic: (401, #"{"error":{"message":"bad key"}}"#),
                         openai: (200, gptText))
        r = await ocr()
        check("when Claude fails, the next route (OpenAI) reads the page",
              r.text?.contains("GPT-TEXT") == true && r.secondReader?.provider == "OpenAI"
              && r.secondReader?.model == LLMModel.openaiModels[0].displayName)

        // 3b. W41.app-openrouter-fu1 — Qwen3.6 27B on OpenRouter is the route after Claude, before OpenAI and Mistral.
        let keyed = OCRRefusalFallback.keyedModels
        check("the keyed second readers run Claude, Qwen3.6 27B, GPT-5.4 mini, Mistral OCR",
              keyed.map(\.provider) == [.anthropic, .openrouter, .openai, .mistral]
              && keyed[1].id == "qwen/qwen3.6-27b" && keyed[2].id == "gpt-5.4-mini")
        let qwenText = #"{"choices":[{"finish_reason":"stop","message":{"content":"[document_start]\nQWEN-TEXT"}}]}"#
        useRoutes([claude, qwen, gpt])
        await script.set(gemini: (200, recitation), anthropic: (401, #"{"error":{"message":"bad key"}}"#),
                         openai: (200, gptText), openrouter: (200, qwenText))
        r = await ocr()
        calls = await script.calls()
        let pin = await script.openRouterPin()
        check("when Claude fails, Qwen3.6 27B on OpenRouter reads the page and OpenAI is never called",
              r.text?.contains("QWEN-TEXT") == true && r.secondReader?.provider == "OpenRouter"
              && r.secondReader?.model == qwenModel.displayName && !calls.contains { $0.contains("openai") })
        check("the OpenRouter second read is pinned as the panel ran it: chutes fp8, reasoning off",
              pin.0 == "qwen/qwen3.6-27b" && pin.1 == ["chutes/fp8"] && pin.2 == false)
        let qwenPage = CostEstimator.secondReaderPageCost(model: qwenModel, imageScale: 1)
        check("the OpenRouter second read carries its estimated cost, inside the pre-run range",
              qwenPage > 0 && r.secondReader?.estimatedCost.map { abs($0 - qwenPage) < 1e-12 } == true
              && OCRRefusalFallback.pageCostRange(imageScale: 1).contains(qwenPage))
        _ = try? PDFGenerator().generate(imageURL: image, result: r, model: gemini[0], outputURL: pdfURL)
        let qwenHeader = PDFDocument(url: pdfURL)?.page(at: 1)?.string ?? ""
        check("the PDF header credits OpenRouter's Qwen3.6 27B, not Gemini",
              qwenHeader.contains("OpenRouter \u{00B7} \(qwenModel.displayName)") && !qwenHeader.contains(gemini[0].displayName))
        // OpenRouter's provider failure (a 200 with an in-body error) is not text: the next route reads the page.
        await script.set(gemini: (200, recitation), anthropic: (401, #"{"error":{"message":"bad key"}}"#),
                         openai: (200, gptText), openrouter: (200, #"{"error":{"code":502,"message":"upstream down"}}"#))
        r = await ocr()
        check("when OpenRouter's provider fails, OpenAI reads the page",
              r.text?.contains("GPT-TEXT") == true && r.secondReader?.provider == "OpenAI")
        let notCatalogued = OCRRefusalFallback.Route(
            provider: .openrouter, model: LLMModel(id: "x/unpinned", displayName: "Unpinned", provider: .openrouter,
                                                   supportsThinking: false, returnsMd: false, inputCostPer1M: 0,
                                                   outputCostPer1M: 0, batchDiscount: 1),
            apiKey: "test-openrouter", localAgent: nil)
        useRoutes([notCatalogued, gpt])
        await script.set(gemini: (200, recitation), openai: (200, gptText), openrouter: (200, qwenText))
        r = await ocr()
        calls = await script.calls()
        check("an OpenRouter model with no pinned route is never called unpinned; the next route reads",
              r.text?.contains("GPT-TEXT") == true && !calls.contains { $0.contains("openrouter") })
        useRoutes([claude, gpt])

        // 4. Never a silent failure: every route fails, or there is none.
        await script.set(gemini: (200, recitation), anthropic: (401, #"{"error":{"message":"bad key"}}"#),
                         openai: (401, #"{"error":{"message":"bad key"}}"#))
        r = await ocr()
        check("every second reader failing fails the page, naming Gemini's reason",
              r.text == nil && r.errorCode == OCRRefusalFallback.exhaustedCode
              && r.errorMessage?.contains("Recitation") == true && r.errorMessage?.contains("Second readers failed") == true)
        let quotedTimeout = OCRResult(text: nil, classification: nil,
                                      errorMessage: "Gemini returned no text. Second readers failed too — claude: timed out",
                                      errorCode: OCRRefusalFallback.exhaustedCode)
        check("an exhausted refusal is never auto-retried, even when a reader's reason says \"timed out\"",
              !OCRProcessor.isTimeoutError(quotedTimeout))
        useRoutes([])
        await script.set(gemini: (200, recitation))
        r = await ocr()
        check("with no second route the page fails and says how to add one",
              r.text == nil && r.errorCode == OCRRefusalFallback.exhaustedCode
              && r.errorMessage?.contains("No second reader") == true)

        // 5. What is not a refusal never spends a second call.
        useRoutes([claude])
        await script.set(gemini: (200, geminiText), anthropic: (200, claudeText))
        r = await ocr()
        calls = await script.calls()
        check("a Gemini success is kept and no second route is called",
              r.text?.contains("GEMINI-TEXT") == true && r.secondReader == nil && !calls.contains { $0.contains("anthropic") })
        await script.set(gemini: (403, #"{"error":{"message":"API key not valid"}}"#), anthropic: (200, claudeText))
        r = await ocr()
        calls = await script.calls()
        check("a key error (403) is the user's to fix: no second route is called",
              r.text == nil && r.errorCode == "403" && !calls.contains { $0.contains("anthropic") })
        check("isRefusal: a transport failure (no code) and a timeout are not refusals",
              !OCRRefusalFallback.isRefusal(OCRResult(text: nil, classification: nil, errorMessage: "offline", errorCode: nil))
              && !OCRRefusalFallback.isRefusal(OCRResult(text: nil, classification: nil, errorMessage: "x", errorCode: "504")))

        // 6. A diagnostic (Tools: Compare Models, Test Resolution) measures Gemini itself.
        await script.set(gemini: (200, recitation), anthropic: (200, claudeText))
        r = await OCRProcessor.performResolutionTestCall(
            imageURL: image, provider: .gemini, model: gemini[0], thinkingLevel: nil, apiKey: "test-gemini",
            imageScale: 1, rotationMode: .off, standardImageMB: 4)
        calls = await script.calls()
        check("the Tools resolution test reports Gemini's refusal and calls no second route",
              r.text == nil && r.errorCode == "Recitation" && !calls.contains { $0.contains("anthropic") })

        // 7. The batch parser keeps the refusal's finish reason instead of an uncoded blank.
        let batchOther = GeminiBatchClient.parseSingleResponse(
            ["candidates": [["finishReason": "OTHER", "content": ["parts": [[String: Any]]()]]]])
        let batchNoParts = GeminiBatchClient.parseSingleResponse(["candidates": [["finishReason": "OTHER"]]])
        check("a batch page refused with OTHER fails with that code",
              batchOther.text == nil && batchOther.errorCode == "OTHER" && batchNoParts.errorCode == "OTHER")

        // 8. W41.app-ocr-default-fu1 — a refused batch page, as collected, is read by the second reader once.
        useRoutes([claude])
        await script.set(gemini: (200, geminiText), anthropic: (200, claudeText))
        func collect(_ page: OCRResult, enabled: Bool = true) async -> OCRResult {
            // The batch collection's call (`processBatchResults`), with the cascade off.
            await OCRCascade.resolve(page, cascade: .off, provider: .gemini, model: gemini[0], refusalFallback: enabled,
                                     imageURL: image, previousText: nil, previousImageURL: nil, customPrompt: nil,
                                     imageScale: 1, visionSettings: .default)
        }
        r = await collect(batchOther)
        calls = await script.calls()
        check("a batch page refused with OTHER is read by the second reader, marked, with one call",
              r.text?.contains("CLAUDE-TEXT") == true && r.secondReader?.firstCode == "OTHER"
              && calls.filter { $0.contains("anthropic") }.count == 1 && !calls.contains { $0.contains("generativelanguage") })
        let batchRecitation = GeminiBatchClient.parseSingleResponse(["candidates": [["finishReason": "RECITATION"]]])
        r = await collect(batchRecitation)
        check("a batch RECITATION page is read by the second reader", r.secondReader?.firstCode == "Recitation")
        await script.set(gemini: (200, geminiText), anthropic: (200, claudeText))
        let batchOK = OCRResult(text: "BATCH-TEXT", classification: nil, errorMessage: nil, errorCode: nil)
        r = await collect(batchOK)
        let offRoute = await collect(batchOther, enabled: false)
        calls = await script.calls()
        check("a batch success, and a refusal off the direct-Gemini route, spend no second call",
              r.text == "BATCH-TEXT" && r.secondReader == nil && offRoute.errorCode == "OTHER"
              && offRoute.secondReader == nil && calls.isEmpty)
        useRoutes([])
        let batchNoReader = await collect(batchOther)
        check("a refused batch page with no second reader fails as exhausted (never auto-retried)",
              batchNoReader.text == nil && batchNoReader.errorCode == OCRRefusalFallback.exhaustedCode)
        // Stop mid-collection: no route is called, and the exhausted verdict is what `processBatchResults` refuses
        // to persist while cancelled (the journal brings the page back on resume).
        useRoutes([claude])
        await script.set(gemini: (200, geminiText), anthropic: (200, claudeText))
        let stopped = Task { await collect(batchOther) }
        stopped.cancel()
        r = await stopped.value
        calls = await script.calls()
        check("a Stop during a batch second read spends nothing and leaves no text",
              r.text == nil && r.errorCode == OCRRefusalFallback.exhaustedCode && calls.isEmpty)

        // 9. Spend: thinking tokens in the estimate, second readers in the run's history and summary.
        let flash = gemini[0]
        let est = CostEstimator.estimate(fileCount: 1000, model: flash, enableTagging: false,
                                         sendPreviousImage: false, contextCharCount: 0)
        let expectedOCR = 1000 * (CostEstimator.estimatedPromptTokens + CostEstimator.estimatedImageTokens(for: .gemini))
            / 1_000_000 * flash.inputCostPer1M
            + 1000 * (CostEstimator.estimatedOutputTokens + 117) / 1_000_000 * flash.outputCostPer1M
        check("3.8 Flash's ~117 thinking tokens a page are in the estimate, at the output rate",
              abs(est.ocrCost - expectedOCR) < 1e-9
              && lite.map { CostEstimator.estimatedThinkingTokens(for: $0) } == 0)
        let range = OCRRefusalFallback.pageCostRange(imageScale: 1)
        check("the pre-run second-reader price range is positive and ordered",
              range.lowerBound > 0 && range.lowerBound <= range.upperBound)
        let snapshot = RunHistorySnapshot(
            startedAt: Date(), provider: .gemini, gatewayConfig: nil, localAgent: nil, imageTokenProvider: nil,
            model: flash, visionTextProvider: nil, visionTextModel: nil, batchMode: true, enableTagging: false,
            enableCollectionSegmentation: false, preOCRedInput: false, reOCRMultiPagePDF: false, mixedReOCR: false,
            sendPreviousImage: false, contextCharCount: 0, imageScale: 1, rotationMode: .off, fileCount: 3)
        let readers = [SecondReader(provider: "Anthropic", model: "m", firstCode: "OTHER", estimatedCost: 0.01),
                       SecondReader(provider: "claude", model: "m", firstCode: "OTHER", estimatedCost: 0)]
        let recorded = snapshot.makeRun(succeeded: 3, secondReaders: readers)
        check("the run's history counts the second-read pages and adds their cost",
              recorded.secondReaderPages == 2 && abs(recorded.cost - (snapshot.estimatedCost + 0.01)) < 1e-12)
        check("a run with no second reader records none", snapshot.makeRun(succeeded: 3).secondReaderPages == nil)
        let oldRun = #"{"id":"\#(UUID().uuidString)","date":0,"providerLabel":"Gemini","modelName":"m","fileCount":1,"succeeded":1,"failed":0,"batchMode":false,"modeLabel":"Standard","cost":0.1}"#
        check("a history run recorded before the field still decodes",
              (try? JSONDecoder().decode(ProcessingRun.self, from: Data(oldRun.utf8)))?.secondReaderPages == nil
              && (try? JSONDecoder().decode(ProcessingRun.self, from: Data(oldRun.utf8))) != nil)
        let processor = OCRProcessor()
        processor.jobs = [OCRJob(sourceURL: image), OCRJob(sourceURL: image)]
        processor.jobs[0].result = OCRResult(text: "t", classification: nil, errorMessage: nil, errorCode: nil,
                                             secondReader: readers[0])
        check("the run summary says how many pages a second reader read",
              processor.runDoneMessage(succeeded: 2, failed: 0) == "Done. 2 succeeded, 0 failed. 1 page read by a second reader.")
        processor.jobs[0].result = nil
        check("the run summary is unchanged with no second reader",
              processor.runDoneMessage(succeeded: 2, failed: 0) == "Done. 2 succeeded, 0 failed.")

        finish(results)
    }

    private static func makeJPEG(at url: URL) -> URL? {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
                                      bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let data = bitmap?.representation(using: .jpeg, properties: [:]) else { return nil }
        try? data.write(to: url)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func finish(_ results: [String]) {
        let passed = !results.contains { $0.hasPrefix("FAIL") }
        let report = (passed ? "ALL PASS\n" : "SOME FAILED\n") + results.joined(separator: "\n") + "\n"
        let output = ProcessInfo.processInfo.environment["OCRREFUSAL_TEST_OUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("archiveprocessor-ocr-refusal.txt")
        try? Data(report.utf8).write(to: output, options: .atomic)
        NSLog("%@", report)
        exit(passed ? 0 : 1)
    }
}
