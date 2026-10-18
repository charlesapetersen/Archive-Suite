import Foundation

/// W41.app-local-models — an open-weight model on a server running on this Mac (LM Studio, Ollama or
/// `mlx_vlm.server`), reached through the gateway's OpenAI-compatible client with `GatewayConfig.localModel` set.
///
/// What the bench measured (`segbench-results/ocr-mac-local.md`, W41.mac-local-measure, Qwen3-VL 8B at 4-bit on the
/// 18 GB M3 Pro): where both finished a page, 4-bit read as well as the hosted bf16 (−0.17 NES over 91 pages); the
/// strict penalty (−2.15) came from whole-page failures. 3 of 99 pages looped to the 8,192-token cap at 7.3 minutes
/// each, and one reply broke the format. So the local route differs from a gateway in four ways, each here:
///   1. a lower token cap (`maxTokens`) — answered pages wrote a median 419 tokens, 90% under 928, and FarmShare's
///      2,000 pages 99.9% under 3,556 — so a loop stops at about half the time, and the reply is `length`, a failure
///      the cheap-first cascade escalates;
///   2. a repetition check (`isRepetitionLoop`) on a reply that ended by itself but looped;
///   3. one page at a time (one model, one GPU), with a timeout long enough for a slow Mac;
///   4. no API key, temperature 0, reasoning switched off (`applyReasoningOff`) and any reasoning text
///      (`<think>…</think>`) that comes anyway stripped.
/// The app's own reply format already keeps the text when the header tag is missing or unknown
/// (`OCRPrompt.parseResponse`), which is the lenient parser the measurement asked for.
enum LocalModelRoute {
    /// The reply budget for an OCR call. 4,096 sits above FarmShare's 99.9th percentile (3,556); its one longer
    /// page (5,766, a newspaper) is cut and escalated rather than read.
    static let maxTokens = 4096
    /// Per request, and the most `NetworkSession.shared` allows (its resource timeout). The 8B's slowest page took
    /// 445 s at 8,192 tokens; at 4,096 a loop on it stops in about 200 s.
    static let requestTimeout: TimeInterval = 600
    /// The placeholder sent as the bearer token: local servers take any key, and the Keychain holds none.
    static let placeholderKey = "local"

    /// The servers the Settings presets fill in. Each serves the OpenAI chat-completions API on this Mac.
    enum Server: String, CaseIterable, Identifiable {
        case lmStudio = "LM Studio"
        case ollama = "Ollama"
        case mlxVLM = "mlx-vlm"

        var id: String { rawValue }

        var baseURL: String {
            switch self {
            case .lmStudio: return "http://127.0.0.1:1234/v1"
            case .ollama: return "http://127.0.0.1:11434/v1"
            case .mlxVLM: return "http://127.0.0.1:8080/v1"
            }
        }
    }

    /// One model the route can offer, with the figures W41 has for it. `ids` is the name each server lists it under
    /// (the measured MLX build is exact; the others are those servers' usual names, and "Check server" shows the
    /// real list).
    struct Pick: Equatable, Identifiable {
        let name: String
        let precision: String
        let memoryGiB: Double
        let summary: String
        /// Seconds a page for the time estimate: measured for the 8B, estimated from memory bandwidth otherwise.
        let secondsPerPage: Double
        let ids: [Server: String]

        var id: String { "\(name) \(precision)" }
        var displayName: String { "\(name), \(precision) (this Mac)" }
        func modelID(for server: Server) -> String { ids[server] ?? ids[.mlxVLM] ?? name }
    }

    static let qwen3VL8B4 = Pick(
        name: "Qwen3-VL 8B", precision: "4-bit", memoryGiB: 8.4,
        summary: "Measured on an 18 GB M3 Pro: 89.7 NES on the truth set at 4-bit (91.8 hosted at bf16; −0.17 where "
            + "both finished a page), about 41 s a page, 8.4 GB in use. Close to the paid default; handwriting still "
            + "reads better in the cloud.",
        secondsPerPage: 41,
        ids: [.mlxVLM: "mlx-community/Qwen3-VL-8B-Instruct-4bit", .ollama: "qwen3-vl:8b", .lmStudio: "qwen/qwen3-vl-8b"])
    static let qwen36_27B4 = Pick(
        name: "Qwen3.6 27B", precision: "4-bit", memoryGiB: 22.9,
        summary: "The best open-weight reader W41 measured: 94.3 NES hosted at fp8. Its 4-bit score is unmeasured "
            + "(the 8B lost 0.17 where both finished). Needs about 23 GiB; estimated 1-2 minutes a page on an M4 Pro.",
        secondsPerPage: 90,
        ids: [.mlxVLM: "mlx-community/Qwen3.6-27B-4bit", .ollama: "qwen3.6:27b", .lmStudio: "qwen/qwen3.6-27b"])
    static let qwen36_35BA3B4 = Pick(
        name: "Qwen3.6 35B-A3B", precision: "4-bit", memoryGiB: 27.3,
        summary: "For speed: 93.0 NES hosted at fp8, handwriting 88.8. It reads about 3B parameters a token, so it "
            + "should be several times faster than the 27B (an estimate). Needs about 27 GiB.",
        secondsPerPage: 30,
        ids: [.mlxVLM: "mlx-community/Qwen3.6-35B-A3B-4bit", .ollama: "qwen3.6:35b-a3b",
              .lmStudio: "qwen/qwen3.6-35b-a3b"])
    static let qwen36_27B8 = Pick(
        name: "Qwen3.6 27B", precision: "8-bit", memoryGiB: 37.8,
        summary: "The nearest a Mac gets to the fp8 that scored 94.3 NES; a Mac's 8-bit build is a different format, "
            + "so its score is unmeasured but expected close. Needs about 38 GiB.",
        secondsPerPage: 90,
        ids: [.mlxVLM: "mlx-community/Qwen3.6-27B-8bit", .ollama: "qwen3.6:27b-q8_0", .lmStudio: "qwen/qwen3.6-27b"])
    static let qwen36_35BA3B8 = Pick(
        name: "Qwen3.6 35B-A3B", precision: "8-bit", memoryGiB: 46.5,
        summary: "The faster alternative at 8-bit: 93.0 NES hosted at fp8. Needs about 47 GiB.",
        secondsPerPage: 30,
        ids: [.mlxVLM: "mlx-community/Qwen3.6-35B-A3B-8bit", .ollama: "qwen3.6:35b-a3b-q8_0",
              .lmStudio: "qwen/qwen3.6-35b-a3b"])

    static let all = [qwen3VL8B4, qwen36_27B4, qwen36_35BA3B4, qwen36_27B8, qwen36_35BA3B8]

    /// Seconds a page for the time estimate of a run on `modelID`: its pick's figure, or the one measurement
    /// (the 8B's 41 s on the M3 Pro) for a model W41 has no figure for.
    static func secondsPerPage(modelID: String) -> Double {
        all.first { $0.ids.values.contains(modelID) }?.secondsPerPage ?? qwen3VL8B4.secondsPerPage
    }

    /// The models to offer for a Mac with this much memory, the recommended one first (W41-answers.md §1). Empty
    /// below 16 GB, where no measured model leaves room for the rest of the Mac: Apple Vision is the local choice.
    static func picks(memoryGB: Double) -> [Pick] {
        switch memoryGB {
        case ..<16: return []
        case ..<32: return [qwen3VL8B4]
        case ..<48: return [qwen36_27B4, qwen36_35BA3B4, qwen3VL8B4]
        case ..<64: return [qwen36_27B8, qwen36_27B4, qwen36_35BA3B4]
        default: return [qwen36_27B8, qwen36_35BA3B8, qwen36_27B4, qwen36_35BA3B4]
        }
    }

    /// This Mac's memory as Apple sells it: an "18 GB" Mac reports 18 GiB.
    static var thisMacMemoryGB: Double {
        (Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()
    }

    /// A sentence for Settings: what this Mac can run and why.
    static func recommendationNote(memoryGB: Double) -> String {
        let gb = Int(memoryGB)
        guard let first = picks(memoryGB: memoryGB).first else {
            return "This Mac has \(gb) GB of memory. No measured open-weight reader fits with room for the rest of "
                + "the Mac; Apple Vision is the free local route."
        }
        var note = "This Mac has \(gb) GB of memory: \(first.name), \(first.precision) is the recommended model. "
            + first.summary
        if memoryGB < 18 { note += " A 16 GB Mac runs it only with little else open." }
        return note
    }

    /// Settings' warning about whole newspaper pages (W41.app-local-models-fu1): 18 of 32 answered broadsheets needed
    /// more than the cap on FarmShare (4,341 to 7,371 tokens, `segbench-results/local-route-guards.md`).
    static let newspaperNote = "Whole newspaper pages mostly fail here: on our measurement 18 of 32 broadsheets needed "
        + "more than the \(maxTokens)-token cap. Leave newspapers to the escalation model, or read them in regions."

    // MARK: Reasoning off

    /// Turns a thinking model's reasoning off, under every spelling the presets' servers read (W41.app-local-models-fu2).
    /// On FarmShare, Qwen3.5 4B and Qwen3.6 27B and 35B-A3B spent the tagging call's 512 tokens thinking on 300 of 300
    /// documents and dated none; with reasoning off they dated a printed year at 95.8-97.5% (Gemini 97.5%;
    /// `segbench-results/date-tagging.md`). Qwen3-VL 8B does not think, and its template ignores the switch.
    ///   - `enable_thinking`: mlx-vlm (0.7.4's request schema reads it at the top level, checked in its source).
    ///   - `chat_template_kwargs.enable_thinking`: vLLM and llama.cpp's server pass it to the chat template.
    ///   - `think`: Ollama's own field; whether its OpenAI endpoint reads it is unchecked.
    /// Each server ignores the names it does not know (mlx-vlm's schema allows extra fields, vLLM warns and drops them,
    /// Ollama's JSON decoding skips them). No `reasoning_effort`: vLLM has validated it against low, medium and high,
    /// so "none" could fail every call there. A server that ignores all three still thinks, and a reply with no answer then
    /// fails (`textAnswer`, and OCR's own check) rather than being read as one.
    static func applyReasoningOff(_ body: inout [String: Any]) {
        body["enable_thinking"] = false
        body["chat_template_kwargs"] = ["enable_thinking": false]
        body["think"] = false
    }

    /// A text call's answer (classification, tags, segmentation), or nil when the reply holds none: cut at its token
    /// budget, empty, or ending in reasoning (an unclosed `<think>`, which `strippingReasoning` keeps). The caller
    /// throws, so the tagger records its failure instead of parsing the model's thinking as tags. A cut reply is no
    /// answer even when it began one: a cut JSON object never parsed, and a cut collection name is worse than none.
    static func textAnswer(_ content: String?, finish: String?) -> String? {
        guard finish != "length", let content else { return nil }
        let answer = strippingReasoning(content)
        return answer.isEmpty || answer.contains("<think>") ? nil : answer
    }

    static let noTextAnswer = "The local model's reply held no answer (all reasoning, or cut at its token budget)"

    // MARK: Reply guards

    /// Removes a reasoning block (`<think>…</think>`) a server returned inline, and a dangling close tag left when the
    /// template opened the block itself. An unclosed `<think>` keeps everything: it is not ours to guess where it ends.
    static func strippingReasoning(_ content: String) -> String {
        var s = content
        while let open = s.range(of: "<think>"), let close = s.range(of: "</think>", range: open.upperBound..<s.endIndex) {
            s.removeSubrange(open.lowerBound..<close.upperBound)
        }
        if !s.contains("<think>"), let close = s.range(of: "</think>") {
            s.removeSubrange(s.startIndex..<close.upperBound)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a reply ends in a loop: its tail repeats one span of 4 to 400 characters, back to back, at least
    /// `minRepeats` times and over at least `minLoopChars` characters. Set well above what a page legitimately
    /// repeats — a form's blank rows or a column of dot leaders runs to a few hundred characters, while a runaway
    /// reply repeats for thousands (a 4,096-token reply is about 15,000 characters). A span needs at least three different visible characters, so leaders, rules and
    /// empty table rows ("......", "____", "|   |   |") never count, however long.
    static func isRepetitionLoop(_ text: String, minLoopChars: Int = 2000, minRepeats: Int = 8) -> Bool {
        let chars = Array(text.unicodeScalars.suffix(6000))
        let n = chars.count
        guard n >= minLoopChars else { return false }
        for period in 4...400 where period * minRepeats <= n {
            var run = 0
            var i = n - 1
            while i - period >= 0, chars[i] == chars[i - period] {
                run += 1
                i -= 1
            }
            let looped = run + period   // the first copy plus every character that matched the one before it
            guard looped >= minLoopChars, looped >= period * minRepeats else { continue }
            let visible = Set(chars[(n - period)...].filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
            if visible.count >= 3 { return true }
        }
        return false
    }

    static let loopedReply = OCRResult(
        text: nil, classification: nil,
        errorMessage: "The local model's reply repeated itself; the page was not read",
        errorCode: OCRFailureCode.cutOff)

    /// A streamed chat-completions reply as it arrives (W41.app-local-models-fu1): server-sent events, `data: {json}`
    /// lines and a closing `data: [DONE]`, as LM Studio, Ollama and mlx-vlm send them for `stream: true`.
    /// `isRepetitionLoop` runs on the content every `checkEvery` characters, so a loop is caught near where it starts:
    /// replayed over 62 of Qwen3-VL 8B's FarmShare runaways at every 250 characters it fired on 51, after a median
    /// 1,232 tokens (`segbench-results/local-route-guards.md`), where the cap reads 4,096.
    struct StreamedReply {
        static let checkEvery = 250

        private(set) var content = ""
        /// Reasoning a server streams in its own field (`reasoning_content`, `reasoning`), kept only to catch a loop in it.
        private var reasoning = ""
        private(set) var finish: String?
        /// Whether the closing `data: [DONE]` came. With no finish reason either, the reply ended early (the server
        /// stopped or unloaded the model) and is not a transcription.
        private(set) var sawDone = false
        private(set) var error: String?
        /// Whether any `data:` line came. None means the server ignored `stream` (or failed) and sent a plain body.
        private(set) var sawEvents = false
        private var lines: [String] = []
        private var length = 0
        private var checkedAt = 0
        private var reasoningLength = 0
        private var reasoningCheckedAt = 0

        /// Whether the reply came to an end the server reported, rather than a connection that just closed.
        var isComplete: Bool { sawDone || finish != nil }

        /// The lines that were not events, as one body: an error status's, or a whole reply from a server that
        /// ignored `stream`.
        var rawBody: Data { Data(lines.joined(separator: "\n").utf8) }

        /// Takes one line of the response. Returns false once the content loops, the cue to close the request.
        mutating func take(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else {
                if !sawEvents { lines.append(line) }
                return true
            }
            sawEvents = true
            let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { sawDone = true; return true }
            guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return true }
            if let failure = json["error"] as? [String: Any] {
                error = (failure["message"] as? String) ?? "The local server failed while answering"
            } else if let failure = json["error"] as? String {
                error = failure
            }
            guard let choice = (json["choices"] as? [[String: Any]])?.first else { return true }
            let delta = choice["delta"] as? [String: Any]
            if let piece = delta?["content"] as? String {
                content += piece
                length += piece.unicodeScalars.count
            }
            if let piece = (delta?["reasoning_content"] ?? delta?["reasoning"]) as? String {
                reasoning += piece
                reasoningLength += piece.unicodeScalars.count
            }
            if let reason = choice["finish_reason"] as? String { finish = reason }
            if length - checkedAt >= Self.checkEvery {
                checkedAt = length
                if LocalModelRoute.isRepetitionLoop(content) { return false }
            }
            if reasoningLength - reasoningCheckedAt >= Self.checkEvery {
                reasoningCheckedAt = reasoningLength
                if LocalModelRoute.isRepetitionLoop(reasoning) { return false }
            }
            return true
        }
    }

    /// The penalty of the second reading, FarmShare's (`fs_ocr.py` `RETRY`), with temperature still 0.
    static let retryRepetitionPenalty = 1.05

    /// Whether a failed page is read once more (W41.app-local-models-fu1): a reply that looped or reached the cap. On
    /// FarmShare a second reading with this penalty answered 9 of Qwen3-VL 8B's 71 looped pages. Not a timeout, which
    /// already took up to ten minutes, and not an error.
    static func shouldReadAgain(_ result: OCRResult) -> Bool {
        result.errorCode == OCRFailureCode.cutOff && result.errorMessage != timedOutReply.errorMessage
    }

    /// The penalty under both names in use: mlx-vlm (and vLLM) read `repetition_penalty`, LM Studio `repeat_penalty`.
    /// Each server ignores the other's name. Ollama's OpenAI endpoint takes neither (an unchecked reading of its
    /// documentation), so there the second reading repeats the first request.
    static func applyRetryPenalty(_ body: inout [String: Any]) {
        body["repetition_penalty"] = retryRepetitionPenalty
        body["repeat_penalty"] = retryRepetitionPenalty
    }

    /// The second reading's result: its text when it answered, else a failure with both readings in the reason. A
    /// second reading that failed some other way (a server that refused the penalty field, or one that fell over) keeps
    /// the first reading's code, so the page still escalates as the looped page it is and the run's retry passes, which
    /// take 5xx codes, do not read it twice more.
    static func afterSecondReading(first: OCRResult, second: OCRResult) -> OCRResult {
        guard second.errorCode != nil else { return second }
        let firstWhat = first.errorMessage == loopedReply.errorMessage
            ? "repeated itself" : "reached the \(maxTokens)-token cap"
        let sameKind = [OCRFailureCode.cutOff, OCRFailureCode.unparsable].contains(second.errorCode ?? "")
        return OCRResult(
            text: nil, classification: nil,
            errorMessage: (second.errorMessage ?? "The page was not read")
                + " (read twice: the first reply \(firstWhat); the second, with a repetition penalty, failed too)",
            errorCode: sameKind ? second.errorCode : first.errorCode)
    }

    /// The first reading's failure when the second could not be made at all (the server stopped answering).
    static func afterFailedSecondReading(first: OCRResult, error: Error) -> OCRResult {
        OCRResult(text: nil, classification: nil,
                  errorMessage: (first.errorMessage ?? "The page was not read")
                    + " (a second reading could not be made: \(error.localizedDescription))",
                  errorCode: first.errorCode)
    }

    static let endedEarlyReply = OCRResult(
        text: nil, classification: nil,
        errorMessage: "The local server's reply ended before it finished (was the model unloaded?)",
        errorCode: OCRFailureCode.unparsable)

    static let timedOutReply = OCRResult(
        text: nil, classification: nil,
        errorMessage: "The local model did not finish within \(Int(requestTimeout)) s (a slow Mac, a big model, or a loop the check did not see)",
        errorCode: OCRFailureCode.cutOff)

    /// Whether the address is this Mac (the presets' 127.0.0.1, `localhost`, `::1`); Settings warns otherwise, since
    /// the local route's single worker, cap and escalation are wrong for a remote paid gateway.
    static func isLoopback(_ baseURL: String) -> Bool {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return false }
        return host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }

    // MARK: Server check

    /// The model names the server at `baseURL` lists (`GET /models`, the OpenAI shape LM Studio, Ollama and
    /// mlx-vlm share). Throws with a readable message when nothing answers. `URLSession.shared` with a short timeout,
    /// like `KeyValidator`: the OCR session waits for connectivity and retries, so a stopped server would hang the
    /// button.
    static func listModels(baseURL: String) async throws -> [String] {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(base)/models") else { throw OCRError.networkError("Invalid server URL: \(baseURL)") }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue("Bearer \(placeholderKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw OCRError.networkError("The server answered \(status)") }
        return parseModelList(data)
    }

    /// What "Check server" says: whether the configured model is among those the server lists.
    static func checkSummary(models: [String], modelID: String) -> String {
        if models.isEmpty { return "The server answers but lists no models: load or download one in it first." }
        let listed = models.prefix(8).joined(separator: ", ") + (models.count > 8 ? ", …" : "")
        if models.contains(modelID) { return "The server answers and lists \(modelID). Ready." }
        return "The server answers, but does not list \(modelID.isEmpty ? "a model ID" : modelID). It lists: \(listed). "
            + "Put one of those in Model ID, or download the model in the server."
    }

    static func parseModelList(_ data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { return [] }
        return items.compactMap { $0["id"] as? String }
    }
}
