import ArchiveCore
import CoreGraphics
import Foundation
import VisionOCRKit

/// The app's one list of page kinds (W42.int-s3, Stage 3 of `execution-plans/integration/00-plan.md`; the rules are
/// Phase 4's, `execution-plans/processing-review/13-stage-rules/10-kinds-and-routing.md`). The classifier, the
/// newspaper rule, the Finder tags, the collection interview, routing and the PDF header all speak it.
///
/// Measured per kind in `segbench-results/page-kinds.md` (`scripts/segbench/page_kinds.py`), pinned by
/// `scripts/test-ocr-page-kind.sh`. Raw values are the settings layer's mix keys and the model guide's kind ids.
enum PageKindName: String, CaseIterable, Codable, Sendable {
    case handwritten, typewritten, printed, forms
    /// A whole newspaper page, told by the shape of Vision's lines (`EnginePageKind.isNewspaper`).
    case newspapers
    /// One article cut to a page; told only by the Finder tag Clippings, else asked.
    case clippings
    /// Registers and ledgers; asked, never detected (the classifier calls them handwritten).
    case registers
    /// A typed or printed page with handwriting on it; asked, never detected: no pre-flag is established (P4-1), so
    /// "Read handwriting on typed pages" acts on every typed or printed page instead.
    case mixed

    /// The kinds the on-device classifier calls, in the settings sheet's order.
    static let classifierKinds: [PageKindName] = [.typewritten, .printed, .handwritten, .forms]
    /// The kinds the collection interview asks for, labelled "not measured" (owner, 2026-11-06). Newspapers are
    /// detected page by page too, but the sample's mix counts them as print (`mixKind`), so the share is asked.
    static let askedKinds: [PageKindName] = [.clippings, .newspapers, .registers, .mixed]

    var label: String {
        switch self {
        case .handwritten: return "Handwritten"
        case .typewritten: return "Typewritten"
        case .printed: return "Printed"
        case .forms: return "Form or table"
        case .newspapers: return "Whole newspaper page"
        case .clippings: return "Newspaper clipping"
        case .registers: return "Register or ledger"
        case .mixed: return "Typed page with handwriting on it"
        }
    }

    /// The kind as a share of a collection, for the interview: "Whole newspaper pages".
    var shareLabel: String {
        switch self {
        case .clippings: return "Newspaper clippings"
        case .newspapers: return "Whole newspaper pages"
        case .registers: return "Registers and ledgers"
        case .mixed: return "Typed pages with handwriting on them"
        default: return label
        }
    }

    /// The model guide's kind whose pick reads this kind (`OCRPageGuidance`, which has rows for the classifier's four
    /// only). Print for newspapers and clippings until the layout stage gives them their own route
    /// (`W46.layout-newspapers`); a mixed page goes to the handwritten pick (`kind-classifier.md` §1); a register is
    /// read as a form, as the settings layer reads it (`SettingsResolver.answers`).
    var routingKind: PageKindName {
        switch self {
        case .handwritten, .typewritten, .printed, .forms: return self
        case .newspapers, .clippings: return .printed
        case .registers: return .forms
        case .mixed: return .handwritten
        }
    }

    /// The kind a sample's measured mix counts the page under: one of `classifierKinds`.
    var mixKind: PageKindName { routingKind }

    /// The PDF header's `Kind:` (`SPEC/tag-format.md`), which keeps the four kinds the readers are ranked by.
    var headerKind: OCRPageKind {
        switch routingKind {
        case .handwritten: return .handwritten
        case .typewritten: return .typewritten
        case .forms: return .forms
        default: return .printed
        }
    }

    /// The kind a source file's Finder tags give it, the corpus's own labels: Handwritten, Clippings and Statistics
    /// (1,304 Statistics, 1,140 Clippings and 286 Handwritten among the corpus photographs' tags). Statistics are
    /// tables, so forms. Matched without case; a tag's colour suffix (`Name\n6`) is ignored. Handwritten wins over
    /// Clippings over Statistics when a file holds several: the hand is what defeats the readers.
    static func fromFinderTags(_ tags: [String]) -> PageKindName? {
        let names = Set(tags.map { ($0.split(separator: "\n").first.map(String.init) ?? $0)
            .trimmingCharacters(in: .whitespaces).lowercased() })
        if names.contains("handwritten") { return .handwritten }
        if names.contains("clippings") || names.contains("clipping") { return .clippings }
        if names.contains("statistics") { return .forms }
        return nil
    }

    /// A label for any settings mix key, including one not in the list.
    static func label(_ key: String) -> String { PageKindName(rawValue: key)?.label ?? key }
}

/// One page's kind: what it is, how sure, who said so, and whether it was photographed (a second axis: it changes
/// the image, not the writing).
struct PageKind: Codable, Sendable, Equatable {
    enum Source: String, Codable, Sendable {
        /// The on-device classifier (`PageKindClassifier`).
        case classifier
        /// The shape of Vision's lines (`EnginePageKind.isNewspaper`).
        case layout
        /// The source file's Finder tags (`PageKindName.fromFinderTags`).
        case finderTag = "finder_tag"
    }

    let kind: PageKindName
    /// The classifier's probability for its call; 1 for a Finder tag or the newspaper rule.
    let confidence: Double
    var source: Source = .classifier
    var photographed = false

    /// The one rule that puts the signals together. A Finder tag corrects everything (the owner's label); then a
    /// newspaper's line shape (the classifier has no newspaper class and calls one printed); then the classifier.
    /// `classified` nil (no weights, an older macOS, an unreadable image) gives nil whatever else is known, so a page
    /// keeps the run's model when the weights fail to load, as the rule note requires.
    static func detect(classified: PageKind?, uprightLines: [PageLine], tags: [String],
                       photographed: Bool) -> PageKind? {
        guard let classified else { return nil }
        if let tagged = PageKindName.fromFinderTags(tags) {
            return PageKind(kind: tagged, confidence: 1, source: .finderTag, photographed: photographed)
        }
        if EnginePageKind.isNewspaper(lines: uprightLines) {
            return PageKind(kind: .newspapers, confidence: 1, source: .layout, photographed: photographed)
        }
        return PageKind(kind: classified.kind, confidence: classified.confidence, source: .classifier,
                        photographed: photographed)
    }

    /// "Typewritten (93%)", "Whole newspaper page (by its columns)", "Handwritten (Finder tag)", each with
    /// ", photographed" when it was.
    var summary: String {
        let how: String
        switch source {
        case .classifier: how = "\(Int((confidence * 100).rounded()))%"
        case .layout: how = "by its columns"
        case .finderTag: how = "Finder tag"
        }
        return "\(kind.label) (\(how))" + (photographed ? ", photographed" : "")
    }
}
