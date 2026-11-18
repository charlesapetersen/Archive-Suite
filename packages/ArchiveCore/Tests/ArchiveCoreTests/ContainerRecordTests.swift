import XCTest
@testable import ArchiveCore

/// The container record's inheritance rule, level map and CSL mapping (`SPEC/containers.md`, W47.ct-spec).
final class ContainerRecordTests: XCTestCase {
    private func label(_ s: String) -> ContainerValue { ContainerValue(s, source: .label, reader: "vision+parser") }
    private func user(_ s: String) -> ContainerValue { ContainerValue(s, source: .user) }
    private func path(_ s: String) -> ContainerValue { ContainerValue(s, source: .path) }
    private func run(_ start: String, _ level: ContainerLevel, _ f: [ContainerField: ContainerValue] = [:]) -> ContainerRun {
        ContainerRun(start: start, level: level, fields: ContainerFieldSet(f))
    }

    func testOrderIsFindersWithNumbersAsNumbers() {
        XCTAssertTrue(ContainerOrder.precedes("Glotzer 2.pdf", "Glotzer 10.pdf"))
        XCTAssertFalse(ContainerOrder.precedes("Glotzer 10.pdf", "Glotzer 2.pdf"))
        XCTAssertTrue(ContainerOrder.atOrBefore("a.pdf", "a.pdf"))
    }

    func testANewBoxEndsTheFolderRunAndAFolderRunNeverEndsTheBox() {
        let runs = [run("0001", .box), run("0002", .folder), run("0005", .folder), run("0009", .box)]
        XCTAssertEqual(ContainerResolver.liveRuns(at: "0001", in: runs).map(\.start), ["0001"])
        XCTAssertEqual(ContainerResolver.liveRuns(at: "0004", in: runs).map(\.start), ["0001", "0002"])
        XCTAssertEqual(ContainerResolver.liveRuns(at: "0007", in: runs).map(\.start), ["0001", "0005"])
        XCTAssertEqual(ContainerResolver.liveRuns(at: "0010", in: runs).map(\.start), ["0009"])
        XCTAssertEqual(ContainerResolver.liveRuns(at: "0000", in: runs), [])
    }

    func testARunBeginsWhereItsMissingStartWouldSort() {
        // The label photo "0003" is gone; the run still covers 0004 on.
        let runs = [run("0001", .box, [.container: label("Box 1")]), run("0003", .box, [.container: label("Box 2")])]
        let f = ContainerFile(runs: runs)
        XCTAssertEqual(ContainerResolver.resolve(fileName: "0002", scopes: [ContainerScope(file: f)]).shown(.container), "Box 1")
        XCTAssertEqual(ContainerResolver.resolve(fileName: "0004", scopes: [ContainerScope(file: f)]).shown(.container), "Box 2")
    }

    func testANewBoxClearsTheFolderAndTheContainerButKeepsTheCollection() {
        // The box label's collection title is stored at its home level, in the collection run live at that box.
        let f = ContainerFile(runs: [
            run("0001", .collection, [.collectionTitle: label("Irving Kristol Papers")]),
            run("0001", .box, [.container: label("Box 10"), .date: label("1946-2001"), .series: label("Series I")]),
            run("0002", .folder, [.folder: label("3"), .folderTitle: user("Reports")]),
            run("0009", .box, [:]),   // a box photo Vision read no number from
        ])
        let inFolder = ContainerResolver.resolve(fileName: "0004", scopes: [ContainerScope(file: f)])
        XCTAssertEqual(inFolder.shown(.container), "Box 10")
        XCTAssertEqual(inFolder.shown(.folder), "3")
        XCTAssertEqual(inFolder.shown(.date), "1946-2001", "a box's date reaches its folders")

        let next = ContainerResolver.resolve(fileName: "0010", scopes: [ContainerScope(file: f)])
        XCTAssertNil(next.shown(.container), "a new box with no read has no number, not the last box's")
        XCTAssertNil(next.shown(.folder))
        XCTAssertNil(next.shown(.folderTitle), "even a user's folder title belongs to its folder")
        XCTAssertNil(next.shown(.date), "date is the run's own")
        XCTAssertEqual(next.shown(.collectionTitle), "Irving Kristol Papers", "collection fields carry across boxes")
        XCTAssertNil(next.shown(.series), "a value held by a box run ends with that box")
    }

    func testADeeperRunMasksAShallowerRunsValueOfItsOwnLevel() {
        let f = ContainerFile(runs: [
            run("0001", .collection, [.container: label("Box 99"), .repository: label("Hoover")]),
            run("0002", .box, [.boxTitle: label("Subject file")]),
        ])
        let r = ContainerResolver.resolve(fileName: "0003", scopes: [ContainerScope(file: f)])
        XCTAssertNil(r.shown(.container))
        XCTAssertEqual(r.shown(.repository), "Hoover")
        XCTAssertEqual(r.shown(.boxTitle), "Subject file")
    }

    func testUserOverLabelOverPathAndTheMostSpecificWithinASource() {
        let own = ContainerScope(
            file: ContainerFile(directory: ContainerFieldSet([.repository: user("Hoover Institution Library & Archives")]),
                                runs: [run("0001", .box, [.container: label("Box 13"),
                                                          .repository: label("HOOVER INSTITUTION ARCHIVES")])]),
            pathFields: ContainerFieldSet([.container: path("Box 12"), .collectionTitle: path("Glotzer")]))
        let parent = ContainerScope(pathFields: ContainerFieldSet([.repository: path("Hoover"),
                                                                   .collectionTitle: path("Outer")]))
        let r = ContainerResolver.resolve(fileName: "0002", scopes: [own, parent])
        XCTAssertEqual(r.shown(.repository), "Hoover Institution Library & Archives", "user wins from a directory")
        XCTAssertEqual(r.shown(.container), "Box 13", "a label beats the tree")
        XCTAssertEqual(r.shown(.collectionTitle), "Glotzer", "the nearer path wins among paths")
        XCTAssertEqual(Set(r.disagreements), [.repository, .container, .collectionTitle])
    }

    func testAUsersEmptyValueHidesEveryOtherSource() {
        let f = ContainerFile(directory: ContainerFieldSet([.series: user("")]),
                              runs: [run("0001", .box, [.series: label("Series II")])])
        let r = ContainerResolver.resolve(fileName: "0001", scopes: [ContainerScope(file: f)])
        XCTAssertEqual(r.values[.series]?.source, .user)
        XCTAssertNil(r.shown(.series))
    }

    func testRunsCoverOnlyTheirOwnDirectory() {
        let parent = ContainerScope(file: ContainerFile(runs: [run("0001", .box, [.container: label("Box 4")])]))
        let r = ContainerResolver.resolve(fileName: "0005", scopes: [ContainerScope(), parent])
        XCTAssertNil(r.shown(.container))
    }

    func testConfirmingAProposalMakesItTheUsersAndKeepsItsReader() {
        let v = ContainerValue("Mss 1036", source: .label, reader: "gpt-5.6-luna", confidence: 1.7).confirmed()
        XCTAssertEqual(v.source, .user)
        XCTAssertEqual(v.reader, "gpt-5.6-luna")
        XCTAssertEqual(v.confidence, 1, "confidence is clamped to 0...1")
    }

    func testNormalisedKeepsTheFirstOfADuplicateAndSortsShallowFirstAtOneStart() {
        let runs = ContainerFile.normalised([run("0002", .folder, [.folder: label("1")]), run("0002", .box),
                                             run("0002", .folder, [.folder: label("2")]), run("", .box),
                                             run("0001", .box)])
        XCTAssertEqual(runs.map { "\($0.start)/\($0.level.rawValue)" }, ["0001/box", "0002/box", "0002/folder"])
        XCTAssertEqual(runs[2].fields[.folder]?.value, "1")
    }

    func testLenientDecodingDropsWhatItDoesNotKnow() throws {
        let json = """
        {"schemaVersion": 1, "directory": {"fields": {"repository": {"value": "Hoover", "source": "user"},
          "shelf": {"value": "x", "source": "user"}, "place": {"value": "Stanford", "source": "oracle"}}},
         "runs": [{"start": "0001", "level": "box", "fields": {"container": {"value": "Box 1", "source": "label",
          "at": "2026-11-17T10:00:00.123Z"}}},
                  {"start": "0002", "level": "drawer"}, {"start": "0003", "level": "folder"}],
         "updatedAt": "2026-11-17T10:00:00Z"}
        """
        let f = try ContainerFileStore.decoder.decode(ContainerFile.self, from: Data(json.utf8))
        XCTAssertEqual(f.directory.values.keys.sorted { $0.rawValue < $1.rawValue }, [.repository])
        XCTAssertEqual(f.runs.map(\.start), ["0001", "0003"])
        XCTAssertNotNil(f.runs[0].fields[.container]?.at, "fractional seconds read")
        XCTAssertNotNil(f.updatedAt)
    }

    func testFieldVocabularyMatchesTheBench() {
        // `ct_truth.py` FIELDS_REV, in its order.
        XCTAssertEqual(ContainerField.allCases.map(\.benchName),
                       ["repository", "place", "collection_title", "collection_subtitle", "collection_number",
                        "accession", "series", "series_title", "container", "box_title", "folder", "folder_title",
                        "date", "other"])
    }

    // MARK: The level map

    func testLevelsByDepthAndPastTheMapNothing() {
        let map = ContainerLevelMap(levels: [.repository, .collection, .box, .folder])
        XCTAssertEqual(map.roles(for: ["Hoover", "Glotzer", "Box 17", "Folder 8", "loose"]),
                       [.repository, .collection, .box, .folder, nil])
    }

    func testAWorkflowFolderDoesNotCountAndChildrenCanRestartTheCount() {
        let map = ContainerLevelMap(levels: [.repository, .collection, .ignore, .box],
                                    overrides: ["05 Final Tagging": .init(role: .ignore),
                                                "05 Final Tagging/5 Priority 5": .init(role: .ignore, children: .collection),
                                                "Hoover/Odd one": .init(role: .box)])
        XCTAssertEqual(map.roles(for: ["05 Final Tagging", "Hoover", "Glotzer"]), [.ignore, .repository, .collection])
        XCTAssertEqual(map.roles(for: ["05 Final Tagging", "5 Priority 5", "Zschau", "Initial Accession", "Box 3"]),
                       [.ignore, .ignore, .collection, .ignore, .box])
        XCTAssertEqual(map.roles(for: ["Hoover", "Odd one", "inner"]), [.repository, .box, nil],
                       "an override continues after its own role in levels")
    }

    func testLevelMapDecodesAnUnknownLevelAsIgnoreKeepingItsDepth() throws {
        let json = #"{"schemaVersion": 1, "levels": ["repository", "shelf", "box"], "overrides": {"a": {"role": "nope"}, "b": {"role": "ignore"}}}"#
        let map = try ContainerFileStore.decoder.decode(ContainerLevelMap.self, from: Data(json.utf8))
        XCTAssertEqual(map.levels, [.repository, .ignore, .box])
        XCTAssertEqual(Array(map.overrides.keys), ["b"])
    }

    // MARK: CSL

    func testCSLVariablesAndNoteLines() {
        let f = ContainerFile(directory: ContainerFieldSet([
            .repository: user("Hoover Institution Archives"), .place: user("Stanford, CA"),
            .collectionTitle: user("Albert Glotzer papers"), .collectionSubtitle: user("Writings"),
            .collectionNumber: user("91006"), .accession: label("91006-10.V"), .series: label("Series II"),
            .seriesTitle: user("Manuscripts"), .date: label("1946"), .other: label("barcode")]),
            runs: [run("0001", .box, [.container: label("Box 17"), .boxTitle: user("Subject file")]),
                   run("0002", .folder, [.folder: label("8"), .folderTitle: user("Reports 1959-1960")])])
        let csl = ContainerCSL(ContainerResolver.resolve(fileName: "0003", scopes: [ContainerScope(file: f)]))
        XCTAssertEqual(csl.variables, [
            "archive": "Hoover Institution Archives", "archive-place": "Stanford, CA", "call-number": "91006",
            "archive_collection": "Albert Glotzer papers: Writings",
            "archive_location": "Box 17 (Subject file), Folder 8, Reports 1959-1960"])
        XCTAssertEqual(csl.noteLines, ["accession: 91006-10.V", "series: Series II, Manuscripts"])
    }

    func testCSLLeavesEmptyFieldsOutAndKeepsAFolderThatSaysWhatItIs() {
        let f = ContainerFile(runs: [run("0001", .folder, [.folder: label("f. 5")])])
        let csl = ContainerCSL(ContainerResolver.resolve(fileName: "0001", scopes: [ContainerScope(file: f)]))
        XCTAssertEqual(csl.variables, ["archive_location": "f. 5"])
        XCTAssertEqual(csl.noteLines, [])
    }
}
