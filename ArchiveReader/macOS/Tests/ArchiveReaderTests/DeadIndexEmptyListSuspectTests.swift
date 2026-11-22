import XCTest
import SwiftUI
@testable import ArchiveReader

/// Regression for S-003 using a disposable corrupt index and a scratch archive.
@MainActor
final class DeadIndexEmptyListSuspectTests: XCTestCase {

    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DeadIndexEmptyListSuspectTests-root-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for name in ["Smith letter.pdf", "Jones memo.pdf"] {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("scratch PDF \(name)".utf8).write(to: url)
            try (url as NSURL).setResourceValue(["Unread"], forKey: .tagNamesKey)
        }
        return root
    }

    /// 1 KiB of non-header bytes, as `ContentIndexerFailureTests` and the VM fixture's `AR_GUI_CORRUPT_INDEX` use:
    /// SQLite opens the file, then fails on the first statement.
    private func garbageIndex() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cix-s003-\(UUID().uuidString).sqlite3")
        addTeardownBlock {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
        }
        try Data(repeating: 0x5A, count: 1024).write(to: url)
        return url
    }

    func testS003ADeadIndexExplainsWhyOCRSearchIsUnavailable() async throws {
        let root = try makeRoot()
        let model = NavigationModel(defaults: fixtureDefaults(pinnedTo: root),
                                    indexer: ContentIndexer(url: try garbageIndex()))
        model.filter.read = .all
        model.recompute()
        XCTAssertEqual(model.displayed.count, 2, "precondition: both files are listed")

        model.fullTextQuery = "smith"
        model.runFullTextSearch()
        let deadline = Date().addingTimeInterval(10)
        while model.ftsPaths == nil, Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        await model.listPresented()

        guard case .unavailable = model.indexFailure else {
            return XCTFail("precondition: the status bar reports the dead index, got \(String(describing: model.indexFailure))")
        }
        XCTAssertEqual(model.indexFailure?.message, "Search index unavailable")
        XCTAssertEqual(model.ftsPaths, [], "the failed index query returned an empty result")
        XCTAssertTrue(model.displayed.isEmpty, "the list empties")

        XCTAssertEqual(model.emptyListState, .ocrSearchUnavailable)

        model.removeFilter(.text)
        await model.listPresented()
        XCTAssertEqual(model.displayed.count, 2)
        XCTAssertNil(model.emptyListState, "browsing still works while the index is unavailable")
    }

    func testUnavailableOCRSearchOverlayRenders() throws {
        let overlay = OCRSearchUnavailableView(rescan: {}).environment(\.colorScheme, .light)
            .background(.white)
        let data = try XCTUnwrap(RenderProbe.pngData(from: overlay, size: CGSize(width: 500, height: 240)))
        writeRenderArtifact(data, named: "ocr-search-unavailable.png")
        let image = try XCTUnwrap(RenderProbe.cgImage(fromPNG: data))
        assertRendersNonBlank(image, "OCR search unavailable overlay")
    }
}
