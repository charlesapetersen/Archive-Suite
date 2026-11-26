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
    /// One per test, not per process: a repeated run (`-test-iterations`) would otherwise start in the store the
    /// previous iteration picked.
    private let bookmarkSuite = "com.archivenotes.app.uitest-store-bookmark.\(UUID().uuidString)"
    private static var adoptedStorePath: String { canonicalFixturePath + " Adopted Store.archivenotes" }

    override var extraLaunchArguments: [String] {
        ["-ANUITestStorePickPath", Self.adoptedStorePath, "-ANUITestStoreBookmarkSuite", bookmarkSuite]
    }

    func testChooseStoreFolderAdoptsAStoreThatSurvivesRelaunch() throws {
        terminateStrayNotesInstances()
        // The relaunched instance is not the one XCUITest launched, so its tearDown would leave it running.
        addTeardownBlock { @MainActor in terminateStrayNotesInstances() }
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
            // from the test. The new process carries this run's arguments, handed over through the app's defaults
            // since a sandboxed relaunch is given none (W49.notes-relaunch-args-flake), so it opens the scratch stores.
            var relaunched: pid_t = 0
            XCTAssertTrue(pollUntil(timeout: 30) {
                guard let new = NSRunningApplication.runningApplications(withBundleIdentifier: "com.archivenotes.app")
                    .first(where: { $0.processIdentifier != pid && !$0.isTerminated }) else { return false }
                relaunched = new.processIdentifier
                return true
            }, "confirming should restart the app")
            XCTAssertTrue(pollUntil(timeout: 30) { NSRunningApplication(processIdentifier: pid) == nil },
                          "the old instance should have quit")
            // `app` launched the old instance, and until XCUITest has registered the new one it reports the app not
            // running, so an `activate()` then starts an instance of its own (measured: a second instance, beside the
            // relaunch). Waiting for the running state attaches to the relaunched instance instead.
            let restarted = XCUIApplication(bundleIdentifier: "com.archivenotes.app")
            XCTAssertTrue(pollUntil(timeout: 20) { restarted.state != .notRunning },
                          "XCUITest should see the relaunched instance running")
            restarted.activate()
            let mainWindow = restarted.windows["Archive Notes"]
            XCTAssertTrue(mainWindow.waitForExistence(timeout: 15), "the window should come back after the restart")
            let instances = { NSRunningApplication.runningApplications(withBundleIdentifier: "com.archivenotes.app")
                .filter { !$0.isTerminated }.map(\.processIdentifier) }
            XCTAssertEqual(instances(), [relaunched], "the instance checked should be the one Notes started")
            let adopted = mainWindow.descendants(matching: .any)["an.cell.title.\(Self.adoptedNoteID)"]
            XCTAssertTrue(adopted.waitForExistence(timeout: 25),
                          "after the relaunch the list should show the note from the picked store")
            XCTAssertFalse(mainWindow.descendants(matching: .any)["an.cell.title.\(Self.idPlain)"].exists,
                           "the fixture store's notes should no longer be listed")
            XCTAssertEqual(FileManager.default.contents(atPath: markerPath), marker, "the store is adopted where it lies: its marker is not rewritten")
        }
    }
}

/// A Notes instance left by an earlier run, started by LaunchServices without this run's arguments (a library
/// opened from Finder does that, W49.notes-store-format): it holds no library, only the first-launch Save panel,
/// and would take the relaunch's place. VM-only scratch instances with no store, so nothing is lost.
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
