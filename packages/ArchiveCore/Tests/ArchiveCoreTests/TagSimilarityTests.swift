import XCTest
@testable import ArchiveCore

/// Pins the read-only near-duplicate subject-tag clustering (`TagSimilarity.clusters`): case/spacing
/// variants always group, a real typo in a long tag groups, short distinct tags never group, grouping
/// is transitive, singletons are dropped, and ordering puts the max-count variant first (the suggested
/// canonical) with biggest-blast-radius clusters first. Pure logic — no files, no writes.
final class TagSimilarityTests: XCTestCase {

    private typealias Variant = TagSimilarity.TagVariant

    // Convenience: the tags of one cluster, in returned (count-desc) order.
    private func tags(_ cluster: [Variant]) -> [String] { cluster.map(\.tag) }

    // MARK: Case / spacing variants (always grouped, any length)

    func testCaseVariantsCluster() {
        let c = TagSimilarity.clusters(subjectCounts: ["Jerry Brown": 40, "jerry brown": 3])
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(tags(c[0]), ["Jerry Brown", "jerry brown"])   // canonical = higher count first
    }

    func testTrailingSpaceVariantClusters() {
        let c = TagSimilarity.clusters(subjectCounts: ["Economics": 12, "Economics ": 2])
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(tags(c[0]), ["Economics", "Economics "])
    }

    func testInternalWhitespaceCollapsedVariantClusters() {
        // "New York" vs "New  York" (double space) normalize identically → grouped.
        let c = TagSimilarity.clusters(subjectCounts: ["New York": 5, "New  York": 1])
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(Set(tags(c[0])), ["New York", "New  York"])
    }

    func testShortPureCaseVariantStillClusters() {
        // Length gating applies ONLY to the fuzzy (Levenshtein) path — pure case variants group
        // regardless of length, so "Tax"/"tax" (normalize equal) still cluster.
        let c = TagSimilarity.clusters(subjectCounts: ["Tax": 4, "tax": 1])
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(tags(c[0]), ["Tax", "tax"])
    }

    // MARK: Real typos in long tags (fuzzy path)

    func testLongTagTypoClusters() {
        let c = TagSimilarity.clusters(subjectCounts: ["Environment": 30, "Environtment": 1])
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(tags(c[0]), ["Environment", "Environtment"])
    }

    func testDistanceTwoGroupsOnlyWhenLongEnough() {
        // length ≥ 9 permits distance 2: "Sacramento" vs "Sacrament" is distance 1, and vs
        // "Sacremernto" (two edits) still ≤ 2 → grouped.
        let long = TagSimilarity.clusters(subjectCounts: ["Sacramento": 9, "Sacremernto": 1])
        XCTAssertEqual(long.count, 1, "distance-2 typo in a ≥9-char tag should group")

        // length 8 with distance 2 must NOT group (cap is 1 below length 9).
        let short = TagSimilarity.clusters(subjectCounts: ["Congress": 6, "Conquess": 1])
        XCTAssertTrue(short.isEmpty, "distance-2 in an 8-char tag must not group")
    }

    func testLengthFiveBoundaryGroupsDistanceOne() {
        // Exactly length 5 permits distance 1: "Draft" vs "Draff".
        let c = TagSimilarity.clusters(subjectCounts: ["Draft": 3, "Draff": 1])
        XCTAssertEqual(c.count, 1)
    }

    // MARK: Short distinct tags never group

    func testShortDistinctTagsDoNotCluster() {
        XCTAssertTrue(TagSimilarity.clusters(subjectCounts: ["tax": 5, "tab": 3]).isEmpty)
        XCTAssertTrue(TagSimilarity.clusters(subjectCounts: ["1984": 2, "1985": 2]).isEmpty)
    }

    // MARK: Transitive grouping (union-find)

    func testTransitiveGrouping() {
        // A~B (dist 1) and B~C (dist 1) but A~C (dist 2, > cap 1 at length 5) — all still land in ONE
        // cluster via transitivity. "aaaaa"/"aaaab"/"aaabb": A-B differ in 1 char, B-C in 1, A-C in 2.
        let c = TagSimilarity.clusters(subjectCounts: ["aaaaa": 3, "aaaab": 2, "aaabb": 1])
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c[0].count, 3)
        XCTAssertEqual(tags(c[0]), ["aaaaa", "aaaab", "aaabb"])   // count-desc
    }

    // MARK: Singletons excluded

    func testSingletonsExcluded() {
        let c = TagSimilarity.clusters(subjectCounts: [
            "Environment": 10, "Environtment": 1,   // a real cluster
            "Photography": 4,                         // lone, distinct → dropped
            "Budget": 7,                              // lone, distinct → dropped
        ])
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(Set(tags(c[0])), ["Environment", "Environtment"])
    }

    func testEmptyAndSingleInputReturnNoClusters() {
        XCTAssertTrue(TagSimilarity.clusters(subjectCounts: [:]).isEmpty)
        XCTAssertTrue(TagSimilarity.clusters(subjectCounts: ["Economics": 5]).isEmpty)
    }

    // MARK: Ordering — canonical (max count) first; clusters by total files desc

    func testCanonicalIsMaxCountAndClustersSortedByTotalFiles() {
        let c = TagSimilarity.clusters(subjectCounts: [
            // Small-total cluster.
            "Economics": 3, "Econimics": 1,           // total 4
            // Large-total cluster.
            "Jerry Brown": 40, "jerry brown": 5, "Jerry  Brown": 2,   // total 47
        ])
        XCTAssertEqual(c.count, 2)
        // Biggest blast radius first.
        XCTAssertEqual(c[0].first?.tag, "Jerry Brown")
        XCTAssertEqual(c[1].first?.tag, "Economics")
        // Within a cluster: max count is the suggested canonical (first).
        XCTAssertEqual(tags(c[0]), ["Jerry Brown", "jerry brown", "Jerry  Brown"])
        XCTAssertEqual(c[0].first?.count, 40)
    }

    // MARK: Levenshtein primitive

    func testLevenshtein() {
        XCTAssertEqual(TagSimilarity.levenshtein(Array("kitten"), Array("sitting")), 3)
        XCTAssertEqual(TagSimilarity.levenshtein(Array("abc"), Array("abc")), 0)
        XCTAssertEqual(TagSimilarity.levenshtein(Array(""), Array("abc")), 3)
        XCTAssertEqual(TagSimilarity.levenshtein(Array("environment"), Array("environtment")), 1)
    }

    // MARK: The candidate index is exact (W40.tag-window-reader)

    /// The groups found through the deletion-form index are the all-pairs groups, on a set built to have near
    /// misses at every cap boundary: lengths 3 to 14, one and two edits, transpositions, spacing and case.
    func testTheCandidateIndexFindsExactlyTheAllPairsGroups() {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("abcde ")
        var counts: [String: Int] = [:]
        for _ in 0..<400 {
            // Up to past `longForm`, so the long forms' direct comparison is covered too.
            let length = Int.random(in: 3...14, using: &generator) + (Bool.random(using: &generator) ? 0 : 22)
            let tag = String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
            counts[tag, default: 0] += 1
            var edited = Array(tag)
            for _ in 0..<Int.random(in: 1...2, using: &generator) {
                let i = Int.random(in: 0..<edited.count, using: &generator)
                switch Int.random(in: 0...3, using: &generator) {
                case 0: edited[i] = alphabet.randomElement(using: &generator)!
                case 1: if edited.count > 1 { edited.remove(at: i) }
                case 2: edited.insert(alphabet.randomElement(using: &generator)!, at: i)
                default: if i + 1 < edited.count { edited.swapAt(i, i + 1) }
                }
            }
            counts[String(edited).uppercased(), default: 0] += 1
        }
        let fast = TagSimilarity.clusters(subjectCounts: counts).map { Set($0.map(\.tag)) }
        XCTAssertEqual(Set(fast), Set(allPairs(counts)), "\(counts.count) tags")
        XCTAssertFalse(fast.isEmpty)
    }

    /// The rule applied to every pair, as `clusters` did before the index.
    private func allPairs(_ counts: [String: Int]) -> [Set<String>] {
        let tags = counts.keys.sorted()
        let norms = tags.map { Array(TagSimilarity.normalize($0)) }
        var parent = Array(tags.indices)
        func find(_ x: Int) -> Int { var r = x; while parent[r] != r { r = parent[r] }; return r }
        for i in tags.indices {
            for j in (i + 1)..<tags.count {
                let (a, b) = (norms[i], norms[j])
                let maxLen = max(a.count, b.count)
                let cap = maxLen >= 9 ? 2 : maxLen >= 5 ? 1 : 0
                guard a == b || (cap > 0 && abs(a.count - b.count) <= cap
                                 && TagSimilarity.levenshtein(a, b) <= cap) else { continue }
                parent[find(i)] = find(j)
            }
        }
        var groups: [Int: Set<String>] = [:]
        for i in tags.indices { groups[find(i), default: []].insert(tags[i]) }
        return groups.values.filter { $0.count > 1 }
    }
}
