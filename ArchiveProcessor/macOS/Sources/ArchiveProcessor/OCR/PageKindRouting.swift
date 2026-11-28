import ArchiveCore
import Foundation

/// Which model reads a page, from its kind (W41.app-page-kind), split two ways (owner, 2026-11-24,
/// W49.proc-pipeline-prune-ok 2): a typed or printed page (forms, newspapers, clippings and registers with them) keeps
/// the run's own model; a handwritten page (and a mixed one) goes to the first of the model guide's handwritten picks
/// (`OCRPageGuidance`, W41.app-ocr-hierarchy) that the app offers and the user can run, else the run's model. The
/// former per-kind matrix and "Read handwriting on typed pages" are gone (the latter deferred to 2.0,
/// W46.kinds-mixed-truth). On Apple Vision the split stays on this Mac (W49.proc-kind-split-mac): a handwritten page goes
/// to the downloaded model that reads handwriting best, never to a paid one. Pure, so the self-test can walk every case
/// without a key.
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
        /// A typewritten or printed page sent to the handwritten kind's pick by the former "Read handwriting on typed
        /// pages" (W46.mixed-route-setting, removed 2026-11-24); kept so an older run's record still reads.
        case handwriting
        /// A free run's handwritten page whose reader on this Mac failed it (W49.proc-kind-split-mac); read by the run's
        /// own Apple Vision instead.
        case localFailed = "local_failed"

        /// The page leaves the run's model for a reader chosen for it (the kind's pick, the user's or the switch's).
        var routes: Bool { self == .kind || self == .override || self == .handwriting }
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
    /// route), in no order; the guide's order decides. A user override wins over everything. A sure handwritten page
    /// takes the handwritten kind's first runnable pick; every other page keeps the run's model.
    static func choose(kind: PageKind?, guidance: OCRPageGuidance?, available: Set<Candidate>,
                       runDefault: Candidate, override: Candidate? = nil) -> Choice {
        if let o = override { return Choice(provider: o.provider, modelID: o.modelID, reason: .override) }
        func keep(_ r: Reason) -> Choice { Choice(provider: runDefault.provider, modelID: runDefault.modelID, reason: r) }
        guard let kind, let guidance else { return keep(.unknown) }
        guard kind.confidence >= minimumConfidence else { return keep(.uncertain) }
        func firstPick(_ id: String) -> Candidate? {
            guard let entry = guidance.kinds.first(where: { $0.id == id }) else { return nil }
            for pick in entry.picks {
                // The maker's own key first, else the same model through OpenRouter (W41.app-openrouter-any).
                if let m = pick.appModel, let c = available.first(where: { $0.modelID == m })
                    ?? available.first(where: { $0.provider == .openrouter
                        && OpenRouterRoute.forModel($0.modelID)?.maker?.id == m }) { return c }
            }
            return nil
        }
        // The two-way split: typed and printed pages are the run's model's.
        guard kind.routingKind == .handwritten else { return keep(.same) }
        if runDefault.provider == .appleVision {
            // A free run: the downloaded reader with the best measured handwriting, if it reads it better than Vision.
            guard let c = bestLocal(available) else { return keep(.noPick) }
            return Choice(provider: c.provider, modelID: c.modelID, reason: .kind)
        }
        guard let c = firstPick(PageKindName.handwritten.rawValue) else { return keep(.noPick) }
        return c == runDefault ? keep(.same) : Choice(provider: c.provider, modelID: c.modelID, reason: .kind)
    }

    /// Of `available`, the model on this Mac with the highest measured handwriting NES above Apple Vision's; ties prefer
    /// an app-managed download over an external local server, then sort by id.
    static func bestLocal(_ available: Set<Candidate>) -> Candidate? {
        available.compactMap { c -> (Candidate, Double, Bool)? in
            guard c.provider == .appleVision, let pick = LocalModelRoute.pick(forModelID: c.modelID),
                  pick.handwrittenNES > LocalModelRoute.visionHandwrittenNES else { return nil }
            return (c, pick.handwrittenNES, ManagedOCRModel(rawValue: c.modelID) != nil)
        }
        .sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.2 != $1.2 { return $0.2 }
            return $0.0.modelID < $1.0.modelID
        }
        .first?.0
    }

    /// The readers on this Mac a free run can send pages to (W49.proc-kind-split-mac / W49.proc-kind-split-mac-fu):
    /// each app-managed model offered for this Mac's memory whose download has finished, plus the user's own loopback
    /// local server (LM Studio / Ollama / mlx-vlm) when its configured model ID is a measured pick. A candidate's
    /// provider is Apple Vision ("on this Mac"). Reads the disk/defaults: call it off a view body, as `keyedCandidates`.
    static func localCandidates(offered: [ManagedOCRModel] = ManagedOCRModel.offered(),
                                defaults d: UserDefaults = .standard) -> Set<Candidate> {
        var out = Set(offered.filter { managedGateway($0) != nil }.map { Candidate(provider: .appleVision, modelID: $0.rawValue) })
        if let ext = externalLocalServerGateway(d), ext.pick.handwrittenNES > LocalModelRoute.visionHandwrittenNES {
            out.insert(Candidate(provider: .appleVision, modelID: ext.gateway.modelID))
        }
        return out
    }

    /// Test seam: the gateway a managed model reads through, in place of its install (headless tests download nothing).
    nonisolated(unsafe) static var managedGatewayOverride: ((ManagedOCRModel) -> GatewayConfig?)?
    /// Test seam: the user's own local server gateway for headless tests.
    nonisolated(unsafe) static var externalLocalGatewayOverride: (() -> (pick: LocalModelRoute.Pick, gateway: GatewayConfig)?)?

    /// The gateway that reads with a downloaded model, or nil while it is not installed.
    static func managedGateway(_ m: ManagedOCRModel) -> GatewayConfig? {
        if let o = managedGatewayOverride { return o(m) }
        return GatewayConfig.managed(m)
    }

    /// The user's own local server (Settings › Advanced: gateway marked local, loopback URL, measured pick's model ID),
    /// available to a Vision run even while Apple Vision is the active Reader. Never escalates to a cloud model.
    static func externalLocalServerGateway(_ d: UserDefaults = .standard) -> (pick: LocalModelRoute.Pick, gateway: GatewayConfig)? {
        if let o = externalLocalGatewayOverride { return o() }
        guard d.bool(forKey: DefaultsKeys.gatewayLocalModel) else { return nil }
        let base = GatewayConfig.normalizedBaseURL(d.string(forKey: DefaultsKeys.gatewayBaseURL) ?? "")
        let modelID = (d.string(forKey: DefaultsKeys.gatewayModelID) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !modelID.isEmpty, LocalModelRoute.isLoopback(base),
              let pick = LocalModelRoute.pick(forModelID: modelID) else { return nil }
        let rawName = (d.string(forKey: DefaultsKeys.gatewayDisplayName) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let gateway = GatewayConfig(baseURL: base, modelID: modelID,
                                    displayName: rawName.isEmpty ? pick.displayName : rawName,
                                    inputCostPer1M: nil, outputCostPer1M: nil,
                                    localModel: true, localEscalates: nil, managedModel: nil)
        return (pick, gateway)
    }

    /// Resolves a local candidate's gateway: installed app-managed model first, else the user's own local server.
    static func localGateway(for modelID: String, defaults d: UserDefaults = .standard) -> GatewayConfig? {
        if let m = ManagedOCRModel(rawValue: modelID), let gw = managedGateway(m) { return gw }
        if let ext = externalLocalServerGateway(d), ext.gateway.modelID == modelID { return ext.gateway }
        return nil
    }

    /// Every built-in model of a provider the user has a key for, as candidates. Reads the Keychain: call it off a
    /// view body (once per refresh), never per render. Custom models are left out, as the cascade leaves them out:
    /// the guide names built-in ids, and a routed page needs a known price for the estimate.
    static func keyedCandidates(hasKey: (LLMProvider) -> Bool = { KeychainHelper.exists(account: $0.rawValue) })
        -> Set<Candidate> {
        var keyed: [LLMProvider: Bool] = [:]
        var out = Set<Candidate>()
        for m in OCRCascade.candidates {
            let has = keyed[m.provider] ?? hasKey(m.provider)
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
        /// Set for a model on this Mac (W49.proc-kind-split-mac): the page is read through this gateway.
        var gateway: GatewayConfig? = nil
        let record: PageReaderRecord
    }

    static func reader(_ entry: PageReaderPlan.Entry, provider: LLMProvider, model: LLMModel, apiKey: String,
                       thinkingLevel: ThinkingLevel?, imageScale: Double, sendPreviousImage: Bool = false,
                       contextCharCount: Int = 0) -> Reader {
        func price(_ m: LLMModel) -> Double {
            pagePrice(m, imageScale: imageScale, sendPreviousImage: sendPreviousImage, contextCharCount: contextCharCount)
        }
        func record(_ reason: Reason, _ p: LLMProvider, _ m: LLMModel, cost: Double? = nil) -> PageReaderRecord {
            PageReaderRecord(kind: entry.kind?.kind.rawValue, confidence: entry.kind?.confidence, reason: reason,
                             provider: p.rawValue, model: m.displayName, estimatedCost: cost,
                             replacedCost: cost == nil ? nil : price(model), readingKind: entry.kind?.readingKind)
        }
        let c = entry.choice
        let differs = c.provider != provider || c.modelID != model.id
        guard c.reason.routes, differs else {
            // A choice that is the run's own model is not a reroute, whatever chose it.
            let reason: Reason = c.reason.routes ? .same : c.reason
            return Reader(provider: provider, model: model, apiKey: apiKey, thinkingLevel: thinkingLevel,
                          record: record(reason, provider, model))
        }
        // W49.proc-kind-split-mac / W49.proc-kind-split-mac-fu: a free run's page never leaves this Mac, and only a
        // free run's goes to a model on it (app-managed download or the user's own local server). A removed download or
        // unconfigured server keeps the run's Vision (no_pick). The record names the reader as a gateway run on the
        // same model does (its name, then its id), and prices it at nothing.
        if provider == .appleVision || c.provider == .appleVision {
            guard provider == .appleVision,
                  let gateway = localGateway(for: c.modelID),
                  let target = Self.model(Candidate(provider: c.provider, modelID: c.modelID))
            else {
                return Reader(provider: provider, model: model, apiKey: apiKey, thinkingLevel: thinkingLevel,
                              record: record(.noPick, provider, model))
            }
            let local = PageReaderRecord(kind: entry.kind?.kind.rawValue, confidence: entry.kind?.confidence,
                                         reason: c.reason, provider: gateway.displayName, model: gateway.modelID,
                                         estimatedCost: 0, replacedCost: 0, readingKind: entry.kind?.readingKind)
            return Reader(provider: provider, model: target, apiKey: LocalModelRoute.placeholderKey, thinkingLevel: nil,
                          gateway: gateway, record: local)
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

    /// The built-in model a candidate names, or nil. A model on this Mac is free and named as Settings names it.
    static func model(_ c: Candidate) -> LLMModel? {
        if c.provider == .appleVision, let pick = ManagedOCRModel(rawValue: c.modelID)?.pick ?? LocalModelRoute.pick(forModelID: c.modelID) {
            return LLMModel(id: c.modelID, displayName: pick.displayName, provider: .appleVision,
                            supportsThinking: false, returnsMd: false, inputCostPer1M: 0, outputCostPer1M: 0,
                            batchDiscount: 1)
        }
        return OCRCascade.candidates.first { $0.provider == c.provider && $0.id == c.modelID }
    }

    /// How the page's reader reads in the run history and the file list: "Typewritten (93%) → Gemini 3.8 Flash".
    static func summary(kind: PageKind?, choice: Choice, modelName: String) -> String {
        let k = kind?.summary ?? "Kind not told"
        switch choice.reason {
        case .kind: return "\(k) → \(modelName)"
        case .same: return "\(k) → \(modelName), the run's model"
        case .uncertain: return "\(k), not sure → \(modelName), the run's model"
        case .unknown: return "\(k) → \(modelName), the run's model"
        case .noPick: return "\(k), no pick you can run → \(modelName), the run's model"
        case .override: return "\(k) → \(modelName), chosen by you"
        case .handwriting: return "\(k) → \(modelName), for its handwriting"
        case .localFailed: return "\(k) → \(modelName), the run's model, after the reader on this Mac failed"
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

    /// Seconds the plan's pages on a model on this Mac take on their dedicated one-worker lane (W49.proc-kind-split-mac /
    /// W49.proc-kind-split-mac-fu): one page at a time, at each model's measured pace (`LocalModelRoute.secondsPerPage`).
    var localSeconds: Double {
        pages.values.reduce(0) { total, entry in
            guard entry.choice.reason.routes, entry.choice.provider == .appleVision,
                  let pick = LocalModelRoute.pick(forModelID: entry.choice.modelID) else { return total }
            return total + pick.secondsPerPage
        }
    }

    /// Number of pages routed to a model on this Mac (excluded from Vision's lane count so they are counted once).
    var localPageCount: Int {
        pages.values.reduce(0) { count, entry in
            guard entry.choice.reason.routes, entry.choice.provider == .appleVision,
                  LocalModelRoute.pick(forModelID: entry.choice.modelID) != nil else { return count }
            return count + 1
        }
    }

    /// True when `url` is scheduled on the free Mac split's one-worker local-model lane rather than Vision's workers.
    func routesToLocal(_ url: URL, runProvider: LLMProvider, runModelID: String) -> Bool {
        guard runProvider == .appleVision, let entry = entry(for: url) else { return false }
        let c = entry.choice
        return c.reason.routes && c.provider == .appleVision && c.modelID != runModelID
            && LocalModelRoute.pick(forModelID: c.modelID) != nil
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

    /// The classifier's hand for a tagged clipping; `kind` stays clippings for layout and sidecars.
    var readingKind: PageKindName? = nil

    var headerKind: OCRPageKind? { (readingKind ?? kind.flatMap(PageKindName.init(rawValue:)))?.headerKind }

    /// True when the page was read by a model other than the run's (the guide's pick or the user's choice): only
    /// then is a price recorded.
    var isRouted: Bool { reason.routes && estimatedCost != nil }
}
