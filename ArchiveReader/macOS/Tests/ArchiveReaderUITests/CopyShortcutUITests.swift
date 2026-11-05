import XCTest
import AppKit

/// W48.reader-copy-shortcut — ⌘C copies selected document text, and only when nothing else should get it.
///
/// What the probe measured before the fix (VM, 2026-11-03): ⌘C was bound twice, on Edit ▸ Copy and on
/// Document ▸ Copy, and AppKit matched the Document item first. Panes and preview copied, but with the
/// caret in the find field ⌘C copied the PDF selection instead of the field's text. ⌘C is now Edit ▸ Copy
/// alone, reaching the panes through the responder chain (`ReaderPDFView.copy(_:)`).
///
/// The clipboard is read from this runner: the app and the runner share the guest's general pasteboard.
/// Each check seeds a sentinel first, so "nothing copied" is told apart from "copied the same text".
final class CopyShortcutUITests: FixtureUITestCase {

    private let sentinel = "W48-SENTINEL"
    /// Text on the fixture's first document's OCR page (`scripts/make-gui-fixture.sh`).
    private let pageText = "Reader synthetic fixture page"

    func testCopyShortcutInDocumentWindowRespectsSelectionAndFocusedField() throws {
        let before = fixtureSnapshot()
        waitForRows(minimum: 3, timeout: 10)
        clickRow(0)
        pressKey("o", modifiers: .command)
        settle(2)
        let doc = documentWindow()
        XCTAssertGreaterThanOrEqual(app.windows.count, 2, "precondition: the document window opened")

        XCTAssertFalse(menuItem("Document", "Copy").exists,
                       "⌘C belongs to Edit ▸ Copy alone; a second Copy here stole it from text fields")
        closeMenu()
        XCTAssertTrue(menuItem("Edit", "Copy Cleaned for Prose").exists); closeMenu()
        XCTAssertFalse(menuItem("Document", "Copy Cleaned for Prose").exists,
                       "both copies of what is on screen live under Edit (W40.fix-reader-edit-menu-copy)")
        closeMenu()

        // Nothing selected: Copy is disabled and ⌘C leaves the clipboard alone.
        doc.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.55)).click()
        settle(0.5)
        XCTAssertFalse(menuItem("Edit", "Copy").isEnabled, "Copy must be disabled with no text selected")
        closeMenu()
        XCTAssertEqual(clipboard(after: { pressKey("c", modifiers: .command) }), sentinel)
        XCTAssertEqual(clipboard(after: { pressKey("c", modifiers: [.command, .option]) }), sentinel)

        // Text selected on the OCR page.
        pressKey("a", modifiers: .command)
        settle(0.5)
        XCTAssertTrue(menuItem("Edit", "Copy").isEnabled, "Copy must be enabled with text selected")
        closeMenu()
        let plain = clipboard(after: { pressKey("c", modifiers: .command) })
        XCTAssertTrue(plain.contains(pageText), "⌘C should copy the selected page text, got «\(plain)»")
        XCTAssertFalse(NSPasteboard.general.types?.contains(.html) ?? false,
                       "⌘C is the verbatim plain-text copy, not PDFKit's rich copy")
        let cleaned = clipboard(after: { pressKey("c", modifiers: [.command, .option]) })
        XCTAssertTrue(cleaned.contains(pageText), "⌥⌘C should copy the selection cleaned, got «\(cleaned)»")

        // Focus on the image pane: the selection on the text page is still what ⌘C copies.
        pressKey(XCUIKeyboardKey.leftArrow.rawValue, modifiers: [.command, .option])
        settle(0.5)
        XCTAssertEqual(clipboard(after: { pressKey("c", modifiers: .command) }), plain,
                       "⌘C should copy the text page's selection from either pane")

        // The find field takes ⌘C for its own text.
        pressKey("f", modifiers: .command)
        let find = app.textFields["ar.doc.findField"]
        XCTAssertTrue(find.waitForExistence(timeout: 5))
        settle(0.5)
        app.typeText("Calif")
        pressKey("a", modifiers: .command)
        settle(0.3)
        XCTAssertEqual(clipboard(after: { pressKey("c", modifiers: .command) }), "Calif",
                       "with the caret in the find field, ⌘C copies the field's selected text")

        pressKey("w", modifiers: .command)
        settle(1)
        XCTAssertEqual(fixtureSnapshot(), before, "copying must not change any archive file or tag")
    }

    func testCopyShortcutInPreviewSheet() throws {
        let before = fixtureSnapshot()
        waitForRows(minimum: 3, timeout: 10)
        clickRow(0)
        toolbarButton("ar.toolbar.preview").click()
        XCTAssertTrue(app.buttons["ar.preview.done"].waitForExistence(timeout: 5), "the preview should open")
        settle(1)

        XCTAssertEqual(clipboard(after: { pressKey("c", modifiers: .command) }), sentinel,
                       "⌘C with nothing selected leaves the clipboard alone")

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.exists, "precondition: the preview is a sheet")
        sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.55)).click()
        settle(0.5)
        pressKey("a", modifiers: .command)
        settle(0.5)
        let plain = clipboard(after: { pressKey("c", modifiers: .command) })
        XCTAssertTrue(plain.contains(pageText), "⌘C should copy the preview's selected text, got «\(plain)»")
        let cleaned = clipboard(after: { pressKey("c", modifiers: [.command, .option]) })
        XCTAssertTrue(cleaned.contains(pageText), "⌥⌘C should copy it cleaned, got «\(cleaned)»")

        app.buttons["ar.preview.done"].click()
        settle(1)
        XCTAssertEqual(fixtureSnapshot(), before, "copying must not change any archive file or tag")
    }

    // MARK: helpers

    /// Seed the sentinel, act, and return what the clipboard holds afterwards.
    private func clipboard(after action: () -> Void) -> String {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sentinel, forType: .string)
        action()
        settle(0.6)
        return NSPasteboard.general.string(forType: .string) ?? "<nil>"
    }

    /// Every archive file's modification date and Finder tags. Fresh URLs each call, so nothing is cached.
    /// The app's own content index (`content-index-*.sqlite3` and its WAL/SHM) is left out: the Reader
    /// writes it as it runs, copy or no copy (its `-shm` moved during the first VM run of this test).
    private func fixtureSnapshot() -> [String: String] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .tagNamesKey, .isRegularFileKey]
        let root = URL(fileURLWithPath: Self.fixturePath)
        var out: [String: String] = [:]
        let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys)
        while let url = walk?.nextObject() as? URL {
            guard !url.lastPathComponent.hasPrefix("content-index"),
                  let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            out[url.path] = "\(v.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(v.tagNames ?? [])"
        }
        XCTAssertFalse(out.isEmpty, "precondition: the fixture has files to watch")
        return out
    }

    private func documentWindow() -> XCUIElement {
        for i in 0..<app.windows.count where app.windows.element(boundBy: i).title != "Archive Reader" {
            return app.windows.element(boundBy: i)
        }
        return app.windows.firstMatch
    }

    private func settle(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private func closeMenu() { app.typeKey(.escape, modifierFlags: []); settle(0.3) }

    /// Open a menu-bar menu and return one of its items (items join the tree only while the menu is open).
    private func menuItem(_ menu: String, _ title: String) -> XCUIElement {
        let bar = app.menuBars.element(boundBy: 0)
        let item = bar.menuBarItems[menu]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the \(menu) menu should exist")
        item.click()
        let entry = item.menuItems[title]
        _ = entry.waitForExistence(timeout: 2)
        return entry
    }
}
