import XCTest
@testable import ArchiveCore

/// How a container's values are shown (`SPEC/containers.md` §Showing a value; W47.ct-normalise): title case, the
/// user's standard names, and their file beside the level map. Invented names throughout.
final class ContainerNamesTests: XCTestCase {
    private func record(_ values: [ContainerField: [ContainerValue]]) -> ResolvedContainer {
        let scope = ContainerScope(pathFields: ContainerFieldSet(values.compactMapValues(\.first)))
        var r = ContainerResolver.resolve(fileName: "0001.pdf", scopes: [scope])
        r.candidates = values
        return r
    }

    private func label(_ s: String) -> ContainerValue { ContainerValue(s, source: .label, reader: "vision+parser") }

    private let libraryA = "Special Collections, Example Library, Example University"
    private let libraryB = "Example University Library Special Collections"
    private let standard = "Example University, Example Library"

    func testAValueInCapitalsIsShownInTitleCaseWithAcronymsKept() {
        let shown = ContainerDisplay.values(record([.container: [label("BOX 12")],
                                                    .collectionTitle: [label("JANE DOE PAPERS")],
                                                    .repository: [label("UCLA")],
                                                    .collectionNumber: [label("MSS 1036")],
                                                    .folderTitle: [label("Reports of the Board")]]))
        XCTAssertEqual(shown[.container]?.text, "Box 12")
        XCTAssertEqual(shown[.container]?.asWritten, "BOX 12")
        XCTAssertEqual(shown[.collectionTitle]?.text, "Jane Doe Papers")
        XCTAssertEqual(shown[.repository]?.text, "UCLA")
        XCTAssertEqual(shown[.collectionNumber]?.text, "MSS 1036", "no vowel: an abbreviation")
        XCTAssertEqual(shown[.folderTitle]?.text, "Reports of the Board", "mixed case is the writer's")
        XCTAssertFalse(shown[.container]!.byStandardName)
        XCTAssertEqual(ContainerDisplay.values(record([.repository: [label("ACME ARCHIVE")]]),
                                               keeping: ["ACME"])[.repository]?.text, "ACME Archive")
    }

    func testTwoWordingsOfOneLibraryShowAsTheStandardName() {
        var names = ContainerNames()
        names.set(ContainerStandardName(field: .repository, standard: standard, variants: [libraryA, libraryB]))
        for written in [libraryA, libraryB, libraryB.uppercased(), "special collections  example library; example university"] {
            let shown = ContainerDisplay.values(record([.repository: [label(written)]]), names: names)[.repository]
            XCTAssertEqual(shown?.text, standard, written)
            XCTAssertEqual(shown?.asWritten, written)
            XCTAssertEqual(shown?.byStandardName, true)
        }
        // A standard name is per field: the same words as a collection title are left alone.
        XCTAssertEqual(ContainerDisplay.values(record([.collectionTitle: [label(libraryB)]]), names: names)[.collectionTitle]?.text,
                       libraryB)
        // An unmatched wording falls back to title case; the standard name is shown as the user wrote it.
        XCTAssertEqual(ContainerDisplay.values(record([.repository: [label("OTHER LIBRARY")]]), names: names)[.repository]?.text,
                       "Other Library")
    }

    func testTwoWordingsUnderOneStandardNameDoNotDisagree() {
        let r = record([.repository: [label(libraryA), label(libraryB)], .container: [label("BOX 12"), label("Box 12.")]])
        XCTAssertEqual(r.disagreements, [.repository, .container])
        XCTAssertEqual(ContainerDisplay.disagreements(r), [.repository])
        var names = ContainerNames()
        names.set(ContainerStandardName(field: .repository, standard: standard, variants: [libraryA, libraryB]))
        XCTAssertEqual(ContainerDisplay.disagreements(r, names: names), [])
        let three = record([.repository: [label(libraryA), label("Another Library")]])
        XCTAssertEqual(ContainerDisplay.disagreements(three, names: names), [.repository])
    }

    func testAStandardNameSaysWhichPartsGoIntoWhichField() {
        var names = ContainerNames()
        names.set(ContainerStandardName(field: .repository, variants: ["Example Archives, Example City"],
                                        fields: [.repository: "Example Archives", .place: "Example City"]))
        // A collection title that was really the repository: shown nowhere as a title, the repository filled.
        names.set(ContainerStandardName(field: .collectionTitle, variants: ["Example Archives"],
                                        fields: [.repository: "Example Archives"]))
        let shown = ContainerDisplay.values(record([.repository: [label("EXAMPLE ARCHIVES, EXAMPLE CITY")]]), names: names)
        XCTAssertEqual(shown[.repository]?.text, "Example Archives")
        XCTAssertEqual(shown[.place]?.text, "Example City")
        XCTAssertNil(shown[.place]?.asWritten)

        // The record's own value, and a user's "none here", are not overwritten by another field's standard name.
        let own = ContainerDisplay.values(record([.repository: [label("Example Archives, Example City")],
                                                  .place: [label("ELSEWHERE")]]), names: names)
        XCTAssertEqual(own[.place]?.text, "Elsewhere")
        let none = ContainerDisplay.values(record([.repository: [label("Example Archives, Example City")],
                                                   .place: [ContainerValue("", source: .user)]]), names: names)
        XCTAssertNil(none[.place])

        let moved = ContainerDisplay.values(record([.collectionTitle: [label("EXAMPLE ARCHIVES")]]), names: names)
        XCTAssertNil(moved[.collectionTitle])
        XCTAssertEqual(moved[.repository]?.text, "Example Archives")
    }

    func testAWordingBelongsToOneEntryAndTheNewestWins() {
        var names = ContainerNames()
        names.set(ContainerStandardName(field: .repository, standard: "First", variants: [libraryA, libraryB]))
        names.set(ContainerStandardName(field: .repository, standard: standard, variants: [libraryB.uppercased(), "", libraryB]))
        XCTAssertEqual(names.names.count, 2)
        XCTAssertEqual(names.names[0].variants, [libraryB.uppercased()], "an empty and a repeated wording are left out")
        XCTAssertEqual(names.names[1].variants, [libraryA])
        XCTAssertEqual(names.entry(for: .repository, matching: libraryB)?.shown(.repository), standard)
        XCTAssertEqual(names.entry(for: .repository, matching: libraryA)?.shown(.repository), "First")
        // Taking every wording of an entry, its own standard name included, drops it.
        names.set(ContainerStandardName(field: .repository, standard: "Third", variants: [libraryA, "First"]))
        XCTAssertEqual(names.names.map { $0.shown(.repository) }, ["Third", standard])
        names.remove(field: .repository, matching: "third")
        XCTAssertEqual(names.names.map { $0.shown(.repository) }, [standard])
        XCTAssertNil(names.entry(for: .repository, matching: "   "))
    }

    func testTheKeyFoldsCaseAccentsAndPunctuation() {
        XCTAssertEqual(ContainerNames.key("Bibliothèque  NATIONALE, Paris."), "bibliotheque nationale paris")
        XCTAssertEqual(ContainerNames.key("Smith & Jones"), ContainerNames.key("SMITH AND JONES"))
        XCTAssertEqual(ContainerNames.key(" -- "), "")
    }

    func testTheFileRoundTripsBesideTheLevelMapAndIsStrict() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContainerNamesTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let deep = root.appendingPathComponent("Collection/Box 1", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var names = ContainerNames(updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        names.set(ContainerStandardName(field: .repository, variants: [libraryA],
                                        fields: [.repository: standard, .place: "Example City"]))
        XCTAssertNil(ContainerFileStore.locateNames(from: deep, within: root))
        XCTAssertEqual(ContainerFileStore.loadNames(root: root), .missing)
        try ContainerFileStore.writeNames(names, root: root, expecting: nil)
        XCTAssertEqual(ContainerFileStore.loadNames(root: root).document, names)
        XCTAssertEqual(ContainerFileStore.locateNames(from: deep, within: root)?.standardizedFileURL.pathComponents,
                       root.standardizedFileURL.pathComponents)
        XCTAssertNil(ContainerFileStore.locateLevelMap(from: deep, within: root), "the names are not a level map")
        // Only the new file, inside `.archivesuite`.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), [".archivesuite", "Collection"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent(ContainerFile.folderName).path), [ContainerNames.fileName])

        // A field this build does not know makes the document unreadable, and it is not overwritten.
        let url = ContainerFileStore.namesURL(in: root)
        let newer = #"{"names":[{"field":"repository","variants":["x"],"fields":{"shelf":"y"}}],"schemaVersion":1}"#
        try Data(newer.utf8).write(to: url)
        guard case .unreadable = ContainerFileStore.loadNames(root: root) else { return XCTFail("read a field it does not know") }
        XCTAssertThrowsError(try ContainerFileStore.writeNames(names, root: root, expecting: nil)) { error in
            guard case ContainerWriteError.refusedExisting = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), newer)

        // So do an unknown field to match and an unknown key, at the top or in an entry; a null is no value.
        for doc in [#"{"names":[{"field":"shelf","variants":["x"],"fields":{}}],"schemaVersion":1}"#,
                    #"{"aliases":[],"names":[],"schemaVersion":1}"#,
                    #"{"names":[{"field":"place","note":"n","variants":["x"],"fields":{}}],"schemaVersion":1}"#] {
            try Data(doc.utf8).write(to: url)
            guard case .unreadable = ContainerFileStore.loadNames(root: root) else { return XCTFail(doc) }
        }
        try Data(#"{"aliases":null,"names":[],"schemaVersion":1}"#.utf8).write(to: url)
        XCTAssertEqual(ContainerFileStore.loadNames(root: root).document, ContainerNames())
    }

    func testTheLevelMapRefusesAKeyItDoesNotKnow() throws {
        let decode = { (s: String) in try JSONDecoder().decode(ContainerLevelMap.self, from: Data(s.utf8)) }
        XCTAssertNoThrow(try decode(#"{"levels":["box"],"overrides":{"a":{"role":"ignore","children":null}},"schemaVersion":1}"#))
        XCTAssertThrowsError(try decode(#"{"levels":["box"],"depthNames":[],"schemaVersion":1}"#))
        XCTAssertThrowsError(try decode(#"{"levels":["box"],"overrides":{"a":{"role":"ignore","why":"x"}},"schemaVersion":1}"#))
    }

    func testFillsComeFromTheNewestEntryAndAFullWidthAmpersandIsAnd() {
        var names = ContainerNames()
        names.set(ContainerStandardName(field: .repository, variants: ["Old Archive"],
                                        fields: [.repository: "Old Archive", .place: "Old Town"]))
        names.set(ContainerStandardName(field: .collectionTitle, variants: ["Doe Papers"],
                                        fields: [.collectionTitle: "Jane Doe Papers", .place: "New Town"]))
        let shown = ContainerDisplay.values(record([.repository: [label("Old Archive")],
                                                    .collectionTitle: [label("DOE PAPERS")]]), names: names)
        XCTAssertEqual(shown[.place]?.text, "New Town")
        XCTAssertEqual(ContainerNames.key("Smith ＆ Jones"), ContainerNames.key("smith and jones"))
    }
}
