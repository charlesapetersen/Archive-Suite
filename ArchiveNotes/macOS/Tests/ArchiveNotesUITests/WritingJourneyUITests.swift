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
final class WritingJourneyUITests: NotesFixtureUITestCase {

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
            let paragraphs = XCTExpectedFailure.Options(); paragraphs.isStrict = false
            XCTExpectFailure("W40.fix-notes-return-paragraph (S2): a Return typed in the styled editor is saved as one "
                             + "newline, so the typed paragraphs merge into one when the note is reopened",
                             options: paragraphs) {
                XCTAssertTrue(editorText.contains("no source blocks.\n\(first)\n\(second)"),
                              "N-12: each Return typed should come back as its own paragraph after relaunch")
            }
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
            let known = XCTExpectedFailure.Options(); known.isStrict = false
            XCTExpectFailure("W40.fix-notes-outside-edit-overwrite (S1): the next save writes the editor's older "
                             + "copy over an edit made to the .md outside the app", options: known) {
                XCTAssertTrue(survived || warned,
                              "N-02: an edit made outside the app must not be overwritten without a word")
            }
        }
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
            let known = XCTExpectedFailure.Options(); known.isStrict = false
            XCTExpectFailure("W40.fix-notes-asset-write-silent (S3): a failed image write is only logged; the note "
                             + "keeps a reference to a file that was never written", options: known) {
                XCTAssertTrue(status != nil || app.alerts.count > 0 || app.sheets.count > 0,
                              "N-15: a pasted image that could not be stored must be reported to the user")
            }
        }
    }

    // MARK: - Helpers

    private var editorText: String { (editor.value as? String) ?? "" }

    private func log(_ line: String) { print(line); NSLog("%@", line) }

    private func loadNote(_ id: String) throws {
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
        let el = mainWindow.descendants(matching: .any)["an.sidebar.status"]
        guard el.exists else { return nil }
        let texts = el.staticTexts.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }
        return texts.isEmpty ? el.label : texts.joined(separator: " ")
    }
}
