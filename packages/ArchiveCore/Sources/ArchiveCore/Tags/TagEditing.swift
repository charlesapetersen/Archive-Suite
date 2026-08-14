import Foundation

/// A single user-intended tag edit. `TagEditing.delta(for:given:)` turns it into a per-file
/// `TagDelta` that the coordinated writer applies safely. Facet-replacing ops (year/month/day/quality)
/// remove ONLY the one raw token that file actually consumed for the facet (`DocumentTags.yearToken`
/// etc.), so a heterogeneous group is handled per file and a subject that merely parses as that facet
/// (e.g. a subject literally "1984" or "Q2") is never destroyed. Classification never drives a write.
public enum TagEditOp: Sendable, Equatable {
    case addSubject(String)
    case removeSubject(String)
    case setYear(Int?)          // nil clears the year
    case setMonth(Int?)         // 1...12, or nil to clear
    case setDay(Int?)           // 1...31, or nil to clear
    case setDateUncertain(Bool)
    case setQuality(Int?)       // 1...3, or nil to clear (unrated writes NO token — never `Q0`)
    /// RETIRED, and retired by W19.q3: the pre-W19 spelling of the rating edit, still here only because
    /// the Reader's Priority cells drive it. It writes a `P` token, which nothing should do any more —
    /// use `setQuality`.
    case setPriority(Int?)      // 7...10, or nil to clear
    case setColor(ArchiveColor?)// box / folder, or nil to clear
}

public enum TagEditing {
    public static func delta(for op: TagEditOp, given tags: DocumentTags) -> TagDelta {
        switch op {
        case .addSubject(let s):
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? TagDelta() : TagDelta(add: [t])
        case .removeSubject(let s):
            return TagDelta(remove: [s])
        case .setYear(let y):
            // Year supersedes Decade: remove both yearToken and decadeToken (prevents orphaned hidden decade).
            let remove = (tags.yearToken.map { [$0] } ?? []) + (tags.decadeToken.map { [$0] } ?? [])
            return TagDelta(add: y.map { [String($0)] } ?? [], remove: remove)
        case .setMonth(let m):
            return TagDelta(add: m.map { [monthToken($0)] } ?? [], remove: tags.monthToken.map { [$0] } ?? [])
        case .setDay(let d):
            return TagDelta(add: d.map { ["Day \($0)"] } ?? [], remove: tags.dayToken.map { [$0] } ?? [])
        case .setDateUncertain(let on):
            if on {
                return tags.dateUncertain ? TagDelta() : TagDelta(add: ["Date Uncertain"])
            } else {
                return tags.dateUncertain ? TagDelta(remove: tokens(in: tags) { $0.caseInsensitiveCompare("Date Uncertain") == .orderedSame }) : TagDelta()
            }
        case .setQuality(let q):
            // Unrated is the ABSENCE of a token, so a clear (and any off-scale value) adds nothing —
            // `Q0` is never written. The removal NAMES the one token this file consumed for the facet
            // — though note the writer matches by VALUE, so a duplicate copy of that same token which
            // `parse` had demoted to `.subjects` goes with it (Reader `TagWriter.apply`). The end state is
            // the intended one (one rating, no orphan), but it is not literally "one token removed".
            // The removal is the token this file consumed for the facet,
            // whichever spelling it used, so setting or clearing a rating on a legacy `P8`-`P10` file
            // retires that token instead of leaving two ratings on the same file.
            return TagDelta(add: DocumentTags.qualityTag(for: q).map { [$0] } ?? [],
                            remove: tags.qualityToken.map { [$0] } ?? [])
        case .setPriority(let p):
            // RETIRED — see `TagEditOp.setPriority`. It is now a thin ALIAS for `.setQuality`, mapping the old
            // 8...10 scale down (`P8`→1, `P9`→2, `P10`→3) and treating `P7`/nil as a clear, per the owner-locked
            // W19 mapping. Two reasons it forwards rather than writing a `P`:
            //   1. It cannot leave TWO rating tokens on one file. The previous version added `P9` while removing
            //      only `priorityToken` — nil on a `Q`-rated file — so `.setPriority(9)` on a `Q2` file left BOTH
            //      tokens, and which one won then depended on tag ORDER. The old "provably cannot destroy a
            //      canonical rating" claim was true of the removal half and silent about the add half.
            //   2. The wave's owner-locked contract is that **no app writes `P` any more**. Forwarding satisfies
            //      that without waiting for W19.q3 to relabel the Reader's cells.
            // Consequence worth knowing: the Reader's "None" button now genuinely clears a `Q` rating instead of
            // being a silent no-op, and its `P7` button clears rather than writing an unrated token.
            return delta(for: .setQuality(p.flatMap { (8...10).contains($0) ? $0 - 7 : nil }), given: tags)
        case .setColor(let c):
            return TagDelta(color: c.map { .set($0) } ?? .clear)
        }
    }

    /// The delta that turns a file's current subject tokens (`old` = `file.subjects`) into the edited
    /// set (`new`) produced by the inline token editor — a single `TagDelta` so one editing session is
    /// one write + one undo step. SUBJECTS ONLY: date/quality/read/color facets are edited by their own
    /// cells and never appear in `new`, so they are neither added nor removed here. Pure/testable.
    public static func subjectDelta(from old: [String], to new: [String]) -> TagDelta {
        func key(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }
        let newKeys = Set(new.map(key))
        var seen = Set(old.map(key))
        var added: [String] = []
        for t in new {
            let k = key(t)
            guard !k.isEmpty, !seen.contains(k) else { continue }
            seen.insert(k)
            added.append(k)
        }
        let removed = old.filter { !newKeys.contains(key($0)) }
        return TagDelta(add: added, remove: removed)
    }

    /// Raw tokens (verbatim) of `tags` matching a predicate on the trimmed token.
    private static func tokens(in tags: DocumentTags, where predicate: (String) -> Bool) -> [String] {
        tags.raw.filter { predicate($0.trimmingCharacters(in: .whitespaces)) }
    }

    public static func monthToken(_ m: Int) -> String {
        String(format: "%02d ", m) + DocumentTags.monthNames[m - 1]
    }
}

/// Summary of a facet across a selection, for the group tag editor (Finder-style tri-state).
public struct GroupTagSummary: Sendable, Equatable {
    public var count: Int
    public var subjectsOnAll: [String]
    public var subjectsOnSome: [String]
    public var commonYear: Int??
    public var commonQuality: Int??
    /// RETIRED alongside `TagEditOp.setPriority` (W19.q3): the same rating on the old 8...10 scale.
    public var commonPriority: Int??
    public var commonReadState: ReadState??
    public var commonColor: ArchiveColor??

    public init(_ files: [DocumentTags]) {
        count = files.count
        guard let first = files.first else {
            subjectsOnAll = []; subjectsOnSome = []
            commonYear = nil; commonQuality = nil; commonPriority = nil
            commonReadState = nil; commonColor = nil
            return
        }
        let subjectSets = files.map { Set($0.subjects) }
        let all = subjectSets.dropFirst().reduce(subjectSets[0]) { $0.intersection($1) }
        let union = subjectSets.reduce(into: Set<String>()) { $0.formUnion($1) }
        subjectsOnAll = all.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        subjectsOnSome = union.subtracting(all).sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        commonYear = Self.common(files.map(\.year))
        commonQuality = Self.common(files.map(\.quality))
        commonPriority = Self.common(files.map(\.priority))
        commonReadState = Self.common(files.map(\.readState))
        commonColor = Self.common(files.map(\.color))
        _ = first
    }

    private static func common<T: Equatable>(_ values: [T]) -> T? {
        guard let f = values.first else { return nil }
        return values.allSatisfy { $0 == f } ? .some(f) : nil
    }
}
