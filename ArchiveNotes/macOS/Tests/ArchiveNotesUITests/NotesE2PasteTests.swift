import XCTest
import AppKit   // NSPasteboard — seed the PNG and the archive link the app pastes

/// W9.e2-paste — the paste-and-extracts part of the gap-closure runtime sweep (plan E2, record in `SUITE_TODO_DONE.md`):
/// a menu-created extract embeds its image bytes (B6), a root Notes holds no grant for re-grants in-app
/// from the preview popover (B7), and a page link pasted once the root is granted shows a thumbnail that
/// really drew. Source-block paste itself is G5 and the freshly pasted note-passage chip is G13.
///
/// The NSOpenPanel is the one step no XCUITest can drive, so `-ANUITestRootPickPath` stands in for the
/// folder a person would pick (`SourceBlockPreviewState`); the marker check, bookmark and re-resolve after
/// it are the production path. Under the harness, grants live in a suite emptied on every launch, so each
/// test starts with no archive granted.
final class NotesE2PasteTests: NotesFixtureUITestCase {

    /// Where the tests move the fixture's embedded Reader corpus before granting it. The link names the
    /// root by GUID, so the move is invisible to it; only the marker in the picked folder says it is the
    /// same archive.
    private static var movedCorpusPath: String { fixturePath + "/reader-corpus-moved" }

    override var extraLaunchArguments: [String] { ["-ANUITestRootPickPath", Self.movedCorpusPath] }

    /// B6 — Extract ▸ Create Extract on a selection holding an inline image copies the image's BYTES into
    /// the new extract's own `assets/`, and leaves the source note's assets as they were.
    func testE2_MenuCreatedExtractEmbedsTheImageBytes() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            let source = Self.idPlain
            selectItem(uuid: source)
            XCTAssertTrue(pollUntil(timeout: 10) { self.editorText.contains("A plain note") },
                          "the plain note should load before the image is pasted")
            ensureStyled()

            let png = try XCTUnwrap(Self.makePNGData(width: 16, height: 16))
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.setData(png, forType: .png))
            XCTAssertTrue(setEditorSelection(location: 0, length: 0))
            XCTAssertTrue(pasteImageViaSeam(), "the image-paste seam must be drivable")
            let outcome = pasteImageOutcome()
            XCTAssertTrue(outcome.hasPrefix("ok "), "the image paste should be handled — got \(outcome)")
            var sourceAsset: String?
            XCTAssertTrue(pollUntil(timeout: 10) {
                sourceAsset = self.assetFiles(inItemDir: source).first { $0.hasPrefix("pasted-") }
                return sourceAsset != nil
                    && (self.rawMarkdown(inItemDir: source) ?? "").contains("](assets/\(sourceAsset!))")
            }, "the pasted image should be on disk and referenced by the note — paste said \(outcome)")
            let assetName = try XCTUnwrap(sourceAsset)
            let sourceBytes = try Data(contentsOf: URL(fileURLWithPath: "\(itemsDir)/\(source)/assets/\(assetName)"))
            let sourceAssetsBefore = Set(assetFiles(inItemDir: source))

            let before = itemDirs()
            XCTAssertTrue(setEditorSelection(location: 0, length: 100_000), "select the whole note, image included")
            app.activate()
            app.menuBars.menuBarItems["Extract"].click()
            let create = app.menuBars.menuItems["Create Extract"]
            XCTAssertTrue(create.waitForExistence(timeout: 5), "Extract ▸ Create Extract should be present")
            create.click()

            var extract: String?
            XCTAssertTrue(pollUntil(timeout: 15) {
                extract = self.itemDirs().subtracting(before)
                    .first { (self.rawMarkdown(inItemDir: $0) ?? "").contains("kind: extract") }
                return extract != nil
            }, "Extract ▸ Create Extract should mint a kind: extract item")
            let extractID = try XCTUnwrap(extract)
            var copied: String?
            XCTAssertTrue(pollUntil(timeout: 10) {
                copied = self.assetFiles(inItemDir: extractID).first { name in
                    (try? Data(contentsOf: URL(fileURLWithPath: "\(self.itemsDir)/\(extractID)/assets/\(name)")))
                        == sourceBytes
                }
                return copied != nil
            }, "the extract's own assets/ should hold the image bytes — has \(assetFiles(inItemDir: extractID))")
            let markdown = rawMarkdown(inItemDir: extractID) ?? ""
            XCTAssertTrue(markdown.contains("](assets/\(copied ?? "?"))"),
                          "the extract should reference its own copy, not the source's: \(markdown)")
            XCTAssertTrue(markdown.contains("archivenotes://open?id=\(source)"),
                          "the extract's passage block should link back to the source note")
            XCTAssertEqual(Set(assetFiles(inItemDir: source)), sourceAssetsBefore,
                           "creating the extract must not add or remove anything in the source note's assets/")
        }
    }

    /// B7 — with the archive moved and no grant held, the preview popover asks for the folder, and choosing
    /// it from the popover re-resolves the link there: the popover then shows the PDF.
    func testE2_MovedArchiveReGrantsFromThePreviewPopover() throws {
        try withFixture {
            try moveCorpus()
            selectItem(uuid: Self.idReader)
            XCTAssertTrue(pollUntil(timeout: 10) { self.editorText.contains("egalitarian") },
                          "the reader note should load before its source is previewed")
            ensureStyled()

            XCTAssertTrue(clickStripButton("an.editor.test.preview", timeout: 10),
                          "the preview seam must be drivable (an.editor.test.preview)")
            let grant = app.popovers.buttons["Choose Archive Folder\u{2026}"]
            XCTAssertTrue(grant.waitForExistence(timeout: 10),
                          "with no grant held, the preview should offer to choose the archive folder")
            XCTAssertTrue(app.popovers.staticTexts.containing(
                NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@",
                            "has not been given access", "has not been given access")
            ).firstMatch.exists, "the popover should say Notes has no access to this archive")
            attachScreenshot(named: "W9.e2-paste needsRootGrant popover")
            grant.click()

            let fileName = app.popovers.staticTexts["sample.pdf"]
            XCTAssertTrue(fileName.waitForExistence(timeout: 15),
                          "after choosing the moved folder the popover should show the linked PDF")
            attachScreenshot(named: "W9.e2-paste resolved preview after re-grant")
            app.typeKey(.escape, modifierFlags: [])
        }
    }

    /// The thumbnail half: grant the moved archive from File ▸ Choose Archive Folder…, paste a page link
    /// whose payload carries no image, and the source block gains a rendered page thumbnail — an asset on
    /// disk and an inline image in the editor whose pixels are the page's dark text, not a placeholder.
    func testE2_PastedPageLinkShowsARenderedThumbnail() throws {
        try withFixture {
            try moveCorpus()
            app.activate()
            app.menuBars.menuBarItems["File"].click()
            let choose = app.menuBars.menuItems["Choose Archive Folder\u{2026}"]
            XCTAssertTrue(choose.waitForExistence(timeout: 5), "File ▸ Choose Archive Folder… should be present")
            choose.click()
            let ready = app.dialogs.staticTexts["Archive folder ready"].firstMatch
            let readyAnywhere = app.staticTexts["Archive folder ready"].firstMatch
            XCTAssertTrue(pollUntil(timeout: 10) { ready.exists || readyAnywhere.exists },
                          "granting the moved folder should be confirmed")
            app.buttons["OK"].firstMatch.click()

            let note = Self.idPlain
            selectItem(uuid: note)
            XCTAssertTrue(pollUntil(timeout: 10) { self.editorText.contains("A plain note") },
                          "the plain note should load before the link is pasted")
            ensureStyled()
            let assetsBefore = Set(assetFiles(inItemDir: note))

            let link = "archivereader://reveal?root=\(Self.corpusRootGUID)&rel=sample.pdf&jpeg=&page=2"
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.setString(link, forType: .string))
            XCTAssertTrue(setEditorSelection(location: 0, length: 0))
            app.activate()
            app.menuBars.menuBarItems["Edit"].click()
            let paste = app.menuBars.menuItems["Paste as Source Block(s)"]
            XCTAssertTrue(paste.waitForExistence(timeout: 5))
            paste.click()

            var thumb: String?
            XCTAssertTrue(pollUntil(timeout: 20) {
                thumb = Set(self.assetFiles(inItemDir: note)).subtracting(assetsBefore)
                    .first { $0.hasPrefix("p2-thumb") }
                return thumb != nil
            }, "the pasted page link should gain a rendered p2 thumbnail asset — has \(assetFiles(inItemDir: note))")
            let thumbName = try XCTUnwrap(thumb)
            XCTAssertTrue(pollUntil(timeout: 10) {
                let md = self.rawMarkdown(inItemDir: note) ?? ""
                return md.contains("block: reader-page") && md.contains("](assets/\(thumbName))")
            }, "the saved source block should carry its thumbnail line: \(rawMarkdown(inItemDir: note) ?? "")")
            XCTAssertFalse(editorText.contains("<!-- block:"), "the pasted source block should render as a chip")

            var image: [String: Any]?
            XCTAssertTrue(pollUntil(timeout: 10) {
                image = self.inlineImages().first { ($0["ref"] as? String) == "assets/\(thumbName)" }
                return image?["placeholder"] as? Bool == false
            }, "the editor should show the thumbnail's loaded bytes, not a placeholder: \(inlineImages())")
            let dark = image?["darkPixels"] as? Int ?? 0
            XCTAssertGreaterThan(dark, 50, "the thumbnail should show the page's text, not a blank image: \(image ?? [:])")
            attachScreenshot(named: "W9.e2-paste pasted page link with thumbnail")
        }
    }

    // MARK: - Helpers

    private var editorText: String { (editor.value as? String) ?? "" }

    /// Move the fixture's embedded Reader corpus to `movedCorpusPath`. The fixture is restored from its
    /// pristine snapshot before every test, so the next test finds it where it was.
    private func moveCorpus() throws {
        try requireCanonicalScratchFixtureForStoreWrites()
        try FileManager.default.moveItem(atPath: Self.fixturePath + "/reader-corpus", toPath: Self.movedCorpusPath)
    }

    /// The `inlineImages` entry of the chip-geometry probe (`EditorTextView.uiTestInlineImages`).
    private func inlineImages() -> [[String: Any]] {
        let probe = mainWindow.descendants(matching: .any)["an.editor.test.chipGeometry"]
        guard let json = probe.value as? String, let data = json.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return entries.compactMap { $0["inlineImages"] as? [[String: Any]] }.first ?? []
    }

    private func attachScreenshot(named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
