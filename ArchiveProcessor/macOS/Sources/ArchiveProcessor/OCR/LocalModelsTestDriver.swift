#if DEBUG // W40.a5: a test driver/contract, compiled out of Release
import AppKit
import CoreText
import ImageIO
import Foundation
import ArchiveCore

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
///   7. (W41.app-local-models-fu2) Every local call, OCR and text, turns reasoning off under the servers' three
///      spellings; a text reply with no answer (cut, empty or all reasoning) throws; a remote gateway is unchanged.
///   8. (W47.ct-capture-gemma) A label's titles go to Gemma 3 12B only on a server on this Mac that lists it, the gateway's
///      own address first when it is a local model there; the request is `ct_read.py`'s (prompt, temperature 0, 640
///      tokens, the stand-in key); only its four fields are taken, and a remote gateway never asks for it.
///   9. (W47.ct-label-cost) A label's Luna call is counted at the gateway's own figure, else its tokens at Luna's price,
///      else the per-label estimate; a refused call costs nothing; the run's history adds it, its ledger share does not.
///  10. (W49.proc-local-model-supervisor, `S` lines) One app-managed model in memory at a time, a stage keeps its
///      model, keep-alive follows Live Capture, memory pressure and stopping unload: `LocalModelSupervisorContract`.
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
        /// Response headers for every answer (the gateway's cost header).
        var headers: [String: String]? = nil
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
            lock.withLock { self.answers = answers; self.queued = queued; requests = []; headers = nil }
            NetworkSession.testStreamLinesRead = 0
        }
        var hosts: [String] { lock.withLock { requests.map { $0.url?.host ?? "" } } }
    }

    static func run() async {
        defer { finish() }
        memoryChecks()
        for (name, ok, detail) in await LocalModelSupervisorContract.run() { check(name, ok, detail) }
        for (name, ok, detail) in await ManagedLocalOCRContract.run() { check(name, ok, detail) }
        if let path = ProcessInfo.processInfo.environment["LOCALMODELS_SCRATCH_OCR_ROOT"] {
            let store = ProcessInfo.processInfo.environment["LOCALMODELS_SCRATCH_OCR_STORE"].map { URL(fileURLWithPath: $0) }
            let rawModel = ProcessInfo.processInfo.environment["LOCALMODELS_SCRATCH_OCR_MODEL"]
            let selectedModel = ManagedOCRModel.allCases.first { $0.rawValue == rawModel || $0.shortID == rawModel } ?? .qwen3VL8B
            for (name, ok, detail) in await ManagedLocalOCRContract.realInstallAndRead(
                scratch: URL(fileURLWithPath: path, isDirectory: true), store: store, model: selectedModel) {
                if name.hasPrefix("NOTE") { lines.append(name) } else { check(name, ok, detail) }
            }
        }
        replyGuardChecks()
        settingsChecks()

        if let path = ProcessInfo.processInfo.environment["LOCALMODELS_SCRATCH_GEMMA_ROOT"] {
            let scratch = URL(fileURLWithPath: path, isDirectory: true)
            let photo = scratch.appending(path: "synthetic-label.jpg")
            if let jpeg = try? Data(contentsOf: photo), let answer = await LocalModelSupervisorContract.realRead(jpeg: jpeg, scratch: scratch) {
                let fields = ContainerLabelReader.localModelFields(fromReply: answer.text)
                check("W49 managed worker returns the expected fields through the app",
                      fields[.collectionTitle] == "Doe Papers" && fields[.date] == "1968", answer.text)
                // W49.proc-local-model-supervisor: the worker's lifetime peak, GPU memory included.
                let gb = Double(answer.peakBytes) / 1_073_741_824
                lines.append(String(format: "NOTE managed worker peak %.2f GB", gb))
                check("W49 managed worker peaks under the supervisor's 10 GB ceiling",
                      answer.peakBytes > 0 && gb < LocalModelSupervisor.memoryCeilingGB, "\(gb) GB")
            } else {
                check("W49 managed worker starts and answers through the app", false)
            }
        }

        check("0 seam dormant before install", !NetworkSession.testTransportIsActive)
        let wire = Wire()
        NetworkSession.testTransport = { request in
            var body = try wire.answer(request)
            var status = 200
            if body.hasPrefix("STATUS "), let code = Int(body.dropFirst(7).prefix(3)) {
                status = code
                body = String(body.dropFirst(11))
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: wire.lock.withLock { wire.headers })!
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
        var lightOnLocal = local
        lightOnLocal.modelID = ManagedOCRModel.lightOnOCR3_4B.rawValue
        wire.reset(["local-mac": reply("Plain LightOnOCR line")])
        let loRead = try? await OpenAICompatibleClient.gateway(lightOnLocal).ocr(imageURL: image)
        if let req = wire.requests.first, let body = jsonBody(req),
           let msgs = body["messages"] as? [[String: Any]],
           let parts = msgs.first?["content"] as? [[String: Any]],
           let textPart = parts.last?["text"] as? String {
            check("2 LightOnOCR-3 4B sends empty prompt and reads plain text",
                  textPart.isEmpty && loRead?.text == "Plain LightOnOCR line", "prompt='\(textPart)' text=\(String(describing: loRead?.text))")
        } else { check("2 LightOnOCR-3 4B request sent", false) }
        wire.reset(["remote-gateway": reply("[document_start]\nHello archive")])
        _ = try? await OpenAICompatibleClient.gateway(remote).ocr(imageURL: image)
        if let request = wire.requests.first, let body = jsonBody(request) {
            check("2 remote gateway unchanged: 8192 tokens, no temperature, 120 s, no key",
                  body["max_tokens"] as? Int == 8192 && body["temperature"] == nil && request.timeoutInterval == 120
                  && request.value(forHTTPHeaderField: "Authorization") == "Bearer ")
        } else { check("2 remote request sent", false) }
        // W40.fix-processor-gateway-url-doubled: a pasted full endpoint is not doubled on the wire.
        var pasted = remote
        pasted.baseURL = " https://remote-gateway.invalid/v1/chat/completions/ "
        wire.reset(["remote-gateway": reply("[document_start]\nHello archive")])
        _ = try? await OpenAICompatibleClient.gateway(pasted).ocr(imageURL: image)
        eq("2 a pasted full endpoint is called once, not doubled", wire.requests.first?.url?.absoluteString,
           "https://remote-gateway.invalid/v1/chat/completions")
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

        // 4b. (W47.wh-read-flag-readers) The page a local model read is checked against Vision's reading of it.
        let said = "The committee met on the fourth of March to consider the report."
        ReadQualityDisagreement.visionOverride = { _, _ in .text(said) }
        defer { ReadQualityDisagreement.visionOverride = nil }
        wire.reset(["local-mac": reply("[document_start]\n\(said)")])
        p = await ocr(stayLocal, .off)
        check("4 a local page that reads as Vision did is not flagged", p.text == said && p.readPoorly == nil,
              String(describing: p.readPoorly))
        wire.reset(["local-mac": reply("[document_start]\nZq xv wk jj pp")])
        p = await ocr(stayLocal, .off)
        check("4 one that does not is flagged, for its reader",
              p.readPoorly?.reader == ReadQualityDisagreement.qwenVL8Mac.reader && p.readPoorly?.disagreement ?? 0 > 0.9,
              String(describing: p.readPoorly))
        wire.reset(["remote-gateway": reply("[document_start]\nZq xv wk jj pp")])
        p = await ocr(remote, .off)
        check("4 a gateway model the bench has not read is not checked", p.text != nil && p.readPoorly == nil)
        ReadQualityDisagreement.visionOverride = nil

        // 5. Scheduling and the estimate.
        eq("5 a local gateway reads one page at a time", OCRProcessor.schedulingWorkerCount(for: nil, gateway: local), 1)
        check("5 a remote gateway keeps the worker count",
              OCRProcessor.schedulingWorkerCount(for: nil, gateway: remote) == OCRProcessor.schedulingWorkerCount(for: nil))
        let t = TimeEstimator.estimate(fileCount: 10, model: local.asLLMModel(), enableTagging: false,
                                       useGateway: true, ocrWorkers: 8,
                                       localSecondsPerPage: LocalModelRoute.secondsPerPage(modelID: local.modelID))
        let perPage = LocalModelRoute.secondsPerPage(modelID: local.modelID)
        eq("5 the LM Studio 8B is timed at its like-for-like seconds", perPage, 35.09)
        check("5 the estimate reads ten pages at the pick's \(perPage) s, one at a time", t.totalSeconds >= 10 * perPage,
              "\(t.totalSeconds)")
        let cost = CostEstimator.estimate(fileCount: 10, model: local.asLLMModel(), enableTagging: true,
                                          sendPreviousImage: false, contextCharCount: 0, useGateway: true)
        eq("5 a local run costs nothing", cost.totalStandard, 0)

        await streamChecks(wire: wire, image: image, local: local, remote: remote, reply: reply)
        await reasoningOffChecks(wire: wire, image: image, local: local, remote: remote, reply: reply)
        await gemmaLabelChecks(wire: wire, image: image, remote: remote, reply: reply)
    }

    /// Whether a request body turns reasoning off under all three spellings.
    /// 8. Gemma 3 12B for a label's titles (W47.ct-capture-gemma). The model lists come from the driver, never a server.
    private static func gemmaLabelChecks(wire: Wire, image: URL, remote: GatewayConfig,
                                         reply: (String, String) -> String) async {
        final class Asked: @unchecked Sendable {
            let lock = NSLock()
            var urls: [String] = []
            var lists: [String: [String]] = [:]
            func list(_ url: String) throws -> [String] {
                try lock.withLock {
                    urls.append(url)
                    guard let l = lists[url] else { throw URLError(.cannotConnectToHost) }
                    return l
                }
            }
            func reset(_ lists: [String: [String]]) { lock.withLock { self.lists = lists; urls = [] } }
            var asked: [String] { lock.withLock { urls } }
        }
        let asked = Asked()
        let saved = ContainerLabelGemma.listModels
        ContainerLabelGemma.listModels = { try asked.list($0) }
        defer { ContainerLabelGemma.listModels = saved }
        let mlx = LocalModelRoute.Server.mlxVLM.baseURL, ollama = LocalModelRoute.Server.ollama.baseURL
        let onMac = GatewayConfig(baseURL: "http://127.0.0.1:9999/v1/", modelID: "qwen", displayName: "Q",
                                  localModel: true)
        let offMac = GatewayConfig(baseURL: "http://local-mac.invalid:1234/v1", modelID: "qwen", displayName: "Q",
                                   localModel: true)
        eq("8 the local gateway's own address first, then the presets", ContainerLabelGemma.candidates(gateway: onMac),
           ["http://127.0.0.1:9999/v1"] + LocalModelRoute.Server.allCases.map(\.baseURL))
        eq("8 a local model off this Mac is not asked", ContainerLabelGemma.candidates(gateway: offMac),
           LocalModelRoute.Server.allCases.map(\.baseURL))
        eq("8 the measured build is picked first",
           ContainerLabelGemma.pick(from: ["gemma3:12b", "mlx-community/gemma-3-12b-it-4bit"]), "mlx-community/gemma-3-12b-it-4bit")
        eq("8 another Gemma 3 12B tag is taken", ContainerLabelGemma.pick(from: ["qwen3.5:9b", "gemma3:12b-it-qat"]),
           "gemma3:12b-it-qat")
        eq("8 no other model stands in", ContainerLabelGemma.pick(from: ["qwen3.5:9b", "gemma3:27b", "gemma-3-4b"]), nil)
        eq("8 never a cloud tag or a base model", ContainerLabelGemma.pick(from: ["gemma3:12b-cloud", "google/gemma-3-12b-pt"]), nil)
        eq("8 mlx-vlm's snapshot path is taken",
           ContainerLabelGemma.pick(from: ["/c/hub/models--mlx-community--gemma-3-12b-it-4bit/snapshots/abc"]),
           "/c/hub/models--mlx-community--gemma-3-12b-it-4bit/snapshots/abc")
        check("8 loopback means an address on this Mac, not a name starting 127.",
              LocalModelRoute.isLoopback("http://127.0.0.1:8080/v1") && LocalModelRoute.isLoopback("http://127.1.2.3/v1")
              && LocalModelRoute.isLoopback("http://localhost:1234/v1") && LocalModelRoute.isLoopback("http://[::1]:11434/v1")
              && !LocalModelRoute.isLoopback("http://127.example.com/v1") && !LocalModelRoute.isLoopback("http://127.0.0.1.nip.io/v1")
              && !LocalModelRoute.isLoopback("http://128.0.0.1/v1"))

        func read(_ gateway: GatewayConfig?) async -> ContainerFieldSet {
            await ContainerLabelGemma.forget()
            return await ContainerLabelCapture.read(type: .box, text: "BOX NO. 17", photo: image, rotation: 0,
                                                    gateway: gateway)
        }
        let answer = #"{"kind": "box label", "repository": "Hoover Institution Archives", "collection_title": "Glotzer Papers", "#
            + #""collection_number": "91006", "accession": "1991-006", "container": "Box 99", "box_title": "Speeches", "#
            + #""date": "1930-1990"}"#
        // No gateway: the second preset lists it, so the read goes there.
        asked.reset([mlx: ["qwen3.5:9b"], ollama: ["gemma3:12b"]])
        wire.reset(["127.0.0.1": reply(answer, "stop")])
        var set = await read(nil)
        eq("8 no gateway: the presets asked in turn until one lists it", asked.asked, [LocalModelRoute.Server.lmStudio.baseURL, ollama])
        eq("8 no gateway: titles from Gemma", set[.repository]?.value, "Hoover Institution Archives")
        eq("8 no gateway: its reader recorded", set[.collectionTitle]?.reader, "gemma-3-12b")
        eq("8 Gemma's date taken", set[.date]?.value, "1930-1990")
        check("8 Gemma's container, accession and box title not taken",
              set[.container]?.value != "Box 99" && set[.accession]?.value != "1991-006" && set[.boxTitle] == nil,
              "\(String(describing: set[.container]?.value)) \(String(describing: set[.accession]?.value))")
        if wire.requests.count == 1, let request = wire.requests.first, let body = jsonBody(request) {
            eq("8 the request goes to that server", request.url?.absoluteString, ollama + "/chat/completions")
            eq("8 request: the model it listed", body["model"] as? String, "gemma3:12b")
            eq("8 request: temperature 0", body["temperature"] as? Int, 0)
            eq("8 request: ct_read's 640-token cap", body["max_tokens"] as? Int, 640)
            eq("8 request: the stand-in key", request.value(forHTTPHeaderField: "Authorization"), "Bearer local")
            let content = ((body["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]) ?? []
            check("8 Ollama by default: the photo, then ct_read's prompt",
                  (content.first?["image_url"] as? [String: Any])?["url"].map { "\($0)".hasPrefix("data:image/jpeg;base64,") } == true
                  && content.last?["text"] as? String == ContainerLabelReader.localModelPrompt)
        } else { check("8 one Gemma request sent", false, "\(wire.requests.count) requests") }

        // A local model on this Mac: its own server is asked first and used when it lists Gemma.
        asked.reset(["http://127.0.0.1:9999/v1": ["qwen", "mlx-community/gemma-3-12b-it-4bit"]])
        wire.reset(["127.0.0.1": reply(answer, "stop")])
        set = await read(onMac)
        eq("8 local gateway: its own server asked first", asked.asked, ["http://127.0.0.1:9999/v1"])
        eq("8 local gateway: titles from Gemma there", set[.repository]?.reader, "gemma-3-12b")

        // W49.proc-gemma-request-adopt: mlx-vlm's server gets the revised request by default, through the same read,
        // on an upright JPEG copy of the photo, so the file's own bytes must reach the wire.
        let savedStyle = ContainerLabelGemma.styleOverride
        let uprightJPEG = image.deletingLastPathComponent().appendingPathComponent("gemma-upright-label.jpg")
        if let src = CGImageSourceCreateWithURL(image as CFURL, nil),
           let drawn = CGImageSourceCreateImageAtIndex(src, 0, nil),
           let dest = CGImageDestinationCreateWithURL(uprightJPEG as CFURL, "public.jpeg" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, drawn, nil)
            _ = CGImageDestinationFinalize(dest)
        }
        ContainerLabelGemma.styleOverride = nil
        asked.reset([mlx: ["mlx-community/gemma-3-12b-it-4bit"]])
        wire.reset(["127.0.0.1": reply(answer, "stop")])
        await ContainerLabelGemma.forget()
        set = await ContainerLabelCapture.read(type: .box, text: "BOX NO. 17", photo: uprightJPEG, rotation: 0, gateway: nil)
        ContainerLabelGemma.styleOverride = savedStyle
        let revisedContent = wire.requests.first.flatMap(jsonBody).flatMap {
            ($0["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]
        } ?? []
        let sentURL = (revisedContent.last?["image_url"] as? [String: Any])?["url"] as? String
        let fileBytes = try? Data(contentsOf: uprightJPEG)
        check("8 mlx-vlm by default: one request, prompt first, the upright JPEG file itself",
              wire.requests.count == 1 && revisedContent.first?["text"] as? String == ContainerLabelReader.localModelPrompt
              && fileBytes != nil && sentURL == "data:image/jpeg;base64," + (fileBytes?.base64EncodedString() ?? ""),
              "\(wire.requests.count) requests")
        eq("8 revised: titles from Gemma", set[.repository]?.reader, "gemma-3-12b")

        // Nothing lists it: no call, the parser's values.
        asked.reset([:])
        wire.reset([:])
        set = await read(nil)
        check("8 no server: no call, the parser's values",
              wire.requests.isEmpty && set[.repository]?.reader != "gemma-3-12b", "\(wire.requests.count) requests")
        // Remembered: a second label within the window asks no server again.
        _ = await ContainerLabelCapture.read(type: .box, text: "", photo: image, rotation: 0, gateway: nil)
        eq("8 the servers asked once for a run of labels", asked.asked.count, LocalModelRoute.Server.allCases.count)

        // A reply cut at the cap gives nothing.
        asked.reset([mlx: ["mlx-community/gemma-3-12b-it-4bit"]])
        wire.reset(["127.0.0.1": reply(#"{"repository": "Hoover Inst"#, "length")])
        set = await read(nil)
        check("8 a cut reply: the parser's values", set[.repository]?.reader != "gemma-3-12b")

        // A server whose call fails counts as none for the window: the next label makes no call.
        asked.reset([mlx: ["mlx-community/gemma-3-12b-it-4bit"]])
        wire.reset(["127.0.0.1": "STATUS 400 {\"error\": \"no vision\"}"])
        _ = await read(nil)
        let failedCalls = wire.requests.count
        _ = await ContainerLabelCapture.read(type: .box, text: "", photo: image, rotation: 0, gateway: nil)
        check("8 a failed server is not asked again within the window", failedCalls == 1 && wire.requests.count == 1,
              "\(failedCalls) then \(wire.requests.count)")

        // A remote gateway: Luna, and Gemma never asked.
        asked.reset([mlx: ["mlx-community/gemma-3-12b-it-4bit"]])
        wire.reset(["remote-gateway": reply(answer, "stop")])
        set = await read(remote)
        check("8 remote gateway: no local server asked, Luna read it",
              asked.asked.isEmpty && set[.repository]?.reader == ContainerLabelCapture.gatewayReader
              && wire.hosts == ["remote-gateway.invalid"], "\(asked.asked) \(wire.hosts)")
        await ContainerLabelGemma.forget()
        await labelCostChecks(wire: wire, image: image, remote: remote, answer: answer)
        await liveBatchedLabelChecks(wire: wire, image: image, local: onMac, remote: remote, answer: answer)
        await labelRotationChecks(in: image.deletingLastPathComponent())
    }

    /// A scratch label with both camera orientation and a separate clockwise correction from the run.
    private static func labelRotationChecks(in directory: URL) async {
        let photo = directory.appendingPathComponent("box-label.jpg")
        let width = 800
        let height = 500
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            check("10 create label context", false)
            return
        }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 42, nil)
        func draw(_ line: String, at point: CGPoint) {
            let text = NSAttributedString(string: line, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ])
            context.textPosition = point
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
        draw("BOX", at: CGPoint(x: 50, y: 385))
        draw("17", at: CGPoint(x: 275, y: 385))
        draw("FOLDER", at: CGPoint(x: 470, y: 255))
        draw("99", at: CGPoint(x: 50, y: 95))

        guard let upright = context.makeImage() else { check("10 render label", false); return }
        let cases: [(storedTurn: Int, correction: Int)] = [(180, 90), (90, 180), (0, 270), (270, 0)]
        for (storedTurn, correction) in cases {
            guard let stored = ImageEncoding.rotate(upright, byDegreesClockwise: storedTurn),
                  let dest = CGImageDestinationCreateWithURL(photo as CFURL, "public.jpeg" as CFString, 1, nil) else {
                check("10 create label photo", false)
                return
            }
            // The camera always requests another 90° clockwise. EXIF + storedTurn + correction makes 360°.
            CGImageDestinationAddImage(dest, stored, [
                kCGImagePropertyOrientation: CGImagePropertyOrientation.right.rawValue,
            ] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { check("10 save label", false); return }

            let result = await ContainerLabelCapture.readLabel(type: .box, text: "BOX NO. 99", photo: photo,
                                                               rotation: correction, gateway: nil, useModel: false)
            let box = result.fields[.container]
            // Vision may read the same words from a turned image, but the layout can change their order.
            check("10 label correction \(correction)° follows EXIF",
                  result.visionText == "BOX\n17\nFOLDER\n99"
                  && result.visionAnswered && box?.value == "Box 17" && box?.reader == ContainerLabelReader.visionReader,
                  "Vision read ‘\(result.visionText)’, box field \(String(describing: box))")
        }

        let unreadable = directory.appendingPathComponent("missing-label.jpg")
        let fallback = await ContainerLabelCapture.readLabel(type: .box, text: "BOX NO. 99", photo: unreadable,
                                                             rotation: 90, gateway: nil, useModel: false)
        check("10 unreadable photo uses the run's text", !fallback.visionAnswered
              && fallback.fields[.container]?.value == "Box 99"
              && fallback.fields[.container]?.reader == ContainerLabelCapture.ocrTextReader)
        check("10 intentional Vision-only reading is not a model fallback", fallback.fallback == nil)
        let noModel = await ContainerLabelCapture.readLabel(type: .box, text: "BOX NO. 99", photo: unreadable,
                                                            rotation: 90, gateway: nil)
        check("10 a missing photo with saved OCR text discloses the text fallback", noModel.fallback == .ocrText)
        let noText = await ContainerLabelCapture.readLabel(type: .box, text: "", photo: unreadable,
                                                           rotation: 90, gateway: nil)
        check("10 a missing photo with no text discloses an unread label", noText.fallback == .unread)
        revisedRequestChecks(upright: upright, turnedPhoto: photo, in: directory)
    }

    /// 11. W49.proc-gemma-request-verify: the revised request sends the prompt first, and the photo file itself only
    /// when it is already the upright JPEG the encoder would draw.
    private static func revisedRequestChecks(upright: CGImage, turnedPhoto: URL, in directory: URL) {
        let saved = ContainerLabelGemma.styleOverride
        defer { ContainerLabelGemma.styleOverride = saved }
        ContainerLabelGemma.styleOverride = .revised
        let server = ContainerLabelGemma.Server(baseURL: "http://127.0.0.1:8080/v1", modelID: "gemma3:12b")
        // W49.proc-gemma-request-adopt (owner, 2026-11-24): revised by default on mlx-vlm only.
        func at(_ baseURL: String) -> ContainerLabelGemma.Server { .init(baseURL: baseURL, modelID: "gemma3:12b") }
        eq("11 default: mlx-vlm's server gets the revised request", ContainerLabelGemma.defaultStyle(for: server), .revised)
        eq("11 default: Ollama keeps the current request",
           ContainerLabelGemma.defaultStyle(for: at(LocalModelRoute.Server.ollama.baseURL)), .current)
        eq("11 default: LM Studio keeps the current request",
           ContainerLabelGemma.defaultStyle(for: at(LocalModelRoute.Server.lmStudio.baseURL)), .current)
        eq("11 default: a local gateway's own address keeps the current request",
           ContainerLabelGemma.defaultStyle(for: at("http://127.0.0.1:9999/v1")), .current)
        ContainerLabelGemma.styleOverride = .current
        eq("11 the override sets mlx-vlm's request too", ContainerLabelGemma.style(for: server), .current)
        ContainerLabelGemma.styleOverride = .revised
        eq("11 the override sets Ollama's request too",
           ContainerLabelGemma.style(for: at(LocalModelRoute.Server.ollama.baseURL)), .revised)
        func order(_ style: ContainerLabelGemma.RequestStyle) -> [String] {
            guard let request = ContainerLabelGemma.request(jpeg: Data([1, 2]), server: server, style: style),
                  let body = jsonBody(request),
                  let content = (body["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]
            else { return [] }
            return content.compactMap { $0["type"] as? String }
        }
        eq("11 current request: photo, then prompt", order(.current), ["image_url", "text"])
        eq("11 revised request: prompt, then photo", order(.revised), ["text", "image_url"])

        func save(_ image: CGImage, as name: String, type: String = "public.jpeg") -> URL? {
            let url = directory.appendingPathComponent(name)
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            return CGImageDestinationFinalize(dest) ? url : nil
        }
        guard let plain = save(upright, as: "upright-label.jpg"),
              let png = save(upright, as: "upright-label.png", type: "public.png"),
              let turned = ImageEncoding.rotate(upright, byDegreesClockwise: 270),
              let turnedPlain = save(turned, as: "turned-label.jpg") else {
            check("11 save scratch label photos", false)
            return
        }
        let source = try? Data(contentsOf: plain)
        let long = ContainerLabelGemma.imageLongSide
        eq("11 an upright JPEG within the cap is sent as the file itself",
           ContainerLabelGemma.image(photo: plain, rotation: 0, style: .revised), source)
        eq("11 the current request re-encodes it",
           ContainerLabelGemma.image(photo: plain, rotation: 0, style: .current),
           ImageEncoding.uprightJPEG(url: plain, rotationDegrees: 0, longEdge: long))
        check("11 a full turn counts as none",
              ImageEncoding.sourceJPEGIfUpright(url: plain, rotationDegrees: 360, longEdge: long) == source)
        check("11 a photo over the cap is scaled, not sent as is",
              ImageEncoding.sourceJPEGIfUpright(url: plain, rotationDegrees: 0, longEdge: 400) == nil)
        check("11 a PNG is encoded, not sent as is",
              ImageEncoding.sourceJPEGIfUpright(url: png, rotationDegrees: 0, longEdge: long) == nil)
        check("11 an EXIF turn is drawn, not sent as is",
              ImageEncoding.sourceJPEGIfUpright(url: turnedPhoto, rotationDegrees: 0, longEdge: long) == nil)
        // A correction from the run: the revised request turns the pixels exactly as the current one does.
        let sent = ContainerLabelGemma.image(photo: turnedPlain, rotation: 90, style: .revised)
        check("11 a correction from the run is drawn upright, as the current request draws it",
              sent != nil && sent != (try? Data(contentsOf: turnedPlain))
              && sent == ImageEncoding.uprightJPEG(url: turnedPlain, rotationDegrees: 90, longEdge: long))
        if let sent, let src = CGImageSourceCreateWithData(sent as CFData, nil),
           let drawn = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            eq("11 the drawn photo has the upright shape", [drawn.width, drawn.height], [upright.width, upright.height])
        } else { check("11 decode the drawn photo", false) }
    }

    /// 9. W47.ct-label-cost: what a label's gateway call is counted at, and where it goes.
    private static func labelCostChecks(wire: Wire, image: URL, remote: GatewayConfig, answer: String) async {
        func read(_ body: String, headers: [String: String]? = nil, throwing: Bool = false, useModel: Bool = true)
            async -> (called: Bool, dollars: Double, reader: String?) {
            wire.reset(["remote-gateway": body], queued: throwing ? ["THROW", "THROW", "THROW", "THROW"] : [])
            wire.lock.withLock { wire.headers = headers }
            let r = await ContainerLabelCapture.readLabel(type: .box, text: "BOX NO. 17", photo: image, rotation: 0,
                                                          gateway: remote, useModel: useModel)
            return (r.gatewayCalled, r.dollars, r.fields[.repository]?.reader)
        }
        func usage(_ p: Int, _ c: Int, total: Int? = nil) -> String {
            var u: [String: Any] = ["prompt_tokens": p, "completion_tokens": c]
            if let total { u["total_tokens"] = total }
            let data = try! JSONSerialization.data(withJSONObject: [
                "choices": [["finish_reason": "stop", "message": ["content": answer]]], "usage": u])
            return String(data: data, encoding: .utf8)!
        }
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-12 }

        var r = await read(usage(2109, 320), headers: ["x-litellm-response-cost": "0.00042"])
        check("9 the gateway's own figure counts", r.called && near(r.dollars, 0.00042)
              && r.reader == ContainerLabelCapture.gatewayReader, "\(r)")
        r = await read(usage(2109, 320))
        check("9 no figure: the tokens at Luna's price", near(r.dollars, (2109 * 0.20 + 320 * 1.20) / 1_000_000), "\(r)")
        r = await read(usage(1000, 100, total: 1500))
        check("9 thinking outside completion_tokens is counted", near(r.dollars, (1000 * 0.20 + 500 * 1.20) / 1_000_000),
              "\(r)")
        r = await read(usage(1000, 100), headers: ["x-litellm-response-cost": "0.0"])
        check("9 a figure of 0 (a model LiteLLM has no price for) falls back to the tokens",
              near(r.dollars, (1000 * 0.20 + 100 * 1.20) / 1_000_000), "\(r)")
        r = await read(usage(1000, 100), headers: ["x-litellm-response-cost": "junk"])
        check("9 an unreadable figure falls back to the tokens", near(r.dollars, (1000 * 0.20 + 100 * 1.20) / 1_000_000),
              "\(r)")
        let bare = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": answer]]]])
        r = await read(String(data: bare, encoding: .utf8)!)
        check("9 no figure and no usage: the per-label estimate",
              r.called && near(r.dollars, ContainerLabelCapture.gatewayDollarsPerLabel), "\(r)")
        r = await read("STATUS 500 {\"error\": \"down\"}")
        check("9 a refused call costs nothing but is a call",
              r.called && r.dollars == 0 && r.reader != ContainerLabelCapture.gatewayReader, "\(r)")
        r = await read("STATUS 500 {}", headers: ["x-litellm-response-cost": "0.0001"])
        check("9 a refused call the gateway still charges counts its figure", near(r.dollars, 0.0001), "\(r)")
        r = await read("{}", throwing: true)
        check("9 no response: the per-label estimate, the safe side",
              r.called && near(r.dollars, ContainerLabelCapture.gatewayDollarsPerLabel), "\(r)")
        r = await read(usage(1, 1), useModel: false)
        check("9 Vision and parser alone: no call, nothing counted", !r.called && r.dollars == 0 && wire.requests.isEmpty)

        // The run's cost: history and ledger add the label calls.
        var snapshot = RunHistorySnapshot(
            startedAt: Date(), provider: .gemini, gatewayConfig: nil, localAgent: nil, imageTokenProvider: nil,
            model: LLMProvider.gemini.models[0], visionTextProvider: nil, visionTextModel: nil, batchMode: false,
            enableTagging: false, enableCollectionSegmentation: false, preOCRedInput: false, reOCRMultiPagePDF: false,
            mixedReOCR: false, sendPreviousImage: false, contextCharCount: 0, imageScale: 1, rotationMode: .off,
            fileCount: 3)
        let plain = snapshot.makeRun(succeeded: 3)
        snapshot.labelCalls = 2
        snapshot.labelDollars = 0.0016
        let withLabels = snapshot.makeRun(succeeded: 3)
        check("9 the history's cost adds the label calls", near(withLabels.cost, plain.cost + 0.0016)
              && withLabels.labelReads == 2 && plain.labelReads == nil, "\(plain.cost) \(withLabels.cost)")
        check("9 the run's own ledger share leaves them out: they have a line of their own",
              snapshot.spentSoFar(readSources: []) == 0)
        let decoded = try? JSONDecoder().decode(ProcessingRun.self, from: JSONEncoder().encode(withLabels))
        eq("9 the history keeps the count", decoded?.labelReads, 2)

        // What the operator reads.
        eq("9 the summary with all reads usable", ContainerLabelCapture.spendNote(calls: 2, successfulReads: 2, dollars: 0.0016),
           "2 box or folder labels read through the gateway (GPT 5.6 Luna), $0.0016.")
        eq("9 the summary with outcomes unknown", ContainerLabelCapture.spendNote(calls: 2, dollars: 0.0016),
           "Tried to read 2 box or folder labels through the gateway (GPT 5.6 Luna), $0.0016.")
        eq("9 no call, no summary line", ContainerLabelCapture.spendNote(calls: 0, dollars: 0), nil)
        check("9 the estimate names the price a photo",
              ContainerLabelCapture.estimateNote(gateway: remote, preOCRedInput: false, enabled: true)?
                .contains("$0.00084 a photo") == true)
        var onMac = remote
        onMac.localModel = true
        check("9 no estimate line without a remote gateway, for pre-OCRed input, or with labels off",
              ContainerLabelCapture.estimateNote(gateway: nil, preOCRedInput: false, enabled: true) == nil
              && ContainerLabelCapture.estimateNote(gateway: onMac, preOCRedInput: false, enabled: true) == nil
              && ContainerLabelCapture.estimateNote(gateway: remote, preOCRedInput: true, enabled: true) == nil
              && ContainerLabelCapture.estimateNote(gateway: remote, preOCRedInput: false, enabled: false) == nil)
    }

    private static func asksNoReasoning(_ body: [String: Any]?) -> Bool {
        body?["enable_thinking"] as? Bool == false && body?["think"] as? Bool == false
            && (body?["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == false
            && body?["reasoning_effort"] == nil
    }

    private static func reasoningOffChecks(wire: Wire, image: URL, local: GatewayConfig, remote: GatewayConfig,
                                           reply: (String, String) -> String) async {
        let client = OpenAICompatibleClient.gateway(local)
        wire.reset(["local-mac": events(["[document_start]\n", "Hello"])])
        _ = try? await client.ocr(imageURL: image)
        check("7 a local OCR call turns reasoning off (all three spellings, no reasoning_effort)",
              asksNoReasoning(wire.requests.first.flatMap(jsonBody)))
        let runaway = events(["[document_start]\n"] + Array(repeating: "the committee met again on Tuesday. ", count: 600),
                             finish: "length")
        wire.reset(["local-mac": runaway])
        _ = try? await client.ocr(imageURL: image)
        check("7 the second reading keeps reasoning off", wire.requests.count == 2
              && asksNoReasoning(wire.requests.last.flatMap(jsonBody)))
        wire.reset(["local-mac": reply(#"{"year":"1952"}"#, "stop")])
        let tags = try? await client.textCompletion(prompt: "tags")
        eq("7 a local text call's answer is returned", tags, #"{"year":"1952"}"#)
        check("7 a local text call turns reasoning off", asksNoReasoning(wire.requests.first.flatMap(jsonBody)))
        wire.reset(["remote-gateway": reply("[document_start]\nok", "stop")])
        _ = try? await OpenAICompatibleClient.gateway(remote).ocr(imageURL: image)
        _ = try? await OpenAICompatibleClient.gateway(remote).textCompletion(prompt: "tags")
        check("7 a remote gateway's requests carry no reasoning switch", wire.requests.count == 2
              && wire.requests.allSatisfy { r in
                  let b = jsonBody(r)
                  return b?["enable_thinking"] == nil && b?["think"] == nil && b?["chat_template_kwargs"] == nil
              })

        // The FarmShare failure: every reply spent the 512 tokens thinking. None is read as tags.
        func textFails(_ name: String, _ body: String) async {
            wire.reset(["local-mac": body])
            do {
                let got = try await client.textCompletion(prompt: "tags")
                check(name, false, "returned \(got.prefix(60))")
            } catch {
                check(name, "\(error)".contains("no answer"), "\(error)")
            }
        }
        await textFails("7 a text reply cut while thinking fails", reply("<think>The year might be 1952, or", "length"))
        await textFails("7 a text reply cut after an answer began fails", reply(#"{"year":"19"#, "length"))
        await textFails("7 a text reply that is an unclosed think block fails", reply("<think>I am not sure.", "stop"))
        await textFails("7 a text reply that is only a closed think block fails", reply("<think>Hmm.</think>\n", "stop"))
        await textFails("7 an empty text reply fails", reply("", "stop"))
        let nullContent = try! JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "length",
            "message": ["content": NSNull(), "reasoning_content": "Let me think about the date."]]]])
        await textFails("7 a text reply with its reasoning in a field and no content fails",
                        String(data: nullContent, encoding: .utf8)!)
        await textFails("7 a text reply that ends in an unclosed think block fails",
                        reply(#"{"year":"1952"}"# + "\n<think>But maybe", "stop"))
        wire.reset(["local-mac": reply("The year is 1952, I think.</think>\n" + #"{"year":"1952"}"#, "stop")])
        let opened = try? await client.textCompletion(prompt: "tags")
        eq("7 a text reply whose block the template opened keeps the answer", opened, #"{"year":"1952"}"#)
        wire.reset(["local-mac": #"STATUS 422 {"detail":"unknown field think"}"#])
        do {
            _ = try await client.textCompletion(prompt: "tags")
            check("7 a local server's refusal of a text call throws", false)
        } catch {
            check("7 a local server's refusal of a text call says why", "\(error)".contains("unknown field think"), "\(error)")
        }
        wire.reset(["remote-gateway": reply("", "stop")])
        let remoteEmpty = try? await OpenAICompatibleClient.gateway(remote).textCompletion(prompt: "tags")
        eq("7 a remote gateway's empty text reply is unchanged", remoteEmpty, "")

        wire.reset(["local-mac": events(["<think>", "The page shows a letter dated"])])
        var r = try? await client.ocr(imageURL: image)
        check("7 an OCR reply that is an unclosed think block is unparsable, not the page's text",
              r?.text == nil && r?.errorCode == OCRFailureCode.unparsable,
              "\(String(describing: r?.text)) \(String(describing: r?.errorCode))")
        wire.reset(["local-mac": events(["[document_start]\n", "Dear Sir,\n", "<think>Is that a 7 or a 1?"])])
        r = try? await client.ocr(imageURL: image)
        check("7 an OCR reply that ends in an unclosed think block is unparsable",
              r?.text == nil && r?.errorCode == OCRFailureCode.unparsable, String(describing: r?.text))
        wire.reset(["local-mac": reply("<think>The page shows", "stop")])
        r = try? await client.ocr(imageURL: image)
        check("7 an unstreamed OCR reply (stream ignored) that is all thinking is unparsable",
              r?.text == nil && r?.errorCode == OCRFailureCode.unparsable, String(describing: r?.text))
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
        // W43.app-guide-refresh / W49.proc-kind-split-mac-fu: the rule table's laptop picks at every size (owner call 7.6:
        // no 27B-class reader measured on a Mac, so 32 and 64 GB pick from the 16 GB rows).
        for gb in [16.0, 18, 32, 48, 64, 128] {
            eq("1 \(Int(gb)) GB: Qwen3.5 9B 4-bit, Qwen3-VL 8B 4-bit, LightOnOCR-3 4B 8-bit",
               LocalModelRoute.picks(memoryGB: gb).map(\.id),
               [LocalModelRoute.qwen35_9B4.id, LocalModelRoute.qwen3VL8B4.id, LocalModelRoute.lightOnOCR3_4B8.id])
        }
        let reading = SettingsRouteTable.bundled?.stage("reading")?.routes ?? []
        func row(_ id: String) -> SettingsRouteTable.Route? { reading.first { $0.id == id } }
        check("1 the picks are the rule table's Mac rows", row("qwen3.5-9b-mlx4")?.family == .mac
              && row("qwen3-vl-8b-mlx4")?.family == .mac && row("lightonocr-3-4b-mlx8")?.family == .mac)
        check("1 every pick fits the memory it is offered at", [16.0, 18, 24, 32, 36, 48, 64, 128].allSatisfy { gb in
            LocalModelRoute.picks(memoryGB: gb).allSatisfy { $0.memoryGiB < gb * 0.9 } })
        check("1 the 16 GB note warns about room", LocalModelRoute.recommendationNote(memoryGB: 16).contains("little else"))
        check("1 the note below 16 GB points to Apple Vision", LocalModelRoute.recommendationNote(memoryGB: 8).contains("Apple Vision"))
        eq("1 the measured MLX build is the bench's", LocalModelRoute.qwen3VL8B4.modelID(for: .mlxVLM),
           "mlx-community/Qwen3-VL-8B-Instruct-4bit")
        eq("1 the 9B's measured MLX build", LocalModelRoute.qwen35_9B4.modelID(for: .mlxVLM), "mlx-community/Qwen3.5-9B-4bit")
        eq("1 LightOnOCR-3 4B's measured MLX build", LocalModelRoute.lightOnOCR3_4B8.modelID(for: .mlxVLM),
           "prithivMLmods/LightOnOCR-3-4B-MLX/8bit")
        check("1 pick(forModelID:) resolves managed and server model IDs",
              LocalModelRoute.pick(forModelID: "qwen/qwen3-vl-8b") == LocalModelRoute.qwen3VL8B4
              && LocalModelRoute.pick(forModelID: "lightonocr-3:4b") == LocalModelRoute.lightOnOCR3_4B8
              && LocalModelRoute.pick(forModelID: "unknown-model") == nil)
        eq("1 an unknown model is timed at the 8B's like-for-like figure", LocalModelRoute.secondsPerPage(modelID: "x"), 35.09)
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
        // W40.fix-processor-gateway-url-doubled: what the field wants, from what was typed or pasted.
        for (typed, want) in [("https://aiapi-prod.stanford.edu/v1/chat/completions", "https://aiapi-prod.stanford.edu/v1"),
                              ("https://aiapi-prod.stanford.edu/v1/chat/completions/", "https://aiapi-prod.stanford.edu/v1"),
                              ("  https://api.openai.com/v1/Chat/Completions\n", "https://api.openai.com/v1"),
                              ("https://api.openai.com/v1/", "https://api.openai.com/v1"),
                              ("https://api.openai.com/v1", "https://api.openai.com/v1"),
                              ("https://example.invalid/chat/completions/v1", "https://example.invalid/chat/completions/v1"),
                              ("", "")] {
            eq("5 normalized base URL of \(typed.debugDescription)", GatewayConfig.normalizedBaseURL(typed), want)
        }
        d.set("https://aiapi-prod.stanford.edu/v1/chat/completions", forKey: DefaultsKeys.gatewayBaseURL)
        eq("5 a saved full endpoint reads as the base", GatewayConfig.fromDefaults(d)?.baseURL,
           "https://aiapi-prod.stanford.edu/v1")
        d.set("/chat/completions", forKey: DefaultsKeys.gatewayBaseURL)
        check("5 a URL that is only the endpoint path counts as not configured", GatewayConfig.fromDefaults(d) == nil)
        let legacy = #"{"baseURL":"u","modelID":"m","displayName":"d"}"#
        let decoded = try? JSONDecoder().decode(GatewayConfig.self, from: Data(legacy.utf8))
        check("5 a saved run without the field decodes as remote", decoded != nil && decoded?.isLocalModel == false)
    }

    /// 12. W49.proc-gemma-external-switch (owner, 2026-11-26): Live Capture with a local page-OCR model
    ///     batches box/folder Gemma label reads to Finish (one switch per batch), gives instant Vision + parser
    ///     proposals during capture, preserves user edits, and keeps Vision + parser fallback if Gemma fails.
    private static func liveBatchedLabelChecks(wire: Wire, image: URL, local: GatewayConfig,
                                               remote: GatewayConfig, answer: String) async {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("APLocalBatchLabels-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        let staging = tmp.appendingPathComponent("staging", isDirectory: true)
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)

        func makeCfg(provider: LLMProvider, gateway: GatewayConfig?) -> SessionProcessingConfig {
            SessionProcessingConfig(
                provider: provider, model: provider.models[0], thinkingLevel: .low, apiKey: "",
                taggingMode: .none, rotationMode: .off, mergeDocuments: false, outputDirectory: tmp,
                customOCRPrompt: "", imageScale: 1.0, standardImageMB: 2.0, ocrWorkerCount: 1,
                enableSegmentJSON: false, tagVocabulary: [], gateway: gateway, outputImageFile: false,
                pdfImageMB: 2.0, exportedImageMB: 2.0, textColumns: 1,
                localAgent: nil, visionTextLLM: nil, keepPreservationCopies: false)
        }
        let managedLocal = GatewayConfig(baseURL: ManagedOCRModel.baseURL, modelID: ManagedOCRModel.qwen3VL8B.rawValue,
                                         displayName: "Qwen3-VL 8B", localModel: true,
                                         managedModel: ManagedOCRModel.qwen3VL8B.rawValue)
        check("12 batchesLabelsToFinish is true for external local server and app-managed local OCR",
              makeCfg(provider: .gemini, gateway: local).batchesLabelsToFinish
                && makeCfg(provider: .gemini, gateway: managedLocal).batchesLabelsToFinish)
        check("12 batchesLabelsToFinish is false for remote gateway and Apple Vision",
              !makeCfg(provider: .gemini, gateway: remote).batchesLabelsToFinish
                && !makeCfg(provider: .appleVision, gateway: nil).batchesLabelsToFinish
                && !makeCfg(provider: .appleVision, gateway: local).batchesLabelsToFinish)

        let savedList = ContainerLabelGemma.listModels
        ContainerLabelGemma.listModels = { _ in [ContainerLabelGemma.ids[.mlxVLM]!] }
        await ContainerLabelGemma.forget()
        defer {
            ContainerLabelGemma.listModels = savedList
            LiveCaptureProcessor._recoveryTestOCRStub = nil
        }

        let gemmaOK = try! JSONSerialization.data(withJSONObject: [
            "choices": [["finish_reason": "stop", "message": ["content": answer]]]
        ])
        let gemmaOKString = String(data: gemmaOK, encoding: .utf8)!
        wire.reset([ContainerLabelGemma.ids[.mlxVLM]!: gemmaOKString])

        let session = CaptureSession()
        session._recoveryTestBeginLive(config: makeCfg(provider: .gemini, gateway: local), stagingDir: staging)
        session.liveProcessor._testFinalizeTasks = []
        LiveCaptureProcessor._recoveryTestOCRStub = OCRResult(text: "BOX NO. 17\nHOOVER", classification: nil,
                                                              errorMessage: nil, errorCode: nil)
        let imgData = (try? Data(contentsOf: image)) ?? Data()
        _ = session.ingest(jpeg: imgData, groupId: "B1", seq: 1, type: .box, quality: nil, year: nil, month: nil, deviceName: "TestPhone")
        _ = session.ingest(jpeg: imgData, groupId: "F1", seq: 2, type: .folder, quality: nil, year: nil, month: nil, deviceName: "TestPhone")
        await session.liveProcessor._testAwaitFinalizes()

        check("12 during capture: 0 Gemma requests made; both markers queued for Finish",
              wire.requests.isEmpty && session.liveProcessor.deferredGemmaLabelGroups == ["B1", "F1"],
              "requests=\(wire.requests.count) deferred=\(session.liveProcessor.deferredGemmaLabelGroups)")
        check("12 during capture: Vision/parser proposals still populate before Finish",
              session.containerFields["B1"]?[.container]?.value == "Box 17",
              "\(String(describing: session.containerFields["B1"]))")

        // User edits container number on B1 during capture; Finish batch must preserve that `.user` value while
        // adding Gemma's repository/collectionTitle. F1 gets a Gemma failure and must keep its parser fallback.
        var b1User = session.containerFields["B1"] ?? ContainerFieldSet()
        b1User[.container] = ContainerValue("Box 99", source: .user)
        _ = session.applyContainerFields(groupId: "B1", fields: b1User)
        var f1Before = session.containerFields["F1"] ?? ContainerFieldSet()
        f1Before[.folder] = ContainerValue("Folder 4", source: .label, reader: ContainerLabelReader.visionReader)
        session.setContainerRead(groupId: "F1", read: f1Before, fallback: nil)

        wire.reset([ContainerLabelGemma.ids[.mlxVLM]!: gemmaOKString],
                   queued: [gemmaOKString, "STATUS 500 {\"error\": \"down\"}"])
        await session.liveProcessor.runDeferredGemmaLabelBatch()

        check("12 Finish batch calls Gemma for each deferred marker and clears the queue",
              wire.requests.count >= 2 && session.liveProcessor.deferredGemmaLabelGroups.isEmpty,
              "requests=\(wire.requests.count) deferred=\(session.liveProcessor.deferredGemmaLabelGroups)")
        check("12 Finish batch merges Gemma proposals on B1 while preserving the user's edit",
              session.containerFields["B1"]?[.container]?.value == "Box 99"
                && session.containerFields["B1"]?[.container]?.source == .user
                && session.containerFields["B1"]?[.repository]?.reader == ContainerLabelReader.localModelReader,
              "\(String(describing: session.containerFields["B1"]))")
        check("12 when Gemma fails on F1, existing Vision/parser fallback proposals stay intact",
              session.containerFields["F1"]?[.folder]?.value == "Folder 4",
              "\(String(describing: session.containerFields["F1"]))")
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

#endif
