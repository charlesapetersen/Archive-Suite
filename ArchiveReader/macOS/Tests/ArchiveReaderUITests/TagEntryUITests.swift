import XCTest
import Darwin

/// W40.fix-reader-tag-entry (owner session reader-1, rows 28, 29 and 36), on the scratch fixture.
///
/// 1. The list's tag field keeps the keyboard after Return, so a second tag is typed without a click.
/// 2. A space typed into an autocompletion keeps what was typed: "W40te Al" + " Two" is the tag "W40te Al Two",
///    even though "W40te Alpha Beta" was being suggested.
/// 3. Edit Info… autocompletes: "W40te Gam" + Tab adds "W40te Gamma". Return adds a typed subject and leaves the
///    sheet open with the keyboard in the field, so the next one is typed without a click; a subject still typed
///    when Done is clicked is added too.
///
/// Tags are read from disk with fresh `getxattr` calls; teardown puts back every tag xattr it found.
final class TagEntryUITests: FixtureUITestCase {
    private static let tagXattr = "com.apple.metadata:_kMDItemUserTags"
    private var root: URL { URL(fileURLWithPath: Self.fixturePath, isDirectory: true) }
    private var baseline: [String: Data?] = [:]

    override func setUp() async throws {
        try await super.setUp()
        try requireGeneratedScratchFixtureForTagWrites()
        baseline = tagSnapshot()
        continueAfterFailure = true   // report every step; teardown restores the tags either way
    }

    override func tearDown() async throws {
        if app != nil, app.state == .runningForeground {
            restoreMinimumWindowSize()
            app.activate()
            app.typeKey("q", modifierFlags: .command)   // a real quit saves the window frame
            if !waitFor(timeout: 15, { self.app.state == .notRunning }) { app.terminate() }
        }
        app?.terminate()
        guard !baseline.isEmpty else { return try await super.tearDown() }   // setup failed before any write
        for (path, bytes) in baseline where tagSnapshot()[path] != bytes {
            if let bytes {
                _ = bytes.withUnsafeBytes { setxattr(path, Self.tagXattr, $0.baseAddress, bytes.count, 0, XATTR_NOFOLLOW) }
            } else {
                _ = removexattr(path, Self.tagXattr, XATTR_NOFOLLOW)
            }
        }
        XCTAssertEqual(tagSnapshot(), baseline, "teardown should leave the fixture's tags as it found them")
        try await super.tearDown()
    }

    func testTagEntryKeepsFocusAndASpaceEndsACompletion() throws {
        XCTAssertTrue(table.waitForExistence(timeout: 10))
        waitForRows(minimum: 2, timeout: 15)
        zoomMainWindow()

        // (1) Two tags in a row in the list's tag field, with no click between them.
        guard let (name, path) = rowFile(0) else { return XCTFail("row 0 should expose its tag field") }
        clickRow(0)
        XCTAssertTrue(focusInlineEditor(name: name), "a click in the selected row's Tags cell should start editing it")
        app.typeKey(.rightArrow, modifierFlags: .command)
        typeSlowly("W40te Alpha Beta")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitFor { self.tags(path).contains("W40te Alpha Beta") }, "Return should write the first tag")
        settle(0.8)
        let field = app.descendants(matching: .any)["ar.cell.tags.\(name)"]
        let kept = hasFocus(field)
        log("[tag-entry] after Return the field kept the keyboard: \(kept ? "yes" : "NO")")
        XCTAssertTrue(kept, "row 29: the list's tag field should keep the keyboard after a tag is added")
        typeSlowly("W40te Gamma")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitFor { self.tags(path).contains("W40te Gamma") },
                      "row 29: a second tag typed straight after the first should be written; tags \(tags(path))")

        // (2) A space ends a completion: "W40te Al" is being completed to "W40te Alpha Beta".
        typeSlowly("W40te Al")
        settle(1.0)
        captureScreenshot("w40-tag-entry-completion")
        typeSlowly(" Two")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitFor { self.tags(path).contains("W40te Al Two") },
                      "row 36: a space should keep what was typed, not the suggestion; tags \(tags(path))")
        log("[tag-entry] inline tags now \(tags(path).filter { $0.hasPrefix("W40te") })")
        XCTAssertEqual(tags(path).filter { $0.hasPrefix("W40te") }.sorted(),
                       ["W40te Al Two", "W40te Alpha Beta", "W40te Gamma"], "the list field should write exactly the typed tags")

        // (3) Edit Info… on another file: Tab takes the suggestion, Return adds it and keeps the sheet open.
        guard let (_, otherPath) = rowFile(1) else { return XCTFail("row 1 should expose its tag field") }
        clickRow(1)
        pressKey("i", modifiers: .command)
        let add = app.textFields["ar.tagEditor.addSubject"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "⌘I should present the tag editor")
        add.click()
        typeSlowly("W40te Gam")
        settle(1.0)
        captureScreenshot("w40-tag-entry-editor-completion")
        app.typeKey(.tab, modifierFlags: [])
        settle(0.5)
        captureScreenshot("w40-tag-entry-editor-tab")
        XCTAssertTrue(waitFor { self.tags(otherPath).contains("W40te Gamma") },
                      "row 28: Edit Info should autocomplete, and Tab take the suggestion; tags \(tags(otherPath))")
        XCTAssertFalse(tags(otherPath).contains("W40te Gam"), "Tab should take the whole suggestion")
        log("[tag-entry] editor field after Tab: \(String(describing: add.value))")

        // Return adds what is typed and keeps the sheet open, with the field ready for the next subject.
        add.click()
        typeSlowly("W40te Delta")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitFor { self.tags(otherPath).contains("W40te Delta") }, "Return should add the subject; tags \(tags(otherPath))")
        settle(0.5)
        captureScreenshot("w40-tag-entry-editor-return")
        XCTAssertTrue(app.buttons["ar.tagEditor.done"].exists, "Return in the subject field should not close the sheet")
        log("[tag-entry] editor field after Return: \(String(describing: add.value)), sheet open \(app.buttons["ar.tagEditor.done"].exists)")
        typeSlowly("W40te Epsilon")
        log("[tag-entry] editor field before Done: \(String(describing: add.value))")
        app.buttons["ar.tagEditor.done"].click()
        XCTAssertTrue(waitFor { self.tags(otherPath).contains("W40te Epsilon") },
                      "a subject still typed when Done is clicked is added, as the list's field keeps typed text")
        XCTAssertTrue(waitFor { !self.app.buttons["ar.tagEditor.done"].exists }, "Done should close the sheet")
        log("[tag-entry] editor tags now \(tags(otherPath).filter { $0.hasPrefix("W40te") })")
        XCTAssertEqual(tags(otherPath).filter { $0.hasPrefix("W40te") }.sorted(),
                       ["W40te Delta", "W40te Epsilon", "W40te Gamma"], "Edit Info should add exactly the subjects entered")
    }

    // MARK: helpers

    /// The file shown in `row`, by its tag field's identifier, and its path in the fixture.
    private func rowFile(_ row: Int) -> (name: String, path: String)? {
        let field = table.tableRows.element(boundBy: row).descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "ar.cell.tags.")).firstMatch
        guard field.waitForExistence(timeout: 5) else { return nil }
        let name = String(field.identifier.dropFirst("ar.cell.tags.".count))
        let matches = tagSnapshot().keys.filter { ($0 as NSString).lastPathComponent == name }
        XCTAssertEqual(matches.count, 1, "precondition: one fixture file is named \(name)")
        return matches.first.map { (name, $0) }
    }

    /// A click in a SELECTED row's tag field, at its empty right end, starts editing it; it must come after the
    /// double-click interval, or the table reads the two clicks as a double-click (as `TriageJourneyUITests`).
    private func focusInlineEditor(name: String) -> Bool {
        let field = app.descendants(matching: .any)["ar.cell.tags.\(name)"]
        for _ in 0..<3 {
            settle(1.2)
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).click()
            if waitFor(timeout: 2, { self.hasFocus(field) }) { return true }
        }
        return false
    }

    private func hasFocus(_ element: XCUIElement) -> Bool {
        (element.value(forKey: "hasKeyboardFocus") as? Bool) == true
            || element.descendants(matching: .any).matching(NSPredicate(format: "hasKeyboardFocus == true")).count > 0
    }

    /// One character at a time, at a human pace, so the token field's completion sees what typing gives it.
    private func typeSlowly(_ text: String) {
        for ch in text {
            app.typeText(String(ch))
            settle(0.12)
        }
    }

    /// The window opens at about 900 pt wide, which can clip the Tags column; zoom it (teardown shrinks it back).
    private func zoomMainWindow() {
        let window = app.windows["Archive Reader"]
        let before = window.frame.width
        app.menuBars.menuBarItems["Window"].click()
        let zoom = app.menuItems["Zoom"]
        if zoom.waitForExistence(timeout: 3) { zoom.click() } else { app.typeKey(.escape, modifierFlags: []) }
        _ = waitFor(timeout: 3) { window.frame.width > before }
    }

    /// The window frame persists, and the layout guard is written against the default 900×612 window, so shrink
    /// it back: drag the bottom-right corner onto the top-left, and the window clamps at its minimum.
    private func restoreMinimumWindowSize() {
        let window = app.windows["Archive Reader"]
        guard window.exists else { return }
        let before = window.frame.size
        app.activate()
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -3, dy: -3))
        corner.press(forDuration: 0.3, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)))
        _ = waitFor(timeout: 3) { window.frame.width < before.width }
    }

    /// Every fixture file's raw tag xattr, keyed by path; nil where a file has none.
    private func tagSnapshot() -> [String: Data?] {
        var out: [String: Data?] = [:]
        let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = walk?.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "pdf" else { continue }
            out[url.path] = Self.xattr(url.path)
        }
        XCTAssertFalse(out.isEmpty, "precondition: the fixture has PDFs to watch")
        return out
    }

    private static func xattr(_ path: String) -> Data? {
        let size = getxattr(path, tagXattr, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, tagXattr, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        return read == size ? data : nil
    }

    /// The tag names on `path`, colour suffixes dropped, read fresh from disk.
    private func tags(_ path: String) -> [String] {
        guard let data = Self.xattr(path),
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else { return [] }
        return list.map { $0.components(separatedBy: "\n")[0] }
    }

    private func waitFor(timeout: TimeInterval = 8, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            settle(0.3)
        }
        return condition()
    }

    private func log(_ line: String) { print(line) }

    private func settle(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
}
