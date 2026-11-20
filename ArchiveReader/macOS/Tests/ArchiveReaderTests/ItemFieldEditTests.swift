import XCTest
import ArchiveCore
@testable import ArchiveReader

/// W40.reader-item-field-edit: correcting a page-2 item field. The user's value goes to the folder's
/// `.archivesuite/item-fields.json` (scratch folders only); the tests check that nothing else changes, that a document
/// this build cannot read is left alone, that undo puts the file back, and what the Checks rows then show.
@MainActor
final class ItemFieldEditTests: XCTestCase {
    private let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ItemFieldEdit-\(UUID().uuidString)", isDirectory: true)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeFolder() throws -> URL {
        let dir = root.appendingPathComponent("Box 17", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for n in ["a.pdf", "b.pdf"] { try Data("scratch fixture \(n)".utf8).write(to: dir.appendingPathComponent(n)) }
        return dir.resolvingSymlinksInPath()
    }

    /// Every path under `root` with its bytes (nil for a folder).
    private func snapshot() throws -> [String: Data?] {
        var out: [String: Data?] = [:]
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let url as URL in e {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            out[url.resolvingSymlinksInPath().path] = isDir.boolValue ? nil : try Data(contentsOf: url)
        }
        return out
    }

    @discardableResult
    private func set(_ field: CheckableField, _ value: String?, _ name: String, in dir: URL) throws
        -> ContainerDocumentRestore? {
        try NavigationModel.editItemFields(at: dir) { f in
            var f = f
            f.set(field, to: value, for: name)
            return f
        }
    }

    func testAnEditWritesOnlyTheFoldersItemFieldFile() throws {
        let dir = try makeFolder()
        let before = try snapshot()
        try set(.title, "The Harbour Report", "a.pdf", in: dir)
        let after = try snapshot()
        let changed = Set(after.keys).union(before.keys).filter { before[$0] != after[$0] }
        let suite = dir.appendingPathComponent(ContainerFile.folderName).path
        let written = ContainerFileStore.itemFieldsURL(in: dir).path
        XCTAssertEqual(changed, [suite, written], "only .archivesuite and the item-field file in it")
        let read = try XCTUnwrap(ContainerFileStore.loadItemFields(directory: dir).document)
        XCTAssertEqual(read.values(for: "a.pdf"), [.title: "The Harbour Report"])
        XCTAssertEqual(read.values(for: "b.pdf"), [:])
        XCTAssertNotNil(read.updatedAt)
    }

    func testNoChangeWritesNothing() throws {
        let dir = try makeFolder()
        let before = try snapshot()
        XCTAssertNil(try set(.title, nil, "a.pdf", in: dir))
        XCTAssertEqual(try snapshot(), before, "not even an empty .archivesuite")
    }

    func testANewerOrUnreadableDocumentIsLeftAsItIs() throws {
        let dir = try makeFolder()
        let suite = dir.appendingPathComponent(ContainerFile.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: suite, withIntermediateDirectories: true)
        let doc = suite.appendingPathComponent(UserItemFields.fileName)
        for bytes in [#"{"schemaVersion": 2, "files": {}}"#, #"{"schemaVersion": 1, "files": {}, "future": 1}"#,
                      #"{"schemaVersion": 1, "files": {"a.pdf": {"signatory": "X"}}}"#, "{ no"] {
            try Data(bytes.utf8).write(to: doc)
            XCTAssertThrowsError(try set(.title, "X", "a.pdf", in: dir)) {
                XCTAssertEqual($0 as? ContainerWriteError, .refusedExisting(UserItemFields.fileName))
            }
            XCTAssertEqual(try String(contentsOf: doc, encoding: .utf8), bytes, "untouched")
            let header = try XCTUnwrap(FieldStatusSection.HeaderFields.read(dir.appendingPathComponent("a.pdf"),
                                                                            isDataless: true))
            XCTAssertNotNil(header.userProblem, "the Inspector says why editing is off")
        }
    }

    func testUndoPutsTheFileBackAndRedoTakesItForward() throws {
        let dir = try makeFolder()
        try set(.title, "First", "a.pdf", in: dir)
        let original = try XCTUnwrap(ContainerFileStore.loadItemFields(directory: dir).document)
        let restore = try XCTUnwrap(try set(.title, "Second", "a.pdf", in: dir))
        let step = ContainerUndoStep(restores: [restore])
        XCTAssertEqual(step.document, .itemFields)
        let undone = step.apply()
        XCTAssertTrue(undone.failures.isEmpty)
        XCTAssertEqual(ContainerFileStore.loadItemFields(directory: dir).document?.files, original.files)
        XCTAssertTrue(undone.inverse.apply().failures.isEmpty)
        XCTAssertEqual(ContainerFileStore.loadItemFields(directory: dir).document?.values(for: "a.pdf"),
                       [.title: "Second"])
    }

    func testUndoLeavesAFileChangedSinceTheEditAlone() throws {
        let dir = try makeFolder()
        let restore = try XCTUnwrap(try set(.byline, "J. Smith", "a.pdf", in: dir))
        try set(.byline, "Another App", "b.pdf", in: dir)
        let before = try snapshot()
        let result = ContainerUndoStep(restores: [restore]).apply()
        XCTAssertEqual(result.failures.first?.error as? ContainerWriteError, .changedSinceRead)
        XCTAssertEqual(try snapshot(), before)
        XCTAssertTrue(containerUndoMessage(result.failures[0].error, .itemFields).contains("item-field file"))
    }

    func testTwoEditsInOneFolderAreUndoneInTurnButAnotherWritersChangeIsNot() throws {
        let dir = try makeFolder()
        let first = try XCTUnwrap(try set(.title, "Title", "a.pdf", in: dir))
        let second = try XCTUnwrap(try set(.byline, "J. Smith", "b.pdf", in: dir))
        let undoSecond = ContainerUndoStep(restores: [second]).apply()
        XCTAssertTrue(undoSecond.failures.isEmpty)
        let undoFirst = ContainerUndoStep(restores: [first]).apply()
        XCTAssertTrue(undoFirst.failures.isEmpty, "\(undoFirst.failures)")
        XCTAssertEqual(ContainerFileStore.loadItemFields(directory: dir).document?.files, [:])

        // Same again, but another writer changes the file between the edit and its undo: the undo is refused.
        let third = try XCTUnwrap(try set(.title, "Mine", "a.pdf", in: dir))
        guard case let .loaded(doc, stamp) = ContainerFileStore.loadItemFields(directory: dir) else { return XCTFail() }
        var other = doc
        other.set(.publication, to: "Theirs", for: "b.pdf")
        try ContainerFileStore.writeItemFields(other, directory: dir, expecting: stamp)
        XCTAssertEqual(ContainerUndoStep(restores: [third]).apply().failures.first?.error as? ContainerWriteError,
                       .changedSinceRead)
        XCTAssertEqual(ContainerFileStore.loadItemFields(directory: dir).document, other)
    }

    func testTheInspectorShowsTheUsersValueCheckedAndTheirNone() throws {
        let dir = try makeFolder()
        try set(.title, "The Right Title", "a.pdf", in: dir)
        try set(.byline, "", "a.pdf", in: dir)
        try set(.publication, "The Times", "a.pdf", in: dir)
        var header = try XCTUnwrap(FieldStatusSection.HeaderFields.read(dir.appendingPathComponent("a.pdf"),
                                                                        isDataless: true))
        XCTAssertNil(header.userProblem)
        header.itemFields = PDFItemFields(documentKind: "report", title: "The Wrong Title", byline: "Somebody")
        let rows = FieldStatusList.rows(tags: DocumentTags.parse(raw: [], labelNumber: nil), header: header)
        XCTAssertEqual(rows.map(\.field), [.documentKind, .title, .byline, .publication])
        XCTAssertEqual(rows.map(\.value), ["report", "The Right Title", FieldStatusList.noneText, "The Times"])
        XCTAssertEqual(rows.map(\.status.level), [.unchecked, .checked, .checked, .checked])
        XCTAssertEqual(rows.map(\.userSet), [false, true, true, true])
        XCTAssertTrue(rows[1].status.source.contains("The Wrong Title"), "page 2's value is in the tooltip")
        XCTAssertTrue(rows[3].status.source.contains("page 2 has none"))
        // Another file in the folder has none of them.
        let other = try XCTUnwrap(FieldStatusSection.HeaderFields.read(dir.appendingPathComponent("b.pdf"),
                                                                       isDataless: true))
        XCTAssertEqual(other.user, [:])
        // Not a PDF: no item fields at all.
        XCTAssertNil(FieldStatusSection.HeaderFields.read(dir.appendingPathComponent("a.jpg"), isDataless: true))
    }

    func testRemovingTheUsersValueBringsPageTwoBack() throws {
        let dir = try makeFolder()
        try set(.title, "Mine", "a.pdf", in: dir)
        try set(.title, nil, "a.pdf", in: dir)
        var header = try XCTUnwrap(FieldStatusSection.HeaderFields.read(dir.appendingPathComponent("a.pdf"),
                                                                        isDataless: true))
        header.itemFields = PDFItemFields(title: "Page Two")
        let rows = FieldStatusList.rows(tags: DocumentTags.parse(raw: [], labelNumber: nil), header: header)
        XCTAssertEqual(rows.map(\.value), ["Page Two"])
        XCTAssertEqual(rows.first?.status.level, .unchecked)
        XCTAssertEqual(ContainerFileStore.loadItemFields(directory: dir).document?.files, [:])
    }

    /// W49.reader-sender-row-check: the sidecar's sender, recipient and sending place are listed after the item fields,
    /// names only with the evidence in the tooltip, and a correction beside the file replaces them, checked.
    func testTheSidecarsNamesAreListedAndCorrectable() throws {
        let dir = try makeFolder()
        let sidecar = """
        {"entities": {"status": "extracted",
          "sender": [{"name": "Max Shachtman", "evidence": "quoted", "quote": "Max"}],
          "recipient": [{"name": "Albert Glotzer", "evidence": "inferred", "inferred_because": "the inside address"},
                        {"name": "J. Cannon", "evidence": "quoted", "quote": "Jim"}],
          "sending_place": [{"name": "Unknown", "evidence": "unknown"}]}}
        """
        try Data(sidecar.utf8).write(to: dir.appendingPathComponent("a.json"))
        let before = try snapshot()
        let tags = DocumentTags.parse(raw: ["Checked Recipient"], labelNumber: nil)
        var header = try XCTUnwrap(FieldStatusSection.HeaderFields.read(dir.appendingPathComponent("a.pdf"),
                                                                        isDataless: false))
        XCTAssertEqual(try snapshot(), before, "reading writes nothing")
        var rows = FieldStatusList.rows(tags: tags, header: header)
        XCTAssertEqual(rows.map(\.field), [.sender, .recipient])
        XCTAssertEqual(rows.map(\.value), ["Max Shachtman", "Albert Glotzer; J. Cannon"])
        XCTAssertEqual(rows.map(\.status.level), [.lowerConfidence, .checked])
        XCTAssertTrue(rows[0].status.detail.contains("“Max”"), rows[0].status.detail)
        XCTAssertFalse(rows[0].value.contains("Max”"), "names only in the row")
        // A placeholder's sidecar is not read.
        XCTAssertNil(try XCTUnwrap(FieldStatusSection.HeaderFields.read(dir.appendingPathComponent("a.pdf"),
                                                                        isDataless: true)).sidecar)

        try set(.sender, "Albert Glotzer", "a.pdf", in: dir)
        try set(.sendingPlace, "New York", "a.pdf", in: dir)
        try set(.recipient, "", "a.pdf", in: dir)
        header = try XCTUnwrap(FieldStatusSection.HeaderFields.read(dir.appendingPathComponent("a.pdf"),
                                                                    isDataless: false))
        rows = FieldStatusList.rows(tags: tags, header: header)
        XCTAssertEqual(rows.map(\.field), [.sender, .recipient, .sendingPlace])
        XCTAssertEqual(rows.map(\.value), ["Albert Glotzer", FieldStatusList.noneText, "New York"])
        XCTAssertEqual(rows.map(\.userSet), [true, true, true])
        XCTAssertTrue(rows[0].status.source.contains("sidecar reads “Max Shachtman”"))
        XCTAssertTrue(rows[2].status.source.contains("sidecar has none"))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("a.json")), Data(sidecar.utf8),
                       "the sidecar is never rewritten")
    }
}
