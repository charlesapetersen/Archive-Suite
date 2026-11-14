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
/// outcome says why it got none.
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
        /// Handwriting: the hand placer's lines (`HandPlacer`), the text page when its confidence is under the gate.
        case placeHands
        case textPage(String)
    }

    static let notDownloadedReason = "handwriting: the handwriting placer has not been downloaded (Settings, Text placement)"
    static let switchOffReason = "handwriting: \"Place handwritten text on the page image\" is off"
    static let noReadingReason = "handwriting: there is no reading to place"
    static func reflowReason(_ model: String) -> String {
        "handwriting: \(model) joins a page's lines into paragraphs, so its reading cannot be placed line by line"
    }
    static func gateReason(_ confidence: Double) -> String {
        String(format: "handwriting: the placer was unsure of the page (confidence %.2f, under %.2f)", confidence, HandPlacer.gate)
    }

    /// The readers `05-placement.md` §3 flags `reflows` (W46.reader-keeps-lines: their median page keeps 0.12 to 0.46
    /// of blla's lines, and the gate does not rescue them): Infinity-Parser2-Pro, LightOnOCR-3, PaddleOCR-VL 1.6 and
    /// Xiaomi-OCR-0, every build. Matched on the model's name as the run records it.
    static func reflows(_ model: String) -> Bool {
        let m = model.lowercased().replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "_", with: "-")
        return ["infinity-parser", "lightonocr", "paddleocr-vl", "xiaomi-ocr"].contains { m.contains($0) }
    }

    /// The model whose reading the page holds: an imported reading's, a second reader's, the reader its kind chose, else
    /// the run's own (`run`, every name the run knows it by: the model, the gateway's or the local agent's).
    static func readerModel(of result: OCRResult, run: String? = nil) -> String? {
        result.imported?.model ?? result.secondReader?.model ?? result.pageReader?.model ?? run
    }

    /// The run's reader as `readerModel` takes it: every name it goes by, so a reflowing model is caught under any.
    static func runReader(model: LLMModel?, gateway: String? = nil, localAgent: String? = nil) -> String? {
        let names = [model?.id, model?.displayName, gateway, localAgent].compactMap { $0 }.filter { !$0.isEmpty }
        return names.isEmpty ? nil : names.joined(separator: " ")
    }

    /// The decision for a page of `kind` (nil: unknown) read as `reading` by `readerModel`. `handPlacerInstalled`:
    /// whether the hand placer's download is in place (`HandPlacer.isInstalled`).
    static func decide(kind: PageKindName?, reading: String?, placeHandOnImage: Bool, readerModel: String? = nil,
                       handPlacerInstalled: Bool) -> Decision {
        // Scripts the writer has no path for (right to left) or Vision gives no word boxes for (F-placement §6.6-6.7).
        if let reading, let script = unplaceableScript(reading) { return .textPage(script) }
        switch kind {
        case .handwritten?, .mixed?, .registers?:
            // §3: switch on, `hand-blla-ctc` with the text page per page under 0.67 (the caller's, once the placer has
            // run); switch off, the text page; a reader that reflows, the text page on every hand page. A register is a
            // handwritten ledger (the classifier calls it handwritten; `03-layout.md` keeps it with hands).
            guard placeHandOnImage else { return .textPage(switchOffReason) }
            guard let reading, !reading.isEmpty else { return .textPage(noReadingReason) }
            if let readerModel, reflows(readerModel) { return .textPage(reflowReason(readerModel)) }
            return handPlacerInstalled ? .placeHands : .textPage(notDownloadedReason)
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
