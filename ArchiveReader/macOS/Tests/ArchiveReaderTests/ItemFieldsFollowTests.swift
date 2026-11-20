import XCTest
import ArchiveCore
@testable import ArchiveReader

/// W49.reader-item-fields-follow: an item field set for a selection, editing anywhere under the folder the Reader was
/// given, the Item fields sort, a snippet for a hit on a correction alone, and the watcher's signal for a correction
/// written by another copy of the Reader. Scratch folders and a scratch content index only.
@MainActor
final class ItemFieldsFollowTests: XCTestCase {
    private let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ItemFieldsFollow-\(UUID().uuidString)", isDirectory: true)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// `names` written as scratch files in `folder` under `base`; the folder, links resolved.
    private func makeFolder(_ folder: String, _ names: [String], under base: URL? = nil) throws -> URL {
        let dir = (base ?? root).appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for n in names { try Data("scratch fixture \(n)".utf8).write(to: dir.appendingPathComponent(n)) }
        return dir.resolvingSymlinksInPath()
    }

    private func values(_ name: String, in dir: URL) -> [CheckableField: String] {
        ContainerFileStore.loadItemFields(directory: dir).document?.values(for: name) ?? [:]
    }

    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return condition()
    }

    // MARK: Set for selection

    func testASelectionEditWritesEveryFolderAndOneUndoTakesItBack() throws {
        let one = try makeFolder("Box 1", ["a.pdf", "b.pdf", "c.pdf"])
        let two = try makeFolder("Box 2", ["d.pdf"])
        let prepared = try [(one, ["a.pdf", "b.pdf"]), (two, ["d.pdf"])].compactMap { dir, names in
            try NavigationModel.prepareItemFieldEdit(at: dir) { f in
                var f = f
                for n in names { f.set(.publication, to: "The Harbour Gazette", for: n) }
                return f
            }
        }
        XCTAssertNil(ContainerFileStore.loadItemFields(directory: one).document, "nothing is written while preparing")
        let step = try XCTUnwrap(try NavigationModel.commitAll(prepared))
        XCTAssertEqual(step.document, .itemFields)
        for (name, dir) in [("a.pdf", one), ("b.pdf", one), ("d.pdf", two)] {
            XCTAssertEqual(values(name, in: dir), [.publication: "The Harbour Gazette"], name)
        }
        XCTAssertEqual(values("c.pdf", in: one), [:], "a file not selected keeps what it had")

        let undone = step.apply()
        XCTAssertTrue(undone.failures.isEmpty)
        XCTAssertEqual(values("a.pdf", in: one), [:])
        XCTAssertEqual(values("d.pdf", in: two), [:])
    }

    func testOneUnreadableFolderRefusesTheWholeSelection() throws {
        let one = try makeFolder("Box 1", ["a.pdf"])
        let two = try makeFolder("Box 2", ["b.pdf"])
        let suite = two.appendingPathComponent(ContainerFile.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: suite, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion": 2, "files": {}}"#.utf8).write(to: suite.appendingPathComponent(UserItemFields.fileName))
        XCTAssertThrowsError(try [one, two].compactMap { dir in
            try NavigationModel.prepareItemFieldEdit(at: dir) { f in
                var f = f
                f.set(.title, to: "X", for: dir == one ? "a.pdf" : "b.pdf")
                return f
            }
        })
        XCTAssertNil(ContainerFileStore.loadItemFields(directory: one).document, "the readable folder is not written")
    }

    func testAFailedSelectionSaysWhatWasPutBack() {
        let none = ContainerSelectionRolledBack(written: 1, total: 2, notRestored: [],
                                                underlying: ContainerWriteError.changedSinceRead)
        XCTAssertEqual(itemFieldEditWriteMessage(none), "Nothing was saved: 1 of 2 folders were written and then put "
            + "back. Another app changed this folder's item fields just now. Look again and redo the change.")
        let stuck = ContainerSelectionRolledBack(written: 1, total: 2,
                                                 notRestored: [(URL(fileURLWithPath: "/corpus/Box 1"),
                                                                ContainerWriteError.changedSinceRead)],
                                                 underlying: ContainerWriteError.busy)
        let message = itemFieldEditWriteMessage(stuck)
        XCTAssertTrue(message.contains("“Box 1” could not be put back"), message)
        XCTAssertTrue(message.contains("item-field file"), message)
    }

    /// The model end to end, under a granted folder that holds an "Archival Photos" main folder: a selection across
    /// two folders, one of them outside the main folder, is saved for both.
    func testTheModelSetsAFieldForASelectionUnderTheGrantedFolder() throws {
        let main = try makeFolder(ReaderArchiveLayout.mainDirectoryName, [])
        let box = try makeFolder("Box 1", ["a.pdf"], under: main)
        let other = try makeFolder("Loose scans", ["b.pdf"])
        let model = NavigationModel(defaults: fixtureDefaults(pinnedTo: root))
        let prefix = try XCTUnwrap(model.rootStore.discoveredPathPrefix, "precondition: a granted folder")
        let a = prefix + "/" + ReaderArchiveLayout.mainDirectoryName + "/Box 1/a.pdf"
        let b = prefix + "/Loose scans/b.pdf"
        XCTAssertTrue(model.canEditItemFields(b), "a file outside the main folder can be corrected")
        XCTAssertNil(ContainerCatalog.split(b, under: try XCTUnwrap(model.containerTree?.path)),
                     "precondition: it is outside the container tree")
        XCTAssertFalse(model.canEditItemFields("/elsewhere/c.pdf"))

        model.editItemFieldForSelection(.byline, .set("Mary Jones"), paths: [a, b])
        XCTAssertTrue(waitUntil { self.values("a.pdf", in: box) == [.byline: "Mary Jones"]
                                  && self.values("b.pdf", in: other) == [.byline: "Mary Jones"] },
                      "\(String(describing: model.itemFieldEditError))")
        XCTAssertTrue(waitUntil { !model.containerEditSaving })

        model.editItemFieldForSelection(.byline, .none, paths: [a, b])
        XCTAssertTrue(waitUntil { self.values("a.pdf", in: box) == [.byline: ""] })
        XCTAssertTrue(waitUntil { !model.containerEditSaving })

        model.editItemFieldForSelection(.byline, .remove, paths: [a, "/elsewhere/c.pdf"])
        XCTAssertNotNil(model.itemFieldEditError, "a file outside the granted folder refuses the whole edit")
        XCTAssertEqual(values("a.pdf", in: box), [.byline: ""], "and nothing is written")
    }

    // MARK: The Item fields sort

    func testTheItemFieldsSortPutsFilesWithNoneLastInEitherDirection() {
        let files = ["c", "a", "b", "none"].map { name in
            ArchiveFile(url: URL(fileURLWithPath: "/corpus/\(name).pdf"), name: name + ".pdf", fileType: "PDF",
                        tags: DocumentTags.parse(raw: [], labelNumber: nil), contentModified: nil)
        }
        let marks = SortMarks(itemFields: ["/corpus/a.pdf": "Annual Report · Mary Jones",
                                           "/corpus/b.pdf": "Survey of 1958", "/corpus/c.pdf": "Ledger 2"])
        let up = LibrarySort.sorted(files, by: [ARSortDescriptor(field: .itemFields)], marks: marks)
        XCTAssertEqual(up.map(\.name), ["a.pdf", "c.pdf", "b.pdf", "none.pdf"])
        let down = LibrarySort.sorted(files, by: [ARSortDescriptor(field: .itemFields, ascending: false)], marks: marks)
        XCTAssertEqual(down.map(\.name), ["b.pdf", "c.pdf", "a.pdf", "none.pdf"])
        for (x, y) in zip(up, up.dropFirst()) {
            XCTAssertTrue(LibrarySort.before(x, y, by: [ARSortDescriptor(field: .itemFields)], marks: marks))
        }
        let column = AppKitTableView.columnDefinitions.first { $0.id == AppKitTableView.itemFieldsColumnID }
        XCTAssertEqual(column?.sortField, .itemFields, "the column header sorts")
    }

    // MARK: A snippet for a hit on a correction alone

    func testAHitOnACorrectionAloneGetsAMarkedSnippet() async throws {
        let index = ContentIndex(url: root.appendingPathComponent("content.sqlite3"))
        try await index.open()
        try await index.upsertBatch([
            IndexRow(path: "/a.pdf", mtime: 1, name: "a.pdf", classification: nil,
                     body: "The harbour board met on Tuesday and the minutes follow.", pageCount: 2, hasText: true,
                     readable: true, headerFields: [:], userFields: [.title: "Minutes of 1958"]),
            IndexRow(path: "/b.pdf", mtime: 1, name: "b.pdf", classification: nil,
                     body: "Minutes of the 1958 meeting.", pageCount: 2, hasText: true, readable: true,
                     headerFields: [:], userFields: [.title: "Minutes of 1958"]),
        ])
        let ranked = await index.searchRanked("1958")
        XCTAssertEqual(Set(ranked.paths), ["/a.pdf", "/b.pdf"])
        let a = try XCTUnwrap(ranked.snippets["/a.pdf"])
        XCTAssertTrue(a.contains(SearchSnippet.openMark + "1958"), "the correction is shown, marked: \(a)")
        let b = try XCTUnwrap(ranked.snippets["/b.pdf"])
        XCTAssertTrue(b.contains("meeting"), "a hit in the text keeps the text's snippet: \(b)")
        await index.close()
    }

    // MARK: The watcher

    func testTheWatcherSignalsAnItemFieldFileWrittenElsewhere() {
        var request = CorpusWatchRequest()
        request.paths.insert("/corpus/Box 1/.archivesuite/item-fields.json")
        XCTAssertTrue(ArchiveLibrary.touchesUserItemFields(request))
        var other = CorpusWatchRequest()
        other.paths.insert("/corpus/Box 1/.archivesuite/containers.json")
        other.paths.insert("/corpus/Box 1/item-fields.json")
        XCTAssertFalse(ArchiveLibrary.touchesUserItemFields(other), "only the item-field file in .archivesuite")
        var subtree = CorpusWatchRequest()
        subtree.subtrees.insert("/corpus/Box 1")
        XCTAssertTrue(ArchiveLibrary.touchesUserItemFields(subtree), "a subtree rescan may hold one")
    }
}
