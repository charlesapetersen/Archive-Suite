import XCTest
@testable import ArchiveCore

/// The label reader (W47.ct-processor-capture): the parser gives what `ct_read.py` `vision_read` gives on the same
/// lines (each expectation below is that function's output, run 2026-11-19), and the proposals take each field from
/// the reader the owner chose for it (2026-11-13).
final class ContainerLabelReaderTests: XCTestCase {
    private func parsed(_ lines: [String], _ type: ItemType) -> [String: String] {
        Dictionary(uniqueKeysWithValues: ContainerLabelReader.parse(lines: lines, type: type).map { ($0.key.benchName, $0.value) })
    }

    func testParserMatchesCtReadVisionRead() {
        let cases: [([String], ItemType, [String: String])] = [
            (["STATE HISTORICAL SOCIETY OF WISCONSIN", "Irving Kristol Papers, 1946-2001", "Mss 1036", "Box 10"], .box,
             ["repository": "STATE HISTORICAL SOCIETY OF WISCONSIN", "collection_number": "Mss 1036", "container": "Box 10",
              "date": "1946-2001"]),
            (["HOOVER INSTITUTION ARCHIVES", "ALBERT GLOTZER", "BOX NO. 17", "ACCESSION NO. 91006-10.V"], .box,
             ["repository": "HOOVER INSTITUTION ARCHIVES", "accession": "91006-10.V", "container": "Box 17"]),
            (["Edward Shils. Papers", "Series II, Manuscripts", "Box 101"], .box,
             ["collection_title": "Edward Shils. Papers", "series": "Series II", "series_title": "Manuscripts",
              "container": "Box 101"]),
            (["Stanford University News Service", "Series 1", "SC 122 Box 82"], .box,
             ["repository": "Stanford University News Service", "collection_number": "SC 122", "series": "Series 1",
              "container": "Box 82"]),
            (["5-9", "Correspondence with Smith 1950"], .folder, ["container": "Box 5", "folder": "9", "date": "1950"]),
            (["Folder 08", "Reports 1959-1960"], .folder, ["folder": "08", "date": "1959-1960"]),
            (["12"], .box, ["container": "Box 12"]),
            (["Fd 3 Files of the Committee", "Minutes"], .folder,
             ["collection_title": "Fd 3 Files of the Committee", "folder_title": "Minutes"]),
            (["CORRESPONDENCE 1950S", "Folder 2"], .folder, ["folder": "2", "folder_title": "CORRESPONDENCE 1950S"]),
        ]
        for (lines, type, want) in cases {
            XCTAssertEqual(parsed(lines, type), want, "\(lines)")
        }
    }

    func testProposalsTakeEachFieldFromItsReader() {
        let lines = ["HOOVER INSTITUTION ARCHIVES", "ALBERT GLOTZER", "Series II, Manuscripts", "BOX NO. 017"]
        // No model: the parser's values, every one a label proposal.
        let alone = ContainerLabelReader.proposals(lines: lines, type: .box)
        XCTAssertEqual(alone.values.mapValues(\.value), [.repository: "HOOVER INSTITUTION ARCHIVES", .series: "Series II",
                                                         .seriesTitle: "Manuscripts", .container: "Box 17"])
        XCTAssertTrue(alone.values.values.allSatisfy { $0.source == .label && $0.reader == ContainerLabelReader.visionReader })

        // A model: its repository, title and accession win; the parser's container stays; box title is nobody's.
        let model: [ContainerField: String] = [.repository: "Hoover Institution Archives", .collectionTitle: "Albert Glotzer papers",
                                               .accession: "91006", .container: "Box 71", .boxTitle: "Subject file"]
        let both = ContainerLabelReader.proposals(lines: lines, type: .box, model: model, modelReader: "gpt-5.6-luna")
        XCTAssertEqual(both[.repository]?.value, "Hoover Institution Archives")
        XCTAssertEqual(both[.repository]?.reader, "gpt-5.6-luna")
        XCTAssertEqual(both[.collectionTitle]?.value, "Albert Glotzer papers")
        XCTAssertEqual(both[.accession]?.value, "91006")
        XCTAssertEqual(both[.container]?.value, "Box 17")
        XCTAssertEqual(both[.container]?.reader, ContainerLabelReader.visionReader)
        XCTAssertNil(both[.boxTitle])

        // Where Vision reads no box number, the model's is the fallback, in the canonical spelling.
        let fallback = ContainerLabelReader.proposals(lines: ["HOOVER INSTITUTION ARCHIVES"], type: .box,
                                                      model: [.container: "BOX #034"], modelReader: "gpt-5.6-luna")
        XCTAssertEqual(fallback[.container]?.value, "Box 34")
        XCTAssertEqual(fallback[.container]?.reader, "gpt-5.6-luna")
    }

    func testFolderProposalsKeepOnlyWhatAFolderRunStores() {
        let set = ContainerLabelReader.proposals(lines: ["5-08", "Correspondence with Smith 1950"], type: .folder)
        // The box number a folder label names is not stored (owner, 2026-11-13); the folder title is the user's.
        XCTAssertEqual(set.values.mapValues(\.value), [.folder: "8", .date: "1950"])
    }

    func testModelReplyParsesLeniently() {
        let reply = "Here you are:\n```json\n{\"repository\": \"Hoover Institution Archives\", \"collection_number\": null, "
            + "\"container\": 17, \"accession\": \"unknown\", \"box_title\": \"Subject\"}\n```"
        XCTAssertEqual(ContainerLabelReader.modelFields(fromReply: reply),
                       [.repository: "Hoover Institution Archives", .container: "17"])
        XCTAssertEqual(ContainerLabelReader.modelFields(fromReply: "no JSON here"), [:])
    }
}

/// `recordMarkers` on scratch directories: the finalize write (Tier-2, `SPEC/containers.md` §File safety).
final class ContainerRecordMarkersTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ct-record-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["00001 Glotzer.pdf", "00002 Glotzer.pdf", "00003 Glotzer.pdf"] {
            try Data("pdf".utf8).write(to: dir.appendingPathComponent(name))
        }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func box(_ name: String, _ fields: ContainerFieldSet) -> ContainerMarker {
        ContainerMarker(fileName: name, type: .box, read: fields)
    }

    func testWritesTheFileAndKeepsTheUsersValues() throws {
        let read = ContainerLabelReader.proposals(lines: ["HOOVER INSTITUTION ARCHIVES", "BOX NO. 17"], type: .box)
        var confirmed = read
        confirmed[.collectionTitle] = ContainerValue("Albert Glotzer papers", source: .user)
        let before = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        let outcome = try ContainerInference.recordMarkers([box("00001 Glotzer.pdf", confirmed)], in: dir)
        guard case .wrote = outcome else { return XCTFail("\(outcome)") }

        // Nothing outside `.archivesuite` changed: the three PDFs are as they were.
        let after = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(after, (before + [".archivesuite"]).sorted())
        for name in before { XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(name)), Data("pdf".utf8)) }

        let file = try XCTUnwrap(ContainerFileStore.load(directory: dir).document)
        let resolved = ContainerResolver.resolve(fileName: "00003 Glotzer.pdf",
                                                 scopes: [ContainerScope(file: file, pathFields: ContainerFieldSet())])
        XCTAssertEqual(resolved.values[.container]?.value, "Box 17")
        XCTAssertEqual(resolved.values[.collectionTitle]?.source, .user)
        XCTAssertEqual(resolved.values[.repository]?.source, .label)

        // The same markers again change nothing; a re-read never overwrites the user's value.
        XCTAssertEqual(try ContainerInference.recordMarkers([box("00001 Glotzer.pdf", confirmed)], in: dir), .unchanged([]))
        var reread = read
        reread[.collectionTitle] = ContainerValue("Glotzer", source: .label)
        _ = try ContainerInference.recordMarkers([box("00001 Glotzer.pdf", reread)], in: dir)
        let again = try XCTUnwrap(ContainerFileStore.load(directory: dir).document)
        XCTAssertEqual(again.runs.first { $0.level == .collection }?.fields[.collectionTitle]?.value, "Albert Glotzer papers")
    }

    /// Two confirmed boxes and two confirmed folders in one batch, then a third box in a later session: each marker the
    /// user started opens its own run, though the run before it holds the user's values (the review's finding 1).
    func testConfirmedMarkersEachStartTheirRun() throws {
        for n in 4...12 { try Data("pdf".utf8).write(to: dir.appendingPathComponent(String(format: "%05d Glotzer.pdf", n))) }
        func user(_ f: [ContainerField: String]) -> ContainerFieldSet { ContainerFieldSet(f.mapValues { ContainerValue($0, source: .user) }) }
        func marker(_ n: Int, _ type: ItemType, _ f: [ContainerField: String]) -> ContainerMarker {
            ContainerMarker(fileName: String(format: "%05d Glotzer.pdf", n), type: type, read: user(f), startedByUser: true)
        }
        let batch = [marker(1, .box, [.container: "Box 17", .collectionTitle: "Glotzer papers"]),
                     marker(2, .folder, [.folder: "1"]), marker(4, .folder, [.folder: "2"]),
                     marker(6, .box, [.container: "Box 18"]), marker(7, .folder, [.folder: "1"])]
        guard case .wrote(let warnings) = try ContainerInference.recordMarkers(batch, in: dir) else { return XCTFail() }
        XCTAssertTrue(warnings.isEmpty, "\(warnings)")
        _ = try ContainerInference.recordMarkers([marker(10, .box, [.container: "Box 19"])], in: dir)
        let file = try XCTUnwrap(ContainerFileStore.load(directory: dir).document)
        func at(_ n: Int) -> [ContainerField: String] {
            ContainerResolver.resolve(fileName: String(format: "%05d Glotzer.pdf", n), scopes: [ContainerScope(file: file)])
                .values.mapValues(\.value)
        }
        XCTAssertEqual(at(3), [.container: "Box 17", .folder: "1", .collectionTitle: "Glotzer papers"])
        XCTAssertEqual(at(5), [.container: "Box 17", .folder: "2", .collectionTitle: "Glotzer papers"])
        XCTAssertEqual(at(6), [.container: "Box 18", .collectionTitle: "Glotzer papers"])
        XCTAssertEqual(at(8), [.container: "Box 18", .folder: "1", .collectionTitle: "Glotzer papers"])
        XCTAssertEqual(at(12), [.container: "Box 19", .collectionTitle: "Glotzer papers"])

        // A photo whose type a classifier gave still starts no run inside the user's (SPEC §Route A).
        let classified = ContainerMarker(fileName: "00011 Glotzer.pdf", type: .box,
                                         read: ContainerLabelReader.proposals(lines: ["Box 20"], type: .box))
        XCTAssertEqual(try ContainerInference.recordMarkers([classified], in: dir),
                       .unchanged([ContainerWarning(.markerInsideUserRun(.box), start: "00011 Glotzer.pdf")]))
    }

    /// A marker the user started never takes over a file that was already in the folder (the second review's finding 3):
    /// adding Box 18 to a folder whose finding aid sorts after the new PDF and sits in the user's Box 17 run.
    func testAStartedMarkerLeavesFilesAlreadyThere() throws {
        try Data("pdf".utf8).write(to: dir.appendingPathComponent("Glotzer finding aid.pdf"))
        let box17 = ContainerFieldSet([.container: ContainerValue("Box 17", source: .user)])
        try ContainerFileStore.write(ContainerFile(runs: [ContainerRun(start: "00001 Glotzer.pdf", level: .box, fields: box17)]),
                                     directory: dir, expecting: nil)
        try Data("pdf".utf8).write(to: dir.appendingPathComponent("00004 Glotzer.pdf"))
        let box18 = ContainerMarker(fileName: "00004 Glotzer.pdf", type: .box,
                                    read: ContainerFieldSet([.container: ContainerValue("Box 18", source: .user)]),
                                    startedByUser: true)
        let outcome = try ContainerInference.recordMarkers([box18], in: dir, filedNow: ["00004 Glotzer.pdf"])
        XCTAssertEqual(outcome, .unchanged([ContainerWarning(.markerInsideUserRun(.box), start: "00004 Glotzer.pdf")]))
        // With nothing of the folder's after it, the same marker starts its run.
        try FileManager.default.removeItem(at: dir.appendingPathComponent("Glotzer finding aid.pdf"))
        guard case .wrote = try ContainerInference.recordMarkers([box18], in: dir, filedNow: ["00004 Glotzer.pdf"]) else {
            return XCTFail()
        }
    }

    func testLeavesANewerOrUnreadableDocumentAlone() throws {
        let folder = dir.appendingPathComponent(ContainerFile.folderName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(ContainerFile.fileName)
        for body in [#"{"schemaVersion": 99, "runs": []}"#, "not json"] {
            try Data(body.utf8).write(to: url)
            let outcome = try ContainerInference.recordMarkers(
                [box("00001 Glotzer.pdf", ContainerLabelReader.proposals(lines: ["Box 3"], type: .box))], in: dir)
            guard case .leftAlone = outcome else { return XCTFail("\(outcome)") }
            XCTAssertEqual(try Data(contentsOf: url), Data(body.utf8))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [ContainerFile.fileName])
        }
    }
}
