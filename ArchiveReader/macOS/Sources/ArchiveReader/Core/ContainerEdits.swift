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
            guard let value, field.homeLevel == level else { return nil }
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

    /// The fields "set for selection" offers: those with a home level, which says what run the value starts.
    static let selectionFields: [ContainerField] = ContainerField.allCases.filter { $0.homeLevel != nil }

    /// The selected names of one directory in runs of neighbours, by `ContainerOrder`, among `fileNames` (all the
    /// directory's files). A gap is a file of the directory that is not selected.
    static func contiguousGroups(selected: Set<String>, fileNames: [String]) -> [[String]] {
        var groups: [[String]] = []
        var current: [String] = []
        for name in fileNames.sorted(by: ContainerOrder.precedes) {
            if selected.contains(name) {
                current.append(name)
            } else if !current.isEmpty {
                groups.append(current)
                current = []
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// Sets `field` to `value` for the files `group` (neighbours in the directory, in order) and for no other file:
    /// splitting runs (SPEC §Runs: the user may start a run anywhere).
    ///
    /// A run of the field's home level L is made at the group's first file, and at each run of level L or shallower
    /// starting inside the group, each a copy of what was live there, holding the value. Deeper runs live there are
    /// copied too, so only `field` changes for the selected files, and they lose `field` inside the group so the new
    /// value shows. At the file after the group the runs of level L and deeper that were live there are copied back,
    /// so every later file keeps what it had. `after` is that file's name; nil when the group ends the directory.
    static func setForSelection(_ field: ContainerField, to value: ContainerValue, group: [String], after: String?,
                                in file: ContainerFile) -> ContainerFile? {
        guard let level = field.homeLevel, let first = group.first, let last = group.last else { return nil }
        let old = file.runs
        var points = [first]
        for run in old where run.level <= level && ContainerOrder.precedes(first, run.start)
            && ContainerOrder.atOrBefore(run.start, last) && !points.contains(run.start) {
            points.append(run.start)
        }
        var runs = old
        func ensureCopies(at point: String) {
            let live = ContainerResolver.liveRuns(at: point, in: old)
            if !runs.contains(where: { $0.start == point && $0.level == level }) {
                var fields = live.first { $0.level == level }?.fields ?? ContainerFieldSet()
                if !live.contains(where: { $0.level == level }) {
                    // No run of this level was live: carry what shallower runs gave the fields this run masks, the
                    // value the resolver would choose (highest source, then the deepest).
                    let held = ContainerResolver.runValues(live.filter { $0.level < level })
                    for (f, values) in held where f.homeLevel.map({ $0 >= level }) ?? false {
                        let usable = values.filter { $0.source == .user || $0.shown != nil }
                        fields[f] = usable.reduce(nil as ContainerValue?) { best, v in
                            best.map { v.source > $0.source ? v : $0 } ?? v
                        }
                    }
                }
                runs.append(ContainerRun(start: point, level: level, fields: fields))
            }
            for deeper in live where deeper.level > level && !runs.contains(where: { $0.start == point && $0.level == deeper.level }) {
                runs.append(ContainerRun(start: point, level: deeper.level, fields: deeper.fields))
            }
        }
        if let after, !old.contains(where: { $0.start == after && $0.level <= level }) { ensureCopies(at: after) }
        for point in points { ensureCopies(at: point) }
        runs = runs.map { run in
            guard ContainerOrder.atOrBefore(first, run.start), ContainerOrder.atOrBefore(run.start, last) else { return run }
            var run = run
            if run.level == level { run.fields[field] = value }
            else if run.level > level { run.fields[field] = nil }
            return run
        }
        var edited = file
        edited.runs = runs
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
