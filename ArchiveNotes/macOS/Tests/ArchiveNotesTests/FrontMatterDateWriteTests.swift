import Testing
import Foundation
@testable import ArchiveNotes

// W6-S7 — the date write path. `NotesModel.setDate` / `setDateUncertain` rewrite the item's own
// front-matter (never a Finder tag — 00-overview D2) atomically via the `NoteStore` actor, then
// re-index the one row. These tests drive that path against a scratch `mktemp` store (Prime Directive
// #1 — never a real corpus) and assert the durable round-trip: precision (decade/year/month/day) is
// preserved, out-of-precision input downgrades, the pure `sortDate` reflects the SPEC formula, an
// uncertain date still sorts by value, and the index projection matches what was written.

@Suite("FrontMatterDateWrite — precision round-trip + sortDate")
@MainActor
struct FrontMatterDateWriteTests {

    struct Env { let model: NotesModel; let store: NoteStore; let index: NotesIndex; let root: URL }

    private func makeEnv() async throws -> Env {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-datewrite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = NotesIndex(url: root.appendingPathComponent("index.db"))
        try await index.open()
        let org = OrganizationStore(index: index)
        try await org.load(storeRoot: root)
        let store = NoteStore(root: root)
        let model = NotesModel(organization: org, index: index, noteStore: store)
        return Env(model: model, store: store, index: index, root: root)
    }

    private func cleanup(_ env: Env) async {
        await env.index.close()
        try? FileManager.default.removeItem(at: env.root)
    }

    /// The human-readable date from the index projection (an `ItemSummary`) after a write — the value
    /// the list's Date column shows. `displayDate`/`qualityStars` live on `ItemSummary`, not `Item`.
    private func displayDate(_ env: Env, _ id: UUID) async -> String? {
        await env.index.summary(for: id)?.displayDate
    }

    /// Create + persist a bare note in the scratch store, returning its id.
    @discardableResult
    private func makeNote(_ env: Env, title: String = "Note") async throws -> UUID {
        let item = Item(id: UUID(), kind: .note, title: title, authors: [], date: nil,
                        datePrecision: nil, dateUncertain: false, quality: nil, tags: [], zotero: [],
                        roundup: false, created: Date(), modified: Date(), schema: 1, blocks: [],
                        unknownFrontMatter: [], trailingBodyRaw: nil)
        _ = try await env.store.create(item)
        return item.id
    }

    // MARK: - Precision round-trips

    @Test("year precision round-trips + sortDate = year*10_000")
    func yearRoundTrip() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try await makeNote(env)
        await env.model.setDate("1968", precision: .year, for: id)
        let r = try await env.store.load(id)
        #expect(r.date == "1968")
        #expect(r.datePrecision == .year)
        #expect(r.sortDate == 19_680_000)
        #expect(await displayDate(env, id) == "1968")
    }

    @Test("month precision zero-pads + sortDate carries the month")
    func monthRoundTrip() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try await makeNote(env)
        await env.model.setDate("1968-3", precision: .month, for: id)
        let r = try await env.store.load(id)
        #expect(r.date == "1968-03")
        #expect(r.datePrecision == .month)
        #expect(r.sortDate == 19_680_300)
        #expect(await displayDate(env, id) == "Mar 1968")
    }

    @Test("day precision zero-pads all components + full sortDate")
    func dayRoundTrip() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try await makeNote(env)
        await env.model.setDate("1968-3-5", precision: .day, for: id)
        let r = try await env.store.load(id)
        #expect(r.date == "1968-03-05")
        #expect(r.datePrecision == .day)
        #expect(r.sortDate == 19_680_305)
        #expect(await displayDate(env, id) == "Mar 5, 1968")
    }

    @Test("decade precision floors the year + renders \"1970s\"")
    func decadeRoundTrip() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try await makeNote(env)
        await env.model.setDate("1975", precision: .decade, for: id)
        let r = try await env.store.load(id)
        #expect(r.date == "1970")
        #expect(r.datePrecision == .decade)
        #expect(r.sortDate == 19_700_000)
        #expect(await displayDate(env, id) == "1970s")
    }

    // MARK: - Normalization (downgrade / clear)

    @Test("month precision with no month downgrades to year")
    func monthMissingDowngrades() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try await makeNote(env)
        await env.model.setDate("1968", precision: .month, for: id)
        let r = try await env.store.load(id)
        #expect(r.date == "1968")
        #expect(r.datePrecision == .year)          // never leaves a coarse string at month precision
        #expect(r.sortDate == 19_680_000)          // → sortDate stays valid, not nil
    }

    @Test("day precision with only a month downgrades to month")
    func dayMissingDayDowngrades() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try await makeNote(env)
        await env.model.setDate("1968-07", precision: .day, for: id)
        let r = try await env.store.load(id)
        #expect(r.date == "1968-07")
        #expect(r.datePrecision == .month)
        #expect(r.sortDate == 19_680_700)
    }

    @Test("out-of-range month is dropped (year kept)")
    func badMonthDropped() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try await makeNote(env)
        await env.model.setDate("1968-13", precision: .month, for: id)
        let r = try await env.store.load(id)
        #expect(r.date == "1968")
        #expect(r.datePrecision == .year)
    }

    // MARK: - Impossible days (W23.l4)
    //
    // The day used to be range-checked as 1…31 independently of the month, so `2026-2-31` reached the
    // note file as a day-precision date with a normal sort key. It now downgrades like any other day
    // the string cannot support. These drive the real model → `NoteStore` → front-matter path against
    // the scratch store, so they pin what lands on disk, not just what the pure rule returns.

    @Test("an impossible day is dropped, keeping the month (2026-02-31 ⟹ 2026-02)")
    func impossibleDayDowngrades() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try await makeNote(env)
        await env.model.setDate("2026-2-31", precision: .day, for: id)
        let r = try await env.store.load(id)
        #expect(r.date == "2026-02")
        #expect(r.datePrecision == .month)
        #expect(r.sortDate == 20_260_200)                     // not 20_260_231
        #expect(await displayDate(env, id) == "Feb 2026")      // never "Feb 31, 2026"
    }

    @Test("February 29 is kept in a leap year and dropped in a common one")
    func leapDayRoundTrip() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let leap = try await makeNote(env, title: "Leap")
        await env.model.setDate("2024-2-29", precision: .day, for: leap)
        let l = try await env.store.load(leap)
        #expect(l.date == "2024-02-29")
        #expect(l.datePrecision == .day)
        #expect(l.sortDate == 20_240_229)

        let common = try await makeNote(env, title: "Common")
        await env.model.setDate("2026-2-29", precision: .day, for: common)
        let c = try await env.store.load(common)
        #expect(c.date == "2026-02")
        #expect(c.datePrecision == .month)
    }

    @Test("a 31st in a 30-day month downgrades (1968-04-31 ⟹ 1968-04)")
    func thirtyFirstOfAThirtyDayMonth() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try await makeNote(env)
        await env.model.setDate("1968-4-31", precision: .day, for: id)
        let r = try await env.store.load(id)
        #expect(r.date == "1968-04")
        #expect(r.datePrecision == .month)
    }

    /// The last day of every month, at day precision, must survive untouched — the guard has to reject
    /// only impossible days, never merely late ones.
    @Test("every real month-end still round-trips at day precision")
    func everyMonthEndSurvives() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let lengths = [1: 31, 2: 29, 3: 31, 4: 30, 5: 31, 6: 30,
                       7: 31, 8: 31, 9: 30, 10: 31, 11: 30, 12: 31]   // 1968 is a leap year
        for (m, last) in lengths.sorted(by: { $0.key < $1.key }) {
            let id = try await makeNote(env, title: "M\(m)")
            await env.model.setDate("1968-\(m)-\(last)", precision: .day, for: id)
            let r = try await env.store.load(id)
            let pad = m < 10 ? "0\(m)" : "\(m)"
            #expect(r.date == "1968-\(pad)-\(last)", "month \(m)")
            #expect(r.datePrecision == .day, "month \(m)")
        }
    }

    @Test("nil date clears date + precision (undated)")
    func clearDate() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try await makeNote(env)
        await env.model.setDate("1968-03", precision: .month, for: id)
        await env.model.setDate(nil, precision: nil, for: id)
        let r = try await env.store.load(id)
        #expect(r.date == nil)
        #expect(r.datePrecision == nil)
        #expect(r.sortDate == nil)
        #expect(await displayDate(env, id) == nil)
    }

    @Test("blank/garbage year clears (no usable year)")
    func garbageClears() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try await makeNote(env)
        await env.model.setDate("   ", precision: .year, for: id)
        let a = try await env.store.load(id)
        #expect(a.date == nil && a.datePrecision == nil)
        await env.model.setDate("notayear", precision: .year, for: id)
        let b = try await env.store.load(id)
        #expect(b.date == nil && b.datePrecision == nil)
    }

    // MARK: - Uncertainty (still sorts by value, not last)

    @Test("uncertain date keeps its sortDate (sorts by value, rendered italic — not dumped last)")
    func uncertainSortsByValue() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let early = try await makeNote(env, title: "Early")
        let late = try await makeNote(env, title: "Late")
        await env.model.setDate("1968", precision: .year, for: early)
        await env.model.setDateUncertain(true, for: early)
        await env.model.setDate("1980", precision: .year, for: late)

        let e = try await env.store.load(early)
        #expect(e.dateUncertain == true)
        #expect(e.sortDate == 19_680_000)                    // NOT nil — the uncertain flag never nils it
        let l = try await env.store.load(late)
        #expect(e.sortDate! < l.sortDate!)                   // 1968 (uncertain) still precedes 1980
    }

    @Test("editing the date preserves quality + tags + authors + body")
    func preservesOtherFields() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let item = Item(id: UUID(), kind: .note, title: "Keep", authors: ["Auth"], date: nil,
                        datePrecision: nil, dateUncertain: false, quality: 4, tags: ["Subject"],
                        zotero: [], roundup: false, created: Date(), modified: Date(), schema: 1,
                        blocks: [], unknownFrontMatter: [], trailingBodyRaw: "Body")
        _ = try await env.store.create(item)
        await env.model.setDate("1970-05", precision: .month, for: item.id)
        let r = try await env.store.load(item.id)
        #expect(r.date == "1970-05" && r.datePrecision == .month)   // changed…
        #expect(r.quality == 4)                                     // …rest untouched
        #expect(r.tags == ["Subject"])
        #expect(r.authors == ["Auth"])
        #expect(r.title == "Keep")
        #expect(r.trailingBodyRaw == "Body")
    }

    // MARK: - Index projection reflects the write

    @Test("editing the date re-indexes the row (index projection matches disk)")
    func reindexReflectsDate() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try await makeNote(env)
        await env.model.setDate("1972-06", precision: .month, for: id)
        let s = await env.index.summary(for: id)
        #expect(s?.sortDate == 19_720_600)
        #expect(s?.date == "1972-06")
        #expect(s?.datePrecision == .month)
        #expect(s?.displayDate == "Jun 1972")
    }
}
