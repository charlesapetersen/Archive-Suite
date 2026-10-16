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
