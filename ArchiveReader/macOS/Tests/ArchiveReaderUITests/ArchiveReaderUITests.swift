import XCTest

@MainActor   // XCUIApplication / XCUIElement are main-actor-isolated in the Swift 6 SDK
final class ArchiveReaderUITests: XCTestCase {

    private var app: XCUIApplication!

    // Async hooks, not the `…WithError` pair: those are nonisolated, so touching `app` there was a
    // Swift 6 isolation warning; the async overrides inherit this class's `@MainActor`.
    override func setUp() async throws {
        continueAfterFailure = false
        app = .archiveUITestApp()   // never a bare XCUIApplication() — see UITestLaunch
        app.launch()
    }

    override func tearDown() async throws {
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

    /// W49.reader-ux-gaps-small: with no folder chosen (none ever is in the VM: every folder panel is cancelled), the
    /// empty list offers Choose Folder… itself rather than pointing at the toolbar.
    func testNoFolderChosenOffersChooseFolder() throws {
        XCTAssertTrue(app.windows["Archive Reader"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["No archive folder chosen"].waitForExistence(timeout: 10),
                      "a launch with no saved folder shows the no-folder state")
        XCTAssertTrue(app.buttons["ar.empty.chooseFolder"].exists, "and its way out")
    }

    /// W26.walk2 — the incident's replacement sentence, through the real window in the headless VM.
    /// A brand-new path has never been Spotlight-indexed; the sole file is genuinely untagged. The UI
    /// may say that only after a complete walk, and the denominator must be visible in the rendered copy.
    func testAnUntaggedFolderShowsTheScannedDenominator() throws {
        // The UI-test runner is sandboxed, so its redirected home is the one place it may create this
        // fixture. The Reader's DEBUG-only `/Users/` temporary exception can read that container path;
        // Release retains the production entitlements and none of this code ships in the app target.
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ArchiveReader", isDirectory: true)
            .appendingPathComponent("AR-GUI-Untagged-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("genuinely untagged scratch file".utf8).write(to: root.appendingPathComponent("one.pdf"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        app.terminate()
        // ASSIGNS rather than appends (a deliberately fresh argument list for the relaunch), so the
        // state-ignoring flag has to be put back explicitly — `+=` elsewhere keeps it for free.
        app.launchArguments = UITestLaunch.arguments(["-ARUITestRootPath", root.path])
        app.launch()
        app.activate()

        let emptyState = app.descendants(matching: .any)["ar.empty.nothingTagged"]
        XCTAssertTrue(emptyState.waitForExistence(timeout: 10),
                      "the empty state must quote what discovery actually examined")
        let accessibilityText = emptyState.accessibilityText   // label + value — see UITestText.swift
        XCTAssertTrue(accessibilityText.contains("No tagged documents"),
                      "a complete scan of an untagged scratch folder should reach the honest empty state")
        XCTAssertTrue(accessibilityText.contains("Scanned 1 file in this folder"),
                      "the rendered denominator must match the one file actually examined")
        XCTAssertTrue(accessibilityText.contains("none carry a Read or Unread tag"),
                      "the claim about tags is coupled to its measured denominator")
        XCTAssertTrue(app.buttons["ar.empty.chooseFolder"].exists,
                      "the empty state should offer the way out: another folder (W40.fix-reader-visual-polish)")
    }

    /// W49.storage-finder — new Processor output keeps its fields only in catalogue companions, with no Finder tags,
    /// so a tags-mode folder of it lists nothing; the empty list says why and offers the catalogue mode.
    func testUntaggedCatalogueOutputOffersCatalogueCompanions() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ArchiveReader", isDirectory: true)
            .appendingPathComponent("AR-GUI-Companions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["one.pdf", "two.pdf"] {
            try Data("untagged scratch output".utf8).write(to: root.appendingPathComponent(name))
            try Data("{}".utf8).write(to: root.appendingPathComponent(name + ".archivesuite.json"))
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        app.terminate()
        app.launchArguments = UITestLaunch.arguments(["-ARUITestRootPath", root.path])
        app.launch()
        app.activate()

        let offer = app.descendants(matching: .any)["ar.empty.catalogueRecords"]
        XCTAssertTrue(offer.waitForExistence(timeout: 10), "the empty list must say the PDFs keep catalogue records")
        XCTAssertTrue(offer.accessibilityText.contains("2 PDFs here keep their fields"), offer.accessibilityText)
        XCTAssertTrue(app.buttons["ar.empty.useCatalogue"].exists, "and offer the catalogue companions")
        XCTAssertFalse(app.descendants(matching: .any)["ar.empty.nothingTagged"].exists,
                       "the plain untagged sentence is replaced, not stacked")
    }

    /// W49.storage-finder-reader-mirror: a folder that lists tagged PDFs and also holds catalogue output says so at the
    /// foot of the list and offers the catalogue companions.
    func testAListedFolderWithCatalogueOutputSaysSo() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ArchiveReader", isDirectory: true)
            .appendingPathComponent("AR-GUI-Mixed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let tagged = root.appendingPathComponent("tagged.pdf")
        try Data("tagged scratch".utf8).write(to: tagged)
        try (tagged as NSURL).setResourceValue(["Unread"], forKey: .tagNamesKey)
        try Data("untagged scratch output".utf8).write(to: root.appendingPathComponent("output.pdf"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("output.pdf.archivesuite.json"))

        app.terminate()
        app.launchArguments = UITestLaunch.arguments(["-ARUITestRootPath", root.path])
        app.launch()
        app.activate()

        let notice = app.descendants(matching: .any)["ar.list.catalogueRecords"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "the listed folder must mention its catalogue output")
        XCTAssertTrue(app.buttons["ar.list.useCatalogue"].exists, "and offer the catalogue companions")
        XCTAssertEqual(app.tables["ar.table"].tableRows.count, 1, "the tagged PDF is still listed")
    }
}
