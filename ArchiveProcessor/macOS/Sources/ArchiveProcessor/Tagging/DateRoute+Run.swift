import Foundation
import ArchiveCore

/// W46.date-route — the route's two calls and the sidecar's `dating` object.
extension DateRoute {
    /// The backend a run tags with, as `performTaggingPhase` holds it.
    struct Backend: Sendable {
        let provider: LLMProvider
        let model: LLMModel
        let apiKey: String
        let gateway: GatewayConfig?
        let localAgent: LocalAgentConfig?

        /// A remote gateway: the measured route (Gemini 3.7 Flash) for both calls, and the only image pass.
        var measured: Bool { localAgent == nil && gateway != nil && gateway?.isLocalModel != true }

        /// What the sidecar names as the route.
        var label: String { measured ? "Gateway · " + DateRoute.gatewayModel : ownLabel }

        /// The run's own text route.
        var ownLabel: String {
            if localAgent != nil { return "Local Agent" }
            if let g = gateway, !g.isLocalModel { return "Gateway · " + g.displayName }
            if let g = gateway { return "this Mac · " + g.displayName }
            return provider.rawValue + " · " + model.displayName
        }
    }

    /// What one document needs for its route, gathered on the main actor.
    struct Input: Sendable {
        let text: String
        let near: [Neighbour]
        /// The first `imagePages` pages: the source file and the run's rotation correction.
        let pages: [(url: URL, rotation: Int)]
    }

    /// Why the image pass was or was not sent, as the sidecar says it.
    static let imageSent = "sent"
    static let imageNotNeeded = "not sent: the text has a year"
    static let imageNoRoute = "not sent: no measured image route on this backend"
    static let imageNoPages = "not sent: no page image"
    static let imageFailed = "failed"

    /// One document through the route: the trace call, then the image pass where step 2 runs (or on every document
    /// when the user turned that on, for its second-role dates). Never throws: a failed call reads as no reply.
    static func run(_ input: Input, backend: Backend, imageEveryDocument: Bool) async -> Decision {
        let (raw, measured) = await trace(tracePrompt(text: input.text, near: input.near), backend: backend)
        let hasCandidate = !candidates(input.text).isEmpty
        var image: ImageReading? = nil
        var note = imageNotNeeded
        if !hasCandidate || imageEveryDocument {
            if !measured {
                note = imageNoRoute
            } else {
                let jpegs = input.pages.prefix(imagePages).compactMap {
                    ImageEncoding.uprightJPEG(url: $0.url, rotationDegrees: $0.rotation, longEdge: imageLongSide)
                }
                if jpegs.isEmpty {
                    note = imageNoPages
                } else if let reply = await imagePass(jpegs, gateway: backend.gateway!) {
                    image = readImage(reply)
                    note = image?.ok == true ? imageSent : imageFailed
                } else {
                    note = imageFailed
                }
            }
        }
        var d = decide(text: input.text, near: input.near, traceRaw: raw, image: image, imageNote: note)
        d.route = measured ? backend.label : backend.ownLabel
        d.measured = measured
        return d
    }

    /// The trace call and whether the measured route answered it. On a remote gateway, the measured request
    /// (`date_route_pipeline.trace_body`); a gateway that does not serve that model (or fails) is asked again on its
    /// own model, as every other backend is: the run's own text route, which no bench measured for this prompt.
    static func trace(_ prompt: String, backend: Backend) async -> (String?, Bool) {
        if backend.measured, let g = backend.gateway, let reply = await chat(content: prompt, gateway: g) {
            return (reply, true)
        }
        let reply = try? await LLMTextClient.complete(prompt: prompt, provider: backend.provider, model: backend.model,
                                                      thinkingLevel: nil, apiKey: backend.apiKey,
                                                      gatewayConfig: backend.gateway, localAgent: backend.localAgent,
                                                      maxTokens: maxTokens, timeout: timeout)
        return (reply, false)
    }

    /// The image pass (`date_undated.image_body`): the pages first, then the prompt.
    static func imagePass(_ jpegs: [Data], gateway: GatewayConfig) async -> String? {
        var content: [[String: Any]] = jpegs.map {
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + $0.base64EncodedString()]]
        }
        content.append(["type": "text", "text": imagePrompt])
        return await chat(content: content, gateway: gateway)
    }

    /// POST one user message to the gateway's chat completions at temperature 0, reasoning low; the first choice's
    /// text, nil on any failure or a non-200.
    private static func chat(content: Any, gateway: GatewayConfig) async -> String? {
        let body: [String: Any] = [
            "model": gatewayModel, "temperature": 0, "max_tokens": maxTokens, "reasoning_effort": "low",
            "messages": [["role": "user", "content": content]],
        ]
        guard let url = URL(string: "\(GatewayConfig.normalizedBaseURL(gateway.baseURL))/chat/completions"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(gateway.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = data
        guard let (respData, response) = try? await NetworkSession.data(for: request, policy: .nonIdempotent,
                                                                        maxRetries: 3),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else { return nil }
        return text
    }
}

extension DateRoute.Decision {
    /// Owner call 9: the 90% interval is shown only where the route measured it. W46.date-route-pipeline measured the
    /// trace reply's own interval on the gateway's Gemini 3.7 Flash: it held the owner's year on 86% (44/51) of the
    /// estimates, a median width of 1 year (`segbench-results/date-route-pipeline.md`, "By evidence class").
    static let measuredCoverage = "held the owner's year on 86% (44/51) of this route's estimates (date-route-pipeline.md)"

    /// The tags' date fields from the decision. The month is written only from the document itself: the tagging call's
    /// month and day when it read the same year, else the month of the dated form the year rests on.
    func apply(to tags: inout GeneratedTags) {
        let taggerYear = tags.year
        tags.dateUncertain = dateUncertain
        guard let year, evidenceClass == .text || evidenceClass == .image else {
            tags.year = year.map(String.init)
            tags.month = nil
            tags.day = nil
            return
        }
        tags.year = String(year)
        if taggerYear == String(year), tags.month != nil { return }   // the tagging call's own month and day stand
        tags.month = month.flatMap { GeneratedTags.monthTag($0) }
        tags.day = nil
    }

    /// Step 3a: an established enclosure with no explicit date of its own takes its cover's year, always with
    /// `Date Uncertain`; its own explicit date always wins (08-dating.md §3).
    mutating func inherit(fromCover cover: GeneratedTags, coverFile: String?) {
        guard evidenceClass != .text, evidenceClass != .image,
              let y = cover.year.flatMap({ Int($0) }), DateRoute.yearRange.contains(y) else { return }
        year = y; month = nil; dateUncertain = true; evidenceClass = .inherited; step = 3
        quote = nil; line = nil; page = nil; place = nil; sourceFile = coverFile
    }

    /// The sidecar's `dating` object: the evidence class and the quote with its place on every route (owner call 9),
    /// the interval only where measured, second-role dates with role, quote and place. An estimate whose evidence
    /// failed is not shown: no year and no quote, only that none passed.
    func sidecarObject() -> [String: Any] {
        var o: [String: Any] = ["class": evidenceClass.rawValue, "route": route, "image_pass": imageNote]
        if let step { o["step"] = step }
        switch evidenceClass {
        case .none:
            o["reason"] = trace.parsed ? "no year with checked evidence" : "the dating call gave no reply"
        case .inherited:
            o["source"] = sourceFile ?? "the covering letter"
        default:
            if let quote { o["quote"] = quote }
            if let line { o["line"] = line }
            if let page { o["page"] = page }
            if let place { o["where"] = place }
            if evidenceClass == .estimate {
                o["source"] = sourceFile ?? cited ?? "self"
                o["check"] = check.reason
                if measured, let lo = trace.lo, let hi = trace.hi {
                    o["interval_90"] = ["lo": lo, "hi": hi, "measured": Self.measuredCoverage]
                }
            }
        }
        if modelFlagAdded { o["uncertain_because"] = "the dating model said the document does not print its own year" }
        if let roles = image?.secondRole, !roles.isEmpty {
            o["second_role_dates"] = roles.map { r -> [String: Any] in
                var e: [String: Any] = ["role": r.place == "stamp" ? "stamp" : r.kind, "quote": r.quote, "where": r.place]
                if let p = r.page { e["page"] = p }
                if let y = r.year { e["year"] = y }
                return e
            }
        }
        return o
    }
}
