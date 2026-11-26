import XCTest

/// The Settings window's five tabs (W49.proc-settings-redesign-core) for the UI suite: the window is found by any tab's
/// identifier, and a tab is shown by its toolbar button.
extension XCUIApplication {
    /// The design's tabs, in the toolbar's order.
    static let settingsPanels = ["Processing", "Output", "Capture", "Accounts", "Advanced"]

    /// The Settings window, whichever tab it shows.
    var settingsWindow: XCUIElement {
        windows.containing(NSPredicate(format: "identifier BEGINSWITH %@", "ap.settings.panel.")).firstMatch
    }

    /// Brings up Settings (⌘,) and returns its window.
    @discardableResult
    func showSettingsWindow(timeout: TimeInterval = 10) -> XCUIElement {
        activate()
        typeKey(",", modifierFlags: .command)
        let window = settingsWindow
        _ = window.waitForExistence(timeout: timeout)
        return window
    }

    /// The toolbar button of the Settings tab titled `title`.
    func settingsPanelButton(_ title: String) -> XCUIElement {
        settingsWindow.toolbars.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR title == %@", title, title)).firstMatch
    }

    /// Shows the Settings tab titled `title` by its toolbar button; false when there is no such button.
    @discardableResult
    func showSettingsPanel(_ title: String) -> Bool {
        let window = settingsWindow
        guard window.waitForExistence(timeout: 5) else { return false }
        let button = settingsPanelButton(title)
        guard button.waitForExistence(timeout: 5) else { return false }
        button.click()
        let id = "ap.settings.panel." + Self.settingsPanelID(title)
        return window.descendants(matching: .any)[id].firstMatch.waitForExistence(timeout: 5)
    }

    /// A tab's identifier suffix (`SettingsTab.rawValue`).
    static func settingsPanelID(_ title: String) -> String { title.lowercased() }

    /// Chooses `title` in the Processing tab's Reader menu (the tab must be showing).
    func chooseReader(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let picker = settingsWindow.descendants(matching: .any)["ap.settings.readerPicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "the Reader menu", file: file, line: line)
        picker.click()
        let item = menuItems[title].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the Reader menu offers \(title)", file: file, line: line)
        item.click()
    }
}
