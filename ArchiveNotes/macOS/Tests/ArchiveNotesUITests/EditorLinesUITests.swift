import XCTest

/// W40.fix-notes-editor-lines — the owner's steps from Notes guided session 1 (`verification/sessions/notes-1-returned.md`
/// rows 8 and 10), with real keystrokes into the styled editor, in the VM. Row 8: Return would not add more than one
/// blank line and Backspace would not delete a line break, and it came back after the note was deselected and
/// selected again. Row 10: Bulleted List showed nothing.
///
/// The paths (phase rule 8): Return and Backspace at the end of the note and in the middle of it; type, select
/// another note, select this one again, type again; quit and relaunch. Bulleted List from ⇧⌘U, the Format menu and
/// the editor toolbar, on an empty last line, then across a reselect. `EditorLinesStackedUITests` runs it all again
/// with the list above the note. Scratch fixture only (`AN-GUI-Fixture`, restored before every test).
class EditorLinesUITests: NotesFixtureUITestCase {

    var journeyLayout: Layout { .sideBySide }
    override var layoutLaunchArguments: [String] { Self.layoutArguments(journeyLayout) }

    private let original = "A plain note with **bold** text and no source blocks."
    private let shown = "A plain note with bold text and no source blocks."

    /// Row 8: Returns and Backspaces at the end of the note and between lines, kept across a reselect and a relaunch.
    func testReturnAndBackspaceKeepTheirLinesAcrossReselectAndRelaunch() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            let id = Self.idPlain
            try loadNote(id)

            // Three Returns at the end: the second and third land on the empty last line, where they did nothing.
            try typeIntoEditor("\n\n\n")
            XCTAssertTrue(editorText.hasSuffix(shown + "\n\n\n"),
                          "three Returns should make three lines — editor: \(editorText.debugDescription)")
            // Backspace on the empty last line deletes the line break, then Return adds it back.
            app.typeKey(.delete, modifierFlags: [])
            XCTAssertTrue(editorText.hasSuffix(shown + "\n\n"), "Backspace on the empty last line should delete it")
            editor.typeText("\nThird line.")
            XCTAssertTrue(pollUntil(timeout: 10) { (self.noteBody(uuid: id) ?? "").contains("Third line.") }, "the lines should save")
            XCTAssertTrue((noteBody(uuid: id) ?? "").contains(original + "\n\n\\\nThird line."),
                          "two blank lines are a paragraph break and a line break — disk: \(noteBody(uuid: id) ?? "")")

            // Select another note and this one again: the blank lines are still there; type again after the reload.
            reselect(id)
            XCTAssertTrue(editorText.contains(shown + "\n\n\nThird line."),
                          "the blank lines should survive a reselect — editor: \(editorText.debugDescription)")
            try typeIntoEditor("\n\nFourth.")
            XCTAssertTrue(editorText.hasSuffix("Third line.\n\nFourth."))

            // Backspace at the start of "Fourth." deletes the blank line above it, and it stays deleted.
            app.typeKey(.leftArrow, modifierFlags: .command)
            app.typeKey(.delete, modifierFlags: [])
            XCTAssertTrue(editorText.hasSuffix("Third line.\nFourth."), "Backspace should join the blank line away")
            XCTAssertTrue(pollUntil(timeout: 10) { (self.noteBody(uuid: id) ?? "").contains("Third line.\\\nFourth.") },
                          "the deleted blank line should save — disk: \(noteBody(uuid: id) ?? "")")
            reselect(id)
            XCTAssertTrue(editorText.hasSuffix("Third line.\nFourth."),
                          "the deleted blank line must not come back on reselect — editor: \(editorText.debugDescription)")
            // A second Backspace joins the two lines.
            try typeIntoEditor("")
            app.typeKey(.leftArrow, modifierFlags: .command)
            app.typeKey(.delete, modifierFlags: [])
            XCTAssertTrue(editorText.hasSuffix("Third line.Fourth."), "a second Backspace should join the lines")
            editor.typeText(" ")

            // Quit and relaunch: the editor shows the same lines, and opening the note rewrites nothing.
            XCTAssertTrue(pollUntil(timeout: 10) { (self.noteBody(uuid: id) ?? "").contains("Third line. Fourth.") })
            app.typeKey("q", modifierFlags: .command)
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "⌘Q should quit the app")
            let saved = noteBody(uuid: id) ?? ""
            relaunch()
            try loadNote(id)
            XCTAssertTrue(pollUntil(timeout: 10) { self.editorText.contains("Third line. Fourth.") })
            XCTAssertTrue(editorText.contains(shown + "\n\n\nThird line. Fourth."),
                          "relaunched editor: \(editorText.debugDescription)")
            RunLoop.current.run(until: Date().addingTimeInterval(3))
            XCTAssertEqual(noteBody(uuid: id), saved, "opening the note after relaunch must not rewrite it")
            print("[lines] final body: \(saved.debugDescription)")
        }
    }

    /// Row 10: Bulleted List from the shortcut, the menu and the toolbar draws a bullet and writes a list, on an
    /// empty last line, and the list survives a reselect, where Return makes the next item.
    func testBulletedListShowsABulletFromEveryWayIn() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            let id = Self.idPlain
            try loadNote(id)
            XCTAssertEqual(markers(), "", "the note starts with no list")

            // ⇧⌘U on an empty last line: the bullet shows before anything is typed.
            try typeIntoEditor("\n\n")
            app.typeKey("u", modifierFlags: [.command, .shift])
            XCTAssertTrue(pollUntil(timeout: 5) { self.markerCount() == 1 },
                          "⇧⌘U should draw a bullet on the empty line — markers: \(markers())")
            editor.typeText("Via shortcut\nSecond item")
            XCTAssertTrue(pollUntil(timeout: 5) { self.markerCount() == 2 }, "Return should make a second item — \(markers())")

            // Return twice leaves the list; Format ▸ Bulleted List starts one again.
            editor.typeText("\n\n")
            XCTAssertTrue(pollUntil(timeout: 5) { self.markerCount() == 2 }, "Return on an empty item should leave the list")
            app.activate()
            let format = app.menuBars.menuBarItems["Format"]
            XCTAssertTrue(format.waitForExistence(timeout: 5), "the Format menu should exist")
            format.click()
            let item = app.menuItems["Bulleted List"]
            XCTAssertTrue(item.waitForExistence(timeout: 3), "Format ▸ Bulleted List should exist")
            item.click()
            XCTAssertTrue(pollUntil(timeout: 5) { self.markerCount() == 3 }, "the menu should draw a bullet — \(markers())")
            editor.typeText("Via menu\n\n")

            // The toolbar's button.
            let button = mainWindow.descendants(matching: .any)["an.editor.toolbar.bullet"].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 5), "the toolbar should have a Bulleted List button")
            button.click()
            XCTAssertTrue(pollUntil(timeout: 5) { self.markerCount() == 4 }, "the toolbar should draw a bullet — \(markers())")
            // The button must leave the caret where it was: a click into the editor would move it.
            XCTAssertEqual(editor.value(forKey: "hasKeyboardFocus") as? Bool, true,
                           "the toolbar button should leave focus in the editor — focus is on \(keyboardFocusDescription())")
            editor.typeText("Via toolbar")
            XCTAssertTrue(pollUntil(timeout: 10) { (self.noteBody(uuid: id) ?? "").contains("- Via toolbar") },
                          "the list should save — disk: \(noteBody(uuid: id) ?? "")")
            let body = noteBody(uuid: id) ?? ""
            XCTAssertTrue(body.contains(original + "\n\n- Via shortcut\n- Second item\n- Via menu\n- Via toolbar"),
                          "each way in should write a list item — disk: \(body.debugDescription)")
            try saveShot("W40.fix-notes-editor-lines-bullets-\(journeyLayout.rawValue)")

            // Reselect: the bullets are drawn again, and Return at the last item makes the next one.
            reselect(id)
            XCTAssertTrue(pollUntil(timeout: 5) { self.markerCount() == 4 }, "the bullets should be drawn after a reselect — \(markers())")
            XCTAssertTrue(editorText.hasSuffix("Via shortcut\nSecond item\nVia menu\nVia toolbar"),
                          "editor after reselect: \(editorText.debugDescription)")
            try typeIntoEditor("\nAfter reselect")
            XCTAssertTrue(pollUntil(timeout: 5) { self.markerCount() == 5 }, "Return after a reselect should make an item — \(markers())")
            XCTAssertTrue(pollUntil(timeout: 10) { (self.noteBody(uuid: id) ?? "").contains("- Via toolbar\n- After reselect") },
                          "disk: \(noteBody(uuid: id) ?? "")")
        }
    }

    // MARK: - Helpers

    private var editorText: String { (editor.value as? String) ?? "" }

    private var markerProbe: XCUIElement { mainWindow.descendants(matching: .any)["an.editor.test.listMarkers"].firstMatch }
    private func markers() -> String { (markerProbe.value as? String) ?? "" }
    private func markerCount() -> Int { markers().split(separator: " ").count }

    private struct StepError: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    private func loadNote(_ id: String) throws {
        assertLayout(journeyLayout, in: mainWindow)
        selectItem(uuid: id)
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "the editor should exist")
        XCTAssertTrue(pollUntil(timeout: 10) { self.editorText.contains("A plain note") }, "the plain note's body should load")
    }

    /// Select another note, then this one again: the editor reloads the body from the saved Markdown.
    private func reselect(_ id: String) {
        selectItem(uuid: Self.idReader)
        XCTAssertTrue(pollUntil(timeout: 10) { !self.editorText.contains("A plain note") }, "another note should load")
        selectItem(uuid: id)
        XCTAssertTrue(pollUntil(timeout: 10) { self.editorText.contains("A plain note") }, "the note should load again")
    }

    /// Click the styled editor until it holds keyboard focus, caret to the end (⌘↓), then type.
    private func typeIntoEditor(_ text: String) throws {
        func focused() -> Bool { (editor.value(forKey: "hasKeyboardFocus") as? Bool) == true }
        for _ in 0..<4 where !focused() {
            app.activate()
            editor.click()
            _ = pollUntil(timeout: 2, focused)
        }
        guard focused() else {
            throw StepError("the styled editor never took keyboard focus — focus is on \(keyboardFocusDescription())")
        }
        app.typeKey(.downArrow, modifierFlags: .command)
        if !text.isEmpty { editor.typeText(text) }
    }

    private func relaunch() {
        if app.state != .notRunning { app.terminate() }
        app.launch()
        app.activate()
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 15), "the window should come back after relaunch")
        let seed = mainWindow.descendants(matching: .any)["an.cell.title.\(Self.idPlain)"]
        XCTAssertTrue(seed.waitForExistence(timeout: 25), "the list should repopulate after relaunch")
    }

    private func saveShot(_ name: String) throws {
        let shot = mainWindow.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".png")
        try shot.pngRepresentation.write(to: path)
        print("[shot] \(name): wrote \(path.path)")
    }
}

/// The same steps with the list above the note (W48.notes-stacked-layout): the toolbar and editor sit elsewhere.
final class EditorLinesStackedUITests: EditorLinesUITests {
    override var journeyLayout: Layout { .stacked }
}
