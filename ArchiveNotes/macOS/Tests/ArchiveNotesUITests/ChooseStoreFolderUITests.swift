import XCTest
import AppKit

/// W40.fix-notes-choose-store (ledger N-48), W49.notes-store-format — File ▸ Open Library… adopts a library where it lies and
/// the pick survives a relaunch: pick a folder holding a store, confirm, the app restarts itself, and the
/// notes are read from the picked store.
///
/// The NSOpenPanel is the one step an XCUITest cannot drive, so `-ANUITestStorePickPath` stands in for the
/// folder a person would pick (`NotesModel.storeFolderChooser`). `-ANUITestStoreBookmarkSuite` sends the
/// remembered bookmark to a suite named for this run, never the app's real `notesStoreRootBookmark`, so
/// driving the picker here cannot move the store a normal launch opens (`GUI_SAFETY.md` rule 3). The
/// picked store is a scratch folder BESIDE the generated fixture (inside it would be refused: a store is
/// never made inside another store), which `make-notes-fixture.sh` rebuilds on every run and this
/// runner may only read.
final class ChooseStoreFolderUITests: NotesFixtureUITestCase {

    private static let adoptedNoteID = "55555555-5555-5555-5555-555555555555"
    private static let bookmarkSuite = "com.archivenotes.app.uitest-store-bookmark.\(UUID().uuidString)"
    private static var adoptedStorePath: String { canonicalFixturePath + " Adopted Store.archivenotes" }

    override var extraLaunchArguments: [String] {
        ["-ANUITestStorePickPath", Self.adoptedStorePath, "-ANUITestStoreBookmarkSuite", Self.bookmarkSuite]
    }

    func testChooseStoreFolderAdoptsAStoreThatSurvivesRelaunch() throws {
        terminateStrayNotesInstances()
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            let markerPath = Self.adoptedStorePath + "/.archive-suite-root.json"
            let marker = try XCTUnwrap(FileManager.default.contents(atPath: markerPath),
                                       "no store to adopt at \(Self.adoptedStorePath) — rerun scripts/make-notes-fixture.sh")

            app.activate()
            app.menuBars.menuBarItems["File"].click()
            let choose = app.menuBars.menuItems["Open Library\u{2026}"]
            XCTAssertTrue(choose.waitForExistence(timeout: 5), "File ▸ Open Library… should be present")
            choose.click()

            // The alert's button is reported twice (the alert and its window); either is the one control.
            let confirm = app.buttons["Restart and Switch"].firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 10), "picking a store should ask before switching")
            let pid = try XCTUnwrap(NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.archivenotes.app").first?.processIdentifier)
            confirm.click()

            // Restart and Switch (owner, notes-2 row 1): Notes quits and starts itself again, with no relaunch
            // from the test. The new process carries this run's arguments, so it opens the scratch stores.
            XCTAssertTrue(pollUntil(timeout: 30) {
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.archivenotes.app")
                    .contains { $0.processIdentifier != pid && !$0.isTerminated }
            }, "confirming should restart the app")
            XCTAssertTrue(pollUntil(timeout: 30) { NSRunningApplication(processIdentifier: pid) == nil },
                          "the old instance should have quit")
            app.activate()
            XCTAssertTrue(mainWindow.waitForExistence(timeout: 15), "the window should come back after the restart")
            let adopted = mainWindow.descendants(matching: .any)["an.cell.title.\(Self.adoptedNoteID)"]
            XCTAssertTrue(adopted.waitForExistence(timeout: 25),
                          "after the relaunch the list should show the note from the picked store")
            XCTAssertFalse(mainWindow.descendants(matching: .any)["an.cell.title.\(Self.idPlain)"].exists,
                           "the fixture store's notes should no longer be listed")
            XCTAssertEqual(FileManager.default.contents(atPath: markerPath), marker, "the store is adopted where it lies: its marker is not rewritten")
        }
    }
}

/// W49.notes-store-format: a library opened from Finder. A class of its own, so its launch does not resolve the
/// pick `ChooseStoreFolderUITests` remembers; its own throwaway bookmark suite keeps even a mis-click away from
/// `notesStoreRootBookmark`.
final class OpenLibraryFromFinderUITests: NotesFixtureUITestCase {

    private static let bookmarkSuite = "com.archivenotes.app.uitest-finder-bookmark.\(UUID().uuidString)"
    private static var adoptedStorePath: String { canonicalFixturePath + " Adopted Store.archivenotes" }

    override var extraLaunchArguments: [String] { ["-ANUITestStoreBookmarkSuite", Self.bookmarkSuite] }

    /// A library opened from Finder reaches Notes (the declared document type, the open-documents event
    /// `NotesAppDelegate` takes) and asks before switching. LaunchServices does not hand a document to an
    /// instance XCUITest launched (it starts a second one, measured in the VM), so the test quits that one and
    /// lets LaunchServices launch Notes with the library, as a double-click on a closed app does, passing this
    /// run's scratch arguments on. Cancelled, so nothing is remembered and the app does not restart.
    func testLibraryOpenedFromFinderAsksToSwitch() throws {
        terminateStrayNotesInstances()
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            let library = URL(fileURLWithPath: Self.adoptedStorePath, isDirectory: true)
            let running = try XCTUnwrap(NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.archivenotes.app").first)
            let appURL = try XCTUnwrap(running.bundleURL)
            let arguments = app.launchArguments
            app.terminate()
            XCTAssertTrue(pollUntil(timeout: 15) {
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.archivenotes.app").isEmpty
            }, "no other Notes instance should be left to receive the library")

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = arguments
            let opened = expectation(description: "LaunchServices hands the library to Notes")
            NSWorkspace.shared.open([library], withApplicationAt: appURL, configuration: configuration) { _, error in
                XCTAssertNil(error, "LaunchServices should open the library with Notes")
                opened.fulfill()
            }
            wait(for: [opened], timeout: 20)

            app.activate()
            let confirm = app.buttons["Restart and Switch"].firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 20), "a library from Finder should ask before switching")
            XCTAssertFalse(app.sheets.firstMatch.exists, "no first-launch panel beside it")
            app.buttons["Cancel"].firstMatch.click()
            XCTAssertTrue(mainWindow.descendants(matching: .any)["an.cell.title.\(Self.idPlain)"]
                .waitForExistence(timeout: 15), "cancelling keeps the fixture library")
            XCTAssertEqual(NSRunningApplication.runningApplications(withBundleIdentifier: "com.archivenotes.app").count,
                           1, "one instance, no restart")
        }
    }
}

/// A Notes instance left by an earlier run, started by LaunchServices without this run's arguments: it holds no
/// library, only the first-launch Save panel (seen in the VM, W49.notes-store-format), and would take the
/// relaunch's or the library's place. VM-only scratch instances with no store, so nothing is lost.
func terminateStrayNotesInstances() {
    for stray in NSRunningApplication.runningApplications(withBundleIdentifier: "com.archivenotes.app") {
        stray.forceTerminate()
    }
    let deadline = Date().addingTimeInterval(10)
    while !NSRunningApplication.runningApplications(withBundleIdentifier: "com.archivenotes.app").isEmpty,
          Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
}
