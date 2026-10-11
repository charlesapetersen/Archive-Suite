import XCTest
import AppKit   // NSPasteboard / NSWorkspace — read what Copy Link wrote, and hand the URL back to the app

/// W9.e2-links — the link part of the gap-closure runtime sweep (plan E2, record in `SUITE_TODO_DONE.md`): Copy Link (B9)
/// puts the item's `archivenotes://open` URL on the pasteboard, and opening that URL selects and loads the
/// linked item (B5). Both Copy Link entry points are driven: Note ▸ Copy Link and the row context menu.
///
/// Reads only — nothing here writes the store, so the fixture needs no restoring. The VM boots with
/// `--no-clipboard` (W9.g4-flake), so the guest pasteboard read back here is the app's own write.
final class NotesE2LinkTests: NotesFixtureUITestCase {

    /// B9 ⇄ B5 — Note ▸ Copy Link, then opening the copied URL with a different note selected, brings the
    /// linked note back.
    func testE2_CopyLinkRoundTripSelectsTheLinkedNote() throws {
        try withFixture {
            selectItem(uuid: Self.idReader)
            XCTAssertTrue(pollUntil(timeout: 10) { self.editorText.contains("egalitarian") },
                          "the linked note should be loaded before copying its link")
            // W9.e2-fu2: the menu read `canCopyCurrentItemLink` off the focused reference, whose identity
            // fields are not published, so it stayed disabled with a note selected.
            NSPasteboard.general.clearContents()
            editor.click()
            app.menuBars.menuBarItems["Note"].click()
            let menuEntry = app.menuBars.menuItems["Copy Link"]
            XCTAssertTrue(menuEntry.waitForExistence(timeout: 5))
            XCTAssertTrue(menuEntry.isEnabled, "Note ▸ Copy Link should be enabled with a note selected")
            menuEntry.click()
            let url = try copiedLink(naming: Self.idReader)

            selectItem(uuid: Self.idPlain)
            XCTAssertTrue(pollUntil(timeout: 10) { self.editorText.contains("A plain note") },
                          "a different note should be showing before the link is opened")
            try openInRunningApp(url)
            XCTAssertTrue(pollUntil(timeout: 15) { self.editorText.contains("egalitarian") },
                          "opening the copied link should select and load the linked note")
        }
    }

    /// B9 — the row context menu's Copy Link writes the same kind of URL for the row it was opened on.
    func testE2_ContextMenuCopyLinkNamesTheClickedRow() throws {
        try withFixture {
            selectItem(uuid: Self.idReader)
            NSPasteboard.general.clearContents()
            let row = mainWindow.descendants(matching: .any)["an.cell.title.\(Self.idPlain)"]
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            _ = pollUntil(timeout: 8) { app.activate(); return row.isHittable }
            row.rightClick()
            let entry = app.menuItems["Copy Link"].firstMatch
            XCTAssertTrue(entry.waitForExistence(timeout: 5), "the row context menu should offer Copy Link")
            entry.click()
            _ = try copiedLink(naming: Self.idPlain)
        }
    }

    // MARK: - Helpers

    private var editorText: String { (editor.value as? String) ?? "" }

    /// Poll the pasteboard for an `archivenotes://open` URL and check it names `id`.
    private func copiedLink(naming id: String) throws -> URL {
        var link: String?
        XCTAssertTrue(pollUntil(timeout: 10) {
            link = NSPasteboard.general.string(forType: .string)
            return link?.hasPrefix("archivenotes://open") == true
        }, "Copy Link should put an archivenotes://open URL on the pasteboard, got \(link ?? "nil")")
        let url = try XCTUnwrap(link.flatMap(URL.init(string:)))
        XCTAssertTrue(url.absoluteString.lowercased().contains(id), "the copied link should name \(id): \(url)")
        return url
    }

    /// `XCUIApplication.open(_:)` relaunches the app and loses the fixture launch environment, so hand the
    /// URL to the RUNNING instance through Launch Services, as a clicked link would.
    private func openInRunningApp(_ url: URL) throws {
        let running = try XCTUnwrap(NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.archivenotes.app").first?.bundleURL)
        let delivered = expectation(description: "Launch Services delivered the link")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: running, configuration: config) { _, error in
            XCTAssertNil(error, "opening the link should reach the running app")
            delivered.fulfill()
        }
        wait(for: [delivered], timeout: 15)
    }
}
