import XCTest

/// W40.fix-notes-small-wins (owner, notes-2 row 6) — after a quit and a fresh launch, the note that was open is
/// open again. `-ANUITestLastOpenSuite` sends the remembered note to a suite named for this run; without it a
/// UITest launch neither reads nor writes the app's own key, so no other test starts with a note selected.
final class ReopenLastNoteUITests: NotesFixtureUITestCase {

    private static let lastOpenSuite = "com.archivenotes.app.uitest-last-open.\(UUID().uuidString)"

    override var extraLaunchArguments: [String] { ["-ANUITestLastOpenSuite", Self.lastOpenSuite] }

    func testTheNoteOpenAtQuitIsOpenAfterRelaunch() throws {
        try withFixture {
            XCTAssertTrue(editor.waitForExistence(timeout: 10))
            XCTAssertTrue(((editor.value as? String) ?? "").isEmpty, "nothing is open at the first launch")

            selectItem(uuid: Self.idReader)
            XCTAssertTrue(pollUntil(timeout: 15) { !((self.editor.value as? String) ?? "").isEmpty },
                          "the selected note should open")
            let opened = (editor.value as? String) ?? ""

            app.terminate()
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 30))
            app.launch()
            app.activate()
            XCTAssertTrue(mainWindow.waitForExistence(timeout: 15), "the window should come back after relaunch")
            XCTAssertTrue(pollUntil(timeout: 25) { (self.editor.value as? String) == opened },
                          "the note open at quit should be open again")
        }
    }
}
