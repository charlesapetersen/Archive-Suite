import Foundation

// MARK: - Window transports (W36.seg-opt-engine)
//
// How a window reaches its voter's model. Each sends exactly what the bench sent: one request per window, the
// page images labelled "Page n:" in order, then the voter's prompt (Gemini: `method_gemini.py` `request_body`;
// Claude by API: `options.py` `tokens_claude`, the request the cost figure was counted on; Claude by plan:
// `method_window.py` `call_claude`). The engine owns parsing and the retry; a transport only sends, returns
// the reply text, and maps a usage or rate limit to `WindowTransportError.usageLimit`.

extension PageInput {
    /// A page for the windows: the image at the approach's long edge (the bench's 1,600 px), and its OCR text.
    static func load(imageURL: URL, text: String, longEdge: Int) -> PageInput? {
        guard let jpeg = ImageEncoding.loadImageAsJPEG(url: imageURL, maxDimension: longEdge) else { return nil }
        return PageInput(jpeg: jpeg, text: text)
    }
}

/// API-key route: Anthropic Messages, Gemini generateContent, OpenAI chat completions. The keys are read by the
/// caller (the Keychain, as for OCR) and passed in; nothing here stores or logs one.
struct APIWindowTransport: WindowTransport {
    typealias HTTP = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    let keys: [WindowProvider: String]
    /// The HTTP seam. Production goes through `NetworkSession` (the global limiter, its back-off on 429/5xx
    /// and `Retry-After`); the engine test injects recorded responses.
    var http: HTTP = { try await NetworkSession.data(for: $0, policy: .nonIdempotent) }

    /// Room for the answer: about 450 output tokens a window were measured (options.json), so this is ample.
    static let maxOutputTokens = 4096
    static let timeout: TimeInterval = 300

    func send(_ r: WindowRequest) async throws -> String {
        guard let key = keys[r.voter.provider], !key.isEmpty else {
            throw WindowTransportError.fatal("no API key for \(r.voter.provider.rawValue)")
        }
        let request = try Self.request(r, key: key)
        let (data, response) = try await http(request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw WindowTransportError.failed("no HTTP response")
        }
        return try Self.replyText(r.voter.provider, data: data, status: status, response: response as? HTTPURLResponse)
    }

    // MARK: Requests

    static func request(_ r: WindowRequest, key: String) throws -> URLRequest {
        let url: URL
        var headers: [String: String] = ["Content-Type": "application/json"]
        let body: [String: Any]
        switch r.voter.provider {
        case .anthropic:
            url = URL(string: "https://api.anthropic.com/v1/messages")!
            headers["x-api-key"] = key
            headers["anthropic-version"] = "2023-06-01"
            var content: [[String: Any]] = []
            for (n, img) in zip(r.pageNumbers, r.images) {
                content.append(["type": "text", "text": "Page \(n):"])
                content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg",
                                                            "data": img.base64EncodedString()]])
            }
            content.append(["type": "text", "text": r.prompt])
            body = ["model": r.voter.modelID, "max_tokens": maxOutputTokens,
                    "messages": [["role": "user", "content": content]]]
        case .gemini:
            url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(r.voter.modelID):generateContent")!
            headers["x-goog-api-key"] = key
            var parts: [[String: Any]] = []
            for (n, img) in zip(r.pageNumbers, r.images) {
                parts.append(["text": "Page \(n):"])
                parts.append(["inlineData": ["mimeType": "image/jpeg", "data": img.base64EncodedString()]])
            }
            parts.append(["text": r.prompt])
            var config: [String: Any] = ["temperature": 0, "responseMimeType": "application/json",
                                         "responseSchema": geminiResponseSchema]
            if let t = r.voter.thinkingLevel { config["thinkingConfig"] = ["thinkingLevel": t] }
            body = ["contents": [["role": "user", "parts": parts]], "generationConfig": config]
        case .openai:
            url = URL(string: "\(OpenAICompatibleClient.openAIBaseURL)/chat/completions")!
            headers["Authorization"] = "Bearer \(key)"
            var content: [[String: Any]] = []
            for (n, img) in zip(r.pageNumbers, r.images) {
                content.append(["type": "text", "text": "Page \(n):"])
                content.append(["type": "image_url",
                                "image_url": ["url": "data:image/jpeg;base64,\(img.base64EncodedString())"]])
            }
            content.append(["type": "text", "text": r.prompt])
            var o: [String: Any] = ["model": r.voter.modelID, "max_completion_tokens": maxOutputTokens,
                                    "messages": [["role": "user", "content": content]]]
            // The bench ran its ChatGPT voter at Codex's `model_reasoning_effort`; the same level here, or the
            // shipped figures would not describe this request.
            if let t = r.voter.thinkingLevel { o["reasoning_effort"] = t }
            body = o
        case .openrouter:
            // `method_openrouter.py` `request_body` for a CHEAP model: the images alone in page order (no "Page n:"
            // lines; the c1 prompt names the pages), then the prompt; temperature 0; reasoning at the voter's level,
            // excluded from the reply; the provider pinned, fallbacks off, at the price the cost figure used.
            guard let route = OpenRouterRoute.forModel(r.voter.modelID) else {
                throw WindowTransportError.fatal("\(r.voter.modelID) has no pinned OpenRouter provider")
            }
            url = URL(string: "\(OpenAICompatibleClient.openRouterBaseURL)/chat/completions")!
            headers["Authorization"] = "Bearer \(key)"
            var content: [[String: Any]] = r.images.map {
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\($0.base64EncodedString())"]]
            }
            content.append(["type": "text", "text": r.prompt])
            var o: [String: Any] = ["model": route.model.id, "max_tokens": maxOutputTokens, "temperature": 0,
                                    "messages": [["role": "user", "content": content]],
                                    "provider": OpenAICompatibleClient.openRouterProviderField(route)]
            if let t = r.voter.thinkingLevel { o["reasoning"] = ["effort": t, "exclude": true] }
            body = o
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// `method_gemini.py` `RESPONSE_SCHEMA`, verbatim.
    static var geminiResponseSchema: [String: Any] { [
        "type": "OBJECT",
        "properties": [
            "pages": ["type": "ARRAY", "items": [
                "type": "OBJECT",
                "properties": ["page": ["type": "INTEGER"],
                               "kind": ["type": "STRING", "enum": ["box", "folder", "document"]]],
                "required": ["page", "kind"]]],
            "boundaries": ["type": "ARRAY", "items": [
                "type": "OBJECT",
                "properties": ["between": ["type": "ARRAY", "items": ["type": "INTEGER"]],
                               "decision": ["type": "STRING", "enum": ["new", "continue"]],
                               "cue": ["type": "STRING"],
                               "confidence": ["type": "NUMBER"]],
                "required": ["between", "decision", "cue", "confidence"]]],
        ],
        "required": ["pages", "boundaries"],
    ] }

    // MARK: Replies

    static func replyText(_ provider: WindowProvider, data: Data, status: Int,
                          response: HTTPURLResponse? = nil) throws -> String {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if status != 200 {
            let err = json?["error"] as? [String: Any]
            var message = (err?["message"] as? String) ?? transientStatusMessage(status) ?? "HTTP \(status)"
            // OpenRouter wraps the provider's own words in metadata.raw ("Provider returned error" says nothing).
            if provider == .openrouter, let raw = (err?["metadata"] as? [String: Any])?["raw"] as? String {
                message += ": " + String(raw.prefix(300))
            }
            let kind = ((err?["type"] as? String) ?? (err?["status"] as? String) ?? (err?["code"] as? String) ?? "")
            // NetworkSession has already retried a 429 with back-off; one still standing is the account's
            // quota or rate limit, so the run stops rather than burning through every window.
            if status == 429 || kind == "rate_limit_error" || kind == "RESOURCE_EXHAUSTED" || kind == "insufficient_quota" {
                let reset = response.flatMap(retryAfter).map { Date().addingTimeInterval($0) }
                throw WindowTransportError.usageLimit(reset: reset, message: message)
            }
            // OpenRouter relays an upstream provider's passing failure as a 400 "Provider returned error" (seen on
            // z-ai in the W41.app-openrouter proof, then fine on the next run): that is this window's failure, retried
            // once, not a bad request.
            if provider == .openrouter, status == 400, (err?["message"] as? String) == "Provider returned error" {
                throw WindowTransportError.failed("openrouter 400: \(message)")
            }
            // A refused key, a bad request or an unknown model fails every window alike (the bench's Fatal).
            if [400, 401, 403, 404].contains(status) {
                throw WindowTransportError.fatal("\(provider.rawValue) \(status): \(message)")
            }
            throw WindowTransportError.failed("\(provider.rawValue) \(status): \(message)")
        }
        guard let json else { throw WindowTransportError.failed("\(provider.rawValue): malformed response") }
        let text: String
        switch provider {
        case .anthropic:
            text = (json["content"] as? [[String: Any]] ?? [])
                .filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        case .gemini:
            // method_gemini.py response_text: the non-thought text of the first candidate, STOP only.
            if let reason = (json["promptFeedback"] as? [String: Any])?["blockReason"] as? String {
                throw WindowTransportError.failed("gemini: prompt blocked: \(reason)")
            }
            guard let c = (json["candidates"] as? [[String: Any]])?.first else {
                throw WindowTransportError.failed("gemini: no candidates")
            }
            if let reason = c["finishReason"] as? String, reason != "STOP" {
                throw WindowTransportError.failed("gemini: finishReason \(reason)")
            }
            text = ((c["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? [])
                .filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
        case .openai:
            text = (((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String) ?? ""
        case .openrouter:
            // A provider's failure comes back as a 200 with an `error` object; it is one window's failure.
            if let err = json["error"] as? [String: Any] {
                let message = (err["message"] as? String) ?? "provider error"
                let code = (err["code"] as? Int) ?? Int((err["code"] as? String) ?? "")
                // As for an HTTP status: a rate limit stops the run, a refused key or no credit fails every window.
                if code == 429 { throw WindowTransportError.usageLimit(reset: nil, message: message) }
                if let code, [401, 402, 403].contains(code) {
                    throw WindowTransportError.fatal("openrouter \(code): \(message)")
                }
                throw WindowTransportError.failed("openrouter: \(message)")
            }
            text = (((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String) ?? ""
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WindowTransportError.failed("\(provider.rawValue): empty answer")
        }
        return text
    }

    private static func retryAfter(_ r: HTTPURLResponse) -> Double? {
        r.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }
}

/// Claude-plan route: the user's own installed `claude`, run as the bench ran it (`method_window.py`
/// `call_claude`): the window's pages written as `page-NNNN.jpg` into a fresh temp dir that is the process's
/// working directory, prompt w1 (here on stdin), the Read tool only, no session kept. The output is
/// `--output-format stream-json --verbose` (W36.seg-opt-subscription), whose `rate_limit_event` carries the
/// account's meter; the final `result` event is the envelope `json` printed. The app never reads the CLI's login.
struct LocalAgentWindowTransport: WindowTransport {
    let binaryPath: String
    /// Per window: the bench allowed 900 s for seven Read turns and the answer.
    var timeout: TimeInterval = 900
    /// The run's meter and its two pauses (`PlanRunGate`); nil sends without them.
    var gate: PlanRunGate? = nil

    /// Inherited from a shell that launched the app, these would make `claude -p` bill an API key, not the plan the
    /// user chose this route for (and the meter would then read as unreadable).
    static let apiCredentialVariables = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"]

    static func arguments(model: String) -> [String] {
        ["-p", "--model", model, "--output-format", "stream-json", "--verbose", "--allowedTools", "Read",
         "--permission-mode", "default", "--no-session-persistence"]
    }

    func send(_ r: WindowRequest) async throws -> String {
        try await gate?.beforeCall()
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("APSegWindow-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        for (n, img) in zip(r.pageNumbers, r.images) {
            try img.write(to: dir.appendingPathComponent(WindowPromptRenderer.fileName(n)))
        }
        let run = await LocalAgentClient.runAsync(binaryPath: binaryPath, args: Self.arguments(model: r.voter.modelID),
                                                  stdinText: r.prompt, timeout: timeout, currentDirectory: dir,
                                                  unsetEnvironment: Self.apiCredentialVariables)
        if run.cancelled { throw CancellationError() }
        let stream = ClaudeStreamOutput.parse(run.stdout)
        let result = Result { try Self.classify(run, stream: stream, now: Date()) }
        if let gate {
            // A call counts toward the pages measured only if its answer parses; a retry covers the same pages.
            let answered = (try? result.get()).flatMap { try? WindowAnswerParser.parse($0, pageNumbers: r.pageNumbers) } != nil
            await gate.record(meter: stream.meter, notionalUSD: stream.notionalUSD ?? 0, answered: answered,
                              voter: r.voter.name)
        }
        return try result.get()
    }

    /// `call_claude`'s classification: the envelope's `result` on success; a limit anywhere in the output stops
    /// the run with the reset time the CLI printed, when it printed one.
    static func classify(_ run: LocalAgentClient.CLIRun, now: Date) throws -> String {
        try classify(run, stream: ClaudeStreamOutput.parse(run.stdout), now: now)
    }

    static func classify(_ run: LocalAgentClient.CLIRun, stream: ClaudeStreamOutput, now: Date) throws -> String {
        if run.cancelled { throw CancellationError() }
        if run.spawnFailed { throw WindowTransportError.fatal("could not launch claude") }
        if run.timedOut || run.exitCode == -2 { throw WindowTransportError.failed("claude timed out") }
        let envelope = stream.envelope
        if let envelope, envelope["is_error"] as? Bool != true, envelope["subtype"] as? String == "success",
           let result = envelope["result"] as? String {
            return result
        }
        // As call_claude: when the envelope parsed, only its result says why; otherwise all the output does.
        let message = (envelope?["result"] as? String) ?? (run.stdout + run.stderr)
        if message.range(of: #"not logged in|please log in|/login|invalid api key|authenticat"#,
                         options: [.regularExpression, .caseInsensitive]) != nil {
            throw WindowTransportError.fatal("claude is not signed in: \(String(message.suffix(300)))")
        }
        if isUsageLimit(message) {
            throw WindowTransportError.usageLimit(
                reset: LocalAgentClient.parseUsageWindowReset(fromStderr: message, now: now),
                message: String(message.suffix(600)))
        }
        throw WindowTransportError.failed("claude exit \(run.exitCode): \(String(message.suffix(300)))")
    }

    static func isUsageLimit(_ s: String) -> Bool {
        s.range(of: #"usage limit|session limit|hit your limit|rate limit|\b429\b|limit reached"#,
                options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// Routes each window to the transport for its voter's provider: the mix sends Claude windows one way and
/// Gemini windows another.
struct RoutingWindowTransport: WindowTransport {
    let routes: [WindowProvider: any WindowTransport]

    func send(_ r: WindowRequest) async throws -> String {
        guard let t = routes[r.voter.provider] else {
            throw WindowTransportError.failed("no route to \(r.voter.provider.rawValue)")
        }
        return try await t.send(r)
    }
}
