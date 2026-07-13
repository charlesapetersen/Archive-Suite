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
