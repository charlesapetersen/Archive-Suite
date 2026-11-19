import XCTest
import ArchiveCore
@testable import ArchiveReader

/// W47.ct-reader-facet-rules: the container rule of Advanced Search and smart folders, the filter bar's facets saved
/// as that rule, and smart-folder counts following a catalog rebuild. The model test runs on a scratch tree; the
/// only file written there is the level map.
@MainActor
final class ContainerRuleTests: XCTestCase {
    private let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ContainerRule-\(UUID().uuidString)", isDirectory: true)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func file(_ path: String) -> ArchiveFile {
        ArchiveFile(url: URL(fileURLWithPath: path), name: URL(fileURLWithPath: path).lastPathComponent,
                    fileType: "PDF", tags: DocumentTags.parse(raw: [], labelNumber: nil), contentModified: nil)
    }

    private func row(_ fields: [ContainerField: String]) -> ContainerRow {
        let record = ContainerResolver.resolve(fileName: "x.pdf", scopes: [ContainerScope(file: ContainerFile(
            directory: ContainerFieldSet(fields.mapValues { ContainerValue($0, source: .path) })))])
        return ContainerRow(shown: ContainerDisplay.values(record), disagreements: [])
    }

    private func containerRule(_ facet: ContainerFacet, _ value: String, _ op: RuleOperator = .is) -> SearchRule {
        var r = SearchRule(field: .container, op: op); r.containerFacet = facet; r.text = value
        return r
    }

    // MARK: The rule

    func testTheRuleMatchesAFacetsValueWithCaseAndPunctuationFolded() {
        let a = file("/c/a.pdf"), b = file("/c/b.pdf"), none = file("/c/none.pdf")
        var context = RuleContext()
        context.containers = ["/c/a.pdf": row([.container: "BOX 17", .repository: "Hoover Institution Archives"]),
                              "/c/b.pdf": row([.container: "Box 18"])]
        let box17 = AdvancedSearch(combine: .all, rules: [containerRule(.container, "box 17.")])
        XCTAssertEqual([a, b, none].map { box17.matches($0, context) }, [true, false, false])
        let notBox17 = AdvancedSearch(combine: .all, rules: [containerRule(.container, "Box 17", .isNot)])
        XCTAssertEqual([a, b, none].map { notBox17.matches($0, context) }, [false, true, true],
                       "a file with no container is not in Box 17")
        let repository = AdvancedSearch(combine: .all, rules: [containerRule(.repository, "HOOVER INSTITUTION ARCHIVES")])
        XCTAssertEqual([a, b, none].map { repository.matches($0, context) }, [true, false, false])
        let wrongFacet = AdvancedSearch(combine: .all, rules: [containerRule(.series, "Box 17")])
        XCTAssertFalse(wrongFacet.matches(a, context), "the value is tested under its own facet only")

        // The prepared search, as smart-folder counts run it, answers the same.
        for s in [box17, notBox17, repository, wrongFacet] {
            let prepared = s.prepared()
            XCTAssertEqual([a, b, none].map { prepared.matchesPrepared($0, context) },
                           [a, b, none].map { s.matches($0, context) })
        }
        // In a group.
        let group = AdvancedSearch(combine: .all, rules: [SearchRule.group(.any, [containerRule(.container, "Box 18"),
                                                                                 containerRule(.container, "Box 17")])])
        XCTAssertEqual([a, b, none].map { group.matches($0, context) }, [true, true, false])
        XCTAssertTrue(group.uses(.container))
    }

    func testWithoutACatalogTheRuleIsSkippedAndAnEmptyValueIsInactive() {
        let s = AdvancedSearch(combine: .all, rules: [containerRule(.container, "Box 17")])
        XCTAssertTrue(s.matches(file("/c/a.pdf"), RuleContext()), "no catalog yet: skipped, like a pending text rule")
        XCTAssertFalse(containerRule(.container, "  ").isActive)
        XCTAssertFalse(AdvancedSearch(combine: .all, rules: [containerRule(.container, "")]).uses(.container))
        XCTAssertEqual(RuleField.container.operators, [.is, .isNot])
    }

    func testARuleRoundTripsAndOneSavedWithoutAFacetDecodes() throws {
        let rule = containerRule(.collection, "Glotzer papers")
        let back = try JSONDecoder().decode(SearchRule.self, from: JSONEncoder().encode(rule))
        XCTAssertEqual(back, rule)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as? [String: Any])
        json.removeValue(forKey: "containerFacet")
        let old = try JSONDecoder().decode(SearchRule.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.containerFacet, .container)
    }

    // MARK: From the filter bar

    func testTheFilterBarsFacetsBecomeContainerRulesThatAgreeWithTheFilter() {
        var filter = LibraryFilter()
        filter.setContainerFacet(.container, "Box 17")
        filter.setContainerFacet(.repository, "Hoover Institution Archives")
        let search = AdvancedSearch(filter: filter, fullTextQuery: "")
        XCTAssertEqual(search.rules.map(\.field), [.container, .container])
        XCTAssertEqual(search.rules.map(\.containerFacet), [.repository, .container], "in the facets' order")
        XCTAssertEqual(search.rules.map(\.text), ["Hoover Institution Archives", "Box 17"])

        let rows = ["/c/a.pdf": row([.container: "Box 17", .repository: "Hoover Institution Archives"]),
                    "/c/b.pdf": row([.container: "Box 17"]),
                    "/c/c.pdf": row([.container: "Box 18", .repository: "Hoover Institution Archives"])]
        var context = RuleContext(); context.containers = rows
        for path in ["/c/a.pdf", "/c/b.pdf", "/c/c.pdf", "/c/none.pdf"] {
            XCTAssertEqual(search.matches(file(path), context), filter.matchesContainer(rows[path]), path)
        }
    }

    // MARK: The signature

    func testTheContainerSignatureFollowsValuesNotOrder() {
        let a = row([.container: "Box 17"]), b = row([.container: "Box 18"])
        let one = LibraryChangeSignature.containers(["/a": a, "/b": b])
        XCTAssertEqual(one, LibraryChangeSignature.containers(["/b": b, "/a": a]))
        XCTAssertNotEqual(one, LibraryChangeSignature.containers(["/a": b, "/b": a]), "values swapped between files")
        XCTAssertNotEqual(one, LibraryChangeSignature.containers(["/a": a, "/b": row([.container: "Box 19"])]))
        XCTAssertEqual(one, LibraryChangeSignature.containers(["/a": row([.container: "BOX 17"]), "/b": b]),
                       "a spelling that folds to the same value matches the same files")
    }

    // MARK: The model

    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return condition()
    }

    func testASmartFolderSavedFromAFacetKeepsItAndItsCountFollowsACatalogRebuild() throws {
        let box17 = ["Hoover Institution Archives", "Glotzer papers", "Box 17"]
            .reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
        let box18 = box17.deletingLastPathComponent().appendingPathComponent("Box 18", isDirectory: true)
        for (dir, name) in [(box17, "a.pdf"), (box17, "b.pdf"), (box18, "c.pdf"), (box18, "Fromm, Box 2, Folder 4 - 0004.pdf")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(name)
            try Data("scratch fixture".utf8).write(to: url)
            try (url as NSURL).setResourceValue(["Unread"], forKey: .tagNamesKey)
        }
        let model = fixtureNavigationModel(pinnedTo: root)
        XCTAssertTrue(waitUntil { model.displayed.count == 4 }, "precondition: the fixture is listed")
        // No level map yet: only the file name gives a box.
        model.refreshContainers()
        XCTAssertTrue(waitUntil { !model.containerCatalog.isEmpty })
        XCTAssertNil(model.containerCatalog.rows[box17.appendingPathComponent("a.pdf").path])

        model.filter.setContainerFacet(.container, "box 17")
        model.recompute()
        XCTAssertTrue(waitUntil { model.displayed.isEmpty })
        model.saveCurrentSearch(name: "Box 17")
        let saved = try XCTUnwrap(model.savedSearches.searches.first { $0.name == "Box 17" })
        XCTAssertTrue(saved.search.uses(.container), "the facet is saved as a container rule")
        XCTAssertTrue(waitUntil { model.smartFolderCounts[saved.id] == 0 }, "nothing is in Box 17 yet")

        // The level map names the boxes; the rebuilt catalog moves the count and the open folder's list.
        model.applyScope(saved)
        try ContainerFileStore.writeLevelMap(ContainerLevelMap(levels: [.repository, .collection, .box]),
                                             root: root, expecting: nil)
        model.refreshContainers(force: true)
        XCTAssertTrue(waitUntil { model.smartFolderCounts[saved.id] == 2 }, "the count follows the catalog")
        XCTAssertTrue(waitUntil { Set(model.displayed.map(\.name)) == ["a.pdf", "b.pdf"] },
                      "the open smart folder lists Box 17's files")
    }
}
