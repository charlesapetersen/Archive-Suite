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
}
