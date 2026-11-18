import Foundation

// MARK: - How far a field's value can be trusted (W40.reader-field-status, SPEC/tag-format.md §"Field checks")
//
// Every app shows a bibliographic or container value with the same three states: checked by the user; unchecked,
// from a route the bench measured clearing the fill rule; unchecked, lower confidence (below the rule, or never
// measured). The cut is the fill rule the Processor already writes item fields by (Wilson lower bound 0.85, point
// 0.90, 40 owner-checked pairs; `ItemFieldPolicy`), and every figure below is a measured one, cited to its result.

/// A field's state, in the order the Inspector ranks them.
public enum FieldCheckLevel: String, Sendable, Equatable, CaseIterable {
    /// The user has checked the value, or set it.
    case checked
    /// Not checked; its route clears the fill rule.
    case unchecked
    /// Not checked; its route is below the fill rule or was never measured.
    case lowerConfidence

    /// Always shown beside the colour, so the state never rests on colour alone.
    public var label: String {
        switch self {
        case .checked: return "Checked"
        case .unchecked: return "Unchecked"
        case .lowerConfidence: return "Unchecked, lower confidence"
        }
    }

    /// The SF Symbol drawn with the label: a different shape for each state.
    public var symbol: String {
        switch self {
        case .checked: return "checkmark.circle.fill"
        case .unchecked: return "circle.dashed"
        case .lowerConfidence: return "exclamationmark.triangle.fill"
        }
    }
}

/// A value's state, where it came from, and the measured figure behind that, for display.
public struct FieldStatus: Sendable, Equatable {
    public var level: FieldCheckLevel
    /// Where the value came from, in a few words ("Processor, item-field call").
    public var source: String
    /// The measured figure for this source, or why there is none.
    public var measured: String

    public init(level: FieldCheckLevel, source: String, measured: String) {
        self.level = level
        self.source = source
        self.measured = measured
    }

    /// The one-line explanation for a tooltip or an accessibility value.
    public var detail: String {
        level == .checked ? "\(level.label). \(source)." : "\(level.label). \(source). \(measured)"
    }
}

public enum FieldStatusPolicy {
    /// The fill rule, as `ItemFieldPolicy` states it (`segbench-results/item-fields-score.md`).
    public static let fillRule = "the fill rule is a Wilson lower bound of 0.85 and a point of 0.90 on 40 owner-checked pairs"

    /// A page-2 item field. Each one written is from the Processor's item-field call (Gemini 3.7 Flash, image
    /// prompt), which fills a field only where it cleared the rule. The figures are the stratified precision the
    /// verdict rests on (`item-fields-score.md`, "Every route, field by field" and "The verdict"). Title is below the
    /// rule; it has a line but is not written, so one present came from elsewhere.
    public static func itemField(_ field: CheckableField, checked: Bool) -> FieldStatus {
        let source = "Read by the Processor’s item-field call"
        let figure: String?
        switch field {
        case .documentKind: figure = "0.96 [0.86, 0.98] on the bench"
        case .byline: figure = "0.97 [0.87, 1.00] on the bench"
        case .publication: figure = "0.94 [0.88, 0.94] on the bench"
        case .publicationDate: figure = "0.98 [0.88, 0.98] on the bench"
        case .recipientPlace: figure = "1.00 [0.92, 1.00] on the bench"
        case .title, .date, .sentWith: figure = nil
        }
        if checked { return FieldStatus(level: .checked, source: source, measured: figure ?? "") }
        if let figure {
            return FieldStatus(level: .unchecked, source: source, measured: "Clears the fill rule: \(figure).")
        }
        return FieldStatus(level: .lowerConfidence, source: source,
                           measured: "Below the fill rule: title is 0.91 [0.83, 0.94] on the bench.")
    }

    /// The item's own date, from its tags. `evidence` is the page-2 `Date evidence:` line, which the Processor's
    /// dating route writes for a year not explicit in the document's text; with none, the date is explicit in the
    /// text or its source was not recorded (a hand-set tag writes no line). No class of the route clears the rule
    /// (`segbench-results/date-route-pipeline.md`, "By evidence class", Gemini 3.7 Flash on the owner's documents).
    public static func date(checked: Bool, evidence: String?) -> FieldStatus {
        let cls = evidence.flatMap { $0.split(separator: ";", maxSplits: 1).first }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let source: String, figure: String
        switch cls {
        case "image":
            source = "Read off the page image by the Processor’s dating route"
            figure = "10 of 12 exact"
        case "estimate":
            source = "Estimated from a neighbouring document by the Processor’s dating route"
            figure = "35 of 51 exact"
        case "inherited":
            source = "Inherited from the covering letter by the Processor’s dating route"
            figure = "not measured on its own"
        case .some:
            source = "From the Processor’s dating route"
            figure = "not measured for this evidence"
        case nil:
            source = "From the document’s text, or not recorded"
            figure = "an explicit year from the text is 139 of 158 exact"
        }
        if checked { return FieldStatus(level: .checked, source: source, measured: "") }
        return FieldStatus(level: .lowerConfidence, source: source, measured: "Below the fill rule: \(figure).")
    }

    /// The covering letter's date (`Sent With …`). The route's dates are not measured apart from the own date's.
    public static func sentWith(checked: Bool) -> FieldStatus {
        let source = "From the tags; the source is not recorded"
        if checked { return FieldStatus(level: .checked, source: source, measured: "") }
        return FieldStatus(level: .lowerConfidence, source: source, measured: "Not measured on its own.")
    }

    /// A container field (`SPEC/containers.md`), in a run of `level` (nil for the directory's own values). A user
    /// value is checked. Of the label reads, only the box number Vision + parser reads off a box photo clears the rule
    /// (70 of 71 right on the truth set's upright photos; `segbench-results/ct-read.md`, carry-forward); its box number
    /// off a folder photo is 28 of 35, and every other field and reader is wrong or empty on a quarter or more of the
    /// filled cells, or not read at all. Folder names (the level map) are measured only on synthetic trees. A value's
    /// own `confidence` is a display hint, shown but never ranked.
    public static func container(_ value: ContainerValue, field: ContainerField, level: ContainerLevel?) -> FieldStatus {
        let hint = value.confidence.map { String(format: " The reader gave %.2f.", $0) } ?? ""
        switch value.source {
        case .user:
            return FieldStatus(level: .checked, source: "Set or confirmed by the user", measured: "")
        case .label:
            let by = value.reader.map { " (\($0))" } ?? ""
            let source = "Read from a box or folder label\(by)"
            if field == .container, level == .box, value.reader?.lowercased() == visionParser {
                return FieldStatus(level: .unchecked, source: source,
                                   measured: "Clears the fill rule: 70 of 71 box numbers right on upright box photos.\(hint)")
            }
            return FieldStatus(level: .lowerConfidence, source: source,
                               measured: "Below the fill rule for this field and reader.\(hint)")
        case .path:
            return FieldStatus(level: .lowerConfidence, source: "From the folder names, by the level map",
                               measured: "Not measured on the owner’s folders.\(hint)")
        }
    }

    /// The label reader's name in a container value (`ContainerValue.reader`).
    public static let visionParser = "vision+parser"
}
