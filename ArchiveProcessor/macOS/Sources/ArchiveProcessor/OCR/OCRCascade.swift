import Foundation

/// W41.app-ocr-cascade — read each page with the run's own (cheap) model first, and send a page it fails on to a
/// stronger route the user picks.
///
/// The bench measured it (`ArchiveOCRBench/difficulty.md` §4 and its proposed rule): on the panel's 96 pages, a
/// cascade that escalates failures, chosen on half the pages, beat a single route chosen the same way by 0.8 to
/// 2.8 NES on the other half at every budget up to $5 per 1,000 pages, and on FarmShare's 2,000 corpus pages only
/// 13 failed, so the dearer route sees about one page in 154. At the strongest-accuracy setting one strong reader
/// alone stayed best, so the cascade is off by default and is a choice, not a replacement.
///
/// The optional second trigger (`onDisagreement`, off by default) also escalates a page whose word count and
/// Apple Vision's differ by more than `disagreementRatio`. Vision runs on the Mac and costs nothing. The signal
/// ranks poor readings well (AUC 0.78-0.89 against Vision's count, §5), but its gain over failure-only escalation
/// was not consistent on unseen pages, so it stays off until a larger test.
///
/// Applies on the direct-provider path, and on a gateway that is a model on this Mac (W41.app-local-models: its
/// looped or cut pages need a fallback). A remote gateway and the Local Agent are the user's explicit single
/// route, Apple Vision is the comparator rather than a first reader, and the Tools diagnostics measure the
/// chosen model, so none of them is ever escalated.
struct OCRCascade: Codable, Equatable, Sendable {
    /// The escalation route, `"<provider rawValue>|<model id>"`; nil = the cascade is off.
    var routeID: String?
    /// Also escalate a page whose word count disagrees with Apple Vision's.
    var onDisagreement: Bool = false
    /// This run's escalation count, shared by every copy of the run's config (a reference), never persisted: a
    /// resumed run starts a fresh count.
    var breaker = Breaker()

    private enum CodingKeys: String, CodingKey { case routeID, onDisagreement }

    init(routeID: String?, onDisagreement: Bool = false) {
        self.routeID = routeID
        self.onDisagreement = onDisagreement
    }

    /// Tolerant of a missing key, so a partial journal decodes as the cascade off rather than failing the batch.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        routeID = try c.decodeIfPresent(String.self, forKey: .routeID)
        onDisagreement = try c.decodeIfPresent(Bool.self, forKey: .onDisagreement) ?? false
    }

    static func == (a: OCRCascade, b: OCRCascade) -> Bool {
        a.routeID == b.routeID && a.onDisagreement == b.onDisagreement
    }

    static let off = OCRCascade(routeID: nil)

    /// Bounds what a fault on the first route can cost. The design expects few escalations (about one page in 154
    /// fail on the corpus; the Vision check sends about one in ten), but an outage that answers every page with a
    /// 500, or a provider whose replies stop parsing, would otherwise send the whole run to the dearer route. The
    /// first `freeEscalations` always go; after that, only while fewer than `maxShare` of the run's pages have.
    final class Breaker: @unchecked Sendable {
        static let freeEscalations = 20
        static let maxShare = 0.25
        private let lock = NSLock()
        /// Distinct pages, not attempts: the run's retry passes and per-item Retry read a page again, and counting
        /// each attempt would loosen the quarter during a rate-limit or timeout storm (Tier-2 review).
        private var seen = Set<String>()
        private var pages: Int { seen.count }
        private var escalated = 0

        func notePage(_ page: URL) { _ = lock.withLock { seen.insert(page.standardizedFileURL.path) } }

        /// Whether one more page may escalate; counts it when it may. Otherwise the count so far, for the message.
        func admit() -> (allowed: Bool, escalated: Int, pages: Int) {
            lock.withLock {
                let allowed = escalated < Self.freeEscalations || Double(escalated) < Self.maxShare * Double(pages)
                if allowed { escalated += 1 }
                return (allowed, escalated, pages)
            }
        }
    }

    /// The code on a page the escalation route could not read either. Never auto-retried (`isTimeoutError`,
    /// `isRetryableError`): a re-run would buy the first reading and the escalation again. Per-item Retry still can.
    static let exhaustedCode = "CascadeExhausted"

    /// Two word counts disagree when one is more than this many times the other (each plus one, as the bench's
    /// `abs(log((a + 1) / (b + 1)))`). Measured on the panel's 96 pages (`segbench-results/ocr-pages.csv`): at 1.5
    /// a cheap reader's flagged pages were 6-11% of those it answered, holding about a third to a half of its
    /// readings under 90 NES; at 2.0 it flagged 3-6% and caught far fewer.
    static let disagreementRatio = 1.5

    /// Test seams (headless tests have no Keychain, and Vision reads nothing off a blank fixture). nil in production.
    nonisolated(unsafe) static var keyOverride: (@Sendable (LLMProvider) -> String?)?
    nonisolated(unsafe) static var visionWordsOverride: (@Sendable (URL) -> Int?)?

    var isOn: Bool { escalationModel != nil }

    static func fromDefaults(_ d: UserDefaults = .standard) -> OCRCascade {
        let id = d.string(forKey: DefaultsKeys.ocrCascadeRoute).flatMap { $0.isEmpty ? nil : $0 }
        return OCRCascade(routeID: id, onDisagreement: d.bool(forKey: DefaultsKeys.ocrCascadeOnDisagreement))
    }

    static func routeID(for model: LLMModel) -> String { "\(model.provider.rawValue)|\(model.id)" }

    /// The models the user may escalate to: every built-in model of every keyed provider. Custom models are left
    /// out (a cascade route must have a known price for the estimate), and OpenRouter's are its pinned catalog.
    static var candidates: [LLMModel] {
        [LLMModel.anthropicModels, LLMModel.geminiModels, LLMModel.openaiModels, LLMModel.openrouterModels,
         LLMModel.mistralModels].flatMap { $0 }
    }

    /// The escalation model `routeID` names, or nil when it is unset or names no built-in model.
    var escalationModel: LLMModel? {
        guard let routeID else { return nil }
        return Self.candidates.first { Self.routeID(for: $0) == routeID }
    }

    /// Whether the run's page goes through the cascade: a direct, non-Vision first reader that is not itself the
    /// escalation model.
    func applies(to provider: LLMProvider, model: LLMModel) -> Bool {
        guard let target = escalationModel, provider != .appleVision else { return false }
        return Self.routeID(for: target) != Self.routeID(for: model)
    }

    /// What one escalated page costs at the escalation route's standard rate, for the pre-run estimate.
    func pageCost(imageScale: Double) -> Double? {
        escalationModel.map { CostEstimator.secondReaderPageCost(model: $0, imageScale: imageScale) }
    }

    /// A failed reading a stronger model can plausibly read: a reply cut off at the token limit (`length`), an
    /// unparsable reply, a provider's server error with no text (HTTP 500, Anthropic's `api_error`), and Gemini's
    /// refusals (a finish or block reason). Not a transport failure (no code), a timeout, a rate limit or overload
    /// (the run's own retry passes take those), or a key, quota or request error (the user's to fix: escalating
    /// those would send every page to the dearer route and hide the problem).
    static func isEscalatable(_ result: OCRResult, provider: LLMProvider) -> Bool {
        guard result.text == nil, let code = result.errorCode, !code.isEmpty else { return false }
        if code == exhaustedCode || code == OCRRefusalFallback.exhaustedCode { return false }
        if OCRProcessor.isTimeoutError(result) { return false }
        switch code {
        case OCRFailureCode.cutOff, OCRFailureCode.unparsable, "500", "api_error": return true
        default: return provider == .gemini && OCRRefusalFallback.isRefusal(result)
        }
    }

    /// Words as the bench counted them: runs of non-whitespace.
    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    static func disagrees(words: Int, visionWords: Int) -> Bool {
        abs(log(Double(words + 1) / Double(visionWords + 1))) > log(disagreementRatio)
    }

    /// The first reading, escalated when it should be. Returns the first reading untouched when the cascade does
    /// not apply or nothing triggers it. A failed first reading the escalation route also fails stays a failure
    /// (`exhaustedCode`, naming both reasons) unless it was a Gemini refusal, which then goes on to the refusal
    /// readers as before (`refusalFallback`). A disagreement whose escalation fails keeps the first reading.
    static func resolve(
        _ first: OCRResult, cascade: OCRCascade, provider: LLMProvider, model: LLMModel, refusalFallback: Bool,
        imageURL: URL, previousText: String?, previousImageURL: URL?, customPrompt: String?, imageScale: Double,
        visionSettings: VisionOCRSettings, firstReaderLabel: String? = nil
    ) async -> OCRResult {
        let refused = refusalFallback && provider == .gemini && OCRRefusalFallback.isRefusal(first)
        guard cascade.applies(to: provider, model: model), let target = cascade.escalationModel else {
            return refused
                ? await OCRRefusalFallback.readRefusedPage(
                    first, imageURL: imageURL, previousText: previousText, previousImageURL: previousImageURL,
                    customPrompt: customPrompt, imageScale: imageScale)
                : first
        }
        cascade.breaker.notePage(imageURL)
        let trigger: SecondReader.Trigger
        let firstCode: String
        if isEscalatable(first, provider: provider) {
            // A cut-off, unparsable or 500 reply is a failure even from Gemini; only its finish/block reasons refuse.
            let failure = [OCRFailureCode.cutOff, OCRFailureCode.unparsable, "500"].contains(first.errorCode ?? "")
            trigger = refused && !failure ? .refusal : .failure
            firstCode = first.errorCode ?? "?"
        } else if cascade.onDisagreement, let text = first.text, !Task.isCancelled,
                  let visionWords = await visionWordCount(imageURL: imageURL, settings: visionSettings) {
            let words = wordCount(text)
            guard disagrees(words: words, visionWords: visionWords) else { return first }
            trigger = .disagreement
            firstCode = "\(words) words, Vision \(visionWords)"
        } else {
            return first
        }

        let admitted = cascade.breaker.admit()
        guard admitted.allowed else {
            NSLog("[OCR] \(imageURL.lastPathComponent): not escalated, \(admitted.escalated) of \(admitted.pages) pages already were")
            if trigger == .disagreement { return first }
            if refused, !Task.isCancelled {
                return await OCRRefusalFallback.readRefusedPage(
                    first, imageURL: imageURL, previousText: previousText, previousImageURL: previousImageURL,
                    customPrompt: customPrompt, imageScale: imageScale)
            }
            let note = " Not escalated: \(admitted.escalated) of the run's \(admitted.pages) pages already were, which "
                + "points to a fault on the first route rather than hard pages."
            return OCRResult(text: nil, classification: nil, errorMessage: (first.errorMessage ?? "No text.") + note,
                             errorCode: first.errorCode)
        }

        let firstLabel = firstReaderLabel ?? "\(model.provider.rawValue) · \(model.displayName)"
        let targetLabel = "\(target.provider.rawValue) · \(target.displayName)"
        var why: String
        if Task.isCancelled {
            why = "stopped before \(targetLabel)"
        } else if let key = key(for: target.provider), !key.isEmpty {
            let route = OCRRefusalFallback.Route(provider: target.provider, model: target, apiKey: key, localAgent: nil)
            do {
                let read = try await OCRRefusalFallback.read(
                    route, imageURL: imageURL, previousText: previousText, previousImageURL: previousImageURL,
                    customPrompt: customPrompt, imageScale: imageScale)
                if read.text != nil {
                    let reader = SecondReader(
                        provider: route.provenanceProvider, model: route.provenanceModel, firstCode: firstCode,
                        estimatedCost: CostEstimator.secondReaderPageCost(model: target, imageScale: imageScale),
                        trigger: trigger, firstReader: firstLabel)
                    NSLog("[OCR] \(imageURL.lastPathComponent): read by \(reader.summary)")
                    return OCRResult(text: read.text, classification: read.classification,
                                     rotationDegrees: read.rotationDegrees, errorMessage: nil, errorCode: nil,
                                     enclosure: read.enclosure, secondReader: reader)
                }
                why = "\(targetLabel): \(read.errorMessage ?? "no text")"
            } catch {
                why = "\(targetLabel): \(error.localizedDescription)"
            }
        } else {
            why = "\(targetLabel) has no API key in Settings"
        }
        NSLog("[OCR] \(imageURL.lastPathComponent): escalation (\(trigger.rawValue)) failed — \(why)")

        // A disagreement still has the first reader's text: keep it rather than fail a page that was read.
        if trigger == .disagreement { return first }
        if refused, !Task.isCancelled {
            return await OCRRefusalFallback.readRefusedPage(
                first, imageURL: imageURL, previousText: previousText, previousImageURL: previousImageURL,
                customPrompt: customPrompt, imageScale: imageScale, excluding: target, failedBefore: why)
        }
        let firstWhy = first.errorMessage ?? "\(firstLabel) returned no text (\(firstCode))."
        return OCRResult(text: nil, classification: nil,
                         errorMessage: "\(firstWhy) Escalated to \(targetLabel), which failed too — \(why)",
                         errorCode: exhaustedCode)
    }

    private static func key(for provider: LLMProvider) -> String? {
        if let keyOverride { return keyOverride(provider) }
        return KeychainHelper.load(account: provider.rawValue)
    }

    private static func visionWordCount(imageURL: URL, settings: VisionOCRSettings) async -> Int? {
        if let visionWordsOverride { return visionWordsOverride(imageURL) }
        guard let result = try? await VisionClient(settings: settings).ocr(imageURL: imageURL),
              let text = result.text else { return nil }
        return wordCount(text)
    }
}

/// Failure codes shared by the OCR clients, so every provider names the same failure the same way.
enum OCRFailureCode {
    /// The reply was cut off at the token limit: almost always a reply repeating itself (`difficulty.md`, FarmShare's
    /// 13 failures), never a transcription. Not auto-retried, since the same budget would cut it again.
    static let cutOff = "length"
    /// The reply came back but held no answer the client could read.
    static let unparsable = "unparsable"
}
