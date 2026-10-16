import Foundation

/// Which model reads a page, from its kind (W41.app-page-kind): the first of the model guide's picks for that kind
/// (`OCRPageGuidance`, W41.app-ocr-hierarchy) that the app offers and the user can run, else the run's own model.
/// Pure, so the self-test can walk every case without a key.
enum PageKindRouting {
    /// Below this, the classifier's call is not trusted and the page keeps the run's model. Not measured: the bench's
    /// probabilities come from weights fitted on the very pages they were scored on, so no held-out calibration
    /// exists yet. 0.8 keeps a page from moving on a call the classifier itself rates near a coin flip between two
    /// kinds; refit and recalibrate as labelled pages grow (kind-classifier.md §6).
    static let minimumConfidence = 0.8

    /// Why a page is read by the model it is read by. Persisted in the run's per-page record: append cases only.
    enum Reason: String, Codable, Sendable, Equatable {
        /// The guide's pick for the page's kind.
        case kind
        /// The classifier was not sure enough; the run's model.
        case uncertain
        /// No kind could be told (an older macOS, an unreadable image, no weights); the run's model.
        case unknown
        /// None of the guide's picks for the kind can be run here (no key, not offered); the run's model.
        case noPick = "no_pick"
        /// The guide's pick is the run's model anyway.
        case same
        /// The user chose the reader for this page or batch.
        case override
    }

    struct Choice: Codable, Sendable, Equatable {
        let provider: LLMProvider
        let modelID: String
        let reason: Reason
    }

    /// One model that can read pages in this run: its provider and id.
    struct Candidate: Sendable, Hashable {
        let provider: LLMProvider
        let modelID: String
    }

    /// The page's reader. `available` is every built-in model the user can run now (a keyed provider, or a local
    /// route), in no order; the guide's order decides. A user override wins over everything.
    static func choose(kind: PageKind?, guidance: OCRPageGuidance?, available: Set<Candidate>,
                       runDefault: Candidate, override: Candidate? = nil) -> Choice {
        if let o = override { return Choice(provider: o.provider, modelID: o.modelID, reason: .override) }
        func keep(_ r: Reason) -> Choice { Choice(provider: runDefault.provider, modelID: runDefault.modelID, reason: r) }
        guard let kind, let guidance else { return keep(.unknown) }
        guard kind.confidence >= minimumConfidence else { return keep(.uncertain) }
        guard let entry = guidance.kinds.first(where: { $0.id == kind.kind }) else { return keep(.noPick) }
        for pick in entry.picks {
            guard let id = pick.appModel, let c = available.first(where: { $0.modelID == id }) else { continue }
            return c == runDefault ? keep(.same) : Choice(provider: c.provider, modelID: c.modelID, reason: .kind)
        }
        return keep(.noPick)
    }

    /// Every built-in model of a provider the user has a key for, as candidates. Reads the Keychain: call it off a
    /// view body (once per refresh), never per render. Custom models are left out, as the cascade leaves them out:
    /// the guide names built-in ids, and a routed page needs a known price for the estimate.
    static func keyedCandidates(key: (LLMProvider) -> String? = { KeychainHelper.load(account: $0.rawValue) })
        -> Set<Candidate> {
        var keyed: [LLMProvider: Bool] = [:]
        var out = Set<Candidate>()
        for m in OCRCascade.candidates {
            let has = keyed[m.provider] ?? { let k = key(m.provider); return k.map { !$0.isEmpty } ?? false }()
            keyed[m.provider] = has
            if has { out.insert(Candidate(provider: m.provider, modelID: m.id)) }
        }
        return out
    }

    /// The reader `performOCRCall` uses for one planned page, and what the page's record says. A routed page whose
    /// model is no longer built in, or whose provider has no key now, keeps the run's model and records `.noPick`. A
    /// routed model reads at the run's Thinking level when it supports one, else its default. Prices count the
    /// context and previous image the page is actually sent with (Tier-2 review).
    struct Reader {
        let provider: LLMProvider
        let model: LLMModel
        let apiKey: String
        let thinkingLevel: ThinkingLevel?
        let record: PageReaderRecord
    }

    static func reader(_ entry: PageReaderPlan.Entry, provider: LLMProvider, model: LLMModel, apiKey: String,
                       thinkingLevel: ThinkingLevel?, imageScale: Double, sendPreviousImage: Bool = false,
                       contextCharCount: Int = 0) -> Reader {
        func price(_ m: LLMModel) -> Double {
            pagePrice(m, imageScale: imageScale, sendPreviousImage: sendPreviousImage, contextCharCount: contextCharCount)
        }
        func record(_ reason: Reason, _ p: LLMProvider, _ m: LLMModel, cost: Double? = nil) -> PageReaderRecord {
            PageReaderRecord(kind: entry.kind?.kind, confidence: entry.kind?.confidence, reason: reason,
                             provider: p.rawValue, model: m.displayName, estimatedCost: cost,
                             replacedCost: cost == nil ? nil : price(model))
        }
        let c = entry.choice
        let differs = c.provider != provider || c.modelID != model.id
        guard c.reason == .kind || c.reason == .override, differs else {
            // A choice that is the run's own model is not a reroute, whatever chose it.
            let reason: Reason = c.reason == .kind || c.reason == .override ? .same : c.reason
            return Reader(provider: provider, model: model, apiKey: apiKey, thinkingLevel: thinkingLevel,
                          record: record(reason, provider, model))
        }
        guard let target = Self.model(Candidate(provider: c.provider, modelID: c.modelID)),
              let key = c.provider == provider && !apiKey.isEmpty ? apiKey : runKey(for: c.provider), !key.isEmpty
        else {
            return Reader(provider: provider, model: model, apiKey: apiKey, thinkingLevel: thinkingLevel,
                          record: record(.noPick, provider, model))
        }
        return Reader(provider: target.provider, model: target, apiKey: key,
                      thinkingLevel: target.supportsThinking ? thinkingLevel : nil,
                      record: record(c.reason, target.provider, target, cost: price(target)))
    }

    /// One page's OCR price on a model, with the context and previous image it is sent with.
    static func pagePrice(_ m: LLMModel, imageScale: Double, sendPreviousImage: Bool, contextCharCount: Int) -> Double {
        CostEstimator.estimate(fileCount: 1, model: m, enableTagging: false, sendPreviousImage: sendPreviousImage,
                               contextCharCount: contextCharCount, imageScale: imageScale).ocrCost
    }

    /// A provider's key at read time; the cascade's test seam replaces the Keychain in the headless tests.
    static func runKey(for provider: LLMProvider) -> String? {
        if let o = OCRCascade.keyOverride { return o(provider) }
        return KeychainHelper.load(account: provider.rawValue)
    }

    /// The built-in model a candidate names, or nil.
    static func model(_ c: Candidate) -> LLMModel? {
        OCRCascade.candidates.first { $0.provider == c.provider && $0.id == c.modelID }
    }

    /// How the page's reader reads in the run history and the file list: "Typewritten (93%) → Gemini 3.8 Flash".
    static func summary(kind: PageKind?, choice: Choice, modelName: String) -> String {
        let k = kind.map { "\(PageKind.label($0.kind)) (\(Int(($0.confidence * 100).rounded()))%)" } ?? "Kind not told"
        switch choice.reason {
        case .kind: return "\(k) → \(modelName)"
        case .same: return "\(k) → \(modelName), the run's model"
        case .uncertain: return "\(k), not sure → \(modelName), the run's model"
        case .unknown: return "\(k) → \(modelName), the run's model"
        case .noPick: return "\(k), no pick you can run → \(modelName), the run's model"
        case .override: return "\(k) → \(modelName), chosen by you"
        }
    }
}

/// The readers frozen into one run (W41.app-page-kind): for each page the user saw in the file list, its kind and the
/// reader chosen for it. Keyed by the source file's standardized path, which is the image URL `performOCRCall`
/// receives for an image file; a multi-page PDF's pages are temporary images and are not in the plan, so they keep
/// the run's model. Empty = every page is read by the run's model, as before this item.
struct PageReaderPlan: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let kind: PageKind?
        let choice: PageKindRouting.Choice
    }

    var pages: [String: Entry] = [:]

    static let empty = PageReaderPlan()

    var isEmpty: Bool { pages.isEmpty }

    static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    func entry(for url: URL) -> Entry? { pages[Self.key(url)] }

    /// What the plan adds to the run model's OCR estimate: for each page read by another model, that model's page
    /// price less the run model's, each with the run's context and previous image (`PageKindRouting.pagePrice`).
    /// Negative when the guide sends pages to a cheaper model.
    func ocrCostDelta(runModel: LLMModel, imageScale: Double, sendPreviousImage: Bool = false,
                      contextCharCount: Int = 0) -> Double {
        func price(_ m: LLMModel) -> Double {
            PageKindRouting.pagePrice(m, imageScale: imageScale, sendPreviousImage: sendPreviousImage,
                                      contextCharCount: contextCharCount)
        }
        let base = price(runModel)
        var prices: [PageKindRouting.Candidate: Double] = [:]
        var delta = 0.0
        for entry in pages.values where entry.choice.modelID != runModel.id || entry.choice.provider != runModel.provider {
            let c = PageKindRouting.Candidate(provider: entry.choice.provider, modelID: entry.choice.modelID)
            guard let p = prices[c] ?? PageKindRouting.model(c).map(price) else { continue }
            prices[c] = p
            delta += p - base
        }
        return delta
    }

    /// Pages per reader the plan sends away from the run's model, for the cost caption: [(model, pages)], most first.
    func routedCounts(runModel: LLMModel) -> [(LLMModel, Int)] {
        var counts: [PageKindRouting.Candidate: Int] = [:]
        for entry in pages.values where entry.choice.modelID != runModel.id || entry.choice.provider != runModel.provider {
            counts[PageKindRouting.Candidate(provider: entry.choice.provider, modelID: entry.choice.modelID), default: 0] += 1
        }
        return counts.compactMap { c, n in PageKindRouting.model(c).map { ($0, n) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.displayName < $1.0.displayName }
    }
}

/// What a page's record says about its reader (W41.app-page-kind): the kind, how sure, why this reader, and the
/// reader that read it first. Set only on a page the run's plan named; `nil` = the page was not classified.
struct PageReaderRecord: Codable, Equatable, Sendable {
    let kind: String?
    let confidence: Double?
    let reason: PageKindRouting.Reason
    /// The first reader, as the PDF header names it: provider rawValue and model display name.
    let provider: String
    let model: String
    /// USD at the reader's standard page rate, and the run model's rate it replaced; set only when the page went to
    /// a model other than the run's. The run history adds the difference to the run's estimate.
    var estimatedCost: Double? = nil
    var replacedCost: Double? = nil

    /// True when the page was read by a model other than the run's (the guide's pick or the user's choice): only
    /// then is a price recorded.
    var isRouted: Bool { (reason == .kind || reason == .override) && estimatedCost != nil }
}
