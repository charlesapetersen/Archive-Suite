import XCTest

/// W40.fix-reader-viewer-switch — 200 file switches with five files open in the document window, where real
/// PDFViews draw, read by the DEBUG `ViewerSwitchProbe` (main-busy per switch, footprint every 20).
///
/// Run on the real-corpus sample, which is what makes the figures mean anything (synthetic fixture pages
/// are tiny): `READER_JOURNEY=rehearsal ONLY_TESTING=ArchiveReaderUITests/ViewerSwitchUITests
/// ops/gui/vm-gui-runner.sh reader xcuitest`. Read only: nothing is tagged or written.
///
/// Two runs in one test: as shipped, and with `-ARViewerNoPrefetch YES` (nothing opened or drawn ahead,
/// the viewer before this item), so the probe's noise (the test's own accessibility queries) is in both.
/// A third run shows the thumbnail sidebar (W40.reader-page-views), which must keep inside the same budget.
/// Evidence: `[vs]` lines in the runner's `xcuitest.log`.
final class ViewerSwitchUITests: FixtureUITestCase {
    private var baseArguments: [String]?

    /// Only on the sample root (`make-journey-fixture.sh` writes this note last): on the synthetic fixture
    /// the pages are a few hundred bytes, so the figures would say nothing, and the lane would spend 15 min.
    override func setUp() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.fixturePath + "/.w40-journey-set.txt"),
                          "measures real scans: run with READER_JOURNEY=rehearsal")
        try await super.setUp()
    }

    func testTwoHundredSwitchesWithFiveOpen() throws {
        continueAfterFailure = true
        let on = try run(prefetch: true)
        let off = try run(prefetch: false)
        let thumbnails = try run(prefetch: true, thumbnails: true)
        for (name, r) in [("on", on), ("off", off), ("thumbnails", thumbnails)] {
            print("[vs] \(name): \(r.raw)")
            print("[vs] \(name): footprint start \(r.footprintStart) MiB, end \(r.footprintEnd) MiB, "
                  + "growth \(r.footprintEnd - r.footprintStart) MiB over \(r.switches) switches")
        }
        // The budgets W40.reader-scale-measure set for this item.
        XCTAssertGreaterThanOrEqual(on.switches, 200)
        XCTAssertLessThanOrEqual(on.footprintEnd - on.footprintStart, 100, "a 200-switch run ends within 100 MB of its start")
        // Main-busy here is mostly this test's own accessibility snapshots (sampled: about two thirds of the
        // app's busy main thread), so it is printed, not budgeted; the 100 ms budget is asserted on the
        // unit lane (`ReaderChainAtSizeTests`, -O). What this run can see is whether the image was in hand.
        XCTAssertGreaterThanOrEqual(on.bitmapHits, on.switches * 9 / 10, "the image page was drawn ahead")
        XCTAssertGreaterThanOrEqual(thumbnails.switches, 200)
        XCTAssertLessThanOrEqual(thumbnails.footprintEnd - thumbnails.footprintStart, 100,
                                 "with the thumbnails shown, a 200-switch run still ends within 100 MB of its start")
    }

    private struct Result {
        var raw: String
        var switches: Int
        var busyMedian: Double
        var bitmapHits: Int
        var footprintStart: Int
        var footprintEnd: Int
    }

    private func run(prefetch: Bool, thumbnails: Bool = false) throws -> Result {
        app.terminate()
        let base = baseArguments ?? app.launchArguments
        baseArguments = base
        app.launchArguments = base + ["-ARSwitchProbe", "YES", "-ARViewerNoPrefetch", prefetch ? "NO" : "YES",
                                      "-ar.doc.thumbnailsVisible", thumbnails ? "YES" : "NO"]
        app.launch()
        app.activate()
        waitForRows(minimum: 5, timeout: 30)
        clickRow(0)
        for _ in 0..<4 { app.typeKey(.downArrow, modifierFlags: .shift) }
        pressKey("o", modifiers: .command)
        let probe = app.staticTexts["ar.debug.switchProbe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 15), "the document window opens with the probe")
        XCTAssertEqual(app.descendants(matching: .any)["ar.doc.thumbnails"].firstMatch.waitForExistence(timeout: 5),
                       thumbnails, "the sidebar is shown exactly in the thumbnails run")
        RunLoop.current.run(until: Date().addingTimeInterval(3))   // the first file drawn, neighbours opened

        // Forward through the five and back, until 200 switches past the opening one.
        var n = 0
        while n < 201 {
            for key in [XCUIKeyboardKey.downArrow, .upArrow] {
                for _ in 0..<4 {
                    app.typeKey(key, modifierFlags: [.command, .shift])
                    RunLoop.current.run(until: Date().addingTimeInterval(1.5))
                }
            }
            n = Int(field("n", in: text(probe)) ?? "") ?? 0
            if n == 0 { XCTFail("the probe counted nothing: \(text(probe))"); break }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let raw = text(probe)
        let footprints = (field("footprint", in: raw) ?? "").split(separator: ",").compactMap { entry -> Int? in
            entry.split(separator: ":").last.flatMap { Int($0) }
        }
        pressKey("w", modifiers: .command)
        return Result(raw: raw, switches: max(0, (Int(field("n", in: raw) ?? "") ?? 0) - 1),
                      busyMedian: Double(field("busy_p50", in: raw) ?? "") ?? .infinity,
                      bitmapHits: Int(field("bitmap_hits", in: raw) ?? "") ?? 0,
                      footprintStart: footprints.first ?? 0, footprintEnd: footprints.last ?? .max)
    }

    private func text(_ element: XCUIElement) -> String {
        let label = element.label
        return label.isEmpty ? (element.value as? String ?? "") : label
    }

    private func field(_ key: String, in summary: String) -> String? {
        summary.split(separator: " ").first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
    }
}
