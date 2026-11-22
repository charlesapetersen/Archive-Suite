import ArchiveCore
import Foundation
import VisionOCRKit

/// W42.int-s5 — which pages get a searchable layer on the image page, and from what (Stage 5 of
/// `execution-plans/integration/00-plan.md`; the rules are Phase 4's,
/// `execution-plans/processing-review/13-stage-rules/05-placement.md` §3). The layer itself is VisionOCRKit's
/// (`TextLayer`): Vision's lines as the engine reads them, the reader's words aligned onto them, the lab writer.
///
/// Every output keeps its text page (page 2), which carries the header; the layer is the text a second time, on the
/// image, where it can be placed. A page that gets no layer is still searchable through its text page, and the
/// outcome says why it got none. A handwritten page always keeps its text page, even where the searchable form is
/// chosen (owner, 2026-11-17, `OutputForm.searchableRefusal`).
enum TextLayerRoute: String, Codable, Sendable {
    /// Print: Vision's lines with the reader's words aligned onto them.
    case visionLinesAligned = "vision-lines-aligned"
    /// Print, the fallback: Vision's own words, where under half of them anchor in the reading (or there is none).
    case visionOwn = "vision-own"
    /// Handwriting (W42.int-s5-hands): kraken blla's lines with the reading force-aligned onto them (`HandPlacer`).
    case handBllaCtc = "hand-blla-ctc"
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
    /// The hand placer's alignment confidence, its seconds and its peak memory in MB, on a page it ran on (placed or
    /// sent to the text page by the gate); nil on every other page.
    var handConfidence: Double? = nil
    var handSeconds: Double? = nil
    var handPeakMB: Int? = nil

    static func textPage(_ reason: String) -> TextLayerOutcome { TextLayerOutcome(route: .textPage, reason: reason) }
}

enum TextLayerRule {
    enum Decision: Equatable {
        /// Place Vision's lines with the reading aligned. `requireAligned`: a page of unknown kind gets a layer only
        /// when the reading aligns, since Vision's own words on a handwritten page would be a second, worse reading.
        case place(requireAligned: Bool)
        /// Handwriting: the hand placer's lines (`HandPlacer`) beside the text page, the text page alone when its
        /// confidence is under the gate.
        case placeHands
        case textPage(String)
    }

    static let notDownloadedReason = "handwriting: the handwriting placer has not been downloaded (Settings, Text placement)"
    static let switchOffReason = "handwriting: \"Place handwritten text on the page image\" is off"
    static let noReadingReason = "handwriting: there is no reading to place"
    static let orderReason = "handwriting: the layer did not keep the full reading in order"
    static let reflowReason = "handwriting: the reading joins the page's lines, so it cannot be placed line by line"

    /// The same line-retention threshold as the handwriting benchmark (reader-keeps-lines.md). Compare this
    /// reading's cleaned lines with the image's detected lines. The confidence gate separately checks their match
    /// in order, so a reading with the right number of lines can still fail placement.
    static func reflows(readingLines: Int, detectedLines: Int) -> Bool {
        detectedLines >= 2 && Double(readingLines) / Double(detectedLines) < 0.7
    }

    static func handPlacementRefusal(_ placement: HandPlacer.Placement, reading: String) -> String? {
        if reflows(readingLines: placement.readingLines, detectedLines: placement.detected) { return reflowReason }
        guard !placement.lines.isEmpty else { return "handwriting: the placer found no lines to write" }
        guard placement.passesGate else { return gateReason(placement.confidence) }
        guard preservesReadingOrder(reading, placed: placement.lines.words.joined(separator: " ")) else {
            return orderReason
        }
        return nil
    }

    /// Ordered alignment can skip a line and still have a high page-average score. Check that the layer
    /// retains the transcription in image line order. Ignore decoration stripped by the placer and spacing
    /// or line-end hyphens changed by the PDF writer.
    static func preservesReadingOrder(_ reading: String, placed: String) -> Bool {
        func lettersAndNumbers(_ text: String) -> String {
            text.filter { $0.isLetter || $0.isNumber }
        }
        let plain = reading.replacingOccurrences(of: #"<[^>\r\n]+>|\[illegible\]"#, with: " ",
                                                  options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        return lettersAndNumbers(plain) == lettersAndNumbers(placed)
    }

    static func gateReason(_ confidence: Double) -> String {
        String(format: "handwriting: the placer was unsure of the page (confidence %.2f, under %.2f)", confidence, HandPlacer.gate)
    }

    /// The hand kinds: their pages go to the hand placer and always keep a text page. A register is a handwritten ledger
    /// (the classifier calls it handwritten; `03-layout.md` keeps it with hands).
    static func isHand(_ kind: PageKindName?) -> Bool {
        switch kind {
        case .handwritten?, .mixed?, .registers?: return true
        default: return false
        }
    }

    /// A tagged clipping keeps its layout kind for the format rule while its writing goes to the hand placer.
    static func placementKind(_ kind: PageKindName?, result: OCRResult) -> PageKindName? {
        if isHand(kind) { return kind }
        if let readingKind = result.pageReader?.readingKind, isHand(readingKind) { return readingKind }
        return kind
    }

    /// A page of unknown kind is placed only if its reading aligns with Vision's lines.
    static func decide(kind: PageKindName?, reading: String?, placeHandOnImage: Bool,
                       handPlacerInstalled: Bool) -> Decision {
        // Scripts the writer has no path for (right to left) or Vision gives no word boxes for (F-placement §6.6-6.7).
        if let reading, let script = unplaceableScript(reading) { return .textPage(script) }
        switch kind {
        case .handwritten?, .mixed?, .registers?:
            // §3: switch on, `hand-blla-ctc` beside the text page, the layer withheld under the 0.9 gate (the caller's,
            // once the placer has run; owner, 2026-11-17). A register is a handwritten ledger (`isHand`).
            guard placeHandOnImage else { return .textPage(switchOffReason) }
            guard let reading, !reading.isEmpty else { return .textPage(noReadingReason) }
            return handPlacerInstalled ? .placeHands : .textPage(notDownloadedReason)
        case .typewritten?, .printed?, .forms?, .newspapers?, .clippings?:
            // §3's print kinds; a whole newspaper page is print read in columns, as Vision OCR places it.
            return .place(requireAligned: false)
        case nil:
            return .place(requireAligned: true)
        }
    }

    /// The layout kind: the person's choice, else the stored call, else an imported kind. A tagged clipping stays
    /// clippings here even when its classifier hand supplies a different PDF header Kind.
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
