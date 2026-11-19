import Foundation
import ArchiveCore

// MARK: - Where each file sits in its archive (W47.ct-reader-view; `SPEC/containers.md`)
//
// The Reader reads every directory's container file (`.archivesuite/containers.json`), the tree's level map and the
// user's standard names, and resolves each listed file through ArchiveCore's inheritance rule (`ContainerResolver`),
// the path values the level map gives its folders and the box and folder numbers in its own name. Values are shown
// through `ContainerDisplay` (title case, standard names) and a disagreement between candidates is shown, never
// settled. Read only: nothing here writes, and the level map is written only from `ContainerLevelsDraft` on the
// user's say-so. Built off the main thread; a directory with no `.archivesuite` costs one failed open.

/// The container facets the list filters by (the plan's Design 4: repository, collection, accession, series and
/// container).
enum ContainerFacet: String, CaseIterable, Codable, Sendable {
    case repository, collection, accession, series, container

    var label: String {
        switch self {
        case .repository: return "Repository"
        case .collection: return "Collection"
        case .accession: return "Accession"
        case .series: return "Series"
        case .container: return "Container"
        }
    }

    /// The facet's value among a file's shown values: the collection by its title, else its number.
    func value(in shown: [ContainerField: ContainerShownValue]) -> String? {
        switch self {
        case .repository: return shown[.repository]?.text
        case .collection: return shown[.collectionTitle]?.text ?? shown[.collectionNumber]?.text
        case .accession: return shown[.accession]?.text
        case .series: return shown[.series]?.text ?? shown[.seriesTitle]?.text
        case .container: return shown[.container]?.text
        }
    }

    /// Two facet values are one value when they differ only in case, accents, width or punctuation.
    static func key(_ value: String) -> String { ContainerNames.key(value) }
}

/// One listed file's container, as the list shows it.
struct ContainerRow: Equatable, Sendable {
    /// The Container cell: "Box 17 (Subject File), Folder 8, Reports 1959-1960"; with no box or folder, the
    /// collection, else the repository.
    let cell: String
    /// Every shown field in the SPEC's order, for the cell's tooltip.
    let summary: [(field: ContainerField, text: String)]
    /// Each facet's shown value.
    let facets: [ContainerFacet: String]
    /// The fields whose candidates disagree (`ContainerDisplay.disagreements`).
    let disagreements: [ContainerField]

    static func == (a: ContainerRow, b: ContainerRow) -> Bool {
        a.cell == b.cell && a.facets == b.facets && a.disagreements == b.disagreements
            && a.summary.map(\.field) == b.summary.map(\.field) && a.summary.map(\.text) == b.summary.map(\.text)
    }

    /// The cell's tooltip: one line per field, then what disagrees.
    var toolTip: String {
        var lines = summary.map { "\($0.field.label): \($0.text)" }
        if !disagreements.isEmpty {
            lines.append("The sources disagree on " + disagreements.map { $0.label.lowercased() }
                .joined(separator: ", ") + "; the Inspector lists them.")
        }
        return lines.joined(separator: "\n")
    }

    /// A file with only a place, a date or other marks has an empty cell; its tooltip and the Inspector list them.
    init(shown: [ContainerField: ContainerShownValue], disagreements: [ContainerField]) {
        let text = { (f: ContainerField) in shown[f]?.text }
        var box = text(.container)
        if let title = text(.boxTitle) { box = box.map { "\($0) (\(title))" } ?? title }
        let folder = text(.folder).map { Self.namesFolder($0) ? $0 : "Folder \($0)" }
        let location = [box, folder, text(.folderTitle)].compactMap { $0 }
        let fallback = text(.collectionTitle) ?? text(.collectionNumber) ?? text(.repository)
        cell = location.isEmpty ? fallback ?? "" : location.joined(separator: ", ")
        summary = ContainerField.allCases.compactMap { f in shown[f].map { (f, $0.text) } }
        var facets: [ContainerFacet: String] = [:]
        for facet in ContainerFacet.allCases { facets[facet] = facet.value(in: shown) }
        self.facets = facets
        self.disagreements = disagreements
    }

    /// The folder value already says what it is ("Folder 8", "f. 5", "ff. 2-3"), as `ContainerCSL` reads it.
    static func namesFolder(_ s: String) -> Bool {
        let lower = s.lowercased()
        return lower.hasPrefix("folder") || lower.hasPrefix("f.") || lower.hasPrefix("ff.")
    }
}

/// One field of one file as the Inspector lists it.
struct ContainerDetailRow: Equatable, Sendable {
    let field: ContainerField
    let text: String
    let status: FieldStatus
}

/// A field whose sources disagree: each distinct value with where it came from.
struct ContainerDisagreement: Equatable, Sendable {
    let field: ContainerField
    let values: [(text: String, source: String)]

    static func == (a: ContainerDisagreement, b: ContainerDisagreement) -> Bool {
        a.field == b.field && a.values.map(\.text) == b.values.map(\.text)
            && a.values.map(\.source) == b.values.map(\.source)
    }

    /// "Container: Box 12 (folder names) or Box 13 (label read)."
    var sentence: String {
        "\(field.label): " + values.map { "\($0.text) (\($0.source))" }.joined(separator: " or ") + "."
    }
}

/// One file's container in full, for the Inspector.
struct ContainerDetail: Equatable, Sendable {
    let rows: [ContainerDetailRow]
    let disagreements: [ContainerDisagreement]
}

struct ContainerCatalog: Sendable {
    /// The path of the tree's root (the archive's main folder), spelled as the library spells paths.
    let rootPath: String
    /// Every listed file with a container value, by path.
    let rows: [String: ContainerRow]
    /// Whether a level map was found at the tree's root (`ContainerFileStore.loadLevelMap`), and its state.
    let rootLevelMap: ContainerLoad<ContainerLevelMap>
    /// Each listed file's directory below the root (top first), once per file under it: what
    /// `ContainerLevelMap.prefilled` weighs.
    let fileDirectories: [[String]]
    private let contexts: [String: DirectoryContext]

    struct DirectoryContext: Sendable {
        let scopes: [ContainerScope]
        let names: ContainerNames?
    }

    static let empty = ContainerCatalog(rootPath: "", rows: [:], rootLevelMap: .missing, fileDirectories: [],
                                        contexts: [:])

    var isEmpty: Bool { rows.isEmpty }

    /// The shown values of `facet` across the listed files, with how many files carry each, most first. Values
    /// differing only in case or punctuation are one, shown as the first spelling met.
    func facetValues(_ facet: ContainerFacet, among paths: [String]? = nil) -> [(value: String, count: Int)] {
        var counts: [String: (value: String, count: Int)] = [:]
        func add(_ row: ContainerRow) {
            guard let v = row.facets[facet] else { return }
            counts[ContainerFacet.key(v), default: (v, 0)].count += 1
        }
        if let paths { for p in paths { if let r = rows[p] { add(r) } } } else { rows.values.forEach(add) }
        return counts.values.sorted {
            $0.count != $1.count ? $0.count > $1.count : $0.value.localizedStandardCompare($1.value) == .orderedAscending
        }
    }

    /// The file's container in full, each value with its state (`FieldStatusPolicy.container`), and every
    /// disagreement with its candidates. Nil for a file outside the tree or with no value.
    func detail(forPath path: String) -> ContainerDetail? {
        guard let (dir, name) = Self.split(path, under: rootPath), let context = contexts[dir.joined(separator: "/")]
        else { return nil }
        let record = ContainerResolver.resolve(fileName: name, scopes: context.scopes,
                                               fileFields: ContainerPatterns.fields(ofFileName: name))
        let shown = ContainerDisplay.values(record, names: context.names)
        guard !shown.isEmpty else { return nil }
        let live = ContainerResolver.liveRuns(at: name, in: context.scopes.first?.file?.runs ?? [])
        let rows = ContainerField.allCases.compactMap { field -> ContainerDetailRow? in
            guard let text = shown[field]?.text else { return nil }
            guard let value = record.values[field] else {
                // Filled by another field's standard name: the user's own naming.
                return ContainerDetailRow(field: field, text: text, status: FieldStatus(
                    level: .checked, source: "From your standard name for another field", measured: ""))
            }
            let level = live.last { $0.fields[field] == value }?.level
            return ContainerDetailRow(field: field, text: text,
                                      status: FieldStatusPolicy.container(value, field: field, level: level))
        }
        let disagreements = ContainerDisplay.disagreements(record, names: context.names).map { field in
            var seen: Set<String> = []
            let values = (record.candidates[field] ?? []).compactMap { v -> (String, String)? in
                guard let written = v.shown, seen.insert(ContainerNames.key(written)).inserted else { return nil }
                return (ContainerDisplay.shown(written), Self.sourceName(v.source))
            }
            return ContainerDisagreement(field: field, values: values)
        }
        return ContainerDetail(rows: rows, disagreements: disagreements)
    }

    static func sourceName(_ source: ContainerSource) -> String {
        switch source {
        case .user: return "set by you"
        case .label: return "label read"
        case .path: return "folder names"
        }
    }

    // MARK: Building

    /// Reads the container files, level maps and standard names under `treeRoot` for the directories `filePaths`
    /// sit in, and resolves each file. `rootPath` is `treeRoot`'s path as the library spells paths; a path not
    /// under it is left out. Reads only; call it off the main thread.
    static func build(treeRoot: URL, rootPath: String, filePaths: [String]) -> ContainerCatalog {
        var byDirectory: [String: (components: [String], files: [(name: String, path: String)])] = [:]
        var fileDirectories: [[String]] = []
        for path in filePaths {
            guard let (dir, name) = split(path, under: rootPath) else { continue }
            byDirectory[dir.joined(separator: "/"), default: (dir, [])].files.append((name, path))
            fileDirectories.append(dir)
        }

        // Every directory on the way up is read once, whichever file asks first.
        var files: [String: ContainerFile?] = [:]
        var maps: [String: ContainerLevelMap?] = [:]
        var namesAt: [String: ContainerNames?] = [:]
        func url(_ components: [String]) -> URL {
            components.reduce(treeRoot) { $0.appendingPathComponent($1, isDirectory: true) }
        }
        func containerFile(_ components: [String]) -> ContainerFile? {
            let key = components.joined(separator: "/")
            if let cached = files[key] { return cached }
            let file = ContainerFileStore.load(directory: url(components)).document
            files[key] = file
            return file
        }
        func levelMap(_ components: [String]) -> ContainerLevelMap? {
            let key = components.joined(separator: "/")
            if let cached = maps[key] { return cached }
            let map = ContainerFileStore.loadLevelMap(root: url(components)).document
            maps[key] = map
            return map
        }
        func names(_ components: [String]) -> ContainerNames? {
            let key = components.joined(separator: "/")
            if let cached = namesAt[key] { return cached }
            let found = ContainerFileStore.loadNames(root: url(components)).document
            namesAt[key] = found
            return found
        }

        let rootMap = ContainerFileStore.loadLevelMap(root: treeRoot)
        maps[""] = rootMap.document
        var contexts: [String: DirectoryContext] = [:]
        var rows: [String: ContainerRow] = [:]
        for (key, entry) in byDirectory {
            let dir = entry.components
            // The nearest level map and standard names at or above the directory (SPEC §The level map).
            let mapDepth = (0...dir.count).reversed().first { levelMap(Array(dir[0..<$0])) != nil }
            let nameDepth = (0...dir.count).reversed().first { names(Array(dir[0..<$0])) != nil }
            var scopes: [ContainerScope]
            if let m = mapDepth, let map = levelMap(Array(dir[0..<m])) {
                let below = Array(dir[m...])
                let chain = (0...below.count).map { containerFile(Array(dir[0..<(m + $0)])) }
                scopes = map.scopes(for: below, files: chain)
                // Above the map's folder, only the container files' directory values apply.
                scopes += (0..<m).reversed().map { ContainerScope(file: containerFile(Array(dir[0..<$0]))) }
            } else {
                scopes = (0...dir.count).reversed().map { ContainerScope(file: containerFile(Array(dir[0..<$0]))) }
            }
            let context = DirectoryContext(scopes: scopes, names: nameDepth.flatMap { names(Array(dir[0..<$0])) })
            contexts[key] = context
            for (name, path) in entry.files {
                let record = ContainerResolver.resolve(fileName: name, scopes: scopes,
                                                       fileFields: ContainerPatterns.fields(ofFileName: name))
                guard !record.values.isEmpty else { continue }
                let shown = ContainerDisplay.values(record, names: context.names)
                guard !shown.isEmpty else { continue }
                rows[path] = ContainerRow(shown: shown,
                                          disagreements: ContainerDisplay.disagreements(record, names: context.names))
            }
        }
        return ContainerCatalog(rootPath: rootPath, rows: rows, rootLevelMap: rootMap,
                                fileDirectories: fileDirectories, contexts: contexts)
    }

    /// `path`'s directory below `rootPath` (top first) and its name; nil when it is not under the root. Byte-exact,
    /// as `ReaderArchiveLayout.isContained` compares.
    static func split(_ path: String, under rootPath: String) -> (directory: [String], name: String)? {
        guard !rootPath.isEmpty, ReaderArchiveLayout.isContained(path: path, underRootPath: rootPath) else { return nil }
        let prefix = rootPath.hasSuffix("/") ? rootPath.utf8.count : rootPath.utf8.count + 1
        let relative = String(decoding: path.utf8.dropFirst(prefix), as: UTF8.self)
        var parts = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let name = parts.popLast() else { return nil }
        return (parts, name)
    }
}
