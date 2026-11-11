import Testing
import Foundation
import ArchiveCore
@testable import ArchiveNotes

/// W40.notes-advanced-search — the rule tree in memory (every field and operator, groups, inactive rows), the
/// filter-bar conversion against `NotesFilter.matches`, the text rules against a real FTS5 index, and the model
/// end to end: an unsaved search as the scope, the filter bar on top, save, edit in place, counts.
@MainActor
struct NotesAdvancedSearchTests {

    // MARK: Helpers

    private func item(_ title: String, kind: Item.Kind = .note, quality: Int? = nil, sortDate: Int? = nil,
                      date: String? = nil, precision: Item.DatePrecision? = nil,
                      tags: [String] = [], uncertain: Bool = false, roundup: Bool = false,
                      sentWith: ArchiveDate? = nil, id: UUID = UUID()) -> ItemSummary {
        let t = Date(timeIntervalSince1970: 0)
        return ItemSummary(id: id, title: title, kind: kind, date: date, datePrecision: precision,
                           dateUncertain: uncertain, sortDate: sortDate, quality: quality,
                           created: t, modified: t, mtime: 0, managedTags: tags, roundup: roundup,
                           sentWith: sentWith)
    }

    private func rule(_ field: NotesRuleField, _ op: RuleOperator? = nil,
                      _ edit: (inout NotesSearchRule) -> Void = { _ in }) -> NotesSearchRule {
        var r = NotesSearchRule(field: field, op: op); edit(&r); return r
    }

    private func search(_ combine: RuleCombine, _ rules: NotesSearchRule...) -> NotesAdvancedSearch {
        NotesAdvancedSearch(combine: combine, rules: rules)
    }

    private func hit(_ s: NotesAdvancedSearch, _ i: ItemSummary, _ c: NotesRuleContext = .init()) -> Bool {
        s.matches(i, c)
    }

    // MARK: In memory

    @Test func starterRowsAndInactiveRowsMatchEverything() {
        let a = item("Anything")
        #expect(!NotesAdvancedSearch.starter.isActive)
        #expect(hit(.starter, a))
        #expect(hit(search(.any, rule(.title), rule(.tags)), a), "an any of inactive rows is not a no-match")
        #expect(!rule(.date) { $0.text = "not a date" }.isActive)
    }

    @Test func titleOperators() {
        let a = item("Moore on Intel culture")
        func title(_ op: RuleOperator, _ t: String) -> Bool { hit(search(.all, rule(.title, op) { $0.text = t }), a) }
        #expect(title(.contains, "intel"))
        #expect(!title(.doesNotContain, "INTEL"))
        #expect(title(.beginsWith, "moore"))
        #expect(!title(.beginsWith, "intel"))
        #expect(title(.endsWith, "Culture"))
        // Notes have no authors (W40.notes-remove-authors): there is no Authors rule to offer.
        #expect(NotesRuleField(rawValue: "authors") == nil)
    }

    @Test func tagOperatorsIgnoreCase() {
        let a = item("a", tags: ["intel", "corporate culture"])
        func tags(_ op: RuleOperator, _ t: String) -> Bool { hit(search(.all, rule(.tags, op) { $0.text = t }), a) }
        #expect(tags(.hasAll, "Intel, corporate culture"))
        #expect(!tags(.hasAll, "intel, meritocracy"))
        #expect(tags(.hasAny, "meritocracy, INTEL"))
        #expect(!tags(.hasAny, "meritocracy"))
        #expect(tags(.hasNone, "meritocracy"))
        #expect(!tags(.hasNone, "meritocracy, intel"))
        #expect(rule(.tags) { $0.text = " a ,, b , " }.tagList == ["a", "b"])
    }

    @Test func kindQualityRoundupAndUncertainDate() {
        let note = item("n", quality: 3, uncertain: true, roundup: true)
        let extract = item("e", kind: .extract)
        let isExtract = search(.all, rule(.kind) { $0.kind = .extract })
        #expect(hit(isExtract, extract) && !hit(isExtract, note))
        let notExtract = search(.all, rule(.kind, .isNot) { $0.kind = .extract })
        #expect(hit(notExtract, note) && !hit(notExtract, extract))
        let q3 = search(.all, rule(.quality) { $0.qualities = [3] })
        #expect(hit(q3, note) && !hit(q3, extract))
        let noQuality = search(.all, rule(.quality) { $0.qualities = [0] })
        #expect(hit(noQuality, extract) && !hit(noQuality, note))
        let notQ3 = search(.all, rule(.quality, .isNot) { $0.qualities = [3] })
        #expect(hit(notQ3, extract) && !hit(notQ3, note))
        #expect(hit(search(.all, rule(.roundup)), note) && !hit(search(.all, rule(.roundup)), extract))
        #expect(hit(search(.all, rule(.roundup, .isNot)), extract))
        #expect(hit(search(.all, rule(.uncertainDate)), note) && !hit(search(.all, rule(.uncertainDate)), extract))
        let sentUncertain: ItemSummary = { var i = item("s"); i.sentWithUncertain = true; return i }()
        #expect(hit(search(.all, rule(.uncertainDate)), sentUncertain))
    }

    @Test func datesByPrecisionAndRole() throws {
        let own1968 = item("own", sortDate: 19680315)
        let sent1970 = item("sent", sortDate: 19500000, date: "1950", precision: .year,
                            sentWith: ArchiveDate(year: 1970, month: 6))
        #expect(sent1970.dateKeysByRole == [.own: 19500000, .sentWith: 19700600])
        let undated = item("undated")
        func date(_ i: ItemSummary, _ op: RuleOperator, _ a: String, _ b: String = "",
                  role: DateRoleChoice = .either) -> Bool {
            hit(search(.all, rule(.date, op) { $0.text = a; $0.text2 = b; $0.dateRole = role }), i)
        }
        #expect(date(own1968, .between, "1960s", ""))
        #expect(date(own1968, .between, "1968", "1968"))
        #expect(date(own1968, .between, "1968-03", "1968-03"))
        #expect(!date(own1968, .between, "1968-04", "1969"))
        #expect(date(own1968, .after, "1968-03-15"))
        #expect(!date(own1968, .after, "1968-03-16"))
        #expect(date(own1968, .before, "1968"))
        #expect(!date(undated, .between, "1968", "1968"), "a bounded date rule leaves undated items out")
        #expect(date(undated, .undated, "") && !date(own1968, .undated, ""))
        // Either date by default; one role when asked. Both bounds hold for the same value.
        #expect(date(sent1970, .between, "1970", "1970"))
        #expect(!date(sent1970, .between, "1970", "1970", role: .own))
        #expect(date(sent1970, .between, "1970", "1970", role: .sentWith))
        #expect(!date(sent1970, .between, "1960", "1965"), "own 1950 and sent 1970 are each outside 1960–65")
        #expect(date(sent1970, .between, "1950", "1950", role: .own))
        #expect(date(own1968, .undated, "", role: .sentWith))
    }

    @Test func foldersAndGroups() {
        let folder = UUID()
        let inside = item("inside"), outside = item("outside", quality: 2)
        let context = NotesRuleContext(folderItems: [folder: [inside.id]])
        let inFolder = NotesAdvancedSearch.folderScope(folder)
        #expect(inFolder.plainFolderScope == folder)
        #expect(hit(inFolder, inside, context) && !hit(inFolder, outside, context))
        #expect(!hit(inFolder, inside), "a folder missing from the context holds nothing")
        let notIn = search(.all, rule(.folder, .isNot) { $0.folderId = folder })
        #expect(hit(notIn, outside, context) && !hit(notIn, inside, context))
        // all of [title contains "side", any of [in folder, quality 2]]
        let tree = search(.all, rule(.title) { $0.text = "side" },
                          .group(.any, [.folder(folder), rule(.quality) { $0.qualities = [2] }]))
        #expect(hit(tree, inside, context) && hit(tree, outside, context))
        #expect(!hit(tree, item("elsewhere"), context))
        #expect(tree.folderIDs == [folder])
    }

    @Test func filterBarConversionMatchesTheFilterRowForRow() throws {
        let folder = UUID()
        let items = [
            item("War letters", quality: 3, sortDate: 19440000, tags: ["war", "letters"]),
            item("Peace times", kind: .extract, quality: 1, sortDate: 19500615, tags: ["peace"]),
            item("Round-up", quality: nil, sortDate: nil, tags: ["war"], roundup: true),
            item("Sent later", sortDate: 19300000, sentWith: ArchiveDate(year: 1946)),
        ]
        let folderItems: Set<UUID> = [items[0].id, items[2].id]
        var filters: [NotesFilter] = [NotesFilter()]
        var f = NotesFilter(); f.kind = .notes; filters.append(f)
        f = NotesFilter(); f.tags = ["war", "letters"]; filters.append(f)
        f = NotesFilter(); f.tags = ["peace", "letters"]; f.tagCombine = .any; filters.append(f)
        f = NotesFilter(); f.qualities = [1, 3]; filters.append(f)
        f = NotesFilter(); f.dateFrom = 19440000; f.dateTo = 19461231; filters.append(f)
        f = NotesFilter(); f.dateFrom = 19450000; filters.append(f)
        f = NotesFilter(); f.dateTo = 19441231; filters.append(f)
        f = NotesFilter(); f.roundup = false; filters.append(f)
        f = NotesFilter(); f.roundup = true; filters.append(f)
        f = NotesFilter(); f.searchText = "TIMES"; filters.append(f)
        f = NotesFilter(); f.folderId = folder; f.kind = .notes; filters.append(f)
        for filter in filters {
            let s = NotesAdvancedSearch(filter: filter, keyword: "")
            let context = NotesRuleContext(folderItems: [folder: folderItems])
            for i in items {
                #expect(s.matches(i, context) == filter.matches(i, folderItemIDs: folderItems),
                        "\(filter) on \(i.title)")
            }
        }
        // The kind control can be left out (the form keeps it on the window).
        var notes = NotesFilter(); notes.kind = .notes
        #expect(!NotesAdvancedSearch(filter: notes, keyword: "", includingKind: false).isActive)
        // The search box becomes a full-text rule, last word a prefix past two characters.
        let kw = NotesAdvancedSearch(filter: NotesFilter(), keyword: "budget defic")
        #expect(kw.rules.map(\.text) == ["budget defic*"])
        #expect(NotesAdvancedSearch(filter: NotesFilter(), keyword: "to be").rules.map(\.text) == ["to be"])
        #expect(NotesAdvancedSearch(filter: NotesFilter(), keyword: "budg* memo").rules.map(\.text) == ["budg memo*"])
    }

    @Test func narrowingAndLenientDecode() throws {
        let anyOf = search(.any, rule(.title) { $0.text = "a" }, rule(.title) { $0.text = "b" })
        let more = search(.all, rule(.quality) { $0.qualities = [3] })
        let n = anyOf.narrowed(by: more)
        #expect(n.combine == .all && n.rules.count == 2 && n.rules[0].field == .group)
        #expect(hit(n, item("a", quality: 3)) && !hit(n, item("a", quality: 2)) && !hit(n, item("c", quality: 3)))
        #expect(NotesAdvancedSearch().narrowed(by: more) == more)
        #expect(more.narrowed(by: NotesAdvancedSearch()) == more)
        // A rule with only its field still loads; an unknown field does not.
        #expect(try JSONDecoder().decode(NotesAdvancedSearch.self, from: Data("{}".utf8)) == NotesAdvancedSearch())
        let json = #"{"combine":"any","rules":[{"field":"tags"},{"field":"date","op":"undated"}]}"#
        let decoded = try JSONDecoder().decode(NotesAdvancedSearch.self, from: Data(json.utf8))
        #expect(decoded.combine == .any && decoded.rules[0].op == .hasAll && decoded.rules[1].op == .undated)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(NotesAdvancedSearch.self,
                                     from: Data(#"{"combine":"all","rules":[{"field":"nope"}]}"#.utf8))
        }
        let round = try JSONDecoder().decode(NotesAdvancedSearch.self, from: JSONEncoder().encode(n))
        #expect(round == n)
    }

    // MARK: The index

    private func makeModel() async throws -> (NotesModel, NotesIndex, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-advanced-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = NotesIndex(url: root.appendingPathComponent("index.db"))
        try await index.open()
        let store = OrganizationStore(index: index)
        try await store.load(storeRoot: root)
        return (NotesModel(organization: store, index: index), index, root)
    }

    private func cleanup(_ root: URL, _ index: NotesIndex) async {
        await index.close(); try? FileManager.default.removeItem(at: root)
    }

    private func row(_ id: UUID, title: String, body: String, tags: String = "") -> NoteIndexRow {
        let t = Date(timeIntervalSince1970: 0)
        return NoteIndexRow(id: id, mtime: 0, title: title, kind: .note, tags: tags,
                            body: body, date: nil, datePrecision: nil,
                            dateUncertain: false, sortDate: nil, quality: nil, created: t,
                            modified: t, managedTags: "[]", sourceCount: 0)
    }

    /// Three notes: "Budget memo" (body: balanced budget, deficit), "Deficit hawks" (body: Stockman), and
    /// "Lunch" (body: nothing fiscal, tagged budget).
    private func seed(_ model: NotesModel, _ index: NotesIndex) async throws -> (UUID, UUID, UUID) {
        let a = UUID(), b = UUID(), c = UUID()
        try await index.upsertBatch([
            row(a, title: "Budget memo", body: "The balanced budget and the deficit."),
            row(b, title: "Deficit hawks", body: "Stockman argued with Darman about newspaper leaks."),
            row(c, title: "Lunch", body: "Sandwiches.", tags: "budget"),
        ])
        model.replaceItems([item("Budget memo", id: a), item("Deficit hawks", id: b),
                            item("Lunch", id: c)])
        return (a, b, c)
    }

    private func hits(_ model: NotesModel, _ field: NotesRuleField, _ op: RuleOperator, _ text: String) async
        -> Set<UUID> {
        let r = rule(field, op) { $0.text = text }
        return await model.textHits(for: search(.all, r))[r.id] ?? []
    }

    @Test func textRulesAgainstARealIndex() async throws {
        let (model, index, root) = try await makeModel()
        defer { Task { await cleanup(root, index) } }
        let (a, b, c) = try await seed(model, index)
        #expect(await hits(model, .text, .allWords, "budget") == [a, c], "any text: title, tags and body")
        #expect(await hits(model, .noteText, .allWords, "budget") == [a], "note text: the body alone")
        #expect(await hits(model, .text, .phrase, "\"balanced budget\"") == [a])
        #expect(await hits(model, .text, .phrase, "budget balanced") == [])
        #expect(await hits(model, .text, .anyWords, "Stockman sandwiches") == [b, c])
        #expect(await hits(model, .text, .allWords, "news*") == [b])
        #expect(await hits(model, .text, .allWords, "news") == [])
        // No typed text is FTS5 syntax.
        #expect(await hits(model, .text, .allWords, "NOT budget") == [])
        #expect(await hits(model, .text, .allWords, "title:budget") == [])
        // "none of" excludes what its words find.
        let none = rule(.text, .noWords) { $0.text = "deficit" }
        let s = search(.all, none)
        let context = NotesRuleContext(textHits: await model.textHits(for: s))
        #expect(model.allItems.filter { s.matches($0, context) }.map(\.id) == [c])
    }

    // MARK: The model end to end

    @Test func unsavedSearchIsTheScopeAndTheFilterBarLayersOnTop() async throws {
        let (model, index, root) = try await makeModel()
        defer { Task { await cleanup(root, index) } }
        let (a, _, c) = try await seed(model, index)
        let nav = NotesNavigationModel(model: model, defaultKind: .note)
        nav.filter.kind = .all
        let budget = search(.all, rule(.text) { $0.text = "budget" })
        nav.runAdvancedSearch(budget)
        #expect(model.scopeIsUnsavedSearch)
        await nav.waitForScopeTextHits()
        #expect(Set(nav.displayed.map(\.id)) == [a, c])
        nav.filter.qualities = [3]                         // the filter bar narrows on top
        #expect(nav.displayed.isEmpty)
        nav.clearUserFilters()                             // Clear returns to the search
        nav.filter.kind = .all
        #expect(Set(nav.displayed.map(\.id)) == [a, c])
        // The form opens on what the list shows.
        nav.openAdvancedSearch()
        #expect(nav.advancedSearchRequest?.search == budget)
        model.setAllNotesScope()
        #expect(!model.scopeIsUnsavedSearch && nav.displayed.count == 3)
        nav.openAdvancedSearch()
        #expect(nav.advancedSearchRequest?.search.rules.map(\.field) == [.text, .tags, .date], "starter rows")
    }

    /// W40.fix-notes-clear-all-advanced (owner, notes-2 row 26): Clear All leaves an unsaved Advanced Search too,
    /// and the In effect row shows it, with every other filter, each removable alone.
    @Test func clearAllLeavesTheAdvancedSearchAndTheChipsSayWhatIsInEffect() async throws {
        let (model, index, root) = try await makeModel()
        defer { Task { await cleanup(root, index) } }
        let (a, _, c) = try await seed(model, index)
        let nav = NotesNavigationModel(model: model, defaultKind: .note)
        nav.filter.kind = .all
        #expect(nav.activeFilterChips.isEmpty && !nav.canClearAll, "the kind control alone is no chip")

        nav.runAdvancedSearch(search(.all, rule(.text) { $0.text = "budget" }, rule(.tags)))
        await nav.waitForScopeTextHits()
        #expect(nav.canClearAll, "an Advanced Search alone is something to clear")
        #expect(nav.activeFilterChips.map(\.label) == ["Advanced Search: 1 rule"], "the empty tags row is no rule")

        nav.filter.qualities = [3, 1]
        nav.filter.tags = ["zeta", "alpha"]
        nav.filter.dateFrom = 19500000
        nav.filter.dateTo = 19601231
        nav.filter.roundup = true
        nav.searchText = "deficit"
        #expect(nav.activeFilterChips.map(\.label) == [
            "Advanced Search: 1 rule", "\u{2605}3", "\u{2605}1", "Tag: alpha", "Tag: zeta", "Years: 1950\u{2013}1960",
            "Round-up notes", "Search: \u{201c}deficit\u{201d}"])

        // One chip's ✕ removes that one alone.
        nav.removeFilter(.tag("zeta"))
        #expect(nav.filter.tags == ["alpha"])
        nav.removeFilter(.dates)
        #expect(nav.filter.dateFrom == nil && nav.filter.dateTo == nil && nav.filter.roundup == true)
        nav.removeFilter(.keyword)
        #expect(nav.searchText.isEmpty && model.scopeIsUnsavedSearch)

        // Clear All clears the filter bar and the Advanced Search, keeping the kind.
        nav.clearAll()
        #expect(!model.scopeIsUnsavedSearch && model.scope == nil)
        #expect(nav.activeFilterChips.isEmpty && !nav.canClearAll && nav.filter.kind == .all)
        #expect(nav.displayed.count == 3)

        // The Advanced Search chip's ✕ shows all notes again, leaving the filter bar.
        nav.runAdvancedSearch(search(.all, rule(.text) { $0.text = "budget" }))
        await nav.waitForScopeTextHits()
        #expect(Set(nav.displayed.map(\.id)) == [a, c])
        nav.filter.roundup = false
        nav.removeFilter(.advancedSearch)
        #expect(model.scope == nil && nav.filter.roundup == false)
        #expect(nav.activeFilterChips.map(\.facet) == [.roundup])

        // A smart folder is where the list looks: a chip, but Clear All keeps it, as in the Reader.
        nav.clearAll()
        let smart = try #require(await model.createSmartFolder(
            name: "Budgets", query: search(.all, rule(.text) { $0.text = "budget" })))
        model.applySmartScope(smart)
        nav.filter.qualities = [2]
        #expect(nav.activeFilterChips.map(\.label) == ["Smart folder: Budgets", "\u{2605}2"])
        nav.clearAll()
        #expect(model.selectedSmartId == smart && nav.activeFilterChips.map(\.facet) == [.smartFolder])
        #expect(!nav.canClearAll)
        nav.removeFilter(.smartFolder)
        #expect(model.scope == nil && nav.activeFilterChips.isEmpty)
    }

    @Test func yearSummaryAndAnyTags() {
        var f = NotesFilter()
        #expect(f.dateYearsSummary == nil)
        f.dateFrom = 19500000
        #expect(f.dateYearsSummary == "from 1950")
        f.dateTo = 19501231
        #expect(f.dateYearsSummary == "1950")
        f.dateFrom = nil
        #expect(f.dateYearsSummary == "to 1950")
        f.tags = ["b", "a"]
        f.tagCombine = .any
        let chips = NotesActiveFilterChip.chips(filter: f, keyword: " ", advancedSearch: nil, smartFolderName: nil)
        #expect(chips.map(\.label) == ["Tag (any): a", "Tag (any): b", "Years: to 1950"])
        #expect(chips.first?.accessibilityIdentifier == "an.filter.chip.tag.a")
    }

    @Test func saveEditAndCount() async throws {
        let (model, index, root) = try await makeModel()
        defer { Task { await cleanup(root, index) } }
        let (a, b, c) = try await seed(model, index)
        let nav = NotesNavigationModel(model: model, defaultKind: .note)
        nav.filter.kind = .all
        let deficit = search(.all, rule(.noteText) { $0.text = "deficit" })
        #expect(await nav.countMatches(deficit) == 1)
        await nav.saveAdvancedSearch(deficit, name: "Deficits")
        let smart = try #require(model.organization.folders.first { $0.kind == .smart && $0.name == "Deficits" })
        #expect(model.selectedSmartId == smart.id && !model.scopeIsUnsavedSearch)
        await nav.waitForScopeTextHits()
        #expect(nav.displayed.map(\.id) == [a])
        #expect(model.smartQuery(smart.id) == deficit)

        // Edit in place: the open scope follows.
        nav.editSmartFolder(smart.id)
        #expect(nav.advancedSearchRequest?.editingId == smart.id)
        #expect(nav.advancedSearchRequest?.search == deficit)
        let either = search(.any, rule(.text) { $0.text = "deficit" }, rule(.title) { $0.text = "lunch" })
        await nav.updateSmartFolder(smart.id, search: either)
        #expect(model.smartQuery(smart.id) == either)
        await nav.waitForScopeTextHits()
        #expect(Set(nav.displayed.map(\.id)) == [a, b, c])

        // Counts: a smart folder of in-memory rules has one; one with text rules has none.
        let titled = try #require(await model.createSmartFolder(
            name: "Lunches", query: search(.all, rule(.title) { $0.text = "lunch" })))
        await model.waitForSmartFolderCounts()
        #expect(model.smartFolderCounts[titled] == 1)
        #expect(model.smartFolderCounts[smart.id] == nil)

        // The filter bar's Save keeps the search box as a text rule, so the folder finds what the list showed.
        model.setAllNotesScope()
        nav.searchText = "stock"
        await nav.runSearchAwaitingResult()
        #expect(nav.displayed.map(\.id) == [b])
        await nav.saveAsSmartFolder(named: "Stock")
        let stock = try #require(model.organization.folders.first { $0.name == "Stock" })
        nav.clearUserFilters()
        nav.filter.kind = .all
        model.applySmartScope(stock.id)
        await nav.waitForScopeTextHits()
        #expect(nav.displayed.map(\.id) == [b])
    }

    @Test func aRelaunchKeepsTheRules() async throws {
        let (model, index, root) = try await makeModel()
        defer { Task { await cleanup(root, index) } }
        let s = search(.any, rule(.tags, .hasNone) { $0.text = "x" },
                       .group(.all, [rule(.date, .after) { $0.text = "1981-06"; $0.dateRole = .sentWith }]))
        let id = try #require(await model.createSmartFolder(name: "Kept", query: s))
        let reloaded = OrganizationStore(index: index)
        try await reloaded.load(storeRoot: root)
        let json = reloaded.folders.first { $0.id == id }?.queryJSON
        #expect(NotesModel.decodeSmartQuery(json) == s)
    }
}
