import XCTest
@testable import ArchiveReader
import ArchiveCore

/// W40.suite-item-types: Box and Folder are item types, written as their tag; colour is the user's. These
/// run on throwaway temp files only — NEVER the corpus — through the real `TagWriter`.
@MainActor
final class ItemTypeTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ItemTypeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        ArchiveLibrary().setRootItemTypeColours(.none)
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func makeFile(_ name: String, tags: [String], label: Int? = nil) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data("PDF-BYTES-\(UUID().uuidString)".utf8).write(to: url)
        if !tags.isEmpty { try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey) }
        if let label { try (url as NSURL).setResourceValue(label, forKey: .labelNumberKey) }
        return url
    }

    private func read(_ url: URL, colours: ItemTypeColors = .redBoxPurpleFolder) throws -> DocumentTags {
        guard case let .success(names, label) = TagReading.read(url) else { throw XCTSkip("unreadable") }
        return DocumentTags.parse(raw: names, labelNumber: label, colours: colours)
    }

    private func setType(_ type: ItemType?, on url: URL) throws {
        let delta = TagEditing.delta(for: .setItemType(type), given: try read(url))
        _ = try TagWriter.apply(delta, to: url)
    }

    /// An older Red box photo, re-typed as a folder: the Folder token is written and the Red label, which
    /// would still read as a box, is cleared with its token. A subject `box` and the bytes are untouched.
    func testRetypingAnOlderColourMarkedFileWritesTheTokenAndClearsTheStaleColour() throws {
        let url = try makeFile("old-box.pdf", tags: ["Red", "box", "Unread"], label: 6)
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(try read(url).itemType, .box, "read through the root's colours")
        XCTAssertNil(try read(url, colours: .none).itemType, "a colour alone is no type")

        try setType(.folder, on: url)
        let after = try read(url)
        XCTAssertEqual(after.itemType, .folder)
        XCTAssertEqual(after.itemTypeToken, "Folder")
        XCTAssertEqual(after.labelNumber ?? 0, 0)
        XCTAssertFalse(after.raw.contains("Red"))
        XCTAssertTrue(after.raw.contains("box"), "a subject box is not the type")
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    /// Confirming the type a colour already gave writes the token and keeps the user's colour.
    func testConfirmingTheColourTypeWritesTheTokenAndKeepsTheColour() throws {
        let url = try makeFile("old-folder.pdf", tags: ["Purple", "Unread"], label: 3)
        try setType(.folder, on: url)
        let after = try read(url, colours: .none)
        XCTAssertEqual(after.itemType, .folder, "the token now carries it on its own")
        XCTAssertEqual(after.labelNumber, 3)
        XCTAssertTrue(after.raw.contains("Purple"))
    }

    /// Clearing the type removes the token and a colour that still means a type, so the file reads as none;
    /// a colour that means nothing under the root's setting stays.
    func testClearingTheTypeRemovesTokenAndTypeColourOnly() throws {
        let typed = try makeFile("typed.pdf", tags: ["Red", "Box", "1948"], label: 6)
        try setType(nil, on: typed)
        let t = try read(typed)
        XCTAssertNil(t.itemType)
        XCTAssertEqual(t.labelNumber ?? 0, 0)
        XCTAssertEqual(t.raw, ["1948"])

        let green = try makeFile("green.pdf", tags: ["Green", "Folder"], label: 2)
        try setType(nil, on: green)
        let g = try read(green)
        XCTAssertNil(g.itemType)
        XCTAssertEqual(g.labelNumber, 2, "the user's own colour, not a type colour, stays")
    }

    /// The per-root answer round-trips, stays absent until given, and is kept per root.
    func testRootColoursArePerRootAndAbsentUntilAnswered() throws {
        let suite = "ItemTypeTests-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let a = UUID(), b = UUID()
        XCTAssertNil(ItemTypePreferences.rootColours(for: a, d))
        ItemTypePreferences.setRootColours(.redBoxPurpleFolder, for: a, d)
        ItemTypePreferences.setRootColours(.none, for: b, d)
        XCTAssertEqual(ItemTypePreferences.rootColours(for: a, d), .redBoxPurpleFolder)
        XCTAssertEqual(ItemTypePreferences.rootColours(for: b, d), ItemTypeColors.none)
        XCTAssertEqual(ItemTypePreferences.markerColours(d), ItemTypeColors.none, "no marker colour by default")
        ItemTypePreferences.setMarkerColour(.blue, for: .box, d)
        XCTAssertEqual(ItemTypePreferences.markerColours(d), ItemTypeColors(box: .blue))
    }

    /// The library reads rows through the root's colours, and re-reads them when the answer changes.
    func testLibraryRowsFollowTheRootColours() throws {
        let url = try makeFile("row.pdf", tags: ["Purple"], label: 3)
        let entry = CorpusEntry(url: url, tagNames: ["Purple"], labelNumber: 3,
                                contentModified: Date(timeIntervalSince1970: 1_000),
                                contentTypeIdentifier: "com.adobe.pdf", isDataless: false)
        let library = ArchiveLibrary()
        library.setRootItemTypeColours(.none)
        XCTAssertNil(ArchiveLibrary.row(entry, tagNames: ["Purple"], labelNumber: 3).itemType)
        library.setRootItemTypeColours(.redBoxPurpleFolder)
        XCTAssertEqual(ArchiveLibrary.row(entry, tagNames: ["Purple"], labelNumber: 3).itemType, .folder)
    }

    /// The list marker: the user's colour as a dot, or, with none chosen (the default), the type's name.
    func testNameCellShowsTheTypeNameOrTheChosenColour() {
        let named = NSTextField(labelWithString: "")
        AppKitTableView.Coordinator.configureNameTextField(
            named, name: "00001.pdf", dotColor: nil, typeLabel: ItemType.box.displayName,
            disambiguator: nil, snippet: nil, fontSize: 13)
        XCTAssertTrue(named.attributedStringValue.string.hasPrefix("Box · 00001.pdf"))
        XCTAssertFalse(named.attributedStringValue.string.contains("●"))

        let dotted = NSTextField(labelWithString: "")
        AppKitTableView.Coordinator.configureNameTextField(
            dotted, name: "00001.pdf", dotColor: ItemTypePreferences.nsColor(.blue), typeLabel: nil,
            disambiguator: nil, snippet: nil, fontSize: 13)
        XCTAssertTrue(dotted.attributedStringValue.string.hasPrefix("● 00001.pdf"))
    }
}
