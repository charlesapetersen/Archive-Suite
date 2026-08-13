import XCTest
import AppKit
import ArchiveCore
@testable import ArchiveReader

@MainActor
final class ProvenanceColumnTests: XCTestCase {
    func testProvenanceColumnIsPresentAndHiddenOnlyByDefault() throws {
        let definition = try XCTUnwrap(
            AppKitTableView.columnDefinitions.first { $0.id == "classification" }
        )
        XCTAssertEqual(definition.title, "Provenance")
        XCTAssertNil(definition.sortField, "the backlog asks for display only, not a new sort contract")

        let defaults = fixtureDefaults()
        XCTAssertEqual(AppSettings.hiddenColumns(in: defaults), ["classification"],
                       "a fresh install keeps the optional provenance column out of the default layout")

        defaults.set(["type"], forKey: SettingsKey.hiddenColumns)
        defaults.removeObject(forKey: SettingsKey.provenanceColumnPreferenceV1)
        XCTAssertEqual(AppSettings.hiddenColumns(in: defaults), ["classification", "type"],
                       "an existing customized layout also receives the default-hidden migration")

        AppSettings.setHiddenColumns([], in: defaults)
        XCTAssertTrue(AppSettings.hiddenColumns(in: defaults).isEmpty,
                      "explicitly showing the column must survive relaunch; default-hidden is not always-hidden")
    }

    func testContentIndexBulkClassificationJoinPreservesKnownValuesAndOmitsUnknownRows() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProvenanceColumnIndex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let index = ContentIndex(url: scratch.appendingPathComponent("content.sqlite3"))
        try await index.open()
        try await index.upsert(path: "/box.pdf", mtime: 1, name: "box", classification: "Box", body: "box")
        try await index.upsert(path: "/start.pdf", mtime: 1, name: "start",
                               classification: "Document Start", body: "start")
        try await index.upsert(path: "/legacy.pdf", mtime: 1, name: "legacy", classification: nil, body: "legacy")

        let values = await index.classifications(for: ["/legacy.pdf", "/start.pdf", "/missing.pdf", "/box.pdf"])
        XCTAssertEqual(values, ["/box.pdf": "Box", "/start.pdf": "Document Start"])
        await index.close()
    }

    func testNavigationModelPublishesIndexedClassificationForTheTable() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProvenanceColumnModel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let fileURL = scratch.appendingPathComponent("fixture.pdf")
        try Data("scratch fixture".utf8).write(to: fileURL)
        try (fileURL as NSURL).setResourceValue(["Unread"], forKey: .tagNamesKey)

        let indexer = ContentIndexer(
            url: scratch.appendingPathComponent("content.sqlite3"),
            extractPDFForTesting: { _ in
                ExtractedContent(fullBody: "body", strippedBody: "body",
                                 classification: "Folder", pageCount: 2)
            }
        )
        do {
            let model = NavigationModel(defaults: fixtureDefaults(pinnedTo: scratch), indexer: indexer)
            let indexedPath = try XCTUnwrap(model.library.files.first?.url.path,
                                            "precondition: the fixture root supplies one nav row")
            XCTAssertTrue(indexedPath.hasSuffix("/fixture.pdf"))

            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, indexer.completedPassesForTesting == 0 {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertGreaterThanOrEqual(indexer.completedPassesForTesting, 1,
                                        "the scratch row must actually reach the index")
            let indexed = await indexer.classifications(for: [indexedPath])
            XCTAssertEqual(indexed, [indexedPath: "Folder"],
                           "non-vacuity: the injected row exists before the model joins it")

            model.refreshFormatStatuses()
            let publicationDeadline = Date().addingTimeInterval(10)
            while Date() < publicationDeadline, model.classification(for: indexedPath) == nil {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(model.classification(for: indexedPath), "Folder")
        }
        await indexer.closeForTesting()
        try FileManager.default.removeItem(at: scratch)
    }

    func testProvenanceCellRendersItsValueToPixels() throws {
        let field = NSTextField(labelWithString: "")
        AppKitTableView.Coordinator.configureProvenanceTextField(
            field, classification: "Document Start", fontSize: 13
        )
        XCTAssertEqual(field.stringValue, "Document Start")

        let data = try XCTUnwrap(
            RenderProbe.pngData(fromAppKitView: field, size: CGSize(width: 180, height: 28)),
            "the real table-cell formatter did not produce a bitmap"
        )
        writeRenderArtifact(data, named: "w18-provenance-column.png")
        let image = try XCTUnwrap(RenderProbe.cgImage(fromPNG: data))
        _ = try XCTUnwrap(assertRendersNonBlank(image, "W18 provenance column cell"))
    }
}
