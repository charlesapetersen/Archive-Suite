import XCTest
import PDFKit
import AppKit
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

    /// W40.fix-reader-jpeg-toolbar: the toolbar's PDF / JPEG switch is disabled without a partner, and its
    /// tooltip says why. Each way of having no partner gives its own reason; a found partner gives none.
    func testNoJPEGPartnerGivesTheReason() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-jpeg-reason-\(UUID().uuidString)", isDirectory: true)
        let main = parent.appendingPathComponent(ReaderArchiveLayout.mainDirectoryName, isDirectory: true)
        let jpegRoot = parent.appendingPathComponent(ReaderArchiveLayout.jpegDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: jpegRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let jpegData = try Self.grayJPEG()
        let pdf = main.appendingPathComponent("letter.pdf")
        let doc = PDFDocument()
        doc.insert(try XCTUnwrap(PDFPage(image: try XCTUnwrap(NSImage(data: jpegData)))), at: 0)
        XCTAssertTrue(doc.write(to: pdf))
        let jpeg = jpegRoot.appendingPathComponent("letter.jpg")
        try jpegData.write(to: jpeg)

        let target = ArchiveLinkTarget(rootPath: parent.path,
                                       marker: RootMarker(guid: UUID(), name: "scratch", kind: .reader, createdAt: Date()),
                                       mainRootPath: main.path)
        func candidate(_ url: URL, dataless: Bool = false) -> JPEGPartnerCandidate {
            JPEGPartnerCandidate(stem: "letter", path: url.path,
                                 collectionContext: url.deletingLastPathComponent().lastPathComponent,
                                 fingerprint: CorpusFileFingerprint(mtime: 1, ctime: 1, size: Int64(jpegData.count),
                                                                    inode: 1, isDataless: dataless))
        }
        func index(_ candidates: [JPEGPartnerCandidate]) -> JPEGPartnerIndex {
            JPEGPartnerIndex(jpegRootPath: jpegRoot.path, candidates: candidates,
                             isClean: true, filesSeen: candidates.count)
        }
        func reason(target: ArchiveLinkTarget?, index: JPEGPartnerIndex?) -> (Bool, String?) {
            let model = DocumentViewerModel(persists: false, thumbnailer: nil)
            model.updateArchiveContext(target: target, index: index)
            model.load(DocumentSelection(filePaths: [pdf.path]))
            return (model.hasJPEGPartner, model.jpegUnavailableReason)
        }

        let (outside, outsideReason) = reason(target: nil, index: nil)
        XCTAssertFalse(outside)
        XCTAssertTrue(outsideReason?.contains("not inside an open archive") == true, "\(outsideReason ?? "nil")")

        let (_, noFolder) = reason(target: target, index: nil)
        XCTAssertTrue(noFolder?.contains(ReaderArchiveLayout.jpegDirectoryName) == true, "\(noFolder ?? "nil")")

        let (_, noFile) = reason(target: target, index: index([]))
        XCTAssertTrue(noFile?.contains("no file with this file's name") == true, "\(noFile ?? "nil")")

        let other = jpegRoot.appendingPathComponent("Box B/letter.jpg")
        let nested = jpegRoot.appendingPathComponent("Box A/letter.jpg")
        let (_, twoFiles) = reason(target: target, index: index([candidate(nested), candidate(other)]))
        XCTAssertTrue(twoFiles?.contains("More than one JPEG") == true, "\(twoFiles ?? "nil")")

        let (_, notDownloaded) = reason(target: target, index: index([candidate(jpeg, dataless: true)]))
        XCTAssertTrue(notDownloaded?.contains("not downloaded") == true, "\(notDownloaded ?? "nil")")

        let (found, foundReason) = reason(target: target, index: index([candidate(jpeg)]))
        XCTAssertTrue(found)
        XCTAssertNil(foundReason, "a document with a JPEG original has no reason to show")
    }

    private static func grayJPEG() throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 50,
                                                 bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<40 { for y in 0..<50 { rep.setColor(.gray, atX: x, y: y) } }
        return try XCTUnwrap(rep.representation(using: .jpeg, properties: [:]))
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
