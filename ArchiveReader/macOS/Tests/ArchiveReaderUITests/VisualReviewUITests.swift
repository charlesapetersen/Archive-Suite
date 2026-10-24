import XCTest
import AppKit
import Darwin   // getpwuid / getuid — the opt-in flag lives in the REAL home, like the fixture

/// W40.e10 — the screen-by-screen visual review tour.
///
/// Opens every screen, sheet, popover, menu-driven panel and empty state the Reader has, in light and
/// dark, at the main window's minimum size and at a typical size, and screenshots each one twice: on
/// open and again once the app is idle (`W40.fix-notes-chips-overdrawn` drew correctly on open and broke
/// about two seconds later). A person — or a session — then LOOKS at every shot; this file asserts only
/// that the tour reached each surface, never anything about how it looked.
///
/// **Opt-in.** The tour takes minutes and writes a few hundred PNGs, so it must not ride along in every
/// VM run or the health gate (the default Reader selector is the whole UITest bundle). It runs only when
/// the flag file below exists in the guest's real home; `vm-gui-runner.sh` creates it for `VISUAL_REVIEW=1`
/// and deletes it otherwise:
///
///     VISUAL_REVIEW=1 ONLY_TESTING=ArchiveReaderUITests/VisualReviewUITests ops/gui/vm-gui-runner.sh reader xcuitest
///
/// **Read-only on the fixture.** Every sheet is dismissed with Cancel or Escape and nothing is marked,
/// edited or renamed, so the canonical fixture is never written. The volume corpus is built by this test
/// in the runner's own container (the `WarmStartUITests` pattern) and removed afterwards.
///
/// Shots are cropped to the app's windows and popovers (plus a margin; menus keep the whole screen) so the reader of a shot is
/// not paying for 1920×1200 of desktop. Names: `uitest-visual-<appearance>-<size>-<surface>-<open|idle>`.
final class VisualReviewUITests: FixtureUITestCase {

    static let flagPath: String = {
        let home: String
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            home = String(cString: dir)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser.path
        }
        return "\(home)/Library/Application Support/ArchiveReader/.visual-review"
    }()

    /// Seconds between the "open" and the "idle" shot. Thumbnails, previews and the content index have
    /// settled by then on the fixture; the Notes chip regression appeared at about two seconds.
    let idleDelay: TimeInterval = 3

    /// Surfaces the tour could not reach. Reported together at the end so one missing trigger does not
    /// cost every shot after it.
    private var missing: [String] = []
    private var prefix = ""

    override func setUp() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.flagPath),
                          "visual review is opt-in — VISUAL_REVIEW=1 in vm-gui-runner.sh")
        try await super.setUp()
        continueAfterFailure = true
    }

    // MARK: - The tours

    func testTourLight() throws { try tour(dark: false) }
    func testTourDark() throws { try tour(dark: true) }
    func testVolumeLight() throws { try volumeTour(dark: false) }
    func testVolumeDark() throws { try volumeTour(dark: true) }
    func testEmptyStatesLight() throws { try emptyStates(dark: false) }
    func testEmptyStatesDark() throws { try emptyStates(dark: true) }

    /// Focused W40.fix-reader-selected-row-contrast recheck without repeating the whole screen tour.
    /// Pixels are inspected after the run; selection assertions ensure each capture has the intended state.
    func testSelectedRowContrastLightAndDark() {
        for dark in [false, true] {
            relaunch(root: Self.fixturePath, dark: dark, size: .typical)
            prefix = "contrast-\(dark ? "dark" : "light")"
            resizeMainWindow(to: WindowSize.typical.main)
            let first = table.tableRows.element(boundBy: 0)
            first.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).click()
            XCTAssertTrue(first.isSelected)
            shoot("selected-one")
            app.typeKey("a", modifierFlags: .command)
            XCTAssertGreaterThan(table.tableRows.count, 1)
            XCTAssertTrue(table.tableRows.allElementsBoundByIndex.allSatisfy { $0.isSelected })
            shoot("selected-all")

            // Moving focus to a filter dims the selection without changing it or writing tags.
            let filter = app.textFields["ar.filter.name"]
            XCTAssertTrue(filter.waitForExistence(timeout: 3))
            filter.click()
            XCTAssertTrue((filter.value(forKey: "hasKeyboardFocus") as? Bool) ?? false)
            XCTAssertTrue(first.isSelected)
            shoot("inactive-selection")

            // A first click into an inactive multiselection can preserve the group. Move with the keyboard
            // after returning focus to the table to deliberately collapse it to one selected row.
            first.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).click()
            app.typeKey(XCUIKeyboardKey.upArrow.rawValue, modifierFlags: [])
            XCTAssertEqual(table.tableRows.allElementsBoundByIndex.filter { $0.isSelected }.count, 1)
            shoot("selected-again")
        }
    }

    private enum WindowSize: String, CaseIterable {
        case min, typical
        /// Requested main-window size; `min` drags past the 900×560 floor so the app's own minimum wins.
        var main: CGSize { self == .min ? CGSize(width: 400, height: 300) : CGSize(width: 1400, height: 860) }
        /// Document window size, seeded through its own saved-size defaults (`viewerWindowWidth/Height`).
        var document: CGSize { self == .min ? CGSize(width: 900, height: 600) : CGSize(width: 1400, height: 860) }
    }

    private func tour(dark: Bool) throws {
        for size in WindowSize.allCases {
            relaunch(root: Self.fixturePath, dark: dark, size: size)
            prefix = "\(dark ? "dark" : "light")-\(size.rawValue)"
            resizeMainWindow(to: size.main)
            mainWindowSurfaces()
            selectionSurfaces()
            documentWindowSurfaces()
            if size == .typical { settingsWindow() }
        }
        reportMissing()
    }

    // MARK: - Main window

    private func mainWindowSurfaces() {
        shoot("main")

        // Tag cloud and sidebar are persisted toggles; drive each to a known state, shoot, restore.
        let cloudTags = app.buttons.matching(identifier: "ar.tagCloud.tag")
        if toggle("ar.toolbar.tagCloud", until: { cloudTags.count > 0 }) {
            shoot("tagcloud")
            if let tag = cloudTags.allElementsBoundByIndex.first(where: { $0.isHittable }) {
                tag.rightClick()
                if app.menuItems.firstMatch.waitForExistence(timeout: 3) { shoot("tagcloud-contextmenu", menu: true) }
                else { missing.append("tag-cloud context menu") }
                escape()
            }
            _ = toggle("ar.toolbar.tagCloud", until: { cloudTags.count == 0 })
        } else { missing.append("tag cloud") }

        let sidebarRow = app.descendants(matching: .any)["ar.sidebar.allFiles"]
        if toggle("ar.toolbar.sidebar", until: { !sidebarRow.exists }) {
            shoot("sidebar-hidden")
            _ = toggle("ar.toolbar.sidebar", until: { sidebarRow.exists })
        } else { missing.append("sidebar hidden") }

        // Empty state from a filter that matches nothing.
        let name = app.textFields["ar.filter.name"]
        if name.waitForExistence(timeout: 3) {
            name.click()
            name.typeText("zzzz-no-such-file")
            pause(1)
            shoot("filter-nomatch")
            app.typeKey("k", modifierFlags: [.command, .shift])   // Clear Filters & Search
            pause(1)
        } else { missing.append("name filter") }

        // OCR search with results, so the active-filter summary and the result rows are seen.
        app.typeKey("f", modifierFlags: [.command, .option])
        let ocr = app.textFields["ar.filter.ocr"]
        if ocr.waitForExistence(timeout: 3) {
            ocr.typeText("California\r")
            pause(1.5)
            shoot("filter-ocr")
            app.typeKey("k", modifierFlags: [.command, .shift])
            pause(1)
        } else { missing.append("OCR search field") }

        popover(trigger: "ar.filter.dates", proof: app.textFields["ar.filter.dateFrom"], name: "dates-popover")
        popover(trigger: "ar.status.health", proof: app.staticTexts["Library health"], name: "health-popover")

        // A SwiftUI `Menu` in the toolbar is a menu button, not a button, so `toolbarButton` cannot see it.
        let saved = app.windows["Archive Reader"].descendants(matching: .any)
            .matching(identifier: "ar.toolbar.saved").firstMatch
        if saved.waitForExistence(timeout: 3) {
            saved.click()
            if app.menuItems.firstMatch.waitForExistence(timeout: 3) { shoot("saved-menu", menu: true) }
            else { missing.append("Saved menu") }
            escape()
        } else { missing.append("Saved toolbar menu") }

        if menu("File", "Save Current Search…") {
            if windowButton("Cancel").waitForExistence(timeout: 3) {
                shoot("save-search-alert")
                cancel()
            } else { missing.append("Save Search alert"); escape() }
        }

        if menu("Tags", "Rename Tag…") {
            if app.textFields["ar.renameTag.newName"].waitForExistence(timeout: 3) {
                shoot("rename-tag-sheet")
            } else { missing.append("Rename Tag sheet") }
            escape()
        }

        if menu("Tags", "Find Similar Tags…") {
            pause(1)
            shoot("similar-tags-sheet")
            if windowButton("Done").exists { windowButton("Done").click() }
            else if windowButton("Close").exists { windowButton("Close").click() }
            else { escape() }
        }

        for title in ["File", "View", "Selection", "Tags", "Sort & Filter"] {
            let bar = app.menuBars.element(boundBy: 0)
            let item = bar.menuBarItems[title]
            guard item.waitForExistence(timeout: 2) else { missing.append("menu \(title)"); continue }
            item.click()
            if app.menuItems.firstMatch.waitForExistence(timeout: 2) {
                shootOnce("menu-\(title.lowercased().replacingOccurrences(of: " & ", with: "-"))")
            }
            escape()
        }
    }

    // MARK: - With a selection

    private func selectionSurfaces() {
        clickRow(0)
        pause(0.5)
        shoot("selected-one")

        // Row context menu.
        // Near the left edge, as `clickRow` falls back to: at the 900-pt minimum the row's centre falls in the
        // gap between File name and Type, where the accessibility hit test finds no row ("Not hittable").
        let row = table.tableRows.element(boundBy: 0)
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).rightClick()
        if app.menuItems.firstMatch.waitForExistence(timeout: 3) { shoot("row-contextmenu", menu: true) }
        else { missing.append("row context menu") }
        escape()

        // Per-row Quality pop-up (opens a menu; Escape leaves the tag untouched).
        let quality = app.popUpButtons.matching(NSPredicate(format: "identifier BEGINSWITH 'ar.quality.menu.'"))
            .firstMatch
        if quality.waitForExistence(timeout: 3) {
            quality.click()
            if app.menuItems.firstMatch.waitForExistence(timeout: 3) { shoot("quality-popup", menu: true) }
            else { missing.append("Quality pop-up menu") }
            escape()
        } else { missing.append("Quality pop-up") }

        // Tag editor on one file, then on several.
        tagEditor(name: "tag-editor-one")
        clickRow(0)
        app.typeKey("a", modifierFlags: .command)
        pause(0.5)
        shoot("selected-all")
        tagEditor(name: "tag-editor-many")
        clickRow(0)

        // Preview sheet: a text-bearing PDF, then the image-only one (its no-text state).
        preview(row: 0, name: "preview")
        if let noText = rowIndex(containing: "IMG_NOTEXT") { preview(row: noText, name: "preview-notext") }
        else { missing.append("IMG_NOTEXT row") }
        if let jpeg = rowIndex(containing: "IMG_PHOTO") { preview(row: jpeg, name: "preview-jpeg") }
        else { missing.append("IMG_PHOTO row") }
    }

    private func tagEditor(name: String) {
        toolbarButton("ar.toolbar.editTags").click()
        if app.textFields["ar.tagEditor.addSubject"].waitForExistence(timeout: 5) {
            shoot(name)
        } else { missing.append(name) }
        // Cancel, never Done: Done is the write path.
        cancel()
        pause(0.5)
    }

    private func preview(row: Int, name: String) {
        clickRow(row)
        toolbarButton("ar.toolbar.preview").click()
        let done = app.buttons["ar.preview.done"]
        if done.waitForExistence(timeout: 5) {
            shoot(name)
            done.click()
        } else { missing.append(name); escape() }
        pause(0.5)
    }

    // MARK: - Document window

    private func documentWindowSurfaces() {
        openDocument(row: 0, name: "document")
        if app.windows.count >= 2 {
            app.typeKey("f", modifierFlags: .command)
            let find = app.textFields["ar.doc.findField"]
            if find.waitForExistence(timeout: 3) {
                pause(0.5)
                // ⌘F should leave the caret in the field; record whether it did, then click so the tour goes on.
                let focused = (find.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
                print("[visual] \(prefix) find field focused after ⌘F: \(focused)")
                if !focused { find.click() }
                find.typeText("California\r")   // Return runs the find (onSubmit)
                pause(1)
                shoot("document-find")
            } else { missing.append("document find bar") }
            let bar = app.menuBars.element(boundBy: 0)
            if bar.menuBarItems["Document"].waitForExistence(timeout: 2) {
                bar.menuBarItems["Document"].click()
                if app.menuItems.firstMatch.waitForExistence(timeout: 2) { shootOnce("menu-document") }
                escape()
            }
            closeDocument()
        }
        if let noText = rowIndex(containing: "IMG_NOTEXT") {
            openDocument(row: noText, name: "document-notext")
            closeDocument()
        }
        if let jpeg = rowIndex(containing: "IMG_PHOTO") {
            openDocument(row: jpeg, name: "document-jpeg")
            closeDocument()
        }
        // Two files in one document window.
        clickRow(0)
        XCUIElement.perform(withKeyModifiers: .shift) {   // near the left edge, as the row context menu above
            table.tableRows.element(boundBy: 1).coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).click()
        }
        app.typeKey("o", modifierFlags: .command)
        if waitForWindows(2) { shoot("document-multi"); closeDocument() } else { missing.append("document-multi") }
    }

    private func openDocument(row: Int, name: String) {
        clickRow(row)
        app.typeKey("o", modifierFlags: .command)
        if waitForWindows(2) { shoot(name) } else { missing.append(name) }
    }

    private func closeDocument() {
        app.typeKey("w", modifierFlags: .command)
        pause(1)
        app.windows["Archive Reader"].click()
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

    /// A long list with long names, a file with many subject chips, a deep tag vocabulary and a sidebar
    /// with nested folders — the volume the 12-file fixture cannot show.
    private func volumeTour(dark: Bool) throws {
        let root = try buildVolumeCorpus()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        relaunch(root: root.path, dark: dark, size: .typical)
        prefix = "\(dark ? "dark" : "light")-volume"
        resizeMainWindow(to: WindowSize.typical.main)
        waitForRows(minimum: 20, timeout: 30)
        shoot("main")
        table.swipeUp()   // scrolls the AppKit table
        pause(0.5)
        shoot("main-scrolled")

        let cloudTags = app.buttons.matching(identifier: "ar.tagCloud.tag")
        if toggle("ar.toolbar.tagCloud", until: { cloudTags.count > 0 }) {
            shoot("tagcloud")
            _ = toggle("ar.toolbar.tagCloud", until: { cloudTags.count == 0 })
        } else { missing.append("volume tag cloud") }

        popover(trigger: "ar.status.health", proof: app.staticTexts["Library health"], name: "health-popover")

        // The many-chip file sorts first by name ("0000 …").
        if menu("Sort & Filter", "Sort by File Name") { pause(1) }
        // Back to the top: the swipe above scrolled row 0 off screen, and `clickRow` then falls back to a
        // coordinate tap above the window — which lands in the menu bar and leaves a menu open.
        for _ in 0..<4 { table.swipeDown() }
        pause(0.5)
        // By name, "0000 … Many subjects" is row 0 and "00001 … Memorandum …" (a long name) row 1. Ask only
        // those rows: `rowIndex` walks every row, a second each with 301 of them.
        if !rowContains(0, "Many subjects") { missing.append("many-subjects row first by name") }
        clickRow(0)
        shoot("selected-manychips")
        tagEditor(name: "tag-editor-manychips")
        if rowContains(1, "Memorandum") { preview(row: 1, name: "preview-longname") }
        else { missing.append("long-name row second by name") }
        resizeMainWindow(to: WindowSize.min.main)
        shoot("main-min")
        reportMissing()
    }

    private func buildVolumeCorpus() throws -> URL {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ArchiveReader", isDirectory: true)
            .appendingPathComponent("AR-Visual-Volume-\(UUID().uuidString)", isDirectory: true)
        let source = URL(fileURLWithPath: Self.fixturePath).appendingPathComponent("00001 IMG — Brown.pdf")
        let sample = try Data(contentsOf: source)   // read-only copy of a generated fixture PDF
        let subjects = ["Jerry Brown", "Economics", "Water Policy", "Proposition 13", "Budget Office",
                        "Department of Finance — Correspondence", "Legislative Analyst", "Press Releases",
                        "University of California Regents", "Coastal Commission", "Energy Commission",
                        "Agricultural Labor Relations Board", "Medi-Cal", "Prison Reform", "Transportation"]
        let boxes = ["Box 001 — Governor's Office", "Box 002 — Finance", "Box 003 — Very long box name "
                     + "that keeps going to see how the sidebar truncates it"]
        for (b, box) in boxes.enumerated() {
            let folder = root.appendingPathComponent(box).appendingPathComponent("Folder \(b + 1) — Subfolder")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for i in 0..<100 {
                let n = b * 100 + i + 1
                let name = String(format: "%05d IMG — ", n)
                    + (i % 7 == 0 ? "Memorandum to the Governor regarding the 1978 budget and its consequences for local government finance"
                                  : "Brown")
                    + ".pdf"
                let url = folder.appendingPathComponent(name)
                try sample.write(to: url)
                var tags = [String(1970 + n % 20), n % 2 == 0 ? "Read" : "Unread", "Q\(1 + n % 3)"]
                tags.append(subjects[n % subjects.count])
                if n % 5 == 0 { tags.append(subjects[(n + 3) % subjects.count]) }
                if n % 11 == 0 { tags.append(String(format: "%02d", 1 + n % 12) + " " + monthName(1 + n % 12)) }
                try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
            }
        }
        // One file with every subject and more: the many-chips case.
        let many = root.appendingPathComponent("0000 IMG — Many subjects.pdf")
        try sample.write(to: many)
        let manyTags = ["1979", "Unread", "Q2"] + subjects
            + (1...12).map { "Extra subject tag number \($0)" }
        try (many as NSURL).setResourceValue(manyTags, forKey: .tagNamesKey)
        return root
    }

    private func monthName(_ m: Int) -> String {
        DateFormatter().monthSymbols[m - 1]
    }

    // MARK: - Empty states

    private func emptyStates(dark: Bool) throws {
        prefix = "\(dark ? "dark" : "light")-empty"
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ArchiveReader", isDirectory: true)
        let empty = base.appendingPathComponent("AR-Visual-Empty-\(UUID().uuidString)", isDirectory: true)
        let untagged = base.appendingPathComponent("AR-Visual-Untagged-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: untagged, withIntermediateDirectories: true)
        try Data("untagged scratch file".utf8).write(to: untagged.appendingPathComponent("one.pdf"))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: empty)
            try? FileManager.default.removeItem(at: untagged)
        }
        for (root, name) in [(empty, "empty-folder"), (untagged, "untagged-folder")] {
            for size in WindowSize.allCases {
                relaunch(root: root.path, dark: dark, size: size, waitForRows: false)
                resizeMainWindow(to: size.main)
                pause(2)
                shoot("\(name)-\(size.rawValue)")
            }
        }
        // Held revalidation on the fixture: the warm-start list from the content index while the scan is held.
        relaunch(root: Self.fixturePath, dark: dark, size: .typical, waitForRows: false,
                 extra: ["-ARUITestScanHoldSeconds", "8"])
        shootOnce("revalidating", menu: false)
        reportMissing()
    }

    // MARK: - Mechanics

    private func relaunch(root: String, dark: Bool, size: WindowSize, waitForRows wait: Bool = true,
                          extra: [String] = []) {
        app.terminate()
        var args = ["-ARUITestRootPath", root,
                    "-viewerWindowWidth", "\(Int(size.document.width))",
                    "-viewerWindowHeight", "\(Int(size.document.height))"]
        if root == Self.canonicalFixturePath {
            args += ["-ARUITestContentIndexPath", Self.canonicalFixturePath + "/content-index-v2.sqlite3"]
        }
        // The app's DEBUG appearance seam (W40.e9); `-AppleInterfaceStyle Dark` leaves a modern AppKit app light.
        args += dark ? LayoutGuard.darkModeArguments : LayoutGuard.lightModeArguments
        app.launchArguments = UITestLaunch.arguments(args + extra)
        app.launch()
        app.activate()
        _ = app.windows["Archive Reader"].waitForExistence(timeout: 15)
        if wait { waitForRows(minimum: 1, timeout: 20) }
    }

    /// Move the main window to the top-left of the screen, then drag its bottom-right corner so it is
    /// `target` in size (or the app's minimum, when `target` is below it).
    private func resizeMainWindow(to target: CGSize) {
        let win = app.windows["Archive Reader"]
        guard win.waitForExistence(timeout: 5) else { missing.append("main window for resize"); return }
        func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
            let f = win.frame
            return win.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x - f.minX, dy: y - f.minY))
        }
        var f = win.frame
        // Title bar: 12 pt below the top edge, a third of the way in (clear of the traffic lights and toolbar items).
        let grab = CGPoint(x: f.minX + f.width / 3, y: f.minY + 12)
        point(grab.x, grab.y).click(forDuration: 0.2, thenDragTo: point(grab.x - f.minX + 40, grab.y - f.minY + 40))
        pause(0.5)
        f = win.frame
        point(f.maxX - 2, f.maxY - 2).click(forDuration: 0.2,
                                            thenDragTo: point(f.minX + target.width, f.minY + target.height))
        pause(1)
        print("[visual] main window \(prefix) requested \(target) got \(win.frame.size)")
    }

    /// Shoot now and again once idle. `menu: true` keeps the whole screen, because an open menu is not
    /// one of the app's windows and querying every menu for its frame costs a second per menu.
    private func shoot(_ surface: String, menu: Bool = false) {
        capture("\(prefix)-\(surface)-open", crop: !menu)
        pause(idleDelay)
        capture("\(prefix)-\(surface)-idle", crop: !menu)
    }

    /// One shot only — a menu closes on its own if left open too long under XCUITest.
    private func shootOnce(_ surface: String, menu: Bool = true) {
        capture("\(prefix)-\(surface)-open", crop: !menu)
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
            let margin: CGFloat = 16
            let r = rect.insetBy(dx: -margin, dy: -margin)
                .applying(CGAffineTransform(scaleX: scale, y: scale))
                .intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height)).integral
            if let cropped = cg.cropping(to: r),
               let png = NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:]) {
                data = png
            }
        }
        let url = UITestShots.directory.appendingPathComponent("uitest-visual-\(name).png")
        do {
            try data.write(to: url, options: .atomic)
            print("[shot] visual-\(name): wrote \(url.path)")
        } catch {
            print("[shot] visual-\(name): could not write \(url.path) — \(error)")
        }
    }

    private func popover(trigger: String, proof: XCUIElement, name: String) {
        let button = app.descendants(matching: .any)[trigger].firstMatch
        guard button.waitForExistence(timeout: 3) else { missing.append("\(name) trigger \(trigger)"); return }
        button.click()
        if proof.waitForExistence(timeout: 3) { shoot(name) } else { missing.append(name) }
        escape()
    }

    @discardableResult
    private func menu(_ bar: String, _ title: String) -> Bool {
        let menuBar = app.menuBars.element(boundBy: 0)
        guard menuBar.menuBarItems[bar].waitForExistence(timeout: 2) else { missing.append("menu \(bar)"); return false }
        menuBar.menuBarItems[bar].click()
        let item = app.menuItems[title]
        guard item.waitForExistence(timeout: 2), item.isEnabled else {
            missing.append("\(bar) ▸ \(title)")
            escape()
            return false
        }
        item.click()
        return true
    }

    /// Click a toolbar toggle until `done` holds (at most twice — the state is persisted and shared).
    private func toggle(_ id: String, until done: () -> Bool) -> Bool {
        let button = toolbarButton(id)
        guard button.waitForExistence(timeout: 3) else { return false }
        for _ in 0..<2 where !done() {
            button.click()
            pause(1.5)
        }
        return done()
    }

    private func rowContains(_ index: Int, _ text: String) -> Bool {
        table.tableRows.element(boundBy: index).staticTexts
            .matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", text, text)).count > 0
    }

    private func rowIndex(containing text: String) -> Int? {
        let rows = table.tableRows
        for i in 0..<rows.count where rows.element(boundBy: i).staticTexts
            .matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", text, text)).count > 0 {
            return i
        }
        return nil
    }

    private func waitForWindows(_ n: Int, timeout: TimeInterval = 6) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while app.windows.count < n, Date() < deadline { pause(0.3) }
        pause(1)
        return app.windows.count >= n
    }

    /// A button inside one of the app's windows. A bare `app.buttons["Cancel"]` also matches the Touch Bar
    /// copy of the button, which XCUITest refuses to click.
    private func windowButton(_ title: String) -> XCUIElement {
        app.windows.buttons.matching(NSPredicate(format: "title == %@ OR label == %@", title, title)).firstMatch
    }

    /// Dismiss a sheet or alert without acting on it: its Cancel button, or Escape when it has none.
    private func cancel() {
        let button = windowButton("Cancel")
        if button.exists && button.isHittable { button.click() } else { escape() }
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
