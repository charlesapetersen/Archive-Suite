import XCTest

/// W40.fix-notes-choose-store (ledger N-48) — File ▸ Choose Store Folder… adopts a store where it lies and
/// the pick survives a relaunch: pick a folder holding a store, confirm, the app quits, launch it again,
/// and the notes are read from the picked store.
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
    private static var adoptedStorePath: String { canonicalFixturePath + " Adopted Store" }

    override var extraLaunchArguments: [String] {
        ["-ANUITestStorePickPath", Self.adoptedStorePath, "-ANUITestStoreBookmarkSuite", Self.bookmarkSuite]
    }

    func testChooseStoreFolderAdoptsAStoreThatSurvivesRelaunch() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            let markerPath = Self.adoptedStorePath + "/.archive-suite-root.json"
            let marker = try XCTUnwrap(FileManager.default.contents(atPath: markerPath),
                                       "no store to adopt at \(Self.adoptedStorePath) — rerun scripts/make-notes-fixture.sh")

            app.activate()
            app.menuBars.menuBarItems["File"].click()
            let choose = app.menuBars.menuItems["Choose Store Folder\u{2026}"]
            XCTAssertTrue(choose.waitForExistence(timeout: 5), "File ▸ Choose Store Folder… should be present")
            choose.click()

            // The alert's button is reported twice (the alert and its window); either is the one control.
            let confirm = app.buttons["Quit and Switch"].firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 10), "picking a store should ask before switching")
            confirm.click()
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 30), "confirming should quit the app")

            app.launch()
            app.activate()
            XCTAssertTrue(mainWindow.waitForExistence(timeout: 15), "the window should come back after relaunch")
            let adopted = mainWindow.descendants(matching: .any)["an.cell.title.\(Self.adoptedNoteID)"]
            XCTAssertTrue(adopted.waitForExistence(timeout: 25),
                          "after the relaunch the list should show the note from the picked store")
            XCTAssertFalse(mainWindow.descendants(matching: .any)["an.cell.title.\(Self.idPlain)"].exists,
                           "the fixture store's notes should no longer be listed")
            XCTAssertEqual(FileManager.default.contents(atPath: markerPath), marker, "the store is adopted where it lies: its marker is not rewritten")
        }
    }
}
