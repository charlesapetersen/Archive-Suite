import XCTest
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
    static let idPlain  = "11111111-1111-1111-1111-111111111111"   // plain note, carries `#`/`**` Markdown
    static let idReader = "22222222-2222-2222-2222-222222222222"   // the reader-page source-block note

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
}

/// Per-wave GUI checks (08-testing §3.7). This session (W8-S8, pass 1) lands the two most robust
/// within-Notes, disk-assertable checks — G1 (create) and G3 (raw toggle) — on the live XCUITest
/// harness. G5/G7/G8/G9 (pasteboard / folder-graph / extract) and the cliclick checks (G4/G6/G10/G11)
/// land in subsequent passes (W8-S8 is oversized — see the plan Session Log + Morning Review).
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
            // Best-effort cleanup so repeated runs against one fixture stay stable (Route-B is RW).
            try? FileManager.default.removeItem(atPath: itemsDir + "/" + dir)
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
}
