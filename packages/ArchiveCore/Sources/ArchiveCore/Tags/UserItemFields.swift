import Foundation

// MARK: - The user's own item-field values (W40.reader-item-field-edit, SPEC/tag-format.md §"Field checks")
//
// The page-2 header is the Processor's output-time snapshot, and no app rewrites a PDF, so a value the user corrects is
// kept beside the files instead: `<folder>/.archivesuite/item-fields.json`, one entry per file name, written through
// `ContainerFileStore` like the container file (no link followed, `flock`, the read's stamp checked before the rename).
// A value here is the user's: it is shown in place of the header's, as checked. An empty value says the file has no
// such field, hiding the header's. Strict, as the level map: a key or field this build does not know makes the document
// unreadable, so a writer leaves it alone rather than erase what a newer build put there.

public struct UserItemFields: Equatable, Sendable {
    public static let fileName = "item-fields.json"
    public static let schemaVersion = 1

    /// File name (NFC) → field → the user's value; "" is "none".
    public private(set) var files: [String: [CheckableField: String]]
    public var updatedAt: Date?

    public init(files: [String: [CheckableField: String]] = [:], updatedAt: Date? = nil) {
        var kept: [String: [CheckableField: String]] = [:]
        for (name, values) in files {
            let v = values.filter { CheckableField.itemFields.contains($0.key) }
            if !v.isEmpty { kept[Self.key(name), default: [:]].merge(v) { _, new in new } }
        }
        self.files = kept
        self.updatedAt = updatedAt
    }

    /// A file name as it is keyed: composed (NFC), so a name read back from the file system in either form matches.
    public static func key(_ fileName: String) -> String { fileName.precomposedStringWithCanonicalMapping }

    /// The user's values for the file named `fileName` in this folder.
    public func values(for fileName: String) -> [CheckableField: String] { files[Self.key(fileName)] ?? [:] }

    /// Sets the user's value of `field` for `fileName`, trimmed; "" says the file has none, nil takes the user's value
    /// away. A date field is not an item field and is ignored (dates are tags).
    public mutating func set(_ field: CheckableField, to value: String?, for fileName: String) {
        guard CheckableField.itemFields.contains(field) else { return }
        let k = Self.key(fileName)
        var values = files[k] ?? [:]
        values[field] = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        files[k] = values.isEmpty ? nil : values
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
            case .date, .sentWith: continue
            }
        }
        return f
    }
}

extension CheckableField {
    /// The JSON key of an item field in `item-fields.json`; nil for the dates.
    public var jsonKey: String? {
        switch self {
        case .date, .sentWith: return nil
        case .documentKind: return "documentKind"
        case .title: return "title"
        case .byline: return "byline"
        case .publication: return "publication"
        case .publicationDate: return "publicationDate"
        case .recipientPlace: return "recipientPlace"
        }
    }

    init?(jsonKey: String) {
        guard let f = CheckableField.itemFields.first(where: { $0.jsonKey == jsonKey }) else { return nil }
        self = f
    }
}

extension UserItemFields: Codable {
    private enum CodingKeys: String, CodingKey { case schemaVersion, files, updatedAt }

    public init(from decoder: Decoder) throws {
        try decoder.refuseUnknownKeys(["schemaVersion", "files", "updatedAt"])
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
        self.init(files: files, updatedAt: try c.decodeIfPresent(Date.self, forKey: .updatedAt))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(UserItemFields.schemaVersion, forKey: .schemaVersion)
        let raw = files.mapValues { values in
            Dictionary(uniqueKeysWithValues: values.compactMap { f, v in f.jsonKey.map { ($0, v) } })
        }
        try c.encode(raw, forKey: .files)
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
                  expecting: expecting)
    }
}
