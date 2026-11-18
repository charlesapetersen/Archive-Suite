import Foundation

// MARK: - Where an item sits in its archive: the record (W47.ct-spec)
//
// The contract is `SPEC/containers.md`. A run is a record per container (collection, box, folder) starting at a file
// name; an item inherits from the runs that cover it and from the directories above it (`ContainerResolver`). The
// container file holds the runs of one directory (`ContainerFileStore`); the level map says what each depth of a
// folder tree names (`ContainerLevelMap`). Reading is lenient: a key, source or level this build does not know drops
// that value or run, never the document.

/// The depth of a container. Shallower first: a collection holds boxes, a box holds folders.
public enum ContainerLevel: String, Sendable, CaseIterable, Codable, Comparable {
    case collection, box, folder

    public var depth: Int {
        switch self {
        case .collection: return 0
        case .box: return 1
        case .folder: return 2
        }
    }

    public static func < (a: ContainerLevel, b: ContainerLevel) -> Bool { a.depth < b.depth }
}

/// The fields of a container record (`SPEC/containers.md` §The fields; `ct_truth.py` `FIELDS_REV`).
public enum ContainerField: String, Sendable, CaseIterable, Codable {
    case repository, place, collectionTitle, collectionSubtitle, collectionNumber, accession, series, seriesTitle
    case container, boxTitle, folder, folderTitle, date, other

    /// The level the field belongs to; nil for `date` and `other`, which take the level of the run that holds them.
    public var homeLevel: ContainerLevel? {
        switch self {
        case .repository, .place, .collectionTitle, .collectionSubtitle, .collectionNumber, .accession, .series,
             .seriesTitle:
            return .collection
        case .container, .boxTitle: return .box
        case .folder, .folderTitle: return .folder
        case .date, .other: return nil
        }
    }

    /// The segbench name (`ct_truth.py` `FIELDS_REV`).
    public var benchName: String {
        switch self {
        case .collectionTitle: return "collection_title"
        case .collectionSubtitle: return "collection_subtitle"
        case .collectionNumber: return "collection_number"
        case .seriesTitle: return "series_title"
        case .boxTitle: return "box_title"
        case .folderTitle: return "folder_title"
        default: return rawValue
        }
    }

    public var label: String {
        switch self {
        case .repository: return "Repository"
        case .place: return "Place"
        case .collectionTitle: return "Collection title"
        case .collectionSubtitle: return "Collection subtitle"
        case .collectionNumber: return "Collection number"
        case .accession: return "Accession"
        case .series: return "Series"
        case .seriesTitle: return "Series title"
        case .container: return "Container"
        case .boxTitle: return "Box title"
        case .folder: return "Folder"
        case .folderTitle: return "Folder title"
        case .date: return "Date or time period"
        case .other: return "Other identifying marks"
        }
    }
}

/// Where a value came from. Precedence: user, then label, then path.
public enum ContainerSource: String, Sendable, CaseIterable, Codable, Comparable {
    case path, label, user

    public var rank: Int {
        switch self {
        case .path: return 0
        case .label: return 1
        case .user: return 2
        }
    }

    public static func < (a: ContainerSource, b: ContainerSource) -> Bool { a.rank < b.rank }
}

/// One field's value and its provenance. A user's `""` means "none here" and hides every other source.
public struct ContainerValue: Equatable, Sendable, Codable {
    public var value: String
    public var source: ContainerSource
    /// For a label read: the route that read it (`vision+parser`, `gpt-5.6-luna`, `gemma-3-12b`).
    public var reader: String?
    /// 0 to 1, a display hint only.
    public var confidence: Double?
    public var at: Date?

    public init(_ value: String, source: ContainerSource, reader: String? = nil, confidence: Double? = nil,
                at: Date? = nil) {
        self.value = value
        self.source = source
        self.reader = reader
        self.confidence = confidence.map { min(1, max(0, $0)) }
        self.at = at
    }

    /// The value as shown: nil for an empty one.
    public var shown: String? {
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Confirming a label proposal makes it the user's, keeping its reader.
    public func confirmed(at date: Date? = nil) -> ContainerValue {
        ContainerValue(value, source: .user, reader: reader, confidence: confidence, at: date ?? at)
    }

    public init(from decoder: Decoder) throws {
        decoder.noteUnknownKeys(["value", "source", "reader", "confidence", "at"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var confidence = decoder.optional(Double.self, c, .confidence)
        if let x = confidence, !x.isFinite || x < 0 || x > 1 { decoder.noteDrop(); confidence = nil }
        self.init(try c.decode(String.self, forKey: .value),
                  source: try c.decode(ContainerSource.self, forKey: .source),
                  reader: decoder.optional(String.self, c, .reader),
                  confidence: confidence,
                  at: decoder.optional(Date.self, c, .at))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(value, forKey: .value)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(reader, forKey: .reader)
        try c.encodeIfPresent(confidence, forKey: .confidence)
        try c.encodeIfPresent(at, forKey: .at)
    }

    private enum CodingKeys: String, CodingKey { case value, source, reader, confidence, at }
}

/// A set of field values, encoded as a JSON object keyed by field name. Unknown keys and unreadable values are
/// dropped on reading.
public struct ContainerFieldSet: Equatable, Sendable, Codable {
    public var values: [ContainerField: ContainerValue]

    public init(_ values: [ContainerField: ContainerValue] = [:]) { self.values = values }

    public subscript(field: ContainerField) -> ContainerValue? {
        get { values[field] }
        set { values[field] = newValue }
    }

    public var isEmpty: Bool { values.isEmpty }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: ContainerJSONKey.self)
        var values: [ContainerField: ContainerValue] = [:]
        for key in c.allKeys where !((try? c.decodeNil(forKey: key)) ?? false) {
            guard let field = ContainerField(rawValue: key.stringValue),
                  let value = try? c.decode(ContainerValue.self, forKey: key) else { decoder.noteDrop(); continue }
            values[field] = value
        }
        self.values = values
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: ContainerJSONKey.self)
        for (field, value) in values { try c.encode(value, forKey: ContainerJSONKey(field.rawValue)) }
    }
}

/// A record per container: it starts at `start` and covers the files after it, in `ContainerOrder`, up to the next
/// run of its own level or a shallower one.
public struct ContainerRun: Equatable, Sendable, Codable {
    /// The file name the run begins at. It need not exist: the run begins where the name would sort.
    public var start: String
    public var level: ContainerLevel
    public var fields: ContainerFieldSet

    public init(start: String, level: ContainerLevel, fields: ContainerFieldSet = ContainerFieldSet()) {
        self.start = start
        self.level = level
        self.fields = fields
    }

    private enum CodingKeys: String, CodingKey { case start, level, fields }

    public init(from decoder: Decoder) throws {
        decoder.noteUnknownKeys(["start", "level", "fields"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(start: try c.decode(String.self, forKey: .start),
                  level: try c.decode(ContainerLevel.self, forKey: .level),
                  fields: decoder.optional(ContainerFieldSet.self, c, .fields) ?? ContainerFieldSet())
    }
}

/// One directory's container file (`<directory>/.archivesuite/containers.json`).
public struct ContainerFile: Equatable, Sendable {
    public static let folderName = ".archivesuite"
    public static let fileName = "containers.json"
    public static let schemaVersion = 1
    public static let maxFileBytes = 1024 * 1024

    /// Values for every file in this directory and below.
    public var directory: ContainerFieldSet
    /// In `start` order, shallow to deep at one start; one run per start and level (`normalised`). Assigning
    /// re-sorts, so edit a copy and assign it once rather than changing runs in place by index.
    public var runs: [ContainerRun] { didSet { runs = ContainerFile.normalised(runs) } }
    public var updatedAt: Date?

    public init(directory: ContainerFieldSet = ContainerFieldSet(), runs: [ContainerRun] = [], updatedAt: Date? = nil) {
        self.directory = directory
        self.runs = ContainerFile.normalised(runs)
        self.updatedAt = updatedAt
    }

    /// Sorted by start then level, keeping the first of any runs that share a start and level.
    public static func normalised(_ runs: [ContainerRun]) -> [ContainerRun] {
        var seen = Set<String>()
        var kept: [ContainerRun] = []
        for run in runs where !run.start.isEmpty {
            guard seen.insert(run.level.rawValue + "\u{0}" + run.start).inserted else { continue }
            kept.append(run)
        }
        // `precedes` is a strict total order on distinct names, so this has no ties left.
        return kept.sorted { a, b in
            a.start == b.start ? a.level < b.level : ContainerOrder.precedes(a.start, b.start)
        }
    }
}

extension ContainerFile: Codable {
    private enum CodingKeys: String, CodingKey { case schemaVersion, directory, runs, updatedAt }
    private enum DirectoryKeys: String, CodingKey { case fields }

    // Lenient, but every value dropped is noted (`ContainerDropLog`), so a writer never overwrites it.
    public init(from decoder: Decoder) throws {
        decoder.noteUnknownKeys(["schemaVersion", "directory", "runs", "updatedAt"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var directory = ContainerFieldSet()
        if c.contains(.directory), !((try? c.decodeNil(forKey: .directory)) ?? false) {
            if let d = try? c.nestedContainer(keyedBy: DirectoryKeys.self, forKey: .directory) {
                if let sub = try? c.superDecoder(forKey: .directory) { sub.noteUnknownKeys(["fields"]) }
                directory = decoder.optional(ContainerFieldSet.self, d, .fields) ?? ContainerFieldSet()
            } else {
                decoder.noteDrop()
            }
        }
        let read = (decoder.optional([LenientRun].self, c, .runs) ?? []).compactMap(\.value)
        let runs = ContainerFile.normalised(read)
        if runs.count != read.count { decoder.noteDrop() }   // a duplicate or an empty start
        self.init(directory: directory, runs: runs, updatedAt: decoder.optional(Date.self, c, .updatedAt))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ContainerFile.schemaVersion, forKey: .schemaVersion)
        var d = c.nestedContainer(keyedBy: DirectoryKeys.self, forKey: .directory)
        try d.encode(directory, forKey: .fields)
        try c.encode(ContainerFile.normalised(runs), forKey: .runs)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }

    private struct LenientRun: Decodable {
        let value: ContainerRun?
        init(from decoder: Decoder) throws {
            do { value = try ContainerRun(from: decoder) } catch { decoder.noteDrop(); value = nil }
        }
    }
}

/// File order within one directory: Finder's (`localizedStandardCompare`), ties broken by plain comparison.
public enum ContainerOrder {
    public static func precedes(_ a: String, _ b: String) -> Bool {
        switch a.localizedStandardCompare(b) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return a < b
        }
    }

    /// `a` sorts at or before `b`.
    public static func atOrBefore(_ a: String, _ b: String) -> Bool { a == b || precedes(a, b) }
}

/// Collects, while one document is decoded, whether reading dropped anything (`ContainerFileStamp.droppedOnReading`).
/// Decoding is single-threaded; the log is made and read by `ContainerFileStore.read`.
final class ContainerDropLog: @unchecked Sendable {
    var dropped = false
    static let key = CodingUserInfoKey(rawValue: "archivesuite.container.drops")!
}

extension Decoder {
    func noteDrop() { (userInfo[ContainerDropLog.key] as? ContainerDropLog)?.dropped = true }

    /// Notes a drop for each key outside `known` that holds anything but null.
    func noteUnknownKeys(_ known: Set<String>) {
        guard let c = try? container(keyedBy: ContainerJSONKey.self) else { return }
        for key in c.allKeys where !known.contains(key.stringValue) {
            if !((try? c.decodeNil(forKey: key)) ?? false) { noteDrop() }
        }
    }

    /// An optional value: absent or null is nil; present but unreadable is nil and noted as a drop.
    func optional<T: Decodable, K: CodingKey>(_ type: T.Type, _ c: KeyedDecodingContainer<K>, _ key: K) -> T? {
        guard c.contains(key), !((try? c.decodeNil(forKey: key)) ?? true) else { return nil }
        do { return try c.decode(T.self, forKey: key) } catch { noteDrop(); return nil }
    }
}

private struct ContainerJSONKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
