import XCTest
import AppKit

/// W40.fix-notes-stale-body-on-switch: hold a large note's read open rather than racing the disk.
/// Real keyboard input and the production image-paste path must leave BOTH scratch files untouched.
final class NoteSwitchSafetyUITests: NotesFixtureUITestCase {
    override var extraLaunchArguments: [String] { ["-ANUITestHoldBodyID", Self.idReader] }

    func testInputWhileLargeNoteLoadsCannotEditEitherNote() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            @MainActor func file(_ id: String) throws -> URL {
                let dir = URL(fileURLWithPath: Self.fixturePath).appendingPathComponent("items/\(id)")
                return try XCTUnwrap(FileManager.default.contentsOfDirectory(at: dir,
                    includingPropertiesForKeys: nil).first { $0.pathExtension == "md" })
            }
            let a = try file(Self.idPlain), b = try file(Self.idReader)
            var large = try Data(contentsOf: b)
            large.append(Data(("\n\n" + String(repeating: String(repeating: "large note text ", count: 64) + "\n\n", count: 1024)).utf8))
            try large.write(to: b, options: .atomic)
            selectItem(uuid: Self.idPlain)
            let editor = mainWindow.textViews["an.editor.text"]
            XCTAssertTrue(pollUntil(timeout: 15) { (editor.value as? String)?.contains("A plain note") == true })
            // Build real undo history and leave an accepted keystroke for flush-on-switch.
            let focus = mainWindow.buttons["an.editor.test.focus"]
            focus.click()
            XCTAssertEqual(focus.value as? String, "editable=true focused=true")
            XCTAssertTrue(pollUntil(timeout: 5) { editor.value(forKey: "hasKeyboardFocus") as? Bool == true })
            app.typeText("AcceptedBeforeSwitch")
            XCTAssertTrue((editor.value as? String ?? "").contains("AcceptedBeforeSwitch"))
            app.typeKey("z", modifierFlags: .command)
            XCTAssertFalse((editor.value as? String ?? "").contains("AcceptedBeforeSwitch"), "enabled Undo must work")
            app.typeKey("z", modifierFlags: [.command, .shift])
            XCTAssertTrue((editor.value as? String ?? "").contains("AcceptedBeforeSwitch"), "enabled Redo must work")
            selectItem(uuid: Self.idReader)
            let release = mainWindow.buttons["an.editor.test.releaseBodyLoad"]
            XCTAssertTrue(pollUntil(timeout: 10) { release.value as? String == "waiting" })
            XCTAssertTrue(self.noteBody(uuid: Self.idPlain)?.contains("AcceptedBeforeSwitch") == true)
            let beforeA = try Data(contentsOf: a), beforeB = try Data(contentsOf: b)
            // Exercise both a normal click and the case where AppKit keeps the outgoing text view as
            // first responder. The focus seam changes only focus; input is real keyboard/clipboard input.
            editor.click()
            focus.click()
            XCTAssertEqual(focus.value as? String, "editable=false focused=true")
            XCTAssertTrue(pollUntil(timeout: 5) { editor.value(forKey: "hasKeyboardFocus") as? Bool == true })
            app.typeText("RejectedDuringSwitch")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("PasteDuringSwitch", forType: .string)
            app.typeKey("v", modifierFlags: .command)
            let heldText = editor.value as? String
            app.menuBars.menuBarItems["Edit"].click()
            let undo = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", "Undo")).firstMatch
            XCTAssertTrue(undo.waitForExistence(timeout: 5))
            XCTAssertFalse(undo.isEnabled, "the old note's Undo must be disabled during loading")
            app.typeKey(.escape, modifierFlags: [])
            app.typeKey("z", modifierFlags: .command)
            XCTAssertEqual(editor.value as? String, heldText, "Undo must not change the held body")
            app.typeKey("z", modifierFlags: [.command, .shift])
            XCTAssertEqual(editor.value as? String, heldText, "Redo must not change the held body")
            let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(png, forType: .png)
            let pasteImage = mainWindow.buttons["an.editor.test.pasteImage"]
            pasteImage.click()
            XCTAssertEqual(pasteImage.value as? String, "declined:disabled")
            let held = XCTAttachment(screenshot: mainWindow.screenshot())
            held.name = "note-switch-load-held"; held.lifetime = .keepAlways
            add(held)
            XCTAssertFalse((editor.value as? String ?? "").contains("RejectedDuringSwitch"))
            XCTAssertFalse((editor.value as? String ?? "").contains("PasteDuringSwitch"))
            XCTAssertTrue((editor.value as? String ?? "").contains("AcceptedBeforeSwitch"))
            XCTAssertEqual(try Data(contentsOf: a), beforeA)
            XCTAssertEqual(try Data(contentsOf: b), beforeB)

            release.click()
            XCTAssertTrue(pollUntil(timeout: 60) { (editor.value as? String)?.contains("large note text") == true })
            let loaded = XCTAttachment(screenshot: mainWindow.screenshot())
            loaded.name = "note-switch-large-body-loaded"; loaded.lifetime = .keepAlways
            add(loaded)
            selectItem(uuid: Self.idPlain)   // flush anything the loading gap might have queued
            XCTAssertTrue(pollUntil(timeout: 15) { (editor.value as? String)?.contains("A plain note") == true })
            XCTAssertEqual(try Data(contentsOf: a), beforeA, "input must not autosave into the outgoing note")
            XCTAssertEqual(try Data(contentsOf: b), beforeB, "input must not clobber the incoming note")
            for id in [Self.idPlain, Self.idReader] {
                let assets = URL(fileURLWithPath: Self.fixturePath).appendingPathComponent("items/\(id)/assets")
                let names = (try? FileManager.default.contentsOfDirectory(atPath: assets.path)) ?? []
                XCTAssertFalse(names.contains { $0.hasPrefix("pasted-") }, "a disabled paste must not write an asset")
            }
            // The gate must reopen: real typing still saves after loading finishes.
            focus.click()
            XCTAssertEqual(focus.value as? String, "editable=true focused=true")
            app.typeText("AcceptedAfterSwitch")
            XCTAssertTrue(pollUntil(timeout: 10) { self.noteBody(uuid: Self.idPlain)?.contains("AcceptedAfterSwitch") == true })
        }
    }

    func testReturningToOutgoingNoteDuringLoadKeepsUndoHistory() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            selectItem(uuid: Self.idPlain)
            let editor = mainWindow.textViews["an.editor.text"]
            XCTAssertTrue(pollUntil(timeout: 15) { (editor.value as? String)?.contains("A plain note") == true })
            let focus = mainWindow.buttons["an.editor.test.focus"]
            focus.click()
            XCTAssertEqual(focus.value as? String, "editable=true focused=true")
            app.typeText("RetainedUndoHistory")
            selectItem(uuid: Self.idReader)
            let release = mainWindow.buttons["an.editor.test.releaseBodyLoad"]
            XCTAssertTrue(pollUntil(timeout: 10) { release.value as? String == "waiting" })
            selectItem(uuid: Self.idPlain)   // cancel B's selection before its load is released
            focus.click()
            XCTAssertEqual(focus.value as? String, "editable=true focused=true")
            app.typeKey("z", modifierFlags: .command)
            XCTAssertFalse((editor.value as? String ?? "").contains("RetainedUndoHistory"))
            app.typeKey("z", modifierFlags: [.command, .shift])
            XCTAssertTrue((editor.value as? String ?? "").contains("RetainedUndoHistory"))
            release.click()
            // The superseded load must not replace A or discard its history when it finally finishes.
            focus.click()
            XCTAssertEqual(focus.value as? String, "editable=true focused=true")
            app.typeKey("z", modifierFlags: .command)
            XCTAssertFalse((editor.value as? String ?? "").contains("RetainedUndoHistory"))
            app.typeKey("z", modifierFlags: [.command, .shift])
            XCTAssertTrue((editor.value as? String ?? "").contains("RetainedUndoHistory"))
        }
    }

}
