import XCTest
import AppKit

/// W48.appearance-notes — Settings ▸ Appearance (System, Light, Dark), in the VM. Written from the item's promise
/// (ledger row N-52): a choice changes every open window at once, a sheet that is open during the switch included;
/// it is restored on the next launch before the first window; System puts the app back on the guest's appearance; and
/// the UI-test argument `-ArchiveUITestAppearance` still wins over the stored choice.
///
/// A window's appearance is read off its pixels (its mean luminance), because the accessibility tree does not carry
/// it. These tests launch without the light/dark argument so the stored setting decides; each fixture launch starts
/// from System (`NotesAppearanceUITestDefaults`), and the relaunches pass `-ANUITestKeepAppearance` to keep it.
/// Read-only on the store: the one sheet used (Save Search) is cancelled. Screenshots: `[shot] appearance-*`.
final class AppearanceSettingUITests: NotesFixtureUITestCase {

    /// Under this a window reads as dark, over `lightFloor` as light. Measured in the VM before being set: see the
    /// `[w48]` lines this suite prints.
    private static let darkCeiling = 0.35
    private static let lightFloor = 0.6

    func testPickingLightAndDarkChangesEveryWindowAtOnceWithASheetOpen() throws {
        try withFixture {
            XCTAssertTrue(waitForIndexReady(timeout: 30))
            let system = luminance(mainWindow, "system-main")

            let save = mainWindow.buttons["an.filter.save"]
            XCTAssertTrue(save.waitForExistence(timeout: 5), "the filter bar's Save Search button should exist")
            save.click()
            let sheet = mainWindow.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 5), "the Save Search sheet should open")

            let settings = openSettings()
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
            sheet.buttons["Cancel"].click()
            XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "the sheet should close unsaved")
        }
    }

    func testTheChoiceIsRestoredAtLaunchAndTheUITestArgumentStillWins() throws {
        try withFixture {
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
            pick("System", in: openSettings())
        }
    }

    // MARK: - Helpers

    private func openSettings() -> XCUIElement {
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.containing(.any, identifier: "an.settings.calendars").firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "Settings should open")
        return settings
    }

    private func appearancePicker(in settings: XCUIElement) -> XCUIElement {
        settings.descendants(matching: .any)["an.settings.appearance"].firstMatch
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
        app.launchArguments += ["-ANUITestStorePath", Self.fixturePath] + zoteroLaunchArguments
            + ["-an.noteWindow.kindFilter", "notes", "-an.extractWindow.kindFilter", "extracts"]
            + layoutLaunchArguments + ["-ANUITestKeepAppearance", "YES"] + extra
        app.launch()
        app.activate()
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 15), "the window should come back after relaunch")
        let extracts = app.windows["Extracts"]
        if extracts.waitForExistence(timeout: 8) {
            let close = extracts.buttons[XCUIIdentifierCloseWindow]
            if close.waitForExistence(timeout: 5), close.isHittable { close.click() }
            _ = extracts.waitForNonExistence(timeout: 8)
        }
        LayoutGuard.waitUntilSettled(mainWindow)
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
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("uitest-appearance-\(shot).png")
            try? image.pngRepresentation.write(to: url, options: .atomic)
            print("[shot] appearance-\(shot): wrote \(url.path)")
            print("[w48] \(shot): luminance \(String(format: "%.3f", value))")
        }
        return value
    }
}
