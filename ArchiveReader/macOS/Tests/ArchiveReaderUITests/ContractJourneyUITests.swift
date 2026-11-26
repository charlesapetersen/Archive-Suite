import XCTest

/// W40.d11 — the shared contract across apps: a folder the Processor wrote, opened in the Reader, must read as
/// written. For every file the list shows, the row's cells (Document date, Capture marker, Quality, Read, the
/// item type beside the name, one token per subject in File tags, and no "needs attention" warning) and the
/// Inspector's subject chips are compared with what the Processor wrote; then one file is opened, and its
/// preservation copy (SPEC/catalogue.md, "Preservation copies") must be found. "What the Processor wrote" is
/// what `ops/verify/cross_app_contract.py expect` stated without the suite's own parsers (plistlib for the
/// tag xattr, pypdf for page 2).
///
/// Runs only in its own lane, which stages the folder and its expectation:
///     ops/verify/cross-app-contract.sh   (→ READER_JOURNEY=processed ops/gui/vm-gui-runner.sh reader xcuitest)
/// The builder copies the folder onto the guest disk with `ditto` and checks every tag xattr survived the copy;
/// the expectation arrives as `.w40-d11-expected.json` in the root. Outside that lane the class skips.
/// Read-only: it selects rows and reads cells, and writes nothing.
///
/// Evidence: `[d11] …` lines in the runner's `xcuitest.log`; `verification/evidence/core/W40.d11-contract.md`.
final class ContractJourneyUITests: FixtureUITestCase {

    static var expectedPath: String { fixturePath + "/.w40-d11-expected.json" }

    private struct Expected {
        let dateCell: String?
        let readCell: String
        let qualityCell: String
        let classification: String?
        let itemType: String?
        let subjects: [String]
        let sourceName: String?
    }

    override func setUp() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.expectedPath),
                          "the contract journey runs only in READER_JOURNEY=processed (ops/verify/cross-app-contract.sh)")
        try await super.setUp()
        continueAfterFailure = true   // one wrong cell must not hide the next file's
    }

    override func tearDown() async throws {
        if app != nil, app.state == .runningForeground {
            // The Inspector widens the window's minimum, so it is closed before the window is shrunk back.
            if app.textFields["ar.tagEditor.addSubject"].exists { pressKey("i", modifiers: [.command, .option]) }
            restoreWindowSize()
            app.typeKey("q", modifierFlags: .command)   // a real quit saves the window frame
            if !waitFor(timeout: 15, { self.app.state == .notRunning }) { app.terminate() }
        }
        try await super.tearDown()
    }

    func testProcessorOutputReadsAsWrittenInTheList() throws {
        let expected = try loadExpected()
        log("[d11] expectation: \(expected.count) files")
        waitForRows(minimum: expected.count, timeout: 60)
        XCTAssertEqual(rowCount, expected.count, "the list should show every file the Processor wrote")
        launchWidth = app.windows["Archive Reader"].frame.width
        zoomMainWindow()

        // Capture marker is offered once the content index has read a page-2 Classification line.
        let marker = table.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "ar.cell.classification.")).firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 120), "the Capture marker column should appear once indexed")
        // The index fills the column file by file; give the last one a moment to land.
        let indexed = waitFor(timeout: 120) { self.indexedCount() >= min(expected.count, self.visibleRowCount()) }
        log("[d11] Capture marker column shown; indexed in view: \(indexedCount()) (ok \(indexed))")
        XCTAssertTrue(indexed, "every row in view should have its Capture marker once indexed")
        captureScreenshot("w40-d11-list")

        // The Inspector follows the selection while it is shown: its chips name each subject as text, where the
        // list's token field reads as one U+FFFC per token. A click back on the row gives the list the keyboard.
        // Row 0 must be in view for its click to land (a list can open scrolled): a click on a row in view gives
        // the list the keyboard, and Home scrolls it to the top.
        let rows = table.tableRows
        if let inView = (0..<min(rows.count, 80)).first(where: { rows.element(boundBy: $0).isHittable }) {
            rows.element(boundBy: inView).click()
        }
        app.typeKey(.home, modifierFlags: [])
        XCTAssertTrue(waitFor(timeout: 5) { rows.element(boundBy: 0).isHittable }, "Home should bring row 0 into view")
        clickRow(0)
        pressKey("i", modifiers: [.command, .option])
        XCTAssertTrue(app.textFields["ar.tagEditor.addSubject"].waitForExistence(timeout: 10), "⌥⌘I shows the Inspector")
        clickRow(0)
        var lastName: String?
        var seen = Set<String>(), mismatches = 0
        for step in 0..<expected.count {
            guard let row = selectedRow(), let name = cellName(row) else {
                XCTFail("step \(step): no selected row with a tag cell"); break
            }
            guard !seen.contains(name) else { XCTFail("step \(step): \(name) selected twice; the list did not move"); break }
            seen.insert(name)
            lastName = name
            guard let want = expected[name] else {
                XCTFail("\(name): listed, but the Processor's folder has no such PDF"); mismatches += 1
                app.typeKey(.downArrow, modifierFlags: []); continue
            }
            let got = read(row, name: name)
            var bad: [String] = []
            if let d = want.dateCell { if got.date != d { bad.append("date \(got.date ?? "nil") ≠ \(d)") } }
            else { bad.append("the expectation has no Document date cell for this file") }
            if got.read != want.readCell { bad.append("read \(got.read ?? "nil") ≠ \(want.readCell)") }
            if got.quality != want.qualityCell { bad.append("quality \(got.quality ?? "nil") ≠ \(want.qualityCell)") }
            if got.marker != (want.classification ?? "\u{2014}") {
                bad.append("capture marker \(got.marker ?? "nil") ≠ \(want.classification ?? "—")")
            }
            // The type is drawn beside the name ("Box · 00001 — …"); read it from what is left once the name is gone.
            let besides = (got.nameCell ?? "").precomposedStringWithCanonicalMapping.replacingOccurrences(of: name, with: "")
            let shownType = ["Box", "Folder"].first { besides.contains($0) }
            if shownType != want.itemType { bad.append("item type \(shownType ?? "none") ≠ \(want.itemType ?? "none") (\(got.nameCell ?? "nil"))") }
            let tokens = (got.tags ?? "").filter { $0 == "\u{FFFC}" }.count
            if tokens != want.subjects.count { bad.append("tags cell shows \(tokens) tokens for \(want.subjects.count) subjects") }
            var chips: [String] = []
            _ = waitFor(timeout: 4) {
                chips = self.chips()
                return Set(chips) == Set(want.subjects)
            }
            if chips.sorted() != want.subjects.sorted() { bad.append("Inspector chips \(chips.sorted()) ≠ \(want.subjects.sorted())") }
            if got.warning == nil { bad.append("no Needs attention cell") }
            if got.warning == "⚠" { bad.append("flagged as needing attention") }
            log("[d11] \(name): date=\(got.date ?? "nil") marker=\(got.marker ?? "nil") quality=\(got.quality ?? "nil") "
                + "read=\(got.read ?? "nil") subjects=\(chips.sorted()) \(bad.isEmpty ? "ok" : "MISMATCH")")
            for b in bad { XCTFail("\(name): \(b)") }
            if !bad.isEmpty { mismatches += 1 }
            if step < expected.count - 1 { app.typeKey(.downArrow, modifierFlags: []) }
        }
        XCTAssertEqual(seen.count, expected.count, "every listed file should have been read")
        log("[d11] read \(seen.count) of \(expected.count) rows; \(mismatches) with a mismatch")
        captureScreenshot("w40-d11-last-row")

        // The last file, in its viewer: the Processor kept its original under Preservation/, which must be found.
        guard let name = lastName, let want = expected[name] else { return }
        app.typeKey("o", modifierFlags: .command)
        let doc = app.windows.matching(NSPredicate(format: "title == %@", name)).firstMatch
        XCTAssertTrue(doc.waitForExistence(timeout: 15), "⌘O should show \(name) in its viewer")
        let status = doc.descendants(matching: .any)["ar.doc.preservation.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10), "the viewer shows the preservation row")
        var shown = ""
        _ = waitFor(timeout: 20) {
            shown = self.text(status)
            return !shown.isEmpty && shown != "Checking…"
        }
        let source = want.sourceName.map { $0.replacingOccurrences(of: "\u{00A0}", with: " ") }
        log("[d11] \(name) in its viewer: preservation copy \(shown); page 2 names its source \(want.sourceName ?? "nil")")
        XCTAssertEqual(shown.replacingOccurrences(of: "\u{00A0}", with: " "), source,
                       "the viewer should find the original the Processor preserved")
        XCTAssertTrue(doc.descendants(matching: .any)["ar.doc.preservation.open"].exists, "View original is offered")
        captureScreenshot("w40-d11-viewer")
        doc.buttons[XCUIIdentifierCloseWindow].click()
    }

    private func chips() -> [String] {
        let prefix = "ar.tagEditor.chip."
        let found = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
        return (0..<found.count).map { String(found.element(boundBy: $0).identifier.dropFirst(prefix.count)) }
    }

    // MARK: - Reading a row

    private struct RowCells { var date, marker, quality, read, tags, nameCell, warning: String? }

    private func read(_ row: XCUIElement, name: String) -> RowCells {
        func cell(_ col: String) -> String? {
            let el = row.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "ar.cell.\(col).")).firstMatch
            return el.exists ? text(el) : nil
        }
        let tags = row.descendants(matching: .any)["ar.cell.tags.\(name)"]
        let quality = row.descendants(matching: .any)["ar.quality.menu.\(name)"]
        return RowCells(date: cell("date"), marker: cell("classification"),
                        quality: quality.exists ? text(quality) : nil, read: cell("read"),
                        tags: tags.exists ? text(tags) : nil, nameCell: cell("name"), warning: cell("warning"))
    }

    private func text(_ el: XCUIElement) -> String {
        if let v = el.value as? String, !v.isEmpty { return v }
        return el.label
    }

    private func selectedRow() -> XCUIElement? {
        let rows = table.tableRows.matching(NSPredicate(format: "isSelected == true"))
        return waitFor(timeout: 5) { rows.count == 1 } ? rows.element(boundBy: 0) : nil
    }

    private func cellName(_ row: XCUIElement) -> String? {
        let field = row.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "ar.cell.tags.")).firstMatch
        return field.exists
            ? String(field.identifier.dropFirst("ar.cell.tags.".count)).precomposedStringWithCanonicalMapping : nil
    }

    // MARK: - The window (the TriageJourneyUITests pattern)

    /// Zoomed, so every column is in view; tearDown shrinks it back, since the frame persists and
    /// `LayoutGuardUITests` is written against the minimum window.
    private func zoomMainWindow() {
        let window = app.windows["Archive Reader"]
        let before = window.frame.width
        app.menuBars.menuBarItems["Window"].click()
        let zoom = app.menuItems["Zoom"]
        if zoom.waitForExistence(timeout: 3) { zoom.click() } else { app.typeKey(.escape, modifierFlags: []) }
        _ = waitFor(timeout: 3) { window.frame.width > before }
        log("[d11] window width \(Int(before)) → \(Int(window.frame.width)) pt")
    }

    /// The width the window had at launch, which teardown puts back (the frame persists across launches).
    private var launchWidth: CGFloat?

    private func restoreWindowSize() {
        let window = app.windows["Archive Reader"]
        guard window.exists, let launchWidth else { return }
        let before = window.frame.size
        app.activate()
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -3, dy: -3))
        corner.click(forDuration: 0.3, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)))
        _ = waitFor(timeout: 3) { window.frame.width < before.width }
        log("[d11] window \(Int(before.width)) → \(Int(window.frame.width)) pt (launched at \(Int(launchWidth)))")
        XCTAssertLessThanOrEqual(window.frame.width, launchWidth, "teardown should leave the window no wider than it opened")
    }

    private func visibleRowCount() -> Int {
        let frame = table.frame
        let rows = table.tableRows
        return (0..<min(rows.count, 60)).filter { rows.element(boundBy: $0).frame.intersects(frame) }.count
    }

    private func indexedCount() -> Int {
        let cells = table.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "ar.cell.classification."))
        return (0..<cells.count).filter { text(cells.element(boundBy: $0)) != "\u{2014}" }.count
    }

    // MARK: - The expectation

    private func loadExpected() throws -> [String: Expected] {
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.expectedPath))
        let doc = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((doc["errors"] as? [Any])?.count ?? -1, 0, "the expectation itself reported errors")
        let files = try XCTUnwrap(doc["files"] as? [String: [String: Any]])
        var out: [String: Expected] = [:]
        for (name, f) in files {
            let facets = f["facets"] as? [String: Any] ?? [:]
            out[name.precomposedStringWithCanonicalMapping] = Expected(
                dateCell: f["dateCell"] as? String, readCell: f["readCell"] as? String ?? "—",
                qualityCell: f["qualityCell"] as? String ?? "None", classification: f["classification"] as? String,
                itemType: facets["itemType"] as? String, subjects: facets["subjects"] as? [String] ?? [],
                sourceName: (f["header"] as? [String: Any])?["originalFilename"] as? String)
        }
        return out
    }

    private func waitFor(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        } while Date() < deadline
        return condition()
    }

    private func log(_ line: String) { print(line) }
}
