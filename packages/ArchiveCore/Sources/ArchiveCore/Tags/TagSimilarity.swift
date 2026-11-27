import Foundation

// MARK: - Near-duplicate subject-tag detection (read-only)
//
// Pure, UI-free clustering of subject tags that look like typo / case / spacing variants of one
// another (e.g. `Environment` vs `Environtment`, `Jerry Brown` vs `jerry brown`, `Economics ` vs
// `Economics`). This NEVER mutates a file and never drives a write — it only *suggests* groups a
// historian may want to merge via the app's own rename (the Reader's `NavigationModel.renameTag`, which
// routes through the audited `TagWriter`; Notes' `NotesModel.renameSubject`). Moved here from the Reader
// so Notes and the shared Tags window use the same rule (W40.tag-rename-suite).
//
// The rule is deliberately CONSERVATIVE — a false grouping is just ignorable noise the user skips,
// but we still keep them low so the list stays trustworthy:
//   • Normalize = lowercased + trimmed + internal-whitespace-collapsed. Tags equal after normalizing
//     are ALWAYS grouped (pure case/spacing variants), regardless of length.
//   • Otherwise group by Levenshtein edit distance on the NORMALIZED forms with a length-scaled cap:
//       distance ≤ 1 only when the (longer) normalized length is ≥ 5,
//       distance ≤ 2 only when it is ≥ 9.
//     So short tokens like `tax`/`tab` or `1984`/`1985` are never grouped, but a one-character typo
//     in a longer word is. Grouping is transitive (union-find): `A~B` and `B~C` land in one cluster.

public enum TagSimilarity {
    /// A distinct subject tag paired with how many files carry it. The highest-count variant in a
    /// cluster is the suggested canonical form.
    public struct TagVariant: Sendable, Equatable {
        public let tag: String
        public let count: Int

        public init(tag: String, count: Int) {
            self.tag = tag
            self.count = count
        }
    }

    /// Group near-duplicate subject tags. `subjectCounts` maps each DISTINCT subject to its file
    /// count. Returns only clusters of size ≥ 2 (singletons are dropped); each cluster is sorted by
    /// count desc (so `.first` is the suggested canonical), and clusters are sorted by total files
    /// desc (biggest blast-radius first).
    ///
    /// Only candidate pairs are compared (W40.tag-window-reader): two forms within edit distance `k` of each other
    /// share a form made by deleting at most `k` characters from each, so each form is indexed under its own deletion
    /// forms (up to 2 deletions from 7 characters, 1 from 4: the cap's lengths) and only forms sharing one are
    /// compared, and not at all once they are in one group already. The groups are exactly the all-pairs ones. The
    /// all-pairs loop took 11 minutes over 7,000 subjects in a Debug build, on the Tags window's main thread.
    public static func clusters(subjectCounts: [String: Int]) -> [[TagVariant]] {
        // Deterministic, stable tag order so clusters are reproducible run to run.
        let tags = subjectCounts.keys.sorted()
        let n = tags.count
        guard n > 1 else { return [] }

        let norms = tags.map { Array(normalize($0)) }   // normalized forms as [Character] for the DP

        var parent = Array(0..<n)
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { parent[r] = parent[parent[r]]; r = parent[r] }
            return r
        }
        func union(_ a: Int, _ b: Int) { parent[find(a)] = find(b) }

        // A long form's deletion forms grow with the square of its length, so a form of `longForm` characters or more
        // is compared directly with every form within 2 characters of its length instead (they are few).
        var index: [String: [Int]] = [:]
        var byLength: [Int: [Int]] = [:]
        for (i, form) in norms.enumerated() {
            byLength[form.count, default: []].append(i)
            guard form.count < longForm else { continue }
            for key in deletionForms(form) { index[key, default: []].append(i) }
        }
        for bucket in index.values where bucket.count > 1 {
            for (k, i) in bucket.enumerated() {
                for j in bucket[(k + 1)...] where find(i) != find(j) && similar(norms[i], norms[j]) { union(i, j) }
            }
        }
        for (i, form) in norms.enumerated() where form.count >= longForm {
            for length in (form.count - 2)...(form.count + 2) {
                for j in byLength[length] ?? [] where j != i && find(i) != find(j) && similar(form, norms[j]) {
                    union(i, j)
                }
            }
        }

        // Collect components, keeping only real clusters (≥ 2 members).
        var groups: [Int: [Int]] = [:]
        for i in 0..<n { groups[find(i), default: []].append(i) }

        var result: [[TagVariant]] = groups.values.compactMap { idxs in
            guard idxs.count >= 2 else { return nil }
            return idxs
                .map { TagVariant(tag: tags[$0], count: subjectCounts[tags[$0]] ?? 0) }
                .sorted { lhs, rhs in
                    lhs.count != rhs.count
                        ? lhs.count > rhs.count                                    // canonical = max count
                        : lhs.tag.localizedStandardCompare(rhs.tag) == .orderedAscending
                }
        }
        // Biggest total blast radius first; tiebreak on the canonical tag for a stable order.
        result.sort { lhs, rhs in
            let (lt, rt) = (total(lhs), total(rhs))
            if lt != rt { return lt > rt }
            return (lhs.first?.tag ?? "").localizedStandardCompare(rhs.first?.tag ?? "") == .orderedAscending
        }
        return result
    }

    /// Sum of file counts across a cluster.
    private static func total(_ cluster: [TagVariant]) -> Int { cluster.reduce(0) { $0 + $1.count } }

    /// Lowercased, trimmed, internal-whitespace-collapsed. `split(whereSeparator:)` drops leading/
    /// trailing whitespace and collapses runs (default `omittingEmptySubsequences: true`).
    public static func normalize(_ s: String) -> String {
        s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The length from which a form is compared directly rather than through the deletion-form index.
    static let longForm = 32

    /// `form` and every form made by deleting up to as many characters as the cap could allow for a pair it is in:
    /// 2 from 7 characters (a pair capped at 2 has a longer form of 9 or more, so both have 7 or more), 1 from 4.
    static func deletionForms(_ form: [Character]) -> Set<String> {
        let depth = form.count >= 7 ? 2 : form.count >= 4 ? 1 : 0
        var out: Set<String> = [String(form)]
        var level: Set<[Character]> = [form]
        for _ in 0..<depth {
            var next: Set<[Character]> = []
            for f in level {
                for i in f.indices {
                    var d = f
                    d.remove(at: i)
                    next.insert(d)
                }
            }
            for f in next { out.insert(String(f)) }
            level = next
        }
        return out
    }

    /// Are two already-normalized forms near-duplicates? Equal → always (pure case/spacing variant);
    /// otherwise within the length-scaled Levenshtein cap.
    private static func similar(_ a: [Character], _ b: [Character]) -> Bool {
        if a == b { return true }
        let maxLen = max(a.count, b.count)
        let cap: Int
        if maxLen >= 9 { cap = 2 }
        else if maxLen >= 5 { cap = 1 }
        else { return false }                       // too short to risk a fuzzy match
        if abs(a.count - b.count) > cap { return false }   // distance ≥ length difference — skip early
        return levenshtein(a, b) <= cap
    }

    /// Standard two-row Levenshtein edit distance.
    public static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        let m = a.count, n = b.count
        if m == 0 { return n }
        if n == 0 { return m }
        var prev = Array(0...n)
        var cur = [Int](repeating: 0, count: n + 1)
        for i in 1...m {
            cur[0] = i
            for j in 1...n {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[n]
    }
}
