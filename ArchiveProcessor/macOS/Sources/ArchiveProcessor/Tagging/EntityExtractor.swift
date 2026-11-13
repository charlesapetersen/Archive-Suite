import Foundation
import ArchiveCore

/// W46.ent-feature: who sent a correspondence document, to whom, and from where, each name with the words it was
/// read from or marked inferred (`execution-plans/processing-review/13-stage-rules/09-entities.md`). One dedicated
/// call per document, after the tagging call; the result goes into the sidecar's `entities` object
/// (`SegmentJSONBuilder`), never into Finder tags.
///
/// The prompt is the bench's dedicated entity prompt with the sending-place rule (`segbench/ent_feature.py`,
/// `test_ent_feature.py` compares the two), measured on the 138 correspondence documents before it shipped
/// (`segbench-results/ent-feature.md`). It carries only the document's own text: no neighbouring documents, so a
/// name cannot be lifted from them, and the evidence check reads that same text.
enum EntityExtractor {
    /// The characters of the document the call sends, as the tagging call does.
    static let textCap = 3000
    /// A quote with this many letters or more may be found at edit distance `nearDistance`.
    static let nearLetters = 5
    static let nearDistance = 2

    /// The part of the document the call sends and the check reads: the first `textCap` Unicode scalars, as the bench
    /// cuts Python strings (a CR LF or an accented letter is one Swift Character but two scalars).
    static func sent(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.prefix(textCap)))
    }

    static func prompt(text: String) -> String {
        """
        You are extracting correspondence metadata from one document in a historical archive: a letter, memo or telegram. The text below was read from a photograph by machine OCR and may contain recognition errors.

        ---
        \(sent(text))
        ---

        Respond with ONLY a JSON object of this shape:
        {"sender": [{"name": "...", "quote": "..."}], "recipient": [{"name": "...", "quote": "..."}], "sending_place": [{"name": "...", "quote": "..."}]}

        Rules:
        - "sender": the person who wrote or signed the document (a signature, a typed name under the closing, a "From:" line). If no person is named as its writer, the organisation it comes from. Typist's initials and enclosures are not senders.
        - "recipient": the person or people it is addressed to (the inside address, a "To:" line, the salutation). List each addressee. Copies ("cc") are not recipients.
        - "sending_place": where it was sent from (the letterhead's or the dateline's city), as "City, State" or "City, Country". Only a place the document writes (a dateline, a letterhead or an address): an empty list when it writes none, never a place inferred from an institution's name, the collection or other documents.
        - "name": the normalised name, as "Given Surname" without titles (no Mr., Dr., Professor, President); correct obvious OCR errors in it.
        - "quote": the name exactly as it is written in the OCR text above, recognition errors included, copied character for character; null when the name is not written in the text (for example only a role is written, such as "Dear Mr. President", and you know who held it).
        - Use an empty list for a field the document does not let you fill. Use only this document.
        """
    }

    // MARK: The evidence check

    enum Evidence: Equatable, Sendable, Codable {
        /// The quote is in the document's own text, at this edit distance (0, or up to `nearDistance`).
        case quoted(distance: Int)
        /// No quote, or one the text does not hold: the name is written marked inferred (owner, 2026-11-06).
        case inferred(why: String)
    }

    static let noQuote = "no quote"
    static let quoteNotInText = "quote not in the text"

    /// Whether `quote` is in the document's text (the part the call sent): whitespace folded, case ignored, exactly,
    /// or at edit distance 2 when the quote has five letters or more. `ent_feature.evidence` is the same rule.
    static func evidence(quote: String?, in text: String) -> Evidence {
        let q = fold(quote ?? "")
        guard !q.isEmpty else { return .inferred(why: noQuote) }
        let t = fold(sent(text))
        let d = bestDistance(Array(q.unicodeScalars), in: Array(t.unicodeScalars), cap: nearDistance + 1)
        if d == 0 { return .quoted(distance: 0) }
        if letterCount(q) >= nearLetters, d <= nearDistance { return .quoted(distance: d) }
        return .inferred(why: quoteNotInText)
    }

    static func fold(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    static func letterCount(_ s: String) -> Int {
        s.unicodeScalars.filter { $0.properties.isAlphabetic }.count
    }

    /// The smallest edit distance between `q` and any stretch of `t` (Sellers' approximate substring match), capped.
    static func bestDistance(_ q: [Unicode.Scalar], in t: [Unicode.Scalar], cap: Int) -> Int {
        guard !q.isEmpty else { return 0 }
        var prev = [Int](repeating: 0, count: t.count + 1)
        var cur = prev
        for i in 1...q.count {
            cur[0] = i
            var rowMin = i
            if !t.isEmpty {
                for j in 1...t.count {
                    cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (q[i - 1] == t[j - 1] ? 0 : 1))
                    rowMin = min(rowMin, cur[j])
                }
            }
            swap(&prev, &cur)
            if rowMin >= cap { return cap }
        }
        return min(prev.min() ?? cap, cap)
    }

    // MARK: The reply

    struct Name: Equatable, Sendable, Codable {
        let name: String
        /// The model's quote as it answered it (kept when the check found it; dropped from the sidecar otherwise).
        let quote: String?
        let evidence: Evidence

        /// high: quoted exactly; medium: quoted at edit distance 1 or 2; low: inferred.
        var confidence: String {
            switch evidence {
            case .quoted(let d): return d == 0 ? "high" : "medium"
            case .inferred: return "low"
            }
        }
    }

    struct Fields: Equatable, Sendable, Codable {
        var senders: [Name] = []
        var recipients: [Name] = []
        var sendingPlaces: [Name] = []
    }

    private static let unknownWords: Set<String> = ["", "null", "none", "unknown", "n/a"]

    /// The reply's three fields with each name checked against `text`, or nil when the reply is not a JSON object.
    /// A field may come as a list of `{name, quote}`, a list of strings or one string; empty and "Unknown"-like names
    /// are dropped and a repeated name kept once (`ent_feature.names`).
    static func parse(_ raw: String, documentText text: String) -> Fields? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}"), start <= end {
            s = String(s[start...end])
        } else {
            return nil
        }
        guard let data = s.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func names(_ value: Any?) -> [Name] {
            guard let value, !(value is NSNull) else { return [] }
            let items = (value as? [Any]) ?? [value]
            var out: [Name] = []
            var seen: Set<String> = []
            for item in items {
                var name: String?
                var quote: String?
                if let str = item as? String {
                    name = str
                } else if let obj = item as? [String: Any] {
                    name = obj["name"] as? String
                    quote = obj["quote"] as? String
                }
                let n = (name ?? "").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                let key = n.lowercased()
                guard !unknownWords.contains(key), !seen.contains(key) else { continue }
                seen.insert(key)
                out.append(Name(name: n, quote: quote, evidence: evidence(quote: quote, in: text)))
            }
            return out
        }
        return Fields(senders: names(json["sender"]), recipients: names(json["recipient"]),
                      sendingPlaces: names(json["sending_place"]))
    }

    // MARK: The call

    /// The reply needs room for several names with quotes; reasoning models spend some first.
    static let maxTokens = 2048
    static let timeout: TimeInterval = 120

    /// One document through the chosen route. A failed call or an unparsable reply gives a `.failed` result with no
    /// names: there is no fallback to another route (09-entities.md §3, Fallback).
    static func extract(text: String, decision: EntityRunPolicy.Run, provider: LLMProvider, model: LLMModel,
                        apiKey: String, gatewayConfig: GatewayConfig?) async -> EntityResult {
        let raw: String
        do {
            raw = try await LLMTextClient.complete(prompt: prompt(text: text), provider: provider, model: model,
                                                   thinkingLevel: nil, apiKey: apiKey, gatewayConfig: gatewayConfig,
                                                   localAgent: nil, maxTokens: maxTokens, timeout: timeout)
        } catch {
            return EntityResult(decision: decision, outcome: .failed("the call failed"))
        }
        guard let fields = parse(raw, documentText: text) else {
            return EntityResult(decision: decision, outcome: .failed("the reply was not a JSON object"))
        }
        return EntityResult(decision: decision, outcome: .extracted(fields))
    }
}

/// One document's names as the sidecar records them. Codable so Live Capture's staging manifest keeps it for a
/// segment the rotation review regenerates (W46.ent-feature-live): the regenerated sidecar carries the same names, with
/// no second call.
struct EntityResult: Equatable, Sendable, Codable {
    enum Outcome: Equatable, Sendable, Codable {
        case extracted(EntityExtractor.Fields)
        case failed(String)
    }

    let decision: EntityRunPolicy.Run
    let outcome: Outcome

    /// The sidecar's `entities` object. Every field is a list of names, each with its evidence and confidence; a
    /// field the document does not fill holds the one name "Unknown" (CMIF's convention, G-entities §5), so an empty
    /// field reads apart from one not looked for. Several recipients are kept as separate entries.
    var sidecarObject: [String: Any] {
        var o: [String: Any] = ["route": decision.route, "text": decision.textSource.rawValue]
        switch outcome {
        case .failed(let why):
            o["status"] = "failed"
            o["reason"] = why
        case .extracted(let f):
            o["status"] = "extracted"
            if let withheld = decision.senderWithheld {
                o["sender_withheld"] = withheld
            } else {
                o["sender"] = Self.list(f.senders)
            }
            o["recipient"] = Self.list(f.recipients)
            o["sending_place"] = Self.list(f.sendingPlaces)
        }
        return o
    }

    static func list(_ names: [EntityExtractor.Name]) -> [[String: Any]] {
        guard !names.isEmpty else { return [["name": "Unknown", "evidence": "unknown"]] }
        return names.map { n in
            var e: [String: Any] = ["name": n.name, "confidence": n.confidence]
            switch n.evidence {
            case .quoted(let d):
                e["evidence"] = "quoted"
                e["quote"] = n.quote ?? ""
                if d > 0 { e["distance"] = d }
            case .inferred(let why):
                e["evidence"] = "inferred"
                e["inferred_because"] = why
            }
            return e
        }
    }
}

/// Whether the entity feature runs on a document, and how (09-entities.md §3; owner call 11, 2026-11-06; owner,
/// walkthrough 2026-11-13: on every route only when the collection ranks names).
enum EntityRunPolicy {
    /// The tagging call's `format` values the feature runs on: the app has no correspondence classifier, and the
    /// stage runs on correspondence only (rule ent-correspondence-only). On the 138 correspondence documents the
    /// tagging call names one of these for 134 (`segbench-results/ent-feature.md`).
    static let correspondenceFormats: Set<String> = [
        "letter", "memo", "memorandum", "telegram", "cable", "cablegram", "postcard", "telex",
    ]

    enum Family: Equatable, Sendable {
        /// A hosted model through a key or the gateway.
        case cloud
        /// A model served on this Mac (the gateway's local-model route).
        case mac
        /// A Local Agent plan CLI: the stage has no plan row (09-entities.md §9, profile 3).
        case plan
    }

    enum TextSource: String, Equatable, Sendable, Codable {
        /// Apple Vision read at least one of the document's pages.
        case vision
        /// Every page was read by a model.
        case reader
        /// The run did not say who read a page.
        case unknown
    }

    enum PageKind: Equatable, Sendable {
        case typedOrPrinted, handwritten, unknown

        init(_ kind: String?) {
            switch kind {
            case "typewritten", "printed", "forms": self = .typedOrPrinted
            case "handwritten": self = .handwritten
            default: self = .unknown
            }
        }
    }

    struct Inputs: Equatable, Sendable {
        var family: Family
        /// The collection interview ranks names (`SettingsPriority.names`).
        var namesRanked: Bool
        /// The user chose "No names" for the stage (`override.entities.<part>` = `none`).
        var routeNone: Bool = false
        /// The tagging call's `format`.
        var format: String?
        var textSource: TextSource
        var pageKinds: [PageKind]
        var route: String
    }

    struct Run: Equatable, Sendable, Codable {
        let route: String
        let textSource: TextSource
        /// Why the sender is not written, when it is not: never from Apple Vision text (rule ent-vision-hands).
        let senderWithheld: String?
    }

    enum Decision: Equatable, Sendable {
        case run(Run)
        case skip(String)
    }

    static func decide(_ i: Inputs) -> Decision {
        if i.routeNone { return .skip("the user chose no names") }
        if i.family == .plan { return .skip("a Local Agent plan has no measured names route") }
        // On every route, as on this Mac: the call costs money on a cloud route and nothing reads unshown names
        // (owner, walkthrough 2026-11-13).
        if !i.namesRanked { return .skip("names are not ranked, and they are read only when they are") }
        guard let f = i.format?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              correspondenceFormats.contains(f) else {
            return .skip("not correspondence")
        }
        if i.family == .mac, !(i.textSource == .vision || i.textSource == .reader) {
            return .skip("the reader of a page is unknown")
        }
        switch i.textSource {
        case .reader:
            // A model read every page: the cloud route on any kind; on the Mac, typed and printed only (owner call 11).
            if i.family == .mac, !i.pageKinds.allSatisfy({ $0 == .typedOrPrinted }) {
                return .skip("on this Mac names are read on typed and printed pages only")
            }
        case .vision, .unknown:
            // Apple Vision text (or none known): never on handwriting, so every page must be known typed or printed.
            if i.pageKinds.contains(.handwritten) { return .skip("Apple Vision text on a handwritten page") }
            if i.pageKinds.isEmpty || i.pageKinds.contains(.unknown) {
                return .skip("Apple Vision text on a page of unknown kind")
            }
        }
        let withheld: String? = i.textSource == .reader ? nil : "never from Apple Vision text"
        return .run(Run(route: i.route, textSource: i.textSource, senderWithheld: withheld))
    }

    /// Whether the sidecar leaves out the tagging call's `author_name` on a document the feature did not run on. The
    /// tagging call reads the same text, so where that is Apple Vision's (or its reader is unknown, as in `decide`)
    /// its sender is withheld for the same reason the feature's is: rule ent-vision-hands holds on every sidecar
    /// (owner, walkthrough 2026-11-13; through Vision text 8 of 17 senders matched, `ent-robust.md` §Reading). The
    /// recipient and place stay. Where the feature ran, its `entities` object replaces all three keys anyway.
    static func withholdsTaggingSender(_ i: Inputs) -> Bool { i.textSource != .reader }

    /// The tags the sidecar writes for a document: the tagging reply, without its sender where
    /// `withholdsTaggingSender` says so. The output PDFs' tags are not touched (they carry no sender).
    static func sidecarTags(_ tags: GeneratedTags, withholdingSender: Bool) -> GeneratedTags {
        guard withholdingSender else { return tags }
        var t = tags
        t.authorName = nil
        return t
    }
}

extension EntityRunPolicy {
    /// The policy's inputs for one document before the tagging reply gives its `format`: the route's family, who read
    /// each page (Apple Vision or a model), each page's kind, whether the collection ranks names and whether the user
    /// chose no names for the stage. `results` holds each page's OCR result (nil when the run has none for it);
    /// `runProvider` is the run's OCR provider, the reader of a page that names none. Process Files
    /// (`OCRProcessor.entityInputs`) and Live Capture (`LiveCaptureProcessor.liveEntities`) both read it, so the two
    /// pipelines decide alike.
    static func inputs(results: [OCRResult?], runProvider: String?, settings values: [String: ResolvedSetting],
                       provider: LLMProvider, model: LLMModel, gateway: GatewayConfig?,
                       localAgent: LocalAgentConfig?) -> Inputs {
        let family: Family = localAgent != nil ? .plan : (gateway?.isLocalModel == true ? .mac : .cloud)
        let kinds = results.map { PageKind($0?.pageReader?.kind) }
        let readers: [String?] = results.map { r in
            guard let r else { return nil }
            if let second = r.secondReader { return second.provider }
            if let page = r.pageReader { return page.provider }
            if r.imported != nil { return "imported" }
            return runProvider
        }
        let source: TextSource
        if readers.contains(LLMProvider.appleVision.rawValue) {
            source = .vision
        } else if readers.isEmpty || readers.contains(where: { $0 == nil }) {
            source = .unknown
        } else {
            source = .reader
        }
        let ranked = values[SettingsKey.priorities.rawValue]?.value.strings?
            .contains(SettingsPriority.names.rawValue) ?? false
        // "No names" on the Names card is stored for the whole stage (`SettingsSheetModel.overrideKey`); a per-part key
        // is read too. Any other route chosen there is not read: the names call takes the run's text route.
        let part = kinds.contains(.handwritten) ? "correspondence-handwritten" : "correspondence-typed"
        let routeNone = [SettingsSheetModel.overrideKey("entities"), SettingsKey.override(stage: "entities", part: part)]
            .contains { values[$0.rawValue]?.value.string == "none" }
        // With a gateway set, LLMTextClient calls the gateway's model, whatever the provider and model say.
        let modelName = gateway?.displayName ?? model.displayName
        let route = (family == .mac ? "this Mac" : (gateway != nil ? "Gateway" : provider.rawValue)) + " · " + modelName
        return Inputs(family: family, namesRanked: ranked, routeNone: routeNone, format: nil,
                      textSource: source, pageKinds: kinds, route: route)
    }
}
