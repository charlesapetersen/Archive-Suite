/// What rotation detection decided for a page: the clockwise correction (nil = keep the OCR model's own guess),
/// and whether the selected checks could settle its orientation.
public struct RotationVerdict: Sendable, Equatable {
    public var correction: Int?
    public var unsure: Bool
    public var comparativeVoteFailed: Bool

    public init(correction: Int?, unsure: Bool = false, comparativeVoteFailed: Bool = false) {
        self.correction = correction
        self.unsure = unsure
        self.comparativeVoteFailed = comparativeVoteFailed
    }
}

public enum RotationAgreement {
    /// The agreement rule (W46.rotation-default; Phase 4, `13-stage-rules/01-reading-copy.md`): Vision and PP-LCNet
    /// agreeing settle the page. Otherwise, or when Vision abstains, the measured cloud route answers (`cloud`, the
    /// comparative call via the gateway or OpenRouter), Vision's answer standing in when that call fails, as
    /// W46.rotation-routes scored "agree, else llmSingle (Vision if it abstains)". That stand-in is marked unsure, as
    /// the free rule marks a disagreement: the scored chain never met a failed call, and a disagreement is where Vision
    /// fails (measurement review 2026-11-11, P13-3). With no cloud route the page is left as it is (0, not the OCR
    /// model's guess) and marked unsure. PP-LCNet alone never turns a page: it flips right-to-left scripts.
    /// A build whose PP-LCNet does not load (`lcnetLoaded` false) runs Vision alone rather than leaving every page:
    /// each page is still marked unsure, since nothing checked it.
    public static func verdict(vision: Int?, lcnet: Int?, cloud: (@Sendable () async -> Int?)?,
                               lcnetLoaded: Bool = true) async -> RotationVerdict {
        if let vision, vision == lcnet { return RotationVerdict(correction: vision) }
        if !lcnetLoaded, cloud == nil { return RotationVerdict(correction: vision ?? 0, unsure: true) }
        if let cloud {
            if let c = await cloud() { return RotationVerdict(correction: c) }
            if let vision { return RotationVerdict(correction: vision, unsure: true) }
        }
        return RotationVerdict(correction: 0, unsure: true)
    }
}
