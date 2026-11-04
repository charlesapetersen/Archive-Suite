import XCTest
import AppKit   // NSPasteboard — seed PNG bytes and plain text for the paste checks

/// W40.notes-w7-gui-checks — the live checks W7-S1a to S4 left for "when GUI resumes" (`ArchiveNotes/KNOWN_ISSUES.md`).
///
/// Only the checks no existing UITest already drives are here; the map of the others is in that file's four
/// W7 sections and in `verification/notes.md`. Every check runs on the scratch fixture (`AN-GUI-Fixture`,
/// restored from its pristine copy before each test) and asserts on its files, not only on what is drawn.
@MainActor
final class NotesW7ChecksUITests: NotesFixtureUITestCase {

    // MARK: - S1a: a pasted image persists in the note's assets/ and reloads

    /// G4 proves the paste writes the asset and the reference. This proves they come back: after selecting
    /// another note and returning, and after a relaunch, the file and its reference are unchanged and the
    /// editor shows the image as an attachment again.
    func testS1a_PastedImageReloadsAfterReselectAndRelaunch() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            let id = Self.idPlain
            let png = try XCTUnwrap(Self.makePNGData(), "should build PNG bytes for the pasteboard")
            let assetsBefore = Set(assetFiles(inItemDir: id))

            selectItem(uuid: id)
            XCTAssertTrue(pollUntil(timeout: 10) { self.editorText(in: self.mainWindow).contains("A plain note") },
                          "the plain note should load before pasting")
            ensureStyled()
            XCTAssertEqual(attachmentCount(editorText(in: mainWindow)), 0, "the plain note starts with no attachment")

            let pb = NSPasteboard.general
            pb.clearContents()
            XCTAssertTrue(pb.setData(png, forType: .png), "should seed the pasteboard with PNG bytes")
            XCTAssertTrue(pasteImageViaSeam(), "the DEBUG image-paste seam must be drivable")
            let outcome = pasteImageOutcome()
            XCTAssertTrue(outcome.hasPrefix("ok "), "the image paste should be handled — got \(outcome)")

            var asset: String?
            XCTAssertTrue(pollUntil(timeout: 12) {
                asset = Set(self.assetFiles(inItemDir: id)).subtracting(assetsBefore).first { $0.hasSuffix(".png") }
                return asset != nil && (self.rawMarkdown(inItemDir: id) ?? "").contains("](assets/\(asset!))")
            }, "the asset and its reference should both be on disk — paste said \(outcome)")
            let name = try XCTUnwrap(asset)
            let assetURL = URL(fileURLWithPath: itemsDir + "/" + id + "/assets/" + name)
            XCTAssertEqual(try Data(contentsOf: assetURL), png, "the stored asset should be the pasted bytes")
            XCTAssertEqual(attachmentCount(editorText(in: mainWindow)), 1, "the pasted image should be in the editor")
            // An attachment could also be the Missing placeholder (a write still in flight, or a reference the
            // read seam could not resolve); the probe says whether the editor drew the asset's own bytes.
            XCTAssertTrue(pollUntil(timeout: 10) { self.showsLoadedImage(named: name) },
                          "the just-pasted image should draw its own bytes once written — \(inlineImages())")
            RunLoop.current.run(until: Date().addingTimeInterval(2))   // past the autosave debounce
            let savedMarkdown = try XCTUnwrap(rawMarkdown(inItemDir: id))

            // Away and back: the note reloads from disk with the image in it.
            selectItem(uuid: Self.idZotero)
            XCTAssertTrue(pollUntil(timeout: 10) { self.editorText(in: self.mainWindow).contains("Notes on the Lovelace") },
                          "the other note should load")
            selectItem(uuid: id)
            XCTAssertTrue(pollUntil(timeout: 10) {
                self.editorText(in: self.mainWindow).contains("A plain note")
                    && self.attachmentCount(self.editorText(in: self.mainWindow)) == 1
            }, "returning to the note should show the image again — editor: \(editorText(in: mainWindow).debugDescription)")
            XCTAssertTrue(pollUntil(timeout: 10) { self.showsLoadedImage(named: name) },
                          "returning to the note should draw the pasted bytes, not a placeholder — \(inlineImages())")
            shot("W7-S1a image after reselect")

            // Relaunch: the same file, the same bytes, the image shown.
            relaunchWithOneWindow()
            selectItem(uuid: id)
            XCTAssertTrue(pollUntil(timeout: 10) {
                self.editorText(in: self.mainWindow).contains("A plain note")
                    && self.attachmentCount(self.editorText(in: self.mainWindow)) == 1
            }, "after relaunch the note should show the image — editor: \(editorText(in: mainWindow).debugDescription)")
            XCTAssertTrue(pollUntil(timeout: 10) { self.showsLoadedImage(named: name) },
                          "after relaunch the note should draw the pasted bytes, not a placeholder — \(inlineImages())")
            XCTAssertEqual(try Data(contentsOf: assetURL), png, "the asset should be unchanged after relaunch")
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            XCTAssertEqual(rawMarkdown(inItemDir: id), savedMarkdown, "opening the note after relaunch must not rewrite it")
            shot("W7-S1a image after relaunch")
        }
    }

    /// S1a: type into note A and select note B at once. A's edit is in A's file, B loads its own text, and
    /// nothing typed reaches B. (`WritingJourneyUITests` drives typing then ⌘Q; this is the switch.)
    func testS1a_TypeThenSelectAnotherNoteSavesTheEditAndLoadsTheOtherFresh() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            let marker = "SwitchedAwayEdit"
            let zoteroBefore = try XCTUnwrap(noteBody(uuid: Self.idZotero))

            selectItem(uuid: Self.idPlain)
            XCTAssertTrue(pollUntil(timeout: 10) { self.editorText(in: self.mainWindow).contains("A plain note") },
                          "the plain note should load")
            ensureStyled()
            XCTAssertTrue(setEditorSelection(location: 0, length: 0), "the selection seam must place the caret")
            app.typeText(marker)
            // Switch at once. Whether the idle autosave (600 ms after the last keystroke) had already written
            // the file is recorded in the log, not assumed: when it had not, the switch itself saved the edit.
            let savedBeforeSwitch = (noteBody(uuid: Self.idPlain) ?? "").contains(marker)
            selectItem(uuid: Self.idZotero)
            XCTContext.runActivity(named: "W7-S1a switch: A's file already held the edit before the switch = \(savedBeforeSwitch)") { _ in }
            XCTAssertTrue(pollUntil(timeout: 10) {
                self.editorText(in: self.mainWindow).contains("Notes on the Lovelace")
            }, "the other note should load")
            XCTAssertFalse(editorText(in: mainWindow).contains(marker), "the other note must not show A's edit")
            XCTAssertTrue(pollUntil(timeout: 10) { (self.noteBody(uuid: Self.idPlain) ?? "").contains(marker) },
                          "A's edit should be in A's file after the switch — focus now: \(keyboardFocusDescription())")
            RunLoop.current.run(until: Date().addingTimeInterval(2))   // past any late autosave
            XCTAssertEqual(noteBody(uuid: Self.idZotero), zoteroBefore, "the other note's file must be unchanged")
            XCTAssertEqual(occurrences(of: marker, in: noteBody(uuid: Self.idPlain) ?? ""), 1,
                           "A's edit should be saved exactly once")
        }
    }

    // MARK: - S2: Create Extract on a two-block selection; plain paste; the Append picker

    /// ⌘⌥E over a selection spanning two source blocks makes an extract with two note-passage blocks, one per
    /// source block, each anchored to its own ordinal. The two-block note is made by pasting a Reader link as a
    /// source block above the Zotero note's own block (the G5 path).
    func testS2_CreateExtractFromATwoBlockSelectionMakesTwoBlocks() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            let id = Self.idZotero
            let link = "archivereader://reveal?root=\(Self.corpusRootGUID)&rel=sample.pdf&jpeg=&page=2"

            selectItem(uuid: id)
            XCTAssertTrue(pollUntil(timeout: 10) { self.editorText(in: self.mainWindow).contains("Notes on the Lovelace paper.") },
                          "the Zotero note should load")
            if editorText(in: mainWindow).contains("zotero://select") {   // raw mode shows the header source
                rawToggle.click()
                _ = pollUntil(timeout: 5) { !self.editorText(in: self.mainWindow).contains("zotero://select") }
            }
            let pb = NSPasteboard.general
            pb.clearContents()
            XCTAssertTrue(pb.setString(link, forType: .string), "should seed the pasteboard with the link")
            XCTAssertTrue(setEditorSelection(location: 0, length: 0), "the selection seam must place the caret")
            clickMenu("Edit", "Paste as Source Block(s)")
            XCTAssertTrue(pollUntil(timeout: 10) {
                let md = self.rawMarkdown(inItemDir: id) ?? ""
                return md.contains("block: reader-page") && md.contains("block: zotero-item")
            }, "the note should now hold two source blocks")
            XCTAssertTrue(pollUntil(timeout: 10) { self.attachmentCount(self.editorText(in: self.mainWindow)) >= 2 },
                          "the editor should show both block chips")
            RunLoop.current.run(until: Date().addingTimeInterval(2))   // past the autosave of the paste
            let sourceBefore = try XCTUnwrap(rawMarkdown(inItemDir: id))

            let before = itemDirs()
            XCTAssertTrue(setEditorSelection(location: 0, length: 100_000), "the selection seam must select both blocks")
            app.activate()
            app.typeKey("e", modifierFlags: [.command, .option])
            @MainActor func newExtracts() -> [String] {
                itemDirs().subtracting(before).filter { (rawMarkdown(inItemDir: $0) ?? "").contains("kind: extract") }
            }
            if !pollUntil(timeout: 12, { !newExtracts().isEmpty }) {
                clickMenu("Extract", "Create Extract")
                _ = pollUntil(timeout: 10) { !newExtracts().isEmpty }
            }
            let dirs = newExtracts()
            XCTAssertEqual(dirs.count, 1, "⌘⌥E should mint exactly one extract")
            let md = try XCTUnwrap(dirs.first.flatMap { rawMarkdown(inItemDir: $0) })
            XCTAssertEqual(occurrences(of: "<!-- block: note-passage", in: md), 2,
                           "a two-block selection should make a two-block extract:\n\(md)")
            XCTAssertTrue(md.contains("archivenotes://open?id=\(id)#block-0"), "the first block should cite block 0:\n\(md)")
            XCTAssertTrue(md.contains("archivenotes://open?id=\(id)#block-1"), "the second block should cite block 1:\n\(md)")
            XCTAssertTrue(md.contains("Notes on the Lovelace paper."), "the Zotero block's text should be in the extract")
            let first = try XCTUnwrap(md.range(of: "archivenotes://open?id=\(id)#block-0")).lowerBound
            let second = try XCTUnwrap(md.range(of: "archivenotes://open?id=\(id)#block-1")).lowerBound
            XCTAssertLessThan(first, second, "the extract's blocks should keep the source's order:\n\(md)")
            RunLoop.current.run(until: Date().addingTimeInterval(2))   // past any save the command could trigger
            XCTAssertEqual(rawMarkdown(inItemDir: id), sourceBefore, "Create Extract must leave the source note as it was")
            closeWindow(app.windows["Extracts"])
        }
    }

    /// A plain-text paste from outside the app, into an extract, inserts the text with no provenance: no new
    /// note-passage block, no new chip, and no "provenance was not imported" note (that is for a passage
    /// payload that could not be honoured).
    func testS2_PlainExternalPasteIntoAnExtractIsFreeform() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            let text = "Freeform words pasted from elsewhere."
            XCTAssertTrue(setKind(to: "Both", in: mainWindow), "should show both kinds in the Note window")
            selectItem(uuid: Self.idExtract)
            XCTAssertTrue(pollUntil(timeout: 12) { self.editorText(in: self.mainWindow).contains("Moore says") },
                          "the extract should load")
            ensureStyled()
            let chipsBefore = passageChipStates()?.count ?? -1
            XCTAssertEqual(chipsBefore, 1, "the fixture extract carries one passage chip")

            let pb = NSPasteboard.general
            pb.clearContents()
            XCTAssertTrue(pb.setString(text, forType: .string), "should seed the pasteboard with plain text")
            // The selection seam leaves the editor first responder (G13 relies on it for ⌘Z), so ⌘V reaches
            // the production `paste(_:)`.
            XCTAssertTrue(setEditorSelection(location: 0, length: 0), "the selection seam must place the caret")
            app.typeKey("v", modifierFlags: .command)

            XCTAssertTrue(pollUntil(timeout: 10) { (self.noteBody(uuid: Self.idExtract) ?? "").contains(text) },
                          "the pasted text should be saved into the extract — focus: \(keyboardFocusDescription())")
            let body = try XCTUnwrap(noteBody(uuid: Self.idExtract))
            XCTAssertEqual(occurrences(of: "<!-- block:", in: body), 1, "a plain paste must add no block:\n\(body)")
            let textAt = try XCTUnwrap(body.range(of: text)).lowerBound
            let blockAt = try XCTUnwrap(body.range(of: "<!-- block: note-passage")).lowerBound
            XCTAssertLessThan(textAt, blockAt, "pasted at the top, the text should stand outside the passage block:\n\(body)")
            XCTAssertEqual(passageChipStates()?.count, chipsBefore, "a plain paste must add no passage chip")
            XCTAssertFalse((statusText(in: mainWindow) ?? "").contains("provenance"),
                           "a plain paste is not a degraded passage paste — status: \(statusText(in: mainWindow) ?? "none")")
        }
    }

    /// Extract ▸ Append to Extract… shows its picker, and Append adds the passage to the chosen extract as a
    /// second note-passage block. The extract then has two distinct sources, which the Extracts window's
    /// Sources column counts (S4).
    func testS2S4_AppendPickerAppendsAndTheSourcesColumnCountsBothSources() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            let extractWin = try openExtractsWindow()
            let sources = extractWin.descendants(matching: .any)["an.cell.sources.\(Self.idExtract)"]
            XCTAssertTrue(sources.waitForExistence(timeout: 15), "the Extracts window should show the Sources column")
            XCTAssertEqual(sources.value as? String, "1", "the fixture extract cites one source note")

            frontWindow(named: "Archive Notes")
            selectItem(uuid: Self.idPlain)
            XCTAssertTrue(pollUntil(timeout: 10) { self.editorText(in: self.mainWindow).contains("A plain note") },
                          "the plain note should load")
            let plainBefore = try XCTUnwrap(rawMarkdown(inItemDir: Self.idPlain))
            XCTAssertTrue(setEditorSelection(location: 0, length: 8), "the selection seam must select text")
            clickMenu("Extract", "Append to Extract\u{2026}")

            let sheet = mainWindow.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 8), "Append to Extract… should show its picker")
            let popup = sheet.popUpButtons.firstMatch
            XCTAssertTrue(popup.waitForExistence(timeout: 5), "the picker should offer the extracts in a pop-up")
            XCTAssertEqual(popup.value as? String, "On egalitarian culture", "the only extract should be offered")
            shot("W7-S2 append picker")
            sheet.buttons["Append"].click()

            XCTAssertTrue(pollUntil(timeout: 12) {
                let md = self.rawMarkdown(inItemDir: Self.idExtract) ?? ""
                return self.occurrences(of: "<!-- block: note-passage", in: md) == 2
                    && md.contains("archivenotes://open?id=\(Self.idPlain)#block-0")
            }, "Append should add a second, provenanced block:\n\(rawMarkdown(inItemDir: Self.idExtract) ?? "")")
            let md = try XCTUnwrap(rawMarkdown(inItemDir: Self.idExtract))
            XCTAssertTrue(md.contains("Moore says he and Noyce"), "the extract's original passage must remain")
            XCTAssertTrue(md.contains("archivenotes://open?id=\(Self.idReader)#block-0"), "its original source must remain")

            XCTAssertTrue(pollUntil(timeout: 12) { (sources.value as? String) == "2" },
                          "the Sources column should count both distinct sources — shows \(sources.value ?? "nil")")
            XCTAssertEqual(rawMarkdown(inItemDir: Self.idPlain), plainBefore, "Append must leave the source note as it was")
            shot("W7-S4 sources column after append")
            closeWindow(extractWin)
        }
    }

    // MARK: - S3: a renamed, a deleted and a changed source

    /// A renamed source shows its current title on the extract's chip; once it is deleted the chip is marked
    /// missing (W21 proves the same across windows) and Jump to Source reports it instead of navigating.
    func testS3_RenamedThenDeletedSourceUpdatesTheChipAndTheJump() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            XCTAssertTrue(setKind(to: "Both", in: mainWindow), "should show both kinds in the Note window")

            // Rename the source note through the list's inline rename (G17's gesture).
            let cell = selectItem(uuid: Self.idReader)
            cell.click()
            app.typeKey(.return, modifierFlags: [])
            app.typeText("Moore renamed")
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(pollUntil(timeout: 10) {
                (self.rawMarkdown(inItemDir: Self.idReader) ?? "").contains("title: Moore renamed")
            }, "the inline rename should reach the source note's front matter")

            selectItem(uuid: Self.idExtract)
            XCTAssertTrue(pollUntil(timeout: 12) { self.editorText(in: self.mainWindow).contains("Moore says") },
                          "the extract should load")
            ensureStyled()
            var chip: [String: Any]?
            XCTAssertTrue(pollUntil(timeout: 10) {
                chip = self.passageChipStates(timeout: 2)?.first { ($0["id"] as? String) == Self.idReader }
                return chip?["label"] as? String == "Moore renamed — 1968" && chip?["missing"] as? Bool == false
            }, "the chip should show the source's current title — state \(String(describing: chip))")
            XCTAssertTrue((rawMarkdown(inItemDir: Self.idExtract) ?? "").contains("display: \"Moore on Intel culture — 1968\""),
                          "the extract's saved snapshot label is left as it was")

            // Delete the source: remove both of its folder placements, confirming the last (W21's route).
            selectItem(uuid: Self.idReader)
            for folder in [Self.folderIdeas, Self.folderReading] {
                let remove = mainWindow.descendants(matching: .any)["an.locations.remove.\(folder)"]
                XCTAssertTrue(remove.waitForExistence(timeout: 10), "the \(folder) remove control should exist")
                _ = pollUntil(timeout: 8) { self.app.activate(); return remove.isHittable }
                remove.click()
                if folder == Self.folderIdeas {
                    XCTAssertTrue(pollUntil(timeout: 12) {
                        !(self.organizationMemberships() ?? []).contains([Self.folderIdeas, Self.idReader])
                    }, "removing one placement should keep the note")
                }
            }
            let confirm = app.descendants(matching: .any)["an.dialog.deleteLastInstance.confirm"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 10), "removing the last placement should ask first")
            confirm.click()
            XCTAssertTrue(pollUntil(timeout: 15) { !self.itemDirs().contains(Self.idReader) },
                          "confirming should move the source note to the Trash")

            selectItem(uuid: Self.idExtract)
            XCTAssertTrue(pollUntil(timeout: 12) { self.editorText(in: self.mainWindow).contains("Moore says") },
                          "the extract should load")
            XCTAssertTrue(pollUntil(timeout: 10) {
                chip = self.passageChipStates(timeout: 2)?.first { ($0["id"] as? String) == Self.idReader }
                return chip?["missing"] as? Bool == true
            }, "the chip should be marked missing once its source is gone — state \(String(describing: chip))")
            XCTAssertTrue(jumpFirstPassageViaSeam(), "the jump seam must be drivable")
            XCTAssertTrue(pollUntil(timeout: 10) {
                (self.statusText(in: self.mainWindow) ?? "").contains("no longer exists — the extract text is preserved")
            }, "Jump to Source should report the missing source — status: \(statusText(in: mainWindow) ?? "none")")
            XCTAssertTrue(editorText(in: mainWindow).contains("Moore says he and Noyce"),
                          "the jump must leave the extract, and its text, where it is")
            shot("W7-S3 deleted source")
        }
    }

    /// An exact ordinal jumps without comment; an ordinal the source no longer has still opens the source
    /// (at the top) and says the source has changed since the extract was made.
    func testS3_StaleOrdinalJumpOpensTheSourceAndSaysItHasChanged() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()

            // Baseline: the fixture's #block-0 exists, so the jump is exact and reports nothing.
            try jumpFromTheFixtureExtract()
            XCTAssertFalse((statusText(in: mainWindow) ?? "").contains("has changed"),
                           "an exact jump should not say the source changed — status: \(statusText(in: mainWindow) ?? "none")")

            // The source has one block, so #block-7 is out of range. Edit the scratch files with the app closed:
            // the extract cites #block-7, and the source gets 200 paragraphs so that a scroll position exists.
            app.terminate()
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "the app should quit before the files are edited")
            let dir = itemsDir + "/" + Self.idExtract
            let md = try XCTUnwrap(mdFiles(inItemDir: Self.idExtract).first)
            let url = URL(fileURLWithPath: dir + "/" + md)
            let original = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(original.contains("#block-0"), "the fixture extract should cite block 0")
            try original.replacingOccurrences(of: "#block-0", with: "#block-7").write(to: url, atomically: true, encoding: .utf8)
            let sourceURL = URL(fileURLWithPath: itemsDir + "/" + Self.idReader + "/"
                                + (try XCTUnwrap(mdFiles(inItemDir: Self.idReader).first)))
            let filler = (1...200).map { "Filler paragraph \($0) of the source note." }.joined(separator: "\n\n")
            try (try String(contentsOf: sourceURL, encoding: .utf8) + "\n" + filler + "\n")
                .write(to: sourceURL, atomically: true, encoding: .utf8)
            relaunchWithOneWindow()

            try jumpFromTheFixtureExtract()
            XCTAssertTrue(pollUntil(timeout: 10) {
                (self.statusText(in: self.mainWindow) ?? "").contains("The source note has changed since this extract was made.")
            }, "a stale ordinal should say the source changed — status: \(statusText(in: mainWindow) ?? "none")")
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            let scroll = editorScroll(in: mainWindow)
            XCTAssertLessThanOrEqual(scroll ?? 0, 0.05,
                                     "a stale ordinal should leave the source at its top — scroll position \(String(describing: scroll))")
            shot("W7-S3 stale ordinal")
        }
    }

    /// A jump from the Extracts window to a block half-way down its source scrolls the Note window to it, not to
    /// the top and not to the end. The source gets 100 paragraphs, a second source block, and 100 more, and the
    /// extract cites that block.
    func testS3_JumpFromTheExtractsWindowScrollsToALowerBlock() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()

            // Edit the scratch files with the app closed.
            app.terminate()
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "the app should quit before the files are edited")
            let sourceURL = URL(fileURLWithPath: itemsDir + "/" + Self.idReader + "/"
                                + (try XCTUnwrap(mdFiles(inItemDir: Self.idReader).first)))
            let fillerAbove = (1...100).map { "Filler paragraph \($0) of the source note." }.joined(separator: "\n\n")
            let fillerBelow = (101...200).map { "Filler paragraph \($0) of the source note." }.joined(separator: "\n\n")
            let lowerBlock = """
                <!-- block: reader-page
                     link: archivereader://reveal?root=\(Self.corpusRootGUID)&rel=sample.pdf&jpeg=&page=2
                     display: "sample.pdf — p. 2"
                     page: 2 -->

                The lower block's own text.
                """
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            try (source + "\n" + fillerAbove + "\n\n" + lowerBlock + "\n\n" + fillerBelow + "\n")
                .write(to: sourceURL, atomically: true, encoding: .utf8)
            let extractURL = URL(fileURLWithPath: itemsDir + "/" + Self.idExtract + "/"
                                 + (try XCTUnwrap(mdFiles(inItemDir: Self.idExtract).first)))
            let extract = try String(contentsOf: extractURL, encoding: .utf8)
            XCTAssertTrue(extract.contains("id=\(Self.idReader)#block-0"), "the fixture extract should cite block 0")
            try extract.replacingOccurrences(of: "id=\(Self.idReader)#block-0", with: "id=\(Self.idReader)#block-1")
                .write(to: extractURL, atomically: true, encoding: .utf8)
            relaunchWithOneWindow()

            let extractWin = try openExtractsWindow()
            let cell = extractWin.descendants(matching: .any)["an.cell.title.\(Self.idExtract)"]
            XCTAssertTrue(cell.waitForExistence(timeout: 15), "the Extracts window should list the extract")
            cell.click()
            XCTAssertTrue(pollUntil(timeout: 12) { self.editorText(in: extractWin).contains("Moore says") },
                          "the extract should load in the Extracts window")
            XCTAssertTrue(clickStripButton("an.editor.test.jump", timeout: 10, in: extractWin),
                          "the jump seam must be drivable in the Extracts window")

            XCTAssertTrue(pollUntil(timeout: 15) {
                self.editorText(in: self.mainWindow).contains("The lower block's own text.")
            }, "Jump to Source should load the source note in the Note window")
            var scroll: Double?
            XCTAssertTrue(pollUntil(timeout: 10) {
                scroll = self.editorScroll(in: self.mainWindow)
                return (0.3...0.7).contains(scroll ?? -1)
            }, "the Note window should scroll to the cited block half-way down, not to the top or the end — scroll position \(String(describing: scroll))")
            // The scroll position alone cannot tell the block from the paragraphs beside it: its header must be
            // on screen. Polled, so a scroll that lands late is not counted as a miss.
            var shown = (false, "")
            let headerShown = pollUntil(timeout: 5) {
                shown = self.showsBlockHeader(1, in: self.mainWindow)
                return shown.0
            }
            XCTContext.runActivity(named: "W7-S3 scroll: cited header visible = \(headerShown) — \(shown.1)") { _ in }
            shot("W7-S3 jump scrolled to block 1")
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            XCTContext.runActivity(named: "W7-S3 scroll, 2 s later: \(self.showsBlockHeader(1, in: self.mainWindow).1)") { _ in }
            shot("W7-S3 jump scrolled to block 1, 2 s later")
            // W40.fix-notes-jump-scroll-short: the jump used to land several paragraphs short of the block.
            XCTAssertTrue(headerShown, "the cited block's header should be visible in the Note window after the jump — \(shown.1)")
            XCTAssertFalse((statusText(in: mainWindow) ?? "").contains("has changed"),
                           "block 1 exists, so the jump is exact — status: \(statusText(in: mainWindow) ?? "none")")
            closeWindow(extractWin)
        }
    }

    /// Show both kinds in the Note window, select the fixture extract and jump to its source: the Note window
    /// then holds the source note.
    private func jumpFromTheFixtureExtract() throws {
        XCTAssertTrue(setKind(to: "Both", in: mainWindow), "should show both kinds in the Note window")
        selectItem(uuid: Self.idExtract)
        XCTAssertTrue(pollUntil(timeout: 12) { self.editorText(in: self.mainWindow).contains("Moore says") },
                      "the extract should load")
        ensureStyled()
        XCTAssertTrue(jumpFirstPassageViaSeam(), "the jump seam must be drivable")
        XCTAssertTrue(pollUntil(timeout: 15) { self.editorText(in: self.mainWindow).contains("Moore on Intel") },
                      "Jump to Source should load the source note")
        RunLoop.current.run(until: Date().addingTimeInterval(1))   // the scroll outcome posts a turn later
    }

    // MARK: - S4: each window features its kind; Both unions them

    /// The Note window lists notes and not extracts, the Extracts window extracts and not notes, and Both in
    /// the Note window lists the two together. (Launch pins each window's remembered filter to its default,
    /// see `NotesFixtureUITestCase`; the defaults themselves are unit-tested in `NotesNavigationModelTests`.)
    func testS4_EachWindowFeaturesItsKindAndBothUnionsThem() throws {
        try withFixture {
            @MainActor func listed(_ id: String, in win: XCUIElement) -> Bool {
                win.descendants(matching: .any)["an.cell.title.\(id)"].exists
            }
            let notes = [Self.idPlain, Self.idReader, Self.idZotero]
            XCTAssertTrue(pollUntil(timeout: 10) { notes.allSatisfy { listed($0, in: self.mainWindow) } },
                          "the Note window should list every note")
            XCTAssertFalse(listed(Self.idExtract, in: mainWindow), "the Note window should not list the extract")

            let extractWin = try openExtractsWindow()
            XCTAssertTrue(pollUntil(timeout: 15) { listed(Self.idExtract, in: extractWin) },
                          "the Extracts window should list the extract")
            XCTAssertFalse(notes.contains { listed($0, in: extractWin) }, "the Extracts window should list no note")

            frontWindow(named: "Archive Notes")
            XCTAssertTrue(setKind(to: "Both", in: mainWindow), "should switch the Note window to Both")
            XCTAssertTrue(pollUntil(timeout: 15) {
                (notes + [Self.idExtract]).allSatisfy { listed($0, in: self.mainWindow) }
            }, "Both should list the notes and the extract together")
            RunLoop.current.run(until: Date().addingTimeInterval(2))   // a late propagation would show by now
            XCTAssertFalse(notes.contains { listed($0, in: extractWin) },
                           "the Note window's choice must not change the Extracts window's list")
            shot("W7-S4 both kinds")
            closeWindow(extractWin)

            // The choice is remembered per window: relaunched without the harness's kind pins, the Note window
            // comes back on Both and the Extracts window on its untouched default.
            relaunchWithOneWindow(keepingKindPins: false)
            XCTAssertTrue(pollUntil(timeout: 15) {
                (notes + [Self.idExtract]).allSatisfy { listed($0, in: self.mainWindow) }
            }, "the Note window should remember Both across a relaunch")
            let extractWinAgain = try openExtractsWindow()
            XCTAssertTrue(pollUntil(timeout: 15) { listed(Self.idExtract, in: extractWinAgain) },
                          "the Extracts window should still list the extract")
            XCTAssertFalse(notes.contains { listed($0, in: extractWinAgain) },
                           "the Extracts window should keep its own remembered kind")
            shot("W7-S4 both remembered after relaunch")
            closeWindow(extractWinAgain)
        }
    }

    // MARK: - Helpers

    private func editorText(in win: XCUIElement) -> String { (win.textViews["an.editor.text"].value as? String) ?? "" }

    /// Text attachments (images, block chips) appear in the editor's value as U+FFFC.
    private func attachmentCount(_ text: String) -> Int { text.unicodeScalars.filter { $0 == "\u{FFFC}" }.count }

    private func occurrences(of needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }

    /// The editor's vertical scroll position, 0 at the top and 1 at the end (as `StackedLayoutUITests`).
    private func editorScroll(in win: XCUIElement) -> Double? {
        let bar = win.scrollViews.containing(.textView, identifier: "an.editor.text").firstMatch.scrollBars.firstMatch
        guard bar.exists else { return nil }
        if let n = bar.value as? NSNumber { return n.doubleValue }
        return (bar.value as? String).flatMap(Double.init)
    }

    /// The `inlineImages` entry of the chip-geometry probe (`EditorTextView.uiTestInlineImages`), as
    /// `NotesE2PasteTests` reads it: one entry per inline image, with its `ref` and whether a placeholder is shown.
    private func inlineImages() -> [[String: Any]] {
        chipProbe(in: mainWindow).compactMap { $0["inlineImages"] as? [[String: Any]] }.first ?? []
    }

    private func chipProbe(in win: XCUIElement) -> [[String: Any]] {
        let probe = win.descendants(matching: .any)["an.editor.test.chipGeometry"]
        guard probe.exists, let raw = probe.value as? String, let data = raw.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return entries
    }

    /// Whether the editor shows the header of its `index`-th source block (0-based, in text order): the header's
    /// laid-out y, from the probe's header slots, lies inside the editor's visible rect. Also returns the figures.
    private func showsBlockHeader(_ index: Int, in win: XCUIElement) -> (Bool, String) {
        let entries = chipProbe(in: win)
        let slots = entries.filter { $0["loc"] != nil && $0["sourceID"] != nil }
            .sorted { ($0["loc"] as? Int ?? 0) < ($1["loc"] as? Int ?? 0) }
        let rect = entries.first { $0["editorVisibleY"] != nil }
        guard index < slots.count, let y = slots[index]["slotY"] as? Double,
              let top = rect?["editorVisibleY"] as? Double, let height = rect?["editorVisibleH"] as? Double
        else { return (false, "slots \(slots), visible rect \(String(describing: rect))") }
        // What is drawn at the top of the view, by character offset: the slots' y alone once disagreed with the
        // screenshot (W40.fix-notes-jump-scroll-short).
        let loc = slots[index]["loc"] as? Int ?? -1
        let topChar = rect?["editorTopChar"] as? Int
        let text = editorText(in: win) as NSString
        let bottomChar = rect?["editorBottomChar"] as? Int
        let topLine = topChar.flatMap { $0 < text.length ? text.substring(from: $0).components(separatedBy: "\n").first : nil }
        // Drawn: the paragraphs at the top and bottom of the view bracket the header's character.
        let drawn = topChar.map { $0 <= loc } == true && bottomChar.map { loc <= $0 } == true
        return (y >= top && y < top + height && drawn,
                "header y \(y) at char \(loc), visible \(top)…\(top + height); paragraphs drawn from char "
                + "\(topChar.map(String.init) ?? "?") (y \(rect?["editorTopFragY"] ?? "?"), \"\(topLine ?? "?")\") to char "
                + "\(bottomChar.map(String.init) ?? "?"); viewport chars \(rect?["viewportStart"] ?? "?")…\(rect?["viewportEnd"] ?? "?"); "
                + "scrolls \(rect?["blockScroll"] ?? "?")")
    }

    /// The editor draws `assets/<name>` from its own bytes: present, and not the Missing or Blocked placeholder.
    private func showsLoadedImage(named name: String) -> Bool {
        inlineImages().contains { ($0["ref"] as? String) == "assets/\(name)" && ($0["placeholder"] as? Bool) == false }
    }

    private func statusText(in win: XCUIElement) -> String? {
        let texts = win.staticTexts.matching(identifier: "an.sidebar.status")
            .allElementsBoundByIndex.map { ($0.value as? String) ?? $0.label }.filter { !$0.isEmpty }
        return texts.isEmpty ? nil : texts.joined(separator: " ")
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: mainWindow.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func clickMenu(_ menu: String, _ item: String) {
        app.activate()
        let bar = app.menuBars.menuBarItems[menu]
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "the \(menu) menu should exist")
        bar.click()
        let entry = app.menuItems[item]
        XCTAssertTrue(entry.waitForExistence(timeout: 3), "\(menu) ▸ \(item) should be offered")
        entry.click()
    }

    /// Switch the `an.filter.kind` segmented control (as `NotesGUITests.setKind`).
    @discardableResult
    private func setKind(to segment: String, in win: XCUIElement) -> Bool {
        let control = win.descendants(matching: .any)["an.filter.kind"]
        guard control.waitForExistence(timeout: 10) else { return false }
        for el in [control.buttons[segment], control.radioButtons[segment], control.descendants(matching: .any)[segment]]
        where el.waitForExistence(timeout: 2) {
            _ = pollUntil(timeout: 4) { self.app.activate(); return el.isHittable }
            if el.isHittable { el.click(); return true }
        }
        let index = ["Notes": 0, "Extracts": 1, "Both": 2][segment] ?? 2
        control.coordinate(withNormalizedOffset: CGVector(dx: (Double(index) + 0.5) / 3.0, dy: 0.5)).tap()
        return true
    }

    /// Front a `Window` scene by name through the Window menu (the two windows open one pixel apart, so a
    /// click aimed at the lower one lands on the upper; see `NotesGUITests.frontWindow`).
    private func frontWindow(named title: String) {
        clickMenu("Window", title)
    }

    private func openExtractsWindow() throws -> XCUIElement {
        let win = app.windows["Extracts"]
        if !win.exists { clickMenu("Window", "Extracts") }
        XCTAssertTrue(win.waitForExistence(timeout: 15), "the Extracts window should be open")
        return win
    }

    private func closeWindow(_ win: XCUIElement) {
        guard win.exists else { return }
        let close = win.buttons[XCUIIdentifierCloseWindow]
        if close.waitForExistence(timeout: 5), close.isHittable { close.click() }
        _ = pollUntil(timeout: 5) { !win.exists }
    }

    /// Quit and relaunch with the same arguments (the fixture is NOT restored), then close the Extracts window
    /// if the relaunch reopened it, as `setUp` does, so the Note window's controls are not covered. With
    /// `keepingKindPins: false` the harness's per-window kind-filter pins are dropped, so the app reads the
    /// choices it remembered in its own defaults.
    private func relaunchWithOneWindow(keepingKindPins: Bool = true) {
        if app.state != .notRunning { app.terminate() }
        if !keepingKindPins {
            for key in ["-an.noteWindow.kindFilter", "-an.extractWindow.kindFilter"] {
                if let i = app.launchArguments.firstIndex(of: key) {
                    app.launchArguments.removeSubrange(i...min(i + 1, app.launchArguments.count - 1))
                }
            }
        }
        app.launch()
        app.activate()
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 15), "the window should come back after relaunch")
        let extractWin = app.windows["Extracts"]
        if extractWin.waitForExistence(timeout: 8) {
            frontWindow(named: "Extracts")
            closeWindow(extractWin)
        }
        let seed = mainWindow.descendants(matching: .any)["an.cell.title.\(Self.idPlain)"]
        XCTAssertTrue(seed.waitForExistence(timeout: 25), "the list should repopulate after relaunch")
    }
}
