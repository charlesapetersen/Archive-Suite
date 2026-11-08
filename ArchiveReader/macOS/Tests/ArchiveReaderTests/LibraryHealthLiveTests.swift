import XCTest
import Combine
import SwiftUI
import ArchiveCore
@testable import ArchiveReader

@MainActor
final class LibraryHealthLiveTests: XCTestCase {
    /// Hold extraction on either side of a real SQLite batch commit. No PDFs or archive folders are
    /// opened: the injected extractor returns unreadable results for synthetic paths in scratch.
    func testOpenHealthViewUpdatesBeforeIndexingFinishesAndFlushesTheTail() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryHealthLive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: scratch) }
        let defaults = fixtureDefaults()
        let gate = HealthExtractionGate()
        defer { gate.releaseAll() }
        let indexer = ContentIndexer(url: scratch.appendingPathComponent("content.sqlite3"),
                                     extractPDFForTesting: { url in
            gate.wait(for: Int(url.deletingPathExtension().lastPathComponent)!)
            return nil
        })
        addTeardownBlock {
            gate.releaseAll()
            await indexer.closeForTesting()
        }
        let model = NavigationModel(defaults: defaults, indexer: indexer, thumbnailer: nil)
        let files = (0..<502).map { n in
            ArchiveFile(url: scratch.appendingPathComponent("\(n).pdf"), name: "\(n).pdf", fileType: "PDF",
                        tags: DocumentTags.parse(raw: ["Unread"], labelNumber: nil), contentModified: nil)
        }
        // Mount once, as the popover does. Never replace rootView when the model changes.
        let host = NSHostingView(rootView: DataQualityView(model: model,
                                                          showNeedsAttention: {}, showAmbiguousDates: {}))
        let size = CGSize(width: 330, height: 270)
        let empty = try render(host, size: size, name: "health-empty.png")
        model.library.replaceFilesForTesting(files)
        await waitFor("discovery to start indexing") { model.indexingProgress != nil }
        let discovered = try render(host, size: size, name: "health-discovered.png")
        XCTAssertNotEqual(discovered, empty, "the already-open health view must follow library discovery")
        XCTAssertEqual(model.dataQuality.total, 502)
        XCTAssertEqual(model.needsAttentionCount, 0)

        let batch = expectation(description: "health receives the first committed batch while extraction is held")
        var sawBatch = false
        let subscription = model.$needsAttentionCount.sink { count in
            if count == 500, !sawBatch {
                sawBatch = true
                batch.fulfill()
            }
        }
        gate.releaseFirstBatch()
        await fulfillment(of: [batch], timeout: 10)
        withExtendedLifetime(subscription) {}
        XCTAssertNotNil(model.indexingProgress, "the last two extractions are still blocked")
        XCTAssertEqual(indexer.completedPassesForTesting, 0, "a final-only refresh cannot satisfy this test")
        XCTAssertEqual(model.formatStatuses.count, 500)
        let during = try render(host, size: size, name: "health-indexing.png")
        XCTAssertNotEqual(during, discovered, "committed health results must redraw the open popover")

        gate.releaseAll()
        await waitFor("the final partial batch to reach health") {
            // The initial library subscription can coalesce a second, unchanged snapshot behind
            // the active pass. Wait for idle rather than requiring exactly one completed pass.
            indexer.completedPassesForTesting >= 1 && model.indexingProgress == nil
                && model.needsAttentionCount == 502
        }
        XCTAssertNil(indexer.failure)
        XCTAssertNil(model.indexingProgress)
        XCTAssertEqual(model.formatStatuses.count, 502)
        let finished = try render(host, size: size, name: "health-finished.png")
        XCTAssertNotEqual(finished, during)

        // Index rows survive a scope clear, but must no longer count as the current library's health.
        model.library.replaceFilesForTesting([])
        await waitFor("health to clear with the library") {
            model.needsAttentionCount == 0 && model.formatStatuses.isEmpty
        }
        XCTAssertEqual(model.dataQuality.total, 0)
        await indexer.closeForTesting()
    }

    private func waitFor(_ description: String, until ready: () -> Bool) async {
        let deadline = Date().addingTimeInterval(10)
        while !ready(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(ready(), description)
    }

    private func render(_ host: NSView, size: CGSize, name: String) throws -> Data {
        let png = try XCTUnwrap(RenderProbe.pngData(fromAppKitView: host, size: size))
        let cg = try XCTUnwrap(RenderProbe.cgImage(fromPNG: png))
        assertRendersNonBlank(cg, "Library health")
        writeRenderArtifact(png, named: name)
        return png
    }
}

/// Synchronous extraction runs on worker threads; only those workers wait, never the main actor.
private final class HealthExtractionGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var firstBatchReleased = false
    private var allReleased = false

    func wait(for n: Int) {
        condition.lock()
        defer { condition.unlock() }
        while !allReleased && !(firstBatchReleased && n < 500) { condition.wait() }
    }

    func releaseFirstBatch() {
        condition.lock()
        firstBatchReleased = true
        condition.broadcast()
        condition.unlock()
    }

    func releaseAll() {
        condition.lock()
        allReleased = true
        condition.broadcast()
        condition.unlock()
    }
}
