import XCTest
import AppKit   // NSPasteboard — seed PNG bytes for the forced asset-write failure
import Darwin   // getxattr / chmod — read the note's Finder-tag xattr, lock the assets folder

/// W40.d9 — a Notes writing session with real keystrokes, in the VM (`verification/evidence/notes/W40.d9-writing.md`).
///
/// Written from the promises (ledger rows N-02, N-12, N-14, N-15) before the code was read, per the phase rules:
/// typing saves itself; quitting within the autosave delay still saves; a relaunch shows exactly what is on disk
/// and rewrites nothing; closing the window saves; an edit made to the note's `.md` outside the app is not
/// silently overwritten; a pasted image that cannot be stored is not lost without a word.
///
/// Unlike the rest of the bundle, the typing here goes through `typeText` into the styled editor itself, not the
/// `an.editor.test.*` seams. The one seam used is `pasteImage`, because ⌘V needs the text view as first responder
/// and the point of that check is the write failure, not the gesture.
///
/// Scratch fixture only (`AN-GUI-Fixture`, restored from its pristine copy before every test).
class WritingJourneyUITests: NotesFixtureUITestCase {

    /// The layout the journey runs in; `WritingJourneyStackedUITests` runs it again with the list above the note
    /// (W48.notes-stacked-layout).
    var journeyLayout: Layout { .sideBySide }
    override var layoutLaunchArguments: [String] { Self.layoutArguments(journeyLayout) }

    /// N-12/N-14/N-02 — type, autosave, ⌘Q within the debounce, relaunch: the file holds every keystroke, the
    /// relaunched editor shows it, and the relaunch itself writes nothing.
    func testTypingAutosavesAndSurvivesQuitWithinDebounceAndRelaunch() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            let id = Self.idPlain
            try loadNote(id)
            let before = try noteFile(id)
            let tagsBefore = finderTags(id)
            log("[d9] start: \(before.data.count) bytes, front matter \(frontMatter(before.text).count) lines")

            // 1. Real keystrokes, then hands off: the idle autosave must write them.
            let first = "Typed by hand in the W40.d9 journey."
            try typeIntoEditor("\n" + first)
            let t0 = Date()
            XCTAssertTrue(pollUntil(timeout: 10) { self.bodyLines(id).contains(first) },
                          "N-14: typing should autosave without any other action")
            log("[d9] step 1 autosave: on disk after \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
            let afterType = try noteFile(id)
            assertBodyKeepsOriginalThenAdds(before: before.text, after: afterType.text, added: [first], step: "1")
            assertFrontMatterUnchangedButModified(before.text, afterType.text, step: "1")

            // 2. Type again and quit at once with ⌘Q — inside both debounces (editor ~400 ms + save 600 ms).
            let second = "Quit straight after typing this."
            try typeIntoEditor("\n" + second)
            app.typeKey("q", modifierFlags: .command)
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "⌘Q should quit the app")
            let afterQuit = try noteFile(id)
            XCTAssertTrue(bodyLines(id).contains(second),
                          "N-14: an edit typed within the autosave delay must be saved on ⌘Q")
            assertBodyKeepsOriginalThenAdds(before: before.text, after: afterQuit.text, added: [first, second], step: "2")
            log("[d9] step 2 ⌘Q within debounce: second line on disk = \(bodyLines(id).contains(second))")

            // 3. Relaunch: the editor shows what is on disk, and opening the note rewrites nothing.
            relaunch()
            try loadNote(id)
            XCTAssertTrue(pollUntil(timeout: 10) { self.editorText.contains(second) && self.editorText.contains(first) },
                          "the relaunched editor should show both typed lines")
            log("[d9] step 3 relaunched editor text: \(editorText.debugDescription)")
            // W40.fix-notes-return-paragraph: each typed Return is written as a paragraph break, so the editor
            // shows the Styler's blank-line separator between the paragraphs it reads back.
            XCTAssertTrue((noteBody(uuid: id) ?? "").contains("no source blocks.\n\n\(first)\n\n\(second)"),
                          "N-12: each Return typed should be saved as a paragraph break")
            XCTAssertTrue(editorText.contains("no source blocks.\n\n\(first)\n\n\(second)"),
                          "N-12: each Return typed should come back as its own paragraph after relaunch")
            RunLoop.current.run(until: Date().addingTimeInterval(3))   // past both debounces
            let afterRelaunch = try noteFile(id)
            XCTAssertEqual(afterRelaunch.data, afterQuit.data, "N-02: opening a note after relaunch must not rewrite it")
            XCTAssertEqual(afterRelaunch.mtime, afterQuit.mtime, "N-02: opening a note after relaunch must not touch it")
            XCTAssertEqual(finderTags(id), tagsBefore, "N-04: typing must leave the note's Finder tags byte-identical")
            log("[d9] step 3 relaunch: bytes identical = \(afterRelaunch.data == afterQuit.data), "
                + "mtime identical = \(afterRelaunch.mtime == afterQuit.mtime), tags identical = \(finderTags(id) == tagsBefore)")
            log("[d9] final body:\n\(noteBody(uuid: id) ?? "<unreadable>")")
        }
    }

    /// N-14 — closing the window straight after typing saves the edit (the pane's `onDisappear` flush).
    func testClosingTheWindowStraightAfterTypingSaves() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            let id = Self.idPlain
            try loadNote(id)
            let before = try noteFile(id)
            let line = "Window closed straight after this."
            try typeIntoEditor("\n" + line)
            let close = mainWindow.buttons[XCUIIdentifierCloseWindow]
            XCTAssertTrue(close.waitForExistence(timeout: 5), "the main window should have a close button")
            close.click()
            XCTAssertTrue(pollUntil(timeout: 10) { self.bodyLines(id).contains(line) },
                          "N-14: closing the window within the autosave delay must save the edit")
            let after = try noteFile(id)
            assertBodyKeepsOriginalThenAdds(before: before.text, after: after.text, added: [line], step: "close")
            log("[d9] window close: line on disk = \(bodyLines(id).contains(line)); app state after close = "
                + "\(app.state == .notRunning ? "quit" : "running")")
        }
    }

    /// N-02/N-14 — the note's `.md` is a plain file the user may edit elsewhere. An edit made outside while the
    /// note is open must not be silently replaced by the editor's older copy on the next save.
    func testEditOutsideTheAppWhileOpenIsNotSilentlyOverwritten() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            let id = Self.idPlain
            try loadNote(id)
            let before = try noteFile(id)

            // Edit the file the way another editor would: same file, in place (keeps its xattrs).
            let outside = "Written outside the app while the note was open."
            let edited = before.text.hasSuffix("\n") ? before.text + "\n" + outside + "\n" : before.text + "\n\n" + outside + "\n"
            try Data(edited.utf8).write(to: before.url)
            XCTAssertTrue(bodyLines(id).contains(outside), "precondition: the outside edit is on disk")
            RunLoop.current.run(until: Date().addingTimeInterval(3))
            let editorSawIt = editorText.contains(outside)
            log("[d9] outside edit: editor reloaded it within 3 s = \(editorSawIt)")

            // Now type in the app and let it save.
            let typed = "Typed after the outside edit."
            try typeIntoEditor("\n" + typed)
            XCTAssertTrue(pollUntil(timeout: 10) { self.bodyLines(id).contains(typed) }, "the typed line should autosave")
            let survived = bodyLines(id).contains(outside)
            let status = statusLine()
            log("[d9] outside edit after the app's save: on disk = \(survived); status line = \(status ?? "none"); "
                + "alerts = \(app.alerts.count), sheets = \(app.sheets.count)")
            if !survived { log("[d9] body after the save:\n\(noteBody(uuid: id) ?? "<unreadable>")") }
            let warned = status != nil || app.alerts.count > 0 || app.sheets.count > 0
            XCTAssertTrue(editorSawIt, "a clean editor must reload the outside paragraph")
            XCTAssertTrue(survived, "N-02: the outside paragraph must survive the next autosave")
            XCTAssertTrue(warned, "N-02: an outside change must be reported to the user")
            let shot = XCTAttachment(screenshot: mainWindow.screenshot())
            shot.name = "W40-outside-edit-reloaded"; shot.lifetime = .keepAlways
            add(shot)
            try saveOutsideEditShot("W40-outside-edit-reloaded", screenshot: mainWindow.screenshot())
        }
    }

    /// No clean-reload grace period: preserve a still-dirty draft separately. XCUITest's event delivery
    /// may let autosave finish first; in that ordering append to its fresh bytes and require both lines.
    /// OutsideEditTests deterministically exercises the dirty branch without automation delays.
    func testOutsideEditWithDirtyDraftKeepsBothVersions() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            let id = Self.idPlain
            try loadNote(id)
            let draft = "Localdrafttoken"
            try typeIntoEditor("\n" + draft)
            let externalBase = try noteFile(id)
            let outside = "Externalconflicttoken"
            let edited = externalBase.text + "\n\n" + outside + "\n"
            try Data(edited.utf8).write(to: externalBase.url)
            @MainActor func recovered() -> Bool {
                recoveredDraftFiles().contains { (try? String(contentsOf: $0, encoding: .utf8))?.contains(draft) == true }
            }
            XCTAssertTrue(pollUntil(timeout: 15) { self.bodyLines(id).contains(draft) || recovered() },
                          "the in-app text must be durable in the original or a separate recovered draft")
            XCTAssertTrue(bodyLines(id).contains(outside), "the outside paragraph must survive")
            if recovered() {
                XCTAssertEqual(try Data(contentsOf: externalBase.url), Data(edited.utf8), "a conflict must leave the original byte-identical")
            }
            XCTAssertTrue(pollUntil(timeout: 10) { self.editorText.contains(outside) }, "the original must reload")
            XCTAssertNotNil(statusLine(), "the outside change must be reported")
            let shot = XCTAttachment(screenshot: mainWindow.screenshot())
            shot.name = "W40-outside-edit-recovered-draft"; shot.lifetime = .keepAlways
            add(shot)
            try saveOutsideEditShot("W40-outside-edit-recovered-draft", screenshot: mainWindow.screenshot())
            log("[W40-outside] separate recovery draft = \(recovered()); status = \(statusLine() ?? "none")")
            relaunch()
            XCTAssertTrue(bodyLines(id).contains(draft) || recovered(), "the in-app text must survive relaunch")
            XCTAssertTrue(bodyLines(id).contains(outside), "the outside paragraph must remain after relaunch")
        }
    }

    /// W40.fix-notes-failed-save-close — the store refuses the write, the window closes: the draft is copied,
    /// a Retry is offered, and once writes work again Retry saves every typed line.
    func testFailedSaveThenCloseKeepsDraftAndRetries() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            let id = Self.idPlain
            try loadNote(id)
            let before = try noteFile(id)
            let dir = itemsDir + "/" + id
            XCTAssertEqual(chmod(dir, 0o555), 0, "should make the scratch note folder read-only")
            defer { _ = chmod(dir, 0o755) }
            let line = "Failedsavecloseline"
            try typeIntoEditor("\n" + line)
            RunLoop.current.run(until: Date().addingTimeInterval(2))   // the autosave is refused
            XCTAssertEqual(try Data(contentsOf: before.url), before.data, "precondition: the write was refused")
            mainWindow.buttons[XCUIIdentifierCloseWindow].click()

            let retry = app.buttons["Retry"].firstMatch
            XCTAssertTrue(retry.waitForExistence(timeout: 10), "a refused save on close must offer a Retry")
            XCTAssertTrue(pollUntil(timeout: 5) { self.unsavedDraftCopies().contains { $0.contains(line) } },
                          "the closed editor's draft must be copied outside the store")
            try saveOutsideEditShot("W40-failed-save-close-alert", screenshot: XCUIScreen.main.screenshot())
            XCTAssertEqual(chmod(dir, 0o755), 0)
            retry.click()
            XCTAssertTrue(pollUntil(timeout: 10) { self.bodyLines(id).contains(line) },
                          "Retry must save the draft once writes work again")
            XCTAssertTrue(pollUntil(timeout: 5) { !self.unsavedDraftCopies().contains { $0.contains(line) } },
                          "the copy is removed once the draft is saved")
            log("[W40-failed-close] saved after retry = \(bodyLines(id).contains(line))")
        }
    }

    /// W40.fix-notes-failed-save-close — ⌘Q while the store refuses the write is stopped behind an alert;
    /// Don't Quit keeps the app and the draft; after writes work again, Retry saves and quits.
    func testFailedSaveBlocksQuitUntilRetrySaves() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            let id = Self.idPlain
            try loadNote(id)
            let dir = itemsDir + "/" + id
            XCTAssertEqual(chmod(dir, 0o555), 0, "should make the scratch note folder read-only")
            defer { _ = chmod(dir, 0o755) }
            let line = "Failedsavequitline"
            try typeIntoEditor("\n" + line)
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            app.typeKey("q", modifierFlags: .command)

            let dontQuit = app.buttons["Don't Quit"].firstMatch
            XCTAssertTrue(dontQuit.waitForExistence(timeout: 10), "a refused save must stop quit with an alert")
            try saveOutsideEditShot("W40-failed-save-quit-alert", screenshot: XCUIScreen.main.screenshot())
            XCTAssertTrue(unsavedDraftCopies().contains { $0.contains(line) }, "the draft is copied before asking")
            dontQuit.click()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            XCTAssertNotEqual(app.state, .notRunning, "Don't Quit must keep the app running")
            XCTAssertTrue(editorText.contains(line), "the draft stays in the editor")

            XCTAssertEqual(chmod(dir, 0o755), 0)
            app.typeKey("q", modifierFlags: .command)
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "once the save succeeds, quit proceeds")
            XCTAssertTrue(bodyLines(id).contains(line), "every typed line is on disk after the quit")
            log("[W40-failed-quit] saved at quit = \(bodyLines(id).contains(line))")
        }
    }

    /// The text of every emergency copy the app wrote beside the scratch store.
    private func unsavedDraftCopies() -> [String] {
        let dir = URL(fileURLWithPath: Self.fixturePath + " Unsaved Drafts")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    private func saveOutsideEditShot(_ name: String, screenshot: XCUIScreenshot) throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".png")
        try screenshot.pngRepresentation.write(to: path)
        print("[shot] \(name): wrote \(path.path)")
    }

    private func recoveredDraftFiles() -> [URL] {
        let root = URL(fileURLWithPath: itemsDir)
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .filter { $0.pathExtension == "md" && $0.lastPathComponent.contains("Recovered draft") }
    }

    /// N-15 — a pasted image whose bytes cannot be written. The note then carries a reference to a file that
    /// does not exist; the user must be told (`ArchiveNotes/KNOWN_ISSUES.md` records it as logged, never shown).
    func testFailedImageWriteIsReportedToTheUser() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            let id = Self.idPlain
            try loadNote(id)
            if editorText.contains("**bold**") {   // raw mode: switch to styled, as G4 does
                rawToggle.click()
                _ = pollUntil(timeout: 5) { !self.editorText.contains("**bold**") }
            }

            // Force the write to fail: an assets folder the app cannot write into.
            let assets = itemsDir + "/" + id + "/assets"
            try FileManager.default.createDirectory(atPath: assets, withIntermediateDirectories: true)
            XCTAssertEqual(chmod(assets, 0o555), 0, "should make the scratch assets folder read-only")
            defer { _ = chmod(assets, 0o755) }
            let assetsBefore = Set(assetFiles(inItemDir: id))

            guard let png = Self.makePNGData() else { return XCTFail("should build PNG bytes") }
            NSPasteboard.general.clearContents()
            XCTAssertTrue(NSPasteboard.general.setData(png, forType: .png), "should seed the pasteboard")
            XCTAssertTrue(pasteImageViaSeam(), "the image-paste seam should be drivable")
            let outcome = pasteImageOutcome()
            log("[d9] forced asset failure: paste outcome = \(outcome)")
            XCTAssertTrue(outcome.hasPrefix("ok "), "the paste itself should be handled — got \(outcome)")

            XCTAssertTrue(pollUntil(timeout: 10) { (self.rawMarkdown(inItemDir: id) ?? "").contains("](assets/pasted-") },
                          "the note should gain the image reference")
            RunLoop.current.run(until: Date().addingTimeInterval(3))
            let landed = Set(assetFiles(inItemDir: id)).subtracting(assetsBefore)
            XCTAssertTrue(landed.isEmpty, "precondition: the forced failure should stop the bytes landing — found \(landed)")
            let status = statusLine()
            log("[d9] forced asset failure: asset files landed = \(landed.count); status line = \(status ?? "none"); "
                + "alerts = \(app.alerts.count), sheets = \(app.sheets.count)")
            XCTAssertTrue(status?.contains("Couldn't store the pasted image") == true,
                          "N-15: a pasted image that could not be stored must be reported to the user — got \(status ?? "none")")
        }
    }

    // MARK: - Helpers

    private var editorText: String { (editor.value as? String) ?? "" }

    private func log(_ line: String) { print(line); NSLog("%@", line) }

    private func loadNote(_ id: String) throws {
        assertLayout(journeyLayout, in: mainWindow)
        selectItem(uuid: id)
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "the editor should exist")
        XCTAssertTrue(pollUntil(timeout: 10) { self.editorText.contains("A plain note") },
                      "the plain note's body should load")
    }

    private struct StepError: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    /// Real keystrokes into the styled editor: click it until it holds keyboard focus, caret to the end
    /// (⌘↓), then `typeText`. Fails loudly, naming where focus is, if the text view never takes focus.
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
        editor.typeText(text)
    }

    private func relaunch() {
        if app.state != .notRunning { app.terminate() }
        app.launch()
        app.activate()
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 15), "the window should come back after relaunch")
        let seed = mainWindow.descendants(matching: .any)["an.cell.title.\(Self.idPlain)"]
        XCTAssertTrue(seed.waitForExistence(timeout: 25), "the list should repopulate after relaunch")
    }

    private struct NoteFile { let url: URL; let data: Data; let text: String; let mtime: Date? }

    private func noteFile(_ id: String) throws -> NoteFile {
        let dir = itemsDir + "/" + id
        guard let md = mdFiles(inItemDir: id).first else { throw StepError("no .md in \(dir)") }
        let url = URL(fileURLWithPath: dir + "/" + md)
        let data = try Data(contentsOf: url)
        var st = stat()
        let mtime: Date? = stat(url.path, &st) == 0
            ? Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
            : nil
        return NoteFile(url: url, data: data, text: String(decoding: data, as: UTF8.self), mtime: mtime)
    }

    private func bodyLines(_ id: String) -> [String] {
        (noteBody(uuid: id) ?? "").components(separatedBy: "\n")
    }

    private func frontMatter(_ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") else { return [] }
        return Array(lines[1..<close])
    }

    private func body(_ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") else { return lines }
        return Array(lines[(close + 1)...])
    }

    /// Every original non-blank body line is still there, in order and unaltered, and the added lines follow
    /// them, each as a whole line of its own.
    private func assertBodyKeepsOriginalThenAdds(before: String, after: String, added: [String], step: String) {
        let old = body(before).filter { !$0.isEmpty }
        let new = body(after).filter { !$0.isEmpty }
        XCTAssertEqual(new, old + added, "[\(step)] the body should be the original lines followed by the typed ones")
    }

    private func assertFrontMatterUnchangedButModified(_ before: String, _ after: String, step: String) {
        let strip: ([String]) -> [String] = { $0.filter { !$0.hasPrefix("modified:") } }
        XCTAssertEqual(strip(frontMatter(after)), strip(frontMatter(before)),
                       "[\(step)] typing must change no front-matter line but `modified:`")
    }

    /// The note file's Finder-tag xattr, raw bytes (nil if it has none).
    private func finderTags(_ id: String) -> Data? {
        guard let file = try? noteFile(id) else { return nil }
        let name = "com.apple.metadata:_kMDItemUserTags"
        let size = getxattr(file.url.path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard getxattr(file.url.path, name, &buf, size, 0, 0) == size else { return nil }
        return Data(buf)
    }

    /// The sidebar's status line (`NotesModel.statusMessage`), if one is showing.
    private func statusLine() -> String? {
        // SwiftUI propagates the container's identifier to both its icon and text. Select only
        // static text so a real notice cannot make this query ambiguous (the old baseline had none).
        let texts = mainWindow.staticTexts.matching(identifier: "an.sidebar.status")
            .allElementsBoundByIndex.map { ($0.value as? String) ?? $0.label }.filter { !$0.isEmpty }
        return texts.isEmpty ? nil : texts.joined(separator: " ")
    }
}

/// W48.notes-stacked-layout — the whole W40.d9 writing journey once more, with the list above the note.
final class WritingJourneyStackedUITests: WritingJourneyUITests {
    override var journeyLayout: Layout { .stacked }
}
