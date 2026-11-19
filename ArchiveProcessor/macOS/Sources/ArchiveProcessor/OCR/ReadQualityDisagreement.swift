import Foundation
import VisionOCRKit

/// W47.wh-read-flag-readers (owner, 2026-11-19, call 15): the read-poorly flag for a reader other than Apple Vision.
/// After the reader's page, Apple Vision reads the same image (on this Mac, for nothing) and the two texts are
/// compared as the bench scores a reading against truth (`similarity`, the bench's NES). A page whose disagreement
/// reaches the reader's own cut is flagged. Each cut was fitted by `scripts/segbench/post_read_flag.py report`
/// (`app_readers` in `segbench-results/post-read-flag.json`) for at most 5% false alarms among that reader's readings
/// at 70 NES or above, on the sets named in `measuredOn`; a reader the bench has not read, or whose cut no set held
/// the ceiling for, has no rule and is not flagged.
///
/// Not checked, as none was measured: a page another route read in the reader's place (a refusal's second reader, the
/// cascade's escalation), a page from an institutional-computing import, a newspaper page read in regions (its text is
/// in region order), a page the app turned (Vision reads the stored image, and the fit's photographs were read as
/// stored), a blank reading, and a page Vision failed on (as opposed to reading no text, which the fit counted as total
/// disagreement). Batch runs do not come through `performOCRCall` and are not checked.
enum ReadQualityDisagreement {
    /// The route a page was read by, as far as a rule needs it.
    struct Route: Equatable, Sendable {
        var provider: LLMProvider
        var modelID: String
        /// Read through the user's OpenAI-compatible gateway (`GatewayConfig`), and whether that is a model on this Mac.
        var gateway = false
        var local = false
    }

    struct Rule: Equatable, Sendable {
        /// The reader's name in the run summary.
        let reader: String
        /// Flag when the disagreement is at or above this (midway between the fitted cut and the next lower
        /// disagreement seen, so the fitted pages flag exactly as they did in the fit).
        let flagAtOrAbove: Double
        /// What the cut was measured on, in the run summary's words.
        let measuredOn: String
        /// The bench reader it was fitted for (`post_read_flag.py`'s key).
        let benchKey: String
    }

    /// The rule for a route, or nil when the bench measured none for it.
    static func rule(for route: Route) -> Rule? {
        let id = route.modelID.lowercased()
        if route.gateway {
            if !route.local { return id == LLMRotationDetector.gatewayModel ? gemini37Gateway : nil }
            if id.contains("thinking") { return nil }   // a reasoning variant is another reader
            if id.contains("lightonocr") { return lightOnOCR }
            if id.contains("qwen3.5-9b") || id.contains("qwen3.5:9b") { return qwenMac }
            if id.contains("qwen3-vl-8b") || id.contains("qwen3-vl:8b") { return qwenVL8Mac }
            return nil
        }
        // A measured model through OpenRouter on its maker's endpoint is the route the bench read it on.
        if route.provider == .openrouter,
           let maker = OpenRouterRoute.makerRoutes.first(where: { $0.model.id.lowercased() == id })?.maker {
            return direct[maker.provider]?[maker.id]
        }
        return direct[route.provider]?[id]
    }

    // MARK: The fitted rules (post-read-flag.json `app_readers`)

    // Cross-validated on the 96 (the estimate for new pages; in-sample and every interval in the report): LightOnOCR-3
    // catches 62% of its poor readings at 5% false alarms, Qwen3.5 9B 36% at 5%, Qwen3-VL 8B 63% at 4%. Gemini 3.7
    // Flash's cut holds the ceiling on the 96 and on the ladder's damaged images each: 35% at 4% over both, none of
    // its 3 poor plain readings. The Mac rules were measured on the 4- and 8-bit MLX builds; another server's build
    // of the same model is taken to read alike.
    static let lightOnOCR = Rule(reader: "LightOnOCR-3", flagAtOrAbove: 0.6481,
                                 measuredOn: "96 plain photographs, read on this Mac", benchKey: "lightonocr-3-4b-mlx8")
    static let qwenMac = Rule(reader: "Qwen3.5 9B", flagAtOrAbove: 0.6754,
                              measuredOn: "96 plain photographs, read on this Mac", benchKey: "qwen3.5-9b-mlx4")
    static let qwenVL8Mac = Rule(reader: "Qwen3-VL 8B", flagAtOrAbove: 0.7013,
                                 measuredOn: "96 plain photographs, read on this Mac", benchKey: "qwen3-vl-8b-mlx4")
    static let gemini37Gateway = Rule(reader: "Gemini 3.7 Flash", flagAtOrAbove: 0.9764,
                                      measuredOn: "96 plain photographs and 480 damaged copies of 48 of them",
                                      benchKey: "gemini3.7-flash")

    /// Direct routes, by provider and the app's model id; each measured on the 96 plain photographs. Cross-validated
    /// catch rates at 4-5% false alarms: Gemini 3.8 Flash 40%, 3.5 Flash 67%, 3.1 Pro 50%, 3.5 Flash Lite 40%, 3.1
    /// Flash Lite 42%, GPT-5.4 mini 40%, and through OpenRouter Qwen3-VL 235B 28%, Qwen3.8 Flash 50%, Qwen3.6 27B
    /// 25%, Qwen3.5 9B 51%. The bench read GPT-5.4 mini through OpenRouter's OpenAI endpoint, the same model the app
    /// calls directly. Not here: Claude Sonnet 5.5 and Mistral OCR, whose cuts hold the ceiling but caught none of
    /// their poor readings (0 of 2 and 0 of 7), so a flag would only be false alarms; that is the owner's call
    /// (W47.wh-read-flag-cm-owner-ok).
    static let direct: [LLMProvider: [String: Rule]] = [
        .gemini: [
            "gemini-3.8-flash": plain("Gemini 3.8 Flash", 0.6882, "gemini3.8-flash"),
            "gemini-3.5-flash": plain("Gemini 3.5 Flash", 0.6847, "gemini3.5-flash"),
            "gemini-3.1-pro": plain("Gemini 3.1 Pro", 0.7006, "gemini3.1-pro"),
            "gemini-3.5-flash-lite": plain("Gemini 3.5 Flash Lite", 0.6967, "gemini3.5-flash-lite"),
            "gemini-3.1-flash-lite": plain("Gemini 3.1 Flash Lite", 0.6978, "gemini3.1-flash-lite"),
        ],
        .openai: ["gpt-5.4-mini": plain("GPT-5.4 mini", 0.6721, "gpt5.4-mini")],
        .openrouter: [
            "qwen/qwen3-vl-235b-a22b-instruct": plain("Qwen3-VL 235B", 0.7106, "qwen3-vl-235b"),
            "qwen/qwen3.8-flash": plain("Qwen3.8 Flash", 0.7243, "qwen3.8-flash"),
            "qwen/qwen3.6-27b": plain("Qwen3.6 27B", 0.7034, "qwen3.6-27b"),
            "qwen/qwen3.5-9b": plain("Qwen3.5 9B", 0.6979, "qwen3.5-9b"),
        ],
    ]

    private static func plain(_ reader: String, _ cut: Double, _ key: String) -> Rule {
        Rule(reader: reader, flagAtOrAbove: cut, measuredOn: "96 plain photographs", benchKey: key)
    }

    static var all: [Rule] { [lightOnOCR, qwenMac, qwenVL8Mac, gemini37Gateway] + direct.values.flatMap(\.values) }

    // MARK: The check

    /// What Vision made of the page: its text, no text at all, or a failure (the image did not load, the request
    /// failed), which says nothing about the reader.
    enum VisionReading: Equatable, Sendable {
        case text(String)
        case nothing
        case failed
    }

    /// Test seam: Vision's reading of an image (headless tests draw no real page). nil in production.
    nonisolated(unsafe) static var visionOverride: (@Sendable (URL) -> VisionReading)?

    /// The flag for `result`, read by `route` from `imageURL`, or nil: no rule for the route, a reading the check does
    /// not cover (see the type's note), a page already flagged, or a reading close enough to Vision's. Vision reads the
    /// image with the settings every cut was fitted with (`VisionOCRSettings.default`), whatever the run's own are.
    static func check(_ result: OCRResult, route: Route?, imageURL: URL) async -> ReadQualityFlag? {
        guard let route, route.provider != .appleVision, let rule = rule(for: route), let text = result.text,
              !normalized(text).isEmpty, result.errorMessage == nil, result.readPoorly == nil,
              result.secondReader == nil, result.imported == nil, result.rotationDegrees == 0,
              (result.newspaperLayout?.regions ?? 0) == 0, !Task.isCancelled else { return nil }
        switch await visionReading(imageURL) {
        case .text(let vision): return assess(readerText: text, visionText: vision, rule: rule)
        case .nothing: return assess(readerText: text, visionText: nil, rule: rule)
        case .failed: return nil
        }
    }

    private static func visionReading(_ imageURL: URL) async -> VisionReading {
        if let visionOverride { return visionOverride(imageURL) }
        guard let reader = try? PageReaders.reader(provider: .appleVision, model: LLMModel.appleVisionModels[0],
                                                   apiKey: "", thinkingLevel: nil, visionSettings: .default,
                                                   newspaperLayout: false),
              let read = try? await reader.read(PageReaderInput(imageURL: imageURL)).detail else { return .failed }
        if let text = read.text, !text.isEmpty { return .text(text) }
        return read.errorCode == "vision_no_text" ? .nothing : .failed
    }

    // MARK: The comparison

    /// The flag for a reading by `rule`'s reader whose page Vision read as `visionText` (nil: Vision read nothing,
    /// which the fit counted as total disagreement), or nil when the two agree closely enough.
    static func assess(readerText: String, visionText: String?, rule: Rule) -> ReadQualityFlag? {
        let d = visionText.map { 1 - similarity($0, readerText) } ?? 1
        guard d >= rule.flagAtOrAbove else { return nil }
        return ReadQualityFlag(visionConfidence: nil, disagreement: d, reader: rule.reader, measuredOn: rule.measuredOn)
    }

    /// The bench's NES of `hypothesis` against `reference` (`ocr_panel_score.score`, stratum S0): both normalized, then
    /// 1 minus their edit distance over the longer length, counted in grapheme clusters.
    static func similarity(_ reference: String, _ hypothesis: String) -> Double {
        let a = Array(normalized(reference)), b = Array(normalized(hypothesis))
        let n = max(a.count, b.count)
        guard n > 0 else { return 1 }
        return 1 - Double(editDistance(a, b)) / Double(n)
    }

    /// `ocr_panel_score.normal` with nothing kept and no hyphen joining: NFKC, bidi controls dropped, typographic
    /// quotes, dashes and table bars unified, a dash opening a line counted as a bullet, whitespace collapsed. Python
    /// works on code points, so every step here does too (a mark after a space or a quote stays its own).
    static func normalized(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for u in text.precomposedStringWithCompatibilityMapping.unicodeScalars where !bidiControls.contains(u.value) {
            scalars.append(contentsOf: typography[u.value].map { $0.unicodeScalars } ?? String(u).unicodeScalars)
        }
        let s = String(scalars)
        let bulleted = lineBullet.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "* ")
        // Python's str.split(): runs of whitespace code points (its isspace, which adds the four separators 1C-1F).
        var words: [String.UnicodeScalarView] = [], word = String.UnicodeScalarView()
        for u in bulleted.unicodeScalars {
            if u.properties.isWhitespace || (0x1C...0x1F).contains(u.value) {
                if !word.isEmpty { words.append(word); word = String.UnicodeScalarView() }
            } else {
                word.append(u)
            }
        }
        if !word.isEmpty { words.append(word) }
        return words.map(String.init).joined(separator: " ")
    }

    private static let bidiControls: Set<UInt32> = Set([0x200E, 0x200F] + Array(0x202A...0x202E) + Array(0x2066...0x2069))
    private static let typography: [UInt32: String] = [0x2018: "'", 0x2019: "'", 0x201C: "\"", 0x201D: "\"", 0x2013: "-",
                                                       0x2014: "-", 0x2212: "-", 0x7C: " ", 0x2022: "*"]
    /// Python's `(?m)^`: the start of the text or just after a line feed, and no other line break.
    // swiftlint:disable:next force_try
    private static let lineBullet = try! NSRegularExpression(pattern: #"(?:\A|(?<=\n))\s*-\s+(?=\S)"#)

    /// Levenshtein distance; characters are numbered first so the inner loop compares integers.
    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var ids: [Character: Int] = [:]
        func number(_ s: [Character]) -> [Int] {
            s.map { c in
                if let id = ids[c] { return id }
                ids[c] = ids.count
                return ids.count - 1
            }
        }
        let x = number(a), y = number(b)
        var prev = Array(0...y.count), cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            let xi = x[i - 1]
            for j in 1...y.count {
                cur[j] = xi == y[j - 1] ? prev[j - 1] : 1 + min(prev[j - 1], prev[j], cur[j - 1])
            }
            swap(&prev, &cur)
        }
        return prev[y.count]
    }
}
