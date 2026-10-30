import XCTest
import AppKit
import Darwin   // getpwuid / getuid — the rehearsal store lives in the REAL home, like the fixture

/// W40.e11 — the screen-by-screen visual review tour (the Notes half of `W40.e10`).
///
/// Opens every window, pane state, sheet, alert, popover, menu and empty state Notes has, in light and dark,
/// at the window's minimum size and at a typical size, and screenshots each one twice: on open and again once
/// the app is idle (`W40.fix-notes-chips-overdrawn` drew correctly on open and broke about two seconds later).
/// A person — or a session — then LOOKS at every shot; this file asserts only that the tour reached each
/// surface, never anything about how it looked.
///
/// **Opt-in.** The tour takes minutes and writes a few hundred PNGs, so it must not ride along in the default
/// VM selector or the health gate. It runs only while `.visual-review` exists inside the fixture (the runner is
/// sandboxed to the fixture, and each test restores it from its pristine copy, so the lane writes the flag into
/// both); `vm-gui-runner.sh` creates it for `VISUAL_REVIEW=1`, and also builds the W40.c1 rehearsal store the
/// volume pass opens:
///
///     VISUAL_REVIEW=1 ONLY_TESTING=ArchiveNotesUITests/VisualReviewUITests ops/gui/vm-gui-runner.sh notes xcuitest
///
/// **What it writes.** Two extra notes into the scratch fixture (a note with 30 file chips and one with a long
/// title), which the next test's pristine restore removes; an empty store in the runner's own temporary directory
/// (removed afterwards) and a junk index inside the fixture. Every sheet and alert is dismissed with Cancel or Escape, so no
/// folder, template or note is created, renamed or deleted.
///
/// Shots are cropped to the app's windows and popovers (plus a margin; menus and the open panel keep the whole
/// screen). Names: `uitest-visual-<appearance>[-stacked]-<size>-<surface>-<open|idle>`.
final class VisualReviewUITests: NotesFixtureUITestCase {

    static var flagPath: String { canonicalFixturePath + "/.visual-review" }

    /// The rehearsal store `make-notes-rehearsal.py` builds with its defaults (400 items, seed 40).
    static let rehearsalStorePath: String = {
        let home: String
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            home = String(cString: dir)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser.path
        }
        return "\(home)/Library/Caches/ArchiveSuiteRehearsal/notes-store/AN-GUI-Fixture"
    }()

    /// Rehearsal items, by id (`uuid5(NS, "item-<i>")`, so stable across seeds) and by a search phrase from the
    /// seed-40 title, which finds the row in a virtualised 400-row list.
    private let volumeManyChips = ("a4591d7d-db0a-578a-9015-8b261395f643", "Briefing deficit signature")  // 15 blocks
    private let volumeExtract = ("9c95412f-1cb4-56d3-83c6-7f0690f69a83", "Redaction deputy index")          // 15 blocks
    private let volumeLongTitle = ("b6070f98-5a6a-57d9-959f-70fdd41998d8", "AAAAAAAAAAAAAAAA")              // 230 × "A"
    private let volumeHuge = "d6fc5ed2-2145-517d-b4b3-84c6c36d045c"                                          // ~1 MB body

    /// The two notes this test adds to the fixture.
    static let idManyChips = "e11e11e1-0000-4000-8000-000000000001"
    static let idLongTitle = "e11e11e1-0000-4000-8000-000000000002"

    let idleDelay: TimeInterval = 3

    private var missing: [String] = []
    private var layout = Layout.sideBySide
    override var layoutLaunchArguments: [String] { Self.layoutArguments(layout) }
    private var prefix = ""
    /// Force the mode through the stored Appearance setting rather than `-ArchiveUITestAppearance` (W48.appearance-notes).
    private var bySetting = false

    // MARK: - The tours

    func testTourLight() throws { try optIn(); try withFixture { try tour(dark: false) } }
    func testTourDark() throws { try optIn(); try withFixture { try tour(dark: true) } }
    // W48.notes-stacked-layout: every surface again with the list above the note.
    func testTourStackedLight() throws { try optIn(); layout = .stacked; try withFixture { try tour(dark: false) } }
    func testTourStackedDark() throws { try optIn(); layout = .stacked; try withFixture { try tour(dark: true) } }
    // W48.appearance-notes: the tour with the mode set by the Appearance setting instead of the test argument.
    func testTourLightBySetting() throws { try optIn(); bySetting = true; try withFixture { try tour(dark: false) } }
    func testTourDarkBySetting() throws { try optIn(); bySetting = true; try withFixture { try tour(dark: true) } }
    func testVolumeLight() throws { try optIn(); try withFixture { volumeTour(dark: false) } }
    func testVolumeDark() throws { try optIn(); try withFixture { volumeTour(dark: true) } }
    func testEmptyStatesLight() throws { try optIn(); try withFixture { try emptyStates(dark: false) } }
    func testEmptyStatesDark() throws { try optIn(); try withFixture { try emptyStates(dark: true) } }

    /// Focused pixel review for W40.fix-notes-list-overrun. The headless unit guard asserts
    /// escaped ink; these whole-window shots retain the actual ellipses and neighbouring columns.
    func testListTruncation() throws {
        try optIn()
        try withFixture {
            try seedVolumeNotes()
            let file = URL(fileURLWithPath: Self.canonicalFixturePath)
                .appendingPathComponent("items/\(Self.idLongTitle)/Long title.md")
            var text = try String(contentsOf: file, encoding: .utf8)
            text = text.replacingOccurrences(of: "date: 1968-07\ndate_precision: month",
                with: "date: 1965-11-17\ndate_precision: day\nadditional_dates:\n"
                    + "  - role: sent_with\n    date: 1966\n    precision: year")
            text = text.replacingOccurrences(of: "tags: [proposition 13, budget office]",
                with: "tags: [proposition 13, budget office, county services, school districts, local government finance]")
            try Data(text.utf8).write(to: file)
            for dark in [false, true] {
                XCTAssertTrue(relaunch(store: Self.fixturePath, dark: dark, readyRow: Self.idLongTitle))
                for size in WindowSize.allCases {
                    prefix = "list-truncation-\(dark ? "dark" : "light")-\(size.rawValue)"
                    resizeMainWindow(to: size.main)
                    select(Self.idLongTitle)
                    shoot("long-title-date-tags")
                }
            }
            reportMissing()
        }
    }

    private func optIn() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.flagPath),
                          "visual review is opt-in — VISUAL_REVIEW=1 in vm-gui-runner.sh")
    }

    private enum WindowSize: String, CaseIterable {
        case min, typical
        /// `min` asks for far less than the window allows, so the app's own minimum wins.
        var main: CGSize { self == .min ? CGSize(width: 400, height: 300) : CGSize(width: 1440, height: 900) }
    }

    private func tour(dark: Bool) throws {
        continueAfterFailure = true
        try seedVolumeNotes()
        for size in WindowSize.allCases {
            relaunch(store: Self.fixturePath, dark: dark, readyRow: Self.idPlain)
            prefix = "\(dark ? "dark" : "light")\(bySetting ? "-setting" : "")\(layout == .stacked ? "-stacked" : "")"
                + "-\(size.rawValue)"
            resizeMainWindow(to: size.main)
            assertLayout(layout, in: mainWindow)
            noteSurfaces()
            listAndFilterSurfaces()
            sidebarSurfaces()
            editorCommandSurfaces()
            menuBarSurfaces()
            extractsWindow()
            if size == .typical { settingsWindow() }
        }
        reportMissing()
    }

    // MARK: - Notes in the editor and inspector

    private func noteSurfaces() {
        select(Self.idPlain)
        shoot("note-plain")
        if rawToggle.waitForExistence(timeout: 3) {
            rawToggle.click()
            pause(0.5)
            shoot("note-plain-raw")
            rawToggle.click()
            pause(0.5)
        } else { missing.append("raw/styled toggle") }

        select(Self.idReader)
        shoot("note-reader-chip")
        // The chip's own Preview button is a TextKit attachment subview XCUITest cannot hit-test, so the test
        // strip's seam opens the same popover (as `NotesE2PasteTests` does).
        if clickStripButton("an.editor.test.preview", timeout: 10) {
            if app.popovers.firstMatch.waitForExistence(timeout: 5) { shoot("chip-preview-popover") }
            else { missing.append("chip preview popover") }
            escape()
        } else { missing.append("chip preview seam") }

        select(Self.idZotero)
        shoot("note-zotero")
        if menu("Note", "Auto-fill from Zotero…") {
            let sheet = app.descendants(matching: .any)["an.zotero.autofill.sheet"].firstMatch
            if sheet.waitForExistence(timeout: 8) {
                pause(1)
                shoot("zotero-autofill-sheet")
            } else if app.alerts.firstMatch.exists || app.dialogs.firstMatch.exists {
                shoot("zotero-autofill-alert")
            } else { missing.append("Zotero auto-fill sheet") }
            let cancel = app.descendants(matching: .any)["an.zotero.autofill.cancel"].firstMatch
            if cancel.exists && cancel.isHittable { cancel.click() } else { dismissAlert() }
            pause(0.5)
        }

        select(Self.idManyChips)
        shoot("note-manychips")
        // The owner's report: the chips broke ~2 s after open. A longer settle as well, and a scrolled view.
        pause(3)
        capture("\(prefix)-note-manychips-idle6s", crop: true)
        editor.swipeUp()
        pause(1)
        shoot("note-manychips-scrolled")

        select(Self.idLongTitle)
        shoot("note-longtitle")
    }

    // MARK: - The list, search and filters

    private func listAndFilterSurfaces() {
        select(Self.idPlain)
        // Selecting the row already focuses the table; stacked, the table's own centre is not hittable (W48).
        if table.isHittable { table.click() }
        app.typeKey("a", modifierFlags: .command)
        pause(1)
        shoot("selected-all")
        select(Self.idPlain)

        let row = mainWindow.descendants(matching: .any)["an.cell.title.\(Self.idPlain)"].firstMatch
        revealRow(row)
        row.rightClick()
        if app.menuItems.firstMatch.waitForExistence(timeout: 3) { shootOnce("row-contextmenu") }
        else { missing.append("note row context menu") }
        escape()

        let search = mainWindow.descendants(matching: .any)["an.filter.search"].firstMatch
        if search.waitForExistence(timeout: 3) {
            search.click()
            app.typeText("zzzz-no-such-note")
            pause(1.5)
            shoot("search-nomatch")
            clearSearch()
            search.click()
            app.typeText("Intel")
            pause(1.5)
            shoot("search-results")
            clearSearch()
        } else { missing.append("search field") }

        let quality = mainWindow.descendants(matching: .any)["an.filter.quality.3"].firstMatch
        if quality.waitForExistence(timeout: 3) {
            quality.click()
            pause(1)
            shoot("filter-quality")
            let save = mainWindow.descendants(matching: .any)["an.filter.save"].firstMatch
            if save.exists && save.isEnabled {
                save.click()
                if waitForAlert() { shoot("save-smart-folder-alert") } else { missing.append("Save as Smart Folder alert") }
                dismissAlert()
            } else { missing.append("Save as Smart Folder button") }
            let clear = mainWindow.descendants(matching: .any)["an.filter.clear"].firstMatch
            if clear.exists && clear.isEnabled { clear.click() } else { quality.click() }
            pause(1)
        } else { missing.append("quality filter") }

        // Delete… asks first; the dialog is cancelled.
        select(Self.idPlain)
        revealRow(row)
        row.rightClick()
        if let delete = contextItem("Delete…") {
            delete.click()
            let cancel = app.descendants(matching: .any)["an.dialog.deleteLastInstance.cancel"].firstMatch
            if cancel.waitForExistence(timeout: 5) {
                shoot("delete-note-confirm")
                cancel.click()
            } else { missing.append("delete-note confirmation"); dismissAlert() }
            pause(0.5)
        } else { escape(); missing.append("row menu Delete…") }

        let new = mainWindow.descendants(matching: .any)["an.toolbar.new"].firstMatch
        if new.waitForExistence(timeout: 3) {
            new.click()
            if app.menuItems.firstMatch.waitForExistence(timeout: 3) { shootOnce("toolbar-new-menu") }
            else { missing.append("toolbar New menu") }
            escape()
        } else { missing.append("toolbar New button") }
    }

    // MARK: - Sidebar, folders, templates

    private func sidebarSurfaces() {
        if let inbox = folderRow("Inbox") {
            inbox.click()
            pause(1.5)
            shoot("folder-empty")
        }
        if let reading = folderRow("Reading") {
            reading.click()
            pause(1)
            shoot("folder-reading")
            reading.rightClick()
            if app.menuItems.firstMatch.waitForExistence(timeout: 3) { shootOnce("folder-contextmenu") }
            else { missing.append("folder context menu") }
            escape()
            for (item, name) in [("Rename…", "rename-folder-alert"), ("Delete", "delete-folder-dialog")] {
                reading.rightClick()
                if let mi = contextItem(item) {
                    mi.click()
                    if waitForAlert() { shoot(name) } else { missing.append(name) }
                    dismissAlert()
                } else { escape(); missing.append("folder menu \(item)") }
            }
        }
        let newFolder = mainWindow.descendants(matching: .any)["an.sidebar.newFolder"].firstMatch
        if newFolder.waitForExistence(timeout: 3) && newFolder.isHittable {
            newFolder.click()
            if waitForAlert() { shoot("new-folder-alert") } else { missing.append("New Folder alert") }
            dismissAlert()
        } else { missing.append("new-folder button") }

        let templates = mainWindow.descendants(matching: .any)["an.sidebar.templates"].firstMatch
        if templates.waitForExistence(timeout: 3) {
            templates.click()
            pause(1.5)
            shoot("templates-empty")
            let newTemplate = mainWindow.descendants(matching: .any)["an.template.new"].firstMatch
            if newTemplate.waitForExistence(timeout: 3) {
                newTemplate.click()
                if waitForAlert() { shoot("new-template-alert") } else { missing.append("New Template alert") }
                dismissAlert()
            } else { missing.append("New Template button") }
        } else { missing.append("Templates sidebar row") }

        allNotes()
        let tree = mainWindow.descendants(matching: .any)["an.toggleTree"].firstMatch
        if tree.waitForExistence(timeout: 3) {
            tree.click()
            pause(1.5)
            shoot("sidebar-hidden")
            tree.click()
            pause(1.5)
        } else { missing.append("sidebar toggle") }
    }

    // MARK: - Commands that open an alert from the editor

    private func editorCommandSurfaces() {
        select(Self.idPlain)
        focusEditor()
        app.typeKey("k", modifierFlags: .command)   // Format ▸ Link…, no link under the caret
        if waitForAlert() { shoot("insert-link-alert") } else { missing.append("Insert Link alert") }
        dismissAlert()

        NSPasteboard.general.clearContents()   // so Attach Zotero Link asks rather than inserting
        select(Self.idPlain)
        if menu("Note", "Attach Zotero Link…") {
            if waitForAlert() { shoot("attach-zotero-alert") } else { missing.append("Attach Zotero Link alert") }
            dismissAlert()
        }
        select(Self.idPlain)
        focusEditor()
        app.typeKey("a", modifierFlags: .command)   // it appends the selected passage, so it needs one
        if menu("Extract", "Append to Extract…") {
            if waitForAlert() { shoot("append-extract-alert") } else { missing.append("Append to Extract alert") }
            dismissAlert()
        }
    }

    private func menuBarSurfaces() {
        select(Self.idPlain)
        focusEditor()
        for title in ["File", "Edit", "Format", "Note", "Extract", "Window"] {
            let bar = app.menuBars.element(boundBy: 0)
            let item = bar.menuBarItems[title]
            guard item.waitForExistence(timeout: 2) else { missing.append("menu \(title)"); continue }
            item.click()
            if app.menuItems.firstMatch.waitForExistence(timeout: 2) { shootOnce("menu-\(title.lowercased())") }
            escape()
        }
        // The folder chooser is an out-of-process open panel: whole screen, Escape cancels it, never Choose.
        if menu("File", "Choose Archive Folder…") {
            pause(2.5)
            shootOnce("choose-folder-panel")
            escape()
            pause(1)
            if !mainWindow.isHittable { escape() }
        }
    }

    // MARK: - Extracts window, Settings

    private func extractsWindow() {
        guard menu("Window", "Extracts") else { return }
        let extracts = app.windows["Extracts"]
        guard extracts.waitForExistence(timeout: 10) else { missing.append("Extracts window"); return }
        let row = extracts.descendants(matching: .any)["an.cell.title.\(Self.idExtract)"].firstMatch
        if row.waitForExistence(timeout: 10) {
            row.click()
            pause(1)
            shoot("extracts-window")
        } else { missing.append("extract row") }
        closeExtracts()
    }

    private func settingsWindow() {
        let before = app.windows.count
        app.typeKey(",", modifierFlags: .command)
        if waitForWindows(before + 1) {
            shoot("settings")
            app.typeKey("w", modifierFlags: .command)
            pause(1)
        } else { missing.append("Settings window") }
    }

    // MARK: - Realistic volume

    /// The W40.c1 rehearsal store: 400 items, 27 folders (deep, replicated, smart, one very long name), two
    /// templates, odd titles, dangling links and missing thumbnails.
    private func volumeTour(dark: Bool) {
        continueAfterFailure = true
        prefix = "\(dark ? "dark" : "light")-volume"
        guard relaunch(store: Self.rehearsalStorePath, dark: dark, readyRow: nil) else {
            reportMissing(); return
        }
        resizeMainWindow(to: WindowSize.typical.main)
        pause(3)
        shoot("main")
        table.swipeUp()
        pause(0.5)
        shoot("main-scrolled")

        for (id, phrase, name) in [(volumeManyChips.0, volumeManyChips.1, "note-manychips"),
                                   (volumeLongTitle.0, volumeLongTitle.1, "note-longtitle")] {
            if search(phrase), let row = waitRow(id) {
                revealRow(row)
                row.click()
                pause(1)
                shoot(name)
            } else { missing.append(name) }
            clearSearch()
        }
        if let row = waitRow(volumeHuge, timeout: 3) {
            revealRow(row)
            row.click()
            shoot("note-huge")
        }   // the 1 MB note is off screen unless it sorts near the top; not required

        let templates = mainWindow.descendants(matching: .any)["an.sidebar.templates"].firstMatch
        if templates.waitForExistence(timeout: 3) {
            templates.click()
            pause(1.5)
            shoot("templates")
            let first = mainWindow.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'an.template.row.'")).firstMatch
            if first.waitForExistence(timeout: 3) {
                first.click()
                pause(1)
                shoot("template-editor")
            } else { missing.append("template row") }
        } else { missing.append("Templates sidebar row") }
        allNotes()

        if menu("Window", "Extracts") {
            let extracts = app.windows["Extracts"]
            if extracts.waitForExistence(timeout: 10) {
                pause(2)
                shoot("extracts-window")
                let field = extracts.descendants(matching: .any)["an.filter.search"].firstMatch
                if field.waitForExistence(timeout: 3) {
                    field.click()
                    app.typeText(volumeExtract.1)
                    pause(1.5)
                    let row = extracts.descendants(matching: .any)["an.cell.title.\(volumeExtract.0.uppercased())"].firstMatch
                    if row.waitForExistence(timeout: 5) {
                        row.click()
                        pause(1)
                        shoot("extract-manyblocks")
                    } else { missing.append("volume extract row") }
                }
                closeExtracts()
            } else { missing.append("volume Extracts window") }
        }

        resizeMainWindow(to: WindowSize.min.main)
        shoot("main-min")
        reportMissing()
    }

    // MARK: - Empty and failure states

    private func emptyStates(dark: Bool) throws {
        continueAfterFailure = true
        prefix = "\(dark ? "dark" : "light")-empty"
        let base = FileManager.default.temporaryDirectory
        let empty = base.appendingPathComponent("AN-Visual-Empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty.appendingPathComponent("items"), withIntermediateDirectories: true)
        let marker = #"{"guid":"\#(UUID().uuidString.lowercased())","name":"AN-Visual-Empty","kind":"notes","createdAt":"2026-10-16T00:00:00Z"}"#
        try Data(marker.utf8).write(to: empty.appendingPathComponent(".archive-suite-root.json"))
        addTeardownBlock { try? FileManager.default.removeItem(at: empty) }
        for size in WindowSize.allCases {
            relaunch(store: empty.path, dark: dark, readyRow: nil)
            resizeMainWindow(to: size.main)
            pause(2)
            shoot("empty-library-\(size.rawValue)")
        }
        // The search-index failure banner over the fixture. The app honours `-ANUITestIndexPath` only at the
        // generated fixture's own `notes-index-v1.sqlite3` (NotesModel.indexDatabaseURL), so the corrupt-index
        // test's 1 KiB junk goes there; the next test's pristine restore removes it.
        try requireCanonicalScratchFixtureForIndexTests()
        let junk = URL(fileURLWithPath: Self.canonicalFixturePath).appendingPathComponent("notes-index-v1.sqlite3")
        try Data(repeating: 0x5A, count: 1024).write(to: junk)
        relaunch(store: Self.fixturePath, dark: dark, readyRow: nil, extra: ["-ANUITestIndexPath", junk.path])
        resizeMainWindow(to: WindowSize.typical.main)
        pause(3)
        shoot("index-unavailable")
        reportMissing()
    }

    // MARK: - Fixture additions

    /// Two notes the four-note fixture lacks: 30 file chips (the owner's chips-overdrawn case had ~25) with a
    /// long tag list, and a 200-character title. In the canonical scratch fixture only; the next test's
    /// pristine restore removes them.
    private func seedVolumeNotes() throws {
        try requireCanonicalScratchFixtureForStoreWrites()
        let items = URL(fileURLWithPath: Self.canonicalFixturePath).appendingPathComponent("items")
        let stamp = "2026-07-14T09:00:00Z"
        func front(_ id: String, _ title: String, tags: [String]) -> String {
            "---\nschema: 1\nid: \(id)\nkind: note\ntitle: \"\(title)\"\nauthors: [Gordon E. Moore, Robert N. Noyce]\n"
                + "date: 1968-07\ndate_precision: month\ndate_uncertain: false\nquality: 2\n"
                + "tags: [\(tags.joined(separator: ", "))]\nroundup: false\ncreated: \(stamp)\nmodified: \(stamp)\n---\n"
        }
        let tags = ["intel", "corporate culture", "apple inc", "semiconductors", "silicon valley", "venture capital",
                    "fairchild", "labor relations", "management", "oral history", "computing history", "1968",
                    "governor's office", "department of finance — correspondence", "press releases"]
        try ChipsOverdrawnUITests.writeManyChipsNote(id: Self.idManyChips,
                                                     title: "Many chips — Apple Inc correspondence", tags: tags)

        let longTitle = "Memorandum to the Governor regarding the 1978 budget and its consequences for local "
            + "government finance, county services, school districts and the special districts, with attachments"
        let long = items.appendingPathComponent(Self.idLongTitle)
        try FileManager.default.createDirectory(at: long.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try Data((front(Self.idLongTitle, longTitle, tags: ["proposition 13", "budget office"])
                  + "A note whose title is far longer than the list column.\n").utf8)
            .write(to: long.appendingPathComponent("Long title.md"))
    }

    // MARK: - Mechanics

    private func appearanceArguments(dark: Bool) -> [String] {
        bySetting ? (dark ? LayoutGuard.darkSettingArguments : LayoutGuard.lightSettingArguments)
            : (dark ? LayoutGuard.darkModeArguments : LayoutGuard.lightModeArguments)
    }

    /// Relaunch against `store` in the requested appearance, close the second auto-opening window, and wait for
    /// `readyRow` (or for the main window only). Returns false when the window never came up.
    @discardableResult
    private func relaunch(store: String, dark: Bool, readyRow: String?, extra: [String] = []) -> Bool {
        app.terminate()
        app = .archiveUITestApp()
        app.launchArguments += ["-ANUITestStorePath", store] + zoteroLaunchArguments + [
            "-an.noteWindow.kindFilter", "notes",
            "-an.extractWindow.kindFilter", "extracts",
        ] + layoutLaunchArguments + appearanceArguments(dark: dark) + extra
        app.launch()
        app.activate()
        guard mainWindow.waitForExistence(timeout: 20) else { missing.append("main window on \(store)"); return false }
        let extracts = app.windows["Extracts"]
        if extracts.waitForExistence(timeout: 8) { closeExtracts() }
        if let readyRow {
            _ = waitRow(readyRow, timeout: 25)
        } else {
            pause(3)
        }
        return true
    }

    private func closeExtracts() {
        let extracts = app.windows["Extracts"]
        guard extracts.exists else { return }
        if menu("Window", "Extracts", record: false) { pause(0.5) }   // raise it: behind the main window it is not hittable
        let close = extracts.buttons[XCUIIdentifierCloseWindow]
        if close.waitForExistence(timeout: 5), close.isHittable { close.click() }
        _ = extracts.waitForNonExistence(timeout: 8)
        mainWindow.click()
    }

    private func resizeMainWindow(to target: CGSize) {
        let win = mainWindow
        guard win.waitForExistence(timeout: 5) else { missing.append("main window for resize"); return }
        func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
            let f = win.frame
            return win.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x - f.minX, dy: y - f.minY))
        }
        var f = win.frame
        let grab = CGPoint(x: f.minX + f.width / 3, y: f.minY + 12)
        point(grab.x, grab.y).click(forDuration: 0.2, thenDragTo: point(grab.x - f.minX + 40, grab.y - f.minY + 40))
        pause(0.5)
        f = win.frame
        point(f.maxX - 2, f.maxY - 2).click(forDuration: 0.2,
                                            thenDragTo: point(f.minX + target.width, f.minY + target.height))
        pause(1)
        print("[visual] main window \(prefix) requested \(target) got \(win.frame.size)")
    }

    private func select(_ id: String) {
        // Stacked, the list shows four or five rows: scroll the row into view first (tours 8 selected nothing).
        if let row = waitRow(id, timeout: 5) {
            revealRow(row)
            row.click()
            pause(1)
        } else {
            allNotes()
            if let row = waitRow(id, timeout: 5) { revealRow(row); row.click(); pause(1) } else { missing.append("row \(id)") }
        }
    }

    private func waitRow(_ id: String, timeout: TimeInterval = 10) -> XCUIElement? {
        let row = mainWindow.descendants(matching: .any)["an.cell.title.\(id.uppercased())"].firstMatch
        return row.waitForExistence(timeout: timeout) ? row : nil
    }

    private func allNotes() {
        let all = mainWindow.descendants(matching: .any)["an.sidebar.allNotes"].firstMatch
        if all.waitForExistence(timeout: 3) { all.click(); pause(1) }
    }

    private func folderRow(_ name: String) -> XCUIElement? {
        let row = mainWindow.descendants(matching: .any).matching(identifier: "an.sidebar.folder")
            .matching(NSPredicate(format: "value ==[c] %@ OR label ==[c] %@", name, name)).firstMatch
        if row.waitForExistence(timeout: 5) { return row }
        missing.append("\(name) folder row")
        return nil
    }

    private func focusEditor() {
        if editor.waitForExistence(timeout: 3) { editor.click(); pause(0.3) } else { missing.append("editor") }
    }

    @discardableResult
    private func search(_ text: String) -> Bool {
        let field = mainWindow.descendants(matching: .any)["an.filter.search"].firstMatch
        guard field.waitForExistence(timeout: 3) else { return false }
        field.click()
        app.typeText(text)
        pause(1.5)
        return true
    }

    private func clearSearch() {
        let clear = mainWindow.descendants(matching: .any)["an.filter.searchClear"].firstMatch
        if clear.exists && clear.isHittable { clear.click() } else {
            let field = mainWindow.descendants(matching: .any)["an.filter.search"].firstMatch
            if field.exists { field.click(); app.typeKey("a", modifierFlags: .command); app.typeKey(.delete, modifierFlags: []) }
        }
        pause(1)
    }

    /// The open context menu's item titled `title` (only the open context menu's copy is hittable).
    private func contextItem(_ title: String) -> XCUIElement? {
        var hit: XCUIElement?
        _ = pollUntil(timeout: 4) {
            hit = self.app.menuItems.matching(NSPredicate(format: "identifier == %@ OR title == %@", title, title))
                .allElementsBoundByIndex.first { $0.isHittable }
            return hit != nil
        }
        return hit
    }

    /// A SwiftUI alert or confirmation dialog, which may come up as a sheet, a dialog or an alert.
    private func waitForAlert(timeout: TimeInterval = 5) -> Bool {
        pollUntil(timeout: timeout) {
            self.app.sheets.firstMatch.exists || self.app.dialogs.firstMatch.exists || self.app.alerts.firstMatch.exists
        }
    }

    /// Dismiss whatever alert is up without acting on it: its Cancel button, else Escape.
    private func dismissAlert() {
        for group in [app.sheets, app.dialogs, app.alerts] {
            let box = group.firstMatch
            guard box.exists else { continue }
            let cancel = box.buttons.matching(NSPredicate(format: "title == 'Cancel' OR label == 'Cancel'")).firstMatch
            if cancel.exists && cancel.isHittable { cancel.click(); pause(0.5); return }
            let ok = box.buttons.matching(NSPredicate(format: "title == 'OK' OR label == 'OK'")).firstMatch
            if ok.exists && ok.isHittable { ok.click(); pause(0.5); return }
        }
        escape()
    }

    @discardableResult
    private func menu(_ bar: String, _ title: String, record: Bool = true) -> Bool {
        let menuBar = app.menuBars.element(boundBy: 0)
        guard menuBar.menuBarItems[bar].waitForExistence(timeout: 2) else {
            if record { missing.append("menu \(bar)") }
            return false
        }
        menuBar.menuBarItems[bar].click()
        let item = menuBar.menuItems[title]
        guard item.waitForExistence(timeout: 2), item.isEnabled else {
            if record { missing.append("\(bar) ▸ \(title)") }
            escape()
            return false
        }
        item.click()
        return true
    }

    private func waitForWindows(_ n: Int, timeout: TimeInterval = 6) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while app.windows.count < n, Date() < deadline { pause(0.3) }
        pause(1)
        return app.windows.count >= n
    }

    private func shoot(_ surface: String, menu: Bool = false) {
        capture("\(prefix)-\(surface)-open", crop: !menu)
        pause(idleDelay)
        capture("\(prefix)-\(surface)-idle", crop: !menu)
    }

    /// One whole-screen shot — a menu closes on its own if left open too long under XCUITest.
    private func shootOnce(_ surface: String) {
        capture("\(prefix)-\(surface)-open", crop: false)
    }

    private func capture(_ name: String, crop: Bool) {
        let shot = XCUIScreen.main.screenshot()
        var rect = CGRect.null
        if crop {
            for group in [app.windows, app.popovers] {
                for el in group.allElementsBoundByIndex where !el.frame.isEmpty {
                    rect = rect.union(el.frame)
                }
            }
        }
        var data = shot.pngRepresentation
        if !rect.isNull, let cg = shot.image.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let screen = NSScreen.screens.first?.frame, screen.width > 0 {
            let scale = CGFloat(cg.width) / screen.width
            let r = rect.insetBy(dx: -16, dy: -16)
                .applying(CGAffineTransform(scaleX: scale, y: scale))
                .intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height)).integral
            if let cropped = cg.cropping(to: r),
               let png = NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:]) {
                data = png
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uitest-visual-\(name).png")
        do {
            try data.write(to: url, options: .atomic)
            print("[shot] visual-\(name): wrote \(url.path)")
        } catch {
            print("[shot] visual-\(name): could not write \(url.path) — \(error)")
        }
    }

    private func escape() {
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        pause(0.5)
    }

    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func reportMissing() {
        print("[visual] \(prefix) missing: \(missing.isEmpty ? "none" : missing.joined(separator: "; "))")
        XCTAssertTrue(missing.isEmpty, "the tour could not reach: \(missing.joined(separator: "; "))")
        missing = []
    }
}
