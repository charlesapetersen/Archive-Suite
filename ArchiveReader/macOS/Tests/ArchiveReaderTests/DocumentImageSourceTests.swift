import XCTest
import ArchiveCore
@testable import ArchiveReader

@MainActor
final class DocumentImageSourceTests: XCTestCase {
    func testLayoutUsesCommonParentAndRecognizesOldMainGrant() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-layout-\(UUID().uuidString)", isDirectory: true)
        let main = parent.appendingPathComponent(ReaderArchiveLayout.mainDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let layout = ReaderArchiveLayout(grantedRoot: parent)
        XCTAssertEqual(layout.mainRoot, main)
        XCTAssertEqual(layout.jpegRoot.lastPathComponent, ReaderArchiveLayout.jpegDirectoryName)
        XCTAssertFalse(layout.needsCommonParentGrant)
        XCTAssertTrue(ReaderArchiveLayout(grantedRoot: main).needsCommonParentGrant)
        XCTAssertTrue(ReaderArchiveLayout(grantedRoot: layout.jpegRoot).needsCommonParentGrant,
                      "selecting the JPEGS subtree alone must not make it Reader's writable MAIN")
    }

    func testMainContainmentKeepsCanonicallyEquivalentPathsDistinct() {
        let composedRoot = "/tmp/archive/caf\u{00e9}/Archival Photos"
        let decomposedSibling = "/tmp/archive/cafe\u{0301}/Archival Photos/scan.pdf"
        XCTAssertFalse(ReaderArchiveLayout.isContained(path: decomposedSibling,
                                                       underRootPath: composedRoot))
        XCTAssertTrue(ReaderArchiveLayout.isContained(path: composedRoot + "/scan.pdf",
                                                      underRootPath: composedRoot))
    }

    func testImageSourcePreferenceIsPerArchiveAndPerPDF() {
        let suiteName = "DocumentImageSourceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = DocumentImageSourcePreferences(defaults: defaults)
        let firstRoot = UUID()
        let secondRoot = UUID()

        XCTAssertEqual(preferences.source(rootGUID: firstRoot, relativePath: "Box/a.pdf"), .pdf)
        preferences.set(.jpeg, rootGUID: firstRoot, relativePath: "Box/a.pdf")
        XCTAssertEqual(preferences.source(rootGUID: firstRoot, relativePath: "Box/a.pdf"), .jpeg)
        XCTAssertEqual(preferences.source(rootGUID: firstRoot, relativePath: "Box/b.pdf"), .pdf)
        XCTAssertEqual(preferences.source(rootGUID: secondRoot, relativePath: "Box/a.pdf"), .pdf)
        preferences.set(.pdf, rootGUID: firstRoot, relativePath: "Box/a.pdf")
        XCTAssertEqual(preferences.source(rootGUID: firstRoot, relativePath: "Box/a.pdf"), .pdf)
    }

    func testOldSceneSelectionDecodesWithoutJPEGFields() throws {
        let oldPayload = Data(#"{"filePaths":["/tmp/letter.pdf"],"initialPage":2}"#.utf8)
        let selection = try JSONDecoder().decode(DocumentSelection.self, from: oldPayload)
        XCTAssertEqual(selection.filePaths, ["/tmp/letter.pdf"])
        XCTAssertEqual(selection.initialPage, 2)
        XCTAssertNil(selection.jpegRelativePath)
        XCTAssertFalse(selection.pinsJPEGPartner)
    }
}
