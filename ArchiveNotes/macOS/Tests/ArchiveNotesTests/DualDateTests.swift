import Testing
import Foundation
@testable import ArchiveNotes
import ArchiveCore

/// W37.dual-date — the item's own date plus a separately labelled sent-with (covering letter) date:
/// front-matter `additional_dates` round-trip, own-date sort with sent-with fallback, either-role date
/// filtering (the SAME value must satisfy both bounds), one index row per UUID, and an exact-ownership
/// `Sent With …` projection onto the note's own scratch `.md`. Never the real store or corpus.
@Suite("DualDate — own date + sent-with date")
@MainActor
struct DualDateTests {
    struct Env { let model: NotesModel; let store: NoteStore; let index: NotesIndex; let root: URL }

    private func makeEnv() async throws -> Env {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-dualdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = NotesIndex(url: root.appendingPathComponent("index.db"))
        try await index.open()
        let org = OrganizationStore(index: index)
        try await org.load(storeRoot: root)
        let store = NoteStore(root: root)
        return Env(model: NotesModel(organization: org, index: index, noteStore: store),
                   store: store, index: index, root: root)
    }

    private func cleanup(_ env: Env) async {
        await env.index.close()
        try? FileManager.default.removeItem(at: env.root)
    }

    private func item(date: String? = nil, precision: Item.DatePrecision? = nil,
                      sentWith: ArchiveDate? = nil, sentWithUncertain: Bool = false,
                      tags: [String] = []) -> Item {
        Item(id: UUID(), kind: .note, title: "Enclosure", authors: [], date: date,
             datePrecision: precision, dateUncertain: false, quality: nil, tags: tags, zotero: [],
             roundup: false, created: Date(timeIntervalSince1970: 0), modified: Date(timeIntervalSince1970: 0),
             schema: 1, blocks: [], unknownFrontMatter: [], trailingBodyRaw: nil,
             sentWith: sentWith, sentWithUncertain: sentWithUncertain)
    }

    private func summary(_ item: Item) -> ItemSummary {
        ItemSummary(id: item.id, title: item.title, kind: item.kind, date: item.date,
                    datePrecision: item.datePrecision, dateUncertain: item.dateUncertain, authors: [],
                    sortDate: item.sortDate, quality: nil, created: item.created, modified: item.modified,
                    mtime: 0, managedTags: [], sentWith: item.sentWith,
                    sentWithUncertain: item.sentWithUncertain)
    }

    private func finderTags(_ env: Env, _ id: UUID) async throws -> [String] {
        let url = try await env.store.mdURL(for: id)
        return try url.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
    }

    private static let allPrecisions: [ArchiveDate] = [
        ArchiveDate(decade: 1950)!, ArchiveDate(year: 1958)!,
        ArchiveDate(year: 1958, month: 3)!, ArchiveDate(year: 1958, month: 3, day: 12)!,
    ]

    // MARK: Front matter

    @Test("save/reload round-trips every precision and the uncertainty flag")
    func saveReloadRoundTrip() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        for value in Self.allPrecisions {
            for uncertain in [false, true] {
                let original = item(date: "1957-11-03", precision: .day, sentWith: value,
                                    sentWithUncertain: uncertain)
                _ = try await env.store.create(original)
                let loaded = try await env.store.load(original.id)
                #expect(loaded.sentWith == value, "\(value.wireValue)")
                #expect(loaded.sentWithUncertain == uncertain)
                #expect(loaded.date == "1957-11-03" && loaded.datePrecision == .day,
                        "the own date is untouched by the sent-with entry")
                #expect(FrontMatterCodec.encode(try FrontMatterCodec.decode(FrontMatterCodec.encode(loaded)))
                        == FrontMatterCodec.encode(loaded), "encode is stable across a reload")
            }
        }
    }

    @Test("own-only omits additional_dates; sent-only and both carry it")
    func ownOnlySentOnlyBoth() throws {
        let own = item(date: "1957", precision: .year)
        #expect(!FrontMatterCodec.encode(own).contains("additional_dates"))
        #expect(try FrontMatterCodec.decode(FrontMatterCodec.encode(own)).sentWith == nil)

        let sentOnly = item(sentWith: ArchiveDate(year: 1958, month: 3)!)
        let sentText = FrontMatterCodec.encode(sentOnly)
        #expect(sentText.contains("additional_dates:\n  - role: sent_with\n    date: 1958-03\n    precision: month"))
        let sentBack = try FrontMatterCodec.decode(sentText)
        #expect(sentBack.date == nil && sentBack.sentWith == ArchiveDate(year: 1958, month: 3))

        let both = item(date: "1957-11-03", precision: .day, sentWith: ArchiveDate(year: 1958, month: 3, day: 12)!)
        let bothBack = try FrontMatterCodec.decode(FrontMatterCodec.encode(both))
        #expect(bothBack.date == "1957-11-03" && bothBack.sentWith == ArchiveDate(year: 1958, month: 3, day: 12))
    }

    @Test("a decade sent-with date is stored as its start year with decade precision")
    func decadeSpelling() throws {
        let text = FrontMatterCodec.encode(item(sentWith: ArchiveDate(decade: 1950)!))
        #expect(text.contains("    date: 1950\n    precision: decade"))
    }

    @Test("invalid, unknown-role and duplicate entries are kept verbatim, never interpreted or crashed on")
    func invalidEntriesKeptVerbatim() throws {
        let id = UUID().uuidString.lowercased()
        let text = """
            ---
            schema: 1
            id: \(id)
            kind: note
            title: T
            additional_dates:
              - role: sent_with
                date: 1958-02-30
                precision: day
                uncertain: false
              - role: received
                date: 1960
                precision: year
              - role: sent_with
                date: 1958
                precision: year
                uncertain: true
              - role: sent_with
                date: 1970
                precision: year
            roundup: false
            ---
            Body
            """
        let decoded = try FrontMatterCodec.decode(text)
        #expect(decoded.sentWith == ArchiveDate(year: 1958), "the first VALID sent_with entry is taken")
        #expect(decoded.sentWithUncertain)
        #expect(decoded.unparsedAdditionalDates.count == 3,
                "the impossible date, the unknown role and the second sent_with stay verbatim")
        let reencoded = FrontMatterCodec.encode(decoded)
        #expect(reencoded.contains("    date: 1958-02-30"))
        #expect(reencoded.contains("  - role: received"))
        #expect(reencoded.contains("    date: 1970"))
        let again = try FrontMatterCodec.decode(reencoded)
        #expect(again.sentWith == decoded.sentWith && again.unparsedAdditionalDates == decoded.unparsedAdditionalDates)
    }

    @Test("clearing the sent-with date retires a second hand-written sent_with entry instead of promoting it")
    func clearRetiresStaleSentWith() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let original = item(date: "1957", precision: .year)
        _ = try await env.store.create(original)
        let url = try await env.store.mdURL(for: original.id)
        let text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "\nroundup:", with: """

            additional_dates:
              - role: sent_with
                date: 1958-03
                precision: month
              - role: sent_with
                date: 1960
                precision: year
              - role: received
                date: 1961
                precision: year
            roundup:
            """)
        try text.write(to: url, atomically: true, encoding: .utf8)
        #expect(try await env.store.load(original.id).sentWith == ArchiveDate(year: 1958, month: 3))
        #expect(await env.model.setSentWith(nil, precision: nil, for: original.id))
        let cleared = try await env.store.load(original.id)
        #expect(cleared.sentWith == nil, "the 1960 entry must not take the cleared date's place")
        #expect(cleared.unparsedAdditionalDates.count == 1, "the other role is kept")
        #expect(FrontMatterCodec.encode(cleared).contains("  - role: received"))
    }

    @Test("a non-block additional_dates value is replayed as its own key, never under a second header")
    func inlineValueNeverDuplicatesTheKey() throws {
        let text = "---\nid: \(UUID())\nadditional_dates: [{role: sent_with, date: 1958, precision: year}]\n---\n"
        let decoded = try FrontMatterCodec.decode(text)
        #expect(decoded.sentWith == nil)
        let out = FrontMatterCodec.encode(decoded)
        #expect(out.components(separatedBy: "additional_dates:").count == 2, "exactly one key")
        var edited = decoded
        edited.sentWith = ArchiveDate(year: 1960)
        edited.unparsedAdditionalDates.removeAll { $0.key == FrontMatterCodec.inlineAdditionalDatesKey }
        #expect(FrontMatterCodec.encode(edited).components(separatedBy: "additional_dates:").count == 2)
        let commented = "---\nid: \(UUID())\nadditional_dates:   # enclosures\n  - role: sent_with\n    date: 1958\n    precision: year\n---\n"
        #expect(try FrontMatterCodec.decode(commented).sentWith == ArchiveDate(year: 1958))
    }

    @Test("an unrecognised uncertain value keeps the entry verbatim")
    func oddUncertainKeptVerbatim() throws {
        let text = "---\nid: \(UUID())\nadditional_dates:\n  - role: sent_with\n    date: 1958\n    precision: year\n    uncertain: maybe\n---\n"
        let decoded = try FrontMatterCodec.decode(text)
        #expect(decoded.sentWith == nil)
        #expect(FrontMatterCodec.encode(decoded).contains("uncertain: maybe"))
    }

    @Test("a precision the date string does not carry is not coerced")
    func mismatchedPrecisionNotCoerced() throws {
        let text = "---\nid: \(UUID())\nadditional_dates:\n  - role: sent_with\n    date: 1958\n    precision: day\n---\n"
        let decoded = try FrontMatterCodec.decode(text)
        #expect(decoded.sentWith == nil)
        #expect(decoded.unparsedAdditionalDates.count == 1)
    }

    // MARK: Sort

    @Test("the own date sorts; the sent-with date is the labelled fallback")
    func sortFallback() {
        let both = item(date: "1957-11-03", precision: .day, sentWith: ArchiveDate(year: 1958, month: 3, day: 12)!)
        #expect(both.sortDate == 19571103 && !both.sortsBySentWith)
        let sentOnly = item(sentWith: ArchiveDate(year: 1958, month: 3)!)
        #expect(sentOnly.sortDate == 19580300 && sentOnly.sortsBySentWith)
        #expect(item().sortDate == nil && !item().sortsBySentWith)

        let rows = [summary(both), summary(sentOnly), summary(item(date: "1957", precision: .year))]
        let sorted = NotesSort.sorted(rows, by: NotesSort.default)
        #expect(sorted.map(\.sortDate) == [19570000, 19571103, 19580300])
        #expect(summary(sentOnly).sortsBySentWith && summary(sentOnly).dateColumnText == "Sent with Mar 1958")
        #expect(summary(both).dateColumnText == "Nov 3, 1957 · sent with Mar 12, 1958")
    }

    // MARK: Filter

    @Test("a date range matches either role, but both bounds must hold for the SAME value")
    func filterMatchesEitherRole() {
        let enclosure = summary(item(date: "1950", precision: .year, sentWith: ArchiveDate(year: 1970)!))
        func range(_ from: Int, _ to: Int) -> NotesFilter {
            var f = NotesFilter()
            f.dateFrom = from * 10_000
            f.dateTo = to * 10_000 + 1231
            return f
        }
        #expect(!range(1960, 1965).matches(enclosure, folderItemIDs: nil),
                "own 1950 + sent 1970 must not satisfy 1960–1965 by splitting the bounds")
        #expect(range(1948, 1952).matches(enclosure, folderItemIDs: nil))
        #expect(range(1948, 1952).matchingDateRoles(enclosure) == [.own])
        #expect(range(1969, 1971).matches(enclosure, folderItemIDs: nil))
        #expect(range(1969, 1971).matchingDateRoles(enclosure) == [.sentWith])
        #expect(range(1940, 1980).matchingDateRoles(enclosure) == [.own, .sentWith])

        var lowerOnly = NotesFilter(); lowerOnly.dateFrom = 1960 * 10_000
        #expect(lowerOnly.matches(enclosure, folderItemIDs: nil), "the sent-with 1970 alone satisfies ≥ 1960")
        let undated = summary(item())
        #expect(!range(1900, 2000).matches(undated, folderItemIDs: nil))
    }

    // MARK: Index

    @Test("index rows keep the sent-with date, one row per UUID, across a full rebuild")
    func indexOneRowPerUUID() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let sent = ArchiveDate(year: 1958, month: 3, day: 12)!
        let both = item(date: "1957-11-03", precision: .day, sentWith: sent, sentWithUncertain: true)
        let sentOnly = item(sentWith: ArchiveDate(decade: 1950)!)
        let bothRef = try await env.store.create(both)
        _ = try await env.store.create(sentOnly)

        try await env.index.upsertBatch([NoteIndexRow(item: both, mtime: bothRef.mtime)])
        try await env.index.upsertBatch([NoteIndexRow(item: both, mtime: bothRef.mtime)])
        let first = await env.index.allSummaries().filter { $0.id == both.id }
        #expect(first.count == 1)
        #expect(first.first?.sentWith == sent && first.first?.sentWithUncertain == true)
        #expect(first.first?.ownSortDate == 19571103)

        // Rebuild from disk into a fresh, empty index (the disposable cache is deleted).
        let fresh = NotesIndex(url: env.root.appendingPathComponent("rebuilt.db"))
        try await fresh.open()
        let indexer = NotesIndexer(index: fresh)
        indexer.startIndexing(await env.store.allItemRefs())
        await indexer.awaitSettled()
        let rebuilt = await fresh.allSummaries()
        #expect(rebuilt.count == 2, "one row per UUID even though each item has two dates")
        let rb = try #require(rebuilt.first { $0.id == both.id })
        #expect(rb.sentWith == sent && rb.sentWithUncertain && rb.date == "1957-11-03")
        let rs = try #require(rebuilt.first { $0.id == sentOnly.id })
        #expect(rs.sentWith == ArchiveDate(decade: 1950) && rs.sortDate == 19500000 && rs.sortsBySentWith)
        await fresh.close()
    }

    // MARK: Projection

    @Test("the sent-with tokens project onto the note's own .md and only Notes-owned ones are removed")
    func projectsSentWithLosslessly() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let note = item(tags: ["Sent With 1960"])
        _ = try await env.store.create(note)
        let url = try await env.store.mdURL(for: note.id)
        #expect(NotesTagProjector.isScratchPath(url.path))
        // A third-party sent-with lookalike and an unrelated tag already on the file.
        try (url as NSURL).setResourceValue(["Sent With 1960", "Sent With 1980", "Do Not Sync"],
                                            forKey: .tagNamesKey)

        await env.model.setDate("1957-11-03", precision: .day, for: note.id)
        #expect(await env.model.setSentWith("1958-03-12", precision: .day, for: note.id))
        var tags = try await finderTags(env, note.id)
        #expect(Set(tags) == ["Sent With 1960", "Sent With 1980", "Do Not Sync",
                              "1957", "11 November", "Day 3", "Sent With 1958-03-12"])
        let parsed = DocumentTags.parse(raw: tags, labelNumber: nil)
        #expect(parsed.sentWith == ArchiveDate(year: 1958, month: 3, day: 12),
                "the authoritative token is appended last, so it wins over lookalike subjects")
        #expect(parsed.year == 1957 && parsed.day == 3, "the own date never cross-pairs with the sent-with date")

        await env.model.setSentWithUncertain(true, for: note.id)
        tags = try await finderTags(env, note.id)
        #expect(tags.contains(SentWithTag.uncertainToken))

        #expect(await env.model.setSentWith("1958", precision: .year, for: note.id))
        tags = try await finderTags(env, note.id)
        #expect(tags.contains("Sent With 1958") && !tags.contains("Sent With 1958-03-12"))
        #expect(tags.contains(SentWithTag.uncertainToken))

        #expect(await env.model.setSentWith(nil, precision: nil, for: note.id))
        tags = try await finderTags(env, note.id)
        #expect(Set(tags) == ["Sent With 1960", "Sent With 1980", "Do Not Sync", "1957", "11 November", "Day 3"],
                "clearing removes only the Notes-owned sent-with tokens; the subject and the third-party tag stay")
        let reloaded = try await env.store.load(note.id)
        #expect(reloaded.sentWith == nil && !reloaded.sentWithUncertain && reloaded.date == "1957-11-03")
    }

    @Test("an uncertainty flag cannot be stored or projected without a sent-with date")
    func uncertaintyNeedsAValue() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let note = item()
        _ = try await env.store.create(note)
        await env.model.setSentWithUncertain(true, for: note.id)
        #expect(try await env.store.load(note.id).sentWithUncertain == false)
        #expect(!(try await finderTags(env, note.id)).contains(SentWithTag.uncertainToken))
        #expect(NotesTagVocabulary.sentWithFacetTokens(for: item(sentWithUncertain: true)).isEmpty)
    }
}
