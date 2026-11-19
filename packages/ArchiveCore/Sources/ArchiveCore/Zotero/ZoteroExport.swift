import Foundation
import PDFKit

// MARK: - The export to Zotero (W47.ct-zotero; `SPEC/containers.md` §Zotero)
//
// One CSL-JSON item per document, carrying everything the apps gathered for it: the container, the date from its tags,
// the item fields from its page-2 header, and the sender, recipient and their places from the Processor's sidecar.
// Zotero 10's CSL-JSON importer keeps a variable only where the item's Zotero type has a field for it; everything
// else is written into `note`, which Zotero imports as Extra, so nothing gathered is dropped. Nothing is invented for
// an empty field, and no citation is formatted.

/// What the apps know about one document.
public struct ZoteroSource: Equatable, Sendable {
    public var fileName: String
    public var tags: DocumentTags?
    /// The page-2 header's item fields; the sidecar's fill what the header lacks.
    public var itemFields = PDFItemFields()
    public var sidecar: ZoteroSidecar?
    /// The container as the apps show it (`ContainerDisplay.values`).
    public var container: [ContainerField: String] = [:]
    /// A link back to the document (Notes' `archivereader://` source link), sent as `URL`.
    public var link: String?

    public init(fileName: String, tags: DocumentTags? = nil, itemFields: PDFItemFields = PDFItemFields(),
                sidecar: ZoteroSidecar? = nil, container: [ContainerField: String] = [:], link: String? = nil) {
        self.fileName = fileName
        self.tags = tags
        self.itemFields = itemFields
        self.sidecar = sidecar
        self.container = container
        self.link = link
    }

    /// Reads everything for the PDF at `pdf`: its tags, the first text page's header, its sidecar and its container
    /// through `lookup`. Read only; call it off the main thread.
    public static func gather(pdf: URL, lookup: ContainerLookup?, link: String? = nil) -> ZoteroSource {
        var source = ZoteroSource(fileName: pdf.lastPathComponent, link: link)
        source.tags = TagReading.readTags(pdf)
        source.itemFields = headerItemFields(pdf: pdf)
        source.sidecar = ZoteroSidecar.read(pdf: pdf)
        if let lookup { source.container = lookup.shown(for: pdf).mapValues(\.text) }
        return source
    }

    /// The item fields of the first text page whose header has any.
    public static func headerItemFields(pdf: URL) -> PDFItemFields {
        guard let doc = PDFDocument(url: pdf) else { return PDFItemFields() }
        return PDFHeaderParser.textPageHeaders(doc).lazy.compactMap { $0?.itemFields }.first { !$0.isEmpty }
            ?? PDFItemFields()
    }
}

public enum ZoteroExport {
    /// How a document kind travels: the CSL type, the genre it states, and which of the gathered variables the
    /// Zotero type that CSL type imports as has a field for (Zotero 10.0.9's schema).
    struct TypeMap: Equatable {
        var csl: String
        var genre: String?
        /// Zotero's `recipient` creator type (Letter only).
        var recipient = false
        /// `publisher-place`: the place the document was written, on the unpublished types.
        var authorPlace = false
        /// `container-title`.
        var publication = false
        /// The genre goes into `medium` rather than `genre` (Artwork).
        var genreAsMedium = false
        /// A kind the Zotero type cannot state is written into Extra.
        var kindInExtra = false
    }

    /// The item-field kinds (SPEC tag-format §Item fields) by their Zotero type: letters and telegrams as Letter,
    /// memos, reports and speeches as Manuscript (unpublished, and kept with their archive fields), the articles as
    /// their article types, a clipping or newsletter as a newspaper or magazine article, a photograph as Artwork.
    static func typeMap(kind: String?, format: String?) -> TypeMap {
        switch kind?.lowercased() {
        case "letter": return TypeMap(csl: "personal_communication", recipient: true)
        case "telegram": return TypeMap(csl: "personal_communication", genre: "Telegram", recipient: true)
        case "memo": return TypeMap(csl: "manuscript", genre: "Memo", authorPlace: true)
        case "report": return TypeMap(csl: "manuscript", genre: "Report", authorPlace: true)
        case "speech": return TypeMap(csl: "manuscript", genre: "Speech", authorPlace: true)
        case "press release": return TypeMap(csl: "document", genre: "Press release", authorPlace: true)
        case "newspaper article": return TypeMap(csl: "article-newspaper", publication: true)
        case "clipping": return TypeMap(csl: "article-newspaper", publication: true, kindInExtra: true)
        case "magazine article": return TypeMap(csl: "article-magazine", publication: true)
        case "newsletter": return TypeMap(csl: "article-magazine", publication: true, kindInExtra: true)
        case "journal article": return TypeMap(csl: "article-journal", publication: true)
        case "photograph": return TypeMap(csl: "graphic", genre: "Photograph", genreAsMedium: true)
        default:
            // No kind read (material that predates the apps, or `other`): a Document, stating the tagging call's
            // format when there is one.
            return TypeMap(csl: "document", genre: kind == nil ? format : nil, authorPlace: true)
        }
    }

    /// The item-field kinds (SPEC tag-format §Item fields).
    static let kinds: Set<String> = ["letter", "memo", "telegram", "newspaper article", "magazine article",
                                     "journal article", "newsletter", "clipping", "report", "speech", "press release",
                                     "photograph", "other"]

    /// Workflow tags that are not subjects of the document.
    static let notSubjects: Set<String> = [DocumentTags.poorOCRTag.lowercased(), "ocr failed"]

    /// The CSL-JSON item for `source`. `id` is the file name, unique within one export (`export` numbers repeats).
    public static func item(_ source: ZoteroSource, id: String? = nil) -> [String: Any] {
        let side = source.sidecar ?? ZoteroSidecar()
        let fields = merged(source.itemFields, side.itemFields)
        // The tagging call's format stands in for a kind only where it names one exactly.
        let kind = fields.documentKind ?? side.format.map { $0.lowercased() }.flatMap { kinds.contains($0) ? $0 : nil }
        let map = typeMap(kind: kind, format: side.format)
        var item: [String: Any] = ["id": id ?? source.fileName, "type": map.csl]
        var extra: [String] = []

        // The container (`ContainerCSL`); Zotero has no field for the collection or the repository's place, so those
        // go into Extra as well, as the CSL variables Zotero reads from there.
        let container = ContainerCSL(shown: source.container)
        for (key, value) in container.variables { item[key] = value }
        if let v = container.variables["archive_collection"] { extra.append("archive_collection: \(v)") }
        if let v = container.variables["archive-place"] { extra.append("archive-place: \(v)") }
        extra += container.noteLines

        if let title = fields.title { item["title"] = title }
        if let genre = map.genre { item[map.genreAsMedium ? "medium" : "genre"] = genre }
        if map.kindInExtra, let kind { extra.append("Document kind: \(kind)") }

        // People: a byline names the author of a published piece; otherwise the sender the entity call read.
        let authors = fields.byline.map(splitList) ?? side.authors
        if !authors.isEmpty { item["author"] = authors.map { ["literal": $0] } }
        if !side.recipients.isEmpty {
            if map.recipient {
                item["recipient"] = side.recipients.map { ["literal": $0] }
            } else {
                extra.append("Recipient: \(side.recipients.joined(separator: "; "))")
            }
        }

        // Places: the place a document was written fills the Zotero type's Place where it has one; a published
        // piece's Place is its publisher's, so its author's place goes into Extra.
        if !side.authorPlaces.isEmpty {
            let places = side.authorPlaces.joined(separator: "; ")
            if map.authorPlace { item["publisher-place"] = places } else { extra.append("Author place: \(places)") }
        }
        let recipientPlaces = fields.recipientPlace.map(splitList) ?? side.recipientPlaces
        if !recipientPlaces.isEmpty { extra.append("Recipient place: \(recipientPlaces.joined(separator: "; "))") }

        if let publication = fields.publication ?? side.publication {
            if map.publication { item["container-title"] = publication } else { extra.append("Publication: \(publication)") }
        }
        // The printed issue date is not the document's date (FLD-6): `issued` comes from the date tags only.
        if let printed = fields.publicationDate { extra.append("Publication date: \(printed)") }

        if let tags = source.tags {
            if let issued = issued(tags) { item["issued"] = issued }
            if tags.dateUncertain, tags.year != nil || tags.decade != nil { extra.append("Date uncertain") }
            if let sent = tags.sentWith {
                extra.append("Sent with: \(sent.wireValue)\(tags.sentWithUncertain ? " (uncertain)" : "")")
            }
            // Zotero's CSL-JSON importer takes no tags: the subjects travel as `keyword` for other CSL tools and as
            // an Extra line Zotero keeps.
            let subjects = tags.subjects.filter { !notSubjects.contains($0.lowercased()) }
            if !subjects.isEmpty {
                item["keyword"] = subjects.joined(separator: ", ")
                extra.append("Subjects: \(subjects.joined(separator: "; "))")
            }
        }

        if let link = source.link { item["URL"] = link }
        extra.append("File: \(source.fileName)")
        item["note"] = extra.joined(separator: "\n")
        return item
    }

    /// The header's fields, each one the header lacks taken from the sidecar.
    static func merged(_ header: PDFItemFields, _ sidecar: PDFItemFields) -> PDFItemFields {
        PDFItemFields(documentKind: header.documentKind ?? sidecar.documentKind, title: header.title ?? sidecar.title,
                      byline: header.byline ?? sidecar.byline, publication: header.publication ?? sidecar.publication,
                      publicationDate: header.publicationDate ?? sidecar.publicationDate,
                      recipientPlace: header.recipientPlace ?? sidecar.recipientPlace)
    }

    /// A header list is joined with `; `.
    static func splitList(_ s: String) -> [String] {
        s.components(separatedBy: "; ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The tags' date as CSL `issued`: date-parts to the precision the tags give, a decade as its literal ("1970s"),
    /// `circa` when the date is uncertain. Nil when undated.
    static func issued(_ tags: DocumentTags) -> [String: Any]? {
        var date: [String: Any]
        if let year = tags.year {
            var parts = [year]
            if let month = tags.month?.number {
                parts.append(month)
                if let day = tags.day { parts.append(day) }
            }
            date = ["date-parts": [parts]]
        } else if let token = tags.decadeToken {
            date = ["literal": token]
        } else {
            return nil
        }
        if tags.dateIsSpeculative { date["circa"] = true }
        return date
    }

    /// The CSL-JSON array for `sources`, one item each in order. A repeated file name gets ` (2)`, ` (3)` on its id.
    public static func export(_ sources: [ZoteroSource]) -> Data {
        var seen: [String: Int] = [:]
        let items = sources.map { source -> [String: Any] in
            let n = seen[source.fileName, default: 0] + 1
            seen[source.fileName] = n
            return item(source, id: n == 1 ? source.fileName : "\(source.fileName) (\(n))")
        }
        return (try? JSONSerialization.data(withJSONObject: items,
                                            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            ?? Data("[]".utf8)
    }
}
