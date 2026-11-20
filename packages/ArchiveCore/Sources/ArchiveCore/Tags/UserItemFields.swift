import Foundation

// MARK: - The user's own item-field values (W40.reader-item-field-edit, SPEC/tag-format.md §"Field checks")
//
// The page-2 header is the Processor's output-time snapshot, and no app rewrites a PDF, so a value the user corrects is
// kept beside the files instead: `<folder>/.archivesuite/item-fields.json`, one entry per file name, written through
// `ContainerFileStore` like the container file (no link followed, `flock`, the read's stamp checked before the rename).
// A value here is the user's: it is shown in place of the header's, as checked. An empty value says the file has no
// such field, hiding the header's. Strict, as the level map: a key or field this build does not know makes the document
// unreadable, so a writer leaves it alone rather than erase what a newer build put there.
//
// W49.reader-sender-row-check: the sidecar's sender, recipient and sending place are corrected the same way; a value
// with several names separates them with ";". No schema change: the keys are new, and nothing is written to migrate.
//
// W47.ct-folder-date-reader: `dates` keeps, per file, the folder date the Reader gave it and the `Date evidence:` value
// page 2 would carry (`FolderDateRecord`), trusted only while the file's tags still carry that date. No migration: the
// key is new, and there is nothing written to migrate.

public struct UserItemFields: Equatable, Sendable {
    public static let fileName = "item-fields.json"
    public static let schemaVersion = 1

    /// File name (NFC) → field → the user's value; "" is "none".
    public private(set) var files: [String: [CheckableField: String]]
    /// File name (NFC) → the folder date the Reader gave it (W47.ct-folder-date-reader).
    public private(set) var dates: [String: FolderDateRecord] = [:]
    public var updatedAt: Date?

    public init(files: [String: [CheckableField: String]] = [:], dates: [String: FolderDateRecord] = [:],
                updatedAt: Date? = nil) {
        var kept: [String: [CheckableField: String]] = [:]
        for (name, values) in files {
            let v = values.filter { CheckableField.correctable.contains($0.key) }
            if !v.isEmpty { kept[Self.key(name), default: [:]].merge(v) { _, new in new } }
        }
        self.files = kept
        for (name, record) in dates { self.dates[Self.key(name)] = record }
        self.updatedAt = updatedAt
    }

    /// The folder date the Reader gave the file named `fileName`, if it gave one.
    public func dateRecord(for fileName: String) -> FolderDateRecord? { dates[Self.key(fileName)] }

    /// Records the folder date the Reader gave `fileName`; nil takes the record away.
    public mutating func setDateRecord(_ record: FolderDateRecord?, for fileName: String) {
        dates[Self.key(fileName)] = record
    }

    /// A file name as it is keyed: composed (NFC), so a name read back from the file system in either form matches.
    public static func key(_ fileName: String) -> String { fileName.precomposedStringWithCanonicalMapping }

    /// The user's values for the file named `fileName` in this folder.
    public func values(for fileName: String) -> [CheckableField: String] { files[Self.key(fileName)] ?? [:] }

    /// Sets the user's value of `field` for `fileName`, trimmed; "" says the file has none, nil takes the user's value
    /// away. A date field is not an item field and is ignored (dates are tags).
    public mutating func set(_ field: CheckableField, to value: String?, for fileName: String) {
        guard CheckableField.correctable.contains(field) else { return }
        let k = Self.key(fileName)
        var values = files[k] ?? [:]
        values[field] = value.map { v in
            // A name field's names are kept as the Inspector shows them, "; " between; separators alone are none.
            guard CheckableField.nameFields.contains(field) else { return v.trimmingCharacters(in: .whitespacesAndNewlines) }
            return v.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.joined(separator: "; ")
        }
        files[k] = values.isEmpty ? nil : values
    }

    /// The user's values for the file at `url`, read from its folder's `item-fields.json`; none when there is no
    /// document or it cannot be read. Read only.
    public static func values(besides url: URL) -> [CheckableField: String] {
        load(folderOf: url)?.values(for: url.lastPathComponent) ?? [:]
    }

    /// The document in `url`'s folder, if one can be read.
    public static func load(folderOf url: URL) -> UserItemFields? {
        ContainerFileStore.loadItemFields(directory: url.deletingLastPathComponent().resolvingSymlinksInPath()).document
    }

    /// `fields` with the user's `values` in place: a value replaces the header's, "" removes it.
    public static func applied(_ values: [CheckableField: String], to fields: PDFItemFields) -> PDFItemFields {
        var f = fields
        for (field, value) in values {
            let v: String? = value.isEmpty ? nil : value
            switch field {
            case .documentKind: f.documentKind = v
            case .title: f.title = v
            case .byline: f.byline = v
            case .publication: f.publication = v
            case .publicationDate: f.publicationDate = v
            case .recipientPlace: f.recipientPlace = v
            case .date, .sentWith, .sender, .recipient, .sendingPlace: continue
            }
        }
        return f
    }

    /// `sidecar` with the user's name `values` in place: a value replaces the sidecar's names (several separated by
    /// ";"), "" removes them. The item fields are left to `applied(_:to:)` on the header.
    public static func applied(_ values: [CheckableField: String], to sidecar: ZoteroSidecar) -> ZoteroSidecar {
        var s = sidecar
        for (field, value) in values {
            let names = value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            switch field {
            case .sender: s.authors = names
            case .recipient: s.recipients = names
            case .sendingPlace: s.authorPlaces = names
            default: continue
            }
        }
        return s
    }
}

extension CheckableField {
    /// The JSON key of an item field in `item-fields.json`; nil for the dates.
    public var jsonKey: String? {
        switch self {
        case .date, .sentWith: return nil
        case .sender: return "sender"
        case .recipient: return "recipient"
        case .sendingPlace: return "sendingPlace"
        case .documentKind: return "documentKind"
        case .title: return "title"
        case .byline: return "byline"
        case .publication: return "publication"
        case .publicationDate: return "publicationDate"
        case .recipientPlace: return "recipientPlace"
        }
    }

    public init?(jsonKey: String) {
        guard let f = CheckableField.correctable.first(where: { $0.jsonKey == jsonKey }) else { return nil }
        self = f
    }
}

extension UserItemFields: Codable {
    private enum CodingKeys: String, CodingKey { case schemaVersion, files, dates, updatedAt }

    public init(from decoder: Decoder) throws {
        try decoder.refuseUnknownKeys(["schemaVersion", "files", "dates", "updatedAt"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode([String: [String: String]].self, forKey: .files)
        var files: [String: [CheckableField: String]] = [:]
        for (name, values) in raw {
            var v: [CheckableField: String] = [:]
            for (key, value) in values {
                guard let f = CheckableField(jsonKey: key) else {
                    throw DecodingError.dataCorruptedError(forKey: .files, in: c, debugDescription: "unknown field \(key)")
                }
                v[f] = value
            }
            // Two spellings of one name (composed and not) would be one file; the document is not one this build wrote.
            guard files[Self.key(name)] == nil else {
                throw DecodingError.dataCorruptedError(forKey: .files, in: c, debugDescription: "repeated file \(name)")
            }
            files[Self.key(name)] = v
        }
        var dates: [String: FolderDateRecord] = [:]
        for (name, record) in try c.decodeIfPresent([String: FolderDateRecord].self, forKey: .dates) ?? [:] {
            guard dates[Self.key(name)] == nil else {
                throw DecodingError.dataCorruptedError(forKey: .dates, in: c, debugDescription: "repeated file \(name)")
            }
            dates[Self.key(name)] = record
        }
        self.init(files: files, dates: dates, updatedAt: try c.decodeIfPresent(Date.self, forKey: .updatedAt))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(UserItemFields.schemaVersion, forKey: .schemaVersion)
        let raw = files.mapValues { values in
            Dictionary(uniqueKeysWithValues: values.compactMap { f, v in f.jsonKey.map { ($0, v) } })
        }
        try c.encode(raw, forKey: .files)
        if !dates.isEmpty { try c.encode(dates, forKey: .dates) }
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }
}

extension ContainerFileStore {
    public static func itemFieldsURL(in directory: URL) -> URL {
        directory.appendingPathComponent(ContainerFile.folderName, isDirectory: true)
            .appendingPathComponent(UserItemFields.fileName)
    }

    /// `directory`'s user item-field values, read as the container file is (`load(directory:)`).
    public static func loadItemFields(directory: URL) -> ContainerLoad<UserItemFields> {
        load(directory, UserItemFields.fileName, version: UserItemFields.schemaVersion)
    }

    /// Writes `fields` as `directory`'s `item-fields.json`, with every check `write(_:directory:expecting:)` makes.
    @discardableResult
    public static func writeItemFields(_ fields: UserItemFields, directory: URL, expecting: ContainerFileStamp?) throws
        -> ContainerFileStamp {
        try write(fields, in: directory, name: UserItemFields.fileName, version: UserItemFields.schemaVersion,
                  expecting: expecting).stamp
    }
}
