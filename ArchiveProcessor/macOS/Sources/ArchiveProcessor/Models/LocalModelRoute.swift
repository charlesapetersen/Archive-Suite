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
///   4. no API key, temperature 0, and reasoning text (`<think>…</think>`) stripped.
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

    static let timedOutReply = OCRResult(
        text: nil, classification: nil,
        errorMessage: "The local model did not finish within \(Int(requestTimeout)) s (most likely a reply repeating itself)",
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
