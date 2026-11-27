import Foundation

/// A change to a list of tag spellings, such as the Processor's two vocabularies (W40.tag-window-processor), held as
/// what each changed tag (by `tagKey`) was and became, so it can be undone and redone on a list that has changed
/// since: only the tags it changed move, an entry added in between stays. A `TagChangePlan` applied to a list makes
/// one (`init(from:to:)`).
public struct TagSpellingChange: Sendable, Equatable {
    /// One changed tag: its spelling and place before and after; nil where the list did not hold it.
    public struct Step: Sendable, Equatable {
        public let before: String?
        public let after: String?
        let beforeIndex: Int?
        let afterIndex: Int?
    }

    /// By `tagKey`.
    public let steps: [String: Step]

    /// The change from `old` to `new`, or nil when no tag's spelling differs. A list holding one tag twice keeps the
    /// first spelling.
    public init?(from old: [String], to new: [String]) {
        let (before, after) = (Self.firsts(old), Self.firsts(new))
        var steps: [String: Step] = [:]
        for key in Set(before.keys).union(after.keys) where before[key]?.spelling != after[key]?.spelling {
            steps[key] = Step(before: before[key]?.spelling, after: after[key]?.spelling,
                              beforeIndex: before[key]?.index, afterIndex: after[key]?.index)
        }
        guard !steps.isEmpty else { return nil }
        self.steps = steps
    }

    private init(steps: [String: Step]) { self.steps = steps }

    /// The change that puts it back.
    public var inverse: TagSpellingChange {
        TagSpellingChange(steps: steps.mapValues {
            Step(before: $0.after, after: $0.before, beforeIndex: $0.afterIndex, afterIndex: $0.beforeIndex)
        })
    }

    /// The spelling each changed tag takes, nil for one dropped: what `TagVocabulary.apply` sets.
    public var spellings: [String: String?] { steps.mapValues(\.after) }

    /// `list` with the change made: each changed tag takes its new spelling where it stands now (once), is dropped,
    /// or is put back where it stood. A tag that replaced a dropped one (a rename, a merge's target) takes the dropped
    /// one's place as it stands now. Every other entry stays as it is, in order.
    public func applied(to list: [String]) -> [String] {
        // The tag added at the place a dropped tag left, by the dropped tag's key.
        var addedAtPlaceOf: [String: String] = [:]
        let addedAt = Dictionary(steps.filter { $0.value.before == nil && $0.value.afterIndex != nil }
            .map { ($0.value.afterIndex!, $0.key) }, uniquingKeysWith: min)
        for (key, step) in steps where step.after == nil {
            if let i = step.beforeIndex, let added = addedAt[i] { addedAtPlaceOf[key] = added }
        }
        var out: [String] = []
        var placed = Set<String>()
        for entry in list {
            let key = Self.key(entry)
            guard let step = steps[key] else {
                out.append(entry)
                continue
            }
            if let after = step.after, placed.insert(key).inserted { out.append(after) }
            if step.after == nil, let added = addedAtPlaceOf[key], !list.contains(where: { Self.key($0) == added }),
               placed.insert(added).inserted, let spelling = steps[added]?.after {
                out.append(spelling)
            }
        }
        let missing = steps.filter { $0.value.after != nil && !placed.contains($0.key) }
            .sorted { ($0.value.afterIndex ?? .max, $0.key) < ($1.value.afterIndex ?? .max, $1.key) }
        for (_, step) in missing {
            out.insert(step.after!, at: min(step.afterIndex ?? out.count, out.count))
        }
        return out
    }

    static func key(_ s: String) -> String { tagKey(s.trimmingCharacters(in: .whitespacesAndNewlines)) }

    private static func firsts(_ list: [String]) -> [String: (spelling: String, index: Int)] {
        var out: [String: (spelling: String, index: Int)] = [:]
        for (i, entry) in list.enumerated() {
            let key = key(entry)
            guard !key.isEmpty, out[key] == nil else { continue }
            out[key] = (entry, i)
        }
        return out
    }
}
