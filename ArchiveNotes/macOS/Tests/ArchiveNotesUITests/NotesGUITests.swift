import XCTest
import AppKit   // NSPasteboard — seed the general pasteboard for the source-block paste check (G5)
import Darwin   // getpwuid / getuid — resolve the REAL home from the password DB

/// Base class for the per-wave Archive Notes GUI checks (08-testing §3.7, W8-S8).
///
/// Mirrors the shipped Reader harness base (`ArchiveReaderUITests/FixtureUITestCase`): launches the
/// app against the pre-built SCRATCH fixture at
/// `~/Library/Application Support/ArchiveNotes/AN-GUI-Fixture` via the DEBUG `-ANUITestStorePath`
/// override (`RootFolderStore.adoptTestStore` — sets the store root IN-MEMORY ONLY; never persists
/// `notesStoreRootBookmark`, never touches the real store). If the fixture directory is absent, every
/// test in the subclass is skipped (build `scripts/make-notes-fixture.sh` first) — so a bare
/// `build-for-testing` stays green and no launch ever opens the owner's real store.
///
/// `@MainActor` because XCUIApplication / XCUIElement are main-actor-isolated in the Swift 6 SDK;
/// UI tests drive the UI and belong on the main actor (matches `SmokeUITest`). Subclasses inherit it.
@MainActor
class NotesFixtureUITestCase: XCTestCase {

    /// Absolute path to the pre-built GUI fixture, resolved against the REAL home (getpwuid) — the
    /// sandboxed runner's `homeDirectoryForCurrentUser` points at its container, not the real `~/`
    /// where `make-notes-fixture.sh` writes the fixture (the pitfall that skipped the Reader Wave-7
    /// harness). The Debug-only Route-B temporary-exception entitlement grants read of `/Users/`, so
    /// both this `fileExists` check and the app's own read of the launch-arg path succeed.
    static let fixturePath: String = {
        if let override = ProcessInfo.processInfo.environment["AN_GUI_FIXTURE_PATH"], !override.isEmpty {
            return override
        }
        let realHome: String
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            realHome = String(cString: dir)
        } else {
            realHome = FileManager.default.homeDirectoryForCurrentUser.path
        }
        return "\(realHome)/Library/Application Support/ArchiveNotes/AN-GUI-Fixture"
    }()

    // Fixed fixture item UUIDs (match make-notes-fixture.sh).
    static let idPlain   = "11111111-1111-1111-1111-111111111111"  // plain note, carries `#`/`**` Markdown
    static let idReader  = "22222222-2222-2222-2222-222222222222"  // the reader-page source-block note
    static let idZotero  = "33333333-3333-3333-3333-333333333333"  // the Zotero-chip note (a kind:note)
    static let idExtract = "44444444-4444-4444-4444-444444444444"  // the extract with a note-passage block
    // The embedded scratch Reader corpus root GUID (durable links resolve under it).
    static let corpusRootGUID = "c07b0700-2000-4000-8000-000000000002"

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Self.fixturePath),
            "GUI fixture not found — run scripts/make-notes-fixture.sh first"
        )

        app = XCUIApplication()
        app.launchArguments += ["-ANUITestStorePath", Self.fixturePath]
        app.launch()
        app.activate()

        let window = app.windows["Archive Notes"]
        XCTAssertTrue(window.waitForExistence(timeout: 15), "Main window should appear")

        // Readiness gate: the list populates from disk (NotesModel.buildIndexFromDisk enumerates
        // items/**/*.md — not Spotlight), so wait for a KNOWN seeded row to appear. This is the
        // reliable gate; the hidden `an.status.indexReady` probe (§3.4) is verified separately by
        // `waitForIndexReady` (its 1×1 clear-color queryability was flagged UNVERIFIED at W8-S7).
        let seed = app.descendants(matching: .any)["an.cell.title.\(Self.idPlain)"]
        XCTAssertTrue(seed.waitForExistence(timeout: 25), "a seeded note row should populate the list")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    // MARK: - Fixture lifecycle
    //
    // The scratch fixture is (re)built EXTERNALLY by `scripts/make-notes-fixture.sh` before each GUI run
    // (the session/daemon that runs this suite does so) — mirroring the Reader harness, which likewise
    // assumes a pre-built fixture. The UITest *runner* is granted only READ of `/Users/` (the RW
    // temporary-exception entitlement is on the app-under-test, NOT the runner), so a test CANNOT delete
    // the items it creates. Creating checks (G1 note, G9 extract) therefore leave their new item behind
    // within a run; every assertion tolerates that by subtracting a pre-test `itemDirs()` snapshot, so a
    // dirty fixture never changes a result. The next pre-run rebuild returns the fixture to 4 items.

    // MARK: - Elements

    /// The virtualized item table (the AppKit `NSTableView`, id `an.table`; the SwiftUI wrapper carries
    /// `an.list.table`). Prefer the concrete table, fall back to the first table in the window.
    var table: XCUIElement {
        let byID = app.tables["an.table"]
        return byID.exists ? byID : app.tables.firstMatch
    }

    /// The hidden index-ready probe (§3.4). A 1×1 clear a11y element; its value is the generation token
    /// once the initial build settles.
    var indexReadyProbe: XCUIElement { app.descendants(matching: .any)["an.status.indexReady"] }

    /// The main editor NSTextView (id `an.editor.text`). Its `.value` is the current editor string —
    /// in styled mode block headers render as chips (no literal `<!-- block: -->`); in raw mode the
    /// literal Markdown source is shown.
    var editor: XCUIElement { app.textViews["an.editor.text"] }

    /// The raw/styled toggle (borderless Button, id `an.editor.rawToggle`).
    var rawToggle: XCUIElement { app.descendants(matching: .any)["an.editor.rawToggle"] }

    // MARK: - Readiness / polling helpers

    /// Poll `condition` until true or `timeout` elapses; returns the final value. Pumps the run loop so
    /// the app makes progress. (XCUITest expectations can't observe app-internal async state, so poll.)
    @discardableResult
    func pollUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    /// Wait until the index-ready probe publishes a non-empty generation token.
    @discardableResult
    func waitForIndexReady(timeout: TimeInterval) -> Bool {
        _ = indexReadyProbe.waitForExistence(timeout: min(timeout, 10))
        return pollUntil(timeout: timeout) {
            if let v = indexReadyProbe.value as? String, !v.isEmpty { return true }
            return false
        }
    }

    /// Click a row's title cell (id `an.cell.title.<uuid>`) to select that item. Brings the app forward
    /// and waits for hittability first (another app briefly holding window-server focus makes an
    /// on-screen element report "not hittable"), with a coordinate tap as a last resort.
    @discardableResult
    func selectItem(uuid: String, timeout: TimeInterval = 15) -> XCUIElement {
        app.activate()
        let cell = app.descendants(matching: .any)["an.cell.title.\(uuid)"]
        XCTAssertTrue(cell.waitForExistence(timeout: timeout), "Title cell for \(uuid) should exist")
        _ = pollUntil(timeout: timeout) { app.activate(); return cell.isHittable }
        if cell.isHittable {
            cell.click()
        } else {
            cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        return cell
    }

    // MARK: - Disk helpers (fixture is scratch; Route-B grants the runner read of /Users/)

    var itemsDir: String { Self.fixturePath + "/items" }

    /// The set of `items/<uuid>` subdirectory names currently on disk.
    func itemDirs() -> Set<String> {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: itemsDir)) ?? []
        return Set(entries.filter { !$0.hasPrefix(".") })
    }

    /// The `.md` filenames inside a given `items/<uuid>` directory.
    func mdFiles(inItemDir dir: String) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: itemsDir + "/" + dir)) ?? []
        return entries.filter { $0.hasSuffix(".md") }
    }

    /// The on-disk body of the fixture item `uuid` (everything after the YAML front-matter close), or
    /// nil if the item / its `.md` can't be read. Used for lossless (body-unchanged) assertions that
    /// are robust to a `modified:` timestamp bump.
    func noteBody(uuid: String) -> String? {
        let dir = itemsDir + "/" + uuid
        guard let md = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .first(where: { $0.hasSuffix(".md") }),
              let text = try? String(contentsOfFile: dir + "/" + md, encoding: .utf8)
        else { return nil }
        // Front matter is a leading `---\n … \n---\n`; the body is what follows the SECOND `---`.
        guard text.hasPrefix("---") else { return text }
        let lines = text.components(separatedBy: "\n")
        var seenClose = false
        var bodyLines: [String] = []
        var idx = 0
        for (i, line) in lines.enumerated() where i > 0 {   // skip the opening `---`
            if !seenClose {
                if line == "---" { seenClose = true; idx = i }
            } else {
                bodyLines.append(line)
            }
        }
        _ = idx
        return seenClose ? bodyLines.joined(separator: "\n") : text
    }

    /// The full raw `.md` text (front-matter + body) of the first note file inside `items/<dir>`, or nil.
    /// Unlike `noteBody`, this keeps the YAML front-matter so a check can assert on `kind:` etc.
    func rawMarkdown(inItemDir dir: String) -> String? {
        let d = itemsDir + "/" + dir
        guard let md = ((try? FileManager.default.contentsOfDirectory(atPath: d)) ?? [])
            .first(where: { $0.hasSuffix(".md") }) else { return nil }
        return try? String(contentsOfFile: d + "/" + md, encoding: .utf8)
    }

    // MARK: - DEBUG editor test seam (W8-S7 §3.3; drives the styled NSTextView XCUITest can't focus)

    /// Set the editor's selected range via the hidden DEBUG control strip
    /// (`an.editor.test.selectionInput` + `an.editor.test.select`) — XCUITest can't reliably place a
    /// caret selection inside the styled NSTextView, so the strip drives it through `testBox`. Returns
    /// false if the strip isn't present/hittable (which would itself be the finding to fix).
    @discardableResult
    func setEditorSelection(location: Int, length: Int, timeout: TimeInterval = 10) -> Bool {
        let field = app.descendants(matching: .any)["an.editor.test.selectionInput"]
        let button = app.descendants(matching: .any)["an.editor.test.select"]
        guard field.waitForExistence(timeout: timeout),
              button.waitForExistence(timeout: timeout) else { return false }
        _ = pollUntil(timeout: timeout) { app.activate(); return field.isHittable }
        guard field.isHittable else { return false }
        field.click()
        field.typeText("\(location),\(length)")
        // Clicking the button ends editing in the field (commits the binding via focus-loss) BEFORE the
        // button action reads `testSelectionInput`, so no explicit commit keystroke is needed.
        guard button.isHittable else { return false }
        button.click()
        return true
    }
}

/// Per-wave GUI checks (08-testing §3.7). Landed incrementally (W8-S8 is oversized — see the plan
/// Session Log + Morning Review): pass 1 = G1 (create) + G3 (raw toggle); pass 2 = G9 (create extract
/// from a note selection, first use of the DEBUG selection seam `an.editor.test.select`); this pass
/// adds G5 (paste archive links as a source block via ⌘⇧V). Still to land: G7/G8 (folder replicate /
/// delete-last-instance) under XCUITest — these need the org-graph folders loaded, which is blocked by
/// the INDEX-DB caveat: the org graph loads DB-first from the app *container's* `notes-index-v1.sqlite3`
/// (survives across launches, never reset), so the fixture's `organization.json` is shadowed unless the
/// app launches against a fresh container. Making them deterministic needs a DEBUG seam that redirects
/// the index DB into the fixture under `-ANUITestStorePath` (so the container is never polluted and the
/// fixture's `organization.json` loads fresh) — recorded for the next session. Then the cliclick checks
/// G4/G6/G10/G11.
@MainActor
final class NotesGUITests: NotesFixtureUITestCase {

    /// G1 — Create a note (⌘N / the New menu) → a new `items/<uuid>/<Title>.md` appears on disk.
    func testG1_CreateNoteWritesNewItemFile() throws {
        let before = itemDirs()
        XCTAssertGreaterThanOrEqual(before.count, 4, "fixture should have its seeded notes")

        // Primary path: ⌘N (the New-menu button carries `.keyboardShortcut("n", .command)`).
        app.activate()
        app.typeKey("n", modifierFlags: .command)

        func newDirsWithMD() -> [String] {
            itemDirs().subtracting(before).filter { !mdFiles(inItemDir: $0).isEmpty }
        }
        var created = pollUntil(timeout: 6) { !newDirsWithMD().isEmpty }

        // Fallback: drive the toolbar New menu explicitly if ⌘N didn't register.
        if !created {
            let newMenu = app.descendants(matching: .any)["an.toolbar.new"]
            if newMenu.waitForExistence(timeout: 5) {
                newMenu.click()
                let item = app.menuItems["New Note"]
                if item.waitForExistence(timeout: 3) { item.click() }
            }
            created = pollUntil(timeout: 10) { !newDirsWithMD().isEmpty }
        }

        let newDirs = newDirsWithMD()
        XCTAssertTrue(created, "a new note should be created (⌘N or the New menu)")
        XCTAssertEqual(newDirs.count, 1, "exactly one new item directory should appear on disk")
        if let dir = newDirs.first {
            XCTAssertFalse(mdFiles(inItemDir: dir).isEmpty, "the new item directory should contain a .md file")
            // (Left on disk — the runner can't delete it; wiped by the next pre-run fixture rebuild.)
        }
    }

    /// G3 — Toggle raw Markdown: raw mode shows the literal `.md` source; toggling back is lossless
    /// (the note's on-disk body is unchanged). Detects raw vs styled by the editor content — the
    /// literal `**bold**` Markdown is present as text only in raw mode (rendered as a bold run, with no
    /// asterisks, in styled mode) — since the toggle itself is a stateless icon button. Uses the plain
    /// note (no source-block chip): a chip's durable-link/thumbnail render is a separate check (G5/G6).
    func testG3_RawMarkdownToggleShowsSourceAndIsLossless() throws {
        let uuid = Self.idPlain
        let bodyBefore = noteBody(uuid: uuid)
        XCTAssertNotNil(bodyBefore, "should read the plain note body off disk")
        XCTAssertEqual(bodyBefore?.contains("**bold**"), true, "fixture plain note should carry `**bold**`")

        selectItem(uuid: uuid)

        // Editor loads the selected item's body (load-on-select). Wait for non-empty content.
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "editor text view should exist")
        _ = pollUntil(timeout: 10) { !((editor.value as? String) ?? "").isEmpty }

        let styledValue = (editor.value as? String) ?? ""
        XCTAssertFalse(
            styledValue.contains("**bold**"),
            "in styled mode `**bold**` renders as a bold run, not literal asterisks (got: \(styledValue))"
        )

        // Toggle → raw. The literal Markdown source should now appear in the editor text.
        XCTAssertTrue(rawToggle.waitForExistence(timeout: 5), "raw toggle should exist")
        rawToggle.click()
        let sawRawSource = pollUntil(timeout: 6) {
            ((editor.value as? String) ?? "").contains("**bold**")
        }
        XCTAssertTrue(sawRawSource, "raw mode should show the literal Markdown source (`**bold**`)")

        // Toggle → styled again; the literal source should disappear (round-trip works).
        rawToggle.click()
        let backToStyled = pollUntil(timeout: 6) {
            !(((editor.value as? String) ?? "").contains("**bold**"))
        }
        XCTAssertTrue(backToStyled, "toggling back should return to styled mode")

        // Lossless (semantic): toggling display mode flushes a write-back (switchMode flushes pending
        // edits), and the Markdown serializer canonicalizes whitespace — it collapses the blank line
        // after an ATX heading and drops the trailing newline, both semantically identical (no content
        // lost). So assert the meaningful content survives (whitespace-normalized equality) and nothing
        // was dropped, rather than byte-for-byte. (The whitespace canonicalization on a view-only toggle
        // is noted as a minor finding — see the plan Session Log / Morning Review.)
        _ = pollUntil(timeout: 2) { false }
        let bodyAfter = noteBody(uuid: uuid)
        func normalized(_ s: String?) -> String? {
            s?.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).joined(separator: " ")
        }
        XCTAssertEqual(normalized(bodyAfter), normalized(bodyBefore),
                       "raw/styled toggle must preserve the note body content (whitespace may canonicalize)")
        XCTAssertEqual(bodyAfter?.contains("**bold**"), true, "the bold source must survive the round-trip")
        XCTAssertEqual(bodyAfter?.contains("# Plain Note"), true, "the heading source must survive the round-trip")
    }

    /// G5 — Paste archive links as a source block (Edit ▸ Paste as Source Block(s), ⌘⇧V). Seeds the
    /// general pasteboard with a plain-text `archivereader://reveal?…` URL (the paster's plain-text
    /// fallback — no custom UTI needed, and `NSPasteboard.general` is settable cross-process from the
    /// test runner) and pastes it into a note editor, asserting the note's on-disk `.md` gains a
    /// `<!-- block: reader-page … -->` provenance block that preserves the durable link.
    ///
    /// Target = the Zotero note (`idZotero`, a real `kind: note`): the paster DECLINES a Reader link
    /// pasted into an *extract* (§D7, `handleSourceBlockPaste`), and no other XCUITest check depends on
    /// this note's body (the cliclick G11 Zotero check runs against a freshly-rebuilt fixture). The
    /// paste also requires STYLED mode (`handleSourceBlockPaste` guards `!currentIsRaw`), so we ensure
    /// styled first. The added block is additive; the note is left dirty and wiped by the next pre-run
    /// fixture rebuild. Disk-asserted, so it's independent of the org-graph / INDEX-DB caveat.
    func testG5_PasteArchiveLinkAsSourceBlockWritesReaderPageBlock() throws {
        let uuid = Self.idZotero
        let bodyBefore = rawMarkdown(inItemDir: uuid) ?? ""
        XCTAssertFalse(bodyBefore.isEmpty, "should read the Zotero note off disk")
        XCTAssertFalse(bodyBefore.contains("block: reader-page"),
                       "the Zotero fixture note should start without a reader-page block")

        // The durable link to paste — resolves under the embedded scratch Reader corpus. `page` present
        // → the paster classifies it as a `.readerPage` block.
        let link = "archivereader://reveal?root=\(Self.corpusRootGUID)&rel=sample.pdf&page=2"

        func blockOnDisk() -> Bool { (rawMarkdown(inItemDir: uuid) ?? "").contains("block: reader-page") }

        // One paste attempt: (re)select the target, ensure STYLED mode, seed the pasteboard, place a
        // caret, fire the trigger, then flush the editor write-back to disk by selecting another item
        // (select() flushes the outgoing editor inline — W7-S6) and poll disk.
        func attempt(_ trigger: () -> Void) -> Bool {
            selectItem(uuid: uuid)
            XCTAssertTrue(editor.waitForExistence(timeout: 10), "editor text view should exist")
            _ = pollUntil(timeout: 10) { !((editor.value as? String) ?? "").isEmpty }

            // Ensure styled: in RAW mode the editor shows the literal `zotero://select…` header source;
            // that never appears in styled mode (it renders as a chip). Toggle back to styled if raw.
            if ((editor.value as? String) ?? "").contains("zotero://select") {
                rawToggle.click()
                _ = pollUntil(timeout: 5) { !(((editor.value as? String) ?? "").contains("zotero://select")) }
            }

            let pb = NSPasteboard.general
            pb.clearContents()
            XCTAssertTrue(pb.setString(link, forType: .string), "should seed the pasteboard with the link")

            _ = setEditorSelection(location: 0, length: 0)   // defined caret at the start
            trigger()

            var ok = pollUntil(timeout: 4) { blockOnDisk() }
            if !ok {
                selectItem(uuid: Self.idPlain)               // flush idZotero's pending write-back
                ok = pollUntil(timeout: 6) { blockOnDisk() }
            }
            return ok
        }

        // Primary: ⌘⇧V. Fallback: the Edit-menu item (title-located, Reader-harness parity).
        var wrote = attempt { app.activate(); app.typeKey("v", modifierFlags: [.command, .shift]) }
        if !wrote {
            wrote = attempt {
                let editMenu = app.menuBars.menuBarItems["Edit"]
                if editMenu.waitForExistence(timeout: 5) {
                    editMenu.click()
                    let item = app.menuItems["Paste as Source Block(s)"]
                    if item.waitForExistence(timeout: 3) { item.click() }
                }
            }
        }

        XCTAssertTrue(wrote, "⌘⇧V / Edit ▸ Paste as Source Block(s) should insert a reader-page block")
        let bodyAfter = rawMarkdown(inItemDir: uuid) ?? ""
        XCTAssertTrue(bodyAfter.contains("block: reader-page"),
                      "the note should carry a reader-page provenance block after the paste")
        XCTAssertTrue(bodyAfter.contains("archivereader://reveal?root=\(Self.corpusRootGUID)"),
                      "the pasted block should preserve the durable reader link")
        // The pre-existing zotero-item block must survive (paste is additive, not a replace).
        XCTAssertTrue(bodyAfter.contains("block: zotero-item"),
                      "the paste must be additive — the note's original zotero-item block should remain")
    }

    /// G9 — Create an extract from a note selection (Extract ▸ Create Extract, ⌘⌥E). Selecting text in a
    /// note and minting an extract must write a NEW `kind: extract` item whose body carries a
    /// `note-passage` provenance block linking back to the source note (00-overview §7; W7-S2). The
    /// model path is already unit-covered (`ExtractCommandTests`); this drives it end-to-end through the
    /// live UI. Uses the DEBUG selection seam (`an.editor.test.select`) because XCUITest can't reliably
    /// place a caret selection in the styled NSTextView. Disk-asserted (like G1); the source note is the
    /// plain note (a real `.note`, so the extract-from-note gate passes). The new extract item is left on
    /// disk (the runner can't delete under `/Users/`) and wiped by the next pre-run fixture rebuild — the
    /// assertion tolerates a dirty fixture by subtracting the pre-test `itemDirs()` snapshot.
    func testG9_CreateExtractFromSelectionWritesExtractItem() throws {
        let before = itemDirs()
        XCTAssertGreaterThanOrEqual(before.count, 4, "fixture should have its seeded notes")

        // Select the plain note so the editor loads a NOTE body (you extract *from* a note).
        selectItem(uuid: Self.idPlain)
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "editor text view should exist")
        XCTAssertTrue(pollUntil(timeout: 10) { !((editor.value as? String) ?? "").isEmpty },
                      "the note body should load into the editor before selecting text")

        // Non-empty selection over the first rendered block (the heading text is well over 8 chars, so
        // this stays inside a single source block). Drives the styled text view via the DEBUG strip.
        XCTAssertTrue(setEditorSelection(location: 0, length: 8),
                      "the DEBUG selection strip must be drivable (an.editor.test.selectionInput/.select)")

        // A new item dir counts as "the extract" once its `.md` is on disk with `kind: extract`
        // (NoteStore.create writes atomically, so this never races a partial file).
        func newExtractDirs() -> [String] {
            itemDirs().subtracting(before).filter { (rawMarkdown(inItemDir: $0) ?? "").contains("kind: extract") }
        }

        // Trigger Create Extract: ⌘⌥E (the Extract-menu shortcut), with the menu click as a fallback.
        app.activate()
        app.typeKey("e", modifierFlags: [.command, .option])
        var created = pollUntil(timeout: 8) { !newExtractDirs().isEmpty }
        if !created {
            let extractMenu = app.menuBars.menuBarItems["Extract"]
            if extractMenu.waitForExistence(timeout: 5) {
                extractMenu.click()
                let item = app.menuItems["Create Extract"]
                if item.waitForExistence(timeout: 3) { item.click() }
            }
            created = pollUntil(timeout: 10) { !newExtractDirs().isEmpty }
        }

        let newDirs = newExtractDirs()
        XCTAssertTrue(created, "Create Extract (⌘⌥E / Extract menu) should mint a kind: extract item")
        XCTAssertEqual(newDirs.count, 1, "exactly one new extract item directory should appear on disk")
        if let dir = newDirs.first {
            let md = rawMarkdown(inItemDir: dir) ?? ""
            XCTAssertTrue(md.contains("kind: extract"),
                          "the new item's front matter should declare kind: extract")
            XCTAssertTrue(md.contains("block: note-passage"),
                          "the extract body should carry a note-passage provenance block")
            XCTAssertTrue(md.contains("archivenotes://open?id=\(Self.idPlain)"),
                          "the note-passage block should link back to the source note \(Self.idPlain)")
            // (Left on disk — the runner can't delete it; wiped by the next pre-run fixture rebuild.)
        }
    }
}
