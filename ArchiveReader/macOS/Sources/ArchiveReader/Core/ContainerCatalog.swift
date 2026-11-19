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
    /// Each facet's value as `ContainerFacet.key` folds it, worked out once here for the container rules
    /// (W47.ct-reader-facet-rules), which test every listed row.
    let facetKeys: [ContainerFacet: String]
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
        facetKeys = facets.mapValues(ContainerFacet.key)
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

/// One file's editor state (`ContainerCatalog.editor(forPath:)`).
struct ContainerEditorInfo: Equatable, Sendable {
    /// The file's directory below the tree's root, and as the library spells its path.
    let directory: [String]
    let directoryPath: String
    let name: String
    /// Per field, which files an edit reaches: "the box from “doc-04.pdf” on, 2 listed files".
    let scopes: [ContainerField: String]
    /// The record's values as written (not as shown), for confirming one and naming its wording.
    let written: [ContainerField: String]
    /// Fields whose value is a read or a folder name, not yet the user's.
    let unconfirmed: Set<ContainerField>
    /// Fields where the edit's target holds the user's own value, which Remove takes away.
    let userHeld: Set<ContainerField>
    /// Fields shown under the user's standard name.
    let byStandardName: Set<ContainerField>
    /// The warnings of the file's folder.
    let warnings: [ContainerWarningRow]
}

/// A warning as the Inspector lists it, with the file it starts at.
struct ContainerWarningRow: Equatable, Sendable {
    let text: String
    let startPath: String
    let start: String

    init(_ w: ContainerWarning, directoryPath: String) {
        start = w.start
        startPath = directoryPath + "/" + w.start
        let files = w.files == 1 ? "“\(w.start)”" : "\(w.files) files from “\(w.start)”"
        func list(_ fields: [ContainerField]) -> String { fields.map { $0.label.lowercased() }.joined(separator: ", ") }
        switch w.kind {
        case .disagreement(let fields): text = "The sources disagree on \(list(fields)): \(files)."
        case .readDisagreesWithUser(let fields): text = "A label read differs from your \(list(fields)): \(files)."
        case .markerInsideUserRun: text = "A box or folder photo inside a run you set: \(files)."
        case .markerWithoutRead: text = "A box or folder photo with nothing read from it: \(files)."
        case .longUnmarkedRun(let count):
            text = "\(count) files in a row from “\(w.start)” with no box or folder starting among them."
        }
    }
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
    /// Each facet's values across the listed files, with how many files carry each, most first
    /// (`facetValues(_:)`), worked out once here rather than on every redraw of the filter bar.
    let facetLists: [ContainerFacet: [FacetValue]]
    private let contexts: [String: DirectoryContext]

    struct DirectoryContext: Sendable {
        let scopes: [ContainerScope]
        let names: ContainerNames?
        /// The directory's listed files, by name.
        var files: [String] = []
        /// `ContainerInference.warnings` for those files (W47.ct-reader-edit).
        var warnings: [ContainerWarning] = []
    }

    struct FacetValue: Equatable, Sendable {
        let value: String
        let count: Int
    }

    static let empty = ContainerCatalog(rootPath: "", rows: [:], rootLevelMap: .missing, fileDirectories: [],
                                        facetLists: [:], contexts: [:])

    var isEmpty: Bool { rows.isEmpty }

    /// The shown values of `facet` across the listed files, with how many files carry each, most first.
    func facetValues(_ facet: ContainerFacet) -> [FacetValue] { facetLists[facet] ?? [] }

    /// Values differing only in case or punctuation are one, shown in the spelling most files carry.
    static func facetLists(_ rows: [String: ContainerRow]) -> [ContainerFacet: [FacetValue]] {
        var lists: [ContainerFacet: [FacetValue]] = [:]
        for facet in ContainerFacet.allCases {
            var spellings: [String: [String: Int]] = [:]
            for row in rows.values {
                guard let v = row.facets[facet] else { continue }
                spellings[ContainerFacet.key(v), default: [:]][v, default: 0] += 1
            }
            let values = spellings.values.map { counts -> FacetValue in
                let best = counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }!
                return FacetValue(value: best.key, count: counts.values.reduce(0, +))
            }
            if !values.isEmpty {
                lists[facet] = values.sorted {
                    $0.count != $1.count ? $0.count > $1.count
                                         : $0.value.localizedStandardCompare($1.value) == .orderedAscending
                }
            }
        }
        return lists
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
        func status(_ field: ContainerField, _ value: ContainerValue) -> FieldStatus {
            FieldStatusPolicy.container(value, field: field, level: live.last { $0.fields[field] == value }?.level)
        }
        let rows = ContainerField.allCases.compactMap { field -> ContainerDetailRow? in
            guard let text = shown[field]?.text else { return nil }
            if let value = record.values[field] { return ContainerDetailRow(field: field, text: text, status: status(field, value)) }
            // Filled by the standard name another field's value matched: as sure as that value, no surer.
            let source = ContainerField.allCases.first { other in
                guard let written = record.shown(other), let entry = context.names?.entry(for: other, matching: written)
                else { return false }
                return entry.shown(field) != nil
            }
            guard let source, let value = record.values[source] else { return nil }
            let from = status(source, value)
            return ContainerDetailRow(field: field, text: text, status: FieldStatus(
                level: from.level, source: "From your standard name for the \(source.label.lowercased()), "
                    + from.source.prefix(1).lowercased() + from.source.dropFirst(),
                measured: from.measured))
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

    /// What the editor needs for `path`: where each field's edit goes and how many files follow it, the values as
    /// written, and the warnings of its folder (W47.ct-reader-edit). Nil for a file outside the tree. Worked out from
    /// the container file as last read; the edit itself is worked out again on the file as it is on disk.
    func editor(forPath path: String) -> ContainerEditorInfo? {
        guard let (dir, name) = Self.split(path, under: rootPath), let context = contexts[dir.joined(separator: "/")]
        else { return nil }
        let file = context.scopes.first?.file ?? ContainerFile()
        let record = ContainerResolver.resolve(fileName: name, scopes: context.scopes,
                                               fileFields: ContainerPatterns.fields(ofFileName: name))
        let shown = ContainerDisplay.values(record, names: context.names)
        var scopes: [ContainerField: String] = [:]
        var userHeld: Set<ContainerField> = []
        var counts: [ContainerEditTarget: Int] = [:]
        for field in ContainerField.allCases {
            let target = ContainerEdits.target(for: field, at: name, in: file)
            switch target {
            case .directory:
                scopes[field] = "every file in this folder and the folders inside it"
            case let .newRun(start, level):
                let n = counts[target] ?? ContainerEdits.covered(by: target, in: file, fileNames: context.files)
                counts[target] = n
                scopes[field] = "a new \(level.rawValue) from “\(start)” to the next, \(n) listed file\(n == 1 ? "" : "s")"
            case let .run(start, level):
                let n = counts[target] ?? ContainerEdits.covered(by: target, in: file, fileNames: context.files)
                counts[target] = n
                scopes[field] = "the \(level.rawValue) from “\(start)” on, \(n) listed file\(n == 1 ? "" : "s")"
                if let run = file.runs.first(where: { $0.start == start && $0.level == level }),
                   run.fields[field]?.source == .user { userHeld.insert(field) }
            }
            if target == .directory, file.directory[field]?.source == .user { userHeld.insert(field) }
        }
        let directoryPath = ([rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath] + dir)
            .joined(separator: "/")
        return ContainerEditorInfo(
            directory: dir, directoryPath: directoryPath, name: name, scopes: scopes,
            written: record.values.compactMapValues { $0.shown },
            unconfirmed: Set(record.values.compactMap { $0.value.source == .user || $0.value.shown == nil ? nil : $0.key }),
            userHeld: userHeld,
            byStandardName: Set(shown.compactMap { $0.value.byStandardName && $0.value.asWritten != nil ? $0.key : nil }),
            warnings: context.warnings.map { ContainerWarningRow($0, directoryPath: directoryPath) })
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
        var maps: [String: ContainerLoad<ContainerLevelMap>] = [:]
        var namesAt: [String: ContainerLoad<ContainerNames>] = [:]
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
        func levelMap(_ components: [String]) -> ContainerLoad<ContainerLevelMap> {
            let key = components.joined(separator: "/")
            if let cached = maps[key] { return cached }
            let map = ContainerFileStore.loadLevelMap(root: url(components))
            maps[key] = map
            return map
        }
        func names(_ components: [String]) -> ContainerLoad<ContainerNames> {
            let key = components.joined(separator: "/")
            if let cached = namesAt[key] { return cached }
            let found = ContainerFileStore.loadNames(root: url(components))
            namesAt[key] = found
            return found
        }
        func isMissing<D>(_ load: ContainerLoad<D>) -> Bool {
            if case .missing = load { return true }
            return false
        }

        let rootMap = levelMap([])
        var contexts: [String: DirectoryContext] = [:]
        var rows: [String: ContainerRow] = [:]
        for (key, entry) in byDirectory {
            let dir = entry.components
            // The nearest level map and standard names at or above the directory (SPEC §The level map). The nearest
            // one wins even when this build cannot read it: its subtree then gets none, not an outer one's.
            let mapDepth = (0...dir.count).reversed().first { !isMissing(levelMap(Array(dir[0..<$0]))) }
            let nameDepth = (0...dir.count).reversed().first { !isMissing(names(Array(dir[0..<$0]))) }
            var scopes: [ContainerScope]
            if let m = mapDepth, let map = levelMap(Array(dir[0..<m])).document {
                let below = Array(dir[m...])
                let chain = (0...below.count).map { containerFile(Array(dir[0..<(m + $0)])) }
                scopes = map.scopes(for: below, files: chain)
                // Above the map's folder, only the container files' directory values apply.
                scopes += (0..<m).reversed().map { ContainerScope(file: containerFile(Array(dir[0..<$0]))) }
            } else {
                scopes = (0...dir.count).reversed().map { ContainerScope(file: containerFile(Array(dir[0..<$0]))) }
            }
            var context = DirectoryContext(scopes: scopes,
                                           names: nameDepth.flatMap { names(Array(dir[0..<$0])).document })
            context.files = entry.files.map(\.name)
            // A directory with no container file and no folder values above it has nothing to disagree about.
            if scopes.contains(where: { $0.file != nil || !$0.pathFields.isEmpty }) {
                context.warnings = ContainerInference.warnings(fileNames: context.files, scopes: scopes,
                                                               names: context.names)
            }
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
                                fileDirectories: fileDirectories, facetLists: facetLists(rows), contexts: contexts)
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
