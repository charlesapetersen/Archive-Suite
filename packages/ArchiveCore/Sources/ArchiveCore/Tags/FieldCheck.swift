import Foundation

// MARK: - A field the user has checked (W40.reader-field-status, SPEC/tag-format.md §"Field checks")
//
// A check is one Finder tag per field, `Checked <Field>` (`Checked Date`, `Checked Publication`), written by the
// Reader's audited `TagWriter` like any other tag edit, so it travels with the file and is undone with ⌘Z. It says
// the user has looked at the field's current value and accepts it; it never holds the value. Container fields are
// not checked by tag: their check is a `user` value in the container file (`SPEC/containers.md`).

/// The item's own fields that can carry a check: its dates (tags), the page-2 item fields and the names the
/// Processor's names feature writes to the JSON sidecar (W49.reader-sender-row-check).
public enum CheckableField: String, Sendable, CaseIterable, Hashable {
    case date = "Date"
    case sentWith = "Sent With"
    case documentKind = "Document Kind"
    case title = "Title"
    case byline = "Byline"
    case publication = "Publication"
    case publicationDate = "Publication Date"
    case recipientPlace = "Recipient Place"
    case sender = "Sender"
    case recipient = "Recipient"
    case sendingPlace = "Sending Place"

    public static let tokenPrefix = "Checked "

    /// The tag a check is written as: `Checked Date`.
    public var token: String { Self.tokenPrefix + rawValue }

    /// The field a tag checks: the whole token, surrounding spaces and case ignored, as `Date Uncertain` is read.
    /// Case is ignored because the writer removes tokens case-insensitively (`TagWriter`): an uncheck takes every
    /// spelling, so every spelling has to read as the check, never as a subject the uncheck would delete.
    public init?(token: String) {
        let s = token.trimmingCharacters(in: .whitespaces)
        guard let f = CheckableField.allCases.first(where: { $0.token.caseInsensitiveCompare(s) == .orderedSame })
        else { return nil }
        self = f
    }

    /// The label the Inspector shows.
    public var label: String {
        switch self {
        case .date: return "Date"
        case .sentWith: return "Sent with"
        case .documentKind: return "Kind"
        case .title: return "Title"
        case .byline: return "Byline"
        case .publication: return "Publication"
        case .publicationDate: return "Publication date"
        case .recipientPlace: return "Recipient place"
        case .sender: return "Sender"
        case .recipient: return "Recipient"
        case .sendingPlace: return "Sending place"
        }
    }

    /// The page-2 item fields, in header order (`PDFItemFields`).
    public static let itemFields: [CheckableField] = [.documentKind, .title, .byline, .publication, .publicationDate,
                                                     .recipientPlace]

    /// The names the JSON sidecar carries and page 2 does not (`ZoteroSidecar`), in the order the Inspector lists them.
    public static let nameFields: [CheckableField] = [.sender, .recipient, .sendingPlace]

    /// Every field whose value the user can correct beside the file (`UserItemFields`): the item fields, then the names.
    public static let correctable: [CheckableField] = itemFields + nameFields

    /// This field's value on a page-2 header; nil for the dates, which are tags.
    public func value(in fields: PDFItemFields) -> String? {
        let v: String?
        switch self {
        case .date, .sentWith, .sender, .recipient, .sendingPlace: return nil
        case .documentKind: v = fields.documentKind
        case .title: v = fields.title
        case .byline: v = fields.byline
        case .publication: v = fields.publication
        case .publicationDate: v = fields.publicationDate
        case .recipientPlace: v = fields.recipientPlace
        }
        guard let t = v?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// This name field's value in a sidecar, several names joined with "; "; nil for any other field or no name.
    public func value(in sidecar: ZoteroSidecar) -> String? {
        let names: [String]
        switch self {
        case .sender: names = sidecar.authors
        case .recipient: names = sidecar.recipients
        case .sendingPlace: names = sidecar.authorPlaces
        default: return nil
        }
        return names.isEmpty ? nil : names.joined(separator: "; ")
    }
}
