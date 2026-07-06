import Foundation

/// A single user-intended tag edit. `TagEditing.delta(for:given:)` turns it into a per-file
/// `TagDelta` that `TagWriter` applies safely. Facet-replacing ops (year/month/day/priority) remove
/// whatever token that file currently has for the facet, so a heterogeneous group is handled per file.
enum TagEditOp: Sendable, Equatable {
    case addSubject(String)
    case removeSubject(String)
    case setYear(Int?)          // nil clears the year
    case setMonth(Int?)         // 1...12, or nil to clear
    case setDay(Int?)           // 1...31, or nil to clear
    case setDateUncertain(Bool)
    case setPriority(Int?)      // 7...10, or nil to clear
    case setColor(ArchiveColor?)// box / folder, or nil to clear
}

enum TagEditing {
    static func delta(for op: TagEditOp, given tags: DocumentTags) -> TagDelta {
        switch op {
        case .addSubject(let s):
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? TagDelta() : TagDelta(add: [t])
        case .removeSubject(let s):
            return TagDelta(remove: [s])
        case .setYear(let y):
            return TagDelta(add: y.map { [String($0)] } ?? [], remove: tokens(in: tags) { DocumentTags.parseYear($0) != nil })
        case .setMonth(let m):
            return TagDelta(add: m.map { [monthToken($0)] } ?? [], remove: tokens(in: tags) { DocumentTags.parseMonth($0) != nil })
        case .setDay(let d):
            return TagDelta(add: d.map { ["Day \($0)"] } ?? [], remove: tokens(in: tags) { DocumentTags.parseDay($0) != nil })
        case .setDateUncertain(let on):
            if on {
                return tags.dateUncertain ? TagDelta() : TagDelta(add: ["Date Uncertain"])
            } else {
                return tags.dateUncertain ? TagDelta(remove: tokens(in: tags) { $0.caseInsensitiveCompare("Date Uncertain") == .orderedSame }) : TagDelta()
            }
        case .setPriority(let p):
            return TagDelta(add: p.map { ["P\($0)"] } ?? [], remove: tokens(in: tags) { DocumentTags.parsePriority($0) != nil })
        case .setColor(let c):
            return TagDelta(color: c.map { .set($0) } ?? .clear)
        }
    }

    /// The delta that turns a file's current subject tokens (`old` = `file.subjects`) into the edited
    /// set (`new`) produced by the inline token editor — a single `TagDelta` so one editing session is
    /// one write + one undo step. SUBJECTS ONLY: date/priority/read/color facets are edited by their own
    /// cells and never appear in `new`, so they are neither added nor removed here. Pure/testable.
    ///
    /// - Adds = tokens in `new` not already present, trimmed, non-empty, de-duplicated (skips a token
    ///   already in `old`, matching `TagWriter`'s own "skip if present"). Reordering `old` = no-op.
    /// - Removes = `old` tokens absent from `new` (verbatim; untouched tokens round-trip through the
    ///   token field unchanged, so they are not flagged). `TagWriter` removes by exact whole-string match.
    static func subjectDelta(from old: [String], to new: [String]) -> TagDelta {
        // Match on a canonical (trimmed) form on BOTH sides so a token that differs only by whitespace
        // the control introduced is treated as unchanged — never added-and-removed (which would rewrite
        // an untouched subject). Added tokens are stored in their trimmed form; removed tokens keep the
        // file's verbatim string (TagWriter removes by exact whole-string match).
        func key(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }
        let newKeys = Set(new.map(key))
        var seen = Set(old.map(key))              // don't re-add a subject the file already has
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

    static func monthToken(_ m: Int) -> String {
        String(format: "%02d ", m) + DocumentTags.monthNames[m - 1]
    }
}

/// Summary of a facet across a selection, for the group tag editor (Finder-style tri-state).
struct GroupTagSummary: Sendable, Equatable {
    var count: Int
    var subjectsOnAll: [String]        // subjects present on every selected file
    var subjectsOnSome: [String]       // subjects present on some but not all
    var commonYear: Int??              // .some(y) all share y; .some(nil) all undated; nil = mixed
    var commonPriority: Int??          // same convention
    var commonReadState: ReadState??
    var commonColor: ArchiveColor??

    init(_ files: [DocumentTags]) {
        count = files.count
        guard let first = files.first else {
            subjectsOnAll = []; subjectsOnSome = []
            commonYear = nil; commonPriority = nil; commonReadState = nil; commonColor = nil
            return
        }
        // Subjects: intersection = onAll; union − intersection = onSome.
        let subjectSets = files.map { Set($0.subjects) }
        let all = subjectSets.dropFirst().reduce(subjectSets[0]) { $0.intersection($1) }
        let union = subjectSets.reduce(into: Set<String>()) { $0.formUnion($1) }
        subjectsOnAll = all.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        subjectsOnSome = union.subtracting(all).sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        commonYear = Self.common(files.map(\.year))
        commonPriority = Self.common(files.map(\.priority))
        commonReadState = Self.common(files.map(\.readState))
        commonColor = Self.common(files.map(\.color))
        _ = first
    }

    /// Returns `.some(value)` if every element is equal; `nil` (mixed) otherwise.
    /// Called with `T == Int?`/`ReadState?`/… so the result is `Int??` etc. (inner optional = the
    /// shared value, which may itself be nil meaning "all share no value"; outer nil = mixed).
    private static func common<T: Equatable>(_ values: [T]) -> T? {
        guard let f = values.first else { return nil }
        return values.allSatisfy { $0 == f } ? .some(f) : nil
    }
}
