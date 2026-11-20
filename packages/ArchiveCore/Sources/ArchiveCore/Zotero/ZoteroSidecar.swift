import Foundation

// MARK: - The Processor's JSON sidecar, as the Zotero export reads it (W47.ct-zotero)
//
// The Processor writes one JSON file per output document (`SegmentJSONBuilder`): beside the PDF with its base name,
// or in a `JSON Output` folder beside it (Live Capture). The only place the document's sender, recipient and their
// places are kept; the page-2 header carries the item fields as well. Read only, and every key is optional.

public struct ZoteroSidecar: Equatable, Sendable {
    public var authors: [String] = []
    public var recipients: [String] = []
    public var authorPlaces: [String] = []
    public var recipientPlaces: [String] = []
    /// The tagging call's publication name, left out by the Processor when the item-field call read one.
    public var publication: String?
    /// The tagging call's `format` ("Letter", "Newspaper Clipping"): what the document is when no kind was read.
    public var format: String?
    /// The item-field call's fields, when it read them (`item_fields.status == "read"`).
    public var itemFields = PDFItemFields()
    /// W49.reader-sender-row-check: why the entity call gave each kept name, one line a name in the list's order
    /// (`Name: “quote”`, `Name: inferred, because …`), for the Inspector's tooltip. Empty for the tagging call's names.
    public var evidence: [CheckableField: [String]] = [:]
    /// The names are the entity call's (`entities.status == "extracted"`, at least one name kept), not the tagging call's.
    public var namesFromEntityCall = false

    public init() {}

    /// The largest sidecar read; a bigger file is not one the Processor wrote.
    public static let maxBytes = 4 * 1024 * 1024
    public static let folderName = "JSON Output"

    /// The sidecar of `pdf`, when one is there: `<name>.json` beside it, else in its folder's `JSON Output`.
    public static func locate(pdf: URL) -> URL? {
        let base = pdf.deletingPathExtension().lastPathComponent + ".json"
        let folder = pdf.deletingLastPathComponent()
        for candidate in [folder.appendingPathComponent(base),
                          folder.appendingPathComponent(folderName, isDirectory: true).appendingPathComponent(base)] {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                return candidate
            }
        }
        return nil
    }

    public static func read(pdf: URL) -> ZoteroSidecar? {
        guard let url = locate(pdf: pdf),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size <= maxBytes, let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    /// Nil when the data is not a JSON object.
    public static func parse(_ data: Data) -> ZoteroSidecar? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var s = ZoteroSidecar()
        func string(_ any: Any?) -> String? {
            guard let raw = any as? String else { return nil }
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty || t.caseInsensitiveCompare("unknown") == .orderedSame ? nil : t
        }
        func strings(_ any: Any?) -> [String] {
            if let one = string(any) { return [one] }
            return (any as? [Any] ?? []).compactMap(string)
        }

        if let entities = o["entities"] as? [String: Any] {
            // The entity call's lists (`EntityExtractor.sidecarObject`): a placeholder "Unknown" entry is no name,
            // and a sending place is kept only where the document writes it (owner, W46.ent-truth-owner-fold).
            if entities["status"] as? String == "extracted" {
                func names(_ key: String, quotedOnly: Bool, field: CheckableField) -> [String] {
                    var lines: [String] = []
                    let kept: [String] = (entities[key] as? [[String: Any]] ?? []).compactMap { e in
                        let evidence = e["evidence"] as? String
                        guard evidence != "unknown", !quotedOnly || evidence == "quoted",
                              let name = string(e["name"]) else { return nil }
                        switch evidence {
                        case "quoted":
                            let quote = (e["quote"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            lines.append(quote.isEmpty ? "\(name): quoted" : "\(name): “\(quote)”")
                        case "inferred":
                            let why = (e["inferred_because"] as? String)?
                                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            lines.append(why.isEmpty ? "\(name): inferred" : "\(name): inferred, \(why)")
                        default: lines.append(name)
                        }
                        return name
                    }
                    if !lines.isEmpty { s.evidence[field] = lines }
                    return kept
                }
                s.authors = names("sender", quotedOnly: false, field: .sender)
                s.recipients = names("recipient", quotedOnly: false, field: .recipient)
                s.authorPlaces = names("sending_place", quotedOnly: true, field: .sendingPlace)
                s.namesFromEntityCall = !(s.authors.isEmpty && s.recipients.isEmpty && s.authorPlaces.isEmpty)
            }
        } else {
            s.authors = strings(o["author_name"])
            s.recipients = strings(o["recipient_name"])
            s.authorPlaces = strings(o["author_location"])
        }
        s.recipientPlaces = strings(o["recipient_location"])
        s.publication = string(o["publication_name"])
        s.format = string(o["format"])

        if let f = o["item_fields"] as? [String: Any], f["status"] as? String == "read" {
            func joined(_ key: String) -> String? {
                let all = strings(f[key])
                return all.isEmpty ? nil : all.joined(separator: "; ")
            }
            s.itemFields = PDFItemFields(documentKind: string(f["kind"]), title: string(f["title"]),
                                         byline: joined("byline"), publication: string(f["publication"]),
                                         publicationDate: string(f["publication_date"]),
                                         recipientPlace: joined("recipient_place"))
        }
        return s
    }
}
