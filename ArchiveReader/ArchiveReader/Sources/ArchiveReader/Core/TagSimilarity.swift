import Foundation

// MARK: - Near-duplicate subject-tag detection (read-only)
//
// Pure, UI-free clustering of subject tags that look like typo / case / spacing variants of one
// another (e.g. `Environment` vs `Environtment`, `Jerry Brown` vs `jerry brown`, `Economics ` vs
// `Economics`). This NEVER mutates a file and never drives a write — it only *suggests* groups a
// historian may want to merge via the app's existing corpus-wide rename (`NavigationModel.renameTag`,
// which routes through the audited `TagWriter`). Kept dependency-free (no SwiftUI/AppKit) so it can
// move into the shared `ArchiveCore` package at Archive Suite convergence.
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

enum TagSimilarity {
    /// A distinct subject tag paired with how many files carry it. The highest-count variant in a
    /// cluster is the suggested canonical form.
    struct TagVariant: Sendable, Equatable {
        let tag: String
        let count: Int
    }

    /// Group near-duplicate subject tags. `subjectCounts` maps each DISTINCT subject to its file
    /// count. Returns only clusters of size ≥ 2 (singletons are dropped); each cluster is sorted by
    /// count desc (so `.first` is the suggested canonical), and clusters are sorted by total files
    /// desc (biggest blast-radius first). O(n²) over the distinct tag set — fine at a few thousand
    /// distinct subjects; pairs whose lengths differ by more than the cap are short-circuited.
    static func clusters(subjectCounts: [String: Int]) -> [[TagVariant]] {
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

        for i in 0..<n {
            for j in (i + 1)..<n where similar(norms[i], norms[j]) { union(i, j) }
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
    static func normalize(_ s: String) -> String {
        s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
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
    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
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
