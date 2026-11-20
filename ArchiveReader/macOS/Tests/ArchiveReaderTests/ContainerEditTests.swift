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
        XCTAssertEqual(ContainerEdits.selectionFields, ContainerField.allCases, "dates and other marks too")
    }

    // MARK: Set for selection without limits (W49.reader-set-selection-limits)

    func testADateSetForASelectionIsAFolderRunsDateForThemAlone() throws {
        let file = ContainerFile(runs: [
            ContainerRun(start: "a.pdf", level: .box, fields: ContainerFieldSet([.container: label("Box 1"),
                                                                                  .date: label("1950-1960")])),
            ContainerRun(start: "e.pdf", level: .folder, fields: ContainerFieldSet([.folder: label("3"),
                                                                                     .date: user("1958")])),
        ])
        let edited = try XCTUnwrap(ContainerEdits.setForSelection(.date, to: user("1953"), group: ["b.pdf", "c.pdf"],
                                                                  after: "d.pdf", in: file))
        XCTAssertEqual(shown(.date, edited), ["1950-1960", "1953", "1953", "1950-1960", "1958", "1958"])
        XCTAssertEqual(shown(.container, edited), Array(repeating: "Box 1", count: 6))
        XCTAssertEqual(shown(.folder, edited), ["-", "-", "-", "-", "3", "3"])
        XCTAssertEqual(ContainerFolderDate.confirmed(at: "c.pdf", in: edited.runs)?.text, "1953",
                       "a folder run's own date, so the folder-date rule reads it")
        XCTAssertNil(ContainerFolderDate.confirmed(at: "d.pdf", in: edited.runs))

        let marks = try XCTUnwrap(ContainerEdits.setForSelection(.other, to: user("Restricted"),
                                                                 group: ["e.pdf"], after: "f.pdf", in: file))
        XCTAssertEqual(shown(.other, marks), ["-", "-", "-", "-", "Restricted", "-"])
        XCTAssertEqual(shown(.date, marks), ["1950-1960", "1950-1960", "1950-1960", "1950-1960", "1958", "1958"],
                       "the folder run's date is carried across the split")
    }

    /// The one-pass edit of every group is the groups' edits made one after another, as the editor did before
    /// (`referenceSetForSelection`), on many generated folders, for every field.
    func testSetForManyGroupsAtOnceIsTheGroupsEditsInTurn() throws {
        var seed: UInt64 = 0x5EED
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        let names = (1...24).map { "p\($0).pdf" }
        let values = ["A", "B", "C"]
        for round in 0..<300 {
            var runs: [ContainerRun] = []
            for _ in 0..<next(9) {
                var fields = ContainerFieldSet()
                for _ in 0..<next(4) {
                    let f = ContainerField.allCases[next(ContainerField.allCases.count)]
                    let v = values[next(values.count)]
                    fields[f] = next(2) == 0 ? label(v) : user(v)
                }
                // Starts on files and between them ("p5a.pdf" sorts after p5), as a run need not start at a file.
                let start = names[next(names.count)].replacingOccurrences(of: ".pdf", with: next(4) == 0 ? "a.pdf" : ".pdf")
                runs.append(ContainerRun(start: start, level: ContainerLevel.allCases[next(3)], fields: fields))
            }
            let file = ContainerFile(runs: runs)
            let selected = Set(names.filter { _ in next(3) == 0 })
            guard !selected.isEmpty else { continue }
            let groups = ContainerEdits.selectionGroups(selected: selected, fileNames: names)
            for field in ContainerField.allCases {
                let value = user("set")
                let once = try XCTUnwrap(ContainerEdits.setForSelection(field, to: value, groups: groups, in: file))
                var inTurn = file
                for group in groups {
                    inTurn = try XCTUnwrap(Self.referenceSetForSelection(field, to: value, group: group.names,
                                                                         after: group.after, in: inTurn))
                }
                XCTAssertEqual(once.runs, inTurn.runs, "round \(round), \(field)")
                for name in names {
                    XCTAssertEqual(ContainerResolver.resolve(fileName: name, scopes: [ContainerScope(file: once)]).values,
                                   ContainerResolver.resolve(fileName: name, scopes: [ContainerScope(file: inTurn)]).values)
                    let shownValue = ContainerResolver.resolve(fileName: name, scopes: [ContainerScope(file: once)])
                        .values[field]
                    if selected.contains(name) { XCTAssertEqual(shownValue, value, "round \(round), \(field), \(name)") }
                }
            }
        }
    }

    func testTenThousandScatteredGroupsAreSetInOnePass() throws {
        let names = (1...20_000).map { "page \($0).pdf" }
        let selected = Set(names.enumerated().filter { $0.offset % 2 == 0 }.map(\.element))
        let file = ContainerFile(runs: [
            ContainerRun(start: "page 1.pdf", level: .box, fields: ContainerFieldSet([.container: label("Box 1")])),
        ])
        let groups = ContainerEdits.selectionGroups(selected: selected, fileNames: names)
        XCTAssertEqual(groups.count, 10_000)
        let started = Date()
        let edited = try XCTUnwrap(ContainerEdits.setForSelection(.container, to: user("Box 2"), groups: groups,
                                                                  in: file))
        XCTAssertLessThan(Date().timeIntervalSince(started), 20, "one pass, not one per group")
        XCTAssertEqual(edited.runs.count, 20_000, "the box run at page 1 is the first group's own; one run after each")
        for name in ["page 1.pdf", "page 2.pdf", "page 9999.pdf", "page 20000.pdf"] {
            XCTAssertEqual(ContainerResolver.resolve(fileName: name, scopes: [ContainerScope(file: edited)]).shown(.container),
                           selected.contains(name) ? "Box 2" : "Box 1", name)
        }
    }

    /// The editor's set for selection before W49.reader-set-selection-limits, one group at a time, with the level
    /// "set for selection" now gives `date` and `other`.
    private static func referenceSetForSelection(_ field: ContainerField, to value: ContainerValue, group: [String],
                                                 after: String?, in file: ContainerFile) -> ContainerFile? {
        let level = ContainerEdits.selectionLevel(field)
        guard let first = group.first, let last = group.last else { return nil }
        let old = file.runs
        var points = [first]
        for run in old where run.level <= level && ContainerOrder.precedes(first, run.start)
            && ContainerOrder.atOrBefore(run.start, last) && !points.contains(run.start) {
            points.append(run.start)
        }
        var runs = old
        func ensureCopies(at point: String) {
            let live = ContainerResolver.liveRuns(at: point, in: old)
            if !runs.contains(where: { $0.start == point && $0.level == level }) {
                var fields = live.first { $0.level == level }?.fields ?? ContainerFieldSet()
                if !live.contains(where: { $0.level == level }) {
                    let held = ContainerResolver.runValues(live.filter { $0.level < level })
                    for (f, values) in held where f.homeLevel.map({ $0 >= level }) ?? false {
                        let usable = values.filter { $0.source == .user || $0.shown != nil }
                        fields[f] = usable.reduce(nil as ContainerValue?) { best, v in
                            best.map { v.source > $0.source ? v : $0 } ?? v
                        }
                    }
                }
                runs.append(ContainerRun(start: point, level: level, fields: fields))
            }
            for deeper in live where deeper.level > level && !runs.contains(where: { $0.start == point && $0.level == deeper.level }) {
                runs.append(ContainerRun(start: point, level: deeper.level, fields: deeper.fields))
            }
        }
        if let after, !old.contains(where: { $0.start == after && $0.level <= level }) { ensureCopies(at: after) }
        for point in points { ensureCopies(at: point) }
        runs = runs.map { run in
            guard ContainerOrder.atOrBefore(first, run.start), ContainerOrder.atOrBefore(run.start, last) else { return run }
            var run = run
            if run.level == level { run.fields[field] = value }
            else if run.level > level { run.fields[field] = nil }
            return run
        }
        var edited = file
        edited.runs = runs
        return edited
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
        // W49.reader-ct-set-aside: a newer document is refused outright; the others are offered for setting aside.
        let cases: [(String, (Error) -> Bool)] = [
            (#"{"schemaVersion": 2, "runs": []}"#, { ($0 as? ContainerWriteError) == .refusedExisting(ContainerFile.fileName) }),
            (#"{"schemaVersion": 1, "runs": [], "future": 1}"#,
             { ($0 as? ContainerSetAsideNeeded)?.reason == .drops(runs: 0, values: 0) }),
            ("{ no", { ($0 as? ContainerSetAsideNeeded)?.reason == .unreadable("no schemaVersion") }),
        ]
        for (bytes, expected) in cases {
            try Data(bytes.utf8).write(to: doc)
            var called = false
            XCTAssertThrowsError(try NavigationModel.editContainerFile(at: box) { file in
                called = true
                return ContainerEdits.set(.container, to: self.user("Box 9"), at: .directory, in: file)
            }) { XCTAssertTrue(expected($0), "\(bytes): \($0)") }
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

    func testSetForSelectionTakesMoreThanFiveThousandFilesInOneWrite() throws {
        let box = root.appendingPathComponent("Box 9", isDirectory: true)
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        let names = (1...6_000).map { "page \($0).pdf" }
        for name in names { FileManager.default.createFile(atPath: box.appendingPathComponent(name).path, contents: nil) }
        let selected = Set(names.prefix(5_500))
        XCTAssertNotNil(try NavigationModel.setForSelection(.date, user("1961"), selected: selected, in: box))
        let read = try XCTUnwrap(ContainerFileStore.load(directory: box).document)
        for name in ["page 1.pdf", "page 5500.pdf", "page 5501.pdf", "page 6000.pdf"] {
            XCTAssertEqual(ContainerResolver.resolve(fileName: name, scopes: [ContainerScope(file: read)]).shown(.date),
                           selected.contains(name) ? "1961" : nil, name)
        }
    }

    /// W49.reader-set-selection-date-offer: a date set for a selection notes every run it is in, each by its first
    /// selected file: one per stretch of neighbours, and one more where a run of the folder starts inside a stretch.
    func testADateSetForASelectionNotesEveryRunItIsIn() throws {
        let box = try makeBox()
        try ContainerFileStore.write(ContainerFile(runs: [
            ContainerRun(start: "a.pdf", level: .folder, fields: ContainerFieldSet([.date: user("1950")])),
            ContainerRun(start: "d.pdf", level: .folder, fields: ContainerFieldSet([.date: user("1960")])),
        ]), directory: box, expecting: nil)
        let split = FolderDateSelection()
        _ = try NavigationModel.setForSelection(.date, user("1953"), in: [(box, ["b.pdf", "c.pdf", "d.pdf", "e.pdf"])],
                                                noting: split)
        XCTAssertEqual(split.runs[box.path], [.init(name: "b.pdf", datedBefore: true), .init(name: "d.pdf", datedBefore: true)],
                       "the run at d.pdf splits the selection in two")
        let gaps = FolderDateSelection()
        let before = try XCTUnwrap(ContainerFileStore.load(directory: box).document)
        _ = try NavigationModel.setForSelection(.date, user("1954"), in: [(box, ["a.pdf", "c.pdf", "f.pdf"])],
                                                noting: gaps)
        XCTAssertEqual(gaps.runs[box.path]?.map(\.name), ["a.pdf", "c.pdf", "f.pdf"], "three stretches, three runs")
        let read = try XCTUnwrap(ContainerFileStore.load(directory: box).document)
        XCTAssertEqual(shown(.date, read), ["1954", "1953", "1954", "1953", "1953", "1954"])
        // Undo of that edit offers for the same runs: the first file of each whose date changed.
        let names = ["a.pdf", "b.pdf", "c.pdf", "d.pdf", "e.pdf", "f.pdf"]
        XCTAssertEqual(NavigationModel.datedRunsChanged(names, before: read.runs, after: before.runs).map(\.name),
                       ["a.pdf", "c.pdf", "f.pdf"])
        XCTAssertEqual(NavigationModel.datedRunsChanged(names, before: read.runs, after: read.runs).count, 0)
        // The batch run lookup reads as the one-file one.
        let tree = box.deletingLastPathComponent()
        let batch = try XCTUnwrap(NavigationModel.folderDateRuns(tree: tree, components: [box.lastPathComponent],
                                                                 editedNames: names))
        for (name, run) in zip(names, batch) {
            let one = try XCTUnwrap(NavigationModel.folderDateRun(tree: tree, components: [box.lastPathComponent],
                                                                  editedName: name))
            XCTAssertEqual(run.names, one.names, name)
            XCTAssertEqual(run.date, one.date, name)
        }
        XCTAssertEqual(batch.map(\.names), [["a.pdf"], ["b.pdf"], ["c.pdf"], ["d.pdf", "e.pdf"], ["d.pdf", "e.pdf"], ["f.pdf"]])
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

    /// Two edits in one folder, undone in turn: the first undo rewrites the file with the first edit's content and a
    /// new stamp, and the second still goes ahead; Redo then takes both forward again.
    func testTwoEditsInOneFolderAreUndoneInTurn() throws {
        let box = try makeBox()
        let first = try XCTUnwrap(try NavigationModel.editContainerFile(at: box) { file in
            ContainerEdits.set(.container, to: self.user("Box 9"), at: .directory, in: file)
        })
        let second = try XCTUnwrap(try NavigationModel.editContainerFile(at: box) { file in
            ContainerEdits.set(.folder, to: self.user("3"), at: .directory, in: file)
        })
        let undoSecond = ContainerUndoStep(restores: [second]).apply()
        XCTAssertTrue(undoSecond.failures.isEmpty)
        let undoFirst = ContainerUndoStep(restores: [first]).apply()
        XCTAssertTrue(undoFirst.failures.isEmpty, "the first edit's file is still its own: \(undoFirst.failures)")
        XCTAssertEqual(ContainerFileStore.load(directory: box).document?.directory, ContainerFieldSet())
        XCTAssertTrue(undoFirst.inverse.apply().failures.isEmpty)
        XCTAssertTrue(undoSecond.inverse.apply().failures.isEmpty)
        let read = try XCTUnwrap(ContainerFileStore.load(directory: box).document)
        XCTAssertEqual(read.directory[.container]?.value, "Box 9")
        XCTAssertEqual(read.directory[.folder]?.value, "3")
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
                                                                         expecting: wrote,
                                                                         written: .names(renamed))])
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

    // MARK: Setting aside (W49.reader-ct-set-aside)

    /// A document holding a value this build drops, beside one run it reads.
    private let dropping = #"{"schemaVersion": 1, "future": {"x": 1}, "runs": [{"start": "a.pdf", "level": "box", "#
        + #""fields": {"container": {"value": "Box 1", "source": "label"}}}]}"#

    private func consenting<T>(_ directory: URL, _ name: String = ContainerFile.fileName,
                               _ work: () throws -> T) rethrows -> T {
        try ContainerSetAsideConsent.$paths.withValue([ContainerSetAsideNeeded.documentPath(directory, name)]) {
            try work()
        }
    }

    /// The files in `.archivesuite` and their bytes.
    private func suiteFiles(_ directory: URL) throws -> [String: String] {
        let suite = directory.appendingPathComponent(ContainerFile.folderName, isDirectory: true)
        var out: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: suite.path) {
            out[name] = try String(contentsOf: suite.appendingPathComponent(name), encoding: .utf8)
        }
        return out
    }

    /// Every file outside any `.archivesuite`, from `snapshot`.
    private func outsideSuite() throws -> [String: String] {
        try snapshot().filter { !$0.key.contains("/\(ContainerFile.folderName)") }
    }

    func testWithConsentADroppingDocumentIsSetAsideAndWhatReadsIsKept() throws {
        let box = try makeBox()
        let suite = box.appendingPathComponent(ContainerFile.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: suite, withIntermediateDirectories: true)
        try Data(dropping.utf8).write(to: suite.appendingPathComponent(ContainerFile.fileName))
        let outside = try outsideSuite()
        XCTAssertThrowsError(try NavigationModel.editContainerFile(at: box) { file in
            ContainerEdits.set(.folder, to: self.user("3"), at: .directory, in: file)
        }) { XCTAssertEqual(($0 as? ContainerSetAsideNeeded)?.reason, .drops(runs: 1, values: 1)) }
        // Consent for another folder's file is not consent for this one.
        try consenting(root) {
            XCTAssertThrowsError(try NavigationModel.editContainerFile(at: box) { file in
                ContainerEdits.set(.folder, to: self.user("3"), at: .directory, in: file)
            })
        }
        XCTAssertEqual(try suiteFiles(box), [ContainerFile.fileName: dropping], "untouched")

        let restore = try XCTUnwrap(try consenting(box) {
            try NavigationModel.editContainerFile(at: box) { file in
                ContainerEdits.set(.folder, to: self.user("3"), at: .directory, in: file)
            }
        })
        let files = try suiteFiles(box)
        XCTAssertEqual(files.count, 2)
        let aside = try XCTUnwrap(files.keys.first { $0.hasPrefix("\(ContainerFile.fileName).set-aside-") })
        XCTAssertEqual(files[aside], dropping, "the old document is renamed, not deleted")
        let written = try XCTUnwrap(ContainerFileStore.load(directory: box).document)
        XCTAssertEqual(written.directory[.folder]?.value, "3")
        XCTAssertEqual(written.runs.first?.fields[.container]?.value, "Box 1", "what reads carries over")
        XCTAssertEqual(try outsideSuite(), outside, "nothing outside .archivesuite changed")

        // Undo puts the set-aside document back (the one written takes its name); Redo swaps them again.
        let undone = ContainerUndoStep(restores: [restore]).apply()
        XCTAssertTrue(undone.failures.isEmpty)
        let afterUndo = try suiteFiles(box)
        XCTAssertEqual(afterUndo[ContainerFile.fileName], dropping)
        XCTAssertEqual(afterUndo[aside], files[ContainerFile.fileName])
        XCTAssertEqual(afterUndo.count, 2)
        let redone = undone.inverse.apply()
        XCTAssertTrue(redone.failures.isEmpty)
        XCTAssertEqual(try suiteFiles(box), files)
        XCTAssertTrue(redone.inverse.apply().failures.isEmpty)
        XCTAssertEqual(try suiteFiles(box)[ContainerFile.fileName], dropping)
    }

    func testANewerDocumentIsNeverSetAsideEvenWithConsent() throws {
        let box = try makeBox()
        let suite = box.appendingPathComponent(ContainerFile.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: suite, withIntermediateDirectories: true)
        let newer = #"{"schemaVersion": 2, "runs": []}"#
        try Data(newer.utf8).write(to: suite.appendingPathComponent(ContainerFile.fileName))
        try consenting(box) {
            XCTAssertThrowsError(try NavigationModel.editContainerFile(at: box) { file in
                ContainerEdits.set(.folder, to: self.user("3"), at: .directory, in: file)
            }) { XCTAssertEqual($0 as? ContainerWriteError, .refusedExisting(ContainerFile.fileName)) }
        }
        XCTAssertEqual(try suiteFiles(box), [ContainerFile.fileName: newer])
    }

    func testUndoOfASetAsideStillWorksAfterALaterEditIsUndone() throws {
        let box = try makeBox()
        let suite = box.appendingPathComponent(ContainerFile.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: suite, withIntermediateDirectories: true)
        try Data("{ no".utf8).write(to: suite.appendingPathComponent(ContainerFile.fileName))
        let first = try XCTUnwrap(try consenting(box) {
            try NavigationModel.editContainerFile(at: box) { file in
                ContainerEdits.set(.folder, to: self.user("3"), at: .directory, in: file)
            }
        })
        let second = try XCTUnwrap(try NavigationModel.editContainerFile(at: box) { file in
            ContainerEdits.set(.folder, to: self.user("4"), at: .directory, in: file)
        })
        XCTAssertTrue(ContainerUndoStep(restores: [second]).apply().failures.isEmpty)
        XCTAssertTrue(ContainerUndoStep(restores: [first]).apply().failures.isEmpty,
                      "the file holds what the set-aside edit wrote, under a new stamp")
        XCTAssertEqual(try suiteFiles(box)[ContainerFile.fileName], "{ no")
        XCTAssertEqual(try suiteFiles(box).count, 2, "nothing deleted")
    }

    func testUndoOfASetAsideLeavesAFileAnotherAppChangedAlone() throws {
        let box = try makeBox()
        let suite = box.appendingPathComponent(ContainerFile.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: suite, withIntermediateDirectories: true)
        try Data("{ no".utf8).write(to: suite.appendingPathComponent(ContainerFile.fileName))
        let restore = try XCTUnwrap(try consenting(box) {
            try NavigationModel.editContainerFile(at: box) { file in
                ContainerEdits.set(.folder, to: self.user("3"), at: .directory, in: file)
            }
        })
        guard case let .loaded(_, stamp) = ContainerFileStore.load(directory: box) else { return XCTFail() }
        try ContainerFileStore.write(boxAndFolder, directory: box, expecting: stamp)
        let before = try suiteFiles(box)
        let undone = ContainerUndoStep(restores: [restore]).apply()
        XCTAssertEqual(undone.failures.count, 1)
        XCTAssertEqual(undone.failures.first?.error as? ContainerWriteError, .changedSinceRead)
        XCTAssertEqual(try suiteFiles(box), before)
    }

    func testAnUnreadableStandardNamesFileNearerTheFolderIsOfferedAndPutBack() throws {
        let tree = root.resolvingSymlinksInPath()
        let box = try makeBox()
        try ContainerFileStore.writeNames(ContainerNames(), root: tree, expecting: nil)
        let suite = box.appendingPathComponent(ContainerFile.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: suite, withIntermediateDirectories: true)
        let strict = #"{"schemaVersion": 1, "names": [], "colour": "red"}"#
        try Data(strict.utf8).write(to: suite.appendingPathComponent(ContainerNames.fileName))
        let near = try NavigationModel.nearestNamesRoot(tree, ["Box 17"])
        XCTAssertEqual(near.path, box.path, "the nearer file, not the root's")

        XCTAssertThrowsError(try NavigationModel.setStandardName("Box 1", for: "B. 1", field: .container,
                                                                 root: near, at: now)) {
            let needed = $0 as? ContainerSetAsideNeeded
            XCTAssertEqual(needed?.fileName, ContainerNames.fileName)
            XCTAssertEqual(needed?.directory.path, box.path)
        }
        let step = try XCTUnwrap(try consenting(box, ContainerNames.fileName) {
            try NavigationModel.setStandardName("Box 1", for: "B. 1", field: .container, root: near, at: now)
        })
        XCTAssertEqual(ContainerFileStore.loadNames(root: box).document?.names.count, 1)
        let aside = try XCTUnwrap(try suiteFiles(box).first { $0.key.hasPrefix("\(ContainerNames.fileName).set-aside-") })
        XCTAssertEqual(aside.value, strict)
        XCTAssertTrue(step.apply().failures.isEmpty)
        XCTAssertEqual(try suiteFiles(box)[ContainerNames.fileName], strict)
    }

    func testTheOfferNamesTheFileWhatReadsAndTheRename() {
        let dir = URL(fileURLWithPath: "/tmp/Box 17")
        let drops = ContainerSetAsideNeeded(directory: dir, fileName: ContainerFile.fileName,
                                            reason: .drops(runs: 2, values: 5))
        XCTAssertTrue(drops.offerMessage.contains("“Box 17/.archivesuite/containers.json”"))
        XCTAssertTrue(drops.offerMessage.contains("2 runs and 5 values"))
        XCTAssertTrue(drops.offerMessage.contains("containers.json.set-aside-"))
        XCTAssertTrue(drops.offerMessage.contains("never deleted"))
        XCTAssertTrue(drops.offerMessage.contains("Undo puts it back"))
        let unreadable = ContainerSetAsideNeeded(directory: dir, fileName: ContainerNames.fileName,
                                                 reason: .unreadable("no schemaVersion"))
        XCTAssertTrue(unreadable.offerMessage.contains("no schemaVersion"))
        XCTAssertTrue(unreadable.offerMessage.contains("None of it carries over"))
        let failure = ContainerEditFailure(unreadable)
        XCTAssertEqual(failure.setAside, unreadable)
        XCTAssertEqual(failure.message, unreadable.refusal)
        XCTAssertNil(ContainerEditFailure(ContainerWriteError.refusedExisting(ContainerFile.fileName)).setAside)
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

    /// W49.reader-ct-warnings-all: every folder's warnings in one list, folders in path order, each with its folder.
    func testTheCatalogListsEveryFoldersWarningsWithTheirFolders() throws {
        let box = try makeBox()
        let other = root.appendingPathComponent("Box 9", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        for n in names { try Data("scratch fixture".utf8).write(to: other.appendingPathComponent(n)) }
        try ContainerFileStore.writeLevelMap(ContainerLevelMap(levels: [.box]), root: root.resolvingSymlinksInPath(),
                                             expecting: nil)
        try ContainerFileStore.write(ContainerFile(runs: [
            ContainerRun(start: "c.pdf", level: .box, fields: ContainerFieldSet([.container: label("Box 18")])),
        ]), directory: box, expecting: nil)
        try ContainerFileStore.write(ContainerFile(runs: [
            ContainerRun(start: "e.pdf", level: .box, fields: ContainerFieldSet([.container: label("Box 10")])),
        ]), directory: other, expecting: nil)
        let rootPath = root.path
        let paths = ["Box 17", "Box 9"].flatMap { dir in names.map { rootPath + "/\(dir)/" + $0 } }
        let catalog = ContainerCatalog.build(treeRoot: root, rootPath: rootPath, filePaths: paths)
        XCTAssertEqual(catalog.warnings.map(\.folder), ["Box 9", "Box 17"], "folders in the Finder's order")
        XCTAssertEqual(catalog.warnings.map(\.row.text), [
            "The sources disagree on container: 2 files from “e.pdf”.",
            "The sources disagree on container: 4 files from “c.pdf”.",
        ])
        XCTAssertEqual(catalog.warnings.map(\.row.startPath), [rootPath + "/Box 9/e.pdf", rootPath + "/Box 17/c.pdf"])
        let d = try XCTUnwrap(catalog.editor(forPath: paths[3]))
        XCTAssertEqual(d.warnings, [catalog.warnings[1].row], "the Inspector's list is the folder's part of it")
        XCTAssertEqual(ContainerCatalog.empty.warnings, [])
        XCTAssertEqual(ContainerFolderWarning(folder: "", row: catalog.warnings[0].row).folderName,
                       "The archive's main folder")
    }
}
