import Foundation
import ArchiveCore

// MARK: - A file's item fields as the content index keeps them (W49.reader-item-fields-search)
//
// Page 2's item fields are read when the file's text is extracted; the user's corrections (`UserItemFields`, the
// folder's `.archivesuite/item-fields.json`) are read beside them on every pass and after every correction, undo or
// redo. Both are kept in the disposable content index, so search matches a corrected value and the list's Item fields
// column shows what the Inspector shows. The JSON sidecar's sender, recipient and sending place are read with the text
// and kept beside page 2's values (W49.reader-sidecar-names-index). Display and search only; nothing here is written
// to an archive file.

struct IndexedItemFields: Equatable, Sendable {
    /// Page 2's values, as the Processor wrote them.
    var header = PDFItemFields()
    /// The user's values; "" is "none", hiding page 2's.
    var user: [CheckableField: String] = [:]
    /// The JSON sidecar's names (`CheckableField.nameFields`), several joined with "; ".
    var names: [CheckableField: String] = [:]

    var isEmpty: Bool { header.isEmpty && user.isEmpty && names.isEmpty }

    /// What the Inspector shows: the user's values over page 2's.
    var shown: PDFItemFields { UserItemFields.applied(user, to: header) }

    /// The names the Inspector shows: the user's over the sidecar's, "none" giving no name.
    var shownNames: [CheckableField: String] { Self.shownNames(names, user: user) }

    static func shownNames(_ names: [CheckableField: String],
                           user: [CheckableField: String]) -> [CheckableField: String] {
        var out: [CheckableField: String] = [:]
        for f in CheckableField.nameFields {
            if let v = user[f] ?? names[f], !v.isEmpty { out[f] = v }
        }
        return out
    }

    /// The fields the list's column gives, title first, as one line. The names follow them (`nameFields`): a letter
    /// often has no title, and its sender is then the first thing the column shows; where there is a title, the
    /// column's width truncates the names first, and the tooltip lists them all.
    static let columnOrder: [CheckableField] = [.title, .byline, .publication, .publicationDate, .documentKind,
                                                .recipientPlace]

    /// The column's text: each shown value in `columnOrder`, joined; nil when none is shown.
    var columnText: String? {
        let s = shown, n = shownNames
        let values = Self.columnOrder.compactMap { $0.value(in: s) } + CheckableField.nameFields.compactMap { n[$0] }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    /// The column's tooltip: one line per shown field, a corrected one marked as the user's.
    var columnToolTip: String? {
        let s = shown, n = shownNames
        let lines = (Self.columnOrder + CheckableField.nameFields).compactMap { field -> String? in
            guard let v = field.value(in: s) ?? n[field] else { return nil }
            return "\(field.label): \(v)" + (user[field] != nil ? " (your value)" : "")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// The values the index searches beside the text, one per line: every non-empty one of the user's, and the
    /// sidecar's names the user has not corrected. Page 2's own values are in the text already.
    static func searchText(_ user: [CheckableField: String], names: [CheckableField: String] = [:]) -> String {
        CheckableField.correctable.compactMap { f in (user[f] ?? names[f]).flatMap { $0.isEmpty ? nil : $0 } }
            .joined(separator: "\n")
    }

    // MARK: Stored form (a JSON object keyed by `CheckableField.jsonKey`)

    static func encode(_ values: [CheckableField: String]) -> String {
        guard !values.isEmpty else { return "" }
        let raw = Dictionary(uniqueKeysWithValues: values.compactMap { f, v in f.jsonKey.map { ($0, v) } })
        guard let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ text: String) -> [CheckableField: String] {
        guard !text.isEmpty, let raw = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String]
        else { return [:] }
        var out: [CheckableField: String] = [:]
        for (key, value) in raw {
            if let f = CheckableField(jsonKey: key) { out[f] = value }
        }
        return out
    }

    /// Page 2's fields as stored values.
    static func values(of fields: PDFItemFields) -> [CheckableField: String] {
        var out: [CheckableField: String] = [:]
        for f in CheckableField.itemFields { if let v = f.value(in: fields) { out[f] = v } }
        return out
    }

    /// A sidecar's names as stored values.
    static func names(of sidecar: ZoteroSidecar?) -> [CheckableField: String] {
        guard let sidecar else { return [:] }
        var out: [CheckableField: String] = [:]
        for f in CheckableField.nameFields { if let v = f.value(in: sidecar) { out[f] = v } }
        return out
    }

    /// Stored values as page 2's fields.
    static func fields(_ values: [CheckableField: String]) -> PDFItemFields {
        UserItemFields.applied(values, to: PDFItemFields())
    }

    /// The first text page that carries item fields gives them, as the Inspector reads them.
    static func header(of content: ExtractedContent) -> PDFItemFields { header(of: content.textPages.map(\.header)) }

    static func header(of headers: [PDFPageHeader?]) -> PDFItemFields {
        headers.lazy.compactMap { $0 }.first(where: { !$0.itemFields.isEmpty })?.itemFields ?? PDFItemFields()
    }
}
