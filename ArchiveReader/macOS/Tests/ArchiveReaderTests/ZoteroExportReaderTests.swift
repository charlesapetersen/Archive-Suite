import XCTest
import ArchiveCore
@testable import ArchiveReader

/// W47.ct-zotero: Selection ▸ Export to Zotero… sends the container as the Container column shows it, and is never
/// saved inside the archive folder. Every tree is a scratch directory.
@MainActor
final class ZoteroExportReaderTests: XCTestCase {
    private let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ZoteroExportReader-\(UUID().uuidString)", isDirectory: true)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTheExportCarriesTheContainerColumnsValues() throws {
        let box = root.appendingPathComponent("Hoover Institution Archives").appendingPathComponent("Box 17")
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        try ContainerFileStore.writeLevelMap(ContainerLevelMap(levels: [.repository, .box]), root: root, expecting: nil)
        let pdf = box.appendingPathComponent("0003.pdf")
        try Data("scratch fixture".utf8).write(to: pdf)
        try Data(#"{"author_name": "A. Writer", "recipient_name": "B. Reader"}"#.utf8)
            .write(to: box.appendingPathComponent("0003.json"))

        let catalog = ContainerCatalog.build(treeRoot: root, rootPath: root.path, filePaths: [pdf.path])
        let container = NavigationModel.zoteroContainer(catalog.rows[pdf.path])
        XCTAssertEqual(container[.repository], "Hoover Institution Archives")
        XCTAssertEqual(container[.container], "Box 17")
        XCTAssertEqual(NavigationModel.zoteroContainer(nil), [:])

        var source = ZoteroSource(fileName: pdf.lastPathComponent, tags: DocumentTags.parse(raw: ["1959"], labelNumber: nil),
                                  container: container)
        source.sidecar = ZoteroSidecar.read(pdf: pdf)
        let item = ZoteroExport.item(source)
        XCTAssertEqual(item["archive"] as? String, "Hoover Institution Archives")
        XCTAssertEqual(item["archive_location"] as? String, "Box 17")
        XCTAssertEqual((item["author"] as? [[String: String]])?.first?["literal"], "A. Writer")
        XCTAssertEqual(item["note"] as? String, "Recipient: B. Reader\nFile: 0003.pdf",
                       "a Document has no recipient field, so the recipient goes into Extra")
    }

    /// W40.reader-item-field-edit: the user's corrected title and "none" byline reach the export.
    func testTheExportCarriesTheUsersItemFieldValues() throws {
        let box = root.appendingPathComponent("Box 17", isDirectory: true)
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        let pdfs = ["0001.pdf", "0002.pdf"].map { box.appendingPathComponent($0) }
        for pdf in pdfs { try Data("scratch fixture".utf8).write(to: pdf) }
        var fields = UserItemFields()
        fields.set(.title, to: "The Right Title", for: "0001.pdf")
        fields.set(.documentKind, to: "report", for: "0001.pdf")
        try ContainerFileStore.writeItemFields(fields, directory: box.resolvingSymlinksInPath(), expecting: nil)
        let sources = NavigationModel.gatherZotero(pdfs.map { ZoteroSource(fileName: $0.lastPathComponent) },
                                                   urls: pdfs, tree: nil)
        XCTAssertEqual(sources[0].userItemFields, [.title: "The Right Title", .documentKind: "report"])
        XCTAssertEqual(sources[1].userItemFields, [:])
        XCTAssertEqual(ZoteroExport.item(sources[0])["title"] as? String, "The Right Title")
    }

    /// W49.storage-notes-zotero: a folder in catalogue mode exports each PDF's record, as Notes reads a source link;
    /// the sidecar and the folder's corrections beside it are not read, and a file outside the root keeps its place.
    func testCatalogueModeExportsTheRecordAloneInFileOrder() throws {
        let box = root.appendingPathComponent("Box 17", isDirectory: true)
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        let fileID = UUID(), content = UUID(), document = UUID()
        let pdf = box.appendingPathComponent("0001.pdf")
        try Data("scratch fixture".utf8).write(to: pdf)
        func field(_ value: String) -> String {
            #"{"state":"value","value":\#(value),"fieldRevision":"\#(UUID())","origin":"user"}"#
        }
        try Data("""
        {"schema":1,"fileID":"\(fileID)","contentRevision":"\(content)","revision":"\(UUID())","parents":[],
         "pages":[{"id":"\(UUID())","physicalIndex":0,"documentID":"\(document)","role":"searchable"}],
         "documents":[{"id":"\(document)","ownerFileID":"\(fileID)","fields":{"title":\(field(#""From the record""#)),
           "senders":\(field(#"["Record Sender"]"#))}}],"fileFields":{}}
        """.utf8).write(to: box.appendingPathComponent(CatalogueRecord.companionFilename(forPDFFilename: "0001.pdf")))
        try Data(#"{"author_name": "Stale Sender"}"#.utf8).write(to: box.appendingPathComponent("0001.json"))
        var fields = UserItemFields()
        fields.set(.title, to: "An Earlier Correction", for: "0001.pdf")
        try ContainerFileStore.writeItemFields(fields, directory: box.resolvingSymlinksInPath(), expecting: nil)
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("zotero-elsewhere-\(UUID()).pdf")
        try Data("scratch fixture".utf8).write(to: elsewhere)
        defer { try? FileManager.default.removeItem(at: elsewhere) }

        let identify: CatalogueReader.IdentifyPDF = { _, _ in .init(fileID: fileID, contentRevision: content, pageCount: 1) }
        let rootPath = CorpusWalker.discoveredPathPrefix(for: root) ?? root.path
        let inRoot = URL(fileURLWithPath: rootPath).appendingPathComponent("Box 17/0001.pdf")
        let sources = NavigationModel.gatherCatalogueZotero(
            [elsewhere, inRoot].map { ZoteroSource(fileName: $0.lastPathComponent) }, urls: [elsewhere, inRoot],
            tree: nil, root: root, identifyPDF: identify)
        XCTAssertEqual(sources.count, 2)
        XCTAssertEqual(sources[0].fileName, elsewhere.lastPathComponent)
        XCTAssertNotNil(sources[0].catalogueUnavailable, "a file outside the granted root has no record here")
        let item = ZoteroExport.item(sources[1])
        XCTAssertNil(sources[1].catalogueUnavailable)
        XCTAssertEqual(item["title"] as? String, "From the record")
        XCTAssertEqual((item["author"] as? [[String: String]])?.map { $0["literal"] }, ["Record Sender"])
        XCTAssertFalse((item["note"] as? String ?? "").contains("Stale"))
    }

    func testTheExportIsNeverSavedInsideTheArchive() throws {
        let inner = root.appendingPathComponent("Box 17", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("zotero-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = outside.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: inner)

        let refuse = "Save the Zotero export outside the archive folder."
        XCTAssertEqual(NavigationModel.zoteroDestinationRefusal(root.appendingPathComponent("x.json"), protecting: [root]), refuse)
        XCTAssertEqual(NavigationModel.zoteroDestinationRefusal(inner.appendingPathComponent("0003.json"), protecting: [root]),
                       refuse)
        XCTAssertEqual(NavigationModel.zoteroDestinationRefusal(link.appendingPathComponent("x.json"), protecting: [root]),
                       refuse, "a link into the archive is the archive")
        XCTAssertEqual(NavigationModel.zoteroDestinationRefusal(
            URL(fileURLWithPath: root.path.uppercased()).appendingPathComponent("x.json"), protecting: [root]), refuse)
        XCTAssertNil(NavigationModel.zoteroDestinationRefusal(outside.appendingPathComponent("x.json"), protecting: [root]))
        XCTAssertEqual(NavigationModel.zoteroDestinationRefusal(outside.appendingPathComponent("x.json"),
                                                                protecting: [root, outside]), refuse,
                       "a selected file's own folder is protected too")
        XCTAssertNil(NavigationModel.zoteroDestinationRefusal(outside.appendingPathComponent("x.json"), protecting: []))
    }

    func testFileName() {
        XCTAssertEqual(NavigationModel.zoteroExportName([URL(fileURLWithPath: "/a/0003 Letter.pdf")]),
                       "0003 Letter (Zotero).json")
        XCTAssertEqual(NavigationModel.zoteroExportName([URL(fileURLWithPath: "/a/1.pdf"), URL(fileURLWithPath: "/a/2.pdf")]),
                       "Zotero export.json")
    }

    /// W47.ct-zotero-tags: what Add to Zotero reports.
    func testAddToZoteroMessages() {
        XCTAssertEqual(NavigationModel.zoteroAddedMessage(count: 2, failure: nil),
                       "Added 2 documents to Zotero, with their subjects as tags, in the library or collection selected there.")
        XCTAssertTrue(NavigationModel.zoteroAddedMessage(count: 1, failure: .notRunning).hasPrefix("Zotero is not running"))
        XCTAssertTrue(NavigationModel.zoteroAddedMessage(count: 1, failure: .refused(status: 500))
            .contains("did not add the 1 document (it answered 500)"))
    }
}
