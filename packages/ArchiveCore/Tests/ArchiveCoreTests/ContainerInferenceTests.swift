import XCTest
@testable import ArchiveCore

/// The inference, both routes (`SPEC/containers.md`; W47.ct-infer): the name patterns and the pre-filled level map
/// (Route B, scored against `ct_trees.json` as `ct_read.py trees` scores it), markers into runs (Route A), the mixed
/// case, and the warnings. The last test does it on a scratch tree through `ContainerFileStore`.
final class ContainerInferenceTests: XCTestCase {
    private func label(_ v: String) -> ContainerValue { ContainerValue(v, source: .label, reader: "vision+parser") }
    private func user(_ v: String) -> ContainerValue { ContainerValue(v, source: .user) }
    private func read(_ f: [ContainerField: String]) -> ContainerFieldSet { ContainerFieldSet(f.mapValues(label)) }
    private func values(_ s: ContainerFieldSet) -> [ContainerField: String] { s.values.mapValues(\.value) }

    // MARK: Name patterns

    func testDirectoryNamesSplitIntoFields() {
        let cases: [(String, ContainerLevelRole, [ContainerField: String])] = [
            ("Box 17", .box, [.container: "Box 17"]),
            ("box_017", .box, [.container: "Box 17"]),
            ("Bx 3 Fd 12", .box, [.container: "Box 3", .folder: "12"]),
            ("B17F8", .box, [.container: "Box 17", .folder: "8"]),
            ("Box 10 - Folder 3", .box, [.container: "Box 10", .folder: "3"]),
            ("Box 2, Folder 4 - Reports 1959", .folder, [.container: "Box 2", .folder: "4", .folderTitle: "Reports 1959"]),
            ("Carton 9", .box, [.container: "Carton 9"]),
            ("Box 3 - Subject file", .box, [.container: "Box 3", .boxTitle: "Subject file"]),
            ("Box 1-3", .box, [.container: "Box 1-3"]),
            ("ff. 1-20", .folder, [.folder: "1-20"]),
            ("Series Civil War", .series, [.series: "Series Civil War"]),
            ("Series 1950-1960 Reports", .series, [.series: "Series 1950-1960 Reports"]),
            ("MC 1968 Democratic Convention", .collection, [.collectionTitle: "MC 1968 Democratic Convention"]),
            ("MC 1968 - Democratic Convention", .collection, [.collectionNumber: "MC 1968",
                                                             .collectionTitle: "Democratic Convention"]),
            ("Oversize", .box, [.boxTitle: "Oversize"]),
            ("f. 5", .folder, [.folder: "5"]),
            ("Folder 08 - Correspondence", .folder, [.folder: "8", .folderTitle: "Correspondence"]),
            ("Correspondence 1950", .folder, [.folderTitle: "Correspondence 1950"]),
            ("Series II, Manuscripts", .series, [.series: "Series II", .seriesTitle: "Manuscripts"]),
            ("Subseries 3", .series, [.series: "Subseries 3"]),
            ("Entry 77", .series, [.series: "Entry 77"]),
            ("Accession 91006", .accession, [.accession: "91006"]),
            ("2005 Accession", .accession, [.accession: "2005"]),
            ("Irving Kristol papers, Mss 1036", .collection, [.collectionTitle: "Irving Kristol papers",
                                                              .collectionNumber: "Mss 1036"]),
            ("SC0122", .collection, [.collectionNumber: "SC0122"]),
            ("SC0122 Stanford News Service", .collection, [.collectionNumber: "SC0122",
                                                           .collectionTitle: "Stanford News Service"]),
            ("Papers of Talcott Parsons, HUG(FP) 15.2", .collection, [.collectionTitle: "Papers of Talcott Parsons",
                                                                     .collectionNumber: "HUG(FP) 15.2"]),
            ("Zschau", .collection, [.collectionTitle: "Zschau"]),
            ("Hoover Institution Archives", .repository, [.repository: "Hoover Institution Archives"]),
            ("05 Final Tagging", .ignore, [:]),
        ]
        for (name, role, want) in cases {
            let got = ContainerPatterns.fields(ofName: name, role: role)
            XCTAssertEqual(values(got), want, name)
            XCTAssertTrue(got.values.values.allSatisfy { $0.source == .path }, name)
        }
    }

    func testRoleGuesses() {
        let cases: [(String, ContainerLevelRole?)] = [
            ("05 Final Tagging", .ignore), ("Box 17", .box), ("B82", .box), ("B17F8", .box), ("Folio 3", .box),
            ("F15", .folder), ("folder_08", .folder), ("Series II", .series), ("Accession 91006", .accession),
            ("RG 165", .collection), ("Edward Shils papers", .collection), ("Wisconsin Historical Society", .repository),
            ("Zschau", nil), ("scans", nil), ("5 Priority 5", nil), ("Box 3 - Smith Papers", .collection),
        ]
        for (name, want) in cases { XCTAssertEqual(ContainerPatterns.role(ofName: name), want, name) }
    }

    func testFileNamesAndNoFolderSheets() {
        XCTAssertEqual(values(ContainerPatterns.fields(ofFileName: "Fromm, Box 2, Folder 4 - 0004.pdf")),
                       [.container: "Box 2", .folder: "4"])
        XCTAssertEqual(values(ContainerPatterns.fields(ofFileName: "Glotzer_bx_12_f_03.pdf")),
                       [.container: "Box 12", .folder: "3"])
        XCTAssertTrue(ContainerPatterns.fields(ofFileName: "IMG_0001.pdf").isEmpty)
        XCTAssertTrue(ContainerPatterns.fields(ofFileName: "Inbox 2 folder.pdf").isEmpty)
        XCTAssertTrue(ContainerPatterns.isNoFolderSheet("NO FOLDER"))
        XCTAssertTrue(ContainerPatterns.isNoFolderSheet("Box 4\nNo  folder"))
        XCTAssertFalse(ContainerPatterns.isNoFolderSheet("Folder 3: no foldering"))
    }

    // MARK: Route B on the scored tree set

    /// `ct_trees.json`, the Route B set `ct_read.py trees` scored 36 of 36 maps right: the Swift patterns must match.
    func testTreeSetLevelMapsAndFields() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../ArchiveProcessor/scripts/segbench/ct_trees.json").standardized
        struct Trees: Decodable {
            struct Tree: Decodable { let id: String; let levels: [String]; let files: [File] }
            struct File: Decodable { let path: String; let expect: [String: String] }
            let trees: [Tree]
        }
        let trees = try JSONDecoder().decode(Trees.self, from: Data(contentsOf: url)).trees
        XCTAssertGreaterThanOrEqual(trees.count, 36)
        let roleOf: [String: ContainerLevelRole] = ["repository": .repository, "collection": .collection,
                                                    "accession": .accession, "series": .series, "container": .box,
                                                    "container+folder": .box, "folder": .folder, "ignore": .ignore]
        let fieldOf = Dictionary(uniqueKeysWithValues: ContainerField.allCases.map { ($0.benchName, $0) })
        var fieldsRight = 0, fieldsAll = 0
        for tree in trees {
            let dirs = tree.files.map { Array($0.path.split(separator: "/").dropLast().map(String.init)) }
            let map = ContainerLevelMap.prefilled(directories: dirs)
            for (file, dir) in zip(tree.files, dirs) {
                XCTAssertEqual(map.roles(for: dir), tree.levels.prefix(dir.count).map { roleOf[$0] }, tree.id)
                let name = String(file.path.split(separator: "/").last!)
                let record = ContainerResolver.resolve(fileName: name, scopes: map.scopes(for: dir),
                                                       fileFields: ContainerPatterns.fields(ofFileName: name))
                let got = Dictionary(uniqueKeysWithValues: ContainerField.allCases.compactMap { f in
                    record.shown(f).map { (f, $0) }
                })
                let want = Dictionary(uniqueKeysWithValues: file.expect.map { (fieldOf[$0.key]!, $0.value) })
                for f in Set(got.keys).union(want.keys) {
                    fieldsAll += 1
                    if got[f].map(ContainerNames.key) == want[f].map(ContainerNames.key) {
                        fieldsRight += 1
                    } else {
                        XCTFail("\(tree.id) \(file.path) \(f): got \(got[f] ?? "nil"), want \(want[f] ?? "nil")")
                    }
                }
            }
        }
        XCTAssertEqual(fieldsRight, fieldsAll)
    }

    func testLevelMapWorkflowFoldersAreOverrides() {
        let dirs = [["05 Final Tagging", "Hoover Institution Archives", "Glotzer papers", "Box 1"],
                    ["Hoover Institution Archives", "Glotzer papers", "Box 2"]]
        let map = ContainerLevelMap.prefilled(directories: dirs)
        XCTAssertEqual(map.levels, [.repository, .collection, .box])
        XCTAssertEqual(map.overrides, ["05 Final Tagging": .init(role: .ignore)])
        XCTAssertEqual(map.roles(for: dirs[0]), [.ignore, .repository, .collection, .box])
        XCTAssertEqual(map.pathFields(for: dirs[0]).map(values),
                       [[:], [.repository: "Hoover Institution Archives"], [.collectionTitle: "Glotzer papers"],
                        [.container: "Box 1"]])
    }

    func testScopesRunFromTheFileUpToTheRoot() {
        let map = ContainerLevelMap(levels: [.repository, .box])
        let rootFile = ContainerFile(directory: ContainerFieldSet([.place: user("Stanford, CA")]))
        let scopes = map.scopes(for: ["Hoover", "Box 3"], files: [rootFile])
        XCTAssertEqual(scopes.count, 3)
        XCTAssertEqual(values(scopes[0].pathFields), [.container: "Box 3"])
        XCTAssertEqual(values(scopes[1].pathFields), [.repository: "Hoover"])
        XCTAssertEqual(scopes[2].file, rootFile)
        let r = ContainerResolver.resolve(fileName: "a.pdf", scopes: scopes)
        XCTAssertEqual(r.shown(.place), "Stanford, CA")
        XCTAssertEqual(r.shown(.container), "Box 3")
    }

    // MARK: Route A

    func testBoxAndFolderPhotosStartRunsAndCarryForward() {
        let markers = [
            ContainerMarker(fileName: "0001.pdf", type: .box,
                            read: read([.repository: "Hoover Institution Archives", .collectionTitle: "Albert Glotzer",
                                        .container: "Box 17", .date: "1950-1960"])),
            ContainerMarker(fileName: "0002.pdf", type: .folder,
                            read: read([.folder: "8", .folderTitle: "Reports", .container: "Box 99",
                                        .collectionTitle: "Someone else"])),
            ContainerMarker(fileName: "0005.pdf", type: .box, read: read([.container: "Box 18"])),
            ContainerMarker(fileName: "0003.pdf", type: nil),
        ]
        let (file, warnings) = ContainerInference.applyMarkers(markers, to: ContainerFile())
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(file.runs.map { "\($0.start) \($0.level)" },
                       ["0001.pdf collection", "0001.pdf box", "0002.pdf folder", "0005.pdf box"])
        XCTAssertEqual(values(file.runs[0].fields), [.repository: "Hoover Institution Archives",
                                                     .collectionTitle: "Albert Glotzer"])
        XCTAssertEqual(values(file.runs[1].fields), [.container: "Box 17", .date: "1950-1960"])
        // A folder label's box number and collection fields are not stored.
        XCTAssertEqual(values(file.runs[2].fields), [.folder: "8", .folderTitle: "Reports"])

        let scopes = [ContainerScope(file: file)]
        let at4 = ContainerResolver.resolve(fileName: "0004.pdf", scopes: scopes)
        XCTAssertEqual(at4.shown(.container), "Box 17")
        XCTAssertEqual(at4.shown(.folder), "8")
        XCTAssertEqual(at4.shown(.collectionTitle), "Albert Glotzer")
        // A new box clears the folder and carries the collection.
        let at6 = ContainerResolver.resolve(fileName: "0006.pdf", scopes: scopes)
        XCTAssertEqual(at6.shown(.container), "Box 18")
        XCTAssertNil(at6.shown(.folder))
        XCTAssertNil(at6.shown(.date))
        XCTAssertEqual(at6.shown(.repository), "Hoover Institution Archives")
    }

    func testABoxNamingAnotherCollectionStartsOneAndTheSameCollectionFillsIn() {
        let markers = [
            ContainerMarker(fileName: "01.pdf", type: .box,
                            read: read([.collectionTitle: "Glotzer papers", .container: "Box 1"])),
            ContainerMarker(fileName: "05.pdf", type: .box,
                            read: read([.collectionTitle: "GLOTZER PAPERS", .accession: "91006", .container: "Box 2"])),
            ContainerMarker(fileName: "09.pdf", type: .box,
                            read: read([.collectionTitle: "Kristol papers", .container: "Box 10"])),
        ]
        let file = ContainerInference.applyMarkers(markers, to: ContainerFile()).file
        let collections = file.runs.filter { $0.level == .collection }
        XCTAssertEqual(collections.map(\.start), ["01.pdf", "09.pdf"])
        // The second box's accession fills the same collection's run, so it reaches the first box too.
        XCTAssertEqual(values(collections[0].fields), [.collectionTitle: "Glotzer papers", .accession: "91006"])
        let scopes = [ContainerScope(file: file)]
        XCTAssertEqual(ContainerResolver.resolve(fileName: "02.pdf", scopes: scopes).shown(.accession), "91006")
        let at10 = ContainerResolver.resolve(fileName: "10.pdf", scopes: scopes)
        XCTAssertEqual(at10.shown(.collectionTitle), "Kristol papers")
        XCTAssertNil(at10.shown(.accession))
    }

    func testRereadKeepsUserValuesAndIsIdempotent() {
        let start = ContainerFile(runs: [
            ContainerRun(start: "01.pdf", level: .collection, fields: ContainerFieldSet([.collectionTitle: user("Glotzer")])),
            ContainerRun(start: "01.pdf", level: .box, fields: ContainerFieldSet([.container: user("Box 7"),
                                                                                  .boxTitle: label("old")])),
            ContainerRun(start: "03.pdf", level: .folder, fields: ContainerFieldSet([.folderTitle: user("Mine")])),
        ])
        let markers = [
            ContainerMarker(fileName: "01.pdf", type: .box,
                            read: read([.collectionTitle: "Glotzer", .container: "Box 1", .boxTitle: "Subject file"])),
            ContainerMarker(fileName: "05.pdf", type: .box,
                            read: read([.collectionTitle: "Kristol papers", .container: "Box 2"])),
        ]
        let (once, warnings) = ContainerInference.applyMarkers(markers, to: start)
        let box1 = once.runs.first { $0.start == "01.pdf" && $0.level == .box }!
        XCTAssertEqual(box1.fields[.container], user("Box 7"))
        XCTAssertEqual(box1.fields[.boxTitle]?.value, "Subject file")
        // The user's collection stands: no collection run is started over it, and the warning says so.
        // The photo at 05 falls inside the user's runs: it starts nothing, and the warnings say so.
        XCTAssertEqual(once.runs.map { "\($0.start) \($0.level)" }, ["01.pdf collection", "01.pdf box", "03.pdf folder"])
        XCTAssertEqual(warnings, [ContainerWarning(.readDisagreesWithUser([.container]), start: "01.pdf"),
                                  ContainerWarning(.markerInsideUserRun(.box), start: "05.pdf")])
        XCTAssertTrue(once.runs.contains(start.runs[2]), "a run with no marker stays")
        XCTAssertEqual(ContainerInference.applyMarkers(markers, to: once).file, once)
    }

    func testANewSeriesCarriesTheCollectionAndAUserCollectionTakesNothingFromAnother() {
        let markers = [
            ContainerMarker(fileName: "01.pdf", type: .box,
                            read: read([.collectionTitle: "Fromm papers", .repository: "Hoover", .series: "Series I"])),
            ContainerMarker(fileName: "10.pdf", type: .box, read: read([.series: "Series II", .container: "Box 4"])),
        ]
        let file = ContainerInference.applyMarkers(markers, to: ContainerFile()).file
        let at11 = ContainerResolver.resolve(fileName: "11.pdf", scopes: [ContainerScope(file: file)])
        XCTAssertEqual(at11.shown(.series), "Series II")
        XCTAssertEqual(at11.shown(.collectionTitle), "Fromm papers")
        XCTAssertEqual(at11.shown(.repository), "Hoover")
        XCTAssertEqual(ContainerResolver.resolve(fileName: "02.pdf", scopes: [ContainerScope(file: file)]).shown(.series),
                       "Series I")

        let mine = ContainerFile(runs: [ContainerRun(start: "01.pdf", level: .collection,
                                                     fields: ContainerFieldSet([.collectionTitle: user("Fromm papers")]))])
        let other = [ContainerMarker(fileName: "05.pdf", type: .box,
                                     read: read([.collectionTitle: "Kristol papers", .collectionNumber: "Mss 1036",
                                                 .container: "Box 2"]))]
        let (after, w) = ContainerInference.applyMarkers(other, to: mine)
        XCTAssertEqual(after.runs.first { $0.level == .collection }, mine.runs[0], "no number from another collection")
        XCTAssertEqual(after.runs.filter { $0.level == .collection }.count, 1)
        XCTAssertEqual(values(after.runs.first { $0.level == .box }!.fields), [.container: "Box 2"])
        XCTAssertEqual(w, [ContainerWarning(.readDisagreesWithUser([.collectionTitle]), start: "05.pdf")])
    }

    func testAPhotoInsideAUsersRunStartsNothing() {
        let mine = ContainerFile(runs: [
            ContainerRun(start: "01.pdf", level: .box, fields: ContainerFieldSet([.container: user("Box 5")])),
        ])
        for marker in [ContainerMarker(fileName: "05.pdf", type: .box, read: read([.container: "Box 6"])),
                       ContainerMarker(fileName: "05.pdf", type: .box)] {
            let (after, w) = ContainerInference.applyMarkers([marker], to: mine)
            XCTAssertEqual(after, mine)
            XCTAssertEqual(w.last, ContainerWarning(.markerInsideUserRun(.box), start: "05.pdf"))
        }
        // A folder photo there is deeper than the user's box run: it starts its folder run.
        let (after, w) = ContainerInference.applyMarkers(
            [ContainerMarker(fileName: "05.pdf", type: .folder, read: read([.folder: "2"]))], to: mine)
        XCTAssertEqual(after.runs.count, 2)
        XCTAssertEqual(w, [])
        XCTAssertEqual(ContainerResolver.resolve(fileName: "06.pdf", scopes: [ContainerScope(file: after)]).shown(.container),
                       "Box 5")
    }

    func testNoFolderSheetsAndUnreadMarkers() {
        let markers = [
            ContainerMarker(fileName: "01.pdf", type: .box, read: read([.container: "Box 1"])),
            ContainerMarker(fileName: "02.pdf", type: .folder, read: read([.folder: "3"])),
            ContainerMarker(fileName: "04.pdf", type: .folder, read: read([.folderTitle: "No Folder"]), text: "NO FOLDER"),
            ContainerMarker(fileName: "06.pdf", type: .folder),
            ContainerMarker(fileName: "08.pdf", type: .box, read: ContainerFieldSet([.container: label("  ")])),
            // A folder read that gave only a box number stores nothing.
            ContainerMarker(fileName: "09.pdf", type: .folder, read: read([.container: "Box 3"])),
        ]
        let (file, warnings) = ContainerInference.applyMarkers(markers, to: ContainerFile())
        let noFolder = file.runs.first { $0.start == "04.pdf" }!
        XCTAssertEqual(noFolder.level, .folder)
        XCTAssertTrue(noFolder.fields.isEmpty)
        XCTAssertNil(ContainerResolver.resolve(fileName: "05.pdf", scopes: [ContainerScope(file: file)]).shown(.folder))
        XCTAssertEqual(warnings, [ContainerWarning(.markerWithoutRead(.folder), start: "06.pdf"),
                                  ContainerWarning(.markerWithoutRead(.box), start: "08.pdf"),
                                  ContainerWarning(.markerWithoutRead(.folder), start: "09.pdf")])
    }

    // MARK: Mixed, and the warnings

    func testMixedTreeAndLabelsMergeByFieldAndWarnOnDisagreement() {
        let map = ContainerLevelMap(levels: [.repository, .collection, .box])
        let dir = ["Hoover Institution Archives", "Glotzer papers, Mss 1036", "Box 12"]
        let markers = [
            ContainerMarker(fileName: "IMG_0001.pdf", type: .box,
                            read: read([.collectionTitle: "Albert Glotzer Papers", .container: "Box 13"])),
            ContainerMarker(fileName: "IMG_0002.pdf", type: .folder, read: read([.folder: "4"])),
        ]
        let file = ContainerInference.applyMarkers(markers, to: ContainerFile()).file
        let scopes = map.scopes(for: dir, files: [nil, nil, nil, file])
        let r = ContainerResolver.resolve(fileName: "IMG_0003.pdf", scopes: scopes)
        // The tree gives what the photos lack; a label beats the tree where both speak.
        XCTAssertEqual(r.shown(.repository), "Hoover Institution Archives")
        XCTAssertEqual(r.shown(.collectionNumber), "Mss 1036")
        XCTAssertEqual(r.shown(.collectionTitle), "Albert Glotzer Papers")
        XCTAssertEqual(r.shown(.container), "Box 13")
        XCTAssertEqual(r.shown(.folder), "4")

        let names = ["IMG_0001.pdf", "IMG_0002.pdf", "IMG_0003.pdf"]
        XCTAssertEqual(ContainerInference.warnings(fileNames: names, scopes: scopes),
                       [ContainerWarning(.disagreement([.collectionTitle, .container]), start: "IMG_0001.pdf", files: 3)])
        // The user's standard name for the collection makes the two titles agree.
        var standard = ContainerNames()
        standard.set(ContainerStandardName(field: .collectionTitle, standard: "Albert Glotzer papers",
                                           variants: ["Glotzer papers", "Albert Glotzer Papers"]))
        XCTAssertEqual(ContainerInference.warnings(fileNames: names, scopes: scopes, names: standard),
                       [ContainerWarning(.disagreement([.container]), start: "IMG_0001.pdf", files: 3)])
    }

    func testLongUnmarkedRuns() {
        let names = (1...200).map { String(format: "%04d.pdf", $0) }
        let file = ContainerFile(runs: [
            ContainerRun(start: "0011.pdf", level: .box),
            ContainerRun(start: "0050.pdf", level: .folder),
            // A start that names no file (its photo removed) ends a stretch; the file after it begins the next one.
            ContainerRun(start: "0130.5.pdf", level: .folder),
        ])
        let w = ContainerInference.warnings(fileNames: names.shuffled(), scopes: [ContainerScope(file: file)],
                                            longRun: 60)
        let at = names.firstIndex { !ContainerOrder.precedes($0, "0130.5.pdf") }!   // Finder's order places it
        XCTAssertEqual(w, [ContainerWarning(.longUnmarkedRun(count: at - 50), start: "0051.pdf", files: at - 50),
                           ContainerWarning(.longUnmarkedRun(count: 200 - at), start: names[at], files: 200 - at)])
        XCTAssertEqual(ContainerInference.warnings(fileNames: names, scopes: [ContainerScope()]), [],
                       "a directory with no runs has no marker to miss")
    }

    // MARK: On a scratch tree

    /// Route A and Route B together on a scratch tree: the tree listed from disk, the pre-filled map, the markers'
    /// runs written through `ContainerFileStore` and read back, and every file resolved. Nothing but the
    /// `.archivesuite` files is written.
    func testScratchTreeEndToEnd() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ContainerInferenceTests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let boxDir = root.appendingPathComponent("Hoover Institution Archives/Glotzer papers, Mss 1036/Box 17")
        let photos = root.appendingPathComponent("Wisconsin Historical Society/Kristol papers")
        for d in [boxDir, photos] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        for n in ["0001.pdf", "0002.pdf", "0003.pdf"] { try Data(n.utf8).write(to: boxDir.appendingPathComponent(n)) }
        for n in (1...6).map({ String(format: "IMG_%04d.pdf", $0) }) {
            try Data(n.utf8).write(to: photos.appendingPathComponent(n))
        }

        func dirs(_ url: URL, _ path: [String] = []) throws -> [[String]] {
            let subs = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                  options: [.skipsHiddenFiles])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            return try [path] + subs.flatMap { try dirs($0, path + [$0.lastPathComponent]) }
        }
        let map = ContainerLevelMap.prefilled(directories: try dirs(root).filter { !$0.isEmpty })
        XCTAssertEqual(map.levels, [.repository, .collection, .box])
        try ContainerFileStore.writeLevelMap(map, root: root, expecting: nil)

        let markers = [
            ContainerMarker(fileName: "IMG_0001.pdf", type: .box, read: read([.container: "Box 10"])),
            ContainerMarker(fileName: "IMG_0004.pdf", type: .folder, read: read([.folder: "3"])),
        ]
        let (proposed, _) = ContainerInference.applyMarkers(markers, to: ContainerFile())
        try ContainerFileStore.write(proposed, directory: photos, expecting: nil)

        let loadedMap = try XCTUnwrap(ContainerFileStore.loadLevelMap(root: root).document)
        let loaded = ContainerFileStore.load(directory: photos).document
        XCTAssertEqual(loaded?.runs, proposed.runs)
        let scopes = loadedMap.scopes(for: ["Wisconsin Historical Society", "Kristol papers"],
                                      files: [nil, nil, loaded])
        let at5 = ContainerResolver.resolve(fileName: "IMG_0005.pdf", scopes: scopes)
        XCTAssertEqual(at5.shown(.repository), "Wisconsin Historical Society")
        XCTAssertEqual(at5.shown(.collectionTitle), "Kristol papers")
        XCTAssertEqual(at5.shown(.container), "Box 10")
        XCTAssertEqual(at5.shown(.folder), "3")
        XCTAssertNil(ContainerResolver.resolve(fileName: "IMG_0002.pdf", scopes: scopes).shown(.folder))

        let inBox = ContainerResolver.resolve(
            fileName: "0002.pdf", scopes: loadedMap.scopes(for: ["Hoover Institution Archives",
                                                               "Glotzer papers, Mss 1036", "Box 17"]))
        XCTAssertEqual(inBox.shown(.collectionNumber), "Mss 1036")
        XCTAssertEqual(inBox.shown(.container), "Box 17")

        // The photos are untouched: same names, same bytes.
        for n in (1...6).map({ String(format: "IMG_%04d.pdf", $0) }) {
            XCTAssertEqual(try Data(contentsOf: photos.appendingPathComponent(n)), Data(n.utf8))
        }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: photos.path).sorted(),
                       [".archivesuite"] + (1...6).map { String(format: "IMG_%04d.pdf", $0) })
    }
}
