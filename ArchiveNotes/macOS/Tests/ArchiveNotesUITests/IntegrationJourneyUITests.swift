import XCTest
import AppKit   // NSPasteboard / NSWorkspace — Copy Link read-back, and links handed to the OS

/// W40.d10 — Notes with the real Zotero, the real Reader and real links. Every other Notes UITest talks to
/// an in-process Zotero stub and RECORDS the links it would open (`WorkspaceOpenSpy`). Here nothing is stood
/// in for: Zotero 7+ runs in the VM with its local API on (`scripts/vm-zotero.sh`), the Debug Reader built at
/// the same commit is registered with Launch Services, and `-ANUITestRealWorkspaceOpen` makes Notes hand its
/// `zotero://` and `archivereader://` links to the OS.
///
/// Runs only in its own lane, which prepares those apps:
///     NOTES_JOURNEY=integrations ops/gui/vm-gui-runner.sh notes xcuitest
/// Outside it (the gate's whole-bundle run) there is no Zotero to talk to, so the class does not run.
///
/// Writes only the scratch `AN-GUI-Fixture`, restored from its pristine copy before every test; Reader reads
/// the fixture's own `reader-corpus/`. Evidence: `verification/evidence/notes/W40.d10-integrations.md`.
final class IntegrationJourneyUITests: NotesFixtureUITestCase {

    /// The lane writes this marker into the fixture's pristine copy after starting Zotero and building
    /// Reader; its absence means the run is not the integration lane.
    static var laneMarkerPath: String { fixturePath + "/.w40-d10-lane" }
    static let readerID = "com.archivereader.app"
    static let zoteroID = "org.zotero.zotero"
    static let zoteroPort = 23119
    /// The APA rendering of the item `vm-zotero.sh` seeds, as Zotero itself formats it (measured in the VM).
    static let apaCitation = "Lovelace, A. (1843). Notes on the Analytical Engine (W40.d10 seed). Richard and John E. Taylor."

    override var zoteroLaunchArguments: [String] {
        // No stub: the production localhost client. APA because Zotero renders it without fetching a style.
        ["-notes.zotero.cslStyleID", "apa"]
    }
    override var extraLaunchArguments: [String] { ["-ANUITestRealWorkspaceOpen", "YES"] }

    /// First line of every test: outside the integration lane there is no Zotero or registered Reader.
    private func requireIntegrationLane() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.laneMarkerPath),
                          "the integration journey runs only in NOTES_JOURNEY=integrations (vm-gui-runner.sh)")
    }

    // MARK: - Zotero

    /// N-43 — the note-level attachment fetches its citation from the real Zotero, and the chip's open
    /// raises Zotero on that item.
    func testD10_1_RealZoteroCitationAndOpenInZotero() throws {
        try requireIntegrationLane()
        let key = try seededZoteroKey()
        let link = "zotero://select/library/items/\(key)"
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            _ = selectItem(uuid: Self.idReader)
            let input = app.textFields["an.zotero.note.link"]
            let attach = app.buttons["an.zotero.note.attach"]
            XCTAssertTrue(input.waitForExistence(timeout: 10))
            mainWindow.scrollViews["an.detail.metadataScroll"].scroll(byDeltaX: 0, deltaY: -600)
            input.click()
            input.typeText(link)
            XCTAssertEqual(input.value as? String, link, "focus is on \(keyboardFocusDescription())")
            attach.click()
            let chip = app.buttons["an.zotero.chip.\(key)"]
            XCTAssertTrue(chip.waitForExistence(timeout: 8), "attaching should show the item's chip")
            var label = ""
            let fetched = pollUntil(timeout: 20) { label = chip.label; return label.contains("Lovelace, A. (1843)") }
            print("[d10] note chip label: \(label) value: \((chip.value as? String) ?? "-")")
            XCTAssertTrue(fetched, "the chip should show the citation Zotero rendered in APA; got \(label)")
            XCTAssertTrue(label.contains(Self.apaCitation), "the whole citation, as Zotero formats it; got \(label)")
            let raw = rawMarkdown(inItemDir: Self.idReader) ?? ""
            XCTAssertTrue(raw.contains("  - selectLink: \(link)"), "the attachment should persist")
            shot(app.windows["Archive Notes"], "d10-zotero-chip")

            let zotero = XCUIApplication(bundleIdentifier: Self.zoteroID)
            app.activate()
            chip.click()
            XCTAssertTrue(zotero.wait(for: .runningForeground, timeout: 15),
                          "Open in Zotero should bring the real Zotero forward (state \(zotero.state.rawValue))")
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            let zwin = zotero.windows.firstMatch
            print("[d10] Zotero windows after open: \(zotero.windows.allElementsBoundByIndex.map(\.title))")
            // Which item Zotero selected is read from this screenshot: a query into Zotero's own
            // accessibility tree timed out after two minutes (measured), so the journey does not make one.
            XCTAssertTrue(zwin.exists, "Zotero should have a window after the open")
            if zwin.exists { shot(zwin, "d10-zotero-after-open") }
        }
    }

    /// N-44 — Note ▸ Attach Zotero Link… then Auto-fill from Zotero…, against the real Zotero's local API.
    func testD10_2_AutoFillFromRealZotero() throws {
        try requireIntegrationLane()
        let key = try seededZoteroKey()
        let link = "zotero://select/library/items/\(key)"
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            let uuid = Self.idPlain
            _ = selectItem(uuid: uuid)
            XCTAssertTrue(pollUntil(timeout: 10) { ((self.editor.value as? String) ?? "").contains("A plain note with") })
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
            let noteMenu = app.menuBars.menuBarItems["Note"]
            noteMenu.click()
            app.menuItems["Attach Zotero Link…"].click()
            XCTAssertTrue(pollUntil(timeout: 8) {
                let raw = self.rawMarkdown(inItemDir: uuid) ?? ""
                return raw.contains("block: zotero-item") && raw.contains(link)
            }, "Attach Zotero Link should persist a source block")
            print("[d10] block chip text after attach: \((editor.value as? String) ?? "")")

            noteMenu.click()
            let autoFill = app.menuItems["Auto-fill from Zotero…"]
            XCTAssertTrue(pollUntil(timeout: 5) { autoFill.isEnabled }, "one Zotero block should enable auto-fill")
            autoFill.click()
            let sheet = app.descendants(matching: .any)["an.zotero.autofill.sheet"].firstMatch
            let opened = sheet.waitForExistence(timeout: 20)
            let crashed = app.state == .notRunning
            print("[d10] auto-fill sheet opened: \(opened); Notes running: \(!crashed) (state \(app.state.rawValue))")
            let known = XCTExpectedFailure.Options(); known.isStrict = false
            XCTExpectFailure("W40.fix-notes-zotero-csljson-crash (S2): Zotero's local API returns `csljson` as a "
                             + "string holding an array; ZoteroClient hands it to JSONSerialization, which throws "
                             + "an Objective-C exception, and Notes aborts", options: known) {
                XCTAssertFalse(crashed, "N-44: Auto-fill from the real Zotero must not crash Notes")
                XCTAssertTrue(opened, "N-44: Auto-fill should open the confirmation with Zotero's metadata")
            }
            guard opened, !crashed else { return }
            shot(app.windows["Archive Notes"], "d10-autofill-sheet")
            app.descendants(matching: .any)["an.zotero.autofill.apply"].firstMatch.click()
            XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
            var after = ""
            XCTAssertTrue(pollUntil(timeout: 12) {
                after = self.rawMarkdown(inItemDir: uuid) ?? ""
                return after.contains("date: 1843") && after.contains(Self.apaCitation)
            }, "Apply should write Zotero's date and its APA citation; got \(after)")
            print("[d10] after Apply:\n\(after)")
        }
    }

    // MARK: - Reader, both ways

    /// N-34 + N-36 — a page link copied in the real Reader pastes into Notes as a source block, and that
    /// block's Reveal opens the real Reader at the page.
    func testD10_3_ReaderPageLinkPastesAndRevealsInRealReader() throws {
        try requireIntegrationLane()
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            let reader = launchReader()
            defer { reader.terminate() }

            // Reader → Notes: open pages.pdf, go to its second image/text pair, copy that page's link.
            let table = reader.tables["ar.table"]
            // Reader lists only Read/Unread-tagged files; the fixture tags pages.pdf `Unread` and no other.
            let listed = pollUntil(timeout: 30) { table.tableRows.count >= 1 }
            print("[d10] Reader lists \(table.tableRows.count) rows; status \(readerStatus(reader))")
            shot(reader.windows["Archive Reader"], "d10-reader-list")
            XCTAssertTrue(listed, "Reader should list the scratch corpus's tagged pages.pdf")
            let filter = reader.textFields["ar.filter.name"]
            XCTAssertTrue(filter.waitForExistence(timeout: 10), "Reader's name filter")
            reader.activate()
            filter.click()
            filter.typeText("pages")
            let filtered = pollUntil(timeout: 15) { table.tableRows.count == 1 }
            print("[d10] after filtering: \(table.tableRows.count) rows, field \((filter.value as? String) ?? "-")")
            XCTAssertTrue(filtered, "the filter should leave pages.pdf")
            table.tableRows.element(boundBy: 0).click()
            reader.typeKey("o", modifierFlags: .command)
            let doc = reader.windows["pages.pdf"]
            XCTAssertTrue(doc.waitForExistence(timeout: 15), "⌘O should open pages.pdf")
            doc.buttons["Next"].firstMatch.click()
            XCTAssertTrue(statusLabel(in: doc, containing: "page 2 of 3").waitForExistence(timeout: 8),
                          "Next should move to the second pair")
            NSPasteboard.general.clearContents()
            reader.menuBars.menuBarItems["Document"].click()
            reader.menuItems["Copy Archive Link to This Page"].click()
            var copied = ""
            XCTAssertTrue(pollUntil(timeout: 10) {
                copied = NSPasteboard.general.string(forType: .string) ?? ""
                return copied.hasPrefix("archivereader://reveal")
            }, "Reader should put a page link on the pasteboard; got \(copied)")
            print("[d10] Reader copied: \(copied)")
            XCTAssertTrue(copied.contains("root=\(Self.corpusRootGUID)") && copied.contains("rel=pages.pdf"))
            let page = Int(URLComponents(string: copied)?.queryItems?.first { $0.name == "page" }?.value ?? "") ?? 0
            XCTAssertTrue((3...4).contains(page), "the second pair is PDF page 3 or 4; got \(page)")
            // Thumbnails are added to the pasteboard a moment later; let that rewrite land first.
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            doc.buttons[XCUIIdentifierCloseWindow].click()
            XCTAssertTrue(doc.waitForNonExistence(timeout: 8))

            // Paste it into the plain note with Edit ▸ Paste as Source Block(s).
            _ = selectItem(uuid: Self.idPlain)
            XCTAssertTrue(pollUntil(timeout: 10) { ((self.editor.value as? String) ?? "").contains("A plain note with") })
            editor.click()
            editor.typeKey(.downArrow, modifierFlags: .command)
            app.menuBars.menuBarItems["Edit"].click()
            app.menuItems["Paste as Source Block(s)"].click()
            var raw = ""
            XCTAssertTrue(pollUntil(timeout: 10) {
                raw = self.rawMarkdown(inItemDir: Self.idPlain) ?? ""
                return raw.contains("rel=pages.pdf") && raw.contains("page=\(page)")
            }, "the pasted link should be saved as a source block; got \(raw)")
            print("[d10] note after paste:\n\(raw)")
            let thumb = Self.fixturePath + "/items/\(Self.idPlain)/assets/p\(page)-thumb.png"
            XCTAssertTrue(pollUntil(timeout: 8) { FileManager.default.fileExists(atPath: thumb) },
                          "the pasted page's thumbnail should be stored beside the note")
            shot(app.windows["Archive Notes"], "d10-reader-link-pasted")

            // Notes → Reader: Reveal that block. Reader is running, so Launch Services hands it the link.
            ensureStyled()
            XCTAssertTrue(revealFirstSourceViaSeam(), "the reveal seam must be drivable")
            XCTAssertTrue(reader.wait(for: .runningForeground, timeout: 15), "Reveal should bring Reader forward")
            let revealed = reader.windows["pages.pdf"]
            XCTAssertTrue(revealed.waitForExistence(timeout: 15),
                          "Reveal should open pages.pdf; Reader says \(readerStatus(reader))")
            XCTAssertTrue(statusLabel(in: revealed, containing: "page 2 of 3").waitForExistence(timeout: 8),
                          "Reader should open at the linked page's pair")
            shot(revealed, "d10-reader-revealed")
        }
    }

    // MARK: - Links into Notes

    /// N-45 + N-46 — Copy Link, then the URL opened through the OS (Launch Services picks the app by its
    /// scheme): with the Notes window open, with every window closed, and with only Extracts open (S-013).
    func testD10_4_CopyLinkOpenedByTheOS() throws {
        try requireIntegrationLane()
        try withFixture {
            _ = selectItem(uuid: Self.idReader)
            XCTAssertTrue(pollUntil(timeout: 10) { self.editorText.contains("egalitarian") })
            NSPasteboard.general.clearContents()
            editor.click()
            app.menuBars.menuBarItems["Note"].click()
            app.menuBars.menuItems["Copy Link"].click()
            var link = ""
            XCTAssertTrue(pollUntil(timeout: 10) {
                link = NSPasteboard.general.string(forType: .string) ?? ""
                return link.hasPrefix("archivenotes://open")
            }, "Copy Link should write an archivenotes:// URL; got \(link)")
            let url = try XCTUnwrap(URL(string: link))
            print("[d10] Copy Link wrote: \(link)")

            // 1. Notes window open, another note showing.
            _ = selectItem(uuid: Self.idPlain)
            XCTAssertTrue(pollUntil(timeout: 10) { self.editorText.contains("A plain note") })
            try openThroughOS(url)
            XCTAssertTrue(pollUntil(timeout: 15) { self.editorText.contains("egalitarian") },
                          "the link should select and load the linked note")

            // 2. Every window closed; the app keeps running.
            _ = selectItem(uuid: Self.idPlain)
            XCTAssertTrue(pollUntil(timeout: 10) { self.editorText.contains("A plain note") })
            mainWindow.buttons[XCUIIdentifierCloseWindow].click()
            XCTAssertTrue(mainWindow.waitForNonExistence(timeout: 8))
            try openThroughOS(url)
            let reopened = mainWindow.waitForExistence(timeout: 15)
                && pollUntil(timeout: 15) { self.editorText.contains("egalitarian") }
            print("[d10] no windows open → Notes window: \(mainWindow.exists), editor: \(editorText.prefix(60))")
            XCTAssertTrue(reopened, "with no window open, the link should open the Notes window on the note")

            // 3. Only the Extracts window open (suspect S-013).
            if !mainWindow.exists { app.activate() } else {
                mainWindow.buttons[XCUIIdentifierCloseWindow].click()
                XCTAssertTrue(mainWindow.waitForNonExistence(timeout: 8))
            }
            app.menuBars.menuBarItems["Window"].click()
            app.menuItems["Extracts"].click()
            let extracts = app.windows["Extracts"]
            XCTAssertTrue(extracts.waitForExistence(timeout: 10), "Window ▸ Extracts should open it")
            try openThroughOS(url)
            let routed = mainWindow.waitForExistence(timeout: 15)
                && pollUntil(timeout: 15) { self.editorText.contains("egalitarian") }
            print("[d10] Extracts only → windows: \(app.windows.allElementsBoundByIndex.map(\.title)), editor: \(editorText.prefix(60))")
            shot(app.windows.firstMatch, "d10-link-with-extracts-only")
            XCTAssertTrue(routed, "with only Extracts open, the link should open the Notes window on the note")
        }
    }

    // MARK: - Helpers

    private var editorText: String { (editor.value as? String) ?? "" }

    /// The key of the item `vm-zotero.sh` seeded, asked of Zotero's own local API.
    private func seededZoteroKey() throws -> String {
        let url = URL(string: "http://127.0.0.1:\(Self.zoteroPort)/api/users/0/items?q=W40.d10&format=keys")!
        final class Box: @unchecked Sendable { var text = ""; var error: Error? }
        let box = Box()
        let done = expectation(description: "Zotero answered")
        URLSession.shared.dataTask(with: url) { data, _, error in
            box.text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            box.error = error
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 15)
        let key = box.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard key.count == 8 else {
            throw XCTSkip("no seeded Zotero item (\(box.error?.localizedDescription ?? box.text)) — run vm-zotero.sh start")
        }
        return key
    }

    /// Launch the Debug Reader the lane built, on the fixture's scratch corpus.
    private func launchReader() -> XCUIApplication {
        let reader = XCUIApplication(bundleIdentifier: Self.readerID)
        reader.launchArguments = ["-ApplePersistenceIgnoreState", "YES",
                                  "-ARUITestRootPath", Self.fixturePath + "/reader-corpus"]
        reader.launch()
        reader.activate()
        XCTAssertTrue(reader.windows["Archive Reader"].waitForExistence(timeout: 20), "Reader's window")
        return reader
    }

    private func statusLabel(in window: XCUIElement, containing text: String) -> XCUIElement {
        window.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
    }

    private func readerStatus(_ reader: XCUIApplication) -> String {
        let el = reader.staticTexts["ar.status.message"]
        return el.exists ? el.label : "(no status message)"
    }

    /// Hand `url` to the OS with no application named, as a link clicked in another app is.
    private func openThroughOS(_ url: URL) throws {
        XCTAssertTrue(NSWorkspace.shared.open(url), "Launch Services should accept \(url)")
    }

    private func shot(_ element: XCUIElement, _ name: String) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
        do {
            try element.screenshot().pngRepresentation.write(to: path)
            print("[shot] \(name): wrote \(path.path)")
        } catch {
            print("[shot] \(name): failed \(error)")
        }
    }
}
