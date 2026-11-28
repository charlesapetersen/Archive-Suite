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
        level == .checked || measured.isEmpty ? "\(level.label). \(source)." : "\(level.label). \(source). \(measured)"
    }
}

public enum FieldStatusPolicy {
    /// The fill rule, as `ItemFieldPolicy` states it (`segbench-results/item-fields-score.md`).
    public static let fillRule = "the fill rule is a Wilson lower bound of 0.85 and a point of 0.90 on 40 owner-checked pairs"

    /// The evidence route recorded by the Processor's Mac item-field extractor (`ItemFieldExtractor.macRoute`).
    /// Shared across Processor and Reader so catalogue-filed Mac item fields carry their lower-confidence status.
    public static let macItemFieldsRoute = "This Mac · Qwen3-VL 8B and Qwen3.5 4B"

    /// Status of a catalogue-filed item field (`CatalogueRecord.Field`) for `documentKind`, `title`, `byline`,
    /// `publication`, `publicationDate` and `recipientPlace` (`W49.reader-catalogue-field-status`).
    /// A `model` value whose active `item-fields` evidence route is `macItemFieldsRoute` is lower confidence until
    /// checked (owner call 23). A `model` value without active `item-fields` evidence (such as a tagging-call
    /// fallback) is unmeasured and therefore lower confidence until checked.
    /// Returns nil for unassessed, cleared, or unchecked non-model fields.
    public static func catalogueItemField<V: Decodable & Sendable>(
        _ field: CheckableField,
        record: CatalogueRecord.Field<V>?
    ) -> FieldStatus? {
        guard let record, case .value = record.current else { return nil }
        switch record.origin {
        case "user":
            return record.isChecked
                ? FieldStatus(level: .checked, source: "Set by the user", measured: "")
                : nil
        case "model":
            let activeItemFields = record.evidence.filter {
                $0.source == "item-fields"
                    && ($0.supportsRevision == nil || $0.supportsRevision == record.fieldRevision)
            }
            if activeItemFields.contains(where: { $0.route == macItemFieldsRoute }) {
                return itemField(field, checked: record.isChecked, lowerConfidence: true)
            }
            if !activeItemFields.isEmpty {
                return itemField(field, checked: record.isChecked, lowerConfidence: false)
            }
            let source = "From the Processor’s tagging call"
            return record.isChecked
                ? FieldStatus(level: .checked, source: source, measured: "")
                : FieldStatus(level: .lowerConfidence, source: source, measured: "Not measured as an item field.")
        case "imported":
            return record.isChecked
                ? FieldStatus(level: .checked, source: "Imported and checked by the user", measured: "")
                : nil
        default:
            return nil
        }
    }

    /// A page-2 item field. The gateway's Gemini 3.7 Flash image prompt fills fields that cleared the fill rule.
    /// Its tooltips show those stratified scores, including title's last look (W47.item-fields-title).
    /// The Mac suggestions explicitly carry lower confidence and show the separate complete-value rescore
    /// in `item-fields-score.md`. Document and enclosure dates use their own status policy.
    public static func itemField(_ field: CheckableField, checked: Bool, lowerConfidence: Bool = false) -> FieldStatus {
        if lowerConfidence {
            let model: String
            let figure: String
            // Complete-value estimates from the owner checks on cached in-process replies. See item-fields-score.md.
            switch field {
            case .documentKind:
                model = "Qwen3-VL 8B reading page images and Vision text"
                figure = "Exact kind: 76% (76 owner-checked fills). Bench interval: 62–84%."
            case .byline:
                model = "Qwen3-VL 8B reading page images and Vision text"
                figure = "Complete byline: 83% estimated over 74 of 81 scored fills (41 owner-checked). "
                    + "Across all scored fills: 62–92%, including 6 outside the owner check sample."
            case .publicationDate:
                model = "Qwen3.5 4B reading Vision text"
                figure = "Full issue date: 70% estimated over 66 of 72 scored fills (31 owner-checked). "
                    + "Across all scored fills: 48–85%, including 2 outside the owner check sample."
            default:
                return FieldStatus(level: checked ? .checked : .lowerConfidence,
                                   source: "Read on the Processor’s Mac", measured: "")
            }
            return FieldStatus(level: checked ? .checked : .lowerConfidence, source: "Read on the Processor’s Mac by " + model,
                               measured: "Estimated from bench replies run in-process. " + figure)
        }
        let source = "Read by the Processor’s item-field call"
        let figure: String?
        switch field {
        case .documentKind: figure = "0.96 [0.86, 0.98] on the bench"
        case .byline: figure = "0.97 [0.87, 1.00] on the bench"
        case .publication: figure = "0.94 [0.88, 0.94] on the bench"
        case .publicationDate: figure = "0.98 [0.88, 0.98] on the bench"
        case .recipientPlace: figure = "1.00 [0.92, 1.00] on the bench"
        case .title: figure = "0.91 [0.86, 0.94] on the bench"
        case .date, .sentWith, .sender, .recipient, .sendingPlace: figure = nil
        }
        if checked { return FieldStatus(level: .checked, source: source, measured: figure ?? "") }
        if let figure {
            return FieldStatus(level: .unchecked, source: source, measured: "Clears the fill rule: \(figure).")
        }
        return FieldStatus(level: .lowerConfidence, source: source,
                           measured: "Not measured as an item field.")
    }

    /// W49.reader-sender-row-check: a name from the Processor's JSON sidecar (the names feature, `EntityExtractor`).
    /// None is measured against owner-checked truth, so none clears the fill rule; the figures are the shipped call's
    /// quoted names against model truth (`segbench-results/ent-8k-paired.md`, "Precision (ed2)", first run).
    /// `evidence` is each name's quote or "inferred" line (`ZoteroSidecar.evidence`), shown in the tooltip. A sidecar
    /// written where the names feature did not run carries the tagging call's names, which have no figure.
    public static func nameField(_ field: CheckableField, checked: Bool, evidence: [String],
                                 fromEntityCall: Bool = true) -> FieldStatus {
        guard fromEntityCall else {
            let source = "From the Processor’s tagging call, in the JSON sidecar"
            return checked ? FieldStatus(level: .checked, source: source, measured: "")
                : FieldStatus(level: .lowerConfidence, source: source, measured: "Not measured.")
        }
        var source = "From the Processor’s names feature, in the JSON sidecar"
        if !evidence.isEmpty { source += " (" + evidence.joined(separator: "; ") + ")" }
        let figure: String
        switch field {
        case .sender: figure = "quoted senders 88 of 115 right"
        case .recipient: figure = "quoted recipients 146 of 160 right"
        case .sendingPlace: figure = "quoted sending places 55 of 64 right"
        default: figure = "not measured"
        }
        if checked { return FieldStatus(level: .checked, source: source, measured: "") }
        return FieldStatus(level: .lowerConfidence, source: source,
                           measured: "Not measured against owner-checked truth; against model truth, \(figure).")
    }

    /// A sidecar name the user set in the Reader (`UserItemFields`): checked, as an item field the user set is.
    public static func userNameField(sidecarValue: String?) -> FieldStatus {
        let source = sidecarValue.map { "Set by the user; the JSON sidecar reads “\($0)”" }
            ?? "Set by the user; the JSON sidecar has none"
        return FieldStatus(level: .checked, source: source, measured: "")
    }

    /// A page-2 item field whose value the user set in the Reader (`UserItemFields`): checked, as a container value
    /// the user set is. `pageValue` is what page 2 reads, nil when it has none.
    public static func userItemField(pageValue: String?) -> FieldStatus {
        let source = pageValue.map { "Set by the user; page 2 reads “\($0)”" } ?? "Set by the user; page 2 has none"
        return FieldStatus(level: .checked, source: source, measured: "")
    }

    /// The item's own date, from its tags. `evidence` is the page-2 `Date evidence:` line, which the Processor's
    /// dating route writes for a year not explicit in the document's text; with none, the date is explicit in the
    /// text or its source was not recorded (a hand-set tag writes no line). No class of the route clears the rule
    /// (`segbench-results/date-route-pipeline.md`, "By evidence class", Gemini 3.7 Flash on the owner's documents).
    public static func date(checked: Bool, evidence: String?) -> FieldStatus {
        let cls = evidence.flatMap { $0.split(separator: ";", maxSplits: 1).first }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let source: String, figure: String?
        switch cls {
        case "image":
            source = "Read off the page image by the Processor’s dating route"
            figure = "10 of 12 exact"
        case "stamp":
            source = "Taken from a stamp or postmark on the page by the Processor’s dating route"
            figure = "1 of 1 exact where it fired; a stamp’s year was the owner’s on 25 of 25 documents carrying one, most also dated in their text"
        case "estimate":
            source = "Estimated from a neighbouring document by the Processor’s dating route"
            figure = "35 of 51 exact"
        case "inherited":
            source = "Inherited from the covering letter by the Processor’s dating route"
            figure = "not measured on its own"
        case "folder":
            source = "Taken from the folder’s confirmed date by the Processor’s dating route"
            figure = folderFigure(evidence)
        case .some:
            source = "From the Processor’s dating route"
            figure = "not measured for this evidence"
        case nil:
            source = "From the document’s text, or not recorded"
            figure = "an explicit year from the text is 139 of 158 exact"
        }
        if checked { return FieldStatus(level: .checked, source: source, measured: "") }
        return FieldStatus(level: .lowerConfidence, source: source, measured: figure.map { "Below the fill rule: \($0)." } ?? "")
    }

    /// The folder rule's figure for the form it wrote, read from the evidence's quoted folder value
    /// (`folder; from <start>; "<value>"; gave <date>`, the text between the first and last quote mark):
    /// `segbench-results/folder-date.md`, "What the rule writes, scored by its form", the owner's Year tags on the dated
    /// documents of 17 checked folders. A range's mid-point year shows none: its `Date Uncertain` says it alone (owner,
    /// 2026-11-20, call 24; it was measured 20 of 42 exact, within a year for 33).
    static func folderFigure(_ evidence: String?) -> String? {
        let value = evidence.flatMap { e -> String? in
            guard let open = e.firstIndex(of: "\""), let close = e.lastIndex(of: "\""), open < close else { return nil }
            return String(e[e.index(after: open)..<close])
        }
        switch value.flatMap({ ContainerFolderDate.parse($0) })?.inherited {
        case .year(_, _, uncertain: false):
            return "a checked single-year folder date was the owner’s year for 13 of 14 dated documents inside it"
        case .year(_, _, uncertain: true):
            return nil
        case .decade:
            return "a decade from a checked folder range is not measured (no dated document in the checked folders)"
        case nil:
            return "a year written from a checked folder date was exact for 33 of 56 dated documents inside it"
        }
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
