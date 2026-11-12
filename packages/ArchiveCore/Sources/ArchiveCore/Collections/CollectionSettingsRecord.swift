import Foundation
import Darwin

// MARK: - The collection's settings document, read-only (W46.settings-reader-notes)
//
// The Processor writes `<output>/.archivesuite/collection-settings.json` and one file per run in `.archivesuite/runs/`
// (`SPEC/collection-settings.md`, writer in the Processor's `Settings/SettingsLayerStore.swift`). The Reader and Notes
// read them here to show what produced a collection. This side never writes: it looks with `lstat`, refuses links and
// anything over 1 MB, and reads leniently, so an entry of a kind it does not know is dropped rather than failing the
// document. A document or run of a newer `schemaVersion` is not interpreted; the record says so instead.

/// What produced a collection, as the Reader and Notes show it.
public struct CollectionSettingsRecord: Equatable, Sendable {
    public static let folderName = ".archivesuite"
    public static let fileName = "collection-settings.json"
    public static let runsFolderName = "runs"
    public static let schemaVersion = 1
    /// The writer's own cap (`CollectionSettingsFile.maxBytes`); a bigger file is left alone on both sides.
    public static let maxFileBytes = 1024 * 1024
    /// The newest runs read; older ones are only counted.
    public static let maxRunsRead = 20

    /// One value as shown: the label, the value in words, and where it came from.
    public struct Setting: Equatable, Sendable, Identifiable {
        public var id: String { key }
        public let key: String
        public let label: String
        public let value: String
        public let source: String
    }

    /// One run, with the settings frozen when it started.
    public struct Run: Equatable, Sendable, Identifiable {
        public let id: String
        public let startedAt: Date?
        /// `processFiles`, `batch`, `preOCRed`, `reOCR`, `mixed`, `liveCapture`.
        public let kind: String
        public let fileCount: Int?
        public let projectName: String?
        public let macMemoryGB: Double?
        /// Every layered value, by label.
        public let settings: [Setting]
        /// The app's processing settings by their `UserDefaults` names, the value in words, sorted by name.
        public let processing: [Setting]
        /// The run is of a newer `schemaVersion` than this build reads; only its date and kind are shown.
        public let isNewer: Bool

        public var kindLabel: String { CollectionSettingsVocabulary.runKindLabel(kind) }

        /// The reading route in words, from the processing settings: "Gemini, gemini-3.7-flash", "Apple Vision".
        public var reader: String? {
            let byKey = Dictionary(processing.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
            if byKey["useAppleVision"] == "On" { return "Apple Vision (on this Mac)" }
            if byKey["useGateway"] == "On" {
                let name = byKey["gatewayDisplayName"].flatMap { $0.isEmpty ? nil : $0 } ?? byKey["gatewayModelID"]
                return ["A gateway", name].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ", ")
            }
            guard let provider = byKey["selectedProvider"], !provider.isEmpty else { return nil }
            let model = byKey["selectedModelId_\(provider)"].flatMap { $0.isEmpty ? nil : $0 }
            return [CollectionSettingsVocabulary.providerLabel(provider), model].compactMap { $0 }.joined(separator: ", ")
        }
    }

    /// The folder the document sits in: the collection.
    public let collectionFolder: URL
    public let collectionName: String?
    public let collectionID: String?
    public let createdAt: Date?
    public let projectName: String?
    /// The collection's own answers (it holds only those it answered itself).
    public let ownSettings: [Setting]
    /// Newest first, at most `maxRunsRead`.
    public let runs: [Run]
    /// Run files found in all, read or not.
    public let runFileCount: Int
    /// Run files read but not understood.
    public let unreadableRunCount: Int
    /// The document is of a newer `schemaVersion`; nothing in it is interpreted.
    public let documentIsNewer: Bool
    /// The document exists but could not be read (too big, not JSON, not a file).
    public let documentUnreadable: Bool

    public var latestRun: Run? { runs.first }

    // MARK: Finding and loading

    /// The nearest collection folder holding a settings document or run records, from the folder that contains
    /// `fileURL` upward. With a `root`, the walk stops at it (inclusive) and a file outside it finds nothing; without
    /// one, only the file's own folder is looked at.
    /// Both sides are put through `resolvingSymlinksInPath` first, so a root spelled through a link (or `/var` for
    /// `/private/var`) still contains its files, and a file whose folders lead out of the root finds nothing.
    public static func locate(from fileURL: URL, within root: URL? = nil) -> URL? {
        var folder = fileURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        guard let root = root?.resolvingSymlinksInPath().standardizedFileURL else {
            return hasRecord(folder) ? folder : nil
        }
        let rootParts = root.pathComponents
        for _ in 0..<64 {
            let parts = folder.pathComponents
            guard parts.count >= rootParts.count, Array(parts.prefix(rootParts.count)) == rootParts else { return nil }
            if hasRecord(folder) { return folder }
            if parts.count == rootParts.count { return nil }
            folder = folder.deletingLastPathComponent()
        }
        return nil
    }

    /// Whether `folder/.archivesuite` is an ordinary folder holding the document or a `runs` folder.
    public static func hasRecord(_ folder: URL) -> Bool {
        let dir = folder.appendingPathComponent(folderName, isDirectory: true)
        guard fileType(dir) == S_IFDIR else { return false }
        return fileType(dir.appendingPathComponent(fileName)) == S_IFREG
            || fileType(dir.appendingPathComponent(runsFolderName, isDirectory: true)) == S_IFDIR
    }

    /// Reads the record of the collection at `folder`, or nil when it has none. Never writes.
    public static func load(collectionFolder folder: URL) -> CollectionSettingsRecord? {
        let dir = folder.appendingPathComponent(folderName, isDirectory: true)
        guard fileType(dir) == S_IFDIR else { return nil }
        let docURL = dir.appendingPathComponent(fileName)
        let runsURL = dir.appendingPathComponent(runsFolderName, isDirectory: true)

        var doc: DocumentDTO?
        var docNewer = false, docUnreadable = false
        if let type = fileType(docURL) {
            if type == S_IFREG, let data = readSmallFile(docURL) {
                if let v = try? decoder.decode(VersionDTO.self, from: data), v.schemaVersion > schemaVersion {
                    docNewer = true
                } else if let d = try? decoder.decode(DocumentDTO.self, from: data) {
                    doc = d
                } else {
                    docUnreadable = true
                }
            } else {
                docUnreadable = true
            }
        }

        var runs: [Run] = []
        var runFiles: [String] = []
        var unreadable = 0
        if fileType(runsURL) == S_IFDIR {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: runsURL.path)) ?? []
            // Names start with the UTC start stamp, so name order is time order.
            runFiles = names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted(by: >)
            for name in runFiles.prefix(maxRunsRead) {
                let url = runsURL.appendingPathComponent(name)
                guard fileType(url) == S_IFREG, let data = readSmallFile(url) else { unreadable += 1; continue }
                if let v = try? decoder.decode(VersionDTO.self, from: data), v.schemaVersion > schemaVersion {
                    let head = try? decoder.decode(RunHeadDTO.self, from: data)
                    runs.append(Run(id: head?.id ?? name, startedAt: head?.startedAt, kind: head?.kind ?? "",
                                    fileCount: nil, projectName: nil, macMemoryGB: nil, settings: [], processing: [],
                                    isNewer: true))
                } else if let r = try? decoder.decode(RunDTO.self, from: data) {
                    runs.append(r.run)
                } else {
                    unreadable += 1
                }
            }
            runs.sort { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
        }

        guard doc != nil || docNewer || docUnreadable || !runFiles.isEmpty else { return nil }
        // As the Processor reads a collection's layer: a value only the general layer may hold is ignored.
        let ownEntries = doc?.collection?.kind == "collection" ? doc?.collection?.entries ?? [:] : [:]
        let own = ownEntries.compactMap { key, e -> Setting? in
            guard !CollectionSettingsVocabulary.generalOnlyKeys.contains(key), let value = e.value?.value else {
                return nil
            }
            return Setting(key: key, label: CollectionSettingsVocabulary.label(key),
                           value: CollectionSettingsVocabulary.describe(key, value),
                           source: "set for this collection" + (e.source.map { ", \($0.phrase)" } ?? ""))
        }.sorted { $0.label < $1.label }
        return CollectionSettingsRecord(
            collectionFolder: folder, collectionName: doc?.collection?.name, collectionID: doc?.collection?.id,
            createdAt: doc?.createdAt, projectName: doc?.projectName ?? runs.first?.projectName, ownSettings: own,
            runs: runs, runFileCount: runFiles.count, unreadableRunCount: unreadable, documentIsNewer: docNewer,
            documentUnreadable: docUnreadable)
    }

    /// `lstat`'s file type, or nil when there is nothing there. A link reports `S_IFLNK`, so it is never followed.
    private static func fileType(_ url: URL) -> mode_t? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return st.st_mode & S_IFMT
    }

    /// The file's bytes when it is an ordinary file of at most `maxFileBytes`, opened without following a link.
    private static func readSmallFile(_ url: URL) -> Data? {
        // O_NONBLOCK: a FIFO swapped in after the lstat must not park the thread in open().
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= maxFileBytes else { return nil }
        guard let data = try? handle.read(upToCount: maxFileBytes + 1), data.count <= maxFileBytes else { return nil }
        return data
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = isoWhole.date(from: s) ?? isoFractional.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "date \(s)"))
        }
        return d
    }()
    nonisolated(unsafe) private static let isoWhole = ISO8601DateFormatter()
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

// MARK: - The JSON shapes (SPEC/collection-settings.md), decoded leniently

/// A value: `{ "type": T, "value": … }`.
public enum CollectionSettingValue: Equatable, Sendable, Decodable {
    case bool(Bool), int(Int), double(Double), string(String), strings([String]), numbers([String: Double])

    private enum CodingKeys: String, CodingKey { case type, value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "bool": self = .bool(try c.decode(Bool.self, forKey: .value))
        case "int": self = .int(try c.decode(Int.self, forKey: .value))
        case "double": self = .double(try c.decode(Double.self, forKey: .value))
        case "string": self = .string(try c.decode(String.self, forKey: .value))
        case "strings": self = .strings(try c.decode([String].self, forKey: .value))
        case "numbers": self = .numbers(try c.decode([String: Double].self, forKey: .value))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "kind \(other)")
        }
    }
}

/// How a layer came to hold a value: Swift's synthesized enum coding, one key naming the case.
public enum CollectionSettingSource: Equatable, Sendable, Decodable {
    case setByUser(Date)
    case measured(Date, sample: Int)
    case startingPoint(String, Date)
    case detected(Date)
    /// Set by the Processor from another answer, by that answer's label (W46.settings-interviews).
    case follows(String, Date)

    private enum CaseKeys: String, CodingKey { case setByUser, measured, startingPoint, detected, follows }
    private enum Fields: String, CodingKey { case _0, _1, sample }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CaseKeys.self)
        guard c.allKeys.count == 1, let key = c.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "one case expected"))
        }
        let f = try c.nestedContainer(keyedBy: Fields.self, forKey: key)
        switch key {
        case .setByUser: self = .setByUser(try f.decode(Date.self, forKey: ._0))
        case .measured: self = .measured(try f.decode(Date.self, forKey: ._0), sample: try f.decode(Int.self, forKey: .sample))
        case .startingPoint:
            self = .startingPoint(try f.decode(String.self, forKey: ._0), try f.decode(Date.self, forKey: ._1))
        case .detected: self = .detected(try f.decode(Date.self, forKey: ._0))
        case .follows: self = .follows(try f.decode(String.self, forKey: ._0), try f.decode(Date.self, forKey: ._1))
        }
    }

    /// The same words the Processor's Settings window uses (`SettingsSource.phrase`).
    public var phrase: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        switch self {
        case .setByUser(let d): return "you set this on \(f.string(from: d))"
        case .measured(let d, let n): return "measured on \(f.string(from: d)) from \(n) photo\(n == 1 ? "" : "s")"
        case .startingPoint(let name, let d): return "filled by “\(name)” on \(f.string(from: d))"
        case .detected(let d): return "found on this Mac on \(f.string(from: d))"
        case .follows(let answer, let d): return "follows your answer to “\(answer)”, \(f.string(from: d))"
        }
    }
}

/// Decodes to nil instead of failing, so one unknown entry does not lose the rest.
private struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

private struct VersionDTO: Decodable { let schemaVersion: Int }

private struct EntryDTO: Decodable {
    let value: Lenient<CollectionSettingValue>?
    let source: CollectionSettingSource?
    private enum CodingKeys: String, CodingKey { case value, source }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = try c.decodeIfPresent(Lenient<CollectionSettingValue>.self, forKey: .value)
        source = try? c.decodeIfPresent(CollectionSettingSource.self, forKey: .source)
    }
}

private struct LayerDTO: Decodable {
    let id: String?
    let kind: String?
    let name: String?
    let entries: [String: EntryDTO]
    private enum CodingKeys: String, CodingKey { case id, kind, name, entries }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try? c.decodeIfPresent(String.self, forKey: .id)
        kind = try? c.decodeIfPresent(String.self, forKey: .kind)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        entries = ((try? c.decodeIfPresent([String: Lenient<EntryDTO>].self, forKey: .entries)) ?? [:])
            .compactMapValues(\.value)
    }
}

private struct DocumentDTO: Decodable {
    let schemaVersion: Int
    let createdAt: Date?
    let collection: LayerDTO?
    let projectName: String?
    private enum CodingKeys: String, CodingKey { case schemaVersion, createdAt, collection, projectName }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
        collection = try? c.decodeIfPresent(LayerDTO.self, forKey: .collection)
        projectName = try? c.decodeIfPresent(String.self, forKey: .projectName)
    }
}

private struct RunHeadDTO: Decodable {
    let id: String?
    let startedAt: Date?
    let kind: String?
    private enum CodingKeys: String, CodingKey { case id, startedAt, kind }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try? c.decodeIfPresent(String.self, forKey: .id)
        startedAt = try? c.decodeIfPresent(Date.self, forKey: .startedAt)
        kind = try? c.decodeIfPresent(String.self, forKey: .kind)
    }
}

private struct ResolvedDTO: Decodable {
    let value: CollectionSettingValue
    let layer: String?
    let source: CollectionSettingSource?
    let layerName: String?
    private enum CodingKeys: String, CodingKey { case value, layer, source, layerName }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = try c.decode(CollectionSettingValue.self, forKey: .value)
        layer = try? c.decodeIfPresent(String.self, forKey: .layer)
        source = try? c.decodeIfPresent(CollectionSettingSource.self, forKey: .source)
        layerName = try? c.decodeIfPresent(String.self, forKey: .layerName)
    }

    /// The Processor's `ResolvedSetting.sourceText`.
    var sourceText: String {
        let tail = source.map { ", \($0.phrase)" } ?? ""
        switch layer {
        case "general": return "from the Processor's general settings" + tail
        case "project": return "from the project “\(layerName ?? "")”" + tail
        case "collection": return "set for this collection" + tail
        default: return "built in: Free, on this Mac"
        }
    }
}

private struct SnapshotDTO: Decodable {
    let projectName: String?
    let macMemoryGB: Double?
    let values: [String: ResolvedDTO]
    let processing: [String: CollectionSettingValue]
    private enum CodingKeys: String, CodingKey { case projectName, macMemoryGB, values, processing }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectName = try? c.decodeIfPresent(String.self, forKey: .projectName)
        macMemoryGB = try? c.decodeIfPresent(Double.self, forKey: .macMemoryGB)
        values = ((try? c.decodeIfPresent([String: Lenient<ResolvedDTO>].self, forKey: .values)) ?? [:])
            .compactMapValues(\.value)
        processing = ((try? c.decodeIfPresent([String: Lenient<CollectionSettingValue>].self, forKey: .processing))
            ?? [:]).compactMapValues(\.value)
    }
}

private struct RunDTO: Decodable {
    let schemaVersion: Int
    let id: String
    let startedAt: Date?
    let kind: String
    let fileCount: Int?
    let settings: SnapshotDTO?
    private enum CodingKeys: String, CodingKey { case schemaVersion, id, startedAt, kind, fileCount, settings }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        id = try c.decode(String.self, forKey: .id)
        startedAt = try? c.decodeIfPresent(Date.self, forKey: .startedAt)
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? ""
        fileCount = try? c.decodeIfPresent(Int.self, forKey: .fileCount)
        settings = try? c.decodeIfPresent(SnapshotDTO.self, forKey: .settings)
    }

    var run: CollectionSettingsRecord.Run {
        let settings = (self.settings?.values ?? [:]).map { key, v in
            CollectionSettingsRecord.Setting(key: key, label: CollectionSettingsVocabulary.label(key),
                                             value: CollectionSettingsVocabulary.describe(key, v.value),
                                             source: v.sourceText)
        }.sorted { $0.label < $1.label }
        let processing = (self.settings?.processing ?? [:]).map { key, v in
            CollectionSettingsRecord.Setting(key: key, label: key, value: CollectionSettingsVocabulary.plain(v),
                                             source: "")
        }.sorted { $0.key < $1.key }
        return .init(id: id, startedAt: startedAt, kind: kind, fileCount: fileCount,
                     projectName: self.settings?.projectName, macMemoryGB: self.settings?.macMemoryGB,
                     settings: settings, processing: processing, isNewer: false)
    }
}

// MARK: - Words

/// The labels and value words the Processor's Settings window uses (`SettingsKey.label` / `describe`), kept in step
/// with it by the Processor's settings-layers test driver, which checks every catalog key and every answer's words
/// against this table.
public enum CollectionSettingsVocabulary {
    public static let labels: [String: String] = [
        "keys": "API keys found",
        "plans": "Signed-in plans",
        "cluster": "A computing cluster",
        "gpusPerJob": "Graphics cards a cluster job may use",
        "downloadsAllowed": "Models may be downloaded to this Mac",
        "moneyHabit": "Spending",
        "monthCeilingUSD": "Most to spend in a month",
        "fineTuning": "Training a model on your corrections",
        "batchCeilingUSD": "Most to spend on a batch",
        "hours": "How long a batch may run",
        "excludedModelFamilies": "Models pages are never sent to",
        "mix": "Kinds of document",
        "strata": "Public test sets that apply",
        "period": "Period",
        "languages": "Languages",
        "scripts": "Scripts",
        "preference": "When two choices are close",
        "priorities": "What matters most",
        "weights": "How much each one counts",
        "staysOnMac": "Pages stay on this Mac",
        "readingFallback": "A page that fails goes to another reader",
        "checkingMinutes": "Minutes you will spend checking where documents begin",
        "straightenReadingCopy": "Straighten the copy you read",
    ]

    /// The values only the general layer holds (`SettingsKey.generalOnly`); a collection's copy is ignored.
    public static let generalOnlyKeys: Set<String> = [
        "keys", "plans", "cluster", "gpusPerJob", "downloadsAllowed", "moneyHabit", "monthCeilingUSD", "fineTuning",
    ]

    static let overridePrefix = "override."

    public static func label(_ key: String) -> String {
        if key.hasPrefix(overridePrefix) {
            let parts = key.dropFirst(overridePrefix.count).split(separator: ".", maxSplits: 1)
            let stage = parts.first.map(String.init) ?? ""
            let part = parts.count > 1 ? String(parts[1]) : "all"
            return part == "all" ? "Your choice for \(stage)" : "Your choice for \(stage) (\(part))"
        }
        return labels[key] ?? key
    }

    public static func describe(_ key: String, _ value: CollectionSettingValue) -> String {
        switch value {
        case .bool(let b): return b ? "On" : "Off"
        case .int(let i): return "\(i)"
        case .double(let d):
            switch key {
            case "batchCeilingUSD", "monthCeilingUSD": return String(format: "$%.2f", d)
            case "hours": return d == 1 ? "1 hour" : String(format: "%g hours", d)
            case "checkingMinutes": return String(format: "%g minutes", d)
            default: return String(format: "%g", d)
            }
        case .string(let s):
            if s.isEmpty { return key.hasPrefix(overridePrefix) ? "the app's pick" : "not given" }
            let words: [String: String]
            switch key {
            case "moneyHabit":
                words = ["none": "Nothing is spent", "perBatch": "A ceiling for each batch",
                         "perMonth": "A ceiling for each month", "noCeiling": "No ceiling"]
            case "preference":
                words = ["bestMeasured": "The best measured", "cheapestWithinPoint": "The cheaper, within a point",
                         "fastestWithinPoint": "The faster, within a point"]
            case "fineTuning":
                words = ["no": "No", "codingAgent": "With a coding agent", "cluster": "On a cluster"]
            default: words = [:]
            }
            return words[s] ?? s
        case .strings(let list):
            guard !list.isEmpty else { return "none" }
            switch key {
            case "priorities":
                return list.map { priorityWords[$0] ?? $0 }.joined(separator: ", then ")
            case "languages":
                return list.map { languageWords[$0] ?? $0 }.joined(separator: ", ")
            case "scripts":
                return list.map { s -> String in
                    let parts = s.split(separator: ":", maxSplits: 1).map(String.init)
                    let name = scriptWords[parts[0]] ?? parts[0]
                    return parts.count > 1 ? "\(name) \(parts[1])%" : name
                }.joined(separator: ", ")
            default:
                return list.joined(separator: ", ")
            }
        case .numbers(let n):
            guard !n.isEmpty else { return "none" }
            let sorted = n.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            func number(_ x: Double) -> String { String(format: "%.0f", x) }
            switch key {
            case "weights":
                return sorted.map { "\(priorityWords[$0.key] ?? $0.key) \(number($0.value))" }.joined(separator: ", ")
            case "strata":
                return sorted.map { "\(number($0.value))% judged on \(stratumWords[$0.key] ?? $0.key)" }
                    .joined(separator: "; ")
            case "mix":
                return sorted.map { "\(kindWords[$0.key] ?? $0.key) \(number($0.value))%" }.joined(separator: ", ")
            default:
                return sorted.map { "\($0.key) \(String(format: "%g", $0.value))%" }.joined(separator: ", ")
            }
        }
    }

    // The Processor's words for the collection interview's values (`SettingsInterviews.swift`).
    static let priorityWords = ["reading": "reading", "findingDocuments": "finding documents", "dates": "dates",
                                "names": "names"]
    static let languageWords = ["en": "English", "fr": "French", "de": "German", "nl": "Dutch", "es": "Spanish",
                                "pt": "Portuguese", "it": "Italian", "la": "Latin", "other": "Another language"]
    static let scriptWords = [
        "latin": "Latin alphabet (English, French, German…)", "kurrent": "German handwriting (Kurrent or secretary hand)",
        "fraktur": "Blackletter or Fraktur print", "greek": "Greek", "hebrew": "Hebrew", "arabic": "Arabic",
        "cyrillic": "Cyrillic", "chinese": "Chinese", "devanagari": "Devanagari",
    ]
    static let kindWords = [
        "handwritten": "handwritten", "typewritten": "typewritten", "printed": "printed", "forms": "form or table",
        "clippings": "newspaper clippings", "newspapers": "whole newspaper pages", "registers": "registers and ledgers",
        "mixed": "typed pages with handwriting on them",
    ]
    static let stratumWords = [
        "L4": "ledgers, forms and tables, 1800-1950",
        "L5": "Dutch, Spanish and Portuguese archival hands, 1600-1850",
        "L6": "German Kurrent and secretary hands, 1500-1900",
        "L7": "medieval and early-modern charters, before 1600",
        "L8": "printed books and pamphlets, Fraktur included, 1500-1900",
        "L9": "newspapers from microfilm, 1850-1920",
        "N1": "Arabic manuscripts", "N2": "Cyrillic, early 1700s", "N3": "Greek minuscule, about 1500",
        "N4": "Hebrew book hands, medieval", "N5": "Chinese print", "N6": "Devanagari print",
    ]

    /// A processing setting's value with no key-specific words.
    public static func plain(_ value: CollectionSettingValue) -> String {
        switch value {
        case .string(let s): return s
        default: return describe("", value)
        }
    }

    public static func runKindLabel(_ kind: String) -> String {
        switch kind {
        case "processFiles": return "Processed files"
        case "batch": return "A paid batch"
        case "preOCRed": return "Already-read PDFs tagged"
        case "reOCR": return "PDFs read again"
        case "mixed": return "PDFs read again, with images"
        case "liveCapture": return "Live Capture"
        default: return kind.isEmpty ? "A run" : kind
        }
    }

    public static func providerLabel(_ raw: String) -> String {
        // The Processor's `LLMProvider` raw values.
        switch raw {
        case "Anthropic": return "Claude"
        case "OpenAI": return "ChatGPT"
        default: return raw
        }
    }
}
