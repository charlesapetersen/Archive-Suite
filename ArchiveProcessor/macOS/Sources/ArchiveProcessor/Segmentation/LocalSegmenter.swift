import Foundation

// MARK: - The corpus-trained 2B on this Mac (W41.app-local-seg)

/// The `local` approach's model: Qwen3.5 2B fine-tuned on the owner's corpus (W41.seg-finetune), at 8 bits through
/// mlx-vlm on this Mac (W41.seg-mac-model, `segbench-results/seg-students.md` §On the Mac). No key and no money; it
/// runs where the local OCR route's models do (`LocalModelRoute`), on the same kind of server.
///
/// What the bench says, and so what the chooser says: on the development boxes the 8-bit build put 90.3% of pages in
/// the exact document unchecked (Gemini 3.8 Flash 90.7%), 18 s a seven-page window and a 4.4 GB peak on an 18 GB
/// M3 Pro; on the locked test boxes (full precision) 78.8% against Gemini's 88.8%. Its confidences make no useful
/// flag, so the review asks about most gaps: a first draft the user skims. It was trained on one owner's archives.
enum LocalSegmenter {
    /// The voter's model id in `WindowVoter.catalog` and options.json: the build, not where it is downloaded from.
    static let buildID = "seg-qwen3.5-2b-8bit"
    /// mlx-vlm's address, as the local OCR route's preset has it.
    static let defaultBaseURL = LocalModelRoute.Server.mlxVLM.baseURL
    /// The repository mlx-vlm downloads the build from on its first request (about 2.5 GB). The owner approved
    /// publishing the weights on 2026-10-17; until the repository exists, a user points this at a local copy.
    static let defaultModelID = "charlesapetersen/archive-suite-seg-qwen3.5-2b-8bit"

    /// The bench's token budget for a window (`method_local.MAX_TOKENS` 1,500, then twice that on its retry): the
    /// fine-tuned 2B wrote a mean of about 380 tokens a window on FarmShare. 3,000 holds the retry's budget at once.
    static let maxTokens = 3000
    /// A window took 18 s on the M3 Pro; ten minutes is room for a slow Mac, never a stopped server (below).
    static let timeout: TimeInterval = LocalModelRoute.requestTimeout
    /// The warm-up call loads the model before the first window, and on the first run mlx-vlm downloads it (about
    /// 2.5 GB) inside that call, sending nothing meanwhile: an hour is about 6 Mbit/s.
    static let warmUpTimeout: TimeInterval = 3600
    /// Windows that fail in a row before the run stops: the engine retries each window once, so this is two windows
    /// that failed twice. The run then says why instead of finishing with every gap flagged at confidence 0.
    static let maxFailuresInARow = 4

    /// The local route's own session. Not `NetworkSession.shared`: that one waits for connectivity, so a stopped or
    /// crashed server would hold each window to its timeout (and the engine's retry to another); here a refused
    /// connection fails at once and the run stops with how to start the server.
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.waitsForConnectivity = false
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = warmUpTimeout
        return URLSession(configuration: c)
    }()

    static func baseURL(_ defaults: UserDefaults = .standard) -> String {
        let s = (defaults.string(forKey: DefaultsKeys.localSegmenterBaseURL) ?? "").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? defaultBaseURL : s
    }

    static func modelID(_ defaults: UserDefaults = .standard) -> String {
        let s = (defaults.string(forKey: DefaultsKeys.localSegmenterModelID) ?? "").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? defaultModelID : s
    }

    /// How to start the server, for the chooser and for a run that finds none.
    static let startHint = "Start mlx-vlm on this Mac (pip install mlx-vlm, then mlx_vlm.server --port 8080); "
        + "it downloads the model, about 2.5 GB, on the first run."

    /// The chooser's lines for this Mac: what was measured, whether its memory is enough, and where the model learned.
    static func notes(memoryGB: Double, mac: SegmentationOptions.Mac?) -> [String] {
        var out: [String] = []
        if let mac {
            out.append("On this Mac, no key and no cost. Measured on an \(mac.measuredOn): about "
                       + "\(SegmentationRow.twoSignificant(mac.secondsPerPage)) s a page, "
                       + "\(SegmentationRow.twoSignificant(mac.peakMemoryGB)) GB of memory at its peak, a "
                       + "\(SegmentationRow.twoSignificant(mac.downloadGB)) GB download.")
        }
        out.append(memoryNote(memoryGB: memoryGB))
        out.append("Trained on one owner's archives: on boxes it never saw it was about ten points behind Gemini 3.8 "
                   + "Flash and further behind ChatGPT, and its doubts are no guide, so skim every boundary it proposes.")
        return out
    }

    /// Recommended where it fits with room for the rest of the Mac. An 8 GB Mac beside a 4.4 GB peak is unmeasured.
    static func memoryNote(memoryGB: Double) -> String {
        let gb = Int(memoryGB)
        if memoryGB < 12 {
            return "This Mac has \(gb) GB of memory. The model needs about 4.4 GB at its peak; how it runs beside the "
                + "app on an 8 GB Mac has not been measured."
        }
        if memoryGB < 32 { return "This Mac has \(gb) GB of memory: recommended here when you have no API key." }
        return "This Mac has \(gb) GB of memory, ample for it."
    }
}

// MARK: - Transport

/// The `local` voter's route: the chat-completions API of a server on this Mac (mlx-vlm), sent as the bench's local
/// route sent it (`method_openrouter.py` `request_body` for a FarmShare key, which the model was trained on): the
/// images alone in page order, then the prompt; temperature 0; thinking off. No key: the bearer is the local route's
/// placeholder.
///
/// Before the first window it asks whether a server answers (`probe`, five seconds) and then loads the model with a
/// one-token call (`warmUp`, which also covers the first run's download), so a missing server or a model that cannot
/// load stops the run with a reason instead of failing every window. A server that stops mid-run fails at once (its
/// own session does not wait for connectivity) and stops the run too, as do `maxFailuresInARow` failures in a row.
struct LocalWindowTransport: WindowTransport {
    let baseURL: String
    let modelID: String
    var http: APIWindowTransport.HTTP = { try await LocalSegmenter.session.data(for: $0) }
    var probe: @Sendable (String) async throws -> [String] = { try await LocalModelRoute.listModels(baseURL: $0) }
    private let state = LocalRunState()

    func send(_ r: WindowRequest) async throws -> String {
        let (baseURL, modelID, http, probe) = (self.baseURL, self.modelID, self.http, self.probe)
        try await state.prepareOnce {
            do { _ = try await probe(baseURL) } catch {
                throw WindowTransportError.fatal("No server answers at \(baseURL). \(LocalSegmenter.startHint)")
            }
            try await Self.warmUp(baseURL: baseURL, modelID: modelID, http: http)
        }
        do {
            let text = try await answer(r, http: http)
            await state.succeeded()
            return text
        } catch WindowTransportError.failed(let message) {
            if await state.failed() >= LocalSegmenter.maxFailuresInARow {
                throw WindowTransportError.fatal("The model on this Mac failed \(LocalSegmenter.maxFailuresInARow) "
                    + "windows in a row; the last: \(message)")
            }
            throw WindowTransportError.failed(message)
        }
    }

    private func answer(_ r: WindowRequest, http: APIWindowTransport.HTTP) async throws -> String {
        let (data, response) = try await Self.call(try Self.request(r, baseURL: baseURL, modelID: modelID),
                                                   baseURL: baseURL, http: http)
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw WindowTransportError.failed("no HTTP response")
        }
        return try Self.replyText(data: data, status: status)
    }

    /// Sends one request. A refused or dropped connection means the server is gone: the run stops (a timeout is this
    /// window's failure, since a slow window on a busy Mac is not a stopped server).
    static func call(_ request: URLRequest, baseURL: String, http: APIWindowTransport.HTTP) async throws
        -> (Data, URLResponse) {
        do { return try await http(request) } catch let e as URLError {
            switch e.code {
            case .timedOut: throw WindowTransportError.failed("the local model did not answer in time")
            case .cancelled: throw CancellationError()
            default:
                throw WindowTransportError.fatal("The server at \(baseURL) stopped answering (\(e.localizedDescription)). "
                    + LocalSegmenter.startHint)
            }
        }
    }

    /// Loads the model with a one-token text call, downloading it first if the server has not yet. A failure stops the
    /// run with the server's reason: most often the repository is not published or the Model setting is wrong.
    static func warmUp(baseURL: String, modelID: String, http: APIWindowTransport.HTTP) async throws {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(base)/chat/completions") else {
            throw WindowTransportError.fatal("Invalid server address: \(baseURL)")
        }
        var body: [String: Any] = ["model": modelID, "max_tokens": 1, "temperature": 0,
                                   "messages": [["role": "user", "content": "Reply OK."]]]
        LocalModelRoute.applyReasoningOff(&body)
        var request = URLRequest(url: url, timeoutInterval: LocalSegmenter.warmUpTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(LocalModelRoute.placeholderKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await call(request, baseURL: baseURL, http: http) } catch WindowTransportError.failed {
            throw WindowTransportError.fatal("The server did not load \(modelID) within an hour.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = (json?["error"] as? [String: Any])?["message"] as? String ?? json?["error"] as? String
                ?? json?["detail"] as? String ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw WindowTransportError.fatal("The server could not load \(modelID) (\(status)): \(message). Check the "
                + "Model setting: a Hugging Face repository the server can download, or a folder on this Mac.")
        }
    }

    static func request(_ r: WindowRequest, baseURL: String, modelID: String) throws -> URLRequest {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(base)/chat/completions") else {
            throw WindowTransportError.fatal("Invalid server address: \(baseURL)")
        }
        var content: [[String: Any]] = r.images.map {
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\($0.base64EncodedString())"]]
        }
        content.append(["type": "text", "text": r.prompt])
        var body: [String: Any] = ["model": modelID, "max_tokens": LocalSegmenter.maxTokens, "temperature": 0,
                                   "messages": [["role": "user", "content": content]]]
        LocalModelRoute.applyReasoningOff(&body)
        var request = URLRequest(url: url, timeoutInterval: LocalSegmenter.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(LocalModelRoute.placeholderKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// The answer, or why there is none. A refusal (an unknown model, a bad request) fails every window alike; a
    /// reply cut at its budget, empty or all reasoning is this window's failure, retried once by the engine.
    static func replyText(data: Data, status: Int) throws -> String {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if status != 200 {
            let err = json?["error"]
            let message = (err as? [String: Any])?["message"] as? String ?? err as? String
                ?? (json?["detail"] as? String) ?? "HTTP \(status)"
            if [400, 401, 403, 404, 422].contains(status) {
                throw WindowTransportError.fatal("the local server refused the request (\(status)): \(message)")
            }
            throw WindowTransportError.failed("local \(status): \(message)")
        }
        guard let choice = (json?["choices"] as? [[String: Any]])?.first else {
            throw WindowTransportError.failed("local: malformed response")
        }
        let message = choice["message"] as? [String: Any]
        guard let answer = LocalModelRoute.textAnswer(message?["content"] as? String,
                                                      finish: choice["finish_reason"] as? String) else {
            throw WindowTransportError.failed("local: \(LocalModelRoute.noTextAnswer)")
        }
        return answer
    }
}

/// One run's state: the server check and warm-up, made once (later windows reuse its outcome, a failure included),
/// and the failures in a row.
private actor LocalRunState {
    private var prepared: Result<Void, Error>?
    private var failuresInARow = 0

    func prepareOnce(_ prepare: @Sendable () async throws -> Void) async throws {
        if prepared == nil {
            do { try await prepare(); prepared = .success(()) } catch { prepared = .failure(error) }
        }
        try prepared?.get()
    }

    func succeeded() { failuresInARow = 0 }

    func failed() -> Int {
        failuresInARow += 1
        return failuresInARow
    }
}
