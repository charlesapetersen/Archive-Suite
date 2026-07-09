import XCTest
@testable import ArchiveReader

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
}
