import XCTest
@testable import ArchiveCore

/// The user's item-field values (W40.reader-item-field-edit, SPEC/tag-format.md §Field checks): a strict document in
/// `.archivesuite`, written on scratch directories only through `ContainerFileStore`, never touching anything else.
final class UserItemFieldsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UserItemFieldsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var target: URL { ContainerFileStore.itemFieldsURL(in: dir) }

    func testSetTrimsKeepsNoneAndRemoves() {
        var f = UserItemFields()
        f.set(.title, to: "  A Report  ", for: "0001.pdf")
        f.set(.byline, to: "", for: "0001.pdf")
        f.set(.date, to: "1950", for: "0001.pdf")           // a date is a tag, never stored here
        XCTAssertEqual(f.values(for: "0001.pdf"), [.title: "A Report", .byline: ""])
        f.set(.title, to: nil, for: "0001.pdf")
        f.set(.byline, to: nil, for: "0001.pdf")
        XCTAssertTrue(f.files.isEmpty, "a file with no values left has no entry")
    }

    func testFileNamesMatchComposedOrNot() {
        var f = UserItemFields()
        f.set(.title, to: "Café", for: "Re\u{0301}sume\u{0301}.pdf")   // decomposed
        XCTAssertEqual(f.values(for: "Résumé.pdf"), [.title: "Café"])
    }

    func testAppliedReplacesAndNoneRemoves() {
        let header = PDFItemFields(documentKind: "report", title: "Wrong", byline: "J. Smith")
        let shown = UserItemFields.applied([.title: "Right", .byline: "", .publication: "The Times"], to: header)
        XCTAssertEqual(shown, PDFItemFields(documentKind: "report", title: "Right", publication: "The Times"))
    }

    func testRoundTripOnScratchFolderTouchesNothingElse() throws {
        let pdf = dir.appendingPathComponent("0001.pdf")
        try Data("pdf bytes".utf8).write(to: pdf)
        let before = try Data(contentsOf: pdf)
        XCTAssertEqual(ContainerFileStore.loadItemFields(directory: dir), .missing)

        var f = UserItemFields(updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        f.set(.title, to: "A Report", for: "0001.pdf")
        let stamp = try ContainerFileStore.writeItemFields(f, directory: dir, expecting: nil)
        guard case let .loaded(read, readStamp) = ContainerFileStore.loadItemFields(directory: dir) else {
            return XCTFail("not read back")
        }
        XCTAssertEqual(read, f)
        XCTAssertEqual(readStamp, stamp)
        XCTAssertEqual(try Data(contentsOf: pdf), before)
        let listed = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(listed, [ContainerFile.folderName, "0001.pdf"])
        let json = try String(contentsOf: target, encoding: .utf8)
        XCTAssertTrue(json.contains("\"title\" : \"A Report\""), json)
        XCTAssertTrue(json.contains("\"schemaVersion\" : 1"), json)

        // A second writer that read before the first wrote is refused.
        XCTAssertThrowsError(try ContainerFileStore.writeItemFields(f, directory: dir, expecting: nil)) {
            XCTAssertEqual($0 as? ContainerWriteError, .changedSinceRead)
        }
    }

    func testUnknownKeysAndFieldsAreUnreadableAndNeverOverwritten() throws {
        let suite = dir.appendingPathComponent(ContainerFile.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: suite, withIntermediateDirectories: false)
        for body in [#"{"schemaVersion":1,"files":{"a.pdf":{"sender":"X"}}}"#,
                     #"{"schemaVersion":1,"files":{},"extra":1}"#,
                     #"{"schemaVersion":1,"files":{"a.pdf":{"title":null}}}"#,
                     #"{"files":{}}"#] {
            try Data(body.utf8).write(to: target)
            guard case .unreadable = ContainerFileStore.loadItemFields(directory: dir) else {
                return XCTFail("read \(body)")
            }
            XCTAssertThrowsError(try ContainerFileStore.writeItemFields(UserItemFields(), directory: dir,
                                                                       expecting: nil))
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), body, "left as it was")
        }
        try Data(#"{"schemaVersion":2,"files":{}}"#.utf8).write(to: target)
        XCTAssertEqual(ContainerFileStore.loadItemFields(directory: dir), .newer)
    }

    func testALinkedDocumentIsRefused() throws {
        let suite = dir.appendingPathComponent(ContainerFile.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: suite, withIntermediateDirectories: false)
        let elsewhere = dir.appendingPathComponent("elsewhere.json")
        try Data(#"{"schemaVersion":1,"files":{}}"#.utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: elsewhere)
        guard case .unreadable = ContainerFileStore.loadItemFields(directory: dir) else { return XCTFail("followed") }
        XCTAssertThrowsError(try ContainerFileStore.writeItemFields(UserItemFields(), directory: dir, expecting: nil))
        XCTAssertEqual(try String(contentsOf: elsewhere, encoding: .utf8), #"{"schemaVersion":1,"files":{}}"#)
    }

    func testZoteroExportTakesTheUsersValues() {
        var side = ZoteroSidecar()
        side.format = "Letter"
        let source = ZoteroSource(fileName: "a.pdf", itemFields: PDFItemFields(documentKind: "memo", title: "Wrong"),
                                  sidecar: side)
        var corrected = source
        corrected.userItemFields = [.title: "Right", .documentKind: "report"]
        let item = ZoteroExport.item(corrected)
        XCTAssertEqual(item["title"] as? String, "Right")
        XCTAssertEqual(item["type"] as? String, ZoteroExport.item(ZoteroSource(
            fileName: "b", itemFields: PDFItemFields(documentKind: "report")))["type"] as? String)

        // "None" for the kind: the sidecar's format does not stand in for it.
        var none = source
        none.userItemFields = [.documentKind: ""]
        XCTAssertEqual(ZoteroExport.item(none)["type"] as? String, "document")
    }

    func testGatherReadsTheUsersValuesBesideThePDF() throws {
        let pdf = dir.appendingPathComponent("0001.pdf")
        try Data().write(to: pdf)
        var f = UserItemFields()
        f.set(.publication, to: "The Times", for: "0001.pdf")
        f.set(.publication, to: "Other", for: "0002.pdf")
        try ContainerFileStore.writeItemFields(f, directory: dir, expecting: nil)
        XCTAssertEqual(ZoteroSource.gather(pdf: pdf, lookup: nil).userItemFields, [.publication: "The Times"])
    }
}
