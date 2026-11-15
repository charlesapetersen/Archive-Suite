import ArchiveCore
import CoreGraphics
import Foundation

/// The app's one list of page kinds (W42.int-s3, Stage 3 of `execution-plans/integration/00-plan.md`; the rules are
/// Phase 4's, `execution-plans/processing-review/13-stage-rules/10-kinds-and-routing.md`). The classifier, the
/// newspaper rule, the Finder tags, the collection interview, routing and the PDF header all speak it.
///
/// Measured per kind in `segbench-results/page-kinds.md` (`scripts/segbench/page_kinds.py`), pinned by
/// `scripts/test-ocr-page-kind.sh`. Raw values are the settings layer's mix keys and the model guide's kind ids.
enum PageKindName: String, CaseIterable, Codable, Sendable {
    case handwritten, typewritten, printed, forms
    /// A whole newspaper page, told by the shape of the engine's reading of it (`EnginePageKind.readNewspaper`).
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
    /// only). Print for newspapers and an unclassified clipping until the layout stage gives them their own route
    /// (`W46.layout-newspapers`). A tagged clipping keeps its classifier hand (`PageKind.routingKind`); a mixed page
    /// goes to the handwritten pick (`kind-classifier.md` §1); a register is read as a form, as the settings layer
    /// reads it (`SettingsResolver.answers`).
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

    /// The PDF header's `Kind:` (`SPEC/tag-format.md`), which keeps the four kinds the readers are ranked by: a
    /// newspaper or unclassified clipping is print (tagged clippings use `PageKind.headerKind`). nil for mixed pages
    /// and registers, which say nothing of the writing, so the line stays absent rather than guessed (as
    /// `PDFGenerator` leaves an unknown kind out).
    var headerKind: OCRPageKind? {
        switch self {
        case .handwritten: return .handwritten
        case .typewritten: return .typewritten
        case .forms: return .forms
        case .printed, .newspapers, .clippings: return .printed
        case .registers, .mixed: return nil
        }
    }

    /// The kind a source file's Finder tags give it, the corpus's own labels: Handwritten, Clippings and Statistics
    /// (1,304 Statistics, 1,140 Clippings and 286 Handwritten among the corpus photographs' tags). Statistics are
    /// tables, so forms. Matched without case; a tag's colour suffix (`Name\n6`) is ignored. Clippings wins so its
    /// layout identity survives other tags; Handwritten then wins over Statistics for an unsure classifier call.
    /// These labels do not establish confidence or override a sure classifier's reading kind.
    static func fromFinderTags(_ tags: [String]) -> PageKindName? {
        let names = Set(tags.map { ($0.split(separator: "\n").first.map(String.init) ?? $0)
            .trimmingCharacters(in: .whitespaces).lowercased() })
        if names.contains("clippings") || names.contains("clipping") { return .clippings }
        if names.contains("handwritten") { return .handwritten }
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
        /// The shape of the engine's reading of the page (`EnginePageKind.readNewspaper`).
        case layout
        /// The source file's Finder tags (`PageKindName.fromFinderTags`).
        case finderTag = "finder_tag"
    }

    let kind: PageKindName
    /// The classifier's probability, retained when a tag contributes a kind; 1 for the newspaper rule.
    let confidence: Double
    /// A tagged clipping keeps its layout kind, but is read and labelled in the PDF by the classifier's hand.
    let readingKind: PageKindName?
    var source: Source = .classifier
    var photographed = false

    init(kind: PageKindName, confidence: Double, source: Source = .classifier, photographed: Bool = false,
         readingKind: PageKindName? = nil) {
        self.kind = kind
        self.confidence = confidence
        self.readingKind = readingKind
        self.source = source
        self.photographed = photographed
    }

    private enum CodingKeys: String, CodingKey { case kind, confidence, source, photographed, readingKind }

    /// A run record written before the source and the photographed axis decodes as the classifier's, not scanned.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(PageKindName.self, forKey: .kind)
        confidence = try c.decode(Double.self, forKey: .confidence)
        readingKind = try c.decodeIfPresent(PageKindName.self, forKey: .readingKind)
        source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .classifier
        photographed = try c.decodeIfPresent(Bool.self, forKey: .photographed) ?? false
    }

    /// The guide's kind and the PDF's four-kind header, independent of a clipping's layout identity.
    var routingKind: PageKindName { (readingKind ?? kind).routingKind }
    var headerKind: OCRPageKind? { (readingKind ?? kind).headerKind }

    /// Owner, 2026-11-13 walkthrough (c): the classifier picks the reader. Clippings marks the layout kind only;
    /// Handwritten and Statistics break an unsure call, without lifting its probability over the routing floor.
    /// Otherwise the newspaper rule then the classifier stand. No classifier (missing weights, an older macOS,
    /// unreadable image) still gives no kind, whatever the tags, so the run keeps its model.
    static func detect(classified: PageKind?, newspaper: Bool, tags: [String], photographed: Bool) -> PageKind? {
        guard let classified else { return nil }
        if let tagged = PageKindName.fromFinderTags(tags) {
            if tagged == .clippings {
                return PageKind(kind: .clippings, confidence: classified.confidence, source: .finderTag,
                                photographed: photographed, readingKind: classified.kind)
            }
            if classified.confidence < PageKindRouting.minimumConfidence {
                return PageKind(kind: tagged, confidence: classified.confidence, source: .finderTag,
                                photographed: photographed)
            }
        }
        if newspaper {
            return PageKind(kind: .newspapers, confidence: 1, source: .layout, photographed: photographed)
        }
        return PageKind(kind: classified.kind, confidence: classified.confidence, source: .classifier,
                        photographed: photographed)
    }

    /// Whether the page is read for the newspaper call: only a page the classifier calls printed. It called all 32
    /// whole newspaper pages of the truth set printed, and the one owner page the rule called a newspaper was a
    /// form (`segbench-results/page-kinds.md`); the engine's banded reading costs seconds a page, spent only here.
    static func readsForNewspaper(_ classified: PageKind?) -> Bool { classified?.kind == .printed }

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
