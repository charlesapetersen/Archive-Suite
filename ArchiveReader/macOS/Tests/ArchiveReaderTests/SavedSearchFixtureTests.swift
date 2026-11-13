import XCTest
import SwiftUI
import ArchiveCore
@testable import ArchiveReader

// W40.reader-smart-folders-keep. The owner's Smart Folders live in UserDefaults, and the store drops an entry this
// build cannot decode, so a saved-shape change that is not decode-compatible would lose them. Each
// `Fixtures/saved-searches-<yyyy-mm>.json` is the store's bytes as one build wrote them, committed once and NEVER
// regenerated. A change to `SavedSearch`, `AdvancedSearch`, `SearchRule` or their enums keeps every fixture loading
// or ships a migration in the same commit. A new format adds a new fixture (and its builder) beside the old ones.

/// The smart folders behind each fixture, frozen like the fixture: never edit a builder once its file is committed.
enum SavedSearchFixtures {
    /// Fixed ids, so the fixture and the builder agree.
    private static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }

    private static func rule(_ n: Int, _ field: RuleField, _ op: RuleOperator,
                             _ fill: (inout SearchRule) -> Void = { _ in }) -> SearchRule {
        var r = SearchRule(field: field, op: op)
        r.id = id(n)
        r.dateRole = .either   // the 2026-11 default, frozen here; new rows default to .own since W40.suite-date-design
        fill(&r)
        return r
    }

    /// Every rule kind, field and operator the Advanced Search form offered in November 2026, nested groups and
    /// full-text rules included, written by the store as of W40.reader-smart-folders-keep.
    static var november2026: [SavedSearch] {
        var n = 100
        func next() -> Int { n += 1; return n }

        // One row for every field and each operator it offers, each with a value of its own.
        var everyOperator: [SearchRule] = []
        for op in RuleField.text.operators {
            everyOperator.append(rule(next(), .text, op) { $0.text = "budget \"Prop 13\" défi*" })
        }
        for op in RuleField.ocrText.operators {
            everyOperator.append(rule(next(), .ocrText, op) { $0.text = "Jerry Brown" })
        }
        for op in RuleField.fileName.operators {
            everyOperator.append(rule(next(), .fileName, op) { $0.text = "Box 3 – memo" })
        }
        for op in RuleField.tags.operators {
            everyOperator.append(rule(next(), .tags, op) { $0.tags = ["Cold War", "Économie", "Press"] })
        }
        for op in RuleField.quality.operators {
            everyOperator.append(rule(next(), .quality, op) { $0.qualities = [0, 2, 5] })
        }
        for op in RuleField.readState.operators {
            for read in ReadFilter.allCases {
                everyOperator.append(rule(next(), .readState, op) { $0.read = read })
            }
        }
        for op in RuleField.folder.operators {
            everyOperator.append(rule(next(), .folder, op) { $0.text = "/Archive/Brown Papers/Box 12/" })
        }
        for field in [RuleField.needsAttention, .ambiguousDate, .flagged] {
            for op in field.operators { everyOperator.append(rule(next(), field, op)) }
        }

        // Dates: every operator, every role, and each kind of value the box takes (year, month, day, decade).
        var dates: [SearchRule] = []
        let values = [("1975", "1980"), ("1975-03", "1976-11"), ("1975-03-14", "1975-12-31"), ("1970s", "1990s")]
        for role in DateRoleChoice.allCases {
            for (from, to) in values {
                dates.append(rule(next(), .date, .between) { $0.text = from; $0.text2 = to; $0.dateRole = role })
                dates.append(rule(next(), .date, .after) { $0.text = from; $0.dateRole = role })
                dates.append(rule(next(), .date, .before) { $0.text = to; $0.dateRole = role })
            }
            dates.append(rule(next(), .date, .undated) { $0.dateRole = role })
        }

        // Groups: "any" inside "all", a group inside a group, and an empty group.
        var inner = rule(next(), .group, .is) { $0.combine = .all }
        inner.children = [rule(next(), .ocrText, .phrase) { $0.text = "balanced budget" },
                          rule(next(), .quality, .isNot) { $0.qualities = [1] }]
        var outer = rule(next(), .group, .is) { $0.combine = .any }
        outer.children = [rule(next(), .tags, .hasAny) { $0.tags = ["Reagan"] }, inner,
                          rule(next(), .date, .between) { $0.text = "1981"; $0.text2 = "1989"; $0.dateRole = .own }]
        let emptyGroup = rule(next(), .group, .is) { $0.combine = .any }

        // As the form leaves a row: a field picked and no value yet.
        let unfilled = [rule(next(), .ocrText, .allWords), rule(next(), .tags, .hasAll),
                        rule(next(), .date, .between)]

        return [
            SavedSearch(id: id(1), name: "Every operator",
                        search: AdvancedSearch(combine: .all, rules: everyOperator)),
            SavedSearch(id: id(2), name: "Every date", search: AdvancedSearch(combine: .any, rules: dates)),
            SavedSearch(id: id(3), name: "Nested groups",
                        search: AdvancedSearch(combine: .all, rules: [
                            rule(next(), .text, .allWords) { $0.text = "deficit" }, outer, emptyGroup,
                            rule(next(), .folder, .is) { $0.text = "/Archive/Brown Papers" },
                        ])),
            SavedSearch(id: id(4), name: "Starter rows, unfilled",
                        search: AdvancedSearch(combine: .all, rules: unfilled)),
            SavedSearch(id: id(5), name: "No rules", search: AdvancedSearch()),
            SavedSearch(id: id(6), name: "Proposition 13 — “taxes” ✓",
                        search: AdvancedSearch(combine: .any, rules: [
                            rule(next(), .ocrText, .allWords) { $0.text = "proposition 13" },
                            rule(next(), .fileName, .contains) { $0.text = "prop13" },
                        ])),
        ]
    }

    /// The newest builder; the coverage test holds it to everything the form offers today.
    static var newest: [SavedSearch] { november2026 }
}

@MainActor
final class SavedSearchFixtureTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "ArchiveReaderTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"),
                                "\(name).json is not in the test bundle")
        return try Data(contentsOf: url)
    }

    private func assertLoads(_ fixtureName: String, as expected: [SavedSearch],
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let (d, name) = makeDefaults(); defer { d.removePersistentDomain(forName: name) }
        d.set(try fixture(fixtureName), forKey: "savedSearches")
        let store = SavedSearchStore(defaults: d)
        XCTAssertEqual(store.searches.count, expected.count, "every smart folder in \(fixtureName) loads",
                       file: file, line: line)
        for (got, want) in zip(store.searches, expected) {
            XCTAssertEqual(got, want, "\(fixtureName): “\(want.name)” loads with its rules unchanged",
                           file: file, line: line)
        }
        XCTAssertNil(store.unreadableNotice, file: file, line: line)
        XCTAssertNil(d.data(forKey: SavedSearchStore.unreadableKey), file: file, line: line)
    }

    /// What loading does on purpose to a frozen builder's searches: quality levels the suite never writes (the
    /// form offered 4 and 5 until W40.reader-quality-levels) match nothing and are dropped. Nothing else changes.
    private func asLoadedToday(_ searches: [SavedSearch]) -> [SavedSearch] {
        func fix(_ r: SearchRule) -> SearchRule {
            var r = r
            r.qualities = r.qualities.filter { $0 == 0 || QualityLevels.all.contains($0) }
            r.children = r.children.map(fix)
            return r
        }
        return searches.map { s in var s = s; s.search.rules = s.search.rules.map(fix); return s }
    }

    func testTheNovember2026FixtureLoadsUnchanged() throws {
        try assertLoads("saved-searches-2026-11", as: asLoadedToday(SavedSearchFixtures.november2026))
    }

    /// W40.reader-quality-levels: the November fixture saved Quality rows with 0, 2 and 5; they load, keeping
    /// none and 2. A row of only 4 and 5 loads too, empty, so it is inactive rather than undecodable.
    func testQualityLevelsTheSuiteNeverWritesAreDroppedOnLoad() throws {
        let (d, name) = makeDefaults(); defer { d.removePersistentDomain(forName: name) }
        d.set(try fixture("saved-searches-2026-11"), forKey: "savedSearches")
        let rules = SavedSearchStore(defaults: d).searches.first { $0.name == "Every operator" }?.search.rules ?? []
        let quality = rules.filter { $0.field == .quality }
        XCTAssertEqual(quality.count, RuleField.quality.operators.count)
        XCTAssertTrue(quality.allSatisfy { $0.qualities == [0, 2] }, "\(quality.map(\.qualities))")

        let json = #"{"field":"quality","op":"is","qualities":[4,5]}"#
        let rule = try JSONDecoder().decode(SearchRule.self, from: Data(json.utf8))
        XCTAssertEqual(rule.qualities, [])
        XCTAssertFalse(rule.isActive)
    }

    /// The newest fixture covers every field, operator, read state, date role and combine the form offers. A new
    /// case fails here: add a new fixture with it (never edit an old one).
    func testTheNewestFixtureCoversEveryRuleKind() {
        func walk(_ rules: [SearchRule], depth: Int) -> [(SearchRule, Int)] {
            rules.flatMap { [($0, depth)] + walk($0.children, depth: depth + 1) }
        }
        let searches = SavedSearchFixtures.newest
        let all = searches.flatMap { walk($0.search.rules, depth: 0) }
        let rules = all.map(\.0)
        for field in RuleField.allCases {
            for op in field.operators {
                XCTAssertTrue(rules.contains { $0.field == field && $0.op == op }, "\(field) \(op) is in the fixture")
            }
        }
        for read in ReadFilter.allCases {
            XCTAssertTrue(rules.contains { $0.field == .readState && $0.read == read }, "read state \(read)")
        }
        for role in DateRoleChoice.allCases {
            XCTAssertTrue(rules.contains { $0.field == .date && $0.dateRole == role }, "date role \(role)")
        }
        for combine in RuleCombine.allCases {
            XCTAssertTrue(searches.contains { $0.search.combine == combine }, "top-level \(combine)")
            XCTAssertTrue(rules.contains { $0.field == .group && $0.combine == combine }, "group \(combine)")
        }
        XCTAssertTrue(all.contains { $0.0.field == .group && $0.1 >= 1 }, "a group inside a group")
        XCTAssertTrue(rules.contains { $0.ftsExpression != nil }, "a full-text rule")
    }

    // MARK: No silent loss

    private func listWithOneUnreadable(_ d: UserDefaults) throws -> Data {
        let good = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            SavedSearch(name: "Good", search: AdvancedSearch(combine: .all, rules: [SearchRule(field: .flagged)]))))
        let future: [String: Any] = ["id": UUID().uuidString, "name": "From a later build",
                                     "search": ["combine": "all", "rules": [["field": "someFutureField"]]]]
        let data = try JSONSerialization.data(withJSONObject: [future, good])
        d.set(data, forKey: "savedSearches")
        return data
    }

    func testAnUnreadableEntryIsKeptAndTheUserToldOnce() throws {
        let (d, name) = makeDefaults(); defer { d.removePersistentDomain(forName: name) }
        let original = try listWithOneUnreadable(d)

        let store = SavedSearchStore(defaults: d)
        XCTAssertEqual(store.searches.map(\.name), ["Good"])
        XCTAssertEqual(store.unreadableNotice, 1)
        XCTAssertEqual(d.data(forKey: SavedSearchStore.unreadableKey), original, "the whole list, byte for byte")

        // A save writes the shorter list over the main key; the kept copy is untouched.
        store.add(name: "New", search: AdvancedSearch())
        XCTAssertEqual(SavedSearchStore(defaults: d).searches.map(\.name), ["Good", "New"])
        XCTAssertEqual(d.data(forKey: SavedSearchStore.unreadableKey), original)

        // Told once: after dismissing, a later launch says nothing more.
        store.dismissUnreadableNotice()
        XCTAssertNil(store.unreadableNotice)
        XCTAssertNil(SavedSearchStore(defaults: d).unreadableNotice)
        XCTAssertEqual(d.data(forKey: SavedSearchStore.unreadableKey), original)
    }

    func testTheNoticeStaysUntilDismissed() throws {
        let (d, name) = makeDefaults(); defer { d.removePersistentDomain(forName: name) }
        _ = try listWithOneUnreadable(d)
        _ = SavedSearchStore(defaults: d)
        XCTAssertEqual(SavedSearchStore(defaults: d).unreadableNotice, 1, "a relaunch before dismissing still says it")
    }

    func testTheKeptCopyIsNeverOverwrittenWhileItHoldsData() throws {
        let (d, name) = makeDefaults(); defer { d.removePersistentDomain(forName: name) }
        let first = try listWithOneUnreadable(d)
        SavedSearchStore(defaults: d).dismissUnreadableNotice()
        _ = try listWithOneUnreadable(d)   // a second loss, later
        let store = SavedSearchStore(defaults: d)
        XCTAssertEqual(d.data(forKey: SavedSearchStore.unreadableKey), first)
        XCTAssertNil(store.unreadableNotice, "the kept copy is the first one, already told")
    }

    func testAListThatCannotBeReadAtAllIsKept() throws {
        let (d, name) = makeDefaults(); defer { d.removePersistentDomain(forName: name) }
        let junk = Data("{\"not\": \"a list\"}".utf8)
        d.set(junk, forKey: "savedSearches")
        let store = SavedSearchStore(defaults: d)
        XCTAssertTrue(store.searches.isEmpty)
        XCTAssertEqual(store.unreadableNotice, 0)
        XCTAssertEqual(d.data(forKey: SavedSearchStore.unreadableKey), junk)
        store.add(name: "After", search: AdvancedSearch())
        XCTAssertEqual(d.data(forKey: SavedSearchStore.unreadableKey), junk)
    }

    func testAReadableListKeepsNothingAside() {
        let (d, name) = makeDefaults(); defer { d.removePersistentDomain(forName: name) }
        let store = SavedSearchStore(defaults: d)
        store.add(name: "A", search: AdvancedSearch())
        let reloaded = SavedSearchStore(defaults: d)
        XCTAssertNil(reloaded.unreadableNotice)
        XCTAssertNil(d.data(forKey: SavedSearchStore.unreadableKey))
    }

    func testTheNoticeDraws() throws {
        XCTAssertEqual(UnreadableSmartFoldersNotice.message(2),
                       "2 Smart Folders could not be read by this version. They are kept, not deleted.")
        let view = UnreadableSmartFoldersNotice(count: 2) {}
            .padding().background(Color.white).environment(\.colorScheme, .light)
        let png = try XCTUnwrap(RenderProbe.pngData(from: view, size: CGSize(width: 240, height: 70)))
        writeRenderArtifact(png, named: "smart-folder-unreadable-notice.png")
        assertRendersNonBlank(RenderProbe.cgImage(fromPNG: png), "unreadable smart folders notice")
    }
}
