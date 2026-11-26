import XCTest
import AppKit

/// W49.notes-library-ux — which library is open, File ▸ Open Recent and Reveal Library in Finder, in the VM on the
/// scratch fixture (`AN-GUI-Fixture`). The fixture is never put on the app's own Open Recent list
/// (`RootFolderStore`), so its list is empty here; `RecentLibrariesTests.testLaunchRecordsTheLibraryItOpens`
/// checks that a library a launch opens is listed. (Checking the list after `ChooseStoreFolderUITests`' relaunch
/// made that test's relaunch come up without the harness arguments in 7 of 8 VM runs, for a reason not found, so
/// that test is left as it was.)
final class LibraryVisibilityUITests: NotesFixtureUITestCase {

    func testTheOpenLibraryIsNamedAndTheLibraryCommandsAreThere() throws {
        try withFixture {
            XCTAssertTrue(mainWindow.waitForExistence(timeout: 10))
            let library = mainWindow.descendants(matching: .any)["an.sidebar.library"].firstMatch
            XCTAssertTrue(library.waitForExistence(timeout: 10), "the sidebar should name the open library")
            XCTAssertTrue(libraryText(library).contains("AN-GUI-Fixture"), "the sidebar reads \(libraryText(library))")
            libraryShot("visible", mainWindow)

            app.activate()
            let fileMenu = app.menuBars.menuBarItems["File"]
            fileMenu.click()
            let reveal = fileMenu.menuItems["Reveal Library in Finder"]
            XCTAssertTrue(reveal.waitForExistence(timeout: 5), "File ▸ Reveal Library in Finder should exist")
            XCTAssertTrue(reveal.isEnabled, "with a library open, Reveal Library in Finder should be on")
            XCTAssertTrue(fileMenu.menuItems["New Note"].isEnabled, "with a library open, New Note should be on")
            let recent = fileMenu.menuItems["Open Recent"]
            XCTAssertTrue(recent.exists, "File ▸ Open Recent should exist")
            recent.hover()
            let clear = recent.menuItems["Clear Menu"]
            XCTAssertTrue(clear.waitForExistence(timeout: 5), "Open Recent should end in Clear Menu")
            XCTAssertFalse(clear.isEnabled, "with nothing listed, Clear Menu is greyed")
            app.typeKey(.escape, modifierFlags: [])
            app.typeKey(.escape, modifierFlags: [])
        }
    }
}

/// The No Library Open state (W49.notes-library-ux): a launch with no library (a first launch whose Save panel
/// was cancelled) said "No notes or extracts yet — press ⌘N", and ⌘N could make nothing. `-ANUITestNoLibrary`
/// starts the harness that way without the Save panel. Open Library… is driven to its confirmation and
/// cancelled, so nothing is switched or remembered; the pick stand-in and the bookmark suite keep it on scratch,
/// as in `ChooseStoreFolderUITests`.
final class NoLibraryOpenUITests: NotesFixtureUITestCase {

    private static let bookmarkSuite = "com.archivenotes.app.uitest-no-library.\(UUID().uuidString)"
    private static var adoptedStorePath: String { canonicalFixturePath + " Adopted Store.archivenotes" }

    override var waitsForSeededList: Bool { false }

    override var extraLaunchArguments: [String] {
        ["-ANUITestNoLibrary", "YES", "-ANUITestStorePickPath", Self.adoptedStorePath,
         "-ANUITestStoreBookmarkSuite", Self.bookmarkSuite]
    }

    func testNoLibraryOpenOffersNewAndOpenAndTurnsNewOff() throws {
        terminateStrayNotesInstances()
        try withFixture {
            XCTAssertTrue(mainWindow.waitForExistence(timeout: 10))
            let open = mainWindow.descendants(matching: .any)["an.list.noLibrary.open"].firstMatch
            XCTAssertTrue(open.waitForExistence(timeout: 15), "with no library, the list should offer Open Library…")
            XCTAssertTrue(mainWindow.descendants(matching: .any)["an.list.noLibrary.new"].firstMatch.exists,
                          "and New Library…")
            XCTAssertTrue(mainWindow.staticTexts["No Library Open"].firstMatch.exists, "the state should say so")
            XCTAssertFalse(mainWindow.descendants(matching: .any)["an.list.empty.library"].exists,
                           "the empty-library state, with its ⌘N hint, should not show")
            XCTAssertFalse(mainWindow.descendants(matching: .any)["an.sidebar.library"].exists,
                           "no library is named")
            let toolbarNew = mainWindow.descendants(matching: .any)["an.toolbar.new"].firstMatch
            XCTAssertTrue(toolbarNew.waitForExistence(timeout: 5))
            XCTAssertFalse(toolbarNew.isEnabled, "the toolbar's New should be off with no library")
            libraryShot("no-library", mainWindow)

            app.activate()
            let fileMenu = app.menuBars.menuBarItems["File"]
            fileMenu.click()
            XCTAssertTrue(fileMenu.menuItems["New Note"].waitForExistence(timeout: 5))
            XCTAssertFalse(fileMenu.menuItems["New Note"].isEnabled, "File ▸ New Note should be off")
            XCTAssertFalse(fileMenu.menuItems["New Extract"].isEnabled, "File ▸ New Extract should be off")
            XCTAssertFalse(fileMenu.menuItems["Reveal Library in Finder"].isEnabled,
                           "there is no library to reveal")
            XCTAssertTrue(fileMenu.menuItems["Open Library\u{2026}"].isEnabled)
            app.typeKey(.escape, modifierFlags: [])

            // The state's Open Library… is the menu's: the same check and confirmation. Cancel switches nothing.
            let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.archivenotes.app")
                .first?.processIdentifier
            open.click()
            let cancel = app.buttons["Cancel"].firstMatch
            XCTAssertTrue(app.buttons["Restart and Switch"].firstMatch.waitForExistence(timeout: 10),
                          "Open Library… from the state should ask before switching")
            cancel.click()
            XCTAssertTrue(open.waitForExistence(timeout: 10), "after Cancel the state is still there")
            XCTAssertEqual(NSRunningApplication.runningApplications(withBundleIdentifier: "com.archivenotes.app")
                .first?.processIdentifier, pid, "Cancel should not restart the app")
        }
    }
}

extension NotesFixtureUITestCase {
    /// The sidebar's library label: its text is the element's value (`accessibilityElement(children: .combine)`).
    func libraryText(_ element: XCUIElement) -> String {
        [element.label, (element.value as? String) ?? ""].joined(separator: " ")
    }

    func libraryShot(_ name: String, _ window: XCUIElement) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uitest-library-\(name).png")
        do {
            try window.screenshot().pngRepresentation.write(to: url, options: .atomic)
            print("[shot] library-\(name): wrote \(url.path)")
        } catch {
            print("[shot] library-\(name): could not write \(url.path) — \(error)")
        }
    }
}
