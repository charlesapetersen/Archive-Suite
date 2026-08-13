// DateSortParityTests.swift — the SPEC §7 chronological sort key (shared DocumentTags.sortDate).
//
// This is the ONE sort formula every Suite app must agree on (SPEC/tag-format.md §7;
// 00-overview §7/§10). Reader reuses `DocumentTags.sortDate` directly; Archive Notes pins its
// own `Item.sortDate` against this same formula (see the cross-implementation parity guard in
// ArchiveNotesTests/ItemSortDateTests). Pinning the formula here is the guard against the
// silent-divergence risk the SPEC warns about.
import Testing
import Foundation
@testable import ArchiveCore

@Suite("DateSortParity — SPEC §7 sort key (shared DocumentTags.sortDate)")
struct DateSortParityTests {

    /// A facet-only `DocumentTags` carrying just the date fields the sort key reads.
    private func dated(year: Int? = nil, month: Int? = nil, day: Int? = nil,
                       decade: Int? = nil, uncertain: Bool = false) -> DocumentTags {
        DocumentTags(
            raw: [], labelNumber: nil,
            year: year,
            month: month.map { DocumentTags.Month(number: $0, name: "") },
            day: day, dateUncertain: uncertain, decade: decade,
            quality: nil, readState: nil, color: nil, subjects: [],
            yearToken: nil, monthToken: nil, dayToken: nil, decadeToken: nil, qualityToken: nil
        )
    }

    // MARK: - The formula: year*10_000 + month*100 + day

    @Test func sortDateMatchesSPECFormula() {
        // Assert the PROPERTY (independent recompute), not just spot constants, over a table.
        let rows: [(year: Int, month: Int?, day: Int?)] = [
            (1962, nil, nil), (1962, 1, nil), (1962, 12, nil),
            (1962, 3, 5), (1983, 1, nil), (2001, 11, 30), (1900, 6, 15),
        ]
        for r in rows {
            let expected = r.year * 10_000 + (r.month ?? 0) * 100 + (r.day ?? 0)
            #expect(dated(year: r.year, month: r.month, day: r.day).sortDate == expected)
        }
    }

    @Test func monthAndDayAbsentCountAsZero() {
        // A year-only doc sorts just before its January (…_0000 < …_0100).
        #expect(dated(year: 1962).sortDate == 19_620_000)
        #expect(dated(year: 1962, month: 1).sortDate == 19_620_100)
        #expect(dated(year: 1962).sortDate! < dated(year: 1962, month: 1).sortDate!)
    }

    // MARK: - Decades

    @Test func decadeSortsAtDecadeStart() {
        // "1970s" → decade start, identical to the year-only 1970 key (SPEC + Verified-Facts).
        #expect(dated(decade: 1970).sortDate == 19_700_000)
        #expect(dated(decade: 1970).sortDate == dated(year: 1970).sortDate)
    }

    @Test func yearSupersedesDecade() {
        // With both present the concrete year wins (decade is only the fallback branch).
        #expect(dated(year: 1975, decade: 1970).sortDate == 19_750_000)
    }

    // MARK: - Medieval / short years (no epoch floor)

    @Test func threeDigitAndMedievalYears() {
        #expect(dated(year: 842).sortDate == 8_420_000)                       // 3-digit year
        #expect(dated(year: 1215, month: 5, day: 25).sortDate == 12_150_525)  // medieval full date
        // Chronological order holds across the millennium boundary.
        #expect(dated(year: 842).sortDate! < dated(year: 1215).sortDate!)
    }

    // MARK: - Uncertain + undated

    @Test func uncertainStillSortsByItsDate() {
        // A speculative date still yields its real key (shown italic in the UI, never dumped last).
        #expect(dated(year: 1968, uncertain: true).sortDate == 19_680_000)
        #expect(dated(year: 1968, uncertain: true).dateIsSpeculative == true)
    }

    @Test func noYearNoDecadeIsNil() {
        #expect(dated().sortDate == nil)
        #expect(dated(month: 3, day: 5).sortDate == nil)   // month/day without a year → undated
    }
}
