import XCTest

/// W49.notes-suspects-small — the reproduce attempt for S-008 (phase rule 5a): a Notes window resized just before ⌘Q
/// keeps its size at the next launch. `-ANUITestPersistWindowSize YES` saves the size as a normal launch does (the
/// harness otherwise skips it). The first test is the control: a window closed before the quit saves its size, so
/// the flag and the relaunch read work. The second is the suspect's path: resize, then quit straight away. It did not
/// reproduce on 2026-11-20 (the size saved before was the control's, so the quit saved the new one): S-008 cleared.
final class NotesWindowSizeQuitUITests: NotesFixtureUITestCase {

    override var extraLaunchArguments: [String] { ["-ANUITestPersistWindowSize", "YES"] }

    /// Drags the window by its title bar towards the top left, for room, then its bottom-right corner by the first of
    /// `offsets` the window's minimum size and the screen allow (as `VisualReviewUITests.resizeMainWindow` does).
    /// Returns the size the window then has.
    private func resize(_ offsets: [CGVector]) -> CGSize {
        let win = mainWindow
        let origin = win.coordinate(withNormalizedOffset: .zero)
        var f = win.frame
        origin.withOffset(CGVector(dx: f.width / 3, dy: 12))
            .click(forDuration: 0.2, thenDragTo: origin.withOffset(CGVector(dx: f.width / 3 - 200, dy: 12 - 200)))
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let before = win.frame.size
        for offset in offsets {
            f = win.frame
            let start = win.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.width - 2, dy: f.height - 2))
            start.click(forDuration: 0.2, thenDragTo: start.withOffset(offset))
            if pollUntil(timeout: 3, {
                abs(win.frame.width - before.width) > 20 || abs(win.frame.height - before.height) > 20
            }) { break }
        }
        XCTAssertTrue(abs(win.frame.width - before.width) > 20 || abs(win.frame.height - before.height) > 20,
                      "the corner drag should resize the window (was \(before))")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        print("[S-008] resized from \(before) to \(win.frame.size)")
        return win.frame.size
    }

    /// Archive Notes ▸ Quit Archive Notes, the menu ⌘Q fires.
    private func quit() {
        let appMenu = app.menuBars.menuBarItems["Archive Notes"]
        XCTAssertTrue(appMenu.waitForExistence(timeout: 5))
        appMenu.click()
        let quitItem = app.menuItems["Quit Archive Notes"]
        XCTAssertTrue(quitItem.waitForExistence(timeout: 5))
        quitItem.click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 30), "the app should quit")
    }

    private func relaunchedSize() -> CGSize {
        app.launch()
        app.activate()
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 15), "the window should come back after relaunch")
        RunLoop.current.run(until: Date().addingTimeInterval(2))   // configureWindow runs on first appearance
        return mainWindow.frame.size
    }

    private func assertSameSize(_ a: CGSize, _ b: CGSize, _ message: String) {
        XCTAssertEqual(a.width, b.width, accuracy: 3, message)
        XCTAssertEqual(a.height, b.height, accuracy: 3, message)
    }

    func testA_ResizeCloseQuitKeepsTheSize() throws {
        try withFixture {
            app.activate()
            let resized = resize([CGVector(dx: -140, dy: -90), CGVector(dx: 140, dy: 90), CGVector(dx: 140, dy: -90),
                                  CGVector(dx: -140, dy: 90)])
            mainWindow.buttons[XCUIIdentifierCloseWindow].click()
            XCTAssertTrue(mainWindow.waitForNonExistence(timeout: 10))
            quit()
            let after = relaunchedSize()
            print("[S-008] control: resized to \(resized), closed, quit, relaunched at \(after)")
            assertSameSize(after, resized, "a window closed before the quit keeps its size (control)")
        }
    }

    func testB_ResizeThenQuitKeepsTheSize() throws {
        try withFixture {
            app.activate()
            let resized = resize([CGVector(dx: -60, dy: -110), CGVector(dx: 60, dy: 110), CGVector(dx: 60, dy: -110),
                                  CGVector(dx: -60, dy: 110)])
            quit()
            let after = relaunchedSize()
            print("[S-008] resized to \(resized) before ⌘Q, relaunched at \(after)")
            assertSameSize(after, resized, "a window resized just before ⌘Q keeps its size (was \(resized), now \(after))")
        }
    }
}
