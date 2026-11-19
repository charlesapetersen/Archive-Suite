import XCTest
import ArchiveCore
@testable import ArchiveReader

/// W47.ct-reader-view: the Container column, its facets, the Inspector's Container section and the level map offered
/// when a root is first added. Every tree is a scratch directory; the only file written is the level map, and the
/// tests check nothing else changed.
@MainActor
final class ContainerViewTests: XCTestCase {
    private let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ContainerView-\(UUID().uuidString)", isDirectory: true)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let repository = "Hoover Institution Archives"
    private let collection = "Glotzer papers, Mss 1036"

    /// Hoover/Glotzer/Box 17 with a.pdf and b.pdf, Box 18 with a file whose name gives another box, and a workflow
    /// folder holding a collection.
    @discardableResult
    private func makeTree() throws -> [String: URL] {
        var urls: [String: URL] = [:]
        let files = [
            ("a", [repository, collection, "Box 17"], "a.pdf"),
            ("b", [repository, collection, "Box 17"], "b.pdf"),
            ("fromm", [repository, collection, "Box 18"], "Fromm, Box 2, Folder 4 - 0004.pdf"),
            ("c", [repository, collection, "Box 18"], "c.pdf"),
        ]
        for (key, dirs, name) in files {
            let dir = dirs.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(name)
            try Data("scratch fixture".utf8).write(to: url)
            try (url as NSURL).setResourceValue(["Unread"], forKey: .tagNamesKey)
            urls[key] = url
        }
        return urls
    }

    private func path(_ url: URL) -> String { url.path }

    private func box17() -> URL {
        root.appendingPathComponent(repository).appendingPathComponent(collection).appendingPathComponent("Box 17")
    }

    /// Every file under the root, hidden ones included, with its size and modification date.
    private func snapshot() throws -> [String: String] {
        var out: [String: String] = [:]
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                                               options: [], errorHandler: { _, _ in true })
        while let url = e?.nextObject() as? URL {
            let v = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            out[url.path] = "\(v.fileSize ?? -1) \(v.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }
        return out
    }

    private func writeLevels(_ levels: [ContainerLevelRole]) throws {
        try ContainerFileStore.writeLevelMap(ContainerLevelMap(levels: levels), root: root, expecting: nil)
    }

    /// Box 17's container file: a box run at a.pdf read by Vision + parser, a folder run at b.pdf.
    private func writeRuns() throws {
        let file = ContainerFile(runs: [
            ContainerRun(start: "a.pdf", level: .box, fields: ContainerFieldSet([
                .container: ContainerValue("Box 17", source: .label, reader: FieldStatusPolicy.visionParser)])),
            ContainerRun(start: "b.pdf", level: .folder, fields: ContainerFieldSet([
                .folder: ContainerValue("8", source: .label, reader: FieldStatusPolicy.visionParser),
                .folderTitle: ContainerValue("REPORTS 1959-1960", source: .user)])),
        ])
        try ContainerFileStore.write(file, directory: box17(), expecting: nil)
    }

    private func build(_ urls: [String: URL], extra: [String] = []) -> ContainerCatalog {
        ContainerCatalog.build(treeRoot: root, rootPath: root.path, filePaths: urls.values.map(\.path) + extra)
    }

    // MARK: The catalog

    func testTheCatalogResolvesFolderLevelsRunsAndFileNamesWithoutWriting() throws {
        let urls = try makeTree()
        try writeLevels([.repository, .collection, .box])
        try writeRuns()
        let before = try snapshot()
        let catalog = build(urls, extra: ["/elsewhere/outside.pdf"])
        XCTAssertEqual(try snapshot(), before, "building the catalog writes nothing")

        let a = try XCTUnwrap(catalog.rows[path(urls["a"]!)])
        XCTAssertEqual(a.cell, "Box 17")
        XCTAssertEqual(a.facets[.repository], repository)
        XCTAssertEqual(a.facets[.collection], "Glotzer papers")
        XCTAssertEqual(a.facets[.container], "Box 17")
        XCTAssertTrue(a.disagreements.isEmpty, "the label read and the folder name agree")

        let b = try XCTUnwrap(catalog.rows[path(urls["b"]!)])
        XCTAssertEqual(b.cell, "Box 17, Folder 8, Reports 1959-1960", "a value wholly in capitals shows in title case")
        XCTAssertTrue(b.toolTip.contains("Collection number: Mss 1036"))

        let c = try XCTUnwrap(catalog.rows[path(urls["c"]!)])
        XCTAssertEqual(c.cell, "Box 18", "Box 18's files have no runs: the folder name alone")

        let fromm = try XCTUnwrap(catalog.rows[path(urls["fromm"]!)])
        XCTAssertEqual(fromm.disagreements, [.container], "the file name says Box 2, the folder Box 18")
        XCTAssertTrue(fromm.cell.hasPrefix("Box 2"), "the file name is the more specific path value")
        XCTAssertNil(catalog.rows["/elsewhere/outside.pdf"], "a file outside the tree has no container")

        XCTAssertEqual(catalog.facetValues(.container).map(\.value), ["Box 17", "Box 2", "Box 18"])
        XCTAssertEqual(catalog.facetValues(.container).map(\.count), [2, 1, 1])
        XCTAssertEqual(catalog.facetValues(.repository).first?.count, 4)
    }

    func testTheInspectorDetailGivesEachValuesStateAndTheDisagreements() throws {
        let urls = try makeTree()
        try writeLevels([.repository, .collection, .box])
        try writeRuns()
        let catalog = build(urls)

        let a = try XCTUnwrap(catalog.detail(forPath: path(urls["a"]!)))
        let status = Dictionary(uniqueKeysWithValues: a.rows.map { ($0.field, $0.status.level) })
        XCTAssertEqual(status[.container], .unchecked, "Vision + parser's box number off a box run clears the fill rule")
        XCTAssertEqual(status[.repository], .lowerConfidence, "folder names are not measured on the owner's folders")

        let b = try XCTUnwrap(catalog.detail(forPath: path(urls["b"]!)))
        let bStatus = Dictionary(uniqueKeysWithValues: b.rows.map { ($0.field, $0.status.level) })
        XCTAssertEqual(bStatus[.folder], .lowerConfidence, "a folder number from a label is below the rule")
        XCTAssertEqual(bStatus[.folderTitle], .checked, "the user's value is checked")
        XCTAssertEqual(b.rows.first { $0.field == .folderTitle }?.text, "Reports 1959-1960")

        let fromm = try XCTUnwrap(catalog.detail(forPath: path(urls["fromm"]!)))
        let d = try XCTUnwrap(fromm.disagreements.first)
        XCTAssertEqual(d.field, .container)
        XCTAssertEqual(d.values.map(\.text), ["Box 2", "Box 18"])
        XCTAssertEqual(d.sentence, "Container: Box 2 (folder names) or Box 18 (folder names).")
    }

    func testWithoutALevelMapOnlyTheContainerRecordsAndFileNamesCount() throws {
        let urls = try makeTree()
        try writeRuns()
        let catalog = build(urls)
        XCTAssertEqual(catalog.rootLevelMap, .missing)
        XCTAssertEqual(catalog.rows[path(urls["a"]!)]?.cell, "Box 17", "the run's label read")
        XCTAssertNil(catalog.rows[path(urls["a"]!)]?.facets[.repository], "no map: the folder names say nothing")
        XCTAssertNil(catalog.rows[path(urls["c"]!)], "nothing for a file with no record")
        XCTAssertEqual(catalog.rows[path(urls["fromm"]!)]?.cell, "Box 2, Folder 4")
    }

    // MARK: The level map

    func testTheDraftPrefillsTheLevelsAndSavingWritesOnlyTheMap() throws {
        let urls = try makeTree()
        let workflow = root.appendingPathComponent("05 Final Tagging").appendingPathComponent("Kristol papers")
        try FileManager.default.createDirectory(at: workflow, withIntermediateDirectories: true)
        let k = workflow.appendingPathComponent("k.pdf")
        try Data("scratch fixture".utf8).write(to: k)
        let first = build(urls, extra: [k.path])
        XCTAssertTrue(NavigationModel.shouldOfferContainerLevels(catalog: first, settled: true, asked: false))
        XCTAssertFalse(NavigationModel.shouldOfferContainerLevels(catalog: first, settled: false, asked: false),
                       "not before the scan has settled")
        XCTAssertFalse(NavigationModel.shouldOfferContainerLevels(catalog: first, settled: true, asked: true),
                       "once per root")

        var draft = ContainerLevelsDraft.make(directories: first.fileDirectories, tree: root, treePath: root.path)
        XCTAssertEqual(draft.map.levels, [.repository, .collection, .box])
        XCTAssertEqual(draft.workflowFolders, ["05 Final Tagging"])
        XCTAssertEqual(draft.examples[2], ["Box 17", "Box 18"])
        XCTAssertEqual(draft.folderCounts, [2, 1, 2], "the workflow folder takes no level, so its folder is at level 1")
        let sample = try XCTUnwrap(draft.sampleDirectory)
        XCTAssertEqual(sample.last, "Box 17")
        XCTAssertEqual(draft.preview(sample),
                       "Repository: Hoover Institution Archives · Collection title: Glotzer papers · Collection number: Mss 1036 · Container: Box 17")
        draft.map.levels[2] = .ignore
        XCTAssertFalse(draft.preview(sample).contains("Container"), "the preview follows an edit")
        draft.map.levels[2] = .box
        draft.setSkipped("05 Final Tagging", false)
        XCTAssertNil(draft.map.overrides["05 Final Tagging"])
        XCTAssertEqual(draft.workflowFolders, ["05 Final Tagging"], "the toggle stays listed")
        draft.setSkipped("05 Final Tagging", true)
        XCTAssertEqual(draft.childRoles, [.repository, .collection, .box])
        draft.setChildren("05 Final Tagging", .collection)

        let before = try snapshot()
        try ContainerFileStore.writeLevelMap(draft.map, root: root, expecting: draft.expecting)
        var after = try snapshot()
        let mapPath = ContainerFileStore.levelMapURL(in: root).path
        XCTAssertNotNil(after.removeValue(forKey: mapPath))
        XCTAssertNotNil(after.removeValue(forKey: root.appendingPathComponent(ContainerFile.folderName).path))
        XCTAssertEqual(after, before, "only .archivesuite/container-levels.json is new")

        let second = build(urls, extra: [k.path])
        XCTAssertFalse(NavigationModel.shouldOfferContainerLevels(catalog: second, settled: true, asked: false),
                       "a root with a map is not asked")
        XCTAssertEqual(second.rows[k.path]?.facets[.collection], "Kristol papers",
                       "the workflow folder is skipped, and the folders inside it are collections")
        XCTAssertNil(second.rows[k.path]?.facets[.repository])
        XCTAssertEqual(second.rows[path(urls["c"]!)]?.facets[.repository], repository)

        // Reopened, the stored map is the draft, and its stamp guards the write.
        guard case let .loaded(stored, stamp) = ContainerFileStore.loadLevelMap(root: root) else {
            return XCTFail("the map reads back")
        }
        let reopened = ContainerLevelsDraft.make(directories: second.fileDirectories, existing: stored, expecting: stamp,
                                                  tree: root, treePath: root.path)
        XCTAssertEqual(reopened.map.levels, draft.map.levels)
        XCTAssertThrowsError(try ContainerFileStore.writeLevelMap(draft.map, root: root, expecting: nil),
                             "a write that did not read the stored map is refused")
    }

    func testAFlatTreeOrAnUnreadableMapIsNotOffered() throws {
        let flat = root.appendingPathComponent("a.pdf")
        try Data("x".utf8).write(to: flat)
        let catalog = ContainerCatalog.build(treeRoot: root, rootPath: root.path, filePaths: [flat.path])
        XCTAssertFalse(NavigationModel.shouldOfferContainerLevels(catalog: catalog, settled: true, asked: false))

        try makeTree()
        let folder = root.appendingPathComponent(ContainerFile.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: folder.appendingPathComponent(ContainerLevelMap.fileName))
        let unreadable = ContainerCatalog.build(treeRoot: root, rootPath: root.path,
                                                filePaths: [box17().appendingPathComponent("a.pdf").path])
        XCTAssertFalse(NavigationModel.shouldOfferContainerLevels(catalog: unreadable, settled: true, asked: false),
                       "an unreadable map is left alone, not replaced")
    }

    func testAnUnreadableNestedMapGivesItsSubtreeNoLevelsRatherThanTheOuterOnes() throws {
        let urls = try makeTree()
        try writeLevels([.repository, .collection, .box])
        let inner = root.appendingPathComponent(repository).appendingPathComponent(collection)
            .appendingPathComponent(ContainerFile.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: inner.appendingPathComponent(ContainerLevelMap.fileName))
        let catalog = build(urls)
        XCTAssertNil(catalog.rows[path(urls["c"]!)], "the nearest map wins even unread: no path values below it")
        XCTAssertEqual(catalog.rows[path(urls["fromm"]!)]?.cell, "Box 2, Folder 4", "file names still count")
    }

    func testAValueFilledByAStandardNameIsAsSureAsTheValueItMatched() throws {
        let urls = try makeTree()
        try writeLevels([.repository, .collection, .box])
        var names = ContainerNames()
        names.set(ContainerStandardName(field: .repository, variants: [repository],
                                        fields: [.repository: "Hoover Institution Library & Archives",
                                                 .place: "Stanford, CA"]))
        try ContainerFileStore.writeNames(names, root: root, expecting: nil)
        let catalog = build(urls)
        let c = try XCTUnwrap(catalog.detail(forPath: path(urls["c"]!)))
        let place = try XCTUnwrap(c.rows.first { $0.field == .place })
        XCTAssertEqual(place.text, "Stanford, CA")
        XCTAssertEqual(place.status.level, .lowerConfidence, "matched by a folder name, so no surer than it")
        XCTAssertTrue(place.status.source.hasPrefix("From your standard name for the repository"))
        XCTAssertEqual(catalog.rows[path(urls["c"]!)]?.facets[.repository], "Hoover Institution Library & Archives")
    }

    func testSavingRefusesATreeThatIsNoLongerOpen() throws {
        try makeTree()
        let model = fixtureNavigationModel(pinnedTo: root)
        XCTAssertTrue(waitUntil { model.displayed.count == 4 })
        let other = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ContainerViewOther-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }
        let draft = ContainerLevelsDraft.make(directories: [["A"]], tree: other, treePath: other.path)
        model.saveContainerLevels(draft)
        XCTAssertEqual(model.containerLevelsError, "The archive folder changed since this sheet opened, so nothing was saved.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.appendingPathComponent(ContainerFile.folderName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ContainerFileStore.levelMapURL(in: root).path))
    }

    func testSplitIsByteExactUnderTheRoot() {
        XCTAssertEqual(ContainerCatalog.split("/r/A/B/x.pdf", under: "/r")?.directory, ["A", "B"])
        XCTAssertEqual(ContainerCatalog.split("/r/A/B/x.pdf", under: "/r/")?.name, "x.pdf")
        XCTAssertEqual(ContainerCatalog.split("/r/x.pdf", under: "/r")?.directory, [])
        XCTAssertNil(ContainerCatalog.split("/r2/x.pdf", under: "/r"))
        XCTAssertNil(ContainerCatalog.split("/r/x.pdf", under: ""))
        XCTAssertNil(ContainerCatalog.split("/r/../x.pdf", under: "/r"))
    }

    // MARK: Filter, chips and sort

    func testContainerFacetsFilterByShownValueAndShowAsChips() throws {
        var filter = LibraryFilter()
        XCTAssertFalse(filter.isActive)
        filter.setContainerFacet(.container, "Box 17")
        filter.setContainerFacet(.repository, "HOOVER INSTITUTION ARCHIVES")
        XCTAssertTrue(filter.isActive)
        let record = ContainerResolver.resolve(fileName: "x.pdf", scopes: [ContainerScope(file: ContainerFile(
            directory: ContainerFieldSet([.container: ContainerValue("BOX 17", source: .path),
                                          .repository: ContainerValue("Hoover Institution Archives", source: .path)])))])
        let row = ContainerRow(shown: ContainerDisplay.values(record), disagreements: [])
        XCTAssertTrue(filter.matchesContainer(row), "values compare with case and punctuation folded")
        XCTAssertFalse(filter.matchesContainer(nil), "a file with no container fails an active facet")
        filter.setContainerFacet(.container, "Box 18")
        XCTAssertFalse(filter.matchesContainer(row))

        let chips = ActiveFilterChip.chips(filter: filter, smartFolderName: nil, fullTextQuery: nil)
        XCTAssertEqual(chips.map(\.label), ["Repository: HOOVER INSTITUTION ARCHIVES", "Container: Box 18"])
        XCTAssertEqual(chips.last?.accessibilityIdentifier, "ar.filter.chip.container.container")
        XCTAssertEqual(chips.last?.phrase, "the container \u{201c}Box 18\u{201d}")
        filter = filter.removing(.container(.container)).removing(.container(.repository))
        XCTAssertNil(filter.containerFacets, "removing the last facet leaves the saved filter as before")
        XCTAssertFalse(filter.isActive)
    }

    func testAFilterSavedBeforeTheFacetsStillDecodesAndTheFacetsRoundTrip() throws {
        let old = try JSONEncoder().encode(LibraryFilter())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: old) as? [String: Any])
        json.removeValue(forKey: "containerFacets")
        let decoded = try JSONDecoder().decode(LibraryFilter.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.containerFacets)
        var filter = LibraryFilter()
        filter.setContainerFacet(.series, "Series II")
        let back = try JSONDecoder().decode(LibraryFilter.self, from: JSONEncoder().encode(filter))
        XCTAssertEqual(back.containerFacet(.series), "Series II")
    }

    func testTheContainerSortPutsFilesWithNoneLastInEitherDirection() {
        let files = ["c", "a", "b", "none"].map { name in
            ArchiveFile(url: URL(fileURLWithPath: "/corpus/\(name).pdf"), name: name + ".pdf", fileType: "PDF",
                        tags: DocumentTags.parse(raw: [], labelNumber: nil), contentModified: nil)
        }
        let marks = SortMarks(containers: ["/corpus/a.pdf": "Box 2", "/corpus/b.pdf": "Box 10", "/corpus/c.pdf": "Box 2, Folder 1"])
        let up = LibrarySort.sorted(files, by: [ARSortDescriptor(field: .container)], marks: marks)
        XCTAssertEqual(up.map(\.name), ["a.pdf", "c.pdf", "b.pdf", "none.pdf"], "Box 2 before Box 10, as Finder sorts")
        let down = LibrarySort.sorted(files, by: [ARSortDescriptor(field: .container, ascending: false)], marks: marks)
        XCTAssertEqual(down.map(\.name), ["b.pdf", "c.pdf", "a.pdf", "none.pdf"])
        for (x, y) in zip(up, up.dropFirst()) {
            XCTAssertTrue(LibrarySort.before(x, y, by: [ARSortDescriptor(field: .container)], marks: marks))
        }
    }

    // MARK: The model

    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return condition()
    }

    func testTheModelShowsTheColumnFiltersByAFacetAndNeverOffersTheSheetUnderATestHost() throws {
        let urls = try makeTree()
        try writeLevels([.repository, .collection, .box])
        let model = fixtureNavigationModel(pinnedTo: root)
        XCTAssertTrue(waitUntil { model.displayed.count == 4 }, "precondition: the fixture is listed")
        model.refreshContainers()
        XCTAssertTrue(waitUntil { !model.containerCatalog.isEmpty }, "the catalog is built off the main thread")
        XCTAssertFalse(model.effectiveHiddenColumns.contains(AppKitTableView.containerColumnID),
                       "Container is offered once a file has a value")
        XCTAssertTrue(model.isColumnAvailable(AppKitTableView.containerColumnID))
        let c = try XCTUnwrap(model.displayed.first { $0.name == "c.pdf" })
        XCTAssertEqual(model.containerRow(for: c.path)?.cell, "Box 18")
        XCTAssertNotNil(urls["c"])

        model.filter.setContainerFacet(.container, "box 17")
        model.recompute()
        XCTAssertEqual(Set(model.displayed.map(\.name)), ["a.pdf", "b.pdf"])
        XCTAssertEqual(model.activeFilterChips.map(\.label), ["Container: box 17"])
        model.removeFilter(.container(.container))
        XCTAssertTrue(waitUntil { model.displayed.count == 4 }, "the chip's ✕ brings them back")

        model.sort = [ARSortDescriptor(field: .container), ARSortDescriptor(field: .name)]
        model.recompute()
        XCTAssertEqual(model.displayed.map(\.name), ["Fromm, Box 2, Folder 4 - 0004.pdf", "a.pdf", "b.pdf", "c.pdf"],
                       "Box 2 before Box 17, as Finder sorts")

        model.offerContainerLevelsIfNeeded()
        XCTAssertNil(model.containerLevelsDraft, "nobody is there to answer under a test host")
    }

    func testTheColumnStaysHiddenWhileNoFileHasAContainer() throws {
        let model = NavigationModel(defaults: fixtureDefaults())
        XCTAssertTrue(model.effectiveHiddenColumns.contains(AppKitTableView.containerColumnID))
        XCTAssertFalse(model.isColumnAvailable(AppKitTableView.containerColumnID))
        let definition = try XCTUnwrap(AppKitTableView.columnDefinitions.first { $0.id == AppKitTableView.containerColumnID })
        XCTAssertEqual(definition.sortField, .container)
        XCTAssertTrue(definition.toolTip.contains("Container Levels"))
    }
}
