import XCTest
import AppKit

/// W48.appearance-reader — Options ▸ Appearance (System, Light, Dark), in the VM. Written from the item's promise
/// (ledger row R-48): a choice changes every open window at once, a sheet that is open during the switch included;
/// it is restored on the next launch before the first window; System puts the app back on the guest's appearance; and
/// the UI-test argument `-ArchiveUITestAppearance` still wins over the stored choice.
///
/// A window's appearance is read off its pixels (its mean luminance), because the accessibility tree does not carry
/// it. These tests launch without the light/dark argument so the stored setting decides; each fixture launch starts
/// from System (`ReaderUITestDefaults`), and the relaunches pass `-ARUITestKeepAppearance` to keep it.
/// Read-only on the fixture: the one sheet used (Save Search) is cancelled. Screenshots: `[shot] appearance-*`.
/// The Notes twin is `ArchiveNotesUITests/AppearanceSettingUITests`.
final class AppearanceSettingUITests: FixtureUITestCase {

    /// Under this a window reads as dark, over `lightFloor` as light. Measured in the VM: see the `[w48]` lines.
    private static let darkCeiling = 0.35
    private static let lightFloor = 0.6

    private var mainWindow: XCUIElement { app.windows["Archive Reader"] }

    /// A test that stops partway (`continueAfterFailure` is off) may leave a choice stored; one more fixture launch,
    /// without `-ARUITestKeepAppearance`, clears it, so a later suite that launches without `-ARUITestRootPath`
    /// (`ArchiveReaderUITests`) never inherits it.
    override func tearDown() async throws {
        app?.terminate()
        app = .archiveUITestApp()
        app.launchArguments += ["-ARUITestRootPath", Self.fixturePath]
        app.launch()
        _ = mainWindow.waitForExistence(timeout: 15)
        try await super.tearDown()
    }

    func testPickingLightAndDarkChangesEveryWindowAtOnceWithASheetOpen() throws {
        let sheet = openSaveSearchSheet()

        let settings = openSettings()
        // Measured with the sheet and Settings already open: a window's screenshot includes whatever is drawn over
        // it, so a baseline taken before Settings opened is not comparable with the later ones.
        let system = luminance(mainWindow, "system-main")
        for choice in ["Dark", "Light", "Dark"] {
            pick(choice, in: settings)
            let dark = choice == "Dark"
            for (name, element) in [("main", mainWindow), ("sheet", sheet), ("settings", settings)] {
                _ = pollUntil(timeout: 5) { self.reads(dark: dark, self.luminance(element)) }
                let measured = luminance(element, "\(choice.lowercased())-\(name)")
                XCTAssertTrue(reads(dark: dark, measured), "\(name) should turn \(choice) at once, measured \(measured)")
            }
        }

        pick("System", in: settings)
        _ = pollUntil(timeout: 5) { abs(self.luminance(self.mainWindow) - system) < 0.1 }
        let again = luminance(mainWindow, "system-again-main")
        XCTAssertLessThan(abs(again - system), 0.1,
                          "System should put the window back on the guest's appearance (\(system)), measured \(again)")

        settings.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(settings.waitForNonExistence(timeout: 5), "Settings should close")
        let cancel = sheet.buttons["Cancel"]
        if cancel.exists { cancel.click() } else { app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: []) }
        XCTAssertTrue(app.textFields["ar.saveSearch.name"].waitForNonExistence(timeout: 5),
                      "the sheet should close unsaved")
    }

    /// The document viewer is mostly page image, which stays as scanned whatever the appearance, so it is held to a
    /// change rather than to the thresholds; its shots show whether the PDF pane's background (`PDFPaneView`,
    /// `windowBackgroundColor`, set once) followed the switch.
    func testAnOpenDocumentViewerFollowsALiveSwitch() throws {
        clickRow(0)
        toolbarButton("ar.toolbar.preview").click()
        let open = app.buttons["ar.preview.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5), "the preview sheet should open")
        open.click()
        let opened = app.windows.matching(NSPredicate(format: "title != %@", "Archive Reader")).firstMatch
        XCTAssertTrue(opened.waitForExistence(timeout: 10), "Open in Viewer should bring up the document window")
        let viewer = app.windows[opened.title]
        LayoutGuard.waitUntilSettled(viewer)

        let settings = openSettings()
        var measured: [String: Double] = [:]
        for choice in ["Dark", "Light"] {
            pick(choice, in: settings)
            let dark = choice == "Dark"
            _ = pollUntil(timeout: 5) { self.reads(dark: dark, self.luminance(self.mainWindow)) }
            LayoutGuard.waitUntilSettled(viewer)
            measured[choice] = luminance(viewer, "\(choice.lowercased())-viewer")
        }
        let light = measured["Light"] ?? 0, dark = measured["Dark"] ?? 1
        XCTAssertGreaterThan(light - dark, 0.1, "the viewer should change with the setting: Light \(light), Dark \(dark)")

        pick("System", in: settings)
        settings.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(settings.waitForNonExistence(timeout: 5), "Settings should close")
        viewer.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(viewer.waitForNonExistence(timeout: 5), "the viewer should close")
    }

    func testTheChoiceIsRestoredAtLaunchAndTheUITestArgumentStillWins() throws {
        let settings = openSettings()
        pick("Dark", in: settings)
        XCTAssertTrue(pollUntil(timeout: 5) { self.reads(dark: true, self.luminance(self.mainWindow)) })
        settings.typeKey("w", modifierFlags: .command)

        relaunch(extra: [])
        XCTAssertTrue(reads(dark: true, luminance(mainWindow, "relaunch-dark-main")),
                      "the stored Dark should be back before the window is drawn")
        let reopened = openSettings()
        XCTAssertEqual(appearancePicker(in: reopened).value as? String, "Dark", "Settings should show the stored choice")
        reopened.typeKey("w", modifierFlags: .command)

        relaunch(extra: ["-ArchiveUITestAppearance", "light"])
        XCTAssertTrue(reads(dark: false, luminance(mainWindow, "argument-light-over-stored-dark-main")),
                      "the UI-test argument should win over the stored Dark")

        // Leave the stored value at System for whatever runs next (the next fixture launch clears it anyway).
        relaunch(extra: [])
        let last = openSettings()
        pick("System", in: last)
        last.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(last.waitForNonExistence(timeout: 5), "Settings should close")
    }

    // MARK: - Helpers

    private func openSaveSearchSheet() -> XCUIElement {
        let menuBar = app.menuBars.element(boundBy: 0)
        menuBar.menuBarItems["File"].click()
        let item = app.menuItems["Save Current Search…"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "File should offer Save Current Search…")
        item.click()
        XCTAssertTrue(app.textFields["ar.saveSearch.name"].waitForExistence(timeout: 5), "the Save Search sheet should open")
        let sheet = mainWindow.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "the main window should carry the sheet")
        return sheet
    }

    private func openSettings() -> XCUIElement {
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.containing(.any, identifier: "ar.settings.appearance").firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "Settings should open")
        LayoutGuard.waitUntilSettled(settings)
        return settings
    }

    private func appearancePicker(in settings: XCUIElement) -> XCUIElement {
        settings.descendants(matching: .any)["ar.settings.appearance"].firstMatch
    }

    private func pick(_ choice: String, in settings: XCUIElement) {
        let picker = appearancePicker(in: settings)
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Settings should offer the Appearance picker")
        picker.click()
        let item = app.menuItems[choice]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the Appearance picker should offer \(choice)")
        item.click()
        XCTAssertTrue(pollUntil(timeout: 5) { picker.value as? String == choice }, "the picker should show \(choice)")
    }

    private func relaunch(extra: [String]) {
        app.terminate()
        app = .archiveUITestApp()
        app.launchArguments += ["-ARUITestRootPath", Self.fixturePath]
        if Self.fixturePath == Self.canonicalFixturePath {
            app.launchArguments += ["-ARUITestContentIndexPath", Self.canonicalFixturePath + "/content-index-v2.sqlite3"]
        }
        app.launchArguments += ["-ARUITestKeepAppearance", "YES"] + extra
        app.launch()
        app.activate()
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 15), "the window should come back after relaunch")
        XCTAssertTrue(table.waitForExistence(timeout: 10), "the table should come back after relaunch")
        waitForRows(minimum: 1, timeout: 15)
        LayoutGuard.waitUntilSettled(mainWindow)
    }

    private func pollUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    private func reads(dark: Bool, _ value: Double) -> Bool {
        dark ? value < Self.darkCeiling : value > Self.lightFloor
    }

    /// The element's mean luminance, 0 (black) to 1 (white), from its screenshot; with `shot`, the image is also
    /// written where the VM runner collects it and the value printed.
    @discardableResult
    private func luminance(_ element: XCUIElement, _ shot: String? = nil) -> Double {
        let image = element.screenshot()
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let cg = image.image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var sum = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            sum += 0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])
        }
        let value = sum / Double(side * side) / 255
        if let shot {
            _ = captureScreenshot("appearance-\(shot)")
            print("[w48] \(shot): luminance \(String(format: "%.3f", value))")
        }
        return value
    }
}
