import XCTest
import ArchiveCore

/// Tests for the read-only tag-facet parser, keyed to REAL tag arrays from the corpus.
/// Uses a plain (non-`@testable`) import: every symbol exercised here is part of the
/// public `DocumentTags` API, so the test doubles as a guard that the parse surface stays public.
final class DocumentTagsTests: XCTestCase {

    // Real file 03063 IMG — Brown.pdf
    func testParsesRealDocumentTags() {
        let raw = ["DP chapters", "Unread", "Jerry Brown", "01 January", "1983", "P9", "Speeches", "NCII"]
        let t = DocumentTags.parse(raw: raw, labelNumber: nil)
        XCTAssertEqual(t.year, 1983)
        XCTAssertEqual(t.month?.number, 1)
        XCTAssertEqual(t.month?.name, "January")
        XCTAssertEqual(t.priority, 9)
        XCTAssertEqual(t.readState, .unread)
        XCTAssertNil(t.color)
        XCTAssertFalse(t.dateIsSpeculative)
        XCTAssertEqual(t.sortDate, 19_830_100)
        XCTAssertEqual(Set(t.subjects), ["DP chapters", "Jerry Brown", "Speeches", "NCII"])
    }

    // Real box marker 00001: Red label + "Red" token, no date/priority.
    func testBoxMarkerFoldsColorAndIsUndated() {
        let raw = ["Red", "Unread", "DP chapters", "Jerry Brown"]
        let t = DocumentTags.parse(raw: raw, labelNumber: 6)
        XCTAssertEqual(t.color, .box)
        XCTAssertNil(t.year)
        XCTAssertNil(t.priority)
        XCTAssertEqual(t.readState, .unread)
        XCTAssertFalse(t.subjects.contains("Red"))  // color token, not a subject
        XCTAssertEqual(Set(t.subjects), ["DP chapters", "Jerry Brown"])
        XCTAssertNil(t.sortDate)                     // undated → sorts last
    }

    func testDayTagAndSpeculativeDate() {
        let raw = ["1215", "05 May", "Day 25", "Date Uncertain", "Crusades"]
        let t = DocumentTags.parse(raw: raw, labelNumber: nil)
        XCTAssertEqual(t.year, 1215)                 // medieval-safe: no epoch limit
        XCTAssertEqual(t.month?.number, 5)
        XCTAssertEqual(t.day, 25)
        XCTAssertTrue(t.dateUncertain)
        XCTAssertTrue(t.dateIsSpeculative)
        XCTAssertEqual(t.sortDate, 12_150_525)
        XCTAssertEqual(t.subjects, ["Crusades"])
    }

    // A subject literally "Red" with NO red label must stay a subject (no color inference).
    func testSubjectNamedRedWithoutLabelStaysSubject() {
        let raw = ["Red", "Cold War", "1950", "Unread"]
        let t = DocumentTags.parse(raw: raw, labelNumber: nil)
        XCTAssertNil(t.color)
        XCTAssertTrue(t.subjects.contains("Red"))
        XCTAssertEqual(t.year, 1950)
    }

    // Read-state matching is exact whole-string — a subject "Read later" must NOT be seen as Read.
    func testReadStateIsExactWholeStringMatch() {
        let raw = ["Read later", "Unread", "1970"]
        let t = DocumentTags.parse(raw: raw, labelNumber: nil)
        XCTAssertEqual(t.readState, .unread)
        XCTAssertTrue(t.subjects.contains("Read later"))
    }

    // The retired `P` spelling still parses on read (W19: nothing writes it any more). Zero-padding is
    // accepted on purpose — see `parsePriority`: a token it rejects becomes a SUBJECT instead.
    func testPriorityParsing() {
        XCTAssertEqual(DocumentTags.parsePriority("P10"), 10)
        XCTAssertEqual(DocumentTags.parsePriority("p7"), 7)
        XCTAssertEqual(DocumentTags.parsePriority("P07"), 7, "a lenient read heals a malformed token")
        XCTAssertNil(DocumentTags.parsePriority("P6"))
        XCTAssertNil(DocumentTags.parsePriority("Proposal"))
    }

    // MARK: Quality facet (W19.q2)

    func testQualityParserAcceptsOnlyTheWireScaleAndPublishesCanonicalTokens() {
        XCTAssertEqual(DocumentTags.qualityTokens, ["Q1", "Q2", "Q3"])
        XCTAssertEqual(DocumentTags.parseQuality("Q1"), 1)
        XCTAssertEqual(DocumentTags.parseQuality("q2"), 2, "case-insensitive, as `p7` always was")
        XCTAssertEqual(DocumentTags.parseQuality("Q3"), 3)
        XCTAssertNil(DocumentTags.parseQuality("Q0"), "unrated is represented by no token")
        XCTAssertNil(DocumentTags.parseQuality("Q4"))
        XCTAssertNil(DocumentTags.parseQuality("Q02"))
        XCTAssertNil(DocumentTags.parseQuality("Quality"))
    }

    // The owner-locked wire contract: absence IS unrated, so there is no token to write for it.
    func testUnratedIsTheAbsenceOfATokenAndQ0IsNeverWritable() {
        XCTAssertEqual(DocumentTags.qualityTag(for: 1), "Q1")
        XCTAssertEqual(DocumentTags.qualityTag(for: 3), "Q3")
        XCTAssertNil(DocumentTags.qualityTag(for: nil))
        XCTAssertNil(DocumentTags.qualityTag(for: 0), "`Q0` is never a token")
        XCTAssertNil(DocumentTags.qualityTag(for: 4))

        let unrated = DocumentTags.parse(raw: ["History", "1968"], labelNumber: nil)
        XCTAssertNil(unrated.quality, "no rating token present = unrated")
        XCTAssertNil(unrated.qualityToken)
        XCTAssertNil(unrated.priority)
    }

    // A literal `Q0` is not a rating token at all, so it must stay an ordinary subject — the mirror image
    // of the `P7` case below, and the reason `isRatingToken` exists separately from `parseQuality`.
    func testQ0IsAnOrdinarySubjectRatherThanARatingToken() {
        XCTAssertFalse(DocumentTags.isRatingToken("Q0"))
        let tags = DocumentTags.parse(raw: ["Q0", "History"], labelNumber: nil)
        XCTAssertNil(tags.quality)
        XCTAssertNil(tags.qualityToken)
        XCTAssertTrue(tags.subjects.contains("Q0"))
    }

    func testLegacyPriorityAliasesIntoQualityWithoutARewrite() {
        // (token, quality, the retired 8...10 view). `P7` is a recognized rating token that MEANS
        // unrated — so it is consumed rather than left to become a Subjects suggestion.
        let aliases: [(token: String, quality: Int?, priority: Int?)] = [
            ("P7", nil, nil), ("P8", 1, 8), ("P9", 2, 9), ("P10", 3, 10),
        ]
        for alias in aliases {
            XCTAssertEqual(DocumentTags.parseQuality(alias.token), alias.quality, alias.token)
            XCTAssertTrue(DocumentTags.isRatingToken(alias.token), alias.token)
            let tags = DocumentTags.parse(raw: [alias.token, "History"], labelNumber: nil)
            XCTAssertEqual(tags.quality, alias.quality, alias.token)
            XCTAssertEqual(tags.priority, alias.priority, alias.token)
            XCTAssertEqual(tags.qualityToken, alias.token,
                           "even legacy P7 is a recognized retired-facet token, not a subject")
            XCTAssertEqual(tags.priorityToken, alias.token, "a P token IS the legacy token")
            XCTAssertFalse(tags.subjects.contains(alias.token), alias.token)
            XCTAssertEqual(tags.raw, [alias.token, "History"], "parsing never rewrites legacy bytes")
        }
    }

    // The transitional 8...10 view is DERIVED from the one facet, so the two can never disagree.
    func testCanonicalQualityPublishesTheRetiredPriorityViewButNoLegacyToken() {
        let tags = DocumentTags.parse(raw: ["Q1", "History"], labelNumber: nil)
        XCTAssertEqual(tags.quality, 1)
        XCTAssertEqual(tags.priority, 8, "Q1 reads as the old P8 for the pre-W19 Reader surfaces")
        XCTAssertEqual(tags.qualityToken, "Q1")
        XCTAssertNil(tags.priorityToken,
                     "a canonical Q token is NOT a legacy token — the retired edit must not touch it")
    }

    func testCanonicalAndLegacyQualityTokensShareOneLastWinnerFacet() {
        let legacyWins = DocumentTags.parse(raw: ["Q1", "P10", "History"], labelNumber: nil)
        XCTAssertEqual(legacyWins.quality, 3)
        XCTAssertEqual(legacyWins.qualityToken, "P10")
        XCTAssertTrue(legacyWins.subjects.contains("Q1"), "the shadowed collision stays visible")

        let canonicalWins = DocumentTags.parse(raw: ["P10", "Q2", "History"], labelNumber: nil)
        XCTAssertEqual(canonicalWins.quality, 2)
        XCTAssertEqual(canonicalWins.qualityToken, "Q2")
        XCTAssertTrue(canonicalWins.subjects.contains("P10"), "the shadowed collision stays visible")
        XCTAssertNil(canonicalWins.priorityToken,
                     "the winner is canonical, so there is no legacy token for the retired edit to remove")

        // A legacy P7 can shadow a canonical rating, because both spellings are the same one facet.
        let unratedWins = DocumentTags.parse(raw: ["Q2", "P7", "History"], labelNumber: nil)
        XCTAssertNil(unratedWins.quality, "last token wins, and P7 means unrated")
        XCTAssertEqual(unratedWins.qualityToken, "P7")
        XCTAssertTrue(unratedWins.subjects.contains("Q2"))
    }

    func testQualityShapedSubjectSurvivesInTheVerbatimSourceOfTruth() {
        let raw = ["Q2", "History"]
        let tags = DocumentTags.parse(raw: raw, labelNumber: nil)
        XCTAssertEqual(tags.quality, 2)
        XCTAssertEqual(tags.raw, raw,
                       "facet classification is read-only; a subject collision must never rewrite bytes")
    }

    // A hand-built value cannot smuggle an off-scale rating into the model either.
    func testOffScaleQualityNormalizesToUnratedInTheInitializer() {
        func made(_ q: Int?) -> DocumentTags {
            DocumentTags(raw: [], labelNumber: nil, year: nil, month: nil, day: nil,
                         dateUncertain: false, decade: nil, quality: q, readState: nil, color: nil,
                         subjects: [], yearToken: nil, monthToken: nil, dayToken: nil,
                         decadeToken: nil, qualityToken: nil)
        }
        XCTAssertEqual(made(2).quality, 2)
        XCTAssertNil(made(0).quality, "`Q0` is not representable")
        XCTAssertNil(made(4).quality)
        XCTAssertNil(made(8).quality, "the 8...10 scale is a derived VIEW, never an input")
    }

    func testRawArrayIsPreservedVerbatim() {
        let raw = ["Red", "Unread", "DP chapters", "Jerry Brown"]
        let t = DocumentTags.parse(raw: raw, labelNumber: 6)
        XCTAssertEqual(t.raw, raw)  // never reordered or mutated
    }

    // MARK: Decade facet

    func testParseDecadeValidTokens() {
        XCTAssertEqual(DocumentTags.parseDecade("1970s"), 1970)
        XCTAssertEqual(DocumentTags.parseDecade("1980s"), 1980)
        XCTAssertEqual(DocumentTags.parseDecade("970s"), 970)      // medieval-friendly 3-digit
        XCTAssertEqual(DocumentTags.parseDecade("800s"), 800)
    }

    func testParseDecadeRejectsInvalid() {
        XCTAssertNil(DocumentTags.parseDecade("1975s"))   // last digit not 0
        XCTAssertNil(DocumentTags.parseDecade("1970S"))   // uppercase S
        XCTAssertNil(DocumentTags.parseDecade("1970"))    // no trailing s
        XCTAssertNil(DocumentTags.parseDecade("19700s"))  // 5-digit run
        XCTAssertNil(DocumentTags.parseDecade("s"))       // no digits
        XCTAssertNil(DocumentTags.parseDecade(""))        // empty
    }

    func testDecadeParseIntegration() {
        let raw = ["1970s", "Economics", "Unread"]
        let t = DocumentTags.parse(raw: raw, labelNumber: nil)
        XCTAssertEqual(t.decade, 1970)
        XCTAssertEqual(t.decadeToken, "1970s")
        XCTAssertNil(t.year)
        XCTAssertEqual(t.subjects, ["Economics"])               // decade NOT in subjects
        XCTAssertFalse(t.topicalTags.contains("1970s"))         // excluded from topicalTags
    }

    func testDecadeSortDate() {
        let t = DocumentTags.parse(raw: ["1970s"], labelNumber: nil)
        XCTAssertEqual(t.sortDate, 19_700_000)
        // Equals a year-only 1970
        let yearOnly = DocumentTags.parse(raw: ["1970"], labelNumber: nil)
        XCTAssertEqual(t.sortDate, yearOnly.sortDate)
    }

    func testDecadeDisplayDate() {
        let t = DocumentTags.parse(raw: ["1970s", "Economics"], labelNumber: nil)
        XCTAssertEqual(t.displayDate, "1970s")
        XCTAssertTrue(t.dateIsSpeculative)                      // decade-only is speculative
    }

    func testYearSupersedesDecadeInSortAndDisplay() {
        // Both year and decade on one file — year wins sortDate/displayDate; decade is hidden.
        let t = DocumentTags.parse(raw: ["1970s", "1975", "Economics"], labelNumber: nil)
        XCTAssertEqual(t.year, 1975)
        XCTAssertEqual(t.decade, 1970)
        XCTAssertEqual(t.sortDate, 19_750_000)                  // year wins
        XCTAssertEqual(t.displayDate, "1975")                   // year wins
        XCTAssertFalse(t.dateIsSpeculative)                     // concrete year, not speculative
    }

    func testTwoDecadesLastWinsPreviousDemoted() {
        let t = DocumentTags.parse(raw: ["1960s", "1970s", "Economics"], labelNumber: nil)
        XCTAssertEqual(t.decade, 1970)
        XCTAssertEqual(t.decadeToken, "1970s")
        XCTAssertTrue(t.subjects.contains("1960s"))             // first decade demoted to subject
    }

    func testDecadeNotInTagCloudOrFilter() {
        // Decade token is consumed (continue), so it never lands in subjects —
        // tag cloud and filter autocomplete derive from subjects, so decade is excluded for free.
        let t = DocumentTags.parse(raw: ["1970s", "Economics"], labelNumber: nil)
        XCTAssertFalse(t.subjects.contains("1970s"))
    }

    func testMedievalDecade() {
        let t = DocumentTags.parse(raw: ["970s", "Manuscripts"], labelNumber: nil)
        XCTAssertEqual(t.decade, 970)
        XCTAssertEqual(t.sortDate, 9_700_000)
        XCTAssertEqual(t.displayDate, "970s")
    }

    // SPEC/tag-format.md discrepancy #3: Archive Processor emits literal `Box`/`Folder` (on marker
    // pages, alongside the color) and `OCR Failed` (on OCR failures) as ordinary subject tokens. They
    // must classify as plain SUBJECTS — never a facet, never the color token — so they can't drive a
    // destructive write and stay visible for filtering.
    func testProcessorLiteralSubjectTokensClassifyAsSubjects() {
        // Box marker: Red label (6) + "Red" color token + literal "Box" subject.
        let box = DocumentTags.parse(raw: ["Red", "Box", "Unread", "DP chapters"], labelNumber: 6)
        XCTAssertEqual(box.color, .box)
        XCTAssertFalse(box.subjects.contains("Red"))   // color token folded, not a subject
        XCTAssertTrue(box.subjects.contains("Box"))    // literal marker word stays a subject
        XCTAssertNil(box.year)
        XCTAssertNil(box.priority)

        // Folder marker: Purple label (3) + "Purple" color token + literal "Folder" subject.
        let folder = DocumentTags.parse(raw: ["Purple", "Folder", "Unread"], labelNumber: 3)
        XCTAssertEqual(folder.color, .folder)
        XCTAssertFalse(folder.subjects.contains("Purple"))
        XCTAssertTrue(folder.subjects.contains("Folder"))

        // OCR failure: literal "OCR Failed" subject, alongside a normal year.
        let failed = DocumentTags.parse(raw: ["OCR Failed", "Unread", "1980"], labelNumber: nil)
        XCTAssertTrue(failed.subjects.contains("OCR Failed"))
        XCTAssertEqual(failed.year, 1980)              // the literal subject doesn't disturb real facets

        // Each literal token is preserved verbatim and surfaces in topicalTags (never silently dropped).
        for t in [box, folder, failed] {
            for token in ["Box", "Folder", "OCR Failed"] where t.raw.contains(token) {
                XCTAssertTrue(t.topicalTags.contains(token), "\(token) should surface in topicalTags")
            }
        }
    }

    // MARK: - Shared sort-date combiner (reused by Reader's DocumentTags.sortDate + Notes' Item.sortDate)

    func testSortDateKeyFormula() {
        // year * 10_000 + month * 100 + day; absent month/day count as 0.
        XCTAssertEqual(DocumentTags.sortDateKey(year: 1968, month: nil, day: nil, decade: nil), 19_680_000)
        XCTAssertEqual(DocumentTags.sortDateKey(year: 1968, month: 3, day: nil, decade: nil), 19_680_300)
        XCTAssertEqual(DocumentTags.sortDateKey(year: 1968, month: 3, day: 25, decade: nil), 19_680_325)
        // Medieval-safe: no epoch floor.
        XCTAssertEqual(DocumentTags.sortDateKey(year: 842, month: nil, day: nil, decade: nil), 8_420_000)
    }

    func testSortDateKeyYearWinsOverDecade() {
        // When both are present, year supersedes decade (matches parse-time demotion).
        XCTAssertEqual(DocumentTags.sortDateKey(year: 1975, month: nil, day: nil, decade: 1970), 19_750_000)
    }

    func testSortDateKeyDecadeOnly() {
        XCTAssertEqual(DocumentTags.sortDateKey(year: nil, month: nil, day: nil, decade: 1970), 19_700_000)
    }

    func testSortDateKeyUndatedIsNil() {
        // Neither a year nor a decade → nil (caller sorts undated rows last). A stray month/day alone
        // (no year) is still nil, never a spurious low key.
        XCTAssertNil(DocumentTags.sortDateKey(year: nil, month: nil, day: nil, decade: nil))
        XCTAssertNil(DocumentTags.sortDateKey(year: nil, month: 3, day: 25, decade: nil))
    }

    func testSortDateRoutesThroughSharedCombiner() {
        // The instance property must be exactly the shared combiner over its own facets.
        let t = DocumentTags.parse(raw: ["1968", "03 March", "Day 25"], labelNumber: nil)
        XCTAssertEqual(t.sortDate,
                       DocumentTags.sortDateKey(year: t.year, month: t.month?.number, day: t.day, decade: t.decade))
    }
}
