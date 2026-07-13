import Testing
import Foundation
@testable import ArchiveNotes

/// W6-S3: deterministic, nil-last, multi-level sort over `ItemSummary` (`NotesSort`).
struct NotesSortTests {

    private func sum(_ title: String, kind: Item.Kind = .note, sortDate: Int? = nil,
                     quality: Int? = nil) -> ItemSummary {
        let t = Date(timeIntervalSince1970: 0)
        return ItemSummary(id: UUID(), title: title, kind: kind, date: nil, datePrecision: nil,
                           dateUncertain: false, authors: [], sortDate: sortDate, quality: quality,
                           created: t, modified: t, mtime: 0, managedTags: [])
    }
    private func desc(_ f: NoteSortField, _ asc: Bool) -> [NoteSortDescriptor] {
        [NoteSortDescriptor(field: f, ascending: asc)]
    }

    @Test func emptyDescriptorsIsIdentity() {
        let items = [sum("b"), sum("a")]
        #expect(NotesSort.sorted(items, by: []).map(\.title) == ["b", "a"])
    }

    @Test func dateAscendingUndatedLast() {
        let items = [sum("x", sortDate: nil), sum("y", sortDate: 19700000), sum("z", sortDate: 18500000)]
        let out = NotesSort.sorted(items, by: desc(.date, true)).map(\.title)
        #expect(out == ["z", "y", "x"])   // 1850 < 1970 < (undated last)
    }

    @Test func dateDescendingUndatedStillLast() {
        let items = [sum("x", sortDate: nil), sum("y", sortDate: 19700000), sum("z", sortDate: 18500000)]
        let out = NotesSort.sorted(items, by: desc(.date, false)).map(\.title)
        #expect(out == ["y", "z", "x"])   // 1970 > 1850, undated LAST regardless of direction
    }

    @Test func qualityNilLast() {
        let items = [sum("a", quality: nil), sum("b", quality: 5), sum("c", quality: 2)]
        let asc = NotesSort.sorted(items, by: desc(.quality, true)).map(\.title)
        #expect(asc == ["c", "b", "a"])   // 2 < 5 < (unrated last)
        let dsc = NotesSort.sorted(items, by: desc(.quality, false)).map(\.title)
        #expect(dsc == ["b", "c", "a"])   // 5 > 2, unrated still last
    }

    @Test func kindSortByRawValue() {
        let items = [sum("n", kind: .note), sum("e", kind: .extract)]
        // "extract" < "note" alphabetically → extract first ascending.
        #expect(NotesSort.sorted(items, by: desc(.kind, true)).map(\.title) == ["e", "n"])
        #expect(NotesSort.sorted(items, by: desc(.kind, false)).map(\.title) == ["n", "e"])
    }

    @Test func titleNaturalOrder() {
        let items = [sum("File 10"), sum("File 2"), sum("File 1")]
        // localizedStandardCompare → natural numeric ordering (2 before 10).
        #expect(NotesSort.sorted(items, by: desc(.title, true)).map(\.title) == ["File 1", "File 2", "File 10"])
    }

    @Test func multiLevelDateThenTitle() {
        let items = [
            sum("beta", sortDate: 19700000),
            sum("alpha", sortDate: 19700000),
            sum("gamma", sortDate: 18500000),
        ]
        let out = NotesSort.sorted(items, by: NotesSort.default).map(\.title)
        #expect(out == ["gamma", "alpha", "beta"])   // 1850 first; then 1970 tie broken by title
    }

    @Test func stableTiebreakByUUIDWhenTitleAndKeysEqual() {
        // Two items identical except id → deterministic order by uuidString (never .orderedSame).
        let t = Date(timeIntervalSince1970: 0)
        let a = ItemSummary(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "same",
                            kind: .note, date: nil, datePrecision: nil, dateUncertain: false, authors: [],
                            sortDate: 19700000, quality: nil, created: t, modified: t, mtime: 0, managedTags: [])
        let b = ItemSummary(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, title: "same",
                            kind: .note, date: nil, datePrecision: nil, dateUncertain: false, authors: [],
                            sortDate: 19700000, quality: nil, created: t, modified: t, mtime: 0, managedTags: [])
        let out1 = NotesSort.sorted([a, b], by: NotesSort.default).map(\.id)
        let out2 = NotesSort.sorted([b, a], by: NotesSort.default).map(\.id)
        #expect(out1 == out2)          // order independent of input order
        #expect(out1 == [a.id, b.id])  // ...001 before ...002
    }

    @Test func relevanceComparatorIsNoOpFallsBackToTitle() {
        // Relevance ordering is injected at recompute() (W6-S4), never via the comparator; a
        // relevance-only sort must not crash and must fall back to the stable title/UUID tiebreak.
        let items = [sum("b", sortDate: 1), sum("a", sortDate: 2)]
        let out = NotesSort.sorted(items, by: desc(.relevance, true)).map(\.title)
        #expect(out == ["a", "b"])
    }
}
