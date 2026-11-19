import XCTest
import ArchiveCore
@testable import ArchiveReader

/// W47.ct-reader-edit: the container editor. The edits are worked out purely (`ContainerEdits`) and checked through
/// the inheritance rule, file by file; the write path runs on scratch directories and the tests check that nothing but
/// the folder's `.archivesuite/containers.json` (or the tree's `container-names.json`) changed.
@MainActor
final class ContainerEditTests: XCTestCase {
    private let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ContainerEdit-\(UUID().uuidString)", isDirectory: true)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let names = ["a.pdf", "b.pdf", "c.pdf", "d.pdf", "e.pdf", "f.pdf"]

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func label(_ v: String) -> ContainerValue {
        ContainerValue(v, source: .label, reader: FieldStatusPolicy.visionParser)
    }

    private func user(_ v: String) -> ContainerValue { ContainerValue(v, source: .user, at: now) }

    /// Each file's shown value of `field`, through the inheritance rule.
    private func shown(_ field: ContainerField, _ file: ContainerFile) -> [String] {
        names.map { ContainerResolver.resolve(fileName: $0, scopes: [ContainerScope(file: file)]).shown(field) ?? "-" }
    }

    /// Box 1 from a.pdf (a label read), Folder 2 from c.pdf.
    private var boxAndFolder: ContainerFile {
        ContainerFile(runs: [
            ContainerRun(start: "a.pdf", level: .box, fields: ContainerFieldSet([.container: label("Box 1")])),
            ContainerRun(start: "c.pdf", level: .folder, fields: ContainerFieldSet([.folder: label("2")])),
        ])
    }

    // MARK: Editing a run

    func testAnEditGoesToTheRunThatGivesTheValueAndEveryFileUnderItFollows() throws {
        let file = boxAndFolder
        XCTAssertEqual(ContainerEdits.target(for: .container, at: "d.pdf", in: file), .run(start: "a.pdf", level: .box))
        XCTAssertEqual(ContainerEdits.target(for: .folderTitle, at: "d.pdf", in: file), .run(start: "c.pdf", level: .folder),
                       "a field with no value goes to the live run of its level")
        XCTAssertEqual(ContainerEdits.target(for: .folder, at: "b.pdf", in: file), .newRun(start: "b.pdf", level: .folder),
                       "no folder run is live before c.pdf: a new one, not the whole folder's value")
        XCTAssertEqual(ContainerEdits.target(for: .repository, at: "b.pdf", in: file), .directory,
                       "no collection run anywhere: the folder's own values")
        XCTAssertEqual(ContainerEdits.target(for: .date, at: "d.pdf", in: file), .run(start: "c.pdf", level: .folder),
                       "a date goes to the deepest live run")

        let target = ContainerEdits.target(for: .container, at: "d.pdf", in: file)
        let value = ContainerEdits.userValue("Box 13", confirming: file.runs[0].fields[.container], at: now)
        let edited = try XCTUnwrap(ContainerEdits.set(.container, to: value, at: target, in: file))
        XCTAssertEqual(shown(.container, edited), Array(repeating: "Box 13", count: 6))
        XCTAssertEqual(shown(.folder, edited), ["-", "-", "2", "2", "2", "2"], "nothing else changes")
        XCTAssertEqual(edited.runs.first?.fields[.container]?.source, .user)
        XCTAssertEqual(ContainerEdits.covered(by: target, in: file, fileNames: names), 6)
    }

    func testAnEditInAGapBeforeTheFirstBoxStartsARunRatherThanOverrulingTheReads() throws {
        let file = ContainerFile(runs: [
            ContainerRun(start: "c.pdf", level: .box, fields: ContainerFieldSet([.container: label("Box 1")])),
            ContainerRun(start: "c.pdf", level: .folder, fields: ContainerFieldSet([.folder: label("2")])),
        ])
        let target = ContainerEdits.target(for: .container, at: "a.pdf", in: file)
        XCTAssertEqual(target, .newRun(start: "a.pdf", level: .box))
        XCTAssertEqual(ContainerEdits.covered(by: target, in: file, fileNames: names), 2)
        let edited = try XCTUnwrap(ContainerEdits.set(.container, to: user("Box 0"), at: target, in: file))
        XCTAssertEqual(shown(.container, edited), ["Box 0", "Box 0", "Box 1", "Box 1", "Box 1", "Box 1"])
        XCTAssertEqual(shown(.folder, edited), ["-", "-", "2", "2", "2", "2"])
        XCTAssertNil(ContainerEdits.set(.container, to: nil, at: target, in: file), "nothing to remove from no run")
    }

    func testAnEditGoesWhereTheShownValueLivesNotToADeeperLosingRead() {
        let file = ContainerFile(directory: ContainerFieldSet([.boxTitle: user("Y")]), runs: [
            ContainerRun(start: "a.pdf", level: .box, fields: ContainerFieldSet([.boxTitle: label("X")])),
        ])
        XCTAssertEqual(ContainerEdits.target(for: .boxTitle, at: "b.pdf", in: file), .directory,
                       "the user's directory value is the one shown")
    }

    func testSelectionCopiesCarryOnlyWhatShallowerRunsGive() throws {
        // A folder run holding a container (another writer's) must not leak into the box run made for the selection.
        let file = ContainerFile(runs: [
            ContainerRun(start: "a.pdf", level: .collection, fields: ContainerFieldSet([.container: user("Box 3")])),
            ContainerRun(start: "a.pdf", level: .folder, fields: ContainerFieldSet([.container: label("Box 9")])),
            ContainerRun(start: "b.pdf", level: .folder, fields: ContainerFieldSet([.folder: label("4")])),
        ])
        let before = shown(.container, file)
        let edited = try XCTUnwrap(ContainerEdits.setForSelection(.boxTitle, to: user("Subject file"),
                                                                  group: ["a.pdf", "b.pdf", "c.pdf"], after: "d.pdf",
                                                                  in: file))
        XCTAssertEqual(shown(.container, edited), before, "only the box title changes")
        XCTAssertEqual(shown(.boxTitle, edited), ["Subject file", "Subject file", "Subject file", "-", "-", "-"])
    }

    func testConfirmingAReadKeepsItsReaderAndATypedValueDoesNot() {
        let read = label("Box 1")
        let confirmed = ContainerEdits.userValue(" Box 1 ", confirming: read, at: now)
        XCTAssertEqual(confirmed.source, .user)
        XCTAssertEqual(confirmed.reader, FieldStatusPolicy.visionParser)
        let typed = ContainerEdits.userValue("Box 2", confirming: read, at: now)
        XCTAssertEqual(typed.source, .user)
        XCTAssertNil(typed.reader)
        XCTAssertEqual(typed.at, now)
    }

    func testNoneHereHidesTheReadAndRemovingTheUsersValueBringsItBack() throws {
        let file = ContainerFile(directory: ContainerFieldSet([.repository: ContainerValue("Hoover", source: .path)]),
                                 runs: boxAndFolder.runs)
        let target = ContainerEdits.target(for: .container, at: "b.pdf", in: file)
        let none = try XCTUnwrap(ContainerEdits.set(.container, to: ContainerValue("", source: .user), at: target, in: file))
        XCTAssertEqual(shown(.container, none), Array(repeating: "-", count: 6))
        let back = try XCTUnwrap(ContainerEdits.set(.container, to: nil, at: target, in: none))
        XCTAssertEqual(shown(.container, back), ["-", "-", "-", "-", "-", "-"], "the read was replaced, not kept under it")
        let dir = try XCTUnwrap(ContainerEdits.set(.repository, to: user("Hoover Institution"), at: .directory, in: file))
        XCTAssertEqual(shown(.repository, dir), Array(repeating: "Hoover Institution", count: 6))
    }

    // MARK: Set for selection

    func testSetForSelectionSplitsTheRunSoOnlyTheSelectedFilesChange() throws {
        let file = boxAndFolder
        let edited = try XCTUnwrap(ContainerEdits.setForSelection(.container, to: user("Box 9"), group: ["c.pdf", "d.pdf"],
                                                                  after: "e.pdf", in: file))
        XCTAssertEqual(shown(.container, edited), ["Box 1", "Box 1", "Box 9", "Box 9", "Box 1", "Box 1"])
        XCTAssertEqual(shown(.folder, edited), ["-", "-", "2", "2", "2", "2"], "the folder run carries across both splits")
        let after = ContainerResolver.resolve(fileName: "e.pdf", scopes: [ContainerScope(file: edited)])
        XCTAssertEqual(after.values[.container]?.source, .label, "the files after keep the read, not the user's value")
        XCTAssertEqual(after.values[.container]?.reader, FieldStatusPolicy.visionParser)
    }

    func testSetForSelectionCoversARunStartingInsideIt() throws {
        let file = ContainerFile(runs: [
            ContainerRun(start: "a.pdf", level: .box, fields: ContainerFieldSet([.container: label("Box 1")])),
            ContainerRun(start: "d.pdf", level: .box, fields: ContainerFieldSet([.container: label("Box 2"),
                                                                                  .boxTitle: label("Subject file")])),
        ])
        let edited = try XCTUnwrap(ContainerEdits.setForSelection(.container, to: user("Box 9"),
                                                                  group: ["c.pdf", "d.pdf", "e.pdf"], after: "f.pdf",
                                                                  in: file))
        XCTAssertEqual(shown(.container, edited), ["Box 1", "Box 1", "Box 9", "Box 9", "Box 9", "Box 2"])
        XCTAssertEqual(shown(.boxTitle, edited), ["-", "-", "-", "Subject file", "Subject file", "Subject file"])
    }

    func testSetForSelectionWithNoRunsMakesOneAndEndsIt() throws {
        let file = ContainerFile(directory: ContainerFieldSet([.collectionTitle: label("Glotzer papers")]))
        let edited = try XCTUnwrap(ContainerEdits.setForSelection(.folder, to: user("8"), group: ["b.pdf", "c.pdf"],
                                                                  after: "d.pdf", in: file))
        XCTAssertEqual(shown(.folder, edited), ["-", "8", "8", "-", "-", "-"])
        XCTAssertEqual(shown(.collectionTitle, edited), Array(repeating: "Glotzer papers", count: 6))
        let toEnd = try XCTUnwrap(ContainerEdits.setForSelection(.folder, to: user("8"), group: ["e.pdf", "f.pdf"],
                                                                 after: nil, in: file))
        XCTAssertEqual(shown(.folder, toEnd), ["-", "-", "-", "-", "8", "8"])
        XCTAssertEqual(toEnd.runs.count, 1, "nothing to end after the directory's last file")
    }

    func testSetForSelectionOfACollectionFieldKeepsTheBoxesUnderIt() throws {
        let file = ContainerFile(runs: [
            ContainerRun(start: "a.pdf", level: .collection, fields: ContainerFieldSet([.collectionTitle: label("Glotzer")])),
            ContainerRun(start: "a.pdf", level: .box, fields: ContainerFieldSet([.container: label("Box 1")])),
            ContainerRun(start: "c.pdf", level: .box, fields: ContainerFieldSet([.container: label("Box 2")])),
        ])
        let edited = try XCTUnwrap(ContainerEdits.setForSelection(.collectionTitle, to: user("Kristol papers"),
                                                                  group: ["b.pdf", "c.pdf"], after: "d.pdf", in: file))
        XCTAssertEqual(shown(.collectionTitle, edited), ["Glotzer", "Kristol papers", "Kristol papers", "Glotzer",
                                                         "Glotzer", "Glotzer"])
        XCTAssertEqual(shown(.container, edited), ["Box 1", "Box 1", "Box 2", "Box 2", "Box 2", "Box 2"],
                       "the box runs a new collection run would end are carried across it")
    }

    func testADeeperRunsOwnValueDoesNotHideTheSelectionsValue() throws {
        let file = ContainerFile(runs: [
            ContainerRun(start: "a.pdf", level: .box, fields: ContainerFieldSet([.container: label("Box 1")])),
            ContainerRun(start: "c.pdf", level: .folder, fields: ContainerFieldSet([.container: user("Box 4"),
                                                                                     .folder: label("2")])),
        ])
        let edited = try XCTUnwrap(ContainerEdits.setForSelection(.container, to: user("Box 9"), group: ["c.pdf", "d.pdf"],
                                                                  after: "e.pdf", in: file))
        XCTAssertEqual(shown(.container, edited), ["Box 1", "Box 1", "Box 9", "Box 9", "Box 4", "Box 4"])
        XCTAssertEqual(shown(.folder, edited), ["-", "-", "2", "2", "2", "2"])
    }

    func testSelectedFilesAreGroupedIntoNeighbours() {
        XCTAssertEqual(ContainerEdits.contiguousGroups(selected: ["a.pdf", "b.pdf", "d.pdf", "f.pdf"], fileNames: names),
                       [["a.pdf", "b.pdf"], ["d.pdf"], ["f.pdf"]])
        XCTAssertEqual(ContainerEdits.contiguousGroups(selected: ["page 10.pdf", "page 9.pdf"],
                                                       fileNames: ["page 10.pdf", "page 9.pdf", "page 11.pdf"]),
                       [["page 9.pdf", "page 10.pdf"]], "in Finder's order")
        XCTAssertTrue(ContainerEdits.selectionFields.allSatisfy { $0.homeLevel != nil })
    }

    // MARK: Standard names

    func testAStandardNameTakesTheWordingAndARenameKeepsTheOnesBefore() {
        var names = ContainerEdits.setStandardName("Hoover Institution Library & Archives", for: "HOOVER INSTITUTION",
                                                   field: .repository, in: ContainerNames(), at: now)
        XCTAssertEqual(names.entry(for: .repository, matching: "Hoover Institution")?.shown(.repository),
                       "Hoover Institution Library & Archives")
        names = ContainerEdits.setStandardName("Hoover", for: "HOOVER INSTITUTION", field: .repository, in: names, at: now)
        XCTAssertEqual(names.names.count, 1)
        XCTAssertEqual(names.entry(for: .repository, matching: "Hoover Institution Library and Archives")?.shown(.repository),
                       "Hoover", "the old standard name is now one of its wordings")
        XCTAssertEqual(names.updatedAt, now)
        names = ContainerEdits.setStandardName("", for: "Hoover Institution", field: .repository, in: names, at: now)
        XCTAssertTrue(names.names.isEmpty, "an empty name stops using one")
    }

    // MARK: Writing, on scratch directories

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

    private func makeBox() throws -> URL {
        let box = root.appendingPathComponent("Box 17", isDirectory: true)
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        for n in names { try Data("scratch fixture".utf8).write(to: box.appendingPathComponent(n)) }
        try FileManager.default.createDirectory(at: box.appendingPathComponent("Sub", isDirectory: true),
                                                withIntermediateDirectories: true)
        return box.resolvingSymlinksInPath()
    }

    func testAnEditWritesOnlyTheFoldersContainerFile() throws {
        let box = try makeBox()
        try ContainerFileStore.write(boxAndFolder, directory: box, expecting: nil)
        let before = try snapshot()
        try NavigationModel.editContainerFile(at: box) { file in
            ContainerEdits.setForSelection(.container, to: self.user("Box 9"), group: ["c.pdf"], after: "d.pdf", in: file)
        }
        let after = try snapshot()
        let written = ContainerFileStore.containerFileURL(in: box).resolvingSymlinksInPath().path
        let changed = Set(after.keys).union(before.keys).filter { before[$0] != after[$0] }
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        let suite = box.appendingPathComponent(ContainerFile.folderName).resolvingSymlinksInPath().path
        XCTAssertEqual(Set(changed), [written, suite], "only the container file changed (and its folder's listing)")
        let read = try XCTUnwrap(ContainerFileStore.load(directory: box).document)
        XCTAssertEqual(ContainerResolver.resolve(fileName: "c.pdf", scopes: [ContainerScope(file: read)]).shown(.container),
                       "Box 9")
        XCTAssertNotNil(read.updatedAt)
        XCTAssertEqual(try NavigationModel.fileNames(in: box).sorted(), names, "folders and hidden files are not files")
    }

    func testANewerOrUnreadableDocumentIsLeftAsItIs() throws {
        let box = try makeBox()
        let suite = box.appendingPathComponent(ContainerFile.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: suite, withIntermediateDirectories: true)
        let doc = suite.appendingPathComponent(ContainerFile.fileName)
        for bytes in [#"{"schemaVersion": 2, "runs": []}"#, #"{"schemaVersion": 1, "runs": [], "future": 1}"#, "{ no"] {
            try Data(bytes.utf8).write(to: doc)
            var called = false
            XCTAssertThrowsError(try NavigationModel.editContainerFile(at: box) { file in
                called = true
                return ContainerEdits.set(.container, to: self.user("Box 9"), at: .directory, in: file)
            }) { XCTAssertEqual($0 as? ContainerWriteError, .refusedExisting(ContainerFile.fileName)) }
            XCTAssertFalse(called)
            XCTAssertEqual(try String(contentsOf: doc, encoding: .utf8), bytes, "untouched")
        }
    }

    func testAFolderSwappedForALinkIsRefused() throws {
        let box = try makeBox()
        let elsewhere = root.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Linked"), withDestinationURL: elsewhere)
        XCTAssertThrowsError(try NavigationModel.containerDirectoryURL(root, ["Linked"]))
        XCTAssertThrowsError(try NavigationModel.containerDirectoryURL(root, ["Linked", "Sub"]))
        XCTAssertEqual(try NavigationModel.containerDirectoryURL(root, ["Box 17"]).path, box.path)
    }

    func testAnUnreadableNearerNamesFileIsNotPassedOver() throws {
        _ = try makeBox()
        let inner = root.appendingPathComponent("Box 17/.archivesuite", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data("{ no".utf8).write(to: inner.appendingPathComponent(ContainerNames.fileName))
        XCTAssertEqual(try NavigationModel.nearestNamesRoot(root, ["Box 17", "Sub"]).lastPathComponent, "Box 17")
        XCTAssertEqual(try NavigationModel.nearestNamesRoot(root, []).path, root.resolvingSymlinksInPath().path)
    }

    func testSetForSelectionInAFolderWritesOnlyItsContainerFile() throws {
        let box = try makeBox()
        let before = try snapshot()
        try NavigationModel.setForSelection(.container, user("Box 5"), selected: ["b.pdf", "c.pdf", "e.pdf"], in: box)
        let read = try XCTUnwrap(ContainerFileStore.load(directory: box).document)
        XCTAssertEqual(shown(.container, read), ["-", "Box 5", "Box 5", "-", "Box 5", "-"])
        let changed = Set(try snapshot().filter { before[$0.key] != $0.value }.keys)
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        XCTAssertTrue(changed.allSatisfy { $0.contains("/.archivesuite") || $0 == box.path },
                      "only .archivesuite, and the box folder's listing gaining it: \(changed)")
    }

    func testNoChangeWritesNothing() throws {
        let box = try makeBox()
        let before = try snapshot()
        try NavigationModel.editContainerFile(at: box) { _ in nil }
        try NavigationModel.editContainerFile(at: box) { $0 }
        XCTAssertEqual(try snapshot(), before, "not even an empty .archivesuite")
    }

    // MARK: Undo and Redo (W47.ct-reader-edit-undo)

    private func makeFolder(_ name: String) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for n in names { try Data("scratch fixture".utf8).write(to: dir.appendingPathComponent(n)) }
        return dir.resolvingSymlinksInPath()
    }

    func testUndoPutsBackWhatTheEditReplacedAndRedoTakesItForwardAgain() throws {
        let box = try makeBox()
        try ContainerFileStore.write(boxAndFolder, directory: box, expecting: nil)
        let original = try XCTUnwrap(ContainerFileStore.load(directory: box).document)
        let restore = try XCTUnwrap(try NavigationModel.editContainerFile(at: box) { file in
            ContainerEdits.set(.container, to: self.user("Box 9"), at: .run(start: "a.pdf", level: .box), in: file)
        })
        let edited = try XCTUnwrap(ContainerFileStore.load(directory: box).document)
        XCTAssertEqual(shown(.container, edited).first, "Box 9")

        let undone = ContainerUndoStep(restores: [restore]).apply()
        XCTAssertTrue(undone.failures.isEmpty)
        XCTAssertEqual(ContainerFileStore.load(directory: box).document, original, "the label read is back as it was")
        let redone = undone.inverse.apply()
        XCTAssertTrue(redone.failures.isEmpty)
        XCTAssertEqual(ContainerFileStore.load(directory: box).document, edited)
        XCTAssertTrue(redone.inverse.apply().failures.isEmpty, "and undone again")
        XCTAssertEqual(ContainerFileStore.load(directory: box).document, original)
    }

    func testUndoLeavesAFileChangedSinceTheEditAlone() throws {
        let box = try makeBox()
        let restore = try XCTUnwrap(try NavigationModel.editContainerFile(at: box) { file in
            ContainerEdits.set(.container, to: self.user("Box 9"), at: .directory, in: file)
        })
        // Another app writes in between.
        guard case let .loaded(doc, stamp) = ContainerFileStore.load(directory: box) else { return XCTFail() }
        let other = try XCTUnwrap(ContainerEdits.set(.container, to: user("Box 3"), at: .directory, in: doc))
        try ContainerFileStore.write(other, directory: box, expecting: stamp)
        let before = try snapshot()
        let result = ContainerUndoStep(restores: [restore]).apply()
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures.first?.error as? ContainerWriteError, .changedSinceRead)
        XCTAssertTrue(result.inverse.restores.isEmpty, "nothing to redo")
        XCTAssertEqual(try snapshot(), before, "the other app's file is left as it is")
        XCTAssertTrue(containerUndoMessage(result.failures[0].error).contains("changed after the edit"))
    }

    func testUndoOfAFolderThatHadNoFileLeavesAnEmptyOne() throws {
        let box = try makeBox()
        let restore = try XCTUnwrap(try NavigationModel.setForSelection(.container, user("Box 5"),
                                                                        selected: ["b.pdf"], in: box))
        XCTAssertTrue(ContainerUndoStep(restores: [restore]).apply().failures.isEmpty)
        let read = try XCTUnwrap(ContainerFileStore.load(directory: box).document)
        XCTAssertEqual(read, ContainerFile(), "an empty document: the store deletes nothing")
        XCTAssertEqual(shown(.container, read), ["-", "-", "-", "-", "-", "-"])
    }

    func testUndoOfAStandardNamePutsTheNamesFileBack() throws {
        let tree = root.resolvingSymlinksInPath()
        let names = ContainerEdits.setStandardName("Box 1", for: "B. 1", field: .container, in: ContainerNames(), at: now)
        let first = try ContainerFileStore.writeNames(names, root: tree, expecting: nil)
        guard case let .loaded(original, _) = ContainerFileStore.loadNames(root: tree) else { return XCTFail() }
        let renamed = ContainerEdits.setStandardName("Box One", for: "B. 1", field: .container, in: original, at: now)
        let wrote = try ContainerFileStore.writeNames(renamed, root: tree, expecting: first)
        let step = ContainerUndoStep(restores: [ContainerDocumentRestore(folder: tree, restore: .names(original),
                                                                         expecting: wrote)])
        let undone = step.apply()
        XCTAssertTrue(undone.failures.isEmpty)
        XCTAssertEqual(ContainerFileStore.loadNames(root: tree).document, original)
        XCTAssertTrue(undone.inverse.apply().failures.isEmpty)
        XCTAssertEqual(ContainerFileStore.loadNames(root: tree).document?.names, renamed.names)
    }

    func testSetForSelectionAcrossFoldersWritesNothingWhenOneIsRefused() throws {
        let first = try makeFolder("Box 1")
        let second = try makeFolder("Box 2")
        let suite = second.appendingPathComponent(ContainerFile.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: suite, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion": 2, "runs": []}"#.utf8).write(to: suite.appendingPathComponent(ContainerFile.fileName))
        let before = try snapshot()
        XCTAssertThrowsError(try NavigationModel.setForSelection(.container, user("Box 5"),
                                                                 in: [(first, ["a.pdf"]), (second, ["a.pdf"])])) {
            XCTAssertEqual($0 as? ContainerWriteError, .refusedExisting(ContainerFile.fileName))
        }
        XCTAssertEqual(try snapshot(), before, "the first folder was not written either")
    }

    func testSetForSelectionAcrossFoldersUndoesAsOneStep() throws {
        let first = try makeFolder("Box 1")
        let second = try makeFolder("Box 2")
        try ContainerFileStore.write(boxAndFolder, directory: second, expecting: nil)
        let original = ContainerFileStore.load(directory: second).document
        let step = try XCTUnwrap(try NavigationModel.setForSelection(
            .container, user("Box 5"), in: [(first, ["b.pdf"]), (second, ["c.pdf", "d.pdf"])]))
        XCTAssertEqual(step.restores.count, 2)
        XCTAssertEqual(shown(.container, try XCTUnwrap(ContainerFileStore.load(directory: second).document)),
                       ["Box 1", "Box 1", "Box 5", "Box 5", "Box 1", "Box 1"])
        XCTAssertTrue(step.apply().failures.isEmpty)
        XCTAssertEqual(ContainerFileStore.load(directory: first).document, ContainerFile())
        XCTAssertEqual(ContainerFileStore.load(directory: second).document, original)
    }

    func testAWriteFailingPartwayPutsBackTheFoldersAlreadyWritten() throws {
        let first = try makeFolder("Box 1")
        let second = try makeFolder("Box 2")
        try ContainerFileStore.write(boxAndFolder, directory: first, expecting: nil)
        let original = ContainerFileStore.load(directory: first).document
        let prepared = try [first, second].compactMap {
            try NavigationModel.prepareSetForSelection(.container, user("Box 5"), selected: ["b.pdf"], in: $0)
        }
        XCTAssertEqual(prepared.count, 2)
        // Another app writes the second folder after it was read.
        try ContainerFileStore.write(boxAndFolder, directory: second, expecting: nil)
        XCTAssertThrowsError(try NavigationModel.commitAll(prepared)) { error in
            let rolled = error as? ContainerSelectionRolledBack
            XCTAssertEqual(rolled?.written, 1)
            XCTAssertEqual(rolled?.notRestored.count, 0)
            XCTAssertEqual(rolled?.underlying as? ContainerWriteError, .changedSinceRead)
            XCTAssertTrue(containerEditWriteMessage(error).hasPrefix("Nothing was saved"))
        }
        XCTAssertEqual(ContainerFileStore.load(directory: first).document, original, "the first folder is put back")
    }

    // MARK: The catalog's editor state

    func testTheEditorSaysWhereAnEditGoesAndListsTheFoldersWarnings() throws {
        let box = try makeBox()
        try ContainerFileStore.writeLevelMap(ContainerLevelMap(levels: [.box]), root: root.resolvingSymlinksInPath(),
                                             expecting: nil)
        try ContainerFileStore.write(ContainerFile(runs: [
            ContainerRun(start: "c.pdf", level: .box, fields: ContainerFieldSet([.container: label("Box 18")])),
            ContainerRun(start: "d.pdf", level: .folder, fields: ContainerFieldSet([.folder: user("3")])),
        ]), directory: box, expecting: nil)
        let rootPath = root.path
        let paths = names.map { rootPath + "/Box 17/" + $0 }
        let catalog = ContainerCatalog.build(treeRoot: root, rootPath: rootPath, filePaths: paths)
        let a = try XCTUnwrap(catalog.editor(forPath: paths[0]))
        XCTAssertEqual(a.scopes[.container], "a new box from “a.pdf” to the next, 2 listed files",
                       "a gap before the box photo: a run of its own")
        XCTAssertEqual(a.scopes[.repository], "every file in this folder and the folders inside it")
        XCTAssertTrue(a.unconfirmed.contains(.container), "a folder name is not the user's")
        XCTAssertEqual(a.written[.container], "Box 17")
        let d = try XCTUnwrap(catalog.editor(forPath: paths[3]))
        XCTAssertEqual(d.scopes[.container], "the box from “c.pdf” on, 4 listed files")
        XCTAssertEqual(d.scopes[.folder], "the folder from “d.pdf” on, 3 listed files")
        XCTAssertEqual(d.userHeld, [.folder])
        XCTAssertFalse(d.unconfirmed.contains(.folder))
        XCTAssertEqual(d.warnings.first?.text, "The sources disagree on container: 4 files from “c.pdf”.")
        XCTAssertEqual(d.warnings.first?.startPath, rootPath + "/Box 17/c.pdf")
        XCTAssertNil(catalog.editor(forPath: "/elsewhere/x.pdf"))
    }
}
