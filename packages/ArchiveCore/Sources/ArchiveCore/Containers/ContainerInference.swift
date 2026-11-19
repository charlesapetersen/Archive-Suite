import Foundation

// MARK: - The inference, both routes (W47.ct-infer; `SPEC/containers.md` §Runs, §The level map, §Warnings)
//
// Pure: no file is read or written here. Route B pre-fills a level map from a tree's directory names and works out
// each directory's path values from the map; Route A turns the marker photos of one directory (box and folder label
// photos, with their label reads) into runs in its container file. `ContainerResolver` merges the two per field, and
// the warnings say where the sources disagree, a marker gave nothing, or a long stretch has no marker. The callers
// (the Reader, the Processor) read the tree, the tags and the container files, and write only what the user accepts.

// MARK: Route B — the level map and the path values

extension ContainerLevelMap {
    /// A map pre-filled from the directories under a root, each given as its path below the root (top first) as often
    /// as it should weigh (`ct_read.py` passes each file's directory, so a name counts once per file under it): the role
    /// most of a depth's names suggest, and for a depth whose names suggest none, the role its neighbours imply
    /// (`ct_read.py` `level_map`). A workflow folder becomes an `ignore` override, so it does not count as a depth. The
    /// user confirms or edits it once per root before it is written.
    public static func prefilled(directories: [[String]]) -> ContainerLevelMap {
        var overrides: [String: Override] = [:]
        var counted: [[String]] = []
        for dir in directories {
            var kept: [String] = []
            for i in dir.indices {
                if ContainerPatterns.isWorkflowName(dir[i]) {
                    overrides[dir[0...i].joined(separator: "/")] = Override(role: .ignore)
                } else {
                    kept.append(dir[i])
                }
            }
            counted.append(kept)
        }
        let depth = counted.map(\.count).max() ?? 0
        var got: [ContainerLevelRole?] = []
        for k in 0..<depth {
            // By `ct_read.py`'s classes, so a box-and-folder name counts apart from a box name, and a tie goes to the
            // greatest class name, as Python's `max` breaks it.
            var count: [String: Int] = [:]
            var names = 0
            for dir in counted where dir.count > k {
                names += 1
                if let c = ContainerPatterns.benchClass(ofName: dir[k]) { count[c, default: 0] += 1 }
            }
            let best = count.max { ($0.value, $0.key) < ($1.value, $1.key) }
            got.append(best.flatMap { $0.value * 2 >= names ? ContainerPatterns.role(ofBenchClass: $0.key) : nil })
        }
        for k in 0..<depth where got[k] == nil {
            let above = got[..<k].compactMap { $0 }
            let below = got[(k + 1)...].compactMap { $0 }.filter { $0 != .ignore }
            if above.contains(where: { $0 == .box || $0 == .folder }) || above.contains(.collection) {
                got[k] = .ignore
            } else if below.first == .collection {
                got[k] = .repository
            } else if let b = below.first, [.box, .folder, .series, .accession].contains(b) {
                got[k] = .collection
            } else if above.contains(.repository) {
                got[k] = .collection
            } else {
                got[k] = below.isEmpty ? .collection : .repository
            }
        }
        return ContainerLevelMap(levels: got.map { $0 ?? .ignore }, overrides: overrides)
    }

    /// The path values of each directory on `components` (the path below the root, top first), in the same order.
    public func pathFields(for components: [String]) -> [ContainerFieldSet] {
        zip(components, roles(for: components)).map { name, role in
            role.map { ContainerPatterns.fields(ofName: name, role: $0) } ?? ContainerFieldSet()
        }
    }

    /// The scopes `ContainerResolver.resolve` takes for a file in the directory at `components` below the root: the
    /// file's own directory first, up to the root. `files[i]` is the container file of the directory at
    /// `components[0..<i]` (`files[0]` the root's), and may be shorter than `components.count + 1`.
    public func scopes(for components: [String], files: [ContainerFile?] = []) -> [ContainerScope] {
        let path = pathFields(for: components)
        let all = (0...components.count).map { i in
            ContainerScope(file: i < files.count ? files[i] : nil,
                           pathFields: i == 0 ? ContainerFieldSet() : path[i - 1])
        }
        return all.reversed()
    }
}

// MARK: Route A — markers into runs

/// One file of a directory that may be a marker: a box or folder label photo. Its type comes from the `Box` / `Folder`
/// tag, a root's colour setting for older material (`DocumentTags.itemType`) or the page-2 Classification.
public struct ContainerMarker: Equatable, Sendable {
    public var fileName: String
    /// nil for a document: it starts no run.
    public var type: ItemType?
    /// The label read, source `label` with its reader. Empty when the photo has not been read or read nothing.
    public var read: ContainerFieldSet
    /// The label's text, if any, for recognising a "No Folder" sheet.
    public var text: String?

    public init(fileName: String, type: ItemType?, read: ContainerFieldSet = ContainerFieldSet(), text: String? = nil) {
        self.fileName = fileName
        self.type = type
        self.read = read
        self.text = text
    }
}

/// Something for the user to look at. Never resolved silently, never a rule.
public struct ContainerWarning: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Candidates for these fields name different values (the tree says Box 12, the label Box 13).
        case disagreement([ContainerField])
        /// A label read disagrees with a value the user set on the run it falls in; the user's value stands.
        case readDisagreesWithUser([ContainerField])
        /// A box or folder photo inside a run the user set, of its level or deeper: no run is started there, since it
        /// would hide the user's values from the photo on.
        case markerInsideUserRun(ItemType)
        /// A box or folder photo whose read gave no value.
        case markerWithoutRead(ItemType)
        /// `count` files after `start` (or from the directory's first file) with no marker among them.
        case longUnmarkedRun(count: Int)
    }

    public var kind: Kind
    /// The first file it concerns.
    public var start: String
    /// How many files in a row it concerns, from `start`.
    public var files: Int

    public init(_ kind: Kind, start: String, files: Int = 1) {
        self.kind = kind
        self.start = start
        self.files = files
    }
}

public enum ContainerInference {
    /// More files than this between markers is a long unmarked run: above the owner's corpus's 90th percentile, 56
    /// documents (2026-10-21, `execution-plans/containers/00-plan.md` §The corpus).
    public static let longRunFiles = 60

    /// The runs the markers start, applied to `file` (the directory's container file, or an empty one).
    ///
    /// - A box photo starts a box run at itself holding its container, box title, date and other marks. Its collection
    ///   fields go into the collection run live there (`putCollection`).
    /// - A folder photo starts a folder run with its folder, folder title, date and other marks; any box number or
    ///   collection field it reads is not stored (owner, 2026-11-13). A "No Folder" sheet starts a folder run with no
    ///   fields.
    /// - A run already at that start keeps every user value; a re-read replaces the label and path values it reads.
    ///   Nothing is removed: a field the read lacks keeps its value, a run with no marker stays.
    /// - A read never hides a user value: a photo inside a user's run of its level or deeper starts no run, and a read
    ///   that disagrees with a user value leaves it, each with a warning.
    public static func applyMarkers(_ markers: [ContainerMarker], to file: ContainerFile)
        -> (file: ContainerFile, warnings: [ContainerWarning]) {
        var runs = file.runs
        var warnings: [ContainerWarning] = []
        let ordered = markers.filter { $0.type != nil }.sorted { ContainerOrder.precedes($0.fileName, $1.fileName) }
        for marker in ordered {
            guard let type = marker.type else { continue }
            let at = marker.fileName
            let level: ContainerLevel = type == .box ? .box : .folder
            let read = marker.read.values.filter { $0.value.shown != nil }
            let noFolder = type == .folder && (marker.text.map(ContainerPatterns.isNoFolderSheet) ?? false)
            let own = noFolder ? [:] : read.filter { $0.key.homeLevel == level || $0.key.homeLevel == nil }
            let collection = type == .box ? read.filter { $0.key.homeLevel == .collection } : [:]
            if own.isEmpty && collection.isEmpty && !noFolder {
                warnings.append(ContainerWarning(.markerWithoutRead(type), start: at))
            }
            // A new run here would end every live run of its level or deeper; one the user set stands.
            let starts = !runs.contains { $0.start == at && $0.level == level }
            if starts, ContainerResolver.liveRuns(at: at, in: runs).contains(where: { run in
                run.start != at && run.level >= level && run.fields.values.values.contains { $0.source == .user }
            }) {
                warnings.append(ContainerWarning(.markerInsideUserRun(type), start: at))
                continue
            }
            var againstUser: Set<ContainerField> = []
            if !collection.isEmpty { againstUser.formUnion(putCollection(collection, at: at, runs: &runs)) }
            againstUser.formUnion(put(own, level: level, at: at, runs: &runs))
            if !againstUser.isEmpty {
                warnings.append(ContainerWarning(.readDisagreesWithUser(ContainerField.allCases.filter(againstUser.contains)),
                                                 start: at))
            }
        }
        var out = file
        out.runs = runs
        return (out, warnings)
    }

    /// Merges `values` into the run of `level` at `start`, making it if there is none. User values stay; returns the
    /// fields where one stayed against a different read.
    @discardableResult
    private static func put(_ values: [ContainerField: ContainerValue], level: ContainerLevel, at start: String,
                            runs: inout [ContainerRun]) -> [ContainerField] {
        var list = runs
        var kept: [ContainerField] = []
        if let i = list.firstIndex(where: { $0.start == start && $0.level == level }) {
            for (field, value) in values {
                if let held = list[i].fields[field], held.source == .user {
                    if differ(held, value) { kept.append(field) }
                } else {
                    list[i].fields[field] = value
                }
            }
        } else {
            list.append(ContainerRun(start: start, level: level, fields: ContainerFieldSet(values)))
        }
        runs = ContainerFile.normalised(list)
        return kept
    }

    private static func differ(_ a: ContainerValue, _ b: ContainerValue) -> Bool {
        ContainerNames.key(a.value) != ContainerNames.key(b.value)
    }

    /// What names a collection: a box read that differs here is another collection.
    private static let identifying: Set<ContainerField> = [.collectionTitle, .collectionNumber]

    /// A box label's collection fields, into the collection run live at the box. Returns the fields that disagreed
    /// with a user value, which stand.
    /// - None live, or the live one starts at this box: into a run at the box.
    /// - Agreeing with the live run: fills in what it lacks, so a later box's accession reaches the earlier boxes.
    /// - Disagreeing with a user value of the live run: nothing changes.
    /// - Naming another collection (title or number): a new run at the box with the read alone.
    /// - Otherwise (a new series or accession in the same collection): a new run at the box with the live run's values
    ///   and the read over them, so the title and repository carry on.
    private static func putCollection(_ values: [ContainerField: ContainerValue], at start: String,
                                      runs: inout [ContainerRun]) -> [ContainerField] {
        guard let live = ContainerResolver.liveRuns(at: start, in: runs).first(where: { $0.level == .collection }),
              live.start != start else {
            return put(values, level: .collection, at: start, runs: &runs)
        }
        let differs = values.keys.filter { f in live.fields[f].map { differ($0, values[f]!) } ?? false }
        let againstUser = differs.filter { live.fields[$0]?.source == .user }
        if !againstUser.isEmpty { return againstUser }
        if differs.isEmpty {
            put(values.filter { live.fields[$0.key] == nil }, level: .collection, at: live.start, runs: &runs)
        } else if differs.contains(where: identifying.contains) {
            put(values, level: .collection, at: start, runs: &runs)
        } else {
            put(live.fields.values.merging(values) { _, read in read }, level: .collection, at: start, runs: &runs)
        }
        return []
    }

    // MARK: Warnings

    /// The files of one directory (any order; hidden files are the caller's to leave out) with their warnings: runs of
    /// files whose candidates disagree (`ContainerDisplay.disagreements`, so two wordings under one standard name
    /// agree), and stretches of more than `longRunFiles` files with no run starting among them in a directory that has
    /// runs. A box number lower than the one before is not a warning, nor is a folder label naming another box
    /// (owner, 2026-11-13).
    public static func warnings(fileNames: [String], scopes: [ContainerScope], names: ContainerNames? = nil,
                                longRun: Int = longRunFiles) -> [ContainerWarning] {
        let ordered = fileNames.sorted(by: ContainerOrder.precedes)
        var out: [ContainerWarning] = []
        var open: (fields: [ContainerField], start: String, files: Int)?
        for name in ordered {
            let record = ContainerResolver.resolve(fileName: name, scopes: scopes,
                                                   fileFields: ContainerPatterns.fields(ofFileName: name))
            let fields = ContainerDisplay.disagreements(record, names: names)
            if let o = open, o.fields == fields {
                open?.files += 1
                continue
            }
            if let o = open { out.append(ContainerWarning(.disagreement(o.fields), start: o.start, files: o.files)) }
            open = fields.isEmpty ? nil : (fields, name, 1)
        }
        if let o = open { out.append(ContainerWarning(.disagreement(o.fields), start: o.start, files: o.files)) }

        let starts = (scopes.first?.file?.runs.map(\.start) ?? []).sorted(by: ContainerOrder.precedes)
        guard !starts.isEmpty else { return out }
        var next = 0   // the first run start not yet passed; a start need not be a file's name
        var stretchStart: String?
        var count = 0
        func close() {
            if count > longRun, let s = stretchStart {
                out.append(ContainerWarning(.longUnmarkedRun(count: count), start: s, files: count))
            }
            stretchStart = nil
            count = 0
        }
        for name in ordered {
            var started = false, isMarker = false
            while next < starts.count, ContainerOrder.atOrBefore(starts[next], name) {
                started = true
                isMarker = isMarker || starts[next] == name
                next += 1
            }
            if started { close() }
            // A run's own first file is its marker; a run whose start names no file begins with this one, unmarked.
            if !isMarker {
                if stretchStart == nil { stretchStart = name }
                count += 1
            }
        }
        close()
        return out
    }
}
