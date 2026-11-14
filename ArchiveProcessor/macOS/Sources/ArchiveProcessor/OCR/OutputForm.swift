import ArchiveCore
import Foundation
import VisionOCRKit

/// W42.int-s5-searchable — the two forms an output can take (Stage 5 of `execution-plans/integration/00-plan.md`;
/// owner, 2026-10-14, decision 2). Image-plus-text: the page image, with its layer where it can be placed, then a page
/// of the text carrying the header (`SPEC/tag-format.md` §"2-page PDF structure"). Searchable: the page image with the
/// reading as its layer and no text page, the header in the XMP (`PDFHeaderCarrier`), as Vision OCR writes it.
enum OutputForm: String, Codable, Sendable {
    case imageAndText = "image-and-text"
    case searchable

    /// The form for an input of `format` whose page is of `kind` (nil: unknown): searchable when an entry of
    /// `searchableFor` (the `searchableFor` setting) names both, `*` standing for any; image-plus-text otherwise. An
    /// unknown kind is matched only by `*`.
    static func form(format: String, kind: PageKindName?, searchableFor: [String]) -> OutputForm {
        for entry in searchableFor {
            let parts = entry.lowercased().split(separator: "/", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            let formatMatches = parts[0] == "*" || parts[0] == format.lowercased()
            let kindMatches = parts[1] == "*" || (kind.map { parts[1] == $0.rawValue } ?? false)
            if formatMatches && kindMatches { return .searchable }
        }
        return .imageAndText
    }

    /// The format name an input file's extension stands for, as `searchableFor` names it.
    static func format(ofExtension ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg", "jpe": return "jpeg"
        case "heic", "heif": return "heic"
        case "tif", "tiff": return "tiff"
        default: return ext.lowercased()
        }
    }

    /// Why a page chosen for the searchable form is written as a pair: no reading (the text page says what failed), or a
    /// script the writer cannot hold even unplaced (`TextLayerRule.unplaceableScript`). Nil when it can be written.
    static func searchableRefusal(reading: String?) -> String? {
        guard let reading, !reading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "no text was read, so the text page says why"
        }
        if let script = TextLayerRule.unplaceableScript(reading) { return script }
        return nil
    }

    /// Whether `layer` (a page's text read back) holds every word of `reading`, as many times as the reading has it,
    /// compared as lower-case letters and digits: the searchable form's test that the layer lost nothing.
    static func holds(_ layer: String, every reading: String) -> Bool { missingWords(layer, reading).isEmpty }

    /// The words of `reading` that `layer` lacks (one entry per missing occurrence). A word broken by a hyphen at a line
    /// end counts whole, as the writer joins it (`SearchableWriter.compose`, `joinHyphenated`), and in its two halves too.
    static func missingWords(_ layer: String, _ reading: String) -> [String] {
        func words(_ s: String) -> [String] {
            s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        }
        var have: [String: Int] = [:]
        for w in words(layer) { have[w, default: 0] += 1 }
        func take(_ w: String) -> Bool {
            guard have[w, default: 0] > 0 else { return false }
            have[w]! -= 1
            return true
        }
        var lines = reading.components(separatedBy: .newlines).map {
            (hyphenated: $0.trimmingCharacters(in: .whitespaces).hasSuffix("-"), words: words($0))
        }
        var missing: [String] = []
        for i in lines.indices {
            var ws = lines[i].words
            if lines[i].hyphenated, i + 1 < lines.count, let last = ws.last, let next = lines[i + 1].words.first,
               take(last + next) {
                ws.removeLast()
                lines[i + 1].words.removeFirst()
            }
            for w in ws where !take(w) { missing.append(w) }
        }
        return missing
    }

    /// The reading's lines spread down the image, full width, top to bottom, normalised with a top-left origin: an
    /// unplaced layer, so the text is on the page and selectable though not on its words.
    static func unplacedLines(_ reading: String) -> [PageLine] {
        let lines = reading.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return [] }
        let pitch = 0.96 / Double(lines.count)
        let height = min(pitch * 0.8, 0.04)
        return lines.enumerated().map { i, text in
            PageLine(text: text, box: CGRect(x: 0.02, y: 0.02 + Double(i) * pitch, width: 0.96, height: height),
                     confidence: 0)
        }
    }
}
