import Foundation
import ArchiveCore

/// W47.item-fields-build: the document's own catalogue fields (its kind, title, byline, publication, the printed issue
/// date and where a letter's addressee is), read by one dedicated call per document after the tagging call. The
/// result goes into the sidecar's `item_fields` object (`SegmentJSONBuilder`), never into Finder tags, and a field
/// fills only where the bench measured this route clearing the fill rule (`ItemFieldPolicy`).
///
/// The call is the bench's image prompt (`segbench/item_fields_retruth.py`, PROMPT; `test_item_fields_app.py` compares
/// the two): Gemini 3.7 Flash on the gateway, every page's image (the first 8 and the last 2 of a longer document, at
/// 1,600 px on the long side) and the pages' text with page marks, temperature 0, low reasoning. Scored with the
/// owner's three sheets folded in (`segbench-results/item-fields-score.md`, "The verdict"). No other route is measured
/// for it, so no other backend makes the call.
enum ItemFieldExtractor {
    static let gatewayModel = DateRoute.gatewayModel
    static let headPages = 8
    static let tailPages = 2
    static let imageLongSide = 1600
    /// The characters of the marked text the call sends.
    static let textCap = 16000
    /// The bench's cap: Gemini 3.7 Flash spends reasoning tokens before the reply.
    static let maxTokens = 8192
    static let timeout: TimeInterval = 180

    static let kinds: [String] = [
        "letter", "memo", "telegram", "newspaper article", "magazine article", "journal article", "newsletter",
        "clipping", "report", "speech", "press release", "photograph", "other",
    ]
    /// `item_fields.CORRESP`: a letter, memo or telegram has no byline, publication or publication date.
    static let correspondence: Set<String> = ["letter", "memo", "telegram"]
    /// `item_fields.PUBLISHED`: the kinds a byline and a publication date were scored on.
    static let published: Set<String> = [
        "newspaper article", "magazine article", "journal article", "newsletter", "clipping", "report",
    ]

    /// The pages the call sends, in order: all of them, or the first `headPages` and the last `tailPages`
    /// (`item_fields_retruth.capped`).
    static func capped<T>(_ pages: [T]) -> [T] {
        guard pages.count > headPages + tailPages else { return pages }
        return Array(pages.prefix(headPages)) + Array(pages.suffix(tailPages))
    }

    /// The sent pages' text, each under its page mark, as `item_fields_retruth.doc_text` writes it, cut at `textCap`
    /// Unicode scalars (the bench cuts a Python string).
    static func markedText(_ texts: [String]) -> String {
        let n = texts.count
        let marked = capped(Array(texts.enumerated())).map { i, t in
            "[page \(i + 1) of \(n)]\n" + t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(String.UnicodeScalarView(marked.joined(separator: "\n\n").unicodeScalars.prefix(textCap)))
    }

    static func prompt(texts: [String]) -> String {
        template.replacingOccurrences(of: "{text}", with: markedText(texts))
    }

    /// `item_fields_retruth.PROMPT`, byte for byte; `{text}` is the marked text.
    static let template = """
        You are labelling catalogue fields for a test set built from a historical archive. You get images of the \
        pages of one document (all of them, or for a long document the first 8 and the last 2) and the text machine OCR read \
        from them, with page marks (it may be noisy). Read the images as well as the text.

        Reply with JSON only, in this form:
        {"kind": one of "letter", "memo", "telegram", "newspaper article", "magazine article", "journal article", \
        "newsletter", "clipping", "report", "speech", "press release", "photograph", "other",
         "title": "..." or null,
         "byline": ["...", ...],
         "publication": "..." or null,
         "publication_date": "YYYY-MM-DD" or "YYYY-MM" or "YYYY" or null,
         "recipient_place": ["...", ...],
         "quotes": {"title": "...", "byline": "...", "publication": "...", "publication_date": "...", \
        "recipient_place": "..."}}

        Definitions.
        - kind: what the document is. "clipping" is a printed cutting whose kind of periodical cannot be told.
        - title: the title or headline the document itself states, OCR errors corrected (a memo's subject line counts; a \
        report's title page). null for a letter, telegram or note, and when no title is printed. A letterhead (the \
        sender's organisation printed at the top) is not a title.
        - byline: the authors credited on a published piece or a report ("By ...", an author line), as "Given Surname" \
        without titles. A report, press release or speech that names no person as its author: the organisation that issued \
        it. An unsigned newspaper or magazine piece: []. [] for correspondence (its sender is not a byline).
        - publication: the newspaper, magazine, journal or newsletter the piece was printed in, as named in its masthead, \
        running head, or a note written on the clipping. null when not stated, or when the document was not printed in one \
        (a letterhead is not a publication; a column's or section's name is not the publication).
        - publication_date: the issue date printed with the piece (masthead, running head, or a note on the clipping). \
        null when not stated, and always null for a letter, memo or telegram (its own date is not a publication date).
        - recipient_place: where the addressee is, from the inside address, a "To:" line or an envelope, on any page, as \
        "City, State" for the United States or "City, Country" elsewhere. [] when not written or not correspondence.
        - quotes: for each field you filled, the words in the OCR text it was read from, copied exactly as the OCR text has \
        them (errors included); null when it is not in the OCR text (read from the image only).
        - Do not guess from general knowledge. Use only this document.

        OCR text:
        ---
        {text}
        ---
        """

    // MARK: The reply

    struct Reading: Equatable, Sendable, Codable {
        var kind: String?
        var title: String?
        var byline: [String] = []
        var publication: String?
        /// "YYYY", "YYYY-MM" or "YYYY-MM-DD", as the reply gave it once checked.
        var publicationDate: String?
        var recipientPlace: [String] = []
        /// The words each filled field was read from, as the reply quoted them (absent when read from the image only).
        var quotes: [String: String] = [:]
    }

    private static let nullWords: Set<String> = ["", "null", "none", "n/a", "unknown", "not stated", "-"]
    private static let entityNullWords: Set<String> = ["", "null", "none", "unknown", "n/a"]
    private static let placeholders: Set<String> = ["city, state", "city, country", "city"]

    /// `item_fields.clean`: a number as its integer's digits, whitespace folded, quotes stripped, null-like words nil.
    static func clean(_ value: Any?) -> String? {
        var s: String
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            s = String(n.int64Value)
        } else if let str = value as? String {
            s = str
        } else {
            return nil
        }
        s = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return nullWords.contains(s.lowercased()) ? nil : s
    }

    /// `ent_truth.ent_names`: a string, a list of strings or a list of `{name, quote}`; empty and "Unknown"-like out.
    static func names(_ value: Any?) -> [String] {
        guard let value, !(value is NSNull) else { return [] }
        if let s = value as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return entityNullWords.contains(t.lowercased()) ? [] : [t]
        }
        var out: [String] = []
        for item in (value as? [Any]) ?? [value] {
            if item is String {
                out += names(item)
            } else if let obj = item as? [String: Any], let n = obj["name"] as? String {
                let t = n.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(t) }
            }
        }
        return out
    }

    /// `item_fields.date_of`: a year, then a month only when 1-12, then a day only when 1-31; anything else nil.
    static func date(_ value: Any?) -> String? {
        guard let v = clean(value) else { return nil }
        let parts = v.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(parts.count), parts[0].count == 4, parts.allSatisfy({ p in
            !p.isEmpty && p.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
        }), parts.dropFirst().allSatisfy({ $0.count <= 2 }), let year = Int(parts[0]) else { return nil }
        var out = String(format: "%04d", year)
        guard parts.count > 1, let month = Int(parts[1]), (1...12).contains(month) else { return out }
        out += String(format: "-%02d", month)
        guard parts.count > 2, let day = Int(parts[2]), (1...31).contains(day) else { return out }
        return out + String(format: "-%02d", day)
    }

    /// The reply as a reading with the label definitions applied (`item_fields.parse`, then `by_definition`, as every
    /// scored image-prompt reading was), or nil when the reply holds no JSON object.
    static func parse(_ raw: String) -> Reading? {
        var s = raw
        while let open = s.range(of: "<think>"), let close = s.range(of: "</think>", range: open.upperBound..<s.endIndex) {
            s.removeSubrange(open.lowerBound..<close.upperBound)
        }
        guard let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}"), start <= end,
              let data = String(s[start...end]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var r = Reading()
        if let k = clean(json["kind"])?.lowercased() { r.kind = kinds.contains(k) ? k : "other" }
        r.title = clean(json["title"])
        r.byline = names(json["byline"])
        r.publication = clean(json["publication"])
        r.publicationDate = date(json["publication_date"])
        r.recipientPlace = names(json["recipient_place"])
        if let q = json["quotes"] as? [String: Any] {
            for (field, v) in q {
                let text = (v as? [Any]).map { $0.map { "\($0)" }.joined(separator: " ") } ?? v
                if let c = clean(text) { r.quotes[field] = c }
            }
        }
        return byDefinition(r)
    }

    /// `item_fields.by_definition`.
    static func byDefinition(_ reading: Reading) -> Reading {
        var r = reading
        if let k = r.kind, correspondence.contains(k) {
            r.byline = []
            r.publication = nil
            r.publicationDate = nil
            if k != "memo" { r.title = nil }
        }
        r.recipientPlace = r.recipientPlace.filter {
            !placeholders.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
        return r
    }

    // MARK: The call

    /// What one document needs for the call, gathered on the main actor.
    struct Input: Sendable {
        /// Every page's text, in order.
        let texts: [String]
        /// Every page's source image and the run's rotation correction, in order.
        let pages: [(url: URL, rotation: Int)]
    }

    /// One document through the measured route. A failed call or an unparsable reply gives a `.failed` result: there
    /// is no other route to fall back to.
    static func extract(_ input: Input, gateway: GatewayConfig, route: String) async -> ItemFieldResult {
        let jpegs = capped(input.pages).compactMap {
            ImageEncoding.uprightJPEG(url: $0.url, rotationDegrees: $0.rotation, longEdge: imageLongSide)
        }
        guard !jpegs.isEmpty else { return ItemFieldResult(route: route, outcome: .failed("no page image")) }
        var content: [[String: Any]] = jpegs.map {
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + $0.base64EncodedString()]]
        }
        content.append(["type": "text", "text": prompt(texts: input.texts)])
        guard let raw = await DateRoute.gatewayChat(content: content, gateway: gateway, model: gatewayModel,
                                                    maxTokens: maxTokens, timeout: timeout) else {
            return ItemFieldResult(route: route, outcome: .failed("the call failed"))
        }
        guard let reading = parse(raw) else {
            return ItemFieldResult(route: route, outcome: .failed("the reply was not a JSON object"))
        }
        return ItemFieldResult(route: route, outcome: .read(reading))
    }
}

/// Which item fields fill, by the bench's fill rule (Wilson lower bound 0.85, point 0.90, 40 owner-checked pairs with a
/// true value) on this route, each on the kinds it was scored on (`item_fields.SCOPE`). A field the reading has but the
/// rule does not fill is left empty, and the sidecar says why rather than giving the value.
enum ItemFieldPolicy {
    enum Field: String, CaseIterable, Sendable {
        case kind, title, byline, publication
        case publicationDate = "publication_date"
        case recipientPlace = "recipient_place"
    }

    /// Too close on the third sheet (53/56 drawn pairs right, stratified 0.91 [0.83, 0.94]); its misses took a kicker
    /// line into the headline and gave half of a title that runs over two pages. A further draw is one look sized in
    /// advance, and a prompt change is judged on a fresh seeded draw (measurement review pass 12, P12-2).
    static let titleBelowBar = "below the fill rule on this route: 0.91 [0.83, 0.94] (item-fields-score.md)"

    /// The reason `field` is not filled on a document of `kind`, or nil when it fills.
    static func withheld(_ field: Field, kind: String?) -> String? {
        switch field {
        case .kind, .publication:
            return nil
        case .title:
            return titleBelowBar
        case .byline, .publicationDate:
            guard let kind, ItemFieldExtractor.published.contains(kind) else {
                return "not measured on this kind"
            }
            return nil
        case .recipientPlace:
            guard let kind, ItemFieldExtractor.correspondence.contains(kind) else {
                return "not measured on this kind"
            }
            return nil
        }
    }

    /// Whether the call runs on a document: only on the measured route, a remote gateway (where the dating route's
    /// image pass runs too), and only where its output is written.
    static func skipReason(gateway: GatewayConfig?, localAgent: LocalAgentConfig?, sidecars: Bool) -> String? {
        if !sidecars { return "no sidecar is written" }
        if localAgent != nil { return "no measured item-fields route on a Local Agent plan" }
        guard let gateway, !gateway.isLocalModel else { return "no measured item-fields route on this backend" }
        return nil
    }
}

/// One document's item fields as the sidecar records them. Codable so Live Capture's staging manifest can keep it.
struct ItemFieldResult: Equatable, Sendable, Codable {
    enum Outcome: Equatable, Sendable, Codable {
        case read(ItemFieldExtractor.Reading)
        case failed(String)
    }

    let route: String
    let outcome: Outcome

    /// The filled fields, as the sidecar and the page-2 header give them (nil: not filled).
    var filled: ItemFieldExtractor.Reading? {
        guard case .read(let r) = outcome else { return nil }
        var f = ItemFieldExtractor.Reading(kind: r.kind)
        let kind = r.kind
        if ItemFieldPolicy.withheld(.title, kind: kind) == nil { f.title = r.title }
        if ItemFieldPolicy.withheld(.byline, kind: kind) == nil { f.byline = r.byline }
        if ItemFieldPolicy.withheld(.publication, kind: kind) == nil { f.publication = r.publication }
        if ItemFieldPolicy.withheld(.publicationDate, kind: kind) == nil { f.publicationDate = r.publicationDate }
        if ItemFieldPolicy.withheld(.recipientPlace, kind: kind) == nil { f.recipientPlace = r.recipientPlace }
        let kept: Set<String> = Set(ItemFieldPolicy.Field.allCases.filter { field in
            switch field {
            case .kind: return f.kind != nil
            case .title: return f.title != nil
            case .byline: return !f.byline.isEmpty
            case .publication: return f.publication != nil
            case .publicationDate: return f.publicationDate != nil
            case .recipientPlace: return !f.recipientPlace.isEmpty
            }
        }.map(\.rawValue))
        f.quotes = r.quotes.filter { kept.contains($0.key) }
        return f
    }

    /// The sidecar's `item_fields` object: the route, then each filled field; `not_filled` names a field the reading
    /// had but the fill rule leaves empty, with the reason and without the value. The publication date is the printed
    /// issue date, apart from the document's own date (`date`), which it never replaces.
    var sidecarObject: [String: Any] {
        var o: [String: Any] = ["route": route]
        switch outcome {
        case .failed(let why):
            o["status"] = "failed"
            o["reason"] = why
        case .read(let r):
            o["status"] = "read"
            guard let f = filled else { return o }
            if let v = f.kind { o["kind"] = v }
            if let v = f.title { o["title"] = v }
            if !f.byline.isEmpty { o["byline"] = f.byline }
            if let v = f.publication { o["publication"] = v }
            if let v = f.publicationDate { o["publication_date"] = v }
            if !f.recipientPlace.isEmpty { o["recipient_place"] = f.recipientPlace }
            if !f.quotes.isEmpty { o["quotes"] = f.quotes }
            var notFilled: [String: String] = [:]
            let had: [ItemFieldPolicy.Field: Bool] = [
                .title: r.title != nil, .byline: !r.byline.isEmpty, .publication: r.publication != nil,
                .publicationDate: r.publicationDate != nil, .recipientPlace: !r.recipientPlace.isEmpty,
            ]
            for (field, present) in had where present {
                if let why = ItemFieldPolicy.withheld(field, kind: r.kind) { notFilled[field.rawValue] = why }
            }
            if !notFilled.isEmpty { o["not_filled"] = notFilled }
        }
        return o
    }
}
