import Foundation

// MARK: - Who segments a run (W36.seg-opt-review)
//
// `TaggingMode` answers who tags; `SegmentationApproach` answers who segments
// (execution-plans/segmentation/04-options-build.md Part 3 §1). This file joins the two, and holds the pure
// half of the review of flagged boundaries (§5): the gaps the user is asked about, their answers, and the
// classifications those make. The pipeline half is `OCRProcessor+WindowSegmentation.swift`.

/// How one run's boundaries are decided, from its tagging mode and its segmentation approach.
enum SegmentationPlan: Equatable, Sendable {
    /// No segment-based tagging (no tagging, or copy-source): the approach is not used. A run with collection
    /// segmentation on still gets the full review sheet, as before.
    case noTagging
    /// `automatic` + `manual`: the user segments in the full review sheet, which starts from the OCR model's own
    /// per-page tags, as the app did before the window segmenter. Decided by W36.seg-opt-review (2026-10-11),
    /// because §1 left it open: no screen exists where the user segments and the model then tags everything, so
    /// keeping the sheet the `automatic` mode always had is the one choice that removes no workflow.
    case perPageReview
    /// `autoDate` or `human` + `manual`: the user segments and tags in the combined window
    /// (`ManualSegmentTagView`), the model filling each date when `autoDate`.
    case manualWindow(autoDate: Bool)
    /// Any other approach: the window segmenter proposes, the user answers every flagged gap, then skims the
    /// whole run in the review sheet.
    case windows(SegmentationApproach)

    static func resolve(tagging: TaggingMode, approach: SegmentationApproach) -> SegmentationPlan {
        switch tagging {
        case .none, .copySource:
            return .noTagging
        case .automatic:
            return approach.proposesBoundaries ? .windows(approach) : .perPageReview
        case .autoDate, .human:
            return approach.proposesBoundaries ? .windows(approach) : .manualWindow(autoDate: tagging == .autoDate)
        }
    }

    /// Whether the user tags in the combined segment-and-tag window (and with auto dates when true), or nil when
    /// the run is already segmented and goes to the per-document tagging sheet. Live Capture's pre-grouped runs
    /// keep what they always did whatever the approach: `human` in the combined window, `autoDate` on the
    /// phone's groups as they are.
    func combinedWindow(tagging: TaggingMode, preGrouped: Bool) -> Bool? {
        if preGrouped { return tagging == .human ? false : nil }
        if case .manualWindow(let autoDate) = self { return autoDate }
        return nil
    }

    /// The OCR model's own per-page segmentation is what this plan starts from (only then do its context
    /// options, such as sending the previous page's image, matter).
    var usesPerPageClassifier: Bool { self == .perPageReview }

    /// The full review sheet offers New document / Continuation.
    var reviewShowsDocumentClasses: Bool {
        switch self {
        case .perPageReview, .windows: return true
        case .noTagging, .manualWindow: return false
        }
    }
}

// MARK: - The flagged pass

/// The user's answer to one flagged gap (§5): Keep accepts the proposal, Split makes page n+1 start a document,
/// Join makes it continue page n.
enum FlaggedGapAnswer: String, Sendable, Codable, CaseIterable {
    case keep, split, join

    func decision(proposed: GapDecision) -> GapDecision {
        switch self {
        case .keep: return proposed
        case .split: return .new
        case .join: return .continue
        }
    }
}

/// One flagged gap as the pass shows it: page n beside page n+1.
struct FlaggedGapItem: Identifiable, Equatable, Sendable {
    /// The gap's index in the run's page list (`WindowStagePages`), between `pages[id]` and `pages[id + 1]`.
    let id: Int
    let leftURL: URL
    let rightURL: URL
    let leftRotation: Int
    let rightRotation: Int
    let proposal: GapDecision
    let confidence: Double
    let cue: String
    var answer: FlaggedGapAnswer?

    var decision: GapDecision? { answer?.decision(proposed: proposal) }

    /// The proposal as the user reads it.
    var proposalText: String {
        proposal == .new ? "New document starts here" : "Same document continues"
    }

    /// The confidence in words. Every flagged gap is at or below its approach's level, so it is low or worse;
    /// 0 means a voter gave no answer.
    var confidenceText: String {
        if confidence <= 0 { return "no answer from the model" }
        return confidence < 0.7 ? "very low confidence" : "low confidence"
    }

    /// The model's cue, shortened for the line above the pages.
    var shortCue: String {
        let c = cue.trimmingCharacters(in: .whitespacesAndNewlines)
        return c.count > 160 ? String(c.prefix(160)) + "…" : c
    }
}

/// The pages a run's windows cover: every file not removed, in run order, with its job index.
struct WindowStagePages: Equatable, Sendable {
    let fileIndices: [Int]
    let urls: [URL]
    let photoKinds: [PhotoKind?]
}

enum FlaggedReview {
    /// The gaps to ask about, in run order, with any answer already recorded for this run (`prior`, keyed by
    /// the path of the page after the gap, so a resume that sees the same pages does not ask again).
    static func items(proposals: [GapProposal], pages: WindowStagePages, rotations: [Int],
                      prior: [String: FlaggedGapAnswer] = [:]) -> [FlaggedGapItem] {
        proposals.filter { $0.flagged && !$0.fixed && $0.gap + 1 < pages.urls.count }.map { p in
            FlaggedGapItem(id: p.gap, leftURL: pages.urls[p.gap], rightURL: pages.urls[p.gap + 1],
                           leftRotation: p.gap < rotations.count ? rotations[p.gap] : 0,
                           rightRotation: p.gap + 1 < rotations.count ? rotations[p.gap + 1] : 0,
                           proposal: p.decision, confidence: p.confidence, cue: p.cue,
                           answer: prior[pages.urls[p.gap + 1].path])
        }
    }

    /// "Done" is enabled only when every flagged gap has an answer: the figures assume each one is checked.
    static func isComplete(_ items: [FlaggedGapItem]) -> Bool { items.allSatisfy { $0.answer != nil } }

    /// The answers to record in the run's manifest, keyed as `items(prior:)` reads them.
    static func answersByPage(_ items: [FlaggedGapItem]) -> [String: FlaggedGapAnswer] {
        Dictionary(items.compactMap { i in i.answer.map { (i.rightURL.path, $0) } }, uniquingKeysWith: { $1 })
    }

    /// Each page's classification, from the proposals and the user's answers: a label photo stays a label, the
    /// first page and every page after a `new` gap starts a document, any other page continues one.
    static func classifications(proposals: [GapProposal], photoKinds: [PhotoKind?],
                                answers: [FlaggedGapItem]) -> [DocumentClassification] {
        let byGap = Dictionary(answers.compactMap { i in i.decision.map { (i.id, $0) } }, uniquingKeysWith: { $1 })
        let decisions = Dictionary(proposals.map { ($0.gap, byGap[$0.gap] ?? $0.decision) },
                                   uniquingKeysWith: { $1 })
        return photoKinds.indices.map { k in
            switch photoKinds[k] {
            case .box: return .boxLabel
            case .folder: return .folderLabel
            case nil:
                guard k > 0 else { return .documentStart }
                return (decisions[k - 1] ?? .new) == .new ? .documentStart : .documentContinuation
            }
        }
    }

    /// The run's count line (§5): "37 checked, 6 changed". Kept in memory only and never sent anywhere.
    static func summary(_ items: [FlaggedGapItem]) -> String? {
        guard !items.isEmpty else { return nil }
        let changed = items.filter { $0.answer != nil && $0.decision != $0.proposal }.count
        return "\(items.count) boundar\(items.count == 1 ? "y" : "ies") checked, \(changed) changed"
    }

    /// The note at the top of the skim (§5), from the shipped figures: "About 1 in 120 pages may still be
    /// wrong without having been flagged; a skim catches them."
    static func skimNote(_ approach: SegmentationApproach, options: SegmentationOptions?) -> String {
        guard let f = options?.approach(approach)?.figures?.test else {
            return "Some boundaries may still be wrong without having been flagged; a skim catches them."
        }
        guard f.unflaggedErrorsPer500Pages > 0 else {
            return "No unflagged errors were found in \(f.pages) test pages, but your material may differ; a skim catches them."
        }
        let oneIn = SegmentationRow.twoSignificant(500 / f.unflaggedErrorsPer500Pages)
        return "About 1 in \(oneIn) pages may still be wrong without having been flagged; a skim catches them."
    }
}

// MARK: - Transports for a run

enum WindowStageTransport {
    struct Missing: Error, Equatable, CustomStringConvertible {
        let description: String
    }

    /// The transport for an approach's voters, from what the user has: by API key where there is one, else Claude
    /// through the user's own `claude`; with both, Claude goes the way `route` says (the chooser asks only then).
    /// `gate` meters and pauses the `claude` calls.
    static func make(_ spec: ApproachSpec, keys: [WindowProvider: String], claudeBinary: String?,
                     route: ClaudeRoute = .apiKey, gate: PlanRunGate? = nil, http: APIWindowTransport.HTTP? = nil)
        -> Result<any WindowTransport, Missing> {
        var routes: [WindowProvider: any WindowTransport] = [:]
        var api = APIWindowTransport(keys: keys.filter { !$0.value.isEmpty })
        if let http { api.http = http }
        for p in Set(spec.voters.map(\.provider)) {
            let byPlan = p == .anthropic && claudeBinary != nil && (route == .plan || (keys[p] ?? "").isEmpty)
            if byPlan, let claudeBinary {
                routes[p] = LocalAgentWindowTransport(binaryPath: claudeBinary, gate: gate)
            } else if let k = keys[p], !k.isEmpty {
                routes[p] = api
            } else {
                return .failure(Missing(description: p == .anthropic
                    ? "Claude needs an Anthropic API key or a signed-in claude."
                    : "\(p == .gemini ? "Gemini" : "ChatGPT") needs an API key."))
            }
        }
        return .success(RoutingWindowTransport(routes: routes))
    }

    /// Reads the Keychain and looks for `claude`. Never call it from a view body.
    static func current(_ spec: ApproachSpec, defaults: UserDefaults = .standard, gate: PlanRunGate? = nil)
        -> Result<any WindowTransport, Missing> {
        var keys: [WindowProvider: String] = [:]
        for p in Set(spec.voters.map(\.provider)) {
            let account: LLMProvider = p == .anthropic ? .anthropic : p == .gemini ? .gemini : .openai
            keys[p] = KeychainHelper.load(account: account.rawValue) ?? ""
        }
        let tool = defaults.string(forKey: DefaultsKeys.localAgentTool).flatMap(LocalAgentTool.init(rawValue:))
        let override = tool == .claude ? (defaults.string(forKey: DefaultsKeys.localAgentBinaryPath) ?? "") : ""
        return make(spec, keys: keys,
                    claudeBinary: LocalAgentClient.resolveBinaryPath(tool: .claude, override: override),
                    route: ClaudeRoute.stored(defaults), gate: gate)
    }
}
