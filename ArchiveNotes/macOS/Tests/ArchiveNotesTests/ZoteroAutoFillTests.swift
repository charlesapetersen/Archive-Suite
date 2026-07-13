import Testing
import Foundation
@testable import ArchiveNotes

@Suite("Zotero auto-fill — CSL→front-matter mapping + confirmation view-model")
struct ZoteroAutoFillTests {

    // MARK: - Fixtures

    private func makeItem(
        title: String = "",
        authors: [String] = [],
        date: String? = nil,
        precision: Item.DatePrecision? = nil,
        dateUncertain: Bool = false,
        zotero: [ZoteroRef] = []
    ) -> Item {
        Item(
            id: UUID(),
            kind: .note,
            title: title,
            authors: authors,
            date: date,
            datePrecision: precision,
            dateUncertain: dateUncertain,
            quality: nil,
            tags: [],
            zotero: zotero,
            roundup: false,
            created: Date(timeIntervalSince1970: 0),
            modified: Date(timeIntervalSince1970: 0),
            schema: 1,
            blocks: [],
            unknownFrontMatter: [],
            trailingBodyRaw: nil
        )
    }

    private func csl(
        title: String? = nil,
        authors: [ZoteroCSLItem.CSLName]? = nil,
        dateParts: [[Int]]? = nil,
        raw: String? = nil
    ) -> ZoteroCSLItem {
        let issued = (dateParts != nil || raw != nil)
            ? ZoteroCSLItem.CSLDate(dateParts: dateParts, raw: raw)
            : nil
        return ZoteroCSLItem(type: nil, title: title, author: authors, issued: issued, itemType: nil)
    }

    private func ref(_ link: String = "zotero://select/library/items/ABCD1234") -> ZoteroRef {
        ZoteroRef(selectLink: link, itemKey: "ABCD1234", library: .user)
    }

    /// Records items handed to the injected store save (never touches disk).
    private actor SaveRecorder {
        private(set) var saved: [Item] = []
        func record(_ item: Item) { saved.append(item) }
        func snapshot() -> [Item] { saved }
    }

    // MARK: - Date precision from date-parts

    @Test("date-parts [y] → year precision")
    func dateYear() {
        let (date, precision) = csl(dateParts: [[2001]]).mappedDate()
        #expect(date == "2001")
        #expect(precision == .year)
    }

    @Test("date-parts [y,m] → month precision, zero-padded month")
    func dateMonth() {
        let (date, precision) = csl(dateParts: [[1936, 11]]).mappedDate()
        #expect(date == "1936-11")
        #expect(precision == .month)
    }

    @Test("date-parts [y,m,d] → day precision, zero-padded month+day")
    func dateDay() {
        let (date, precision) = csl(dateParts: [[1963, 8, 28]]).mappedDate()
        #expect(date == "1963-08-28")
        #expect(precision == .day)
    }

    @Test("3-digit medieval year survives verbatim (no zero-padding of the year)")
    func dateThreeDigitYear() {
        let (date, precision) = csl(dateParts: [[842]]).mappedDate()
        #expect(date == "842")
        #expect(precision == .year)
    }

    @Test("out-of-range month stops at year precision")
    func dateBadMonth() {
        let (date, precision) = csl(dateParts: [[2000, 13]]).mappedDate()
        #expect(date == "2000")
        #expect(precision == .year)
    }

    @Test("out-of-range day stops at month precision")
    func dateBadDay() {
        let (date, precision) = csl(dateParts: [[2000, 5, 40]]).mappedDate()
        #expect(date == "2000-05")
        #expect(precision == .month)
    }

    @Test("raw date fallback takes the first 4-digit run as year")
    func dateRawFallback() {
        let (date, precision) = csl(raw: "circa 1850").mappedDate()
        #expect(date == "1850")
        #expect(precision == .year)
    }

    @Test("no parseable date → (nil, nil), leaving the note untouched")
    func dateNone() {
        let (d1, p1) = csl().mappedDate()
        #expect(d1 == nil)
        #expect(p1 == nil)
        let (d2, p2) = csl(raw: "n.d.").mappedDate()
        #expect(d2 == nil)
        #expect(p2 == nil)
    }

    // CSL never emits a decade.
    @Test("decade is never emitted from Zotero (a 4-digit year is a year)")
    func neverDecade() {
        let (_, precision) = csl(dateParts: [[1970]]).mappedDate()
        #expect(precision == .year)
    }

    // MARK: - Author mapping

    @Test("given/family authors joined as 'given family'")
    func authorsGivenFamily() {
        let item = csl(authors: [.init(family: "Moore", given: "Gordon E.", literal: nil)])
        #expect(item.mappedAuthors == ["Gordon E. Moore"])
    }

    @Test("literal author preserved verbatim")
    func authorsLiteral() {
        let item = csl(authors: [.init(family: nil, given: nil, literal: "Martin Luther King Jr.")])
        #expect(item.mappedAuthors == ["Martin Luther King Jr."])
    }

    @Test("empty / whitespace-only author names are dropped and trimmed")
    func authorsDropEmpty() {
        let item = csl(authors: [
            .init(family: "Moore", given: "", literal: nil),   // → "Moore" (leading space trimmed)
            .init(family: nil, given: nil, literal: "   "),     // → dropped
            .init(family: "Noyce", given: "Robert", literal: nil),
        ])
        #expect(item.mappedAuthors == ["Moore", "Robert Noyce"])
    }

    // MARK: - Title mapping

    @Test("title trimmed; empty → nil")
    func titleMapping() {
        #expect(csl(title: "  Oral History  ").mappedTitle == "Oral History")
        #expect(csl(title: "   ").mappedTitle == nil)
        #expect(csl(title: nil).mappedTitle == nil)
    }

    // MARK: - AutoFillPlan.make

    @Test("empty note → every field is a fill (default-selected)")
    func planFillEmpty() {
        let item = makeItem()  // empty title/authors/date
        let plan = AutoFillPlan.make(
            from: csl(title: "Oral History",
                      authors: [.init(family: "Moore", given: "Gordon E.", literal: nil)],
                      dateParts: [[2001]]),
            item: item)
        #expect(plan.changes.count == 3)
        #expect(plan.changes.allSatisfy { $0.defaultSelected })
        #expect(plan.defaultSelection == Set(AutoFillField.allCases))
        #expect(plan.changes.allSatisfy { !$0.isReplacement })
    }

    @Test("non-empty note → replacements are NOT default-selected")
    func planReplaceNotDefault() {
        let item = makeItem(title: "My title", authors: ["Someone"], date: "1999", precision: .year)
        let plan = AutoFillPlan.make(
            from: csl(title: "Oral History",
                      authors: [.init(family: "Moore", given: "Gordon E.", literal: nil)],
                      dateParts: [[2001]]),
            item: item)
        #expect(plan.changes.count == 3)
        #expect(plan.changes.allSatisfy { $0.isReplacement })
        #expect(plan.defaultSelection.isEmpty)
        // Display strings show current vs proposed.
        let titleChange = plan.changes.first { $0.field == .title }
        #expect(titleChange?.currentDisplay == "My title")
        #expect(titleChange?.proposedDisplay == "Oral History")
    }

    @Test("identical proposed values are not offered as changes")
    func planNoOpFields() {
        let item = makeItem(title: "Oral History", authors: ["Gordon E. Moore"], date: "2001", precision: .year)
        let plan = AutoFillPlan.make(
            from: csl(title: "Oral History",
                      authors: [.init(family: "Moore", given: "Gordon E.", literal: nil)],
                      dateParts: [[2001]]),
            item: item)
        #expect(plan.isEmpty)
        #expect(plan.defaultSelection.isEmpty)
    }

    // MARK: - AutoFillPlan.apply

    @Test("apply writes only selected fields; date carries its precision")
    func planApplySelected() {
        let item = makeItem()
        let plan = AutoFillPlan.make(
            from: csl(title: "Oral History",
                      authors: [.init(family: "Moore", given: "Gordon E.", literal: nil)],
                      dateParts: [[2001, 3]]),
            item: item)
        let out = plan.apply(selected: [.title, .date], to: item)
        #expect(out.title == "Oral History")
        #expect(out.authors == [])           // not selected → untouched
        #expect(out.date == "2001-03")
        #expect(out.datePrecision == .month)
    }

    @Test("apply with empty selection is a no-op copy")
    func planApplyNothing() {
        let item = makeItem(title: "Keep", authors: ["Keep A"])
        let plan = AutoFillPlan.make(from: csl(title: "New", dateParts: [[2001]]), item: item)
        let out = plan.apply(selected: [], to: item)
        #expect(out.title == "Keep")
        #expect(out.authors == ["Keep A"])
        #expect(out.date == nil)
    }

    // MARK: - View-model: confirm / cancel

    @Test("fill-empty: confirm writes the filled item once and stamps citation/fetchedAt")
    @MainActor
    func modelConfirmFillEmpty() async throws {
        let link = "zotero://select/library/items/ABCD1234"
        let item = makeItem(zotero: [ref(link)])
        let recorder = SaveRecorder()
        let when = Date(timeIntervalSince1970: 1_000)

        let model = ZoteroAutoFillModel(
            item: item,
            csl: csl(title: "Oral History",
                     authors: [.init(family: "Moore", given: "Gordon E.", literal: nil)],
                     dateParts: [[2001]]),
            refSelectLink: link,
            citation: "Moore, Gordon E. Oral History. 2001.",
            fetchedAt: when,
            save: { saved in await recorder.record(saved) })

        // Default selection fills all three empty fields.
        #expect(model.selected == Set(AutoFillField.allCases))

        try await model.confirm()
        #expect(model.didCommit)

        let saved = await recorder.snapshot()
        #expect(saved.count == 1)
        let out = try #require(saved.first)
        #expect(out.title == "Oral History")
        #expect(out.authors == ["Gordon E. Moore"])
        #expect(out.date == "2001")
        #expect(out.datePrecision == .year)
        // The matching ref is stamped with citation + fetchedAt (the durable survivor).
        #expect(out.zotero.first?.citation == "Moore, Gordon E. Oral History. 2001.")
        #expect(out.zotero.first?.fetchedAt == when)
    }

    @Test("replace-with-confirm: replacement applies only after the user selects it")
    @MainActor
    func modelReplaceWithConfirm() async throws {
        let link = "zotero://select/library/items/ABCD1234"
        let item = makeItem(title: "Old Title", zotero: [ref(link)])
        let recorder = SaveRecorder()

        let model = ZoteroAutoFillModel(
            item: item,
            csl: csl(title: "New Title"),
            refSelectLink: link,
            fetchedAt: Date(timeIntervalSince1970: 0),
            save: { saved in await recorder.record(saved) })

        // Title is a replacement → not selected by default.
        #expect(model.selected.isEmpty)
        #expect(model.resolvedItem.title == "Old Title")

        // User opts in.
        model.toggle(.title)
        #expect(model.resolvedItem.title == "New Title")

        try await model.confirm()
        let saved = await recorder.snapshot()
        #expect(saved.first?.title == "New Title")
    }

    @Test("no-op on cancel: nothing is written")
    @MainActor
    func modelCancelWritesNothing() async {
        let link = "zotero://select/library/items/ABCD1234"
        let item = makeItem(zotero: [ref(link)])
        let recorder = SaveRecorder()

        let model = ZoteroAutoFillModel(
            item: item,
            csl: csl(title: "Oral History", dateParts: [[2001]]),
            refSelectLink: link,
            save: { saved in await recorder.record(saved) })

        model.cancel()
        let saved = await recorder.snapshot()
        #expect(saved.isEmpty)
        #expect(!model.didCommit)
    }

    @Test("only the matching ref is stamped; other attached refs are untouched")
    @MainActor
    func modelStampsOnlyMatchingRef() async throws {
        let target = "zotero://select/library/items/ABCD1234"
        let other = "zotero://select/library/items/WXYZ5678"
        let item = makeItem(zotero: [
            ref(target),
            ZoteroRef(selectLink: other, itemKey: "WXYZ5678", library: .user),
        ])
        let recorder = SaveRecorder()
        let when = Date(timeIntervalSince1970: 42)

        let model = ZoteroAutoFillModel(
            item: item,
            csl: csl(title: "Oral History"),
            refSelectLink: target,
            citation: "A citation.",
            fetchedAt: when,
            save: { saved in await recorder.record(saved) })

        try await model.confirm()
        let out = try #require(await recorder.snapshot().first)
        let stamped = out.zotero.first { $0.selectLink == target }
        let untouched = out.zotero.first { $0.selectLink == other }
        #expect(stamped?.citation == "A citation.")
        #expect(stamped?.fetchedAt == when)
        #expect(untouched?.citation == nil)
        #expect(untouched?.fetchedAt == nil)
    }

    // MARK: - Degrade (W5-S5): a failed citation fetch must not erase a stored citation

    @Test("fetch failure (no new citation) leaves the ref's existing citation intact")
    @MainActor
    func modelPreservesExistingCitationWhenFetchFails() async throws {
        let link = "zotero://select/library/items/ABCD1234"
        // A prior successful fetch already stored a citation on the ref (the durable survivor, §5).
        var existing = ref(link)
        existing.citation = "Previously fetched citation."
        existing.fetchedAt = Date(timeIntervalSince1970: 10)
        let item = makeItem(zotero: [existing])   // empty title → the title fill is default-selected
        let recorder = SaveRecorder()
        let when = Date(timeIntervalSince1970: 2_000)

        // citation: nil = the citation fetch failed this time (offline / style error), even though
        // CSL metadata for author/date/title came through.
        let model = ZoteroAutoFillModel(
            item: item,
            csl: csl(title: "Oral History"),
            refSelectLink: link,
            citation: nil,
            fetchedAt: when,
            save: { saved in await recorder.record(saved) })

        try await model.confirm()

        let out = try #require(await recorder.snapshot().first)
        let stamped = out.zotero.first { $0.selectLink == link }
        #expect(stamped?.citation == "Previously fetched citation.")  // intact, not wiped
        #expect(stamped?.fetchedAt == when)                            // fetch attempt still stamped
        #expect(out.title == "Oral History")                           // the fill still applied
    }
}
