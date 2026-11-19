import XCTest
@testable import ArchiveCore

/// The export to Zotero (W47.ct-zotero; `SPEC/containers.md` §Zotero): every gathered field reaches the CSL-JSON
/// item, in a variable the Zotero type keeps or in `note` (Extra), nothing is invented, and Zotero's own importer
/// reads the fields back (`Tools/zotero-import`, run where Zotero 10 and node are installed).
final class ZoteroExportTests: XCTestCase {
    private func tags(_ raw: [String]) -> DocumentTags { DocumentTags.parse(raw: raw, labelNumber: nil) }

    private func note(_ item: [String: Any]) -> [String] {
        (item["note"] as? String ?? "").components(separatedBy: "\n")
    }

    private let glotzer: [ContainerField: String] = [
        .repository: "Hoover Institution Archives", .place: "Stanford, CA", .collectionTitle: "Albert Glotzer Papers",
        .collectionNumber: "Mss 1036", .accession: "91006", .container: "Box 17", .folder: "8",
        .folderTitle: "Reports 1959-1960",
    ]

    // MARK: The sidecar

    func testSidecarEntitiesKeepNamesAndOnlyWrittenPlaces() throws {
        let json = """
        {"entities": {"status": "extracted", "route": "gateway",
          "sender": [{"name": "Max Shachtman", "evidence": "quoted", "quote": "Max"}],
          "recipient": [{"name": "Albert Glotzer", "evidence": "inferred", "inferred_because": "addressed"}],
          "sending_place": [{"name": "New York", "evidence": "inferred"}, {"name": "Chicago", "evidence": "quoted"}]},
         "recipient_location": "Chicago", "publication_name": null, "format": "Letter",
         "item_fields": {"status": "read", "kind": "letter", "recipient_place": ["Chicago, IL"]}}
        """
        let s = try XCTUnwrap(ZoteroSidecar.parse(Data(json.utf8)))
        XCTAssertEqual(s.authors, ["Max Shachtman"])
        XCTAssertEqual(s.recipients, ["Albert Glotzer"])
        XCTAssertEqual(s.authorPlaces, ["Chicago"], "an inferred sending place is not one the document writes")
        XCTAssertEqual(s.recipientPlaces, ["Chicago"])
        XCTAssertEqual(s.itemFields.documentKind, "letter")
        XCTAssertEqual(s.itemFields.recipientPlace, "Chicago, IL")
    }

    func testSidecarUnknownPlaceholdersAndFailedCallsGiveNothing() throws {
        let json = """
        {"entities": {"status": "extracted", "sender": [{"name": "Unknown", "evidence": "unknown"}],
          "recipient": [{"name": "Unknown", "evidence": "unknown"}], "sending_place": []},
         "item_fields": {"status": "failed", "reason": "timeout", "kind": "memo"}}
        """
        let s = try XCTUnwrap(ZoteroSidecar.parse(Data(json.utf8)))
        XCTAssertEqual(s, ZoteroSidecar())
        XCTAssertNil(ZoteroSidecar.parse(Data("[1]".utf8)))
    }

    func testSidecarWithoutEntitiesReadsTheTaggingCallsNames() throws {
        let json = #"{"author_name": "J. Cannon", "recipient_name": "unknown", "author_location": "  "}"#
        let s = try XCTUnwrap(ZoteroSidecar.parse(Data(json.utf8)))
        XCTAssertEqual(s.authors, ["J. Cannon"])
        XCTAssertEqual(s.recipients, [])
        XCTAssertEqual(s.authorPlaces, [])
    }

    func testSidecarIsFoundBesideThePDFOrInJSONOutput() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ZoteroSidecar-\(UUID().uuidString)")
        let out = dir.appendingPathComponent(ZoteroSidecar.folderName)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("00001 Letter.pdf"), b = dir.appendingPathComponent("00002 Memo.pdf")
        try Data(#"{"author_name": "A"}"#.utf8).write(to: dir.appendingPathComponent("00001 Letter.json"))
        try Data(#"{"author_name": "B"}"#.utf8).write(to: out.appendingPathComponent("00002 Memo.json"))
        XCTAssertEqual(ZoteroSidecar.read(pdf: a)?.authors, ["A"])
        XCTAssertEqual(ZoteroSidecar.read(pdf: b)?.authors, ["B"])
        XCTAssertNil(ZoteroSidecar.read(pdf: dir.appendingPathComponent("00003.pdf")))
    }

    // MARK: The item

    func testLetterCarriesContainerPeopleDateAndExtra() {
        var side = ZoteroSidecar()
        side.authors = ["Max Shachtman"]
        side.recipients = ["Albert Glotzer"]
        side.authorPlaces = ["New York"]
        side.itemFields = PDFItemFields(documentKind: "letter", recipientPlace: "Chicago")
        let item = ZoteroExport.item(ZoteroSource(
            fileName: "0004.pdf", tags: tags(["1959", "3 March", "Day 12", "Date Uncertain", "Trotskyism", "OCR Poor",
                                              "Unread", "Q2"]),
            sidecar: side, container: glotzer))
        XCTAssertEqual(item["type"] as? String, "personal_communication")
        XCTAssertEqual(item["archive"] as? String, "Hoover Institution Archives")
        XCTAssertEqual(item["call-number"] as? String, "Mss 1036")
        XCTAssertEqual(item["archive_location"] as? String, "Box 17, Folder 8, Reports 1959-1960")
        XCTAssertEqual((item["author"] as? [[String: String]])?.first?["literal"], "Max Shachtman")
        XCTAssertEqual((item["recipient"] as? [[String: String]])?.first?["literal"], "Albert Glotzer")
        let issued = item["issued"] as? [String: Any]
        XCTAssertEqual(issued?["date-parts"] as? [[Int]], [[1959, 3, 12]])
        XCTAssertEqual(issued?["circa"] as? Bool, true)
        XCTAssertNil(item["title"], "no title is invented")
        XCTAssertNil(item["publisher-place"], "a Letter has no Place")
        XCTAssertEqual(item["keyword"] as? String, "Trotskyism")
        XCTAssertEqual(note(item), [
            "archive_collection: Albert Glotzer Papers", "archive-place: Stanford, CA", "accession: 91006",
            "Author place: New York", "Recipient place: Chicago", "Date uncertain", "Subjects: Trotskyism",
            "File: 0004.pdf",
        ])
    }

    func testMemoKeepsItsPlaceAndPutsTheRecipientInExtra() {
        var side = ZoteroSidecar()
        side.authors = ["J. Cannon"]
        side.recipients = ["Political Committee"]
        side.authorPlaces = ["New York"]
        let item = ZoteroExport.item(ZoteroSource(fileName: "m.pdf",
                                                  itemFields: PDFItemFields(documentKind: "memo"), sidecar: side))
        XCTAssertEqual(item["type"] as? String, "manuscript")
        XCTAssertEqual(item["genre"] as? String, "Memo")
        XCTAssertEqual(item["publisher-place"] as? String, "New York")
        XCTAssertNil(item["recipient"])
        XCTAssertEqual(note(item), ["Recipient: Political Committee", "File: m.pdf"])
    }

    func testClippingTakesByLinePublicationAndKeepsThePrintedDateApart() {
        var side = ZoteroSidecar()
        side.authors = ["Someone Else"]
        side.itemFields = PDFItemFields(title: "From The Sidecar", publication: "Sidecar Times")
        let header = PDFItemFields(documentKind: "clipping", title: "Strike Spreads", byline: "A. Reporter; B. Writer",
                                   publication: "The Militant", publicationDate: "June 3, 1946")
        let item = ZoteroExport.item(ZoteroSource(fileName: "c.pdf", tags: tags(["1946"]), itemFields: header,
                                                  sidecar: side))
        XCTAssertEqual(item["type"] as? String, "article-newspaper")
        XCTAssertEqual(item["title"] as? String, "Strike Spreads", "the page header wins over the sidecar")
        XCTAssertEqual(item["container-title"] as? String, "The Militant")
        XCTAssertEqual((item["author"] as? [[String: String]])?.compactMap { $0["literal"] }, ["A. Reporter", "B. Writer"])
        XCTAssertEqual((item["issued"] as? [String: Any])?["date-parts"] as? [[Int]], [[1946]],
                       "issued is the tags' date, never the printed issue date (FLD-6)")
        XCTAssertEqual(note(item), ["Document kind: clipping", "Sender: Someone Else", "Publication date: June 3, 1946",
                                    "File: c.pdf"], "a sender the byline does not name is kept")
    }

    func testUnclassifiedMaterialCarriesOnlyWhatItsTagsAndFoldersGive() {
        let item = ZoteroExport.item(ZoteroSource(fileName: "Fromm, Box 2, Folder 4 - 0004.pdf",
                                                  tags: tags(["1970s", "Read"]),
                                                  container: [.container: "Box 2", .folder: "4"]))
        XCTAssertEqual(item["type"] as? String, "document")
        XCTAssertNil(item["genre"])
        XCTAssertEqual(item["archive_location"] as? String, "Box 2, Folder 4")
        let issued = item["issued"] as? [String: Any]
        XCTAssertEqual(issued?["literal"] as? String, "1970s")
        XCTAssertEqual(issued?["circa"] as? Bool, true, "a decade alone is an approximate date")
        for key in ["author", "recipient", "title", "archive", "call-number", "keyword", "container-title", "URL"] {
            XCTAssertNil(item[key], key)
        }
        XCTAssertEqual(note(item), ["File: Fromm, Box 2, Folder 4 - 0004.pdf"])
    }

    func testFormatStandsInForAKindOnlyWhenItNamesOne() {
        var side = ZoteroSidecar()
        side.format = "Letter"
        XCTAssertEqual(ZoteroExport.item(ZoteroSource(fileName: "a", sidecar: side))["type"] as? String,
                       "personal_communication")
        side.format = "Newspaper Clipping"
        let item = ZoteroExport.item(ZoteroSource(fileName: "b", sidecar: side))
        XCTAssertEqual(item["type"] as? String, "document")
        XCTAssertEqual(item["genre"] as? String, "Newspaper Clipping")
    }

    func testDatePartsIssuedCannotCarryAreKept() {
        XCTAssertEqual(note(ZoteroExport.item(ZoteroSource(fileName: "a", tags: tags(["3 March", "Day 12"])))),
                       ["Month: March", "Day: 12", "File: a"])
        let decade = ZoteroExport.item(ZoteroSource(fileName: "b", tags: tags(["1970s", "3 March"])))
        XCTAssertEqual((decade["issued"] as? [String: Any])?["literal"] as? String, "1970s")
        XCTAssertEqual(note(decade), ["Month: March", "File: b"])
        let noMonth = ZoteroExport.item(ZoteroSource(fileName: "c", tags: tags(["1959", "Day 12"])))
        XCTAssertEqual((noMonth["issued"] as? [String: Any])?["date-parts"] as? [[Int]], [[1959]])
        XCTAssertEqual(note(noMonth), ["Day: 12", "File: c"])
    }

    func testFormatAndSendersAreKeptWhereTheTypeDoesNotTakeThem() {
        var side = ZoteroSidecar()
        side.format = "Postcard"
        side.itemFields = PDFItemFields(documentKind: "other")
        let other = ZoteroExport.item(ZoteroSource(fileName: "a", sidecar: side))
        XCTAssertEqual(other["genre"] as? String, "Postcard")
        XCTAssertEqual(note(other), ["genre: Postcard", "File: a"], "Zotero's Document has no genre field")
        side.itemFields = PDFItemFields(documentKind: "letter")
        XCTAssertEqual(note(ZoteroExport.item(ZoteroSource(fileName: "b", sidecar: side))), ["Format: Postcard", "File: b"])
        side.format = "Letter"
        XCTAssertEqual(note(ZoteroExport.item(ZoteroSource(fileName: "c", sidecar: side))), ["File: c"])

        var letter = ZoteroSidecar()
        letter.authors = ["A. Reader", "J. Smith"]
        let item = ZoteroExport.item(ZoteroSource(fileName: "d", itemFields: PDFItemFields(
            documentKind: "newspaper article", byline: "J. Smith"), sidecar: letter))
        XCTAssertEqual((item["author"] as? [[String: String]])?.compactMap { $0["literal"] }, ["J. Smith"])
        XCTAssertEqual(note(item), ["Sender: A. Reader", "File: d"])
    }

    func testSentWithAndUndatedFiles() {
        let item = ZoteroExport.item(ZoteroSource(fileName: "e.pdf",
                                                  tags: tags(["Sent With 1958-03-12", "Sent With Date Uncertain"])))
        XCTAssertNil(item["issued"])
        XCTAssertEqual(note(item), ["Sent with: 1958-03-12 (uncertain)", "File: e.pdf"])
    }

    func testExportNumbersRepeatedNames() throws {
        let data = ZoteroExport.export([ZoteroSource(fileName: "a.pdf"), ZoteroSource(fileName: "a.pdf")])
        let items = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(items.compactMap { $0["id"] as? String }, ["a.pdf", "a.pdf (2)"])
    }

    // MARK: Reading from disk

    func testGatherReadsTheContainerThroughTheLevelMap() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ZoteroGather-\(UUID().uuidString)")
        let main = root.appendingPathComponent(ContainerLookup.mainDirectoryName)
        let folder = main.appendingPathComponent("Hoover").appendingPathComponent("Box 17")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try ContainerFileStore.writeLevelMap(ContainerLevelMap(levels: [.repository, .box]), root: main, expecting: nil)
        let file = ContainerFile(runs: [ContainerRun(start: "0002.pdf", level: .folder, fields: ContainerFieldSet(
            [.folder: ContainerValue("Folder 8", source: .user)]))])
        try ContainerFileStore.write(file, directory: folder, expecting: nil)
        let pdf = folder.appendingPathComponent("0003.pdf")
        try Data(#"{"author_name": "A. Writer"}"#.utf8).write(to: folder.appendingPathComponent("0003.json"))

        XCTAssertEqual(ContainerLookup.treeRoot(forGrantedRoot: root).lastPathComponent, ContainerLookup.mainDirectoryName)
        let source = ZoteroSource.gather(pdf: pdf, lookup: ContainerLookup(treeRoot: main))
        XCTAssertEqual(source.container[.repository], "Hoover")
        XCTAssertEqual(source.container[.container], "Box 17")
        XCTAssertEqual(source.container[.folder], "Folder 8")
        XCTAssertEqual(source.sidecar?.authors, ["A. Writer"])
        XCTAssertNil(source.tags, "no file, no tags")
        XCTAssertEqual(ZoteroExport.item(source)["archive_location"] as? String, "Box 17, Folder 8")
        XCTAssertEqual(ContainerLookup(treeRoot: main).shown(for: root.appendingPathComponent("x.pdf")), [:])
    }

    // MARK: Zotero's own importer

    /// The Zotero items the installed Zotero's importer makes of the CSL-JSON `export`. Skips where Zotero 10 or node
    /// is not installed.
    private func zoteroImport(_ export: Data) throws -> [[String: Any]] {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Tools/zotero-import/zotero-import.sh")
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("zotero-\(UUID().uuidString).json")
        try export.write(to: input)
        defer { try? FileManager.default.removeItem(at: input) }
        let run = Process()
        run.executableURL = URL(fileURLWithPath: "/bin/bash")
        run.arguments = [script.path, input.path]
        let out = Pipe()
        run.standardOutput = out
        run.standardError = Pipe()
        try run.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        run.waitUntilExit()
        if run.terminationStatus == 3 { throw XCTSkip("Zotero 10 or node is not installed") }
        XCTAssertEqual(run.terminationStatus, 0)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    /// Imports an export with the installed Zotero's importer and reads each field back from the Zotero item. Skips
    /// where Zotero 10 or node is not installed.
    func testZoteroImportsEveryGatheredField() throws {
        var letter = ZoteroSidecar()
        letter.authors = ["Max Shachtman"]
        letter.recipients = ["Albert Glotzer"]
        letter.authorPlaces = ["New York"]
        var memo = ZoteroSidecar()
        memo.recipients = ["Political Committee"]
        memo.authorPlaces = ["New York"]
        let sources = [
            ZoteroSource(fileName: "0004.pdf", tags: tags(["1959", "3 March", "Day 12", "Trotskyism"]),
                         itemFields: PDFItemFields(documentKind: "letter", recipientPlace: "Chicago"),
                         sidecar: letter, container: glotzer, link: "archivereader://reveal?x=1"),
            ZoteroSource(fileName: "m.pdf", tags: tags(["1960s"]), itemFields: PDFItemFields(documentKind: "memo"),
                         sidecar: memo),
            ZoteroSource(fileName: "c.pdf", tags: tags(["1946"]), itemFields: PDFItemFields(
                documentKind: "newspaper article", title: "Strike Spreads", byline: "A. Reporter",
                publication: "The Militant", publicationDate: "June 3, 1946"), container: glotzer),
            ZoteroSource(fileName: "p.pdf", itemFields: PDFItemFields(documentKind: "photograph"), container: glotzer),
        ]
        let items = try zoteroImport(ZoteroExport.export(sources))
        XCTAssertEqual(items.count, 4)
        func creators(_ i: [String: Any]) -> [String] {
            (i["creators"] as? [[String: Any]] ?? []).map { "\($0["creatorType"] ?? ""): \($0["lastName"] ?? "")" }
        }
        func extra(_ i: [String: Any]) -> [String] { (i["extra"] as? String ?? "").components(separatedBy: "\n") }

        let l = items[0]
        XCTAssertEqual(l["itemType"] as? String, "letter")
        XCTAssertEqual(creators(l), ["author: Max Shachtman", "recipient: Albert Glotzer"])
        XCTAssertEqual(l["archive"] as? String, "Hoover Institution Archives")
        XCTAssertEqual(l["archiveLocation"] as? String, "Box 17, Folder 8, Reports 1959-1960")
        XCTAssertEqual(l["callNumber"] as? String, "Mss 1036")
        XCTAssertEqual(l["date"] as? String, "March 12, 1959")
        XCTAssertEqual(l["url"] as? String, "archivereader://reveal?x=1")
        XCTAssertEqual(extra(l), ["archive_collection: Albert Glotzer Papers", "archive-place: Stanford, CA",
                                  "accession: 91006", "Author place: New York", "Recipient place: Chicago",
                                  "Subjects: Trotskyism", "File: 0004.pdf"])

        let m = items[1]
        XCTAssertEqual(m["itemType"] as? String, "manuscript")
        // A translator's item holds a base field by its base name; saving it fills the type's own field (Manuscript
        // Type, Medium).
        XCTAssertEqual(m["type"] as? String, "Memo")
        XCTAssertEqual(m["place"] as? String, "New York")
        XCTAssertEqual(m["date"] as? String, "1960s")
        XCTAssertEqual(creators(m), [])
        XCTAssertEqual(extra(m), ["Recipient: Political Committee", "File: m.pdf"])

        let c = items[2]
        XCTAssertEqual(c["itemType"] as? String, "newspaperArticle")
        XCTAssertEqual(c["title"] as? String, "Strike Spreads")
        XCTAssertEqual(c["publicationTitle"] as? String, "The Militant")
        XCTAssertEqual(creators(c), ["author: A. Reporter"])
        XCTAssertEqual(c["date"] as? String, "1946")
        XCTAssertEqual(c["archiveLocation"] as? String, "Box 17, Folder 8, Reports 1959-1960")
        XCTAssertTrue(extra(c).contains("Publication date: June 3, 1946"))

        let p = items[3]
        XCTAssertEqual(p["itemType"] as? String, "artwork")
        XCTAssertEqual(p["medium"] as? String, "Photograph")
        XCTAssertEqual(p["archive"] as? String, "Hoover Institution Archives")
    }

    // MARK: Add to Zotero (W47.ct-zotero-tags)

    /// One document of every kind, with every variable the export writes.
    private func everyKind(subjects: [String] = ["Trotskyism", "Labor"]) -> [ZoteroSource] {
        var side = ZoteroSidecar()
        side.authors = ["Max Shachtman"]
        side.recipients = ["Albert Glotzer"]
        side.authorPlaces = ["New York"]
        side.format = "Carbon copy"
        let kinds = ["letter", "telegram", "memo", "report", "speech", "press release", "newspaper article", "clipping",
                     "magazine article", "newsletter", "journal article", "photograph", "other", nil]
        let dates = [["1959", "3 March", "Day 12"], ["1959", "3 March"], ["1959"], ["1970s"], ["1959", "Date Uncertain"]]
        return kinds.enumerated().map { n, kind in
            let fields = PDFItemFields(documentKind: kind, title: "Title \(n)", byline: n % 2 == 0 ? nil : "A. Reporter",
                                       publication: "The Militant", publicationDate: "June 3, 1946",
                                       recipientPlace: "Chicago")
            return ZoteroSource(fileName: "\(n).pdf", tags: tags(dates[n % dates.count] + subjects + ["OCR Poor"]),
                                itemFields: fields, sidecar: side, container: glotzer,
                                link: "archivereader://reveal?n=\(n)")
        }
    }

    /// The connector item is what Zotero's own importer makes of the CSL-JSON item, field for field, plus the tags.
    func testConnectorItemsAreWhatZoteroImportsPlusTags() throws {
        let sources = everyKind()
        let imported = try zoteroImport(ZoteroExport.export(sources))
        let sent = ZoteroExport.connectorItems(sources)
        XCTAssertEqual(imported.count, sent.count)
        func normal(_ item: [String: Any]) -> NSDictionary {
            var item = item
            for key in ["id", "itemID", "tags", "attachments", "seeAlso"] { item[key] = nil }
            item["creators"] = (item["creators"] as? [[String: Any]] ?? []).map { c -> [String: Any] in
                var c = c
                c["creatorTypeID"] = nil
                return c
            }
            return item as NSDictionary
        }
        for (z, s) in zip(imported, sent) {
            XCTAssertEqual(normal(s), normal(z), "\(s["id"] ?? "")")
            XCTAssertEqual(s["id"] as? String, z["itemID"] as? String)
            XCTAssertEqual((s["tags"] as? [[String: String]])?.compactMap { $0["tag"] }, ["Trotskyism", "Labor"])
        }
    }

    func testConnectorItemTagsDatesAndRepeatedNames() {
        let items = ZoteroExport.connectorItems([
            ZoteroSource(fileName: "a.pdf", tags: tags(["1959", "3 March", "OCR Failed", "Unread"])),
            ZoteroSource(fileName: "a.pdf"),
        ])
        XCTAssertEqual(items.compactMap { $0["id"] as? String }, ["a.pdf", "a.pdf (2)"])
        XCTAssertEqual(items[0]["date"] as? String, "March 1959")
        XCTAssertEqual((items[0]["tags"] as? [[String: String]])?.count, 0, "workflow tags are not subjects")
        XCTAssertNil(items[1]["date"])
        XCTAssertEqual(items[1]["itemType"] as? String, "document")
        XCTAssertEqual(ZoteroExport.zoteroDate(["date-parts": [[1946, 6, 3]], "circa": true]), "June 3, 1946")
    }

    func testConnectorPostsBatchesToSaveItemsOnLoopback() async throws {
        let session = ZoteroStub.session()
        ZoteroStub.reset(status: 201)
        let sources = (0..<51).map { ZoteroSource(fileName: "\($0).pdf", tags: tags(["Labor"])) }
        try await ZoteroConnector(port: 23999, session: session).save(sources)
        let requests = ZoteroStub.requests
        XCTAssertEqual(requests.count, 2, "50 items a request")
        for r in requests {
            XCTAssertEqual(r.url?.absoluteString, "http://127.0.0.1:23999/connector/saveItems")
            XCTAssertEqual(r.httpMethod, "POST")
            XCTAssertEqual(r.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(r.value(forHTTPHeaderField: "X-Zotero-Connector-API-Version"), "3")
        }
        let bodies = try requests.map { try XCTUnwrap(JSONSerialization.jsonObject(with: ZoteroStub.body($0)) as? [String: Any]) }
        XCTAssertEqual(bodies.map { ($0["items"] as? [Any])?.count }, [50, 1])
        XCTAssertNotEqual(bodies[0]["sessionID"] as? String, bodies[1]["sessionID"] as? String)
        let first = try XCTUnwrap((bodies[0]["items"] as? [[String: Any]])?.first)
        XCTAssertEqual((first["tags"] as? [[String: String]])?.first?["tag"], "Labor")

        ZoteroStub.reset(status: 500)
        do {
            try await ZoteroConnector(port: 23999, session: session).save(sources)
            XCTFail("a refusal throws")
        } catch let failure as ZoteroConnector.Failure {
            XCTAssertEqual(failure, .refused(status: 500))
        }
        XCTAssertEqual(ZoteroStub.requests.count, 1, "nothing is sent after a refused batch")

        ZoteroStub.reset(status: 200)
        let running = await ZoteroConnector(port: 23999, session: session).isRunning()
        XCTAssertTrue(running)
        XCTAssertEqual(ZoteroStub.requests.first?.url?.path, "/connector/ping")
    }

    func testConnectorWithNothingListeningIsNotRunning() async throws {
        // A port nothing listens on: the real loopback, no stub.
        let connector = ZoteroConnector(port: 9)
        let running = await connector.isRunning()
        XCTAssertFalse(running)
        do {
            try await connector.save([ZoteroSource(fileName: "a.pdf")])
            XCTFail("no Zotero throws")
        } catch let failure as ZoteroConnector.Failure {
            XCTAssertEqual(failure, .notRunning)
        }
    }

    /// Add to Zotero into a real Zotero: every kind is saved, and read back through Zotero's local API with its
    /// fields and its subjects as tags. Runs only where `ARCHIVE_ZOTERO_LIVE=1`: the VM's scratch Zotero
    /// (`Tools/zotero-import/vm-zotero-live.sh`), never a library anyone keeps.
    func testLiveZoteroKeepsFieldsAndTags() async throws {
        guard ProcessInfo.processInfo.environment["ARCHIVE_ZOTERO_LIVE"] == "1" else {
            throw XCTSkip("needs the VM's scratch Zotero (ARCHIVE_ZOTERO_LIVE=1)")
        }
        let marker = "W47 Live \(UUID().uuidString.prefix(8))"
        let sources = everyKind(subjects: ["Trotskyism", "Labor", marker])
        let connector = ZoteroConnector()
        let running = await connector.isRunning()
        XCTAssertTrue(running)
        try await connector.save(sources)

        var query = URLComponents(string: "http://127.0.0.1:\(ZoteroConnector.defaultPort)/api/users/0/items")!
        query.queryItems = [URLQueryItem(name: "tag", value: marker), URLQueryItem(name: "format", value: "json"),
                            URLQueryItem(name: "limit", value: "100")]
        var saved: [[String: Any]] = []
        for _ in 0..<30 {
            let (data, _) = try await URLSession.shared.data(from: query.url!)
            saved = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []).compactMap {
                $0["data"] as? [String: Any]
            }
            if saved.count >= sources.count { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTAssertEqual(saved.count, sources.count)
        // The API names a base field by the type's own name (Letter Type, Manuscript Type, Artwork's Medium).
        let ownNames = ["type": ["letterType", "manuscriptType"], "medium": ["artworkMedium"]]
        for sent in ZoteroExport.connectorItems(sources) {
            let title = sent["title"] as? String
            guard let got = saved.first(where: { $0["title"] as? String == title }) else {
                XCTFail("\(title ?? "?") was not saved")
                continue
            }
            XCTAssertEqual(got["itemType"] as? String, sent["itemType"] as? String, title ?? "")
            for (field, value) in sent {
                guard let value = value as? String, !["id", "itemType"].contains(field) else { continue }
                let stored = (ownNames[field] ?? [field]).lazy.compactMap { got[$0] as? String }.first { !$0.isEmpty }
                XCTAssertEqual(stored, value, "\(title ?? ""): \(field)")
            }
            let names = (got["creators"] as? [[String: Any]] ?? []).map { "\($0["creatorType"] ?? ""): \($0["name"] ?? "")" }
            let sentNames = (sent["creators"] as? [[String: Any]] ?? []).map {
                "\($0["creatorType"] ?? ""): \($0["lastName"] ?? "")"
            }
            XCTAssertEqual(names, sentNames, title ?? "")
            let tags = Set((got["tags"] as? [[String: Any]] ?? []).compactMap { $0["tag"] as? String })
            XCTAssertEqual(tags, ["Trotskyism", "Labor", marker], title ?? "")
        }
    }
}

/// Answers every request with one status and records it.
final class ZoteroStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var status = 201
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ZoteroStub.self]
        return URLSession(configuration: config)
    }
    static func reset(status: Int) { lock.withLock { self.status = status; recorded = [] } }
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = Self.lock.withLock { Self.recorded.append(request); return Self.status }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
