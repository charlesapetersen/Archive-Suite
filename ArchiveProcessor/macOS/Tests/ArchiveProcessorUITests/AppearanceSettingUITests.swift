import XCTest

/// W48.appearance-processor — the Appearance setting (System, Light, Dark) picked from Settings changes every open
/// window at once, a sheet included, and comes back after a relaunch. XCUITest cannot read an `NSAppearance`, so
/// the check is the pixels: the mean luminance of each window's screenshot, dark under 0.5 and light over it. Each
/// shot is also written for a reader (`[shot]` lines, collected by `vm-gui-runner.sh`). Scratch IN/OUT only.
@MainActor
final class AppearanceSettingUITests: XCTestCase {
    private var app: XCUIApplication!
    private var scratchRoot: URL!
    private var shotDirectory: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-processor-appearance-\(UUID().uuidString)", isDirectory: true)
        shotDirectory = scratchRoot.appendingPathComponent("shots", isDirectory: true)
        for sub in ["IN", "OUT", "shots"] {
            try FileManager.default.createDirectory(at: scratchRoot.appendingPathComponent(sub, isDirectory: true),
                                                    withIntermediateDirectories: true)
        }
        app = .archiveProcessorUITestApp()
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
    }

    func testPickingLightAndDarkChangesOpenWindowsLiveAndSurvivesARelaunch() throws {
        // First launch clears any stored choice (scratch defaults), so this is System, the guest's appearance.
        launch(keepAppearance: false)
        let main = mainWindow()
        let sheet = try showHistorySheet(in: main)
        let systemIsDark = luminance(of: main, "system-main") < 0.5

        // Each pick is made in Settings with the History sheet open; Settings is then closed so the main window
        // and the sheet are measured without it overlapping them.
        for (title, dark) in [("Dark", true), ("Light", false), ("Dark", true)] {
            let settings = try showSettings()
            pick(title)
            let slug = title.lowercased()
            expect(luminance(of: settings, "\(slug)-settings"), dark: dark, "the Settings window")
            closeSettings(settings)
            expect(luminance(of: main, "\(slug)-main"), dark: dark, "the main window")
            expect(luminance(of: sheet, "\(slug)-sheet"), dark: dark, "the open History sheet")
        }
        app.terminate()

        // The stored Dark is back before the first window.
        launch(keepAppearance: true)
        let relaunched = mainWindow()
        expect(luminance(of: relaunched, "relaunch-dark-main"), dark: true, "the main window after a relaunch")
        let settings = try showSettings()
        XCTAssertEqual(appearancePicker().value as? String, "Dark", "the picker should show the stored choice")
        pick("System")
        closeSettings(settings)
        XCTAssertEqual(luminance(of: relaunched, "system-again-main") < 0.5, systemIsDark,
                       "System should follow the guest again")
    }

    func testTheUITestArgumentStillWinsOverTheStoredChoice() throws {
        // The stored value says Light (argument domain); the layout guard's argument says Dark and must win.
        launch(keepAppearance: false, extra: LayoutGuard.lightSettingArguments + LayoutGuard.darkModeArguments)
        XCTAssertLessThan(luminance(of: mainWindow(), "argument-wins-main"), 0.5,
                          "-ArchiveUITestAppearance dark should override the stored Light")
    }

    // MARK: - Helpers

    private func launch(keepAppearance: Bool, extra: [String] = []) {
        app.launchArguments = UITestLaunch.arguments([
            "-APUITestMode",
            "-APUITestInputDirectory", scratchRoot.appendingPathComponent("IN").path,
            "-APUITestOutputDirectory", scratchRoot.appendingPathComponent("OUT").path,
        ] + (keepAppearance ? ["-APUITestKeepAppearance"] : []) + extra)
        app.launchEnvironment["ARCHIVEPROC_HEADLESS"] = "1"
        app.launch()
        app.activate()
    }

    private func mainWindow() -> XCUIElement {
        // The mode picker is in every mode, so the query still finds this window after Tools replaces the drop zone.
        let main = app.windows.containing(.any, identifier: "ap.mode.picker").firstMatch
        if !main.waitForExistence(timeout: 10) {
            print("PROCESSOR_UI_NO_WINDOW")   // the gate's VM/keychain-launch marker (see ProcessorUITests)
            XCTFail("the Process Files window should appear within 10 seconds")
        }
        LayoutGuard.waitUntilSettled(main)
        return main
    }

    private func showHistorySheet(in main: XCUIElement) throws -> XCUIElement {
        let tools = [main.radioButtons["Tools"], main.buttons["Tools"]].first { $0.exists }
        try XCTUnwrap(tools, "the main window must offer the Tools mode").click()
        let history = main.buttons["View History…"]
        XCTAssertTrue(history.waitForExistence(timeout: 5), "Tools must offer View History…")
        history.click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "the History sheet should open")
        return sheet
    }

    private func showSettings() throws -> XCUIElement {
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.containing(.any, identifier: "ap.settings.guidedKeySetup").firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "Settings should open")
        XCTAssertTrue(appearancePicker().waitForExistence(timeout: 5), "Settings should offer the Appearance picker")
        LayoutGuard.waitUntilSettled(settings)
        return settings
    }

    /// Settings is still the key window after a pick (the menu was its own), so ⌘W closes it, not the main window.
    private func closeSettings(_ settings: XCUIElement) {
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(settings.waitForNonExistence(timeout: 5), "Settings should close")
        Thread.sleep(forTimeInterval: 0.5)
    }

    private func appearancePicker() -> XCUIElement {
        app.descendants(matching: .any)["ap.settings.appearance"].firstMatch
    }

    private func expect(_ value: Double, dark: Bool, _ what: String) {
        if dark { XCTAssertLessThan(value, 0.5, "\(what) should be dark") }
        else { XCTAssertGreaterThan(value, 0.5, "\(what) should be light") }
    }

    private func pick(_ title: String) {
        appearancePicker().click()
        let item = app.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 3), "the Appearance picker should offer \(title)")
        item.click()
        Thread.sleep(forTimeInterval: 1)   // let every window redraw before the next shot
    }

    /// The mean Rec. 709 luminance (0 black – 1 white) of the element's screenshot, written to the shots folder.
    private func luminance(of element: XCUIElement, _ name: String) -> Double {
        let shot = element.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "appearance-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = shotDirectory.appendingPathComponent("uitest-appearance-\(name).png")
        if (try? shot.pngRepresentation.write(to: url, options: .atomic)) != nil {
            print("[shot] appearance-\(name): wrote \(url.path)")
        }
        guard let cg = shot.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            XCTFail("no image for \(name)"); return .nan
        }
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { XCTFail("could not read the pixels of \(name)"); return .nan }
        var sum = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            sum += 0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])
        }
        let mean = sum / Double(side * side) / 255
        print("[appearance] \(name): luminance \(String(format: "%.3f", mean))")
        return mean
    }
}
