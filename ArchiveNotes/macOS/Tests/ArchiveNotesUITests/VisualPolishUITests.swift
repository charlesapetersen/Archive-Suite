import AppKit
import XCTest

/// W40.fix-notes-visual-polish: the visual review's small inconsistencies that need the real window to
/// check. A name prompt takes typing at once and refuses an empty name; a clicked folder is the
/// highlighted sidebar row; the editor prompts are sheets on the window. The shots it prints (`[shot]`)
/// are copied out by `ops/gui/vm-gui-runner.sh` for the rest, which are looked at, not asserted.
final class VisualPolishUITests: NotesFixtureUITestCase {

    /// Typing straight after the New Folder sheet opens replaces its default name, and Return creates
    /// the folder: no click into the field. The SwiftUI alert left focus on Cancel and typing did nothing.
    func testNewFolderSheetTakesTypingAtOnce() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            let newFolder = mainWindow.descendants(matching: .any)["an.sidebar.newFolder"]
            XCTAssertTrue(newFolder.waitForExistence(timeout: 10))
            newFolder.click()
            let sheet = mainWindow.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 8), "New Folder should open a sheet")
            XCTAssertTrue(sheet.textFields.firstMatch.waitForExistence(timeout: 5))
            pause(0.5)
            shot("new-folder-sheet")
            app.typeText("Typed Folder")
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(pollUntil(timeout: 10) { self.folderNames().contains("Typed Folder") },
                          "typing into the just-opened sheet and pressing Return should create the folder, "
                          + "saw \(folderNames())")
        }
    }

    /// Save as Smart Folder cannot be confirmed with an empty name; Escape dismisses the sheet.
    func testSmartFolderSaveNeedsAName() throws {
        try withFixture {
            let save = mainWindow.buttons["an.filter.save"]
            XCTAssertTrue(save.waitForExistence(timeout: 10))
            save.click()
            let sheet = mainWindow.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 8))
            let confirm = sheet.buttons["Save"].firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            XCTAssertFalse(confirm.isEnabled, "Save must be disabled while the name is empty")
            app.typeText("   ")
            XCTAssertFalse(confirm.isEnabled, "a blank name is still empty")
            app.typeText("Named")
            XCTAssertTrue(pollUntil(timeout: 3) { confirm.isEnabled }, "Save should enable once named")
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(pollUntil(timeout: 5) { !sheet.exists }, "Escape should dismiss the sheet")
        }
    }

    /// After a click on a folder, that folder's row is the selected sidebar row, and All Notes is not.
    func testClickedFolderIsTheHighlightedRow() throws {
        try withFixture {
            let reading = sidebarRow(named: "Reading")
            XCTAssertTrue(reading.waitForExistence(timeout: 10), mainWindow.debugDescription)
            reading.click()
            pause(1)
            shot("folder-clicked")
            XCTAssertTrue(pollUntil(timeout: 5) { reading.isSelected },
                          "the clicked folder's row should be selected")
            XCTAssertFalse(sidebarRow(named: "All Notes").isSelected, "All Notes should not stay selected")
        }
    }

    /// Shots for the polish that is judged by eye: the list's Quality cells and a selected replicated
    /// row, the detail with no note, Insert Link as a sheet, a note's Locations block, Settings.
    func testPolishShots() throws {
        try withFixture {
            let title = mainWindow.descendants(matching: .any)["an.cell.title.\(Self.idPlain)"].firstMatch
            XCTAssertTrue(title.waitForExistence(timeout: 15))
            shot("list-no-selection")
            // The fixture's reader note is in two folders, so its title carries the replicated glyph.
            let replicated = mainWindow.descendants(matching: .any)["an.cell.title.\(Self.idReader)"].firstMatch
            if replicated.waitForExistence(timeout: 5) {
                replicated.click()
                pause(1.5)
                shot("replicated-selected")
            }
            title.click()
            pause(1.5)
            shot("note-selected")
            let link = mainWindow.descendants(matching: .any)["an.editor.toolbar.link"].firstMatch
            if link.waitForExistence(timeout: 5) {
                link.click()
                let sheet = mainWindow.sheets.firstMatch
                XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Insert Link should be a sheet on the window")
                pause(0.5)
                shot("insert-link-sheet")
                app.typeKey(.escape, modifierFlags: [])
                _ = pollUntil(timeout: 5) { !sheet.exists }
            }
            let before = app.windows.count
            app.typeKey(",", modifierFlags: .command)
            if pollUntil(timeout: 10, { self.app.windows.count > before }) {
                pause(1)
                shot("settings", whole: true)
                app.typeKey("w", modifierFlags: .command)
            }
        }
    }

    // MARK: - Helpers

    private func sidebarRow(named name: String) -> XCUIElement {
        let outline = mainWindow.outlines.firstMatch
        return outline.outlineRows.containing(NSPredicate(format: "value ==[c] %@ OR label ==[c] %@", name, name))
            .firstMatch
    }

    private func folderNames() -> [String] {
        let path = Self.fixturePath + "/organization.json"
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["folders"] as? [[String: Any]] else { return [] }
        return arr.compactMap { $0["name"] as? String }
    }

    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Write a shot the VM runner copies out: the app's windows cropped, or the whole screen.
    private func shot(_ name: String, whole: Bool = false) {
        let data = whole ? XCUIScreen.main.screenshot().pngRepresentation : mainWindow.screenshot().pngRepresentation
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uitest-polish-\(name).png")
        do {
            try data.write(to: url, options: .atomic)
            print("[shot] polish-\(name): wrote \(url.path)")
        } catch {
            print("[shot] polish-\(name): could not write \(url.path) — \(error)")
        }
    }
}
