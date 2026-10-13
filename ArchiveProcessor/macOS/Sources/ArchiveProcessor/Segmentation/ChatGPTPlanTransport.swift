import Foundation

// MARK: - ChatGPT by the user's plan (W36.seg-opt-siwc)
//
// The ChatGPT voter's windows through Sign in with ChatGPT (`Net/ChatGPTAuth.swift`): the Responses API with the
// account's access token, `store: false` and `stream: true` as OpenAI requires for plan usage
// (https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference). The window is what the API
// route sends: each page image labelled "Page n:", then the voter's prompt, at the voter's reasoning level.
// There is no usage meter to read, so nothing here measures the plan; the chooser shows the token figure and its
// notional price instead, and a usage limit stops the run resumably with the "Manage usage" link.

/// Which way ChatGPT's windows are paid for when the user has both an OpenAI key and a signed-in ChatGPT account.
enum ChatGPTRoute: String, CaseIterable, Sendable {
    case apiKey
    case plan

    static func stored(_ defaults: UserDefaults = .standard) -> ChatGPTRoute {
        defaults.string(forKey: DefaultsKeys.segmentationChatGPTRoute).flatMap(ChatGPTRoute.init(rawValue:)) ?? .apiKey
    }
}

struct ChatGPTPlanWindowTransport: WindowTransport {
    let auth: ChatGPTAuth
    /// No retry inside the session: a plan usage limit is a 429 that must stop new requests at once, and the
    /// engine already retries a failed window once after a pause.
    var http: APIWindowTransport.HTTP = { try await NetworkSession.data(for: $0, policy: .nonIdempotent, maxRetries: 0) }

    static let responsesURL = URL(string: "https://api.openai.com/v1/responses")!
    static let timeout: TimeInterval = 300
    static let usageLimitMessage = "Your ChatGPT plan's usage limit is reached. Manage usage: \(ChatGPTAuth.manageUsageURL.absoluteString)"

    func send(_ r: WindowRequest) async throws -> String {
        var token = try await Self.mapAuth { try await auth.accessToken() }
        for attempt in 0..<2 {
            let (data, response) = try await http(try Self.request(r, token: token))
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            // An expired or revoked access token: refresh once and resend; a grant that is gone asks for sign-in.
            if status == 401, attempt == 0, Self.errorCode(data) != "subscription_sharing_invalid_user" {
                token = try await Self.mapAuth { try await auth.accessToken(afterRejecting: token) }
                continue
            }
            // Only a grant OpenAI says is gone clears the account; another 401 just after a good refresh may be
            // transient, and wiping a valid refresh token would force a needless sign-in.
            if Self.errorCode(data) == "subscription_sharing_invalid_user" { await auth.markSignInRequired() }
            return try Self.replyText(data: data, status: status, response: http)
        }
        throw WindowTransportError.failed("unreachable")
    }

    private static func mapAuth(_ body: () async throws -> String) async throws -> String {
        do { return try await body() } catch ChatGPTAuthError.signInRequired {
            throw WindowTransportError.fatal("ChatGPT is not signed in. Sign in with ChatGPT in Settings, Segmentation.")
        } catch let e as ChatGPTAuthError {
            throw WindowTransportError.failed(e.description)
        }
    }

    // MARK: Request

    static func request(_ r: WindowRequest, token: String) throws -> URLRequest {
        var content: [[String: Any]] = []
        for (n, img) in zip(r.pageNumbers, r.images) {
            content.append(["type": "input_text", "text": "Page \(n):"])
            content.append(["type": "input_image", "image_url": "data:image/jpeg;base64,\(img.base64EncodedString())"])
        }
        content.append(["type": "input_text", "text": r.prompt])
        var body: [String: Any] = ["model": r.voter.modelID,
                                   "input": [["role": "user", "content": content]],
                                   "store": false, "stream": true]
        // The bench's Codex `model_reasoning_effort`, so the shipped figures describe this request.
        if let t = r.voter.thinkingLevel { body["reasoning"] = ["effort": t] }
        var request = URLRequest(url: responsesURL, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: Reply

    /// The stream as read: the answer, and how it ended.
    struct Stream: Equatable {
        var text = ""
        var completed = false
        var errorCode: String?
        var errorMessage: String?
        var inputTokens: Int?
        var outputTokens: Int?
    }

    /// Server-sent events: each `data:` line is one JSON event. The answer is the completed response's output
    /// text, or the deltas when the completed event carries none.
    static func parseStream(_ data: Data) -> Stream {
        var s = Stream()
        var deltas = ""
        let text = String(decoding: data, as: UTF8.self)
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]",
                  let ev = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any],
                  let type = ev["type"] as? String else { continue }
            switch type {
            case "response.output_text.delta":
                deltas += ev["delta"] as? String ?? ""
            case "response.completed":
                s.completed = true
                let resp = ev["response"] as? [String: Any]
                s.text = outputText(resp)
                let usage = resp?["usage"] as? [String: Any]
                s.inputTokens = (usage?["input_tokens"] as? NSNumber)?.intValue
                s.outputTokens = (usage?["output_tokens"] as? NSNumber)?.intValue
            case "response.failed", "response.incomplete":
                let resp = ev["response"] as? [String: Any]
                let err = resp?["error"] as? [String: Any]
                s.errorCode = (err?["code"] as? String)
                    ?? ((resp?["incomplete_details"] as? [String: Any])?["reason"] as? String) ?? type
                s.errorMessage = err?["message"] as? String
            case "error":
                let err = (ev["error"] as? [String: Any]) ?? ev
                s.errorCode = (err["code"] as? String) ?? "error"
                s.errorMessage = err["message"] as? String
            default:
                break
            }
        }
        if s.text.isEmpty { s.text = deltas }
        return s
    }

    private static func outputText(_ resp: [String: Any]?) -> String {
        (resp?["output"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "message" }
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .filter { $0["type"] as? String == "output_text" }
            .compactMap { $0["text"] as? String }.joined()
    }

    static func errorCode(_ data: Data) -> String? {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (json?["error"] as? [String: Any])?["code"] as? String
    }

    static func replyText(data: Data, status: Int, response: HTTPURLResponse? = nil) throws -> String {
        if status != 200 {
            let err = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? [String: Any]
            let code = err?["code"] as? String
            let message = (err?["message"] as? String) ?? "HTTP \(status)"
            let reset = response?.value(forHTTPHeaderField: "Retry-After")
                .flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }.map { Date().addingTimeInterval($0) }
            try classify(code: code, message: message, status: status, reset: reset)
            throw WindowTransportError.failed("chatgpt \(status): \(message)")
        }
        let s = parseStream(data)
        if let code = s.errorCode {
            try classify(code: code, message: s.errorMessage ?? code, status: nil, reset: nil)
            throw WindowTransportError.failed("chatgpt: \(code): \(s.errorMessage ?? "")")
        }
        // Only a completed response is an answer (OpenAI: never treat a stream without one as success).
        guard s.completed else { throw WindowTransportError.failed("chatgpt: the stream ended before completing") }
        guard !s.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WindowTransportError.failed("chatgpt: empty answer")
        }
        return s.text
    }

    /// OpenAI's error table (errors-and-recovery): a usage limit stops the run with the Manage usage link; an
    /// ineligible account, an unsupported input or a refused grant fails every window alike; a temporary
    /// unavailability is left to the engine's one retry.
    private static func classify(code: String?, message: String, status: Int?, reset: Date?) throws {
        switch code {
        case "subscription_sharing_usage_limit_exceeded":
            throw WindowTransportError.usageLimit(reset: reset, message: "\(usageLimitMessage) (\(message))")
        case "subscription_sharing_user_not_eligible":
            throw WindowTransportError.fatal("This ChatGPT account cannot use its plan in other apps: \(message)")
        case "subscription_sharing_unsupported_capability":
            throw WindowTransportError.fatal("ChatGPT plan usage does not support this request: \(message)")
        case "subscription_sharing_invalid_user":
            throw WindowTransportError.fatal("ChatGPT sign-in is no longer valid. Sign in with ChatGPT again. (\(message))")
        case "subscription_sharing_usage_unavailable":
            // OpenAI: keep the credentials and retry later. The engine's one quick retry would let every window
            // fail through an outage and the run end without ChatGPT's votes, so stop resumably instead.
            throw WindowTransportError.usageLimit(reset: reset,
                message: "ChatGPT plan usage is temporarily unavailable; resume the run later. (\(message))")
        default:
            break
        }
        switch status {
        case 401:
            throw WindowTransportError.fatal("ChatGPT refused the sign-in. Sign in with ChatGPT again. (\(message))")
        case 400, 403, 404:
            throw WindowTransportError.fatal("chatgpt \(status!): \(message)")
        default:
            break
        }
    }
}
