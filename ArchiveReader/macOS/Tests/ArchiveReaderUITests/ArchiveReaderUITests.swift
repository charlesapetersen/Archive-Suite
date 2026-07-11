import XCTest

final class ArchiveReaderUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testAppLaunchesAndShowsMainWindow() throws {
        let window = app.windows["Archive Reader"]
        XCTAssertTrue(
            window.waitForExistence(timeout: 10),
            "The main Archive Reader window should appear within 10 seconds"
        )
    }
}
