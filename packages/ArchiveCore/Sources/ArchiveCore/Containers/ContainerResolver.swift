import Foundation

// MARK: - The inheritance rule (W47.ct-spec; `SPEC/containers.md` §Runs and the inheritance rule)
//
// Pure: no file is read here. The caller gives the directories from the file's own up to the archive root, each with
// its container file (if any) and the path values the level map gives it (`W47.ct-infer` works those out).

/// One directory on the way from a file up to the root.
public struct ContainerScope: Equatable, Sendable {
    public var file: ContainerFile?
    /// Values worked out from the folder name and the level map; never stored.
    public var pathFields: ContainerFieldSet

    public init(file: ContainerFile? = nil, pathFields: ContainerFieldSet = ContainerFieldSet()) {
        self.file = file
        self.pathFields = pathFields
    }
}

/// What one item inherits: the winning value of each field, and every other candidate (for the warnings).
public struct ResolvedContainer: Equatable, Sendable {
    public var values: [ContainerField: ContainerValue]
    /// Per field, every candidate most specific first, the winner included.
    public var candidates: [ContainerField: [ContainerValue]]

    public init(values: [ContainerField: ContainerValue], candidates: [ContainerField: [ContainerValue]] = [:]) {
        self.values = values
        self.candidates = candidates
    }

    /// The value as shown, nil when there is none or the user set "none here".
    public func shown(_ field: ContainerField) -> String? { values[field]?.shown }

    /// Fields whose candidates name more than one value (case-folded), a disagreement to show, never to settle.
    public var disagreements: [ContainerField] {
        ContainerField.allCases.filter { field in
            let named = Set((candidates[field] ?? []).compactMap { $0.shown?.lowercased() })
            return named.count > 1
        }
    }
}

public enum ContainerResolver {
    /// The runs live at `fileName`, shallow to deep: at most one per level, each starting after the one before.
    public static func liveRuns(at fileName: String, in runs: [ContainerRun]) -> [ContainerRun] {
        var live: [ContainerRun] = []
        // `runs` is in `ContainerFile.normalised` order, as `ContainerFile` keeps it.
        for run in runs {
            guard ContainerOrder.atOrBefore(run.start, fileName) else { break }
            live.removeAll { $0.level >= run.level }
            live.append(run)
        }
        return live
    }

    /// The unmasked values of the live runs, per field, deepest run first.
    static func runValues(_ live: [ContainerRun]) -> [ContainerField: [ContainerValue]] {
        // Each entry remembers the level of the run that gave it, for masking `date` and `other`.
        var held: [ContainerField: [(ContainerLevel, ContainerValue)]] = [:]
        for run in live {
            for field in ContainerField.allCases {
                held[field]?.removeAll { from, _ in (field.homeLevel ?? from) >= run.level }
            }
            for (field, value) in run.fields.values { held[field, default: []].append((run.level, value)) }
        }
        return held.mapValues { $0.reversed().map(\.1) }
    }

    /// What `fileName` inherits. `scopes[0]` is the file's own directory, then its parent, up to the root.
    /// `fileFields` are the path values in the file's own name (`ContainerPatterns.fields(ofFileName:)`), the most
    /// specific of the path values.
    public static func resolve(fileName: String, scopes: [ContainerScope],
                               fileFields: ContainerFieldSet = ContainerFieldSet()) -> ResolvedContainer {
        var candidates = runValues(liveRuns(at: fileName, in: scopes.first?.file?.runs ?? []))
        for (field, value) in fileFields.values { candidates[field, default: []].append(value) }
        for scope in scopes {
            for (field, value) in scope.file?.directory.values ?? [:] { candidates[field, default: []].append(value) }
            for (field, value) in scope.pathFields.values { candidates[field, default: []].append(value) }
        }
        var values: [ContainerField: ContainerValue] = [:]
        for (field, list) in candidates {
            // The highest source; among equals the first, which is the most specific.
            var best: ContainerValue?
            // An empty value hides the others only when the user set it ("none here"); an empty read is no read.
            for value in list where value.source == .user || value.shown != nil {
                if best == nil || value.source > best!.source { best = value }
            }
            values[field] = best
        }
        return ResolvedContainer(values: values, candidates: candidates)
    }
}
