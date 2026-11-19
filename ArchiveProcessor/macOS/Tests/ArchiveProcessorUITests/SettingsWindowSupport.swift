import XCTest

/// The Settings window's eight panels (W47.settings-panels) for the UI suite: the window is found by any panel's
/// identifier, and a panel is shown by its toolbar button.
extension XCUIApplication {
    /// The design's panels, in the toolbar's order.
    static let settingsPanels = ["General", "Collection", "Reading", "Documents", "Dates and names",
                                 "Pages and output", "Capture", "Accounts"]

    /// The Settings window, whichever panel it shows.
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

    /// The toolbar button of the Settings panel titled `title`.
    func settingsPanelButton(_ title: String) -> XCUIElement {
        settingsWindow.toolbars.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR title == %@", title, title)).firstMatch
    }

    /// Shows the Settings panel titled `title` by its toolbar button; false when there is no such button.
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

    /// A panel's identifier suffix (`SettingsPanel.rawValue`).
    static func settingsPanelID(_ title: String) -> String {
        ["General": "general", "Collection": "collection", "Reading": "reading", "Documents": "documents",
         "Dates and names": "datesAndNames", "Pages and output": "pagesAndOutput", "Capture": "capture",
         "Accounts": "accounts"][title] ?? title
    }
}
