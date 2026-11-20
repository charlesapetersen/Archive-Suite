import Foundation
import ArchiveCore

// MARK: - Editing where a file sits in its archive (W47.ct-reader-edit; `SPEC/containers.md`)
//
// The Reader is the one place a container is corrected. Every edit is worked out here, purely, on a container file
// freshly read from disk, and written back by `NavigationModel+ContainerEdits` through `ContainerFileStore.write` with
// the stamp of that read, so nothing another app wrote in between is lost. Only `<directory>/.archivesuite/
// containers.json` and the tree's `container-names.json` are ever written; no document is touched.
//
// A value the user types, confirms or empties is source `user`, which a re-read never overwrites (SPEC §A value and
// its source). "One correction to a run fixes every item under it": an edit goes to the run that gives the value.

/// Where an edit to one file's field is kept.
enum ContainerEditTarget: Hashable, Sendable {
    /// The run of `level` starting at `start`: every file it covers follows.
    case run(start: String, level: ContainerLevel)
    /// A run of `level` to start at `start`, the file edited, where the directory has runs of that level but none is
    /// live there: it covers the files up to the next run of its level or a shallower one.
    case newRun(start: String, level: ContainerLevel)
    /// The directory's own values: every file in the folder and below.
    case directory
}

enum ContainerEdits {
    /// Where an edit to `field` at `fileName` goes, so that one correction fixes every file the value reaches:
    /// - where the shown value lives, when this folder's container file gives it: the deepest live run holding it, or
    ///   the directory's own values;
    /// - else the live run of the field's home level (for `date` and `other`, the deepest live run);
    /// - else, in a folder whose runs of that level start later (a gap before the first box photo), a new run at the
    ///   file, so a correction there does not overrule the runs' reads;
    /// - else the directory's own values (a folder per box, Route B).
    static func target(for field: ContainerField, at fileName: String, in file: ContainerFile) -> ContainerEditTarget {
        let live = ContainerResolver.liveRuns(at: fileName, in: file.runs)
        let record = ContainerResolver.resolve(fileName: fileName, scopes: [ContainerScope(file: file)])
        if let winner = record.values[field] {
            if let run = unmaskedHolders(live)[field]?.first(where: { $0.fields[field] == winner }) {
                return .run(start: run.start, level: run.level)
            }
            if file.directory[field] == winner { return .directory }
        }
        guard let home = field.homeLevel else {
            return live.last.map { .run(start: $0.start, level: $0.level) } ?? .directory
        }
        if let run = live.last(where: { $0.level == home }) { return .run(start: run.start, level: run.level) }
        if file.runs.contains(where: { $0.level == home }) { return .newRun(start: fileName, level: home) }
        return .directory
    }

    /// Per field, the live runs whose value is not masked, deepest first.
    private static func unmaskedHolders(_ live: [ContainerRun]) -> [ContainerField: [ContainerRun]] {
        var held: [ContainerField: [ContainerRun]] = [:]
        for run in live {
            for field in ContainerField.allCases {
                held[field]?.removeAll { (field.homeLevel ?? $0.level) >= run.level }
            }
            for (field, value) in run.fields.values where value.source == .user || value.shown != nil {
                held[field, default: []].insert(run, at: 0)
            }
        }
        return held
    }

    /// The files a target covers among `fileNames` (the directory's files, any order).
    static func covered(by target: ContainerEditTarget, in file: ContainerFile, fileNames: [String]) -> Int {
        switch target {
        case .directory:
            return fileNames.count
        case let .run(start, level):
            return fileNames.filter { name in
                ContainerResolver.liveRuns(at: name, in: file.runs).contains { $0.start == start && $0.level == level }
            }.count
        case let .newRun(start, level):
            let end = file.runs.filter { $0.level <= level && ContainerOrder.precedes(start, $0.start) }.map(\.start)
                .min(by: ContainerOrder.precedes)
            return fileNames.filter { name in
                ContainerOrder.atOrBefore(start, name) && end.map { ContainerOrder.precedes(name, $0) } ?? true
            }.count
        }
    }

    /// Sets `field` at `target` to `value` (nil removes it there, so the file inherits again). A user's `""` is
    /// "none here". A run that does not exist is not made, except a `newRun`, made as "set for selection" makes one.
    static func set(_ field: ContainerField, to value: ContainerValue?, at target: ContainerEditTarget,
                    in file: ContainerFile) -> ContainerFile? {
        var file = file
        switch target {
        case .directory:
            file.directory[field] = value
        case let .run(start, level):
            var runs = file.runs
            guard let i = runs.firstIndex(where: { $0.start == start && $0.level == level }) else { return nil }
            runs[i].fields[field] = value
            file.runs = runs
        case let .newRun(start, level):
            guard let value, selectionLevel(field) == level else { return nil }
            return setForSelection(field, to: value, group: [start], after: nil, in: file)
        }
        return file
    }

    /// The user's value: typed, confirmed or "none here" (`""`). A confirmed read keeps its reader (SPEC).
    static func userValue(_ text: String, confirming old: ContainerValue?, at date: Date) -> ContainerValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let old, old.shown == trimmed, !trimmed.isEmpty { return old.confirmed(at: date) }
        return ContainerValue(trimmed, source: .user, reader: nil, confidence: nil, at: date)
    }

    // MARK: Set for selection

    /// The fields "set for selection" offers: every one (W49.reader-set-selection-limits).
    static let selectionFields: [ContainerField] = ContainerField.allCases

    /// The level of the runs "set for selection" makes for `field`: its home level, and for `date` and `other`, which
    /// take the level of the run that holds them, a folder's. That is the deepest, so no run masks the value for the
    /// selected files, and a date set there is the folder date the folder-date rule reads (SPEC §The folder-date rule).
    static func selectionLevel(_ field: ContainerField) -> ContainerLevel { field.homeLevel ?? .folder }

    /// The selected names of one directory in runs of neighbours, by `ContainerOrder`, among `fileNames` (all the
    /// directory's files). A gap is a file of the directory that is not selected.
    static func contiguousGroups(selected: Set<String>, fileNames: [String]) -> [[String]] {
        selectionGroups(selected: selected, fileNames: fileNames).map(\.names)
    }

    /// `contiguousGroups`, each with the name of the file after it (nil when the group ends the directory).
    static func selectionGroups(selected: Set<String>, fileNames: [String]) -> [SelectionGroup] {
        var groups: [SelectionGroup] = []
        var current: [String] = []
        for name in fileNames.sorted(by: ContainerOrder.precedes) {
            if selected.contains(name) {
                current.append(name)
            } else if !current.isEmpty {
                groups.append(SelectionGroup(names: current, after: name))
                current = []
            }
        }
        if !current.isEmpty { groups.append(SelectionGroup(names: current, after: nil)) }
        return groups
    }

    /// Neighbouring selected files of one directory, in order, and the name of the file after them.
    struct SelectionGroup: Equatable, Sendable {
        let names: [String]
        let after: String?
    }

    /// Sets `field` to `value` for the files `group` (neighbours in the directory, in order) and for no other file:
    /// splitting runs (SPEC §Runs: the user may start a run anywhere). `after` is the name of the file after the group;
    /// nil when the group ends the directory.
    static func setForSelection(_ field: ContainerField, to value: ContainerValue, group: [String], after: String?,
                                in file: ContainerFile) -> ContainerFile? {
        setForSelection(field, to: value, groups: [SelectionGroup(names: group, after: after)], in: file)
    }

    /// Sets `field` to `value` for every group's files and for no other file, in one pass over the runs, so a
    /// selection of many scattered files costs about as much as one (W49.reader-set-selection-limits). `groups` are
    /// in order and apart, each followed by a file that is not selected.
    ///
    /// For each group: a run of the field's selection level L is made at the group's first file, and at each run of
    /// level L or shallower starting inside the group, each a copy of what was live there, holding the value. Deeper
    /// runs live there are copied too, so only `field` changes for the selected files, and they lose `field` inside
    /// the group so the new value shows. At the file after the group the runs of level L and deeper that were live
    /// there are copied back, so every later file keeps what it had. Each group's copies end at its `after` and read
    /// only what was live from its first file, so the result is the groups' edits made one after another.
    static func setForSelection(_ field: ContainerField, to value: ContainerValue, groups: [SelectionGroup],
                                in file: ContainerFile) -> ContainerFile? {
        let level = selectionLevel(field)
        let groups = groups.filter { !$0.names.isEmpty }
        guard !groups.isEmpty else { return nil }
        let old = file.runs   // `ContainerFile.normalised` order
        struct Key: Hashable { let start: String, level: ContainerLevel }
        var existing = Set(old.map { Key(start: $0.start, level: $0.level) })
        var added: [ContainerRun] = []
        // Each copy's group (an index into `groups`), or nil for a copy at a group's `after`.
        var addedGroup: [Int?] = []

        // The points to copy at, in order: each with its group, or nil for an `after`.
        var points: [(name: String, group: Int?)] = []
        var j = 0
        for (g, group) in groups.enumerated() {
            let first = group.names[0], last = group.names[group.names.count - 1]
            points.append((first, g))
            while j < old.count, ContainerOrder.atOrBefore(old[j].start, first) { j += 1 }
            var k = j
            var seen: Set<String> = [first]
            while k < old.count, ContainerOrder.atOrBefore(old[k].start, last) {
                if old[k].level <= level, seen.insert(old[k].start).inserted { points.append((old[k].start, g)) }
                k += 1
            }
            if let after = group.after {
                // A run of level L or shallower already at `after` ends the group's runs itself.
                var ended = false
                while k < old.count, ContainerOrder.atOrBefore(old[k].start, after) {
                    if old[k].start == after, old[k].level <= level { ended = true }
                    k += 1
                }
                if !ended { points.append((after, nil)) }
            }
            j = k   // the next group starts after this one's `after`
        }

        // One sweep for what was live at each point (they are in order).
        var live: [ContainerRun] = []
        var r = 0
        for point in points {
            while r < old.count, ContainerOrder.atOrBefore(old[r].start, point.name) {
                live.removeAll { $0.level >= old[r].level }
                live.append(old[r])
                r += 1
            }
            func add(_ run: ContainerRun) {
                guard existing.insert(Key(start: run.start, level: run.level)).inserted else { return }
                added.append(run)
                addedGroup.append(point.group)
            }
            var fields = live.first { $0.level == level }?.fields ?? ContainerFieldSet()
            if !live.contains(where: { $0.level == level }) {
                // No run of this level was live: carry what shallower runs gave the fields this run masks, the value
                // the resolver would choose (highest source, then the deepest).
                let held = ContainerResolver.runValues(live.filter { $0.level < level })
                for (f, values) in held where f.homeLevel.map({ $0 >= level }) ?? false {
                    let usable = values.filter { $0.source == .user || $0.shown != nil }
                    fields[f] = usable.reduce(nil as ContainerValue?) { best, v in
                        best.map { v.source > $0.source ? v : $0 } ?? v
                    }
                }
            }
            add(ContainerRun(start: point.name, level: level, fields: fields))
            for deeper in live where deeper.level > level {
                add(ContainerRun(start: point.name, level: deeper.level, fields: deeper.fields))
            }
        }

        func edit(_ run: inout ContainerRun) {
            if run.level == level { run.fields[field] = value }
            else if run.level > level { run.fields[field] = nil }
        }
        // The old runs inside a group, found with the groups in order.
        var runs = old
        var g = 0
        for i in runs.indices {
            while g < groups.count, ContainerOrder.precedes(groups[g].names[groups[g].names.count - 1], runs[i].start) {
                g += 1
            }
            guard g < groups.count else { break }
            if ContainerOrder.atOrBefore(groups[g].names[0], runs[i].start) { edit(&runs[i]) }
        }
        for i in added.indices where addedGroup[i] != nil { edit(&added[i]) }
        var edited = file
        edited.runs = runs + added
        return edited
    }

    // MARK: Standard names

    /// The user's standard name `standard` for `written` in `field`: `written` and every wording an entry for it
    /// already matched are shown as `standard` (`ContainerNames.set`). An empty standard removes the entry.
    static func setStandardName(_ standard: String, for written: String, field: ContainerField,
                                in names: ContainerNames, at date: Date) -> ContainerNames {
        var names = names
        let trimmed = standard.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = names.entry(for: field, matching: written)
        if trimmed.isEmpty {
            names.remove(field: field, matching: written)
        } else {
            var variants = [written]
            if let previous {
                variants += previous.variants
                if let old = previous.shown(field) { variants.append(old) }
            }
            var entry = ContainerStandardName(field: field, standard: trimmed, variants: variants)
            // Keep what the entry said about other fields (a repository that also names the place).
            if let previous { for (f, t) in previous.fields where f != field { entry.fields[f] = t } }
            names.set(entry)
        }
        names.updatedAt = date
        return names
    }
}
