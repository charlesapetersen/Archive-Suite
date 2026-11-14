import ArchiveCore
import Foundation

/// W42.int-s5 — which pages get a searchable layer on the image page, and from what (Stage 5 of
/// `execution-plans/integration/00-plan.md`; the rules are Phase 4's,
/// `execution-plans/processing-review/13-stage-rules/05-placement.md` §3). The layer itself is VisionOCRKit's
/// (`TextLayer`): Vision's lines as the engine reads them, the reader's words aligned onto them, the lab writer.
///
/// Every output keeps its text page (page 2), which carries the header; the layer is the text a second time, on the
/// image, where it can be placed. A page that gets no layer is still searchable through its text page, and the
/// outcome says why it got none.
enum TextLayerRoute: String, Codable, Sendable {
    /// Print: Vision's lines with the reader's words aligned onto them.
    case visionLinesAligned = "vision-lines-aligned"
    /// Print, the fallback: Vision's own words, where under half of them anchor in the reading (or there is none).
    case visionOwn = "vision-own"
    /// No layer on the image; the text page alone.
    case textPage = "text-page"
    /// The searchable form's fallback (W42.int-s5-searchable): the reading's own lines down the image, not placed on
    /// its words, since that form has no text page to hold the text.
    case unplaced = "unplaced"
}

/// What one page's layer came to.
struct TextLayerOutcome: Codable, Sendable, Equatable {
    var route: TextLayerRoute
    /// Why a page got the text page alone, or an unplaced layer; nil for a placed layer.
    var reason: String?
    /// The lines drawn, and how many of them the writer could not place.
    var lines: Int = 0
    var unplaced: Int = 0

    static func textPage(_ reason: String) -> TextLayerOutcome { TextLayerOutcome(route: .textPage, reason: reason) }
}

enum TextLayerRule {
    enum Decision: Equatable {
        /// Place Vision's lines with the reading aligned. `requireAligned`: a page of unknown kind gets a layer only
        /// when the reading aligns, since Vision's own words on a handwritten page would be a second, worse reading.
        case place(requireAligned: Bool)
        case textPage(String)
    }

    static let handwritingReason = "handwriting: the hand placer (kraken blla lines with CTC alignment) is not in the app yet"
    static let switchOffReason = "handwriting: \"Place handwritten text on the page image\" is off"

    /// The decision for a page of `kind` (nil: unknown) read as `reading`.
    static func decide(kind: PageKindName?, reading: String?, placeHandOnImage: Bool) -> Decision {
        // Scripts the writer has no path for (right to left) or Vision gives no word boxes for (F-placement §6.6-6.7).
        if let reading, let script = unplaceableScript(reading) { return .textPage(script) }
        switch kind {
        case .handwritten?, .mixed?, .registers?:
            // §3: switch on, `hand-blla-ctc` with the text page per page under 0.67; switch off, the text page. A
            // register is a handwritten ledger (the classifier calls it handwritten; `03-layout.md` keeps it with hands).
            return .textPage(placeHandOnImage ? handwritingReason : switchOffReason)
        case .typewritten?, .printed?, .forms?, .newspapers?, .clippings?:
            // §3's print kinds; a whole newspaper page is print read in columns, as Vision OCR places it.
            return .place(requireAligned: false)
        case nil:
            return .place(requireAligned: true)
        }
    }

    /// The kind `PDFGenerator` writes in the header, as a `PageKindName`: the person's choice, else the classifier's
    /// stored call, else an imported kind.
    static func kind(explicit: OCRPageKind?, result: OCRResult) -> PageKindName? {
        if let explicit { return PageKindName(rawValue: explicit.rawValue) }
        if let stored = result.pageReader?.kind.flatMap(PageKindName.init(rawValue:)) { return stored }
        return result.imported?.kind.flatMap(PageKindName.init(rawValue:))
    }

    /// The script a reading is in when the layer cannot hold it: right to left (Hebrew, Arabic, Syriac, Thaana, N'Ko),
    /// or CJK and Thai. A reading counts when a fifth of its letters are in one; a stray quoted word does not.
    static func unplaceableScript(_ text: String) -> String? {
        var letters = 0, rtl = 0, cjk = 0
        for s in text.unicodeScalars where s.properties.isAlphabetic {
            letters += 1
            switch s.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF: rtl += 1
            case 0x0E00...0x0E7F, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF,
                 0xF900...0xFAFF, 0x20000...0x2FA1F: cjk += 1
            default: break
            }
        }
        guard letters > 0 else { return nil }
        if rtl * 5 >= letters { return "a right-to-left script: the writer has no right-to-left path" }
        if cjk * 5 >= letters { return "CJK or Thai: Vision gives no word boxes for it" }
        return nil
    }
}
