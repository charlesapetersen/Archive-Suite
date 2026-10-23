import XCTest

/// W40.i-sim-ui: the iPhone companion's own controls, pressed by touch, against the real Mac in a headless
/// simulator. Run only by `scripts/e2e-ios-ui.sh`, which owns everything outside the simulator: the Mac session
/// (stopped and restarted on request), a port with nothing listening and a server that answers /ping with 404
/// (the connect diagnostics), the camera feed, and the evidence. The two sides talk through files in a host
/// directory: the test writes `req-<n>-<verb>` and waits for the script's `ack-<n>-<verb>`.
///
/// The methods run in name order and share one app install: each step starts from the state the last one left.
/// The one seam is the camera (the simulator has none): with `ARCHIVECAP_UITEST_FEED` set, each shutter, Box or
/// Folder press takes the next JPEG of the feed directory (`Debug/E2EHarness.swift`). Everything else is the real
/// app: its buttons, sheets, dialogs, queue, retry loop, heartbeat and the LAN transport.
final class CaptureFlowUITests: XCTestCase {
    private static var env: [String: String] { ProcessInfo.processInfo.environment }
    private static var ctl: URL { URL(fileURLWithPath: env["E2E_CTL"] ?? "/nonexistent", isDirectory: true) }
    private static var seq = 0

    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(Self.env["E2E_CTL"] == nil, "run by scripts/e2e-ios-ui.sh only")
        app.launchEnvironment["ARCHIVECAP_UITEST_FEED"] = Self.env["E2E_FEED"] ?? ""
    }

    // MARK: - The steps

    /// C-32, C-33: manual entry, each connect diagnostic, then a good pairing.
    func test1_connectDiagnostics() throws {
        app.launch()
        XCTAssertTrue(app.staticTexts["Connect to your Mac"].waitForExistence(timeout: 20), "not on the pairing screen")
        app.buttons["Enter manually"].tap()
        let host = app.textFields["Host (e.g. 192.168.1.5)"], port = app.textFields["Port"], token = app.textFields["Token"]
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        replace(host, with: "127.0.0.1")
        replace(token, with: "WRONGTOKENWRONGTOKENWRONGTOKEN22")

        replace(port, with: "0")
        // Recorded, not asserted: with the Port field's number pad up, can the operator reach Connect?
        shot("c32-port-numpad-up")
        try ctl("mark numpad-up connect-hittable=\(app.buttons["Connect"].isHittable) keyboard=\(app.keyboards.count)")
        connectTap()
        expectText("Port must be a number between 1 and 65535.", timeout: 5)
        shot("c32-port-rejected")

        let dead = try XCTUnwrap(Self.env["E2E_DEAD_PORT"])
        replace(port, with: dead)
        connectTap()
        expectText("Can't reach the Mac at 127.0.0.1:\(dead)", timeout: 15)
        shot("c33-unreachable")

        let refuse = try XCTUnwrap(Self.env["E2E_REFUSE_PORT"])
        replace(port, with: refuse)
        connectTap()
        expectText("Reached the network but nothing is listening at 127.0.0.1:\(refuse)", timeout: 15)
        shot("c33-refused")

        replace(port, with: try XCTUnwrap(Self.env["E2E_PORT"]))
        connectTap()
        expectText("Pairing code rejected", timeout: 15)
        shot("c33-unauthorized")

        replace(token, with: try XCTUnwrap(Self.env["E2E_TOKEN"]))
        connectTap()                                   // no shot until the token field is gone
        expectText("Connected · Mac", timeout: 15)
        shot("c32-connected")
    }

    /// C-35 to C-38: Box, Folder, two pages, End segment, and the tag sheet's Apply with Q2 and 1962.
    func test2_markersPagesAndTags() throws {
        app.launch()
        expectText("Connected · Mac", timeout: 20)     // C-34: the saved endpoint opens straight to capture
        press("Box. Capture a box-label marker")
        press("Folder. Capture a folder-label marker")
        shutter(); shutter()
        expectThumbs("Document page, sent to Mac", count: 2, timeout: 30)
        shot("c36-c37-two-pages-sent")
        app.buttons["End segment"].tap()
        XCTAssertTrue(app.staticTexts["Tag this document"].waitForExistence(timeout: 5), "no tag sheet")
        app.buttons["Q2"].tap()
        let year = app.textFields["Specific year"]
        year.tap(); year.typeText("1962")
        shot("c38-tag-sheet-q2-1962")
        app.buttons["Apply & continue"].tap()
        XCTAssertTrue(app.staticTexts["Tag this document"].waitForNonExistence(timeout: 5), "sheet did not close")
        expectThumbs("Document page", count: 0, timeout: 30)
        shot("c37-segment-ended")
        try ctl("segment-tagged")                     // the script finalizes this document on the Mac and reads its tags
    }

    /// C-39, C-42: Retry and auto-retry with the Mac stopped and restarted; the Mac logs the heartbeat's count.
    func test3_retryAndAutoRetry() throws {
        app.launch()
        expectText("Connected · Mac", timeout: 20)
        try ctl("mac-stop")
        shutter()
        expectThumbs("Document page, upload failed, will retry", count: 1, timeout: 45)
        XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 5), "no Retry button for a failed page")
        shot("c39-failed-retry-shown")
        app.buttons["Retry"].tap()                     // Mac still down: fails again, nothing lost
        expectThumbs("Document page, upload failed, will retry", count: 1, timeout: 45)
        try ctl("mac-start")
        app.buttons["Retry"].tap()
        expectThumbs("Document page, sent to Mac", count: 1, timeout: 20)
        shot("c39-retry-sent")
        try ctl("mark retry-sent")

        // Auto-retry: two pages fail, the Mac comes back, nothing is tapped.
        try ctl("mac-stop")
        shutter(); shutter()
        expectThumbs("Document page, upload failed, will retry", count: 2, timeout: 45)
        shot("c39-two-failed")
        try ctl("mac-start")
        expectThumbs("Document page, sent to Mac", count: 3, timeout: 40)
        XCTAssertFalse(app.buttons["Retry"].exists)
        shot("c39-auto-retry-sent")
        try ctl("mark auto-retry-sent")
        endSegmentSkip()
    }

    /// S-023: the app in the background while three unsent pages wait and the Mac comes back.
    func test4_backgroundDuringUpload() throws {
        app.launch()
        expectText("Connected · Mac", timeout: 20)
        try ctl("mac-stop")
        shutter(); shutter(); shutter()
        expectThumbs("Document page, upload failed, will retry", count: 3, timeout: 45)
        endSegmentSkip(expectEmpty: false)
        shot("s023-three-unsent")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackgroundSuspended, timeout: 20)
                      || app.state == .runningBackground, "app did not go to the background")
        try ctl("mark backgrounded")
        try ctl("mac-start")
        Thread.sleep(forTimeInterval: 40)              // five retry periods with the app away
        try ctl("mark before-foreground")              // the script counts what the Mac received by now
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), "app did not come back to the foreground")
        expectText("Connected · Mac", timeout: 20)     // the screen is back, so an empty strip means drained
        expectThumbs("Document page", count: 0, timeout: 40)
        shot("s023-drained-after-foreground")
        try ctl("mark drained")
    }

    /// C-40, C-41: unsent pages survive the app being terminated; after relaunch they upload.
    func test5_terminateAndRelaunch() throws {
        app.launch()
        expectText("Connected · Mac", timeout: 20)
        try ctl("mac-stop")
        shutter(); shutter()
        expectThumbs("Document page, upload failed, will retry", count: 2, timeout: 45)
        endSegmentSkip(expectEmpty: false)
        shot("c41-two-unsent-before-kill")
        app.terminate()
        try ctl("mark terminated")
        app.launch()
        expectText("Connected · Mac", timeout: 20)
        XCTAssertEqual(thumbs("Document page").count, 2, "the unsent pages did not survive the relaunch")
        shot("c41-relaunched-two-kept")
        try ctl("mac-start")
        expectThumbs("Document page", count: 0, timeout: 40)
        shot("c40-drained-after-relaunch")
        try ctl("mark relaunch-drained")
    }

    /// The Clear and delete dialogs on an unsent page, then Re-pair and a page that uploads after reconnecting.
    func test6_dialogsAndRepair() throws {
        app.launch()
        expectText("Connected · Mac", timeout: 20)
        try ctl("mac-stop")
        shutter()
        expectThumbs("Document page, upload failed, will retry", count: 1, timeout: 45)
        app.buttons["Clear"].tap()
        expectText("1 photo(s) have NOT been uploaded to the Mac and will be permanently lost.", timeout: 5)
        shot("clear-dialog-unsent")
        // iOS 26+ draws a confirmation dialog as a popover with no Cancel button: a tap outside it cancels.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        XCTAssertTrue(app.buttons["Clear (1)"].waitForNonExistence(timeout: 5), "the Clear dialog did not close")
        XCTAssertEqual(thumbs("Document page").count, 1, "Cancel cleared the page")

        let page = thumbs("Document page").firstMatch
        page.tap(); page.tap()                         // select, then arm
        XCTAssertTrue(thumbs("tap again to delete").firstMatch.waitForExistence(timeout: 5), "thumbnail not armed")
        shot("delete-armed")
        thumbs("tap again to delete").firstMatch.tap()
        expectText("Delete a photo the Mac doesn't have?", timeout: 5)
        shot("delete-dialog-unsent")
        app.buttons["Delete permanently"].tap()
        expectThumbs("Document page", count: 0, timeout: 10)

        shutter()                                      // one unsent page carried across the Re-pair
        expectThumbs("Document page, upload failed, will retry", count: 1, timeout: 45)
        app.buttons["Re-pair with a Mac"].tap()
        expectText("Re-pair with a Mac?", timeout: 5)
        shot("c34-repair-dialog")
        app.buttons["Re-pair"].firstMatch.tap()          // the dialog's; the screen's button reads "Re-pair with a Mac"
        XCTAssertTrue(app.staticTexts["Connect to your Mac"].waitForExistence(timeout: 10), "Re-pair did not reach the pairing screen")
        shot("c34-repair-pairing-screen")
        try ctl("mac-start")
        app.buttons["Enter manually"].tap()
        replace(app.textFields["Host (e.g. 192.168.1.5)"], with: "127.0.0.1")
        replace(app.textFields["Port"], with: try XCTUnwrap(Self.env["E2E_PORT"]))
        replace(app.textFields["Token"], with: try XCTUnwrap(Self.env["E2E_TOKEN"]))
        connectTap()
        expectText("Connected · Mac", timeout: 15)
        expectThumbs("Document page, sent to Mac", count: 1, timeout: 30)
        shot("c34-reconnected-page-sent")
        endSegmentSkip()
        try ctl("mark done")
    }

    // MARK: - Helpers

    private func thumbs(_ labelPrefix: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@ OR label CONTAINS %@",
                                                             labelPrefix, ", " + labelPrefix))
    }

    private func expectThumbs(_ labelPrefix: String, count: Int, timeout: TimeInterval,
                              file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while thumbs(labelPrefix).count != count, Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        let got = thumbs(labelPrefix).count
        if got != count { shot("fail-\(Self.seq)") }
        XCTAssertEqual(got, count, "thumbnails labelled \"\(labelPrefix)…\"", file: file, line: line)
    }

    private func expectText(_ prefix: String, timeout: TimeInterval, file: StaticString = #filePath, line: UInt = #line) {
        let el = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        if !el.waitForExistence(timeout: timeout) { shot("fail-text-\(Self.seq)") }
        XCTAssertTrue(el.exists, "no text \"\(prefix)…\"", file: file, line: line)
    }

    private func replace(_ field: XCUIElement, with text: String) {
        field.tap()
        let old = (field.value as? String) ?? ""
        let placeholder = field.placeholderValue ?? ""
        if !old.isEmpty && old != placeholder {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        }
        field.typeText(text)
    }

    /// The port field's number pad has no return key, so the keyboard goes away through the Token field's return key
    /// first. On the iPhone 18 Pro simulator Connect stays visible and hittable above the pad (test1 records it); a
    /// smaller screen is not checked.
    private func connectTap() {
        let token = app.textFields["Token"]
        token.tap(); token.typeText("\n")
        app.buttons["Connect"].tap()
    }

    /// How many feed images the app has taken (`.used`): a marker leaves the strip once sent, so the feed is the one
    /// sign every press took a photo.
    private var fedCount: Int {
        let feed = Self.env["E2E_FEED"] ?? "/nonexistent"
        return ((try? FileManager.default.contentsOfDirectory(atPath: feed)) ?? []).filter { $0.hasSuffix(".used") }.count
    }

    /// Press a capture button and wait until it took one feed image.
    private func press(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let before = fedCount
        app.buttons[label].tap()
        let deadline = Date().addingTimeInterval(10)
        while fedCount == before, Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertGreaterThan(fedCount, before, "\(label): no photo taken", file: file, line: line)
    }

    private func shutter() { press("Shutter. Capture a document page") }

    private func endSegmentSkip(expectEmpty: Bool = true) {
        app.buttons["End segment"].tap()
        XCTAssertTrue(app.staticTexts["Tag this document"].waitForExistence(timeout: 5), "no tag sheet")
        app.buttons["Skip (tag on Mac)"].tap()
        XCTAssertTrue(app.staticTexts["Tag this document"].waitForNonExistence(timeout: 5), "sheet did not close")
        if expectEmpty { expectThumbs("Document page", count: 0, timeout: 30) }
    }

    /// A screenshot, attached to the result and also written to `<ctl>/shots/<name>.png` for the evidence.
    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        let dir = Self.ctl.appendingPathComponent("shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? s.pngRepresentation.write(to: dir.appendingPathComponent("\(name).png"))
    }

    /// Ask the script for something and wait for its answer (`mac-stop`, `mac-start`, `segment-tagged`, `mark <label>`).
    private func ctl(_ verb: String, timeout: TimeInterval = 240) throws {
        Self.seq += 1
        let name = "\(String(format: "%03d", Self.seq))-\(verb.replacingOccurrences(of: " ", with: "_"))"
        try Data().write(to: Self.ctl.appendingPathComponent("req-\(name)"))
        let ack = Self.ctl.appendingPathComponent("ack-\(name)")
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: ack.path) {
            if Date() > deadline { XCTFail("no answer from the script to \(verb)"); return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        let answer = (try? String(contentsOf: ack, encoding: .utf8)) ?? ""
        XCTAssertFalse(answer.hasPrefix("FAIL"), "script: \(answer)")
    }
}
