import Testing
import Foundation
import SwiftUI
import Vision
import ArchiveCore
@testable import ArchiveNotes

// W24.cal1-toggle — the Settings switch (default off) and the per-item display calendar. Display only:
// these tests pin that the stored ISO date is the same bytes before and after a calendar is chosen, that
// the choice round-trips through front-matter and the index, that with the switch off nothing visible
// changes, and (headless render + OCR) that the header actually draws a non-Gregorian date. Scratch
// `mktemp` stores only — never a real corpus.

@Suite("DisplayCalendarToggle — setting, front-matter round trip, unchanged stored date")
@MainActor
struct DisplayCalendarToggleTests {

    struct Env { let model: NotesModel; let store: NoteStore; let index: NotesIndex; let root: URL }

    private func makeEnv() async throws -> Env {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-calendar-\(UUID().uuidString)", isDirectory: true)
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

    private func makeNote(_ env: Env) async throws -> UUID {
        let item = Item(id: UUID(), kind: .note, title: "Letter", authors: [], date: nil,
                        datePrecision: nil, dateUncertain: false, quality: nil, tags: [], zotero: [],
                        roundup: false, created: Date(), modified: Date(), schema: 1, blocks: [],
                        unknownFrontMatter: [], trailingBodyRaw: nil)
        _ = try await env.store.create(item)
        return item.id
    }

    /// The item's `.md` on disk, read as raw bytes.
    private func fileBytes(_ env: Env, _ id: UUID) throws -> Data {
        let dir = NoteStore.itemDir(root: env.root, id: id)
        let md = try #require(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "md" })
        return try Data(contentsOf: md)
    }

    /// The file's lines minus the two that a choice is allowed to change: `modified:` (every save stamps
    /// it) and `display_calendar:` (the choice itself).
    private func linesOtherThanTheChoice(_ data: Data) -> [Substring] {
        String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("modified:") && !$0.hasPrefix("display_calendar:") }
    }

    private func dateLine(_ data: Data) -> Data? {
        String(decoding: data, as: UTF8.self).split(separator: "\n")
            .first { $0.hasPrefix("date:") }.map { Data($0.utf8) }
    }

    // MARK: - The setting

    @Test("the setting is off when nothing has been stored")
    func settingDefaultsOff() throws {
        let suite = "an-cal-default-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(DisplayCalendarSettings.isEnabled(defaults) == false)
        defaults.set(true, forKey: DisplayCalendarSettings.enabledKey)
        #expect(DisplayCalendarSettings.isEnabled(defaults) == true)
    }

    @Test("with the setting off, a chosen calendar changes nothing visible")
    func offShowsAsStored() {
        let s = summary(date: "1752-09-13", calendar: .julianEnglish1752,
                        sentWith: ArchiveDate(year: 1752, month: 9, day: 1))
        #expect(s.displayDate(calendarsEnabled: false) == s.displayDate)
        #expect(s.displayDate(calendarsEnabled: false) == "Sep 13, 1752")
        #expect(s.dateColumnText(calendarsEnabled: false) == s.dateColumnText)
        #expect(s.displaySentWith(calendarsEnabled: false) == s.displaySentWith)
        #expect(s.activeCalendar(calendarsEnabled: false) == nil)
    }

    @Test("with the setting on, day dates show in the item's calendar")
    func onShowsInCalendar() {
        // England's last Julian day and the first Gregorian one.
        #expect(summary(date: "1752-09-13", calendar: .julianEnglish1752).displayDate(calendarsEnabled: true)
                == "2 September 1752 (O.S.)")
        #expect(summary(date: "1752-09-14", calendar: .julianEnglish1752).displayDate(calendarsEnabled: true)
                == "14 September 1752")
        #expect(summary(date: "1804-01-01", calendar: .frenchRepublican).displayDate(calendarsEnabled: true)
                == "10 Nivôse An XII")
        // The sent-with date converts the same way, and the column labels it.
        let both = summary(date: "1752-09-13", calendar: .julian,
                           sentWith: ArchiveDate(year: 1752, month: 9, day: 14))
        #expect(both.dateColumnText(calendarsEnabled: true)
                == "2 September 1752 (O.S.) · sent with 3 September 1752 (O.S.)")
    }

    @Test("coarser dates, out-of-range days and `standard` fall back to the stored rendering")
    func fallsBackToStored() {
        #expect(summary(date: "1752-09", precision: .month, calendar: .julian)
                    .displayDate(calendarsEnabled: true) == "Sep 1752")
        #expect(summary(date: "1752", precision: .year, calendar: .hebrew)
                    .displayDate(calendarsEnabled: true) == "1752")
        // Before 1 Vendémiaire An I there is no French Republican day.
        #expect(summary(date: "1789-07-14", calendar: .frenchRepublican)
                    .displayDate(calendarsEnabled: true) == "Jul 14, 1789")
        #expect(summary(date: "1789-07-14", calendar: .standard)
                    .displayDate(calendarsEnabled: true) == "Jul 14, 1789")
        #expect(summary(date: "1789-07-14", calendar: nil).displayDate(calendarsEnabled: true) == "Jul 14, 1789")
    }

    // MARK: - Front-matter

    @Test("display_calendar round-trips through the codec; absent when as stored")
    func codecRoundTrip() throws {
        var item = bareItem()
        #expect(!FrontMatterCodec.encode(item).contains("display_calendar"))
        for cal in DisplayCalendar.allCases where cal != .standard {
            item.displayCalendar = cal
            let text = FrontMatterCodec.encode(item)
            #expect(text.contains("display_calendar: \(cal.rawValue)\n"))
            #expect(try FrontMatterCodec.decode(text).displayCalendar == cal)
        }
        item.displayCalendar = .standard
        #expect(!FrontMatterCodec.encode(item).contains("display_calendar"))
    }

    @Test("an unknown display_calendar value is kept verbatim, and a choice replaces it")
    func unknownValuePreserved() throws {
        let text = """
            ---
            schema: 1
            id: 3f2504e0-4f89-11d3-9a0c-0305e82c3301
            kind: note
            title: "x"
            display_calendar: mayan-long-count
            roundup: false
            ---

            """
        var item = try FrontMatterCodec.decode(text)
        #expect(item.displayCalendar == nil)
        #expect(FrontMatterCodec.encode(item).contains("display_calendar: mayan-long-count\n"))
        item.displayCalendar = .hebrew
        let replaced = FrontMatterCodec.encode(item)
        #expect(replaced.contains("display_calendar: hebrew\n"))
        #expect(!replaced.contains("mayan-long-count"))
    }

    // MARK: - The write path (scratch store)

    @Test("choosing a calendar leaves the stored date the same bytes, and persists the choice")
    func storedDateUnchanged() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try await makeNote(env)
        await env.model.setDate("1752-09-13", precision: .day, for: id)
        _ = await env.model.setSentWith("1752-09-01", precision: .day, for: id)
        let before = try fileBytes(env, id)

        for cal in DisplayCalendar.allCases where cal != .standard {
            #expect(await env.model.setDisplayCalendar(cal, for: id))
            let after = try fileBytes(env, id)
            #expect(dateLine(after) == dateLine(before))
            #expect(dateLine(after) == Data("date: \"1752-09-13\"".utf8) || dateLine(after) == Data("date: 1752-09-13".utf8))
            #expect(linesOtherThanTheChoice(after) == linesOtherThanTheChoice(before))
            let loaded = try await env.store.load(id)
            #expect(loaded.displayCalendar == cal)
            #expect(loaded.date == "1752-09-13" && loaded.datePrecision == .day)
            #expect(loaded.sentWith == ArchiveDate(year: 1752, month: 9, day: 1))
            #expect(await env.index.summary(for: id)?.displayCalendar == cal)
        }

        // Back to "as stored": no key on disk, and every other line as it was.
        #expect(await env.model.setDisplayCalendar(.standard, for: id))
        let cleared = try fileBytes(env, id)
        #expect(!String(decoding: cleared, as: UTF8.self).contains("display_calendar"))
        #expect(linesOtherThanTheChoice(cleared) == linesOtherThanTheChoice(before))
        #expect(try await env.store.load(id).displayCalendar == nil)
        #expect(await env.index.summary(for: id)?.displayCalendar == nil)
    }

    @Test("the index projection shows the chosen calendar")
    func indexProjectionDisplays() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try await makeNote(env)
        await env.model.setDate("1752-09-13", precision: .day, for: id)
        await env.model.setDisplayCalendar(.julianEnglish1752, for: id)
        let s = try #require(await env.index.summary(for: id))
        #expect(s.displayDate(calendarsEnabled: true) == "2 September 1752 (O.S.)")
        #expect(s.displayDate(calendarsEnabled: false) == "Sep 13, 1752")
    }

    // MARK: - Headless render

    /// Draws the detail header's date labels off-screen and reads the pixels back with Vision, so the
    /// claim is "the header draws a Julian date", not just "a function returns one".
    @Test("the detail header draws a date in a non-Gregorian calendar")
    func headerRendersCalendarDate() async throws {
        let s = summary(date: "1752-09-13", calendar: .julianEnglish1752)
        let view = HStack(spacing: 10) { ItemHeaderDates(item: s, calendarsEnabled: true) }
            .padding(12).background(Color.white).environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        let image = try #require(renderer.cgImage)
        #expect(image.width > 0 && image.height > 0)

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        #expect(text.contains("2 September 1752"), "OCR read: \(text)")
        #expect(!text.contains("Sep 13"), "OCR read: \(text)")
    }

    // MARK: - Helpers

    private func summary(date: String?, precision: Item.DatePrecision? = .day, calendar: DisplayCalendar?,
                         sentWith: ArchiveDate? = nil) -> ItemSummary {
        ItemSummary(id: UUID(), title: "t", kind: .note, date: date, datePrecision: precision,
                    dateUncertain: false, authors: [], sortDate: nil, quality: nil,
                    created: Date(), modified: Date(), mtime: 0, managedTags: [],
                    sentWith: sentWith, displayCalendar: calendar)
    }

    private func bareItem() -> Item {
        Item(id: UUID(), kind: .note, title: "t", authors: [], date: "1752-09-13", datePrecision: .day,
             dateUncertain: false, quality: nil, tags: [], zotero: [], roundup: false,
             created: Date(timeIntervalSince1970: 0), modified: Date(timeIntervalSince1970: 0), schema: 1,
             blocks: [], unknownFrontMatter: [], trailingBodyRaw: nil)
    }
}
