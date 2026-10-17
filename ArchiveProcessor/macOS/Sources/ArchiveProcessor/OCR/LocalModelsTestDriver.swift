import AppKit
import Foundation

/// Key-free, no-network contract for W41.app-local-models, gated by `LOCALMODELS_TEST=1` (does nothing in normal
/// use). Every request goes to the no-wire seam (`NetworkSession.testTransport`), which this flag enables; the driver
/// stops at once if the seam is not active after the stub is installed, so nothing reaches a server. No Keychain read
/// (headless mode reads none), no window, never the corpus. Run by `scripts/test-local-models.sh`.
///
/// What has to be true:
///   1. The model offered follows the Mac's memory as W41-answers.md §1 has it, and nothing below 16 GB.
///   2. A local model's request carries the lower token cap, temperature 0, the stand-in key and the long timeout; a
///      remote gateway's request is unchanged.
///   3. A looped reply fails the page as `length` (cut at the cap, or ended by itself), never a transcription, while
///      leaders, blank rows and ordinary pages pass; reasoning text is stripped; an unknown header keeps the text.
///   4. Such a page goes to the user's escalation model only when the user allowed it, recorded with the local model
///      as the first reader; a remote gateway's page still never escalates.
///   5. One page at a time, the time estimate at the model's pace, $0, and the settings round trip.
///   6. (W41.app-local-models-fu1) The local reply is streamed and closed as soon as it loops, a looped or capped page
///      is read once more with a repetition penalty, the reason says so, and a timeout or a good page is read once.
@MainActor
enum LocalModelsTestDriver {
    nonisolated static let envKey = "LOCALMODELS_TEST"
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

    /// Every request the stub saw, and what each host answers.
    private final class Wire: @unchecked Sendable {
        let lock = NSLock()
        var requests: [URLRequest] = []
        var answers: [String: String] = [:]
        /// Answers given in turn before `answers`, one per request: a first and a second reading that differ. A
        /// queued "THROW" fails that request on the wire; "STATUS 422 <body>" answers it with that status.
        var queued: [String] = []
        var timesOut = false
        func answer(_ request: URLRequest) throws -> String {
            try lock.withLock {
                requests.append(request)
                if timesOut { throw URLError(.timedOut) }
                if !queued.isEmpty {
                    let next = queued.removeFirst()
                    if next == "THROW" { throw URLError(.cannotConnectToHost) }
                    return next
                }
                let host = request.url?.host ?? ""
                return answers.first { host.contains($0.key) }?.value ?? "{}"
            }
        }
        func reset(_ answers: [String: String], queued: [String] = []) {
            lock.withLock { self.answers = answers; self.queued = queued; requests = [] }
            NetworkSession.testStreamLinesRead = 0
        }
        var hosts: [String] { lock.withLock { requests.map { $0.url?.host ?? "" } } }
    }

    static func run() async {
        defer { finish() }
        memoryChecks()
        replyGuardChecks()
        settingsChecks()

        check("0 seam dormant before install", !NetworkSession.testTransportIsActive)
        let wire = Wire()
        NetworkSession.testTransport = { request in
            var body = try wire.answer(request)
            var status = 200
            if body.hasPrefix("STATUS "), let code = Int(body.dropFirst(7).prefix(3)) {
                status = code
                body = String(body.dropFirst(11))
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
        OCRCascade.keyOverride = { "test-\($0.rawValue)" }
        OCRRefusalFallback.routesOverride = { [] }
        defer {
            NetworkSession.testTransport = nil; OCRCascade.keyOverride = nil; OCRRefusalFallback.routesOverride = nil
        }
        guard NetworkSession.testTransportIsActive else {
            check("0 the injected transport is active", false, "stopping before any request")
            return
        }
        guard let image = makeImage() else { check("0 test image", false); return }
        defer { try? FileManager.default.removeItem(at: image.deletingLastPathComponent()) }

        let local = GatewayConfig(baseURL: "http://local-mac.invalid:1234/v1", modelID: "qwen/qwen3-vl-8b",
                                  displayName: "Qwen3-VL 8B, 4-bit (this Mac)", inputCostPer1M: 0, outputCostPer1M: 0,
                                  localModel: true, localEscalates: true)
        var stayLocal = local
        stayLocal.localEscalates = nil
        let remote = GatewayConfig(baseURL: "https://remote-gateway.invalid/v1", modelID: "gw", displayName: "GW",
                                   inputCostPer1M: 1, outputCostPer1M: 1)
        func reply(_ content: String, finish: String = "stop") -> String {
            let data = try! JSONSerialization.data(withJSONObject: [
                "choices": [["finish_reason": finish, "message": ["content": content]]]])
            return String(data: data, encoding: .utf8)!
        }
        let claudeText = #"{"content":[{"type":"text","text":"[document_start]\nCLAUDE-TEXT"}],"stop_reason":"end_turn"}"#

        // 2. The request on the wire.
        wire.reset(["local-mac": reply("[document_start]\nHello archive")])
        let read = try? await OpenAICompatibleClient.gateway(local).ocr(imageURL: image)
        eq("2 a local reply is read", read?.text, "Hello archive")
        if let request = wire.requests.first, let body = jsonBody(request) {
            eq("2 local: max_tokens is the local cap", body["max_tokens"] as? Int, LocalModelRoute.maxTokens)
            eq("2 local: temperature 0", body["temperature"] as? Int, 0)
            eq("2 local: the stand-in key, none saved", request.value(forHTTPHeaderField: "Authorization"), "Bearer local")
            eq("2 local: the long timeout", request.timeoutInterval, LocalModelRoute.requestTimeout)
            eq("2 local: chat completions on the server", request.url?.path, "/v1/chat/completions")
        } else { check("2 local request sent", false) }
        wire.reset(["remote-gateway": reply("[document_start]\nHello archive")])
        _ = try? await OpenAICompatibleClient.gateway(remote).ocr(imageURL: image)
        if let request = wire.requests.first, let body = jsonBody(request) {
            check("2 remote gateway unchanged: 8192 tokens, no temperature, 120 s, no key",
                  body["max_tokens"] as? Int == 8192 && body["temperature"] == nil && request.timeoutInterval == 120
                  && request.value(forHTTPHeaderField: "Authorization") == "Bearer ")
        } else { check("2 remote request sent", false) }
        wire.reset(["local-mac": reply("<think>Let me look.</think>\nletter")])
        let text = try? await OpenAICompatibleClient.gateway(local).textCompletion(prompt: "classify", maxTokens: 64)
        eq("2 local text call: reasoning stripped", text, "letter")
        if let request = wire.requests.first, let body = jsonBody(request) {
            check("2 local text call: its own budget, temperature 0",
                  body["max_tokens"] as? Int == 64 && body["temperature"] as? Int == 0)
        }

        // 3. Looped and odd replies.
        let loop = "[document_start]\nDear Sir,\n" + String(repeating: "the committee met again on Tuesday. ", count: 120)
        wire.reset(["local-mac": reply(loop)])
        var r = try? await OpenAICompatibleClient.gateway(local).ocr(imageURL: image)
        check("3 a looped reply that stopped by itself fails as length",
              r?.text == nil && r?.errorCode == OCRFailureCode.cutOff && r?.errorMessage?.contains("repeated") == true,
              "\(String(describing: r?.errorCode)) \(String(describing: r?.text?.prefix(40)))")
        wire.reset(["remote-gateway": reply(loop)])
        r = try? await OpenAICompatibleClient.gateway(remote).ocr(imageURL: image)
        check("3 a remote gateway's reply is not loop-checked", r?.text != nil)
        wire.reset(["local-mac": reply("[document_start]\nloop loop", finish: "length")])
        r = try? await OpenAICompatibleClient.gateway(local).ocr(imageURL: image)
        eq("3 a reply cut at the cap fails as length", r?.errorCode, OCRFailureCode.cutOff)
        wire.reset(["local-mac": reply("<think>Hmm.</think>\n[document_start]\nThinking aside")])
        r = try? await OpenAICompatibleClient.gateway(local).ocr(imageURL: image)
        eq("3 an OCR reply's reasoning is stripped", r?.text, "Thinking aside")
        wire.reset(["local-mac": reply("KIND: memorandum\nTEXT: Kept anyway")])
        r = try? await OpenAICompatibleClient.gateway(local).ocr(imageURL: image)
        check("3 a header outside the format keeps the text", r?.text?.contains("Kept anyway") == true,
              String(describing: r?.text))
        wire.reset(["local-mac": reply("<think>I cannot read this page.</think>")])
        r = try? await OpenAICompatibleClient.gateway(local).ocr(imageURL: image)
        eq("3 a reply that is all reasoning is unparsable", r?.errorCode, OCRFailureCode.unparsable)
        wire.reset([:])
        wire.timesOut = true
        r = try? await OpenAICompatibleClient.gateway(local).ocr(imageURL: image)
        check("3 a local request that times out fails as length, once", r?.errorCode == OCRFailureCode.cutOff
              && wire.requests.count == 1, "\(String(describing: r?.errorCode)) \(wire.requests.count)")
        wire.reset([:])
        let remoteTimeout = try? await OpenAICompatibleClient.gateway(remote).ocr(imageURL: image)
        check("3 a remote gateway's timeout still throws", remoteTimeout == nil)
        wire.timesOut = false

        // 4. The fallback.
        let toClaude = OCRCascade(routeID: OCRCascade.routeID(for: LLMModel.anthropicModels[0]))
        func ocr(_ gateway: GatewayConfig, _ cascade: OCRCascade) async -> OCRResult {
            await OCRProcessor.performOCRCall(
                imageURL: image, provider: .gemini, model: gateway.asLLMModel(), thinkingLevel: nil,
                apiKey: gateway.apiKey, previousText: nil, previousImageURL: nil, gatewayConfig: gateway,
                rotationMode: .off, standardImageMB: 4, cascade: cascade)
        }
        wire.reset(["local-mac": reply(loop), "anthropic": claudeText])
        var p = await ocr(local, toClaude)
        check("4 a local model's looped page is escalated and Claude's text kept",
              p.text?.contains("CLAUDE-TEXT") == true && wire.hosts.contains { $0.contains("anthropic") },
              "\(String(describing: p.errorMessage)) \(wire.hosts)")
        check("4 the record names the local model as the first reader",
              p.secondReader?.firstReader == local.displayName && p.secondReader?.trigger == .failure
              && p.secondReader?.firstCode == OCRFailureCode.cutOff, String(describing: p.secondReader))
        wire.reset(["local-mac": reply(loop), "anthropic": claudeText])
        p = await ocr(stayLocal, toClaude)
        check("4 without the user's leave, a local page never goes to the cloud",
              p.errorCode == OCRFailureCode.cutOff && !wire.hosts.contains { $0.contains("anthropic") }, "\(wire.hosts)")
        wire.reset(["local-mac": reply(loop), "anthropic": claudeText])
        p = await ocr(local, .off)
        check("4 cascade off: the looped page fails, with no call beyond its second reading",
              p.text == nil && p.errorCode == OCRFailureCode.cutOff && wire.hosts == ["local-mac.invalid", "local-mac.invalid"],
              "\(wire.hosts)")
        wire.reset(["local-mac": reply("[document_start]\nfine page"), "anthropic": claudeText])
        p = await ocr(local, toClaude)
        check("4 a page the local model reads is not escalated", p.text == "fine page" && wire.hosts.count == 1)
        wire.reset(["remote-gateway": reply("x", finish: "length"), "anthropic": claudeText])
        p = await ocr(remote, toClaude)
        check("4 a remote gateway's cut page still never escalates",
              p.errorCode == OCRFailureCode.cutOff && !wire.hosts.contains { $0.contains("anthropic") })

        // 5. Scheduling and the estimate.
        eq("5 a local gateway reads one page at a time", OCRProcessor.schedulingWorkerCount(for: nil, gateway: local), 1)
        check("5 a remote gateway keeps the worker count",
              OCRProcessor.schedulingWorkerCount(for: nil, gateway: remote) == OCRProcessor.schedulingWorkerCount(for: nil))
        let t = TimeEstimator.estimate(fileCount: 10, model: local.asLLMModel(), enableTagging: false,
                                       useGateway: true, ocrWorkers: 8,
                                       localSecondsPerPage: LocalModelRoute.secondsPerPage(modelID: local.modelID))
        check("5 the estimate reads ten pages at 41 s, one at a time", t.totalSeconds >= 410, "\(t.totalSeconds)")
        let cost = CostEstimator.estimate(fileCount: 10, model: local.asLLMModel(), enableTagging: true,
                                          sendPreviousImage: false, contextCharCount: 0, useGateway: true)
        eq("5 a local run costs nothing", cost.totalStandard, 0)

        await streamChecks(wire: wire, image: image, local: local, remote: remote, reply: reply)
    }

    /// A streamed reply as a server sends it: one `data:` event per piece, the finish on the last, then `[DONE]`.
    private static func events(_ pieces: [String], finish: String = "stop") -> String {
        var out = pieces.enumerated().map { i, piece in
            let choice: [String: Any] = ["index": 0, "delta": ["content": piece],
                                         "finish_reason": i == pieces.count - 1 ? finish : NSNull()]
            let data = try! JSONSerialization.data(withJSONObject: ["choices": [choice]])
            return "data: " + String(data: data, encoding: .utf8)! + "\n\n"
        }
        out.append("data: [DONE]\n\n")
        return out.joined()
    }

    private static func streamChecks(wire: Wire, image: URL, local: GatewayConfig, remote: GatewayConfig,
                                     reply: (String, String) -> String) async {
        let client = OpenAICompatibleClient.gateway(local)
        let good = events(["[document_start]\n", "Dear Sir,\n", "the committee ", "met on Tuesday."])
        wire.reset(["local-mac": good])
        var r = try? await client.ocr(imageURL: image)
        eq("6 a streamed reply is put together", r?.text, "Dear Sir,\nthe committee met on Tuesday.")
        check("6 a good page is read once", wire.requests.count == 1)
        if let body = wire.requests.first.flatMap(jsonBody) {
            check("6 local: stream on, no penalty on a first reading",
                  body["stream"] as? Bool == true && body["repetition_penalty"] == nil && body["repeat_penalty"] == nil)
        } else { check("6 local request sent", false) }
        wire.reset(["remote-gateway": reply("[document_start]\nok", "stop")])
        _ = try? await OpenAICompatibleClient.gateway(remote).ocr(imageURL: image)
        check("6 a remote gateway is not streamed", wire.requests.first.flatMap(jsonBody)?["stream"] == nil)

        // A runaway: 600 pieces of one sentence (about 22,000 characters, past the cap), then text that must not be read.
        let sentence = "the committee met again on Tuesday. "
        let runaway = events(["[document_start]\nDear Sir,\n"] + Array(repeating: sentence, count: 600) + ["LATE-TEXT"],
                             finish: "length")
        let total = runaway.split(separator: "\n").count
        wire.reset(["local-mac": runaway])
        r = try? await client.ocr(imageURL: image)
        let read = NetworkSession.testStreamLinesRead
        check("6 a streamed loop fails the page as length", r?.text == nil && r?.errorCode == OCRFailureCode.cutOff,
              String(describing: r?.errorMessage))
        // Two readings of the same runaway: each stopped by 2,000 + 250 characters of loop, about 63 lines of 602.
        check("6 the stream is closed once it loops, long before its end", read < total / 2, "read \(read) of 2 × \(total)")
        check("6 a looped page is read a second time", wire.requests.count == 2, "\(wire.requests.count)")
        if wire.requests.count == 2, let body = jsonBody(wire.requests[1]) {
            check("6 the second reading has the repetition penalty under both names, temperature still 0",
                  body["repetition_penalty"] as? Double == LocalModelRoute.retryRepetitionPenalty
                  && body["repeat_penalty"] as? Double == LocalModelRoute.retryRepetitionPenalty
                  && body["temperature"] as? Int == 0 && body["stream"] as? Bool == true)
        }
        check("6 the reason says it was read twice and why",
              r?.errorMessage?.contains("read twice: the first reply repeated itself") == true,
              String(describing: r?.errorMessage))

        wire.reset([:], queued: [runaway, good])
        r = try? await client.ocr(imageURL: image)
        eq("6 a second reading that answers is kept", r?.text, "Dear Sir,\nthe committee met on Tuesday.")
        check("6 and carries no failure", r?.errorCode == nil && r?.errorMessage == nil)

        let capped = events(["[document_start]\n", "A long newspaper page"], finish: "length")
        wire.reset(["local-mac": capped])
        r = try? await client.ocr(imageURL: image)
        check("6 a capped page is read twice and says so", wire.requests.count == 2 && r?.errorCode == OCRFailureCode.cutOff
              && r?.errorMessage?.contains("the first reply reached the 4096-token cap") == true,
              String(describing: r?.errorMessage))

        wire.reset([:])
        wire.timesOut = true
        r = try? await client.ocr(imageURL: image)
        check("6 a timed-out page is not read again", r?.errorCode == OCRFailureCode.cutOff && wire.requests.count == 1)
        wire.timesOut = false

        wire.reset(["local-mac": #"data: {"error":{"message":"model crashed"}}"# + "\n\n"])
        r = try? await client.ocr(imageURL: image)
        check("6 an error event fails the page, read once", r?.errorMessage == "model crashed" && r?.errorCode == "500"
              && wire.requests.count == 1, String(describing: r?.errorMessage))

        wire.reset(["local-mac": events(["<think>Let me look.</think>\n", "[document_start]\n", "Thinking aside"])])
        r = try? await client.ocr(imageURL: image)
        eq("6 a streamed reply's reasoning is stripped", r?.text, "Thinking aside")

        wire.reset([:], queued: [runaway, #"STATUS 422 {"detail":"unknown field repeat_penalty"}"#])
        r = try? await client.ocr(imageURL: image)
        check("6 a second reading the server refuses keeps the first reading's code, so the page still escalates",
              r?.errorCode == OCRFailureCode.cutOff && r?.errorMessage?.contains("read twice") == true,
              "\(String(describing: r?.errorCode)) \(String(describing: r?.errorMessage))")
        wire.reset([:], queued: [runaway, "THROW"])
        r = try? await client.ocr(imageURL: image)
        check("6 a second reading that cannot be made keeps the first failure",
              r?.errorCode == OCRFailureCode.cutOff && r?.errorMessage?.contains("a second reading could not be made") == true,
              String(describing: r?.errorMessage))

        let unfinished = events(["[document_start]\n", "Dear Sir,\n", "the commit"]).components(separatedBy: "data: [DONE]")[0]
            .replacingOccurrences(of: #""finish_reason":"stop""#, with: #""finish_reason":null"#)
        wire.reset(["local-mac": unfinished])
        r = try? await client.ocr(imageURL: image)
        check("6 a stream that ends with no finish and no [DONE] is not a transcription",
              r?.text == nil && r?.errorCode == OCRFailureCode.unparsable && wire.requests.count == 1,
              "\(String(describing: r?.text)) \(String(describing: r?.errorCode))")

        wire.reset(["local-mac": good.replacingOccurrences(of: "\n\n", with: "\r\n\r\n")])
        r = try? await client.ocr(imageURL: image)
        eq("6 a CRLF stream is read", r?.text, "Dear Sir,\nthe committee met on Tuesday.")

        // A loop in a separate reasoning field (LM Studio, Ollama) is stopped too.
        let thinking = (0..<600).map { _ -> String in
            let data = try! JSONSerialization.data(withJSONObject: ["choices": [["index": 0,
                "delta": ["reasoning_content": "wait, let me check the date again. "], "finish_reason": NSNull()]]])
            return "data: " + String(data: data, encoding: .utf8)! + "\n\n"
        }.joined() + "data: [DONE]\n\n"
        wire.reset(["local-mac": thinking])
        r = try? await client.ocr(imageURL: image)
        check("6 a loop in the reasoning field stops the stream", r?.errorCode == OCRFailureCode.cutOff
              && NetworkSession.testStreamLinesRead < 600, "\(NetworkSession.testStreamLinesRead)")

        // The rule fires only on a loop: a long, varied page streamed in small pieces is read whole.
        let prose = (1...300).map { "Line \($0) of the letter mentions item \($0 * 7 % 13). " }
        wire.reset(["local-mac": events(["[document_start]\n"] + prose)])
        r = try? await client.ocr(imageURL: image)
        check("6 a long streamed page is read whole", r?.text?.hasSuffix("item \(300 * 7 % 13).") == true
              && wire.requests.count == 1, String(describing: r?.errorMessage))
    }

    private static func memoryChecks() {
        func first(_ gb: Double) -> String? { LocalModelRoute.picks(memoryGB: gb).first?.id }
        check("1 under 16 GB: nothing offered", LocalModelRoute.picks(memoryGB: 8).isEmpty)
        eq("1 16 GB: Qwen3-VL 8B 4-bit", first(16), LocalModelRoute.qwen3VL8B4.id)
        eq("1 18 GB (ours): Qwen3-VL 8B 4-bit", first(18), LocalModelRoute.qwen3VL8B4.id)
        eq("1 32 GB: Qwen3.6 27B 4-bit", first(32), LocalModelRoute.qwen36_27B4.id)
        check("1 32 GB: 35B-A3B offered for speed",
              LocalModelRoute.picks(memoryGB: 32).contains(LocalModelRoute.qwen36_35BA3B4))
        eq("1 48 GB: Qwen3.6 27B 8-bit", first(48), LocalModelRoute.qwen36_27B8.id)
        check("1 64 GB: 27B 8-bit, then 35B-A3B 8-bit", LocalModelRoute.picks(memoryGB: 64).prefix(2)
              == [LocalModelRoute.qwen36_27B8, LocalModelRoute.qwen36_35BA3B8])
        check("1 every pick fits the memory it is offered at", [16.0, 18, 24, 32, 36, 48, 64, 128].allSatisfy { gb in
            LocalModelRoute.picks(memoryGB: gb).allSatisfy { $0.memoryGiB < gb * 0.9 } })
        check("1 the 16 GB note warns about room", LocalModelRoute.recommendationNote(memoryGB: 16).contains("little else"))
        check("1 the note below 16 GB points to Apple Vision", LocalModelRoute.recommendationNote(memoryGB: 8).contains("Apple Vision"))
        eq("1 the measured MLX build is the bench's", LocalModelRoute.qwen3VL8B4.modelID(for: .mlxVLM),
           "mlx-community/Qwen3-VL-8B-Instruct-4bit")
        eq("1 an unknown model is timed at the one measurement", LocalModelRoute.secondsPerPage(modelID: "x"), 41)
        check("1 Settings warns that whole newspaper pages pass the cap",
              LocalModelRoute.newspaperNote.contains("18 of 32") && LocalModelRoute.newspaperNote.contains("4096"))
    }

    private static func replyGuardChecks() {
        let loop = String(repeating: "and the meeting was adjourned. ", count: 100)
        check("3 a repeated sentence is a loop", LocalModelRoute.isRepetitionLoop("Minutes\n" + loop))
        check("3 a short repeat is not", !LocalModelRoute.isRepetitionLoop(String(repeating: "and so on. ", count: 20)))
        let form = String(repeating: "Name: ______________  Date: ________\n", count: 50)
        check("3 a form's blank rows (\(form.count) chars) are not a loop", !LocalModelRoute.isRepetitionLoop(form))
        check("3 dot leaders are not a loop", !LocalModelRoute.isRepetitionLoop("Contents " + String(repeating: ".", count: 3000)))
        check("3 empty table rows are not a loop",
              !LocalModelRoute.isRepetitionLoop(String(repeating: "|      |      |      |\n", count: 200)))
        let prose = (1...300).map { "Line \($0) of the letter mentions item \($0 * 7 % 13)." }.joined(separator: " ")
        check("3 an ordinary long page is not a loop", !LocalModelRoute.isRepetitionLoop(prose))
        check("3 a loop the reply recovered from is not flagged", !LocalModelRoute.isRepetitionLoop(loop + prose))
        eq("3 inline reasoning removed", LocalModelRoute.strippingReasoning("<think>a\nb</think>\n[document_start]\nX"),
           "[document_start]\nX")
        eq("3 a dangling close tag removed", LocalModelRoute.strippingReasoning("thinking…</think>Text"), "Text")
        eq("3 an unclosed block kept", LocalModelRoute.strippingReasoning("<think>Text"), "<think>Text")
        eq("3 the model list parsed", LocalModelRoute.parseModelList(Data(#"{"data":[{"id":"a"},{"id":"b"}]}"#.utf8)), ["a", "b"])
        check("3 loopback addresses", LocalModelRoute.isLoopback("http://127.0.0.1:1234/v1")
              && LocalModelRoute.isLoopback("http://localhost:11434/v1")
              && !LocalModelRoute.isLoopback("https://api.openai.com/v1"))
        check("3 check: listed model is ready", LocalModelRoute.checkSummary(models: ["a"], modelID: "a").contains("Ready"))
        check("3 check: an unlisted model names the list",
              LocalModelRoute.checkSummary(models: ["a", "b"], modelID: "c").contains("It lists: a, b"))
    }

    private static func settingsChecks() {
        guard let d = UserDefaults(suiteName: "LocalModelsTest-\(UUID().uuidString)") else { check("5 defaults", false); return }
        d.set(true, forKey: DefaultsKeys.useGateway)
        d.set("http://127.0.0.1:1234/v1", forKey: DefaultsKeys.gatewayBaseURL)
        d.set("qwen/qwen3-vl-8b", forKey: DefaultsKeys.gatewayModelID)
        check("5 a gateway without the flag is remote", GatewayConfig.fromDefaults(d)?.isLocalModel == false)
        eq("5 a remote gateway with no key has none", GatewayConfig.storedKey(d), "")
        d.set(true, forKey: DefaultsKeys.gatewayLocalModel)
        check("5 the flag makes it local", GatewayConfig.fromDefaults(d)?.isLocalModel == true)
        eq("5 a local model gets the stand-in key", GatewayConfig.storedKey(d), LocalModelRoute.placeholderKey)
        check("5 escalation stays off until allowed", GatewayConfig.fromDefaults(d)?.localEscalates == nil)
        d.set(true, forKey: DefaultsKeys.gatewayLocalEscalates)
        check("5 allowed, it is frozen into the config", GatewayConfig.fromDefaults(d)?.localEscalates == true)
        d.set(false, forKey: DefaultsKeys.gatewayLocalModel)
        check("5 the leave means nothing for a remote gateway", GatewayConfig.fromDefaults(d)?.localEscalates == nil)
        let legacy = #"{"baseURL":"u","modelID":"m","displayName":"d"}"#
        let decoded = try? JSONDecoder().decode(GatewayConfig.self, from: Data(legacy.utf8))
        check("5 a saved run without the field decodes as remote", decoded != nil && decoded?.isLocalModel == false)
    }

    private static func jsonBody(_ request: URLRequest) -> [String: Any]? {
        request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private static func makeImage() -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("localmodels-test-\(UUID().uuidString)")
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
        if let out = ProcessInfo.processInfo.environment["LOCALMODELS_TEST_OUT"] {
            try? text.write(toFile: out, atomically: true, encoding: .utf8)
        } else {
            print(text)
        }
    }
}
