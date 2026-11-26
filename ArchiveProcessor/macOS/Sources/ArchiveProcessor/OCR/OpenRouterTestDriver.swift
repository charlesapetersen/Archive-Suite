#if DEBUG // W40.a5: a test driver/contract, compiled out of Release
import AppKit
import Foundation

/// Headless, $0 self-test of the OpenRouter provider (W41.app-openrouter), gated by `OPENROUTER_TEST=1` (does nothing
/// in normal use). Every request goes to the no-wire seam (`NetworkSession.testTransport`), which this flag enables;
/// the driver FAILS at once if the seam is not active after the stub is installed, so nothing can reach OpenRouter.
/// No key (a fake one is passed), no Keychain read, no window, never the corpus. Run by `scripts/test-openrouter.sh`.
///
/// What has to be true:
///   1. The catalog is the bench's: each model's id, pinned provider, precision and price, and no custom models.
///   2. The request on the wire pins the provider (`order`, `allow_fallbacks: false`, `quantizations`, a
///      `max_price` at the pinned price), sends temperature 0 and the bench's reasoning setting, for OCR and text.
///   3. A model the catalog lacks gets no client: an unpinned call is never made.
///   4. OpenRouter's 200-with-an-error reply becomes a failed page with its message, never an empty success.
///   5. The cost estimate is priced at the pinned provider's rates, and is not below what the panel paid.
///   7. The rotation vote (llmMajority) breaks a tie by the first ordering's answer, not by hash order.
///   8. The measured Gemini and GPT models through OpenRouter (W41.app-openrouter-any): mapped, pinned to their
///      makers, at the user's thinking level, their refusals read as Gemini's own, run on an OpenRouter key alone.
///   9. Any other OpenRouter model (W41.app-openrouter-unmeasured): the listing's image models and a typed id, unpinned
///      with `data_collection: "deny"`, priced from the listing for the estimate and `max_price`, or unpriced.
@MainActor
enum OpenRouterTestDriver {
    nonisolated static let envKey = "OPENROUTER_TEST"
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

    private static func eq<T: Equatable>(_ name: String, _ got: T, _ want: T) {
        check(name, got == want, "got \(got) want \(want)")
    }

    /// Every request the stub saw, and the reply it gives.
    private final class Wire: @unchecked Sendable {
        var requests: [URLRequest] = []
        var reply = #"{"choices":[{"message":{"content":"[document_start]\nHello archive"}}]}"#
        var status = 200
    }

    static func run() async {
        defer { finish() }
        catalogChecks()

        // The seam must be dormant until the stub is installed, then active; otherwise stop before any call.
        check("0 seam dormant before install", !NetworkSession.testTransportIsActive)
        let wire = Wire()
        NetworkSession.testTransport = { request in
            wire.requests.append(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: wire.status, httpVersion: nil, headerFields: nil)!
            return (Data(wire.reply.utf8), response)
        }
        defer { NetworkSession.testTransport = nil }
        guard NetworkSession.testTransportIsActive else {
            check("0 the injected transport is active", false, "stopping before any request")
            return
        }

        guard let image = makeImage() else { check("0 test image", false); return }
        defer { try? FileManager.default.removeItem(at: image.deletingLastPathComponent()) }

        for route in OpenRouterRoute.catalog {
            wire.requests = []
            guard let client = OpenAICompatibleClient.openRouter(model: route.model, apiKey: "test-key") else {
                check("2 \(route.model.id) has a client", false); continue
            }
            let result = try? await client.ocr(imageURL: image)
            eq("2 \(route.model.id) OCR text parsed", result?.text, "Hello archive")
            eq("2 \(route.model.id) one request", wire.requests.count, 1)
            if let request = wire.requests.first { requestChecks(request, route: route, ocr: true) }

            wire.requests = []
            let text = try? await LLMTextClient.complete(
                prompt: "tag this", provider: .openrouter, model: route.model, thinkingLevel: nil, apiKey: "test-key",
                gatewayConfig: nil, maxTokens: 512, timeout: 60)
            check("2 \(route.model.id) text completion returns content", text?.contains("Hello archive") == true)
            if let request = wire.requests.first { requestChecks(request, route: route, ocr: false) }
            else { check("2 \(route.model.id) text request sent", false) }
        }

        // 3. No unpinned call.
        let stray = LLMModel(id: "qwen/some-other-model", displayName: "Stray", provider: .openrouter,
                             supportsThinking: false, returnsMd: false, inputCostPer1M: 0, outputCostPer1M: 0,
                             batchDiscount: 1)
        check("3 an uncatalogued model gets no client", OpenAICompatibleClient.openRouter(model: stray, apiKey: "k") == nil)
        wire.requests = []
        let strayText = try? await LLMTextClient.complete(
            prompt: "x", provider: .openrouter, model: stray, thinkingLevel: nil, apiKey: "k",
            gatewayConfig: nil, maxTokens: 16, timeout: 10)
        check("3 an uncatalogued model throws and sends nothing", strayText == nil && wire.requests.isEmpty,
              "\(wire.requests.count) requests")

        // 4. A provider failure reported in a 200.
        wire.reply = #"{"error":{"code":502,"message":"Provider returned error"}}"#
        let failed = try? await OpenAICompatibleClient.openRouter(model: OpenRouterRoute.catalog[0].model,
                                                                  apiKey: "k")!.ocr(imageURL: image)
        check("4 200-with-error is a failed page, retried as a 503", failed?.text == nil
              && failed?.errorMessage == "Provider returned error" && failed?.errorCode == "503", "\(String(describing: failed?.errorMessage)) \(String(describing: failed?.errorCode))")
        // A provider failure, or a reply cut at the limit, inside `choices`: a failed page, never a transcription.
        for (finish, code) in [("error", "503"), ("length", "length")] {
            wire.reply = #"{"choices":[{"finish_reason":"\#(finish)","message":{"content":"[document_start]\nHalf a pa"}}]}"#
            let r = try? await OpenAICompatibleClient.openRouter(model: OpenRouterRoute.catalog[0].model,
                                                                 apiKey: "k")!.ocr(imageURL: image)
            check("4 finish_reason \(finish) is a failed page", r?.text == nil && r?.errorCode == code,
                  "\(String(describing: r?.text)) \(String(describing: r?.errorCode))")
        }
        // A text call with no answer throws rather than returning an empty classification or tag list.
        wire.reply = #"{"choices":[{"finish_reason":"length","message":{"content":""}}]}"#
        let empty = try? await LLMTextClient.complete(
            prompt: "x", provider: .openrouter, model: OpenRouterRoute.catalog[2].model, thinkingLevel: nil,
            apiKey: "k", gatewayConfig: nil, maxTokens: 64, timeout: 10)
        check("4 an empty text answer throws", empty == nil, String(describing: empty))
        wire.reply = #"{"error":{"code":402,"message":"Insufficient credits"}}"#
        wire.status = 402
        var message = ""
        do {
            _ = try await LLMTextClient.complete(
                prompt: "x", provider: .openrouter, model: OpenRouterRoute.catalog[0].model, thinkingLevel: nil,
                apiKey: "k", gatewayConfig: nil, maxTokens: 64, timeout: 10)
        } catch { message = error.localizedDescription }
        check("4 a text call's HTTP error keeps OpenRouter's message", message.contains("Insufficient credits"), message)
        wire.status = 200

        // 401, not 429: a 429 is retried with real backoff.
        wire.reply = #"{"error":{"code":401,"message":"No auth credentials found"}}"#
        wire.status = 401
        let limited = try? await OpenAICompatibleClient.openRouter(model: OpenRouterRoute.catalog[0].model,
                                                                   apiKey: "k")!.ocr(imageURL: image)
        eq("4 an HTTP error keeps its status and message", [limited?.errorCode, limited?.errorMessage], ["401", "No auth credentials found"])

        makerChecks()
        await makerRequestChecks(wire: wire, image: image)
        costChecks()
        rotationVoteChecks()
        segmentationChecks()
        wire.reply = #"{"choices":[{"message":{"content":"[document_start]\nHello archive"}}]}"#
        await unmeasuredChecks(wire: wire, image: image)
        wire.reply = #"{"choices":[{"message":{"content":"[document_start]\nHello archive"}}]}"#
        await claudeChecks(wire: wire, image: image)
        await concurrentTrainingChecks(image: image)
    }

    private nonisolated static func dataCollection(_ request: URLRequest) -> String? {
        guard let bytes = request.httpBody,
              let body = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let provider = body["provider"] as? [String: Any] else { return nil }
        return provider["data_collection"] as? String
    }

    private actor TrainingRequests {
        private var firstRequest: CheckedContinuation<Void, Never>?
        private(set) var requests: [URLRequest] = []

        func record(_ request: URLRequest) async {
            requests.append(request)
            // Hold the first request open until the other job reaches the transport.
            if requests.count == 1 {
                await withCheckedContinuation { firstRequest = $0 }
            } else {
                firstRequest?.resume()
                firstRequest = nil
            }
        }
    }

    private static func concurrentTrainingChecks(image: URL) async {
        let wire = TrainingRequests()
        NetworkSession.testTransport = { request in
            await wire.record(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"choices":[{"message":{"content":"[document_start]\nHello archive"}}]}"#.utf8), response)
        }
        let model = OpenRouterRoute.catalog[0].model
        await withTaskGroup(of: Void.self) { jobs in
            for protected in [true, false] {
                jobs.addTask {
                    let settings = [SettingsKey.noTraining.rawValue: ResolvedSetting(
                        value: .bool(protected), layer: .collection, source: nil, layerName: nil)]
                    await OpenRouterDataPolicy.$denyDataCollection.withValue(OpenRouterDataPolicy.deny(settings)) {
                        let key = protected ? "protected-job" : "other-job"
                        _ = await OCRProcessor.performOCRCall(
                            imageURL: image, provider: .openrouter, model: model, thinkingLevel: nil, apiKey: key,
                            previousText: nil, previousImageURL: nil, rotationMode: .off, standardImageMB: 4,
                            cascade: .off, refusalFallback: false)
                        _ = try? await LLMTextClient.complete(
                            prompt: "Read this scratch page", provider: .openrouter, model: model, thinkingLevel: nil,
                            apiKey: key, gatewayConfig: nil, maxTokens: 64, timeout: 10)
                    }
                }
            }
        }
        let byJob = Dictionary(grouping: await wire.requests) { $0.value(forHTTPHeaderField: "Authorization") ?? "" }
        eq("11 concurrent protected job sends deny on OCR and text", byJob["Bearer protected-job"]?.map(dataCollection),
           ["deny", "deny"])
        eq("11 concurrent unprotected job omits deny on OCR and text", byJob["Bearer other-job"]?.map(dataCollection),
           [nil, nil])
        check("11 outside both jobs the default stands", !OpenRouterDataPolicy.denyDataCollection)

        // The manual card makes a separate request while the run is waiting for a review response.
        let processor = OCRProcessor()
        processor.activeResolvedSettings = ResolvedSettingsSnapshot(
            runID: UUID(), resolvedAt: Date(), collectionID: nil, projectID: nil, projectName: nil, macMemoryGB: 16,
            values: [SettingsKey.noTraining.rawValue: ResolvedSetting(
                value: .bool(true), layer: .collection, source: nil, layerName: nil)])
        var job = OCRJob(sourceURL: image)
        job.result = OCRResult(text: "March 3, 1947", classification: nil, errorMessage: nil, errorCode: nil)
        processor.jobs = [job]
        processor.manualSegImages = [ManualSegImage(fileIndex: 0, url: image, rotationDegrees: 0, kind: .document)]
        processor.manualSegAutoDate = true
        processor.manualSegModel = model
        processor.manualSegProvider = .openrouter
        processor.manualSegApiKey = "manual-card"
        await Task { await processor.fetchManualSegDate(forIndices: [0]) }.value
        let cardRequests = await wire.requests.filter { $0.value(forHTTPHeaderField: "Authorization") == "Bearer manual-card" }
        eq("11 a standalone manual date card uses the run's saved switch", cardRequests.map(dataCollection), ["deny"])
    }

    /// 10. W41.app-openrouter-claude — Claude Sonnet 5.5, the Claude model the bench measured, through OpenRouter on
    /// Anthropic's own endpoint, and on the Anthropic key's list.
    private static func claudeChecks(wire: Wire, image: URL) async {
        guard let sonnet = LLMModel.anthropicModels.first, let route = OpenRouterRoute.through(sonnet) else {
            check("10 Claude Sonnet 5.5 has a maker's route", false); return
        }
        // The Anthropic key's list: Sonnet 5.5 first, at Anthropic's list price; the 4.6 entries stay under their ids.
        eq("10 the Anthropic list", LLMModel.anthropicModels.map(\.id), ["claude-sonnet-5-5", "claude-sonnet-4-6", "claude-opus-4-6"])
        eq("10 Sonnet 5.5 at $2/$10, half in a batch", [sonnet.inputCostPer1M, sonnet.outputCostPer1M, sonnet.batchDiscount], [2, 10, 0.5])
        let reading = SettingsRouteTable.bundled?.stage("reading")?.route("claude-sonnet5.5")
        eq("10 the reading row is the Anthropic entry's", reading?.appRoute, "anthropic|claude-sonnet-5-5")
        eq("10 its figure is the plan route's", reading?.figure("overall"), 96.48)
        check("10 Opus and Haiku are not routes", LLMModel.anthropicModels.dropFirst().allSatisfy { OpenRouterRoute.through($0) == nil }
              && !OpenRouterRoute.catalog.contains { $0.model.id.contains("opus") || $0.model.id.contains("haiku") })
        // The maker's route: Anthropic's endpoint, fallbacks off, the bench's low effort, no temperature, no batch.
        eq("10 the route", [route.model.id, route.providerTag], ["anthropic/claude-sonnet-5.5", "anthropic"])
        check("10 it stands for Sonnet 5.5", route.model.measuredModel == sonnet && route.model.batchDiscount == 1)
        wire.requests = []
        _ = try? await OpenAICompatibleClient.openRouter(model: route.model, apiKey: "k", thinkingLevel: .low)?.ocr(imageURL: image)
        let body = wire.requests.first?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let provider = body?["provider"] as? [String: Any]
        eq("10 pinned to Anthropic", provider?["order"] as? [String], ["anthropic"])
        eq("10 fallbacks off, parameters required", [provider?["allow_fallbacks"] as? Bool, provider?["require_parameters"] as? Bool],
           [false, true])
        check("10 no temperature, no quantizations", body?["temperature"] == nil && provider?["quantizations"] == nil)
        eq("10 low reasoning at Low", (body?["reasoning"] as? [String: Any])?["effort"] as? String, "low")
        let note = route.settingsNote
        check("10 the note: the plan's figure, the drafter's relative, Anthropic only",
              note.contains("96.48") && note.contains("Claude plan") && note.contains("Opus 5.5") && note.contains("Runs on Anthropic only"), note)
        // Listed ahead of, and not again as, its unmeasured listing entry; Opus 5.5 stays an unmeasured entry.
        func row(_ id: String) -> String {
            #"{"id":"\#(id)","name":"N","architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},"pricing":{"prompt":"0.000002","completion":"0.00001"},"supported_parameters":["reasoning"]}"#
        }
        if let entries = OpenRouterListing.parse(Data((#"{"data":["# + [row("anthropic/claude-sonnet-5.5"), row("anthropic/claude-opus-5.5")]
            .joined(separator: ",") + "]}").utf8)) {
            OpenRouterListing.testListing = OpenRouterListing.Stored(entries: entries, fetched: Date())
            let ids = LLMProvider.openrouter.models.map(\.id)
            OpenRouterListing.testListing = nil
            eq("10 Sonnet 5.5 listed once, among the makers' routes", ids.filter { $0 == route.model.id }.count, 1)
            check("10 ahead of the unmeasured entries", (ids.firstIndex(of: route.model.id) ?? 99) < (ids.firstIndex(of: "anthropic/claude-opus-5.5") ?? -1),
                  ids.joined(separator: ", "))
        } else { check("10 the listing parses", false) }

        // The settings solver with only an OpenRouter key reaches both Claude rows, on the OpenRouter route.
        guard let table = SettingsRouteTable.bundled, let seg = table.stage("segmentation")?.route("claude-sonnet5.5"),
              let reading else { check("10 the Claude rows load", false); return }
        var res = SettingsResources(macMemoryGB: 16)
        res.keys = ["openrouter"]
        let solver = SettingsSolver(table: table, pairs: OCRPairMatrix.bundled, resources: res, answers: SettingsAnswers())
        check("10 only an OpenRouter key: the reading row is usable", solver.blockers(reading, stage: "reading").isEmpty,
              solver.blockers(reading, stage: "reading").joined(separator: "; "))
        check("10 only an OpenRouter key: the windows row is usable", solver.blockers(seg, stage: "segmentation").isEmpty,
              solver.blockers(seg, stage: "segmentation").joined(separator: "; "))
        eq("10 the reading row runs through OpenRouter", reading.appRoute(keys: ["openrouter"]), "openrouter|anthropic/claude-sonnet-5.5")
        eq("10 by the Anthropic key with it", reading.appRoute(keys: ["anthropic", "openrouter"]), "anthropic|claude-sonnet-5-5")
        // By key it is money. W41.app-claude-plan-reading: the Claude plan reaches it too, at no money, and the sheet then
        // switches on the plan, never the key (SettingsSheetTestDriver 3a).
        var planAndKey = res
        planAndKey.plans = ["claude"]
        check("10 by key alone it is money", solver.usdPer1000(reading, stage: "reading") > 19)
        check("10 with the Claude plan it is no money", SettingsSolver(table: table, pairs: nil, resources: planAndKey,
              answers: SettingsAnswers()).usdPer1000(reading, stage: "reading") == 0)
        var planOnly = SettingsResources(macMemoryGB: 16)
        planOnly.plans = ["claude"]
        check("10 the plan alone reaches the reading row", SettingsSolver(table: table, pairs: nil, resources: planOnly,
              answers: SettingsAnswers()).blockers(reading, stage: "reading").isEmpty)
        let solved = SettingsSolver(table: table, pairs: OCRPairMatrix.bundled, resources: res, answers: SettingsAnswers()).solve()
        lines.append("INFO 10 picks with only an OpenRouter key: "
                     + solved.picks.filter { ["reading", "segmentation"].contains($0.stage) }
                        .map { "\($0.stage)/\($0.part) → \($0.route?.id ?? "-")" }.joined(separator: ", "))
        let run = ReOCRRanking.executable(reading, builtInModels: OCRCascade.candidates, keys: ["openrouter"])
        check("10 Re-OCR runs it through OpenRouter", run?.0 == .openrouter && run?.1.id == route.model.id)
        // Anthropic's terms hold through OpenRouter: no training warning.
        eq("10 no training warning", SettingsTraining.runWarning([(.openRouter(modelID: route.model.id), "reads the pages")],
                                                                 resources: res), nil)

        // Its windows: the Anthropic request, through OpenRouter on Anthropic's endpoint, for Claude alone.
        guard let options = try? SegmentationOptions.loadBundled(), let spec = try? options.spec(for: .claude),
              let mix = try? options.spec(for: .mix), let voter = spec.voters.first else {
            check("10 the claude approach resolves", false); return
        }
        let routes = SegmentationRoutes(hasOpenRouterKey: true)
        check("10 the chooser: Claude runs on an OpenRouter key, the mix does not",
              routes.canRun(.anthropic, approach: .claude) && !routes.canRun(.anthropic, approach: .mix) && !routes.canRun(.anthropic))
        let row = SegmentationRow.make(.claude, options: options, pageCount: 100, routes: routes)
        check("10 the claude row can run and is priced", row.canRun && (row.apiDollars ?? 0) > 0, row.unavailableReason ?? "")
        check("10 the mix row still needs its plans or keys", !SegmentationRow.make(.mix, options: options, pageCount: 100, routes: routes).canRun)
        eq("10 the run's way for Claude's windows", SettingsTraining.segmentationWays(.windows(.claude), routes: routes, options: options),
           [.openRouter(modelID: route.model.id)])
        let captured = Wire()
        let http: APIWindowTransport.HTTP = { request in
            captured.requests.append(request)
            return (Data(#"{"choices":[{"message":{"content":"{\"pages\":[]}"}}]}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        guard case .success(let t) = WindowStageTransport.make(spec, keys: [.openrouter: "or-key"], claudeBinary: nil, http: http) else {
            check("10 the claude windows get a transport on an OpenRouter key", false); return
        }
        var missing = ""
        if case .failure(let m) = WindowStageTransport.make(mix, keys: [.openrouter: "or-key", .openai: "oa"], claudeBinary: nil, http: http) {
            missing = m.description
        }
        eq("10 the mix does not go through OpenRouter", missing, "Claude needs an Anthropic API key or a signed-in claude.")
        let answer = try? await t.send(WindowRequest(voter: voter, prompt: "PROMPT", images: [Data([1]), Data([2])], pageNumbers: [3, 4]))
        eq("10 a window answer", answer, #"{"pages":[]}"#)
        guard let w = captured.requests.first, let wb = w.httpBody.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        else { check("10 a window request was sent", false); return }
        eq("10 window: OpenRouter, the OpenRouter key", [w.url?.absoluteString, w.value(forHTTPHeaderField: "Authorization")],
           ["https://openrouter.ai/api/v1/chat/completions", "Bearer or-key"])
        eq("10 window model", wb["model"] as? String, "anthropic/claude-sonnet-5.5")
        let content = ((wb["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]) ?? []
        eq("10 window: Page n before each image, the prompt last", content.map { ($0["type"] as? String ?? "") + ($0["text"] as? String ?? "") },
           ["textPage 3:", "image_url", "textPage 4:", "image_url", "textPROMPT"])
        let wp = wb["provider"] as? [String: Any]
        eq("10 window pinned to Anthropic, fallbacks off", [wp?["order"] as? [String] == ["anthropic"], wp?["allow_fallbacks"] as? Bool == false,
                                                           wp?["require_parameters"] as? Bool == true], [true, true, true])
        check("10 window: no temperature, no reasoning, 4,096 tokens", wb["temperature"] == nil && wb["reasoning"] == nil
              && wb["max_tokens"] as? Int == APIWindowTransport.maxOutputTokens)

        // The Anthropic key's own request for Sonnet 5.5: adaptive thinking, since 4.7 and later refuse a budget.
        wire.requests = []
        wire.reply = #"{"content":[{"type":"text","text":"[document_start]\nHello archive"}],"stop_reason":"end_turn"}"#
        _ = try? await AnthropicClient(apiKey: "k", model: sonnet, thinkingLevel: .low).ocr(imageURL: image)
        let ab = wire.requests.first?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        eq("10 the Anthropic key: adaptive thinking at low effort, no budget",
           [(ab?["thinking"] as? [String: Any])?["type"] as? String, (ab?["output_config"] as? [String: Any])?["effort"] as? String,
            (ab?["thinking"] as? [String: Any])?["budget_tokens"].map { "\($0)" }], ["adaptive", "low", nil])
    }

    /// 9. W41.app-openrouter-unmeasured — every other image model OpenRouter lists, and a typed id.
    private static func unmeasuredChecks(wire: Wire, image: URL) async {
        defer { OpenRouterListing.testListing = nil; OpenRouterListing.testTyped = [] }
        eq("9 no listing read, nothing typed: the pinned routes only", LLMProvider.openrouter.models.map(\.id),
           OpenRouterRoute.makerRoutes.map(\.model.id) + OpenRouterRoute.openRoutes.map(\.model.id))
        func row(_ id: String, _ input: [String], _ output: [String], _ prompt: String?, _ completion: String?,
                 _ params: [String] = [], image: String? = nil, request: String? = nil) -> String {
            let price = [prompt.map { #""prompt":"\#($0)""# }, completion.map { #""completion":"\#($0)""# },
                         image.map { #""image":"\#($0)""# }, request.map { #""request":"\#($0)""# }]
                .compactMap { $0 }.joined(separator: ",")
            return #"{"id":"\#(id)","name":"N \#(id)","architecture":{"input_modalities":\#(input),"output_modalities":\#(output)},"#
                + #""pricing":{\#(price)},"supported_parameters":\#(params)}"#
        }
        let json = #"{"data":["# + [
            row("anthropic/claude-sonnet-4.6", ["text", "image"], ["text"], "0.000003", "0.000015", ["reasoning", "max_tokens"]),
            row("x/text-only", ["text"], ["text"], "0.0000001", "0.0000001"),
            row("x/draws", ["text", "image"], ["image"], "0.0000001", "0.0000001"),
            row("openrouter/auto", ["text", "image"], ["text"], "-1", "-1"),
            row("qwen/qwen3.6-27b", ["text", "image"], ["text"], "0.00000025", "0.000002", request: "0.005"),
            row("openai/gpt-5-nano", ["text", "image", "file"], ["text"], "0.00000005", "0.0000004", ["reasoning"]),
            row("y/free:free", ["image", "text"], ["text"], "0", "0"),
            row("y/half-priced", ["image"], ["text"], "0.000001", nil),
            row("y/per-image", ["image"], ["text"], "0.000001", "0.000001", ["reasoning"], image: "0.001"),
            row("y/per-request", ["image"], ["text"], nil, nil, request: "0.01"),
            row("y/image-free", ["image"], ["text"], "0.000001", "0.000001", image: "0"),
        ].joined(separator: ",") + "]}"
        guard let entries = OpenRouterListing.parse(Data(json.utf8)) else { check("9 the listing parses", false); return }
        eq("9 the image filter: image in, text out", entries.map(\.id),
           ["anthropic/claude-sonnet-4.6", "openrouter/auto", "qwen/qwen3.6-27b", "openai/gpt-5-nano", "y/free:free",
            "y/half-priced", "y/per-image", "y/per-request", "y/image-free"])
        eq("9 incomplete token rates and image or request charges give no token-only estimate",
           entries.filter { !$0.priced }.map(\.id),
           ["openrouter/auto", "qwen/qwen3.6-27b", "y/half-priced", "y/per-image", "y/per-request"])
        check("9 not a listing", OpenRouterListing.parse(Data(#"{"error":"x"}"#.utf8)) == nil)
        let listing = OpenRouterListing.Stored(entries: entries, fetched: Date())
        OpenRouterListing.testListing = listing
        let models = LLMProvider.openrouter.models
        eq("9 pinned routes, then image models with token rates or an image/request charge", models.map(\.id),
           OpenRouterRoute.makerRoutes.map(\.model.id) + OpenRouterRoute.openRoutes.map(\.model.id)
            + ["anthropic/claude-sonnet-4.6", "openai/gpt-5-nano", "y/free:free", "y/per-image", "y/per-request", "y/image-free"])
        guard let claude = models.first(where: { $0.id == "anthropic/claude-sonnet-4.6" }),
              let nano = models.first(where: { $0.id == "openai/gpt-5-nano" }) else { check("9 models listed", false); return }
        eq("9 marked not measured in the picker", claude.displayName, "N anthropic/claude-sonnet-4.6 (not measured)")
        eq("9 the listing's price, no batch discount", [claude.inputCostPer1M, claude.outputCostPer1M, claude.batchDiscount],
           [3, 15, 1])
        check("9 a model that reasons shows the Thinking control", claude.supportsThinking)
        check("9 a listed model is priced", !OpenRouterRoute.isUnpriced(claude))
        check("9 a free model is priced at $0, not unpriced",
              models.first { $0.id == "y/free:free" }.map { !OpenRouterRoute.isUnpriced($0) } == true)
        check("9 the pinned Qwen stays pinned, at the bench's price",
              OpenRouterRoute.route(for: OpenRouterRoute.forModel("qwen/qwen3.6-27b")!.model)?.pinned == true)
        check("9 its note says not measured", OpenRouterRoute.unmeasuredNote(claude).hasPrefix("Not measured")
              && OpenRouterRoute.unmeasuredNote(claude).contains("$3.00 in, $15.00 out"))
        check("9 the training note: not pinned", SettingsTraining.unpinned.terms == .unknown)

        // The estimate is the listing's price, and so is the ceiling.
        let est = CostEstimator.estimate(fileCount: 1000, model: claude, enableTagging: false, sendPreviousImage: false,
                                         contextCharCount: 0)
        let input = CostEstimator.estimatedPromptTokens + CostEstimator.estimatedImageTokens(for: .openrouter)
        let thinking = Double(CostEstimator.estimatedThinkingTokens(for: claude))
        let want = 1000 * (input * 3 + (CostEstimator.estimatedOutputTokens + thinking) * 15) / 1_000_000
        check("9 the estimate is at the listing's price", abs(est.ocrCost - want) < 1e-9, "\(est.ocrCost) vs \(want)")

        func sent(_ model: LLMModel, _ level: ThinkingLevel? = nil) async -> [String: Any]? {
            wire.requests = []
            guard let client = OpenAICompatibleClient.openRouter(model: model, apiKey: "test-key", thinkingLevel: level)
            else { return nil }
            let r = try? await client.ocr(imageURL: image)
            guard r?.text == "Hello archive", let data = wire.requests.first?.httpBody else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        for id in ["y/per-image", "y/per-request"] {
            guard let model = models.first(where: { $0.id == id }) else {
                check("9 charged image model is listed", false, id)
                continue
            }
            check("9 charged model is offered and marked price not estimated", OpenRouterRoute.isUnpriced(model)
                  && model.displayName.contains("price not estimated")
                  && OpenRouterRoute.unavailableSelection(id) == nil, id)
            eq("9 listed reasoning support survives unpriced model construction", model.supportsThinking, id == "y/per-image")
            let body = await sent(model)
            eq("9 the charged model itself reads", body?["model"] as? String, id)
            eq("9 an unpriced request still denies data collection", (body?["provider"] as? [String: String]),
               ["data_collection": "deny"])
        }
        guard let body = await sent(claude) else { check("9 an unpinned model reads", false); return }
        eq("9 the model's own id", body["model"] as? String, "anthropic/claude-sonnet-4.6")
        let provider = body["provider"] as? [String: Any] ?? [:]
        eq("9 no pin: only data_collection and max_price", provider.keys.sorted(), ["data_collection", "max_price"])
        eq("9 data_collection deny", provider["data_collection"] as? String, "deny")
        eq("9 max_price at the listing's price", (provider["max_price"] as? [String: Double]).map { [$0["prompt"], $0["completion"]] },
           [3, 15])
        check("9 no reasoning field with no thinking level", body["reasoning"] == nil)
        eq("9 temperature 0", body["temperature"] as? Double, 0)
        let high = await sent(claude, .high)
        eq("9 the user's High", (high?["reasoning"] as? [String: Any])?["effort"] as? String, "high")
        check("9 High gets room above the page budget", (high?["max_tokens"] as? Int ?? 0) > (body["max_tokens"] as? Int ?? 0))
        let low = await sent(nano, .low)
        eq("9 the user's Low", (low?["reasoning"] as? [String: Any])?["effort"] as? String, "low")
        check("9 an OpenAI model unpinned: no temperature", low != nil && low?["temperature"] == nil)

        // The run's ceiling is the price its estimate showed, even when the listing is read again during the run.
        OpenRouterListing.testListing = OpenRouterListing.Stored(entries: entries.map {
            $0.id == claude.id ? .init(id: $0.id, name: $0.name, inputPer1M: 6, outputPer1M: 30, reasons: true) : $0
        }, fetched: Date())
        let raised = await sent(claude)
        eq("9 the ceiling stays the estimate's", ((raised?["provider"] as? [String: Any])?["max_price"] as? [String: Double])?["prompt"], 3)
        OpenRouterListing.testListing = listing

        // A typed id: offered, unpinned; at the listing's price when listed, else unpriced (no estimate, no ceiling).
        func typed(_ id: String) -> LLMModel {
            LLMModel(id: id, displayName: id, provider: .openrouter, supportsThinking: false, returnsMd: false,
                     inputCostPer1M: 0, outputCostPer1M: 0, batchDiscount: 1)
        }
        OpenRouterListing.testTyped = [typed("someone/new-vision-model"), typed("openrouter/auto"), typed(claude.id)]
        let withTyped = LLMProvider.openrouter.models
        eq("9 typed ids follow, once each", withTyped.map(\.id).suffix(3), ["y/image-free", "someone/new-vision-model", "openrouter/auto"])
        guard let fresh = withTyped.first(where: { $0.id == "someone/new-vision-model" }) else { check("9 typed listed", false); return }
        eq("9 a typed id is marked unmeasured and unpriced", fresh.displayName,
           "someone/new-vision-model (not measured, price not estimated)")
        check("9 a typed id the listing does not price is unpriced", OpenRouterRoute.isUnpriced(fresh)
              && withTyped.first { $0.id == "openrouter/auto" }.map(OpenRouterRoute.isUnpriced) == true)
        check("9 the unpriced note", OpenRouterRoute.unmeasuredNote(fresh).contains(OpenRouterRoute.unpricedEstimateMessage))
        guard let typedBody = await sent(fresh) else { check("9 a typed id reads", false); return }
        let typedProvider = typedBody["provider"] as? [String: Any] ?? [:]
        eq("9 unpriced: data_collection deny and no max_price", typedProvider.keys.sorted(), ["data_collection"])
        // Priced or not is fixed when the model is offered: a listing read during the run changes neither way.
        guard let free = models.first(where: { $0.id == "y/free:free" }) else { check("9 free listed", false); return }
        OpenRouterListing.testListing = OpenRouterListing.Stored(entries: entries.map {
            $0.id == "openrouter/auto" ? .init(id: $0.id, name: $0.name, inputPer1M: 1, outputPer1M: 1, reasons: false)
                : ($0.id == free.id ? .init(id: $0.id, name: $0.name, inputPer1M: nil, outputPer1M: nil, reasons: false) : $0)
        } + [.init(id: fresh.id, name: "N", inputPer1M: 1, outputPer1M: 1, reasons: false)], fetched: Date())
        check("9 an unpriced run stays unpriced when the listing later prices it", OpenRouterRoute.isUnpriced(fresh))
        check("9 a free run stays priced at $0 when the listing later drops its price", !OpenRouterRoute.isUnpriced(free))
        OpenRouterListing.testListing = listing
        let freeProvider = (await sent(free))?["provider"] as? [String: Any]
        eq("9 a free model's ceiling is $0", (freeProvider?["max_price"] as? [String: Double])?["prompt"], 0)
        check("9 an unmeasured model that reasons is estimated with its reasoning room",
              CostEstimator.estimatedThinkingTokens(for: claude) == Double(OpenAICompatibleClient.openRouterReasoningAllowance)
              && CostEstimator.estimatedThinkingTokens(for: free) == 0)
        let lowRoom = await sent(nano, .low)
        eq("9 an unpinned Low gets the reasoning room", lowRoom?["max_tokens"] as? Int,
           (body["max_tokens"] as? Int ?? 0) + OpenAICompatibleClient.openRouterReasoningAllowance)
        OpenRouterListing.testTyped = []
        check("9 a typed id removed gets no client", OpenAICompatibleClient.openRouter(model: fresh, apiKey: "k") == nil)
        check("10 a listed id has no warning", OpenRouterRoute.unavailableSelection(claude.id) == nil)
        check("10 a pinned id has no warning outside the listing",
              OpenRouterRoute.unavailableSelection(OpenRouterRoute.catalog[0].model.id) == nil)
        check("10 no explicit selection uses the provider default", OpenRouterRoute.unavailableSelection("") == nil)
        let shorter = OpenRouterListing.Stored(entries: entries.filter { $0.id != claude.id }, fetched: Date())
        OpenRouterListing.testListing = shorter
        check("10 a removed listing id reports the original id",
              OpenRouterRoute.unavailableSelection(claude.id)?.contains(claude.id) == true)
        OpenRouterListing.testTyped = [typed(claude.id)]
        check("10 a deliberately typed id remains available outside the listing",
              OpenRouterRoute.unavailableSelection(claude.id) == nil)
        OpenRouterListing.testTyped = []
        await disappearanceDuringOCR(model: claude, image: image, listed: listing, shorter: shorter)
    }

    private static func disappearanceDuringOCR(
        model: LLMModel, image: URL, listed: OpenRouterListing.Stored, shorter: OpenRouterListing.Stored
    ) async {
        let root = image.deletingLastPathComponent()
        let second = root.appendingPathComponent("second.jpg")
        do { try FileManager.default.copyItem(at: image, to: second) } catch {
            check("10 second scratch page created", false, error.localizedDescription)
            return
        }
        let files = [image, second]
        var config = SessionProcessingConfig.fromDefaults()
        config.provider = .openrouter
        config.model = model
        config.gateway = nil
        config.localAgent = nil
        config.rotationMode = .off
        config.cascade = .off
        config.ocrWorkerCount = 1
        let runConfig = config
        let savedTransport = NetworkSession.testTransport
        defer { NetworkSession.testTransport = savedTransport }
        for contextCount in [0, 50] {
            let output = root.appendingPathComponent("disappeared-\(contextCount)")
            do { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) } catch {
                check("10 scratch output folder created", false, error.localizedDescription)
                return
            }
            let wire = Wire()
            OpenRouterListing.testListing = listed
            NetworkSession.testTransport = { request in
                wire.requests.append(request)  // one OCR worker, rotation and cascade off
                await MainActor.run { OpenRouterListing.testListing = shorter }
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data(wire.reply.utf8), response)
            }
            let processor = OCRProcessor()
            processor.jobs = files.map { OCRJob(sourceURL: $0) }
            processor.isProcessing = true
            let task = Task {
                await processor.performOCRPhase(
                    fileURLs: files, provider: .openrouter, model: model, thinkingLevel: nil, apiKey: "test-key",
                    outputDirectory: output,
                    segmentationContext: .init(previousTextCharCount: contextCount, sendPreviousImage: false),
                    runConfig: runConfig)
            }
            processor.processingTask = task
            await task.value
            let mode = contextCount == 0 ? "parallel scheduler" : "sequential scheduler"
            eq("10 \(mode) sends only the first request", wire.requests.count, 1)
            check("10 \(mode) saves the finished page and leaves the unread page pending",
                  processor.jobs[0].status == .succeeded && processor.jobs[1].status == .pending
                  && processor.failedFiles.isEmpty
                  && FileManager.default.fileExists(atPath: output.appendingPathComponent(image.deletingPathExtension().lastPathComponent + ".pdf").path)
                  && !FileManager.default.fileExists(atPath: output.appendingPathComponent("second.pdf").path),
                  "\(processor.jobs.map(\.status)) \(processor.outputURLMap.values.map(\.lastPathComponent))")
            check("10 \(mode) ends with one model warning",
                  !processor.isProcessing && processor.statusMessage == "Processing stopped. "
                  + OpenRouterRoute.unavailableMessage(model.id), processor.statusMessage)
        }
    }

    /// 6. GLM-5.3 Flash as a segmentation voter: options.json's approach resolves to it, and its window request
    /// is `method_openrouter.py` `request_body`'s (images alone, then the prompt; pinned; temperature 0).
    private static func segmentationChecks() {
        guard let options = try? SegmentationOptions.loadBundled() else {
            check("6 options.json loads", false); return
        }
        eq("6 options.json has no problems", options.problems(), [])
        guard let spec = try? options.spec(for: .glm) else { check("6 the glm approach resolves", false); return }
        eq("6 glm's one voter", spec.voters.map(\.modelID), ["z-ai/glm-5.3-flash"])
        eq("6 glm's level is the one fitted at the 98% bar", spec.level, 0.925)
        let voter = spec.voters[0]
        eq("6 glm voter goes by OpenRouter at minimal, prompt c1", [voter.provider.rawValue, voter.thinkingLevel ?? "", voter.prompt.rawValue],
           ["openrouter", "minimal", "c1"])
        let test = options.approach(.glm)?.figures?.test
        eq("6 glm test figures (cheap-models.md's 98% row)", [test?.pagesExactNoReview.map { ($0 * 1000).rounded() / 10 },
                                                             test.map { ($0.flaggedPer100Pages * 10).rounded() / 10 },
                                                             test.map { ($0.pagesExactAfterReview * 1000).rounded() / 10 }],
           [82.8, 33.1, 96.9])  // rescored on the owner's corrections, W46.seg-truth-owner-fixes
        let cost = options.approach(.glm)?.cost?.total
        check("6 glm costs $1.16 per 1,000 pages, no batch", cost.map { abs($0.listUSDPer1000Pages - 1.16) < 0.005 } == true
              && cost?.batchUSDPer1000Pages == nil, String(describing: cost))
        let r = WindowRequest(voter: voter, prompt: "PROMPT", images: [Data([1, 2]), Data([3, 4])], pageNumbers: [5, 6])
        guard let request = try? APIWindowTransport.request(r, key: "test-key"),
              let data = request.httpBody,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = String(data: data, encoding: .utf8) else {
            check("6 glm window request builds", false); return
        }
        eq("6 window endpoint", request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        eq("6 window bearer", request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let content = ((body["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]) ?? []
        eq("6 window: the images alone in order, then the prompt", content.map { $0["type"] as? String ?? "" },
           ["image_url", "image_url", "text"])
        eq("6 window prompt last", content.last?["text"] as? String, "PROMPT")
        let provider = body["provider"] as? [String: Any]
        eq("6 window provider pinned", provider?["order"] as? [String], ["z-ai"])
        eq("6 window precision", provider?["quantizations"] as? [String], ["fp8"])
        check("6 window fallbacks off", raw.contains(#""allow_fallbacks":false"#))
        check("6 window: no data_collection with the switch off", provider?["data_collection"] == nil, raw)
        let denied = OpenRouterDataPolicy.$denyDataCollection.withValue(true) {
            try? APIWindowTransport.request(r, key: "test-key")
        }
        eq("6 window under the switch: data_collection deny", denied.flatMap(dataCollection), "deny")
        let route0 = OpenRouterRoute.catalog[0]
        eq("6 the provider field with deny", OpenAICompatibleClient.openRouterProviderField(route0, denyDataCollection: true)["data_collection"] as? String, "deny")
        check("6 the provider field without", OpenAICompatibleClient.openRouterProviderField(route0, denyDataCollection: false)["data_collection"] == nil)
        eq("6 the switch as a snapshot holds it",
           [OpenRouterDataPolicy.deny([SettingsKey.noTraining.rawValue: ResolvedSetting(value: .bool(true), layer: .collection, source: nil, layerName: nil)]),
            OpenRouterDataPolicy.deny([:]), OpenRouterDataPolicy.deny(nil)], [true, false, false])
        eq("6 window max_price", (provider?["max_price"] as? [String: Double])?["completion"], 0.50)
        eq("6 window temperature 0", (body["temperature"] as? NSNumber)?.doubleValue, 0)
        check("6 window reasoning minimal, excluded", (body["reasoning"] as? [String: Any])?["effort"] as? String == "minimal"
              && raw.contains(#""exclude":true"#))
        // A window failure in a 200 is one window's failure, retried by the engine; an empty answer likewise.
        let errorReply = Data(#"{"error":{"code":502,"message":"Provider returned error"}}"#.utf8)
        check("6 a 200-with-error window fails", (try? APIWindowTransport.replyText(.openrouter, data: errorReply, status: 200)) == nil)
        let limited = Data(#"{"error":{"code":429,"message":"Rate limited"}}"#.utf8)
        var stopped = false
        do { _ = try APIWindowTransport.replyText(.openrouter, data: limited, status: 200) }
        catch let e as WindowTransportError { if case .usageLimit = e { stopped = true } } catch {}
        check("6 an in-body 429 stops the run", stopped)
        func kind(_ body: String, _ status: Int) -> String {
            do { _ = try APIWindowTransport.replyText(.openrouter, data: Data(body.utf8), status: status); return "ok" }
            catch let e as WindowTransportError {
                switch e { case .fatal: return "fatal"; case .failed: return "failed"; default: return "other" }
            } catch { return "other" }
        }
        eq("6 an upstream 400 is one window's failure, retried",
           kind(#"{"error":{"code":400,"message":"Provider returned error","metadata":{"raw":"busy"}}}"#, 400), "failed")
        eq("6 OpenRouter's own 400 is fatal", kind(#"{"error":{"code":400,"message":"Invalid model"}}"#, 400), "fatal")
        let ok = Data(#"{"choices":[{"message":{"content":"{\"pages\":[]}"}}]}"#.utf8)
        eq("6 a window answer is read", try? APIWindowTransport.replyText(.openrouter, data: ok, status: 200), #"{"pages":[]}"#)
        let stray = WindowVoter(name: "x", provider: .openrouter, modelID: "z-ai/other", thinkingLevel: nil, prompt: .c1)
        check("6 an unpinned window voter is refused", (try? APIWindowTransport.request(
            WindowRequest(voter: stray, prompt: "p", images: [], pageNumbers: []), key: "k")) == nil)
        var missing = ""
        if case .failure(let m) = WindowStageTransport.make(spec, keys: [:], claudeBinary: nil) { missing = m.description }
        eq("6 the glm route names its key", missing, "GLM-5.3 Flash needs an OpenRouter API key.")
        let routes = SegmentationRoutes(hasOpenRouterKey: true)
        check("6 an OpenRouter key makes glm runnable", routes.canRun(.openrouter) && !SegmentationRoutes().canRun(.openrouter))
    }

    /// 8. W41.app-openrouter-any — the measured Gemini and GPT models through OpenRouter, on their makers' endpoints.
    private static func makerChecks() {
        let makers = OpenRouterRoute.makerRoutes
        // The id mapping for every measured model (`ocr_cloud.py` / `method_openrouter.py` MODELS).
        eq("8 the id mapping", Dictionary(uniqueKeysWithValues: makers.map { ($0.maker?.id ?? "", $0.model.id) }),
           ["gemini-3.8-flash": "google/gemini-3.8-flash", "gemini-3.5-flash-lite": "google/gemini-3.5-flash-lite",
            "gemini-3.1-flash-lite": "google/gemini-3.1-flash-lite", "gemini-3.5-flash": "google/gemini-3.5-flash",
            "gemini-3.1-pro": "google/gemini-3.1-pro-preview", "gpt-5.4-mini": "openai/gpt-5.4-mini",
            // W41.app-openrouter-claude: OpenRouter's listing's id (`ocr_cloud.py`, `ocr-panel-cloud-prices.json`).
            "claude-sonnet-5-5": "anthropic/claude-sonnet-5.5"])
        eq("8 each pinned to its maker's own endpoint", makers.map(\.providerTag),
           ["google-ai-studio", "google-ai-studio", "google-ai-studio", "google-ai-studio", "google-ai-studio", "openai",
            "anthropic"])
        // Claude's endpoint refuses reasoning off, so the bench sent low (`ocr-panel-cloud-pilot.md`).
        eq("8 the reasoning the bench sent", makers.map(\.reasoning),
           [.effort("low"), .effort("minimal"), .effort("minimal"), .effort("minimal"), .effort("low"), .effort("minimal"),
            .effort("low")])
        for r in makers {
            guard let m = r.maker else { check("8 \(r.model.id) names its maker", false); continue }
            check("8 \(r.model.id) is an OpenRouter model with no batch", r.model.provider == .openrouter && r.model.batchDiscount == 1)
            eq("8 \(r.model.id) thinks as its maker does", r.model.supportsThinking, m.supportsThinking)
            check("8 \(r.model.id) stands for its maker's model", r.model.measuredModel == m
                  && OpenRouterRoute.through(m)?.model.id == r.model.id && OpenRouterRoute.through(r.model)?.model.id == r.model.id)
            // Before the listing is read: the maker's price plus a tenth (Gemini 3.8 Flash's listing, 2026-11-18).
            check("8 \(r.model.id) priced at its maker's plus a tenth until the listing is read",
                  abs(r.model.inputCostPer1M - m.inputCostPer1M * 1.1) < 1e-6 && abs(r.model.outputCostPer1M - m.outputCostPer1M * 1.1) < 1e-6,
                  "\(r.model.inputCostPer1M)/\(r.model.outputCostPer1M)")
            let note = r.settingsNote
            check("8 \(r.model.id) note: maker, figure, fallbacks off, no batch",
                  note.hasPrefix(m.displayName + " through OpenRouter") && note.contains("NES")
                  && note.contains("fallbacks off") && note.contains("no batch discount"), note)
        }
        eq("8 Gemini 3.8 Flash's note says it drafted part of the truth",
           makers[0].settingsNote.contains("drafted part of their truth"), true)
        check("8 a cascade never escalates to the same model by its other route",
              !OCRCascade(routeID: OCRCascade.routeID(for: LLMModel.geminiModels[0])).applies(to: .openrouter, model: makers[0].model)
              && !OCRCascade(routeID: OCRCascade.routeID(for: makers[0].model)).applies(to: .gemini, model: LLMModel.geminiModels[0])
              && OCRCascade(routeID: OCRCascade.routeID(for: LLMModel.geminiModels[4])).applies(to: .openrouter, model: makers[0].model))
        eq("8 the OpenRouter default is the app's default", LLMProvider.openrouter.models.first?.id, "google/gemini-3.8-flash")
        check("8 an open model stands for itself", OpenRouterRoute.catalog[0].model.measuredModel == OpenRouterRoute.catalog[0].model)

        // Every reading row the bench measured through OpenRouter on a maker's model has its route.
        guard let table = SettingsRouteTable.bundled, let reading = table.stage("reading")?.routes else {
            check("8 the route table loads", false); return
        }
        let makerRows = reading.filter { r in
            r.needs.key.contains("openrouter") && ["gemini|", "openai|", "anthropic|"].contains { r.appRoute?.hasPrefix($0) == true }
        }
        check("8 the table has the makers' rows", makerRows.count == makers.count, makerRows.map(\.id).joined(separator: ", "))
        for r in makerRows {
            let through = r.appRoute(keys: ["openrouter"])
            let id = through?.split(separator: "|").last.map(String.init) ?? ""
            check("8 \(r.id) runs through OpenRouter with only an OpenRouter key",
                  through?.hasPrefix("openrouter|") == true && LLMProvider.openrouter.models.contains { $0.id == id },
                  through ?? "nil")
            eq("8 \(r.id) keeps its maker's route with the maker's key", r.appRoute(keys: ["openrouter", r.appRoute!.components(separatedBy: "|")[0]]), r.appRoute)
            eq("8 \(r.id) keeps its maker's route with no key", r.appRoute(keys: []), r.appRoute)
            let run = ReOCRRanking.executable(r, builtInModels: OCRCascade.candidates + LLMModel.appleVisionModels, keys: ["openrouter"])
            check("8 \(r.id) Re-OCR runs it through OpenRouter", run?.0 == .openrouter && run?.1.id == id)
        }
        if let open = reading.first(where: { $0.appRoute == "openrouter|qwen/qwen3.6-27b" }) {
            eq("8 an open model's row is unchanged", open.appRoute(keys: ["openrouter"]), "openrouter|qwen/qwen3.6-27b")
        }
        // The sheet sees the run's mapped model as its maker's measured row.
        let running = SettingsAdvisor.running(segmentation: .defaultApproach, useAppleVision: false, useGateway: false,
                                                useLocalAgent: false, provider: .openrouter, model: makers[0].model, table: table)
        eq("8 the sheet finds the mapped model's row", running.readingRouteID, "gemini3.8-flash")

        // The key interview with only an OpenRouter key: what it recommends runs on that key alone.
        let mac = MacInventory.read(exists: { $0 == LLMProvider.openrouter.rawValue }, claudePath: nil, memoryGB: 16, chip: "Apple M4")
        eq("8 interview: only the OpenRouter key is found", mac.keys, ["openrouter"])
        var layer = SettingsLayer(kind: .general, name: "General")
        GeneralInterviewAnswers.applyFound(mac, to: &layer, now: Date(timeIntervalSince1970: 1_800_000_000))
        let resources = SettingsResolver(general: layer).resources(macMemoryGB: 16)
        eq("8 interview: the sheet's keys", resources.keys, ["openrouter"])
        var answers = SettingsAnswers()
        answers.ceilingUSD = 100
        let solution = SettingsSolver(table: table, pairs: OCRPairMatrix.bundled, resources: resources, answers: answers).solve()
        let picks = solution.picks.filter { $0.stage == "reading" }.compactMap(\.route).filter { $0.appRoute != nil }
        lines.append("INFO 8 reading picks with only an OpenRouter key: "
                     + picks.map { "\($0.id) → \($0.appRoute(keys: resources.keys) ?? "-")" }.joined(separator: ", "))
        check("8 interview: a pick reads through a maker's model", picks.contains { makerRows.map(\.id).contains($0.id) })
        check("8 interview: every pick runs on the OpenRouter key", !picks.isEmpty && picks.allSatisfy { r in
            let ar = r.appRoute(keys: resources.keys) ?? ""
            return ar.hasPrefix("openrouter|") && LLMProvider.openrouter.models.contains { "openrouter|" + $0.id == ar }
        })

        // Google's and OpenAI's paid API terms rule training out: no warning under the no-training switch.
        for r in makers {
            eq("8 \(r.model.id) raises no training warning", SettingsTraining.runWarning(
                [(.openRouter(modelID: r.model.id), "reads the pages")], resources: resources), nil)
        }
        // Priced as its maker: the same image and thinking tokens, at the route's prices, no batch.
        let direct = LLMModel.geminiModels[0], mapped = makers[0].model
        let d = CostEstimator.estimate(fileCount: 1000, model: direct, enableTagging: false, sendPreviousImage: false, contextCharCount: 0)
        let o = CostEstimator.estimate(fileCount: 1000, model: mapped, enableTagging: false, sendPreviousImage: false, contextCharCount: 0)
        check("8 Gemini 3.8 Flash through OpenRouter costs its maker's tokens at a tenth more", abs(o.ocrCost - d.ocrCost * 1.1) < 1e-6,
              "\(o.ocrCost) vs \(d.ocrCost)")
        eq("8 no batch discount through OpenRouter", o.batchOcrCost, o.ocrCost)
        eq("8 its thinking tokens are its maker's", CostEstimator.estimatedThinkingTokens(for: mapped), 117)
        // The listing's row for a maker: the one Google AI Studio row, whatever precision it lists.
        let listing = Data(#"{"data":{"id":"google/gemini-3.8-flash","endpoints":[{"tag":"google-vertex","quantization":"unknown","pricing":{"prompt":"0.0000009","completion":"0.0000045"}},{"tag":"google-ai-studio","pricing":{"prompt":"0.000000825","completion":"0.000004125"}}]}}"#.utf8)
        let price = OpenRouterPrices.parse(listing, route: makers[0])
        eq("8 the listing's AI Studio row prices the maker's route", [price?.inputPer1M, price?.outputPer1M, nil], [0.825, 4.125, nil])
        eq("8 and names where it came from", price?.tag, "google-ai-studio")
    }

    /// 8. The maker's requests: the user's thinking level, and Gemini's refusals as OpenRouter passes them on.
    private static func makerRequestChecks(wire: Wire, image: URL) async {
        let flash = OpenRouterRoute.makerRoutes[0].model, lite = OpenRouterRoute.makerRoutes[1].model
        func body(_ model: LLMModel, _ level: ThinkingLevel?) async -> [String: Any]? {
            wire.requests = []
            wire.reply = #"{"choices":[{"message":{"content":"[document_start]\nHello archive"}}]}"#
            _ = try? await OpenAICompatibleClient.openRouter(model: model, apiKey: "k", thinkingLevel: level)?.ocr(imageURL: image)
            return wire.requests.first?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        let high = await body(flash, .high)
        eq("8 High reads at effort high", (high?["reasoning"] as? [String: Any])?["effort"] as? String, "high")
        eq("8 High gets the direct clients' high budget on top", high?["max_tokens"] as? Int,
           8192 + ThinkingLevel.high.budgetTokens(for: .documentOCR))
        let low = await body(flash, .low)
        eq("8 Low reads at the bench's effort", (low?["reasoning"] as? [String: Any])?["effort"] as? String, "low")
        eq("8 Low keeps the bench's 8,192", low?["max_tokens"] as? Int, 8192)
        let mini = await body(OpenRouterRoute.makerRoutes[5].model, .low)
        eq("8 GPT-5.4 mini at Low keeps the bench's minimal", (mini?["reasoning"] as? [String: Any])?["effort"] as? String, "minimal")
        eq("8 GPT-5.4 mini at High reads at high", ((await body(OpenRouterRoute.makerRoutes[5].model, .high))?["reasoning"]
            as? [String: Any])?["effort"] as? String, "high")
        let none = await body(lite, .high)
        eq("8 a model with no thinking level keeps the bench's effort", (none?["reasoning"] as? [String: Any])?["effort"] as? String, "minimal")
        let open = await body(OpenRouterRoute.catalog[2].model, .high)
        eq("8 an open model keeps the bench's effort", (open?["reasoning"] as? [String: Any])?["effort"] as? String, "minimal")

        func read(_ model: LLMModel, _ reply: String, status: Int = 200) async -> OCRResult? {
            wire.reply = reply
            wire.status = status
            defer { wire.status = 200 }
            return try? await OpenAICompatibleClient.openRouter(model: model, apiKey: "k")?.ocr(imageURL: image)
        }
        let recitation = await read(flash, #"{"choices":[{"finish_reason":"stop","native_finish_reason":"RECITATION","message":{"content":""}}]}"#)
        eq("8 Gemini's RECITATION finish is its refusal", recitation?.errorCode, "Recitation")
        check("8 and a refusal the second reader takes", recitation.map(OCRRefusalFallback.isRefusal) == true)
        let raw = #"{"error":{"code":502,"message":"Provider returned error","metadata":{"raw":"{\"error\":\"RECITATION\"}"}}}"#
        eq("8 a provider error naming RECITATION is the refusal, not a retried 503", (await read(flash, raw))?.errorCode, "Recitation")
        eq("8 so is an HTTP error naming it", (await read(flash, raw, status: 400))?.errorCode, "Recitation")
        eq("8 a content filter is its native reason", (await read(flash,
            #"{"choices":[{"finish_reason":"content_filter","native_finish_reason":"SAFETY","message":{"content":null}}]}"#))?.errorCode, "SAFETY")
        eq("8 Gemini's other reason with no text is that reason", (await read(flash,
            #"{"choices":[{"finish_reason":"stop","native_finish_reason":"OTHER","message":{"content":""}}]}"#))?.errorCode, "OTHER")
        eq("8 OpenAI's content filter fails the page", (await read(OpenRouterRoute.makerRoutes[5].model,
            #"{"choices":[{"finish_reason":"content_filter","message":{"content":"[document_start]\nHalf"}}]}"#))?.errorCode, "content_filter")
        eq("8 Gemini's STOP with text is its reading", (await read(flash,
            #"{"choices":[{"finish_reason":"stop","native_finish_reason":"STOP","message":{"content":"[document_start]\nHello archive"}}]}"#))?.text, "Hello archive")
        check("8 an open model's reply is not read as Gemini's refusal", (await read(OpenRouterRoute.catalog[0].model,
            #"{"choices":[{"finish_reason":"stop","native_finish_reason":"RECITATION","message":{"content":"[document_start]\nHello archive"}}]}"#))?.text == "Hello archive")
        eq("8 an unrelated provider error is still a retried 503", (await read(flash,
            #"{"error":{"code":502,"message":"Provider returned error"}}"#))?.errorCode, "503")

        // The refused page goes to the second reader, as Gemini's own refusal does.
        guard let refused = recitation, let qwen = OpenRouterRoute.forModel(OCRRefusalFallback.openRouterReaderID)?.model else {
            check("8 a refusal to resolve", false); return
        }
        OCRRefusalFallback.routesOverride = { [OCRRefusalFallback.Route(provider: .openrouter, model: qwen, apiKey: "k", localAgent: nil)] }
        defer { OCRRefusalFallback.routesOverride = nil }
        wire.reply = #"{"choices":[{"message":{"content":"[document_start]\nHello archive"}}]}"#
        func resolve(_ model: LLMModel) async -> OCRResult {
            await OCRCascade.resolve(refused, cascade: .off, provider: .openrouter, model: model, refusalFallback: true,
                                     imageURL: image, previousText: nil, previousImageURL: nil, customPrompt: nil,
                                     imageScale: 1, visionSettings: .default)
        }
        let second = await resolve(flash)
        check("8 Gemini's refusal through OpenRouter is read by the second reader",
              second.text == "Hello archive" && second.secondReader?.model == qwen.displayName,
              String(describing: second.secondReader))
        let kept = await resolve(OpenRouterRoute.catalog[3].model)
        check("8 an open model's failure is not sent to Gemini's second reader", kept.secondReader == nil && kept.text == nil)
    }

    private static func catalogChecks() {
        let c = OpenRouterRoute.openRoutes
        eq("1 models", c.map(\.model.id), ["qwen/qwen3-vl-235b-a22b-instruct", "qwen/qwen3.6-27b", "z-ai/glm-5.3-flash",
                                            "qwen/qwen3.8-flash", "qwen/qwen3.5-9b", "qwen/qwen3-vl-8b-instruct",
                                            "qwen/qwen3-vl-30b-a3b-instruct", "qwen/qwen3.5-35b-a3b",
                                            "mistralai/mistral-medium-3-5"])
        eq("1 pinned providers", c.map(\.providerTag), ["deepinfra/fp8", "chutes/fp8", "z-ai", "alibaba", "deepinfra/bf16",
                                                    "parasail/bf16", "deepinfra/fp8", "deepinfra/fp8", "mistral"])
        eq("1 precisions", c.map(\.precision), ["fp8", "fp8", "fp8", "unknown", "bf16", "bf16", "fp8", "fp8", "unknown"])
        eq("1 reasoning as the bench sent it", c.map(\.reasoning), [.none, .off, .effort("minimal"), .off, .off,
                                                         .none, .none, .off, .off])
        // The pinned endpoints' prices: the panel's frozen catalogs, and GLM's from its seg-cheap call log.
        eq("1 input prices", c.map(\.model.inputCostPer1M), [0.20, 0.25, 0.15, 0.15, 0.10, 0.25, 0.15, 0.14, 1.50])
        eq("1 output prices", c.map(\.model.outputCostPer1M), [0.88, 2.00, 0.50, 0.47, 0.15, 0.75, 0.60, 1.00, 7.50])
        // W43.app-guide-refresh: every measured model is a reading row of the rule table, linked by its app route.
        let reading = SettingsRouteTable.bundled?.stage("reading")?.routes ?? []
        check("1 every measured model is linked from the rule table",
              c.filter { !$0.settingsNote.contains("not been measured") }.allSatisfy { r in
                  reading.contains { $0.appRoute == "openrouter|\(r.model.id)" } })
        // W47.wh-readers-lost-clients: and every OpenRouter reading row, the lower-scoring ones included, has its pin.
        check("1 every OpenRouter reading row runs on a pinned route",
              reading.compactMap(\.appRoute).filter { $0.hasPrefix("openrouter|") }
                  .allSatisfy { ar in OpenRouterRoute.catalog.contains { "openrouter|" + $0.model.id == ar } })
        check("1 the lower-scoring hosted rows run in the app",
              ["qwen3-vl-8b", "qwen3-vl-30b-a3b", "qwen3.5-35b-a3b", "mistral-medium3.5"].allSatisfy { id in
                  reading.first { $0.id == id }.map { $0.lowerScoring && $0.appRoute?.hasPrefix("openrouter|") == true } == true })
        check("1 every model is an OpenRouter model", c.allSatisfy { $0.model.provider == .openrouter })
        // W41.app-openrouter-any: the makers' measured models first (the provider's default is the app's), then these.
        // Section 9 checks that nothing else is listed with no listing read and no id typed (the seam hides this
        // Mac's own); before the seam, what a real launch read may follow them.
        eq("1 the provider's models start with the makers' routes then the open ones",
           Array(LLMProvider.openrouter.models.prefix(OpenRouterRoute.catalog.count)).map(\.id),
           (OpenRouterRoute.makerRoutes + c).map(\.model.id))
        eq("1 the catalog is every pinned route", OpenRouterRoute.catalog.map(\.model.id),
           (c + OpenRouterRoute.makerRoutes).map(\.model.id))
        check("1 no batch path", !LLMProvider.openrouter.supportsBatch)
        check("1 names carry provider and precision for the PDF header",
              c.allSatisfy { $0.model.displayName.contains($0.providerTag.split(separator: "/")[0]) && $0.model.displayName.contains($0.precision) },
              c.map(\.model.displayName).joined(separator: ", "))
        check("1 the Settings note names provider, precision and fallbacks",
              c.allSatisfy { ($0.settingsNote.contains($0.precision) || $0.settingsNote.contains("lists none"))
                  && $0.settingsNote.contains("fallbacks off") })
        check("1 GLM's note says its OCR is unmeasured", c[2].settingsNote.contains("not been measured"))
        check("1 the page guidance sees Qwen3.6 27B", OCRPageGuidance.builtInModelIDs.contains("qwen/qwen3.6-27b"))
        eq("1 the Keychain account is the bench's", LLMProvider.openrouter.rawValue, "OpenRouter")
    }

    private static func requestChecks(_ request: URLRequest, route: OpenRouterRoute, ocr: Bool) {
        let tag = "\(route.model.id) \(ocr ? "OCR" : "text")"
        eq("2 \(tag) endpoint", request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        eq("2 \(tag) bearer", request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        guard let data = request.httpBody,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = String(data: data, encoding: .utf8) else {
            check("2 \(tag) body is JSON", false); return
        }
        eq("2 \(tag) model", body["model"] as? String, route.model.id)
        let provider = body["provider"] as? [String: Any]
        eq("2 \(tag) provider order", provider?["order"] as? [String], [route.providerTag])
        if route.maker == nil {
            eq("2 \(tag) quantizations", provider?["quantizations"] as? [String], [route.precision])
            check("2 \(tag) no require_parameters", provider?["require_parameters"] == nil)
        } else {
            // A maker serves its own weights; an endpoint that would drop the reasoning setting is refused.
            check("2 \(tag) no quantizations for a maker", provider?["quantizations"] == nil)
            check("2 \(tag) require_parameters", raw.contains(#""require_parameters":true"#))
        }
        // A JSON boolean false, not 0: OpenRouter would read a number as no setting at all.
        check("2 \(tag) allow_fallbacks is JSON false", raw.contains(#""allow_fallbacks":false"#), raw.prefix(400).description)
        let price = provider?["max_price"] as? [String: Double]
        eq("2 \(tag) max_price prompt", price?["prompt"], route.model.inputCostPer1M)
        eq("2 \(tag) max_price completion", price?["completion"], route.model.outputCostPer1M)
        if [LLMProvider.openai, .anthropic].contains(route.maker?.provider) {
            check("2 \(tag) no temperature on OpenAI's or Anthropic's endpoint", body["temperature"] == nil)
        } else {
            eq("2 \(tag) temperature 0", (body["temperature"] as? NSNumber)?.doubleValue, 0)
        }
        let allowance: Int
        // A maker's page read keeps the bench's 8,192 with its reasoning inside (`ocr_panel.py`).
        if case .effort = route.reasoning, route.maker == nil || !ocr { allowance = 1024 } else { allowance = 0 }
        eq("2 \(tag) max_tokens (plus room for reasoning)", body["max_tokens"] as? Int, (ocr ? 8192 : 512) + allowance)
        check("2 \(tag) no OpenAI reasoning_effort", body["reasoning_effort"] == nil)
        let reasoning = body["reasoning"] as? [String: Any]
        switch route.reasoning {
        case .none: check("2 \(tag) no reasoning field", reasoning == nil)
        case .off: check("2 \(tag) reasoning off", raw.contains(#""enabled":false"#) && reasoning?.count == 1, raw.prefix(400).description)
        case .effort(let level):
            check("2 \(tag) reasoning effort \(level), excluded",
                  reasoning?["effort"] as? String == level && raw.contains(#""exclude":true"#))
        }
        if ocr {
            let content = ((body["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]) ?? []
            eq("2 \(tag) image then prompt", content.map { $0["type"] as? String ?? "" }, ["image_url", "text"])
            let detail = (content.first?["image_url"] as? [String: Any])?["detail"] as? String
            eq("2 \(tag) image detail", detail, route.maker?.provider == .openai ? "high" : nil)
        }
    }

    private static func costChecks() {
        let m = OpenRouterRoute.catalog[0].model
        let e = CostEstimator.estimate(fileCount: 1000, model: m, enableTagging: false, sendPreviousImage: false,
                                       contextCharCount: 0)
        let input = CostEstimator.estimatedPromptTokens + CostEstimator.estimatedImageTokens(for: .openrouter)
        let want = 1000 * (input * 0.20 + CostEstimator.estimatedOutputTokens * 0.88) / 1_000_000
        check("5 priced at the pinned provider's rates", abs(e.ocrCost - want) < 1e-9, "\(e.ocrCost) vs \(want)")
        // The panel paid $1.22 per 1,000 pages on this route (99 calls). The estimate may be above, never below.
        check("5 not below the panel's $1.22 per 1,000 pages, and within 1.5x", e.ocrCost >= 1.22 && e.ocrCost <= 1.83,
              String(format: "$%.2f", e.ocrCost))
        let q = CostEstimator.estimate(fileCount: 1000, model: OpenRouterRoute.catalog[1].model, enableTagging: false,
                                       sendPreviousImage: false, contextCharCount: 0)
        // About 1.57x the panel here: the app assumes 850 output tokens a page (its prompt adds the classification
        // line; the panel's replies averaged ~455), and this model's output is the dearer side of its price.
        check("5 Qwen3.6 27B not below the panel's $1.74, within 1.75x", q.ocrCost >= 1.74 && q.ocrCost <= 3.05,
              String(format: "$%.2f", q.ocrCost))
        eq("5 no batch discount offered", e.batchOcrCost, e.ocrCost)
        eq("5 GLM's minimal reasoning is priced as output", CostEstimator.estimatedThinkingTokens(for: OpenRouterRoute.catalog[2].model), 153)
        let rotation = TimeEstimator.estimate(
            fileCount: 10, model: m, rotationMode: .llmMajority, enableTagging: false, ocrWorkers: 4)
        check("5 the time estimate counts three Gemini comparisons per page across four workers",
              abs(rotation.rotationSeconds - 9 * 5.79) < 1e-9)
        let majority = CostEstimator.estimate(fileCount: 10, model: m, enableTagging: false, sendPreviousImage: false,
                                               contextCharCount: 0, rotationMode: .llmMajority)
        check("5 the estimate prices three Gemini comparisons per page", abs(majority.rotationCost - 30 * 0.0037) < 1e-9)
    }

    /// W46.rotation-majority-fix: llmMajority's vote is deterministic. A tie goes to the earliest vote (the first
    /// ordering that answered), never to the Dictionary's per-launch hash order.
    private static func rotationVoteChecks() {
        eq("7 no votes, no answer (Vision decides)", LLMRotationDetector.majority(of: []), nil)
        eq("7 a majority wins wherever it falls", LLMRotationDetector.majority(of: [90, 0, 0]), 0)
        eq("7 three different answers take the first ordering's", LLMRotationDetector.majority(of: [270, 90, 180]), 270)
        eq("7 three different answers, other order", LLMRotationDetector.majority(of: [180, 270, 0]), 180)
        eq("7 a two-vote split takes the earlier", LLMRotationDetector.majority(of: [90, 0]), 90)
        eq("7 the label claims no accuracy", RotationMode.llmMajority.displayName, "LLM comparative ×3")
    }

    private static func makeImage() -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("openrouter-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                                         samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = dir.appendingPathComponent("page.png")
        return (try? png.write(to: url)) == nil ? nil : url
    }

    private static func finish() {
        lines.append(failures == 0 ? "ALL PASS" : "FAILURES \(failures)")
        let text = lines.joined(separator: "\n") + "\n"
        if let out = ProcessInfo.processInfo.environment["OPENROUTER_TEST_OUT"] {
            try? text.write(toFile: out, atomically: true, encoding: .utf8)
        } else {
            print(text)
        }
    }
}

#endif
