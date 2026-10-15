import XCTest
import CryptoKit
import Darwin

/// W40.d8 — the Reader triage-writes journey: every write a user makes while triaging, checked on disk
/// after each step, then a quit and relaunch.
///
/// Steps: Mark Read & Next (⌘⇧M), the inline subject editor in a row, a group edit in the ⌘I sheet, a
/// rename across files, two undos (⌘Z), a merge from Find Similar Tags, a smart folder, quit, relaunch.
///
/// After every step the whole root is snapshotted: each file's Finder-tag xattr decoded with its colour
/// suffixes (`"Red\n6"`; `URLResourceValues.tagNames` strips colours, so this reads the raw xattr), every
/// other xattr by hash, and every file's content hash. A step must change exactly the files and tags it
/// names. Every other tag, every colour and every byte of content must survive.
///
/// DATA-DRIVEN, so one test serves two roots, both written to the generated fixture path (the only
/// path the runner's sandbox may write, and the one `requireGeneratedScratchFixtureForTagWrites`
/// accepts):
///   * the synthetic GUI fixture, in the ordinary VM lane and the health gate;
///   * two folders of the W40.c2 real-corpus sample copied onto the guest disk
///     (`READER_JOURNEY=rehearsal ops/gui/vm-gui-runner.sh reader xcuitest`, built by
///     `scripts/make-journey-fixture.sh`). The copy is a copy of a copy; the corpus is never reachable.
/// Targets are picked from what is on disk, never hard-coded names.
///
/// The test restores every tag xattr it changed, and deletes its smart folder, so the classes that run
/// after it see the fixture they were written against.
///
/// Evidence: every step prints `[d8] …` lines into the runner's `xcuitest.log`. Files are named by alias
/// (`f07`); `[d8-alias]` lines map aliases to paths and stay in the uncommitted log.
final class TriageJourneyUITests: FixtureUITestCase {

    private static let tagXattr = "com.apple.metadata:_kMDItemUserTags"
    /// One word: a space typed into the inline editor opens the Preview sheet (`W40.fix-reader-inline-keys`,
    /// reproduced by step 9), so a two-word tag cannot be typed there yet.
    private let inlineTag = "W40d8-Inline"
    private let groupTag = "W40d8 Group"
    private let renamedTag = "W40d8 Renamed"
    private let mergeKeep = "W40d8 Merge"
    private let mergeVariant = "w40d8 merge"

    private var root: URL { URL(fileURLWithPath: Self.fixturePath, isDirectory: true) }
    private var baseline: [String: FileState] = [:]
    private var alias: [String: String] = [:]
    private var smartFolderName: String?

    override func setUp() async throws {
        try await super.setUp()
        try requireGeneratedScratchFixtureForTagWrites()
        // A journey records every failed check and keeps going: one wrong write must not hide the next.
        continueAfterFailure = true
    }

    override func tearDown() async throws {
        if let name = smartFolderName, app != nil, app.state == .runningForeground {
            deleteSmartFolder(named: name)
        }
        app?.terminate()
        restoreBaseline()
        try await super.tearDown()
    }

    func testTriageWritesKeepEveryOtherTagColourAndByte() throws {
        baseline = try snapshot()
        for (i, path) in baseline.keys.sorted().enumerated() { alias[path] = String(format: "f%02d", i) }
        for path in baseline.keys.sorted() { log("[d8-alias] \(alias[path]!) = \(path)") }
        let coloured = baseline.values.filter { !$0.colours.isEmpty }.count
        log("[d8] root \(root.path): \(baseline.count) files, \(coloured) with a colour label, "
            + "\(baseline.values.filter { $0.names.contains("Unread") }.count) Unread")
        waitForRows(minimum: 3, timeout: 20)
        zoomMainWindow()
        removeLeftoverJourneyFolders()
        let rowsShown = rowCount
        log("[d8] list shows \(rowsShown) rows")
        var before = baseline

        // (1) Mark Read & Next.
        guard let (aRow, aFile) = firstRow(where: { $0.names.contains("Unread") && !$0.names.contains("Read") },
                                           preferColour: true) else {
            return XCTFail("no Unread file with a unique name is visible in the list")
        }
        let a = aFile.path
        let expectedNext = nextUnread(after: aRow)
        clickRow(aRow)
        pressKey("m", modifiers: [.command, .shift])
        before = check("1 Mark Read & Next (⌘⇧M)", from: before,
                       expect: [a: Delta(remove: ["Unread"], add: ["Read"])])
        if let expectedNext {
            XCTAssertTrue(waitFor { self.selectedNames() == [expectedNext.name] },
                          "⌘⇧M should select the next Unread file \(alias[expectedNext.path] ?? "?")")
            log("[d8]   selection moved to \(alias[expectedNext.path] ?? "?"): "
                + "\(selectedNames() == [expectedNext.name] ? "yes" : "NO, got \(selectedNames())")")
        }

        // (2) The inline subject editor in a row.
        guard let (bRow, b) = firstRow(where: { $0.path != a && !$0.names.contains(self.inlineTag) },
                                       preferColour: true, after: aRow) else {
            return XCTFail("no second file for the inline edit")
        }
        let cell = table.tableRows.element(boundBy: bRow).descendants(matching: .any)["ar.cell.tags.\(b.name)"]
        XCTAssertTrue(cell.waitForExistence(timeout: 5), "row \(bRow) should expose its tag token field")
        // (2a) First, a Space typed into the editor must type a space, not open the Preview sheet (R-20: the
        // list's bare keys never fire inside a text field; R-23: subjects are often two words). Reproduced
        // broken 2026-10-14. If the field kept the space, a Backspace takes it back, so a fixed app ends
        // this step with the tags unchanged.
        let focusedA = focusInlineEditor(row: bRow, name: b.name)
        captureScreenshot("w40-d8-step2-focus")
        XCTAssertTrue(focusedA, "a click in the row's Tags cell should start editing it")
        log("[d8]   inline editor took keyboard focus: \(focusedA ? "yes" : "NO")")
        if focusedA {
            app.typeKey(.rightArrow, modifierFlags: .command)
            app.typeText(" ")
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            // The Preview sheet is the only place a "1 of N" page counter appears.
            let previewOpened = app.staticTexts.matching(
                NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "1 of ", "1 of ")).count > 0
            log("[d8] step 2a Space typed in the inline editor opened the Preview sheet: \(previewOpened ? "YES (broken)" : "no")")
            captureScreenshot("w40-d8-inline-space")
            let known = XCTExpectedFailure.Options(); known.isStrict = false
            XCTExpectFailure("W40.fix-reader-inline-keys (S2): the list's Space handler fires inside the inline tag editor",
                             options: known) {
                XCTAssertFalse(previewOpened, "R-20/R-23: Space in the inline tag editor must not open the Preview sheet")
            }
            if previewOpened { app.buttons["Done"].firstMatch.click() } else { app.typeKey(.delete, modifierFlags: []) }
            app.typeKey(.escape, modifierFlags: [])
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            before = check("2a Space in the inline editor writes nothing", from: before, expect: [:])
        }

        // (2) The edit itself, with the row still selected.
        let focused = focusInlineEditor(row: bRow, name: b.name)
        XCTAssertTrue(focused, "a second click in the row's Tags cell should start editing it again")
        // Move the insertion point to the end, so the typed token cannot replace a selected one.
        app.typeKey(.rightArrow, modifierFlags: .command)
        // One character at a time, at a human pace, so the token field's completion handling sees what
        // a person's typing gives it.
        for ch in inlineTag {
            app.typeText(String(ch))
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        }
        captureScreenshot("w40-d8-inline-typed")
        app.typeKey(.return, modifierFlags: [])
        let committedOnReturn = waitFor(timeout: 4) { self.tagNames(b.path).contains(self.inlineTag) }
        log("[d8]   inline edit committed on Return: \(committedOnReturn ? "yes" : "NO")")
        let returnKnown = XCTExpectedFailure.Options(); returnKnown.isStrict = false
        XCTExpectFailure("W40.fix-reader-inline-keys (S2): Return in the inline tag editor does not commit; "
                         + "only leaving the field does", options: returnKnown) {
            XCTAssertTrue(committedOnReturn, "R-23: the inline editor should commit on Return")
        }
        if !committedOnReturn {
            captureScreenshot("w40-d8-inline-after-return")
            // R-23's other half: leaving the field commits. Leave it by selecting another row.
            clickRow(bRow == 0 ? 1 : 0)
        }
        before = check("2 inline subject editor (type, Return, leave the field)", from: before,
                       expect: [b.path: Delta(add: [inlineTag])])

        // (3) Group edit in the ⌘I sheet: three consecutive rows, one coloured if any is visible.
        let start = groupStart()
        clickRow(start)
        app.typeKey(.downArrow, modifierFlags: .shift)
        app.typeKey(.downArrow, modifierFlags: .shift)
        XCTAssertTrue(waitFor { self.selectedNames().count == 3 }, "a click and Shift+↓ twice should select three rows")
        // The group is what the table actually selected, read back by name, not what row indices predict.
        let selected = selectedNames()
        let group = selected.compactMap { n in baseline.values.first { $0.name == n } }
        XCTAssertEqual(group.count, 3, "the three selected rows should map to files: \(selected)")
        log("[d8]   group selected: \(group.map { alias[$0.path] ?? "?" }), \(group.filter { !$0.colours.isEmpty }.count) with a colour")
        captureScreenshot("w40-d8-step3-selection")
        pressKey("i", modifiers: .command)
        addSubjectInEditor(groupTag)
        before = check("3 group edit, ⌘I on 3 files", from: before,
                       expect: Dictionary(uniqueKeysWithValues: group.map { ($0.path, Delta(add: [groupTag])) }))
        let afterGroup = before

        // (4) Rename across files.
        selectTagInCloud(groupTag)
        XCTAssertTrue(waitFor { self.rowCount == 3 }, "the tag filter should show the three group files")
        app.menuBars.menuBarItems["Tags"].click()
        app.menuItems["Rename Tag…"].click()
        let renameField = app.textFields["ar.renameTag.newName"]
        XCTAssertTrue(renameField.waitForExistence(timeout: 5), "Rename Tag should present its field")
        renameField.click()
        renameField.typeText(renamedTag)
        let renameCommit = app.buttons["ar.renameTag.commit"]
        XCTAssertEqual(renameCommit.title.isEmpty ? renameCommit.label : renameCommit.title, "Rename 3 Files",
                       "R-28: the sheet should show how many files the rename affects")
        log("[d8]   rename sheet button: \(renameCommit.title.isEmpty ? renameCommit.label : renameCommit.title)")
        renameCommit.click()
        before = check("4 Rename Tag across 3 files", from: before,
                       expect: Dictionary(uniqueKeysWithValues: group.map {
                           ($0.path, Delta(remove: [groupTag], add: [renamedTag])) }))
        clearFilters()

        // (5) Undo twice: the rename, then the group edit.
        clickRow(0)
        pressKey("z", modifiers: .command)
        before = check("5a ⌘Z undoes the rename", from: before,
                       expect: Dictionary(uniqueKeysWithValues: group.map {
                           ($0.path, Delta(remove: [renamedTag], add: [groupTag])) }))
        compare(before, to: afterGroup, paths: group.map(\.path), label: "5a state equals the state after 3")
        pressKey("z", modifiers: .command)
        before = check("5b ⌘Z undoes the group edit", from: before,
                       expect: Dictionary(uniqueKeysWithValues: group.map {
                           ($0.path, Delta(remove: [groupTag])) }))

        // (6) Merge similar tags: two case variants on two files, merged from Find Similar Tags.
        guard let (keepRow, keepFile) = firstRow(where: { _ in true }, preferColour: true),
              let (variantRow, variantFile) = firstRow(where: { $0.path != keepFile.path }, preferColour: true,
                                                       after: keepRow) else {
            return XCTFail("two files are needed for the merge")
        }
        clickRow(keepRow)
        pressKey("i", modifiers: .command)
        addSubjectInEditor(mergeKeep)
        clickRow(variantRow)
        pressKey("i", modifiers: .command)
        addSubjectInEditor(mergeVariant, expectCaseWarning: true)
        before = check("6a two case variants added through ⌘I", from: before,
                       expect: [keepFile.path: Delta(add: [mergeKeep]), variantFile.path: Delta(add: [mergeVariant])])
        mergeVariantIntoKeep()
        before = check("6b Find Similar Tags ▸ Merge", from: before,
                       expect: [variantFile.path: Delta(remove: [mergeVariant], add: [mergeKeep])])

        // (7) A smart folder on the merged tag. Saving it writes nothing to any file.
        selectTagInCloud(mergeKeep)
        XCTAssertTrue(waitFor { self.rowCount == 2 }, "the merged tag should be on exactly two files")
        let name = "W40d8 Journey \(Int(Date().timeIntervalSince1970))"
        saveSmartFolder(named: name)
        clearFilters()
        XCTAssertTrue(waitFor { self.rowCount == rowsShown }, "Clear should restore the whole list")
        openSmartFolder(named: name)
        XCTAssertTrue(waitFor { self.rowCount == 2 }, "the smart folder should scope the list to two files")
        log("[d8]   smart folder scope shows \(rowCount) rows")
        before = check("7 save and open a smart folder", from: before, expect: [:])

        // (8) Quit and relaunch: nothing is written by either, and the state reads back.
        app.terminate()
        before = check("8a quit (⌘Q equivalent: terminate)", from: before, expect: [:])
        app.launch()
        app.activate()
        XCTAssertTrue(table.waitForExistence(timeout: 15), "the table should return after relaunch")
        zoomMainWindow()
        waitForRows(minimum: 3, timeout: 20)
        XCTAssertTrue(waitFor(timeout: 20) { self.rowCount == rowsShown }, "relaunch should list the same rows")
        RunLoop.current.run(until: Date().addingTimeInterval(2))   // let a late write, if any, land
        before = check("8b relaunch", from: before, expect: [:])
        openSmartFolder(named: name)
        XCTAssertTrue(waitFor { self.rowCount == 2 }, "the smart folder should survive the relaunch")
        // The token field's accessibility value is attachment glyphs, not tag text, so the read-back is the
        // scope itself: after relaunch the merged tag's smart folder lists exactly the two files that carry it.
        let scoped = Set((0..<rowCount).compactMap { fileForRow($0)?.path })
        XCTAssertEqual(scoped, [keepFile.path, variantFile.path],
                       "after relaunch the smart folder should list the two files carrying \(mergeKeep)")
        log("[d8]   after relaunch: smart folder lists \(scoped.map { alias[$0] ?? "?" }.sorted()), expected "
            + "\([keepFile.path, variantFile.path].map { alias[$0] ?? "?" }.sorted())")
        captureScreenshot("w40-d8-after-relaunch")

        // Net effect against the start: exactly A read, B's inline tag, the merged tag on two files.
        var net: [String: Delta] = [a: Delta(remove: ["Unread"], add: ["Read"])]
        net[b.path, default: Delta()].add.append(inlineTag)
        net[keepFile.path, default: Delta()].add.append(mergeKeep)
        net[variantFile.path, default: Delta()].add.append(mergeKeep)
        _ = check("net change from the start", from: baseline, expect: net, current: before, canonicalUntouched: true)
    }

    // MARK: - UI steps

    /// Start editing a row's tag token field. A click in a SELECTED row's field starts editing; it must
    /// come after the double-click interval, or the table reads the two clicks as a double-click.
    private func focusInlineEditor(row: Int, name: String) -> Bool {
        // Found by file name, not row index: a write reloads the table, and the index may then name another row.
        let id = "ar.cell.tags.\(name)"
        let field = app.descendants(matching: .any)[id]
        let rowElement = table.tableRows.containing(NSPredicate(format: "identifier == %@", id)).firstMatch
        if rowElement.waitForExistence(timeout: 5) {
            app.activate()
            rowElement.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).click()
        } else {
            clickRow(row)
        }
        var focused = false
        for _ in 0..<3 where !focused {
            RunLoop.current.run(until: Date().addingTimeInterval(1.2))
            // The field's empty right end: on a real archive the tokens fill the middle, and a click on a
            // token does not start editing.
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).click()
            focused = waitFor(timeout: 2) {
                (field.value(forKey: "hasKeyboardFocus") as? Bool) == true
                    || field.descendants(matching: .any).matching(NSPredicate(format: "hasKeyboardFocus == true")).count > 0
            }
        }
        return focused
    }

    /// The window opens at about 900 pt wide, which clips the Tags column at its right edge; a click on a
    /// tag cell's centre then lands outside the window. Zoom it to the screen.
    private func zoomMainWindow() {
        let window = app.windows["Archive Reader"]
        let before = window.frame.width
        app.menuBars.menuBarItems["Window"].click()
        let zoom = app.menuItems["Zoom"]
        if zoom.waitForExistence(timeout: 3) { zoom.click() } else { app.typeKey(.escape, modifierFlags: []) }
        _ = waitFor(timeout: 3) { window.frame.width > before }
        log("[d8] window width \(Int(before)) → \(Int(window.frame.width)) pt")
    }

    private func addSubjectInEditor(_ subject: String, expectCaseWarning: Bool = false) {
        let field = app.textFields["ar.tagEditor.addSubject"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "⌘I should present the tag editor")
        field.click()
        field.typeText(subject)
        if expectCaseWarning {
            let warning = app.staticTexts.matching(
                NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@",
                            "differs only by case", "differs only by case")).firstMatch
            let shown = warning.waitForExistence(timeout: 3)
            XCTAssertTrue(shown, "adding a case variant should warn (R-27)")
            log("[d8]   case-variant warning shown: \(shown ? "yes" : "NO")")
        }
        app.buttons["ar.tagEditor.addSubjectButton"].click()
        // The sheet writes on Add; give the write a moment before Done dismisses the sheet.
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.buttons["Done"].firstMatch.click()
    }

    private func selectTagInCloud(_ tag: String) {
        clearFilters()
        let toggle = toolbarButton("ar.toolbar.tagCloud")
        let button = app.buttons.matching(identifier: "ar.tagCloud.tag")
            .matching(NSPredicate(format: "label == %@", tag)).firstMatch
        for _ in 0..<2 where !button.exists {
            toggle.click()
            RunLoop.current.run(until: Date().addingTimeInterval(0.7))
        }
        XCTAssertTrue(button.waitForExistence(timeout: 5), "the tag cloud should list \(tag)")
        scrollIntoView(button, within: app.descendants(matching: .any)["ar.tagCloud"])
        button.click()
    }

    private func mergeVariantIntoKeep() {
        app.menuBars.menuBarItems["Tags"].click()
        app.menuItems["Find Similar Tags…"].click()
        let key = [mergeKeep, mergeVariant].sorted().joined(separator: "|")
        let merge = app.buttons["ar.similarTags.merge.\(key)"]
        XCTAssertTrue(merge.waitForExistence(timeout: 10), "Find Similar Tags should group the two variants")
        let sheetScroll = app.sheets.firstMatch.scrollViews.firstMatch
        let keep = app.radioButtons.matching(NSPredicate(format: "label BEGINSWITH %@", mergeKeep + " ")).firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 5), "the cluster should offer \(mergeKeep) to keep")
        scrollIntoView(keep, within: sheetScroll)
        keep.click()
        scrollIntoView(merge, within: sheetScroll)
        merge.click()
        let commit = app.buttons["ar.renameTag.commit"]
        XCTAssertTrue(commit.waitForExistence(timeout: 5), "Merge should open the rename sheet")
        let field = app.textFields["ar.renameTag.newName"]
        XCTAssertEqual(field.value as? String, mergeKeep, "the rename sheet should be seeded with the kept tag")
        commit.click()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.buttons["Done"].firstMatch.click()
    }

    private func saveSmartFolder(named name: String) {
        let save = app.descendants(matching: .any)["ar.filter.saveSmartFolder"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "the filter bar should offer Save as smart folder")
        save.click()
        let inDialog = app.dialogs.textFields.firstMatch, inSheet = app.sheets.textFields.firstMatch
        XCTAssertTrue(waitFor(timeout: 5) { inDialog.exists || inSheet.exists }, "Save Search should ask for a name")
        let field = inDialog.exists ? inDialog : inSheet
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(name)
        // Scoped to the dialog: an unscoped "Save" also matches the Touch Bar's copy, which cannot be clicked.
        let save2 = (inDialog.exists ? app.dialogs : app.sheets).buttons["Save"].firstMatch
        if save2.exists { save2.click() } else { app.typeKey(.return, modifierFlags: []) }
        smartFolderName = name
        XCTAssertTrue(smartFolder(named: name).waitForExistence(timeout: 5), "the smart folder should appear")
    }

    private func smartFolder(named name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "ar.sidebar.smart")
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", name, name)).firstMatch
    }

    private func openSmartFolder(named name: String) {
        let item = smartFolder(named: name)
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the sidebar should list smart folder \(name)")
        item.click()
    }

    /// Through the sidebar's context menu, as a user would. Never asserts: it also runs from tearDown.
    @discardableResult
    private func deleteSmartFolder(named name: String) -> Bool {
        let item = smartFolder(named: name)
        guard item.waitForExistence(timeout: 3) else { return true }
        item.rightClick()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let offered = app.menuItems.allElementsBoundByIndex.filter { $0.isHittable }.map { $0.title }
        log("[d8] smart folder context menu offers: \(offered)")
        // The open context menu's item is the hittable one; Edit ▸ Delete matches "Delete" too.
        let candidates = app.menuItems.matching(NSPredicate(format: "title == %@", "Delete"))
        let delete = candidates.allElementsBoundByIndex.first { $0.isHittable }
        if let delete { delete.click() } else { app.typeKey(.escape, modifierFlags: []) }
        let gone = !smartFolder(named: name).waitForExistence(timeout: 1)
        log("[d8] smart folder \(name) deleted: \(gone ? "yes" : "NO")")
        return gone
    }

    /// Smart folders persist in the app's defaults, also in UI-test mode, so a run that died before its
    /// tearDown leaves one behind. Remove those before starting; never asserts.
    private func removeLeftoverJourneyFolders() {
        let leftovers = app.descendants(matching: .any).matching(identifier: "ar.sidebar.smart")
            .matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "W40d8 Journey", "W40d8 Journey"))
        let start = leftovers.count
        var tries = 0
        while leftovers.count > 0 && tries < 10 {
            leftovers.firstMatch.rightClick()
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            let delete = app.menuItems.matching(NSPredicate(format: "title == %@", "Delete"))
                .allElementsBoundByIndex.first { $0.isHittable }
            if let delete { delete.click() } else { app.typeKey(.escape, modifierFlags: []) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            tries += 1
        }
        if start > 0 { log("[d8] removed leftover journey smart folders: \(start - leftovers.count) of \(start)") }
    }

    private func clearFilters() {
        let clear = app.descendants(matching: .any)["ar.filter.clear"]
        if clear.exists && clear.isEnabled { clear.click() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.7))
    }

    private func scrollIntoView(_ element: XCUIElement, within container: XCUIElement) {
        var tries = 0
        while !element.isHittable && container.exists && tries < 40 {
            container.scroll(byDeltaX: 0, deltaY: -120)
            tries += 1
        }
    }

    // MARK: - Rows ↔ files

    private func fileForRow(_ index: Int) -> FileState? {
        guard index < rowCount else { return nil }
        let field = table.tableRows.element(boundBy: index).descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "ar.cell.tags.")).firstMatch
        guard field.exists else { return nil }
        let name = String(field.identifier.dropFirst("ar.cell.tags.".count))
        let matches = baseline.values.filter { $0.name == name }
        return matches.count == 1 ? matches[0] : nil   // a duplicated name cannot be mapped (R-14)
    }

    /// The first row (from `after + 1`) whose file satisfies `predicate` on its CURRENT state, preferring
    /// one with a colour label among the visible rows.
    private func firstRow(where predicate: (FileState) -> Bool, preferColour: Bool,
                          after: Int = -1) -> (Int, FileState)? {
        let now = (try? snapshot()) ?? baseline
        var fallback: (Int, FileState)?
        for i in (after + 1)..<max(after + 1, rowCount) {
            guard let f = fileForRow(i), let cur = now[f.path], predicate(cur) else { continue }
            if !preferColour || !cur.colours.isEmpty { return (i, cur) }
            if fallback == nil { fallback = (i, cur) }
        }
        return fallback
    }

    private func nextUnread(after row: Int) -> FileState? {
        let now = (try? snapshot()) ?? baseline
        for i in (row + 1)..<max(row + 1, rowCount) {
            if let f = fileForRow(i), let cur = now[f.path], cur.names.contains("Unread") { return cur }
        }
        return nil
    }

    private func groupStart() -> Int {
        let last = max(0, rowCount - 3)
        for i in 0...last where (i..<(i + 3)).contains(where: { !(fileForRow($0)?.colours.isEmpty ?? true) }) {
            return i
        }
        return 0
    }

    private func selectedNames() -> [String] {
        let rows = table.tableRows.matching(NSPredicate(format: "isSelected == true"))
        return (0..<rows.count).compactMap { i in
            let field = rows.element(boundBy: i).descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "ar.cell.tags.")).firstMatch
            return field.exists ? String(field.identifier.dropFirst("ar.cell.tags.".count)) : nil
        }
    }

    private func waitFor(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return condition()
    }

    // MARK: - On-disk state

    struct FileState: Equatable {
        var path: String            // relative to the root
        var name: String
        var tagBytes: Data?         // the raw Finder-tag xattr
        var tags: [String]          // decoded, colour suffix kept ("Red\n6")
        var otherXattrs: [String: String]   // name → SHA-256 of the value
        var quarantine: String?     // com.apple.quarantine's text, to show what a write did to it
        var size: Int
        var contentHash: String
        var names: [String] { tags.map { String($0.split(separator: "\n", omittingEmptySubsequences: false).first ?? "") } }
        var colours: [String] { tags.filter { $0.contains("\n") && !$0.hasSuffix("\n0") } }
    }

    struct Delta { var remove: [String] = []; var add: [String] = [] }

    private func snapshot() throws -> [String: FileState] {
        var out: [String: FileState] = [:]
        let rootPath = root.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles]) else { return out }
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            if url.pathExtension == "sqlite3" || url.lastPathComponent.hasPrefix("content-index") { continue }
            let full = url.resolvingSymlinksInPath().path
            let rel = full.hasPrefix(rootPath + "/") ? String(full.dropFirst(rootPath.count + 1)) : full
            let data = try Data(contentsOf: url)
            var other: [String: String] = [:]
            for n in Self.xattrNames(full) where n != Self.tagXattr {
                other[n] = Self.xattr(full, n).map(Self.sha) ?? "unreadable"
            }
            let tagBytes = Self.xattr(full, Self.tagXattr)
            let tags = tagBytes.flatMap {
                (try? PropertyListSerialization.propertyList(from: $0, format: nil)) as? [String]
            } ?? []
            let q = Self.xattr(full, "com.apple.quarantine").map { String(decoding: $0.prefix(120), as: UTF8.self) }
            out[rel] = FileState(path: rel, name: url.lastPathComponent, tagBytes: tagBytes, tags: tags,
                                 otherXattrs: other, quarantine: q, size: data.count, contentHash: Self.sha(data))
        }
        return out
    }

    /// Wait for the expected change to land, then check it and that nothing else moved.
    @discardableResult
    /// `canonicalUntouched`: compare files outside `expect` by tag meaning rather than bytes. Only the net
    /// check uses it: a file written and then undone is back to its tags, but in macOS's re-encoded form.
    private func check(_ step: String, from before: [String: FileState], expect: [String: Delta],
                       current: [String: FileState]? = nil, canonicalUntouched: Bool = false) -> [String: FileState] {
        var after = current ?? [:]
        if current == nil {
            // Poll only the expected files' tag xattrs (a full snapshot hashes every file), then take one.
            _ = waitFor(timeout: 10) {
                expect.allSatisfy { path, d in
                    let names = Self.xattr(self.root.appendingPathComponent(path).path, Self.tagXattr)
                        .flatMap { (try? PropertyListSerialization.propertyList(from: $0, format: nil)) as? [String] }?
                        .map(Self.name) ?? []
                    return d.add.allSatisfy(names.contains) && d.remove.allSatisfy { !names.contains($0) }
                }
            }
            // Let a late or stray write land before the whole-root check.
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            after = (try? snapshot()) ?? [:]
        }
        var problems: [String] = []
        var quarantine: [String] = []   // the filed W40.fix-reader-tag-quarantine defect, kept apart
        var notes: [String] = []
        if Set(after.keys) != Set(before.keys) { problems.append("the set of files changed") }
        for path in before.keys.sorted() {
            guard let b = before[path], let a = after[path] else { continue }
            let id = alias[path] ?? path
            if a.contentHash != b.contentHash || a.size != b.size { problems.append("\(id): CONTENT changed") }
            if a.otherXattrs != b.otherXattrs {
                let changed = Set(a.otherXattrs.keys).union(b.otherXattrs.keys)
                    .filter { b.otherXattrs[$0] != a.otherXattrs[$0] }.sorted()
                // Only a quarantine xattr added or rewritten is the filed defect; anything else fails outright.
                if changed == ["com.apple.quarantine"] && a.quarantine != nil {
                    quarantine.append("\(id): com.apple.quarantine \(b.quarantine == nil ? "added" : "rewritten") "
                                      + "(\(b.quarantine ?? "none") → \(a.quarantine ?? "none"))")
                } else {
                    problems.append("\(id): other xattrs changed: \(changed)")
                }
            }
            guard let d = expect[path] else {
                let same = canonicalUntouched ? a.tags.map(Self.canonical) == b.tags.map(Self.canonical)
                                              : a.tagBytes == b.tagBytes
                if !same { problems.append("\(id): tags changed but should not: \(b.tags) → \(a.tags)") }
                continue
            }
            // Expected: every tag of `before` not named in `remove` survives with its colour; each `add`
            // name is present; nothing else appears.
            // A bare "Read" and "Read\n0" are the same tag with no colour; macOS writes every tag of a
            // written file in the second form. Compare in that form, and note when the bytes were rewritten.
            let survivors = b.tags.filter { t in !d.remove.contains(Self.name(t)) }.map(Self.canonical)
            let after = a.tags.map(Self.canonical)
            let added = after.filter { t in d.add.contains(Self.name(t)) && !survivors.contains(t) }
            let rest = after.filter { t in !added.contains(t) }
            if rest.sorted() != survivors.sorted() {
                problems.append("\(id): unrelated tags or colours changed: expected \(survivors), got \(rest)")
            } else if rest != survivors {
                notes.append("\(id): tags kept but reordered")
            }
            if b.tags.contains(where: { !$0.contains("\n") }) {
                notes.append("\(id): bare tags rewritten with an explicit no-colour suffix")
            }
            for n in d.add where !a.names.contains(n) { problems.append("\(id): \(n) was not added") }
            for n in d.remove where a.names.contains(n) { problems.append("\(id): \(n) was not removed") }
            log("[d8]   \(id) before \(Self.show(b.tags))")
            log("[d8]   \(id) after  \(Self.show(a.tags))")
        }
        let untouched = before.count - expect.count
        if app.state != .notRunning { notes.append("\(app.windows.count) window(s) open") }
        log("[d8] step \(step): \(problems.isEmpty ? "PASS" : "FAIL")\(quarantine.isEmpty ? "" : " (known: quarantine)") — "
            + "\(expect.count) file(s) changed as expected, \(untouched) untouched file(s) byte-identical in tags, "
            + "other xattrs and content"
            + (problems.isEmpty ? "" : "; problems: \(problems.joined(separator: "; "))")
            + (quarantine.isEmpty ? "" : "; known defect: \(quarantine.joined(separator: "; "))")
            + (notes.isEmpty ? "" : "; notes: \(notes.joined(separator: "; "))"))
        // A known, filed defect is recorded as an expected failure naming its fix item, so the journey can
        // sit in the gate's lane without hiding anything else. Every other problem fails outright.
        for p in problems { XCTFail("[\(step)] \(p)") }
        if !quarantine.isEmpty {
            let known = XCTExpectedFailure.Options(); known.isStrict = false
            XCTExpectFailure("W40.fix-reader-tag-quarantine (S3): a Reader tag write adds com.apple.quarantine",
                             options: known) {
                for p in quarantine { XCTFail("[\(step)] \(p)") }
            }
        }
        return after
    }

    private func compare(_ now: [String: FileState], to then: [String: FileState], paths: [String], label: String) {
        let same = paths.allSatisfy { now[$0]?.tags.sorted() == then[$0]?.tags.sorted() }
        log("[d8] \(label): \(same ? "yes" : "NO")")
        XCTAssertTrue(same, label)
    }

    /// Put back every tag xattr the journey changed, after the app has quit.
    private func restoreBaseline() {
        guard !baseline.isEmpty else { return }
        guard let now = try? snapshot() else {
            return XCTFail("teardown could not read the root to restore it; later test classes may see a changed fixture")
        }
        var restored = 0
        for (path, b) in baseline where now[path]?.tagBytes != b.tagBytes {
            let full = root.appendingPathComponent(path).path
            if let bytes = b.tagBytes {
                _ = bytes.withUnsafeBytes { setxattr(full, Self.tagXattr, $0.baseAddress, bytes.count, 0, XATTR_NOFOLLOW) }
            } else {
                _ = removexattr(full, Self.tagXattr, XATTR_NOFOLLOW)
            }
            restored += 1
        }
        let clean = (try? snapshot()).map { s in baseline.allSatisfy { s[$0.key]?.tagBytes == $0.value.tagBytes } } ?? false
        log("[d8] teardown: restored the tag xattr on \(restored) file(s); root back to its start: \(clean ? "yes" : "NO")")
        XCTAssertTrue(clean, "teardown should put every tag xattr back as it was")
    }

    // MARK: - Helpers

    private func log(_ line: String) { print(line) }

    private func tagNames(_ path: String) -> [String] {
        Self.xattr(root.appendingPathComponent(path).path, Self.tagXattr)
            .flatMap { (try? PropertyListSerialization.propertyList(from: $0, format: nil)) as? [String] }?
            .map(Self.name) ?? []
    }

    private static func canonical(_ tag: String) -> String { tag.contains("\n") ? tag : tag + "\n0" }

    private static func name(_ tag: String) -> String {
        String(tag.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
    }

    private static func show(_ tags: [String]) -> String {
        "[" + tags.map { $0.replacingOccurrences(of: "\n", with: "\\n") }.joined(separator: ", ") + "]"
    }

    private static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func xattr(_ path: String, _ name: String) -> Data? {
        let len = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard len >= 0 else { return nil }
        var data = Data(count: len)
        let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, len, 0, XATTR_NOFOLLOW) }
        return read == len ? data : nil
    }

    private static func xattrNames(_ path: String) -> [String] {
        let len = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard len > 0 else { return [] }
        var buf = [CChar](repeating: 0, count: len)
        guard listxattr(path, &buf, len, XATTR_NOFOLLOW) == len else { return [] }
        return buf.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
            .filter { $0 != "com.apple.provenance" }
    }
}
