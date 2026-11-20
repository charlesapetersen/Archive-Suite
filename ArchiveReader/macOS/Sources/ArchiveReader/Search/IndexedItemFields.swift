import Foundation
import ArchiveCore

// MARK: - A file's item fields as the content index keeps them (W49.reader-item-fields-search)
//
// Page 2's item fields are read when the file's text is extracted; the user's corrections (`UserItemFields`, the
// folder's `.archivesuite/item-fields.json`) are read beside them on every pass and after every correction, undo or
// redo. Both are kept in the disposable content index, so search matches a corrected value and the list's Item fields
// column shows what the Inspector shows. Display and search only; nothing here is written to an archive file.

struct IndexedItemFields: Equatable, Sendable {
    /// Page 2's values, as the Processor wrote them.
    var header = PDFItemFields()
    /// The user's values; "" is "none", hiding page 2's.
    var user: [CheckableField: String] = [:]

    var isEmpty: Bool { header.isEmpty && user.isEmpty }

    /// What the Inspector shows: the user's values over page 2's.
    var shown: PDFItemFields { UserItemFields.applied(user, to: header) }

    /// The fields the list's column gives, title first, as one line.
    static let columnOrder: [CheckableField] = [.title, .byline, .publication, .publicationDate, .documentKind,
                                                .recipientPlace]

    /// The column's text: each shown value in `columnOrder`, joined; nil when none is shown.
    var columnText: String? {
        let s = shown
        let values = Self.columnOrder.compactMap { $0.value(in: s) }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    /// The column's tooltip: one line per shown field, a corrected one marked as the user's.
    var columnToolTip: String? {
        let s = shown
        let lines = Self.columnOrder.compactMap { field -> String? in
            guard let v = field.value(in: s) else { return nil }
            return "\(field.label): \(v)" + (user[field] != nil ? " (your value)" : "")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// The user's values as the index searches them: every non-empty one, one per line.
    static func searchText(_ user: [CheckableField: String]) -> String {
        CheckableField.itemFields.compactMap { f in user[f].flatMap { $0.isEmpty ? nil : $0 } }.joined(separator: "\n")
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
            if let f = CheckableField.itemFields.first(where: { $0.jsonKey == key }) { out[f] = value }
        }
        return out
    }

    /// Page 2's fields as stored values.
    static func values(of fields: PDFItemFields) -> [CheckableField: String] {
        var out: [CheckableField: String] = [:]
        for f in CheckableField.itemFields { if let v = f.value(in: fields) { out[f] = v } }
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
