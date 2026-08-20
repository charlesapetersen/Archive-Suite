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
    /// The one generated path that a UI test is allowed to mutate. Keep this separate from
    /// `fixturePath`: read-only harness experiments may point the latter elsewhere, but a test that drives
    /// a write must reject that override before it touches the store (W21.vmgui-c-fu).
    static let canonicalFixturePath: String = {
        let realHome: String
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            realHome = String(cString: dir)
        } else {
            realHome = FileManager.default.homeDirectoryForCurrentUser.path
        }
        return "\(realHome)/Library/Application Support/ArchiveNotes/AN-GUI-Fixture"
    }()

    static let fixturePath: String = {
        if let override = ProcessInfo.processInfo.environment["AN_GUI_FIXTURE_PATH"], !override.isEmpty {
            return override
        }
        return canonicalFixturePath
    }()

    // Fixed fixture item UUIDs (match make-notes-fixture.sh).
    static let idPlain   = "11111111-1111-1111-1111-111111111111"  // plain note, carries `#`/`**` Markdown
    static let idReader  = "22222222-2222-2222-2222-222222222222"  // the reader-page source-block note
    static let idZotero  = "33333333-3333-3333-3333-333333333333"  // the Zotero-chip note (a kind:note)
    static let idExtract = "44444444-4444-4444-4444-444444444444"  // the extract with a note-passage block
    // The embedded scratch Reader corpus root GUID (durable links resolve under it).
    static let corpusRootGUID = "c07b0700-2000-4000-8000-000000000002"
    // Fixed demo-folder UUIDs (match make-notes-fixture.sh organization.json). Reading holds idPlain
    // + idReader; Ideas holds idReader + idZotero (idReader is the replicated item).
    static let folderReading = "f1f1f1f1-0000-0000-0000-0000000000f1"
    static let folderIdeas   = "f2f2f2f2-0000-0000-0000-0000000000f2"

    var app: XCUIApplication!

    /// Run one test's scratch-fixture lifecycle from its `@MainActor` test method. XCTest's macOS lifecycle
    /// overrides are nonisolated in the Swift 6 SDK, so putting this UI work in `setUpWithError` would
    /// weaken its actor checking. `defer` always shuts down the scratch app after the test body returns.
    func withFixture(_ body: () throws -> Void) throws {
        try setUpOnMainActor()
        defer { tearDownOnMainActor() }
        try body()
    }

    /// Guard a test that invokes a durable store write. The app is deliberately launchable against an
    /// alternate fixture for read-only diagnostics, so `fixturePath` alone cannot establish this safety
    /// boundary. Require the generated fixture's exact final path, a real (non-symlink) directory, and its
    /// deterministic root marker before the test can click a mutating control.
    func requireCanonicalScratchFixtureForStoreWrites() throws {
        guard Self.fixturePath == Self.canonicalFixturePath else {
            throw FixtureWriteSafetyError("AN_GUI_FIXTURE_PATH is not permitted for a mutating test")
        }

        let root = URL(fileURLWithPath: Self.canonicalFixturePath)
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw FixtureWriteSafetyError("canonical GUI fixture must be a non-symlink directory")
        }

        let marker = root.appendingPathComponent(".archive-suite-root.json")
        guard let data = FileManager.default.contents(atPath: marker.path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["guid"] as? String == "a11ce5e7-1000-4000-8000-000000000001",
              object["name"] as? String == "AN-GUI-Fixture",
              object["kind"] as? String == "notes" else {
            throw FixtureWriteSafetyError("canonical GUI fixture is missing its generated Notes root marker")
        }
    }

    private struct FixtureWriteSafetyError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private func setUpOnMainActor() throws {
        continueAfterFailure = false
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Self.fixturePath),
            "GUI fixture not found — run scripts/make-notes-fixture.sh first"
        )

        app = .archiveUITestApp()   // never a bare XCUIApplication() — see UITestLaunch
        app.launchArguments += ["-ANUITestStorePath", Self.fixturePath]
        app.launch()
        app.activate()

        let window = app.windows["Archive Notes"]
        XCTAssertTrue(window.waitForExistence(timeout: 15), "Main window should appear")

        // ONE WINDOW, GUARANTEED, before any test body runs (W21.vmgui-g14-leak).
        //
        // `ArchiveNotesApp` declares TWO `Window` scenes and its own comment calls them "both auto-opening
        // windows" — there is no `.defaultLaunchBehavior(.suppressed)`. Both render `NotesBrowserView`, so
        // both carry `an.status.indexReady` / `an.editor.text` / the toolbar ids, and almost every check in
        // this suite queries UNSCOPED. Two windows therefore make those queries throw "Multiple matching
        // elements", which surfaces as a failure in whatever ran next rather than as a window problem.
        //
        // Until now nothing guaranteed one window: `closeExtractsWindow` was called only at the END of the
        // two tests that open it, so the suite depended on the app CONTAINER remembering "Extracts closed"
        // from an earlier run. That is not a guarantee, it is a leftover — and it inverts on a FRESH
        // container, which is exactly what `notes:prerun` creates. Proven in isolation on 2026-08-04: with
        // the container wiped, `testG0` ALONE fails at line 133 with multiple matches, no other test in play.
        // It also meant one leaked window (see G14 at 1101 s) poisoned every editor-using test after it.
        //
        // Closing it HERE fixes both: it is a precondition rather than a cleanup, so it holds no matter what
        // the container remembers, and no matter which test leaked. `openExtractsWindow()` re-opens it via
        // Window ▸ Extracts when G12/G14 need it, so nothing loses coverage.
        //
        // Written INLINE, on locals, to keep this best-effort precondition beside the test lifecycle that
        // owns it — no assertion. This runs before EVERY test, so asserting here would turn an unrelated
        // window hiccup into a suite-wide failure; if the close does not take, the test that needs one window
        // fails on its own terms with its own message.
        // 8 s, not 1 s: the secondary scene comes up a BEAT AFTER the main one, so a 1 s sample returned
        // false, skipped the close, and the window then opened anyway — G0 still failed on two matches.
        // On a fresh container (the norm, since `notes:prerun` wipes it) this returns almost immediately
        // because the window IS there; the full wait is only paid on an inherited container where it never
        // opens, and correctness is worth those seconds.
        let extractsWindow = app.windows["Extracts"]
        if extractsWindow.waitForExistence(timeout: 8) {
            // RAISE IT FIRST. Measured 2026-08-04: the close button exists but `isHittable == false`, because
            // the secondary scene launches BEHIND the main window and an occluded element is not hittable —
            // the same class as W21.vmgui-c's off-window controls, NOT a timing problem, which is why a
            // longer wait changed nothing. Window ▸ Extracts brings it forward; that is the same menu path
            // `openExtractsWindow()` already uses successfully in G12/G14.
            let windowMenu = app.menuBars.menuBarItems["Window"]
            if windowMenu.waitForExistence(timeout: 5) {
                windowMenu.click()
                let extractsItem = app.menuItems["Extracts"]
                if extractsItem.waitForExistence(timeout: 3) { extractsItem.click() }
            }
            let closeButton = extractsWindow.buttons[XCUIIdentifierCloseWindow]
            if closeButton.waitForExistence(timeout: 5), closeButton.isHittable { closeButton.click() }
            _ = extractsWindow.waitForNonExistence(timeout: 8)
        }

        // Readiness gate: the list populates from disk (NotesModel.buildIndexFromDisk enumerates
        // items/**/*.md — not Spotlight), so wait for a KNOWN seeded row to appear. This is the
        // reliable gate; the hidden `an.status.indexReady` probe (§3.4) is verified separately by
        // `waitForIndexReady` (its 1×1 clear-color queryability was flagged UNVERIFIED at W8-S7).
        // Scoped to the main window like every other lookup — through the LOCAL `window` above, which keeps
        // this readiness gate bound to the primary window captured immediately after launch.
        let seed = window.descendants(matching: .any)["an.cell.title.\(Self.idPlain)"]
        XCTAssertTrue(seed.waitForExistence(timeout: 25), "a seeded note row should populate the list")
    }

    private func tearDownOnMainActor() {
        app?.terminate()
        app = nil
    }

    // NOTE: the "one window before every test" precondition lives INLINE in `setUpOnMainActor` above. The
    // subclass keeps `closeExtractsWindow(_:)` for its own end-of-test tidy-up (W21.vmgui-g14-leak).

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

    /// The index-ready probe (§3.4), present only under the UITest harness. A UITest-gated `Text`
    /// (occluded behind the panes); its value/label carry the generation token once the build settles.
    /// The scoping root for every element lookup in this suite (W21.vmgui-g14-leak).
    ///
    /// `ArchiveNotesApp` declares TWO auto-opening `Window` scenes and BOTH render `NotesBrowserView`, so
    /// `an.status.indexReady` / `an.editor.text` / the toolbar ids exist TWICE whenever the Extracts window is
    /// open. An `app.`-rooted query then throws "Multiple matching elements" — and lands that failure on
    /// whatever test ran next, which is how six innocent tests were blamed on 2026-08-04.
    ///
    /// Scoping here is what makes the suite CORRECT rather than merely lucky: a window-scoped query resolves
    /// to exactly one element or none, never two, so the result no longer depends on how many windows are
    /// open. That is a property, not a cleanup — unlike closing the second window (setUp does that too, and
    /// it helps, but it depends on z-order, menu readiness and hit-testing, all three of which have already
    /// produced a false diagnosis in this lane). `Window` (not `WindowGroup`) means one window per title, so
    /// the root itself cannot become ambiguous.
    ///
    /// ⚠️ Deliberately NOT applied to menus: `app.menuBars`, `app.menuItems`, `app.activate()` and
    /// `app.typeKey` are OUTSIDE any window and must stay app-rooted, as must the window lookups themselves.
    /// A blanket `app.` -> `mainWindow.` rewrite would break the suite.
    var mainWindow: XCUIElement { app.windows["Archive Notes"] }

    var indexReadyProbe: XCUIElement { mainWindow.descendants(matching: .any)["an.status.indexReady"] }

    /// The main editor NSTextView (id `an.editor.text`). Its `.value` is the current editor string —
    /// in styled mode block headers render as chips (no literal `<!-- block: -->`); in raw mode the
    /// literal Markdown source is shown.
    var editor: XCUIElement { mainWindow.textViews["an.editor.text"] }

    /// The raw/styled toggle (borderless Button, id `an.editor.rawToggle`).
    var rawToggle: XCUIElement { mainWindow.descendants(matching: .any)["an.editor.rawToggle"] }

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

    /// Wait until the index-ready probe publishes the settled completion token. The probe carries the
    /// bare generation token in its `accessibilityValue` (empty before settle) and mirrors it in the
    /// label (`building` → `ready:<gen>`); some SwiftUI static-text elements surface their string via
    /// `.label` not `.value` (cf. `lastOpenedURL`), so accept either signal (W8-S8b probe fix).
    @discardableResult
    func waitForIndexReady(timeout: TimeInterval) -> Bool {
        _ = indexReadyProbe.waitForExistence(timeout: min(timeout, 10))
        return pollUntil(timeout: timeout) {
            if let v = indexReadyProbe.value as? String, !v.isEmpty { return true }
            return indexReadyProbe.label.hasPrefix("ready:")
        }
    }

    /// Click a row's title cell (id `an.cell.title.<uuid>`) to select that item. Brings the app forward
    /// and waits for hittability first (another app briefly holding window-server focus makes an
    /// on-screen element report "not hittable"), with a coordinate tap as a last resort.
    @discardableResult
    func selectItem(uuid: String, timeout: TimeInterval = 15) -> XCUIElement {
        app.activate()
        let cell = mainWindow.descendants(matching: .any)["an.cell.title.\(uuid)"]
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

    /// Parse `<fixture>/organization.json` into the set of `[folderId, itemId]` membership pairs (each a
    /// 2-element array so it's `Hashable`), or nil if the file can't be read/parsed. The app rewrites
    /// this file atomically on every membership change (`OrganizationStore.exportOrganization`), so it's
    /// the durable on-disk source of truth the folder-graph checks (G7 replicate / G8 delete) assert on.
    /// Parses the JSON (not a substring match) because `OrganizationFile.export` re-serializes it.
    /// UUID strings are **lowercased** so comparisons are case-insensitive: the fixture builder writes
    /// lowercase UUIDs, but once the app rewrites the file (via `OrganizationFile.export`) they come back
    /// UPPERCASE (Swift's `UUID.uuidString`); a UUID is case-insensitive, so normalize both here.
    func organizationMemberships() -> Set<[String]>? {
        let path = Self.fixturePath + "/organization.json"
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["memberships"] as? [[String: Any]] else { return nil }
        var pairs = Set<[String]>()
        for m in arr {
            if let f = m["folderId"] as? String, let i = m["itemId"] as? String {
                pairs.insert([f.lowercased(), i.lowercased()])
            }
        }
        return pairs
    }

    /// The `assets/<name>` file names inside a given `items/<uuid>` directory (G4 asserts the pasted
    /// image lands here). Missing `assets/` → empty.
    func assetFiles(inItemDir dir: String) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: itemsDir + "/" + dir + "/assets")) ?? []
        return entries.filter { !$0.hasPrefix(".") }
    }

    // MARK: - Image helper (G4 seeds the pasteboard with real PNG bytes)

    /// Build a small but valid PNG entirely off-screen via `NSBitmapImageRep` — no `lockFocus` and no
    /// window server, so it's safe in the UITest runner. The image-paste path only needs valid `.png`
    /// bytes on the pasteboard (`EditorTextView.tryPasteImage` reads `.png` verbatim); the fill just
    /// gives `InlineImageAttachment.downsampledThumbnail` real pixels.
    static func makePNGData(width: Int = 8, height: Int = 8) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            NSColor.systemBlue.setFill()
            NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - DEBUG editor test seam (W8-S7 §3.3; drives the styled NSTextView XCUITest can't focus)

    /// Set the editor's selected range via the hidden DEBUG control strip
    /// (`an.editor.test.selectionInput` + `an.editor.test.select`) — XCUITest can't reliably place a
    /// caret selection inside the styled NSTextView, so the strip drives it through `testBox`. Returns
    /// false if the strip isn't present/hittable (which would itself be the finding to fix).
    /// `scope` limits the query to one window — REQUIRED once a second window is open (G12/G14), since both
    /// windows carry an editor and its strip, and an unscoped query then resolves to "multiple matching
    /// elements" and throws rather than picking one.
    @discardableResult
    func setEditorSelection(location: Int, length: Int, timeout: TimeInterval = 10,
                            in scope: XCUIElement? = nil) -> Bool {
        // Default scope is the MAIN WINDOW, not the app (W21.vmgui-g14-leak): both windows carry this
        // strip, so an app-rooted lookup throws once the Extracts window is open. Callers that mean the
        // other window (G12/G14) already pass it explicitly.
        let root = scope ?? mainWindow
        let field = root.descendants(matching: .any)["an.editor.test.selectionInput"]
        let button = root.descendants(matching: .any)["an.editor.test.select"]
        guard field.waitForExistence(timeout: timeout),
              button.waitForExistence(timeout: timeout) else { return false }
        _ = pollUntil(timeout: timeout) { app.activate(); return field.isHittable }
        guard field.isHittable else { return false }
        field.click()
        // Select-all first: the field is per-pane @State that PERSISTS across calls, so typing without
        // clearing APPENDS. G13 calls this twice ("0,100000" then "0,0"), and the second call produced a
        // three-part string whose `parts.count == 2` parse failed, so `testBox.setSelection` was never
        // invoked and the selection silently stayed put — nondeterministic, because what the append yields
        // depends on where `click()` lands the caret. (W21.vmgui-g13)
        field.typeKey("a", modifierFlags: .command)
        field.typeText("\(location),\(length)")
        // Clicking the button ends editing in the field (commits the binding via focus-loss) BEFORE the
        // button action reads `testSelectionInput`, so no explicit commit keystroke is needed.
        guard button.isHittable else { return false }
        button.click()
        return true
    }

    /// Trigger the DEBUG image-paste seam (`an.editor.test.pasteImage`), which drives the editor's REAL
    /// `tryPasteImage` from `NSPasteboard.general` (asset write + attachment insert + serialize) without
    /// ⌘V / field-editor focus — XCUITest can't reliably focus the styled NSTextView and route a paste to
    /// it (same reason the selection seam exists; the ⌘V gesture itself is owner-eye). Seed the pasteboard
    /// with PNG bytes BEFORE calling. Returns false if the strip button isn't present/hittable (itself the
    /// finding to fix).
    @discardableResult
    func pasteImageViaSeam(timeout: TimeInterval = 10) -> Bool {
        let button = mainWindow.descendants(matching: .any)["an.editor.test.pasteImage"]
        guard button.waitForExistence(timeout: timeout) else { return false }
        _ = pollUntil(timeout: timeout) { app.activate(); return button.isHittable }
        guard button.isHittable else { return false }
        button.click()
        return true
    }

    /// Trigger the DEBUG jump-to-source seam (`an.editor.test.jump`), which fires the first note-passage
    /// chip's REAL `onJump` callback (→ `NotesModel.openItem` → cross-window select) without a chip-button
    /// click — the chip button (`an.chip.jump`) is a TextKit-2 attachment-view-provider subview XCUITest
    /// can't hit-test (same weak spot as the selection/paste seams; the literal click is owner-eye).
    /// Returns false if the strip button isn't present/hittable (itself the finding to fix). Used by G10.
    @discardableResult
    func jumpFirstPassageViaSeam(timeout: TimeInterval = 10) -> Bool {
        let button = mainWindow.descendants(matching: .any)["an.editor.test.jump"]
        guard button.waitForExistence(timeout: timeout) else { return false }
        _ = pollUntil(timeout: timeout) { app.activate(); return button.isHittable }
        guard button.isHittable else { return false }
        button.click()
        return true
    }

    /// Trigger the DEBUG reveal seam (`an.editor.test.reveal`), which fires the first reader-page chip's
    /// REAL `onReveal` callback (→ `openExternalURL`) without a chip-button click — the chip button
    /// (`an.chip.reveal`) is a TextKit-2 attachment subview XCUITest can't hit-test (owner-eye, like G2).
    /// The button action also re-reads the `WorkspaceOpenSpy` into `an.editor.test.lastOpenedURL`. Used by
    /// G6. Returns false if the strip button isn't present/hittable (itself the finding to fix).
    @discardableResult
    func revealFirstSourceViaSeam(timeout: TimeInterval = 10) -> Bool {
        return clickStripButton("an.editor.test.reveal", timeout: timeout)
    }

    /// Trigger the DEBUG Zotero-open seam (`an.editor.test.zoteroOpen`), which runs the first Zotero
    /// chip's REAL open path (→ `openExternalURL`) without a chip-button click. The action re-reads the
    /// `WorkspaceOpenSpy` into `an.editor.test.lastOpenedURL`. Used by G11. Returns false if the strip
    /// button isn't present/hittable.
    @discardableResult
    func openFirstZoteroViaSeam(timeout: TimeInterval = 10) -> Bool {
        return clickStripButton("an.editor.test.zoteroOpen", timeout: timeout)
    }

    /// Click a hidden control-strip button by identifier, bringing the app forward + waiting for
    /// hittability first (shared by the reveal/zotero/copy/paste seam triggers). `scope` limits the query to
    /// one window, which is required once a second window is open — see `setEditorSelection`.
    @discardableResult
    func clickStripButton(_ id: String, timeout: TimeInterval, in scope: XCUIElement? = nil) -> Bool {
        // Same as `setEditorSelection`: default to the main window, explicit scope wins (W21.vmgui-g14-leak).
        let button = (scope ?? mainWindow).descendants(matching: .any)[id]
        guard button.waitForExistence(timeout: timeout) else { return false }
        _ = pollUntil(timeout: timeout) { app.activate(); return button.isHittable }
        guard button.isHittable else { return false }
        button.click()
        return true
    }

    /// Read back the last external URL the app dispatched (the `an.editor.test.lastOpenedURL` static text
    /// the reveal/zotero seams populate from `WorkspaceOpenSpy`), polling until it starts with
    /// `expectedPrefix`. Returns the final observed value (empty/"-" if nothing dispatched). G6/G11.
    func lastOpenedURL(startingWith expectedPrefix: String, timeout: TimeInterval = 12) -> String {
        let el = mainWindow.descendants(matching: .any)["an.editor.test.lastOpenedURL"]
        _ = el.waitForExistence(timeout: min(timeout, 8))
        var seen = ""
        _ = pollUntil(timeout: timeout) {
            let v = (el.value as? String) ?? ""
            seen = v.isEmpty ? el.label : v
            return seen.hasPrefix(expectedPrefix)
        }
        return seen
    }

    /// The passage paste's own verdict (`an.editor.test.pastePassageOutcome`, W21.vmgui-g13) — "ok …" or
    /// "declined:<which guard> …", each carrying `kind=` and `store=`. `handlePassagePaste` reports through
    /// a `Bool` no UITest could see, so a decline and a paste-that-imported-nothing used to be one
    /// observation; this is the difference. Read as `.value` with `.label` as the fallback, the same way
    /// `lastOpenedURL` does (W8-S8b probe fix).
    func seamOutcome(_ identifier: String, timeout: TimeInterval = 8) -> String {
        // Scoped like every other lookup (W21.vmgui-g14-leak) — this helper was in a stash during the
        // scoping pass, so it is caught up here. Both windows carry the seam buttons.
        let el = mainWindow.descendants(matching: .any)[identifier]
        guard el.waitForExistence(timeout: timeout) else { return "<probe absent>" }
        var seen = ""
        // Value ONLY — never fall back to `.label`. The probe now rides on the seam BUTTON's a11y value
        // (no extra element, no layout change), and a button's label is "pasteP"/"copyP": a fallback would
        // return that and read as a diagnosis. Distinct markers for every non-answer, so "seam not wired",
        // "never clicked" and "unreadable" can never alias onto one another.
        _ = pollUntil(timeout: 5) {
            seen = (el.value as? String) ?? ""
            return !seen.isEmpty && seen != "-"
        }
        if seen.isEmpty { return "<probe value unreadable>" }
        return seen == "-" ? "<probe never set>" : seen
    }
    func pastePassageOutcome(timeout: TimeInterval = 8) -> String {
        seamOutcome("an.editor.test.pastePassage", timeout: timeout)
    }
    func copyPassageOutcome(timeout: TimeInterval = 8) -> String {
        seamOutcome("an.editor.test.copyPassage", timeout: timeout)
    }

    /// Read the DEBUG snapshot of note-passage chips from this window's rendered text storage. The
    /// attachment-view-provider chip is absent from the accessibility tree, so its label/tint cannot be
    /// queried directly; this reads a non-interactive AX child of `EditorTextView`, whose cached value is
    /// formed from the actual attachments at renderer time without mutating SwiftUI state or triggering
    /// `updateNSView`. The returned
    /// dictionaries contain `id`, `label`, and `missing`. `scope` is mandatory once two windows are open.
    func passageChipStates(timeout: TimeInterval = 8, in scope: XCUIElement? = nil) -> [[String: Any]]? {
        let probe = (scope ?? mainWindow).descendants(matching: .any)["an.editor.test.passageChips"]
        guard probe.waitForExistence(timeout: timeout) else { return nil }

        var states: [[String: Any]]?
        _ = pollUntil(timeout: timeout) {
            guard let raw = probe.value as? String,
                  let data = raw.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return false
            }
            states = parsed
            return true
        }
        return states
    }

    /// Ensure the editor is in STYLED mode: block-chip seams (G6/G11) scan the text storage for
    /// `BlockHeaderAttachment`, which exists only in styled mode (raw mode shows the literal
    /// `<!-- block: -->` source). Notes load styled by default; this is a safety net.
    func ensureStyled(timeout: TimeInterval = 6) {
        guard ((editor.value as? String) ?? "").contains("<!-- block:") else { return }
        if rawToggle.waitForExistence(timeout: 5) {
            _ = pollUntil(timeout: 4) { app.activate(); return rawToggle.isHittable }
            if rawToggle.isHittable { rawToggle.click() }
        }
        _ = pollUntil(timeout: timeout) { !(((editor.value as? String) ?? "").contains("<!-- block:")) }
    }
}

/// Per-wave GUI checks (08-testing §3.7). Landed incrementally (W8-S8 is oversized — see the plan
/// Session Log + Daemon Report): pass 1 = G1 (create) + G3 (raw toggle); pass 2 = G9 (create extract
/// from a note selection, first use of the DEBUG selection seam `an.editor.test.select`); pass 3 = G5
/// (paste archive links as a source block via ⌘⇧V); this pass = G7 (folder replicate) + G8
/// (delete-last-instance, Tier-2). G7/G8 needed the org-graph folders loaded, which had been blocked by
/// the INDEX-DB caveat: the org graph loads DB-first from the app *container's* `notes-index-v1.sqlite3`
/// (survives across launches, never reset), so the fixture's `organization.json` was shadowed. RESOLVED
/// this pass by the DEBUG index-DB seam `NotesModel.indexDatabaseURL(inAppSupport:)`: under
/// `-ANUITestStorePath` the app opens a dedicated `notes-index-uitest.sqlite3` reset on every launch, so
/// the fixture's `organization.json` loads fresh (the owner's real DB is untouched — distinct filename).
/// pass 5 = G4 (paste image → the item's `assets/` + an inline `![](…)` reference, Tier-2 — the last
/// un-GUI-verified file-WRITE path). pass 6 = G10 (jump-to-source): click a note-passage chip's
/// "Jump to Source" (`an.chip.jump`) → the featuring window selects the source note. this pass = G6
/// (reveal → Reader) + G11 (Zotero chip open): both dispatch an external URL through the DEBUG
/// `WorkspaceOpenSpy` (`openExternalURL`) — the seams fire the un-hit-testable chip buttons' REAL
/// callbacks and the harness reads the dispatched URL back via `an.editor.test.lastOpenedURL`; the real
/// Reader/Zotero launch stays owner-eye. W8-S8b completes the wave: G0 asserts the (now UITest-gated,
/// queryable) `an.status.indexReady` probe resolves, and the owner-eye checks (G2 typing, G6/G11
/// external launch, chip-button clicks) are documented in `ArchiveNotes/scripts/GUI-HARNESS.md`.
@MainActor
final class NotesGUITests: NotesFixtureUITestCase {

    /// G0 — The `an.status.indexReady` probe is XCUITest-queryable and publishes the settled
    /// completion token (W8-S8b). Was a 1×1 `Color.clear` that never resolved — its value stayed empty
    /// across a 30 s poll (KNOWN_ISSUES pass-1). Now a UITest-gated `Text`; this asserts it both exists
    /// in the a11y tree and flips to a non-empty token once the initial index build settles, so a later
    /// FTS/relevance check can safely gate on it.
    func testG0_IndexReadyProbeResolvesAfterInitialBuild() throws {
        try withFixture { try runG0_IndexReadyProbeResolvesAfterInitialBuild() }
    }

    private func runG0_IndexReadyProbeResolvesAfterInitialBuild() throws {
        XCTAssertTrue(indexReadyProbe.waitForExistence(timeout: 10),
                      "the an.status.indexReady probe should be present in the accessibility tree")
        XCTAssertTrue(waitForIndexReady(timeout: 30),
                      "the probe should publish the completion token once the initial index build settles")
    }

    /// G1 — Create a note (⌘N / the New menu) → a new `items/<uuid>/<Title>.md` appears on disk.
    func testG1_CreateNoteWritesNewItemFile() throws {
        try withFixture { try runG1_CreateNoteWritesNewItemFile() }
    }

    private func runG1_CreateNoteWritesNewItemFile() throws {
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
            let newMenu = mainWindow.descendants(matching: .any)["an.toolbar.new"]
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
        try withFixture { try runG3_RawMarkdownToggleShowsSourceAndIsLossless() }
    }

    private func runG3_RawMarkdownToggleShowsSourceAndIsLossless() throws {
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
        // is noted as a minor finding — see the plan Session Log / Daemon Report.)
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

    /// G4 — Paste an image → the item's `assets/pasted-….png` is written AND an `![](assets/pasted-…)`
    /// inline-image reference lands in the note's on-disk `.md`. This is the last un-GUI-verified
    /// file-WRITE path in Notes: it drives W3-S4's image-paste handler (`EditorTextView.tryPasteImage`)
    /// end-to-end through W7-S5's item-scoped `ItemAssetStore` (**Tier-2** — a real byte write into the
    /// item). Disk-asserted (like G1/G9); the plan lists G4 as a cliclick check, but a disk-asserted
    /// XCUITest is deterministic and needs no pointer geometry — the reconciliation is logged in the plan.
    ///
    /// Drives the paste through the DEBUG seam `an.editor.test.pasteImage` (→ `EditorTextView.uiTestPasteImage`
    /// → the real `tryPasteImage(from: NSPasteboard.general)`), NOT a live ⌘V: XCUITest can't reliably focus
    /// the styled NSTextView and route a paste keystroke to it — the same documented weak spot the selection
    /// seam (G9) works around (an earlier real-⌘V attempt fell through to the default paste and wrote no
    /// asset). The seam runs the production asset-write + attachment-insert + serialize path verbatim; only
    /// the ⌘V gesture routing is bypassed (that gesture is owner-eye, like G2's typing).
    ///
    /// Target = the plain note (`idPlain`, no chip; nothing else asserts its body — G7/G8/G9 assert the
    /// folder graph / structure). Selecting it retargets the `ItemAssetStore` to idPlain (W7-S5). `addAsset`
    /// reserves the name synchronously and persists bytes on a background `Task` (the asset file appears
    /// shortly after); the coordinator flushes the `![](…)` write-back so the reference is on disk at once.
    /// A before-snapshot of `assets/` tolerates a dirty fixture. The mutated note is wiped by the next rebuild.
    func testG4_PasteImageWritesAssetAndInlineReference() throws {
        try withFixture { try runG4_PasteImageWritesAssetAndInlineReference() }
    }

    private func runG4_PasteImageWritesAssetAndInlineReference() throws {
        let uuid = Self.idPlain
        guard let png = Self.makePNGData() else {
            return XCTFail("should build PNG bytes for the pasteboard")
        }

        let assetsBefore = Set(assetFiles(inItemDir: uuid))
        func newPastedAsset() -> String? {
            Set(assetFiles(inItemDir: uuid)).subtracting(assetsBefore)
                .first { $0.hasPrefix("pasted-") && $0.hasSuffix(".png") }
        }
        func referenceOnDisk() -> Bool { (rawMarkdown(inItemDir: uuid) ?? "").contains("](assets/pasted-") }

        // Select the plain note so the editor loads its body AND the ItemAssetStore is retargeted to it
        // (W7-S5, keyed to nav.selectedItemID) — the paste writes into THIS item's assets/.
        selectItem(uuid: uuid)
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "editor text view should exist")
        XCTAssertTrue(pollUntil(timeout: 10) { !((editor.value as? String) ?? "").isEmpty },
                      "the note body should load before pasting")

        // Ensure STYLED mode: the image inserts + serializes as `![](…)` in styled mode (raw shows the
        // monospaced literal source). idPlain loads styled by default; toggle back if a prior check left
        // it raw (detected via the literal `**bold**` the fixture carries only in raw mode).
        if ((editor.value as? String) ?? "").contains("**bold**") {
            rawToggle.click()
            _ = pollUntil(timeout: 5) { !(((editor.value as? String) ?? "").contains("**bold**")) }
        }

        // Seed the pasteboard with PNG bytes (settable cross-process from the runner), then fire the seam.
        let pb = NSPasteboard.general
        pb.clearContents()
        XCTAssertTrue(pb.setData(png, forType: .png), "should seed the pasteboard with PNG bytes")
        XCTAssertTrue(pasteImageViaSeam(),
                      "the DEBUG image-paste seam must be drivable (an.editor.test.pasteImage)")

        // The `![](…)` reference is flushed synchronously by the coordinator; the asset bytes land on a
        // background Task shortly after. Poll both on disk.
        XCTAssertTrue(pollUntil(timeout: 10) { newPastedAsset() != nil },
                      "an assets/pasted-….png file should be written into the item")
        XCTAssertTrue(pollUntil(timeout: 10) { referenceOnDisk() },
                      "the note .md should gain an ![](assets/pasted-…) inline-image reference")
        // (Left on disk — the runner can't delete under /Users/; wiped by the next pre-run fixture rebuild.)
    }

    /// G5 — Paste archive links as a source block (Edit ▸ Paste as Source Block(s)). Seeds the
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
        try withFixture { try runG5_PasteArchiveLinkAsSourceBlockWritesReaderPageBlock() }
    }

    private func runG5_PasteArchiveLinkAsSourceBlockWritesReaderPageBlock() throws {
        let uuid = Self.idZotero
        let bodyBefore = rawMarkdown(inItemDir: uuid) ?? ""
        XCTAssertFalse(bodyBefore.isEmpty, "should read the Zotero note off disk")
        XCTAssertFalse(bodyBefore.contains("block: reader-page"),
                       "the Zotero fixture note should start without a reader-page block")

        // The durable link to paste — resolves under the embedded scratch Reader corpus. `page` present
        // → the paster classifies it as a `.readerPage` block.
        let link = "archivereader://reveal?root=\(Self.corpusRootGUID)&rel=sample.pdf&page=2"

        func blockOnDisk() -> Bool { (rawMarkdown(inItemDir: uuid) ?? "").contains("block: reader-page") }

        selectItem(uuid: uuid)
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "editor text view should exist")
        // Target-specific, not merely "nonempty": the old shortcut→select-away→menu retry accepted the
        // previously loaded plain note here and could paste into the wrong item. This exact phrase is in
        // both the raw and styled renderings of idZotero, and in no other fixture note.
        XCTAssertTrue(
            pollUntil(timeout: 10) {
                ((editor.value as? String) ?? "").contains("Notes on the Lovelace paper.")
            },
            "the Zotero target body must finish loading before the paste command runs"
        )

        // Ensure styled: in RAW mode the editor shows the literal `zotero://select…` header source;
        // that never appears in styled mode (it renders as a chip). Toggle back to styled if raw.
        if ((editor.value as? String) ?? "").contains("zotero://select") {
            XCTAssertTrue(rawToggle.waitForExistence(timeout: 5), "raw toggle should exist")
            rawToggle.click()
            XCTAssertTrue(
                pollUntil(timeout: 5) {
                    !(((editor.value as? String) ?? "").contains("zotero://select"))
                },
                "the target editor must reach styled mode before source-block paste"
            )
        }

        let pb = NSPasteboard.general
        pb.clearContents()
        XCTAssertTrue(pb.setString(link, forType: .string), "should seed the pasteboard with the link")
        XCTAssertTrue(setEditorSelection(location: 0, length: 0),
                      "the DEBUG selection seam must place a defined caret before paste")

        // Drive the real command through its deterministic menu item. The ⌘⇧V binding is declared on
        // this same Button in SourceBlockCommands and needs no first-responder timing test; intermittently
        // missing that synthesized keystroke was what made this check spend its long retry path.
        app.activate()
        let editMenu = app.menuBars.menuBarItems["Edit"]
        XCTAssertTrue(editMenu.waitForExistence(timeout: 5), "the Edit menu should exist")
        editMenu.click()
        let pasteItem = app.menuItems["Paste as Source Block(s)"]
        XCTAssertTrue(pasteItem.waitForExistence(timeout: 3),
                      "Edit ▸ Paste as Source Block(s) should be present")
        pasteItem.click()

        var wrote = pollUntil(timeout: 4) { blockOnDisk() }
        if !wrote {
            selectItem(uuid: Self.idPlain)   // flush idZotero's pending write-back (W7-S6)
            wrote = pollUntil(timeout: 6) { blockOnDisk() }
        }

        XCTAssertTrue(wrote, "Edit ▸ Paste as Source Block(s) should insert a reader-page block")
        let bodyAfter = rawMarkdown(inItemDir: uuid) ?? ""
        XCTAssertTrue(bodyAfter.contains("block: reader-page"),
                      "the note should carry a reader-page provenance block after the paste")
        XCTAssertTrue(bodyAfter.contains("link: \(link)"),
                      "the pasted block should preserve the complete durable reader link")
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
        try withFixture { try runG9_CreateExtractFromSelectionWritesExtractItem() }
    }

    private func runG9_CreateExtractFromSelectionWritesExtractItem() throws {
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

    /// G7 — Replicate an item into another folder (row context menu ▸ **Add to Folder ▸ <name>**).
    /// Replication is the DevonThink "one file, many folders" model: adding a membership leaves every
    /// existing one intact (`NotesNavigationModel.replicate` → `OrganizationStore.addMembership`, which
    /// rewrites `organization.json` atomically). Target = the plain note (`idPlain`, sole member of
    /// "Reading"); replicate it into "Ideas" → it becomes a member of BOTH. Disk-asserted on
    /// `organization.json`. Deterministic because the DEBUG index-DB seam (`-ANUITestStorePath`, W8-S8:
    /// `NotesModel.indexDatabaseURL`) resets the container index each launch, so the fixture's
    /// `organization.json` loads fresh and its folder graph is present. `idPlain` is not the G8 delete
    /// target, so the two folder-graph checks don't interact even though both mutate `organization.json`.
    func testG7_ReplicateItemIntoFolderAddsMembership() throws {
        try withFixture { try runG7_ReplicateItemIntoFolderAddsMembership() }
    }

    private func runG7_ReplicateItemIntoFolderAddsMembership() throws {
        guard let before = organizationMemberships() else {
            return XCTFail("should read the fixture organization.json")
        }
        XCTAssertTrue(before.contains([Self.folderReading, Self.idPlain]),
                      "fixture: the plain note should start as a member of Reading")
        let targetPair = [Self.folderIdeas, Self.idPlain]
        func replicated() -> Bool { (organizationMemberships() ?? []).contains(targetPair) }

        let row = selectItem(uuid: Self.idPlain)

        // Right-click the row → Add to Folder ▸ Ideas. `Add` replicates (Move would drop the source).
        // The `Ideas` item is scoped to the Add submenu so it can't collide with Move's `Ideas`.
        func attempt() -> Bool {
            app.activate()
            _ = pollUntil(timeout: 8) { app.activate(); return row.isHittable }
            row.rightClick()
            let add = app.menuItems["Add to Folder"]
            guard add.waitForExistence(timeout: 5) else { return false }
            add.hover()   // open the submenu
            var ideas = add.menuItems["Ideas"]
            if !ideas.waitForExistence(timeout: 3) {
                ideas = app.menuItems["Ideas"]   // fallback: only Add's submenu is open, so unambiguous
                _ = ideas.waitForExistence(timeout: 2)
            }
            guard ideas.exists else { return false }
            ideas.click()
            return pollUntil(timeout: 5) { replicated() }
        }

        var ok = attempt()
        if !ok { ok = attempt() }
        XCTAssertTrue(ok, "Add to Folder ▸ Ideas should replicate the note into Ideas")

        let after = organizationMemberships() ?? []
        XCTAssertTrue(after.contains(targetPair),
                      "the note should now be a member of Ideas (replicated)")
        XCTAssertTrue(after.contains([Self.folderReading, Self.idPlain]),
                      "replication must KEEP the original Reading membership (add, not move)")
    }

    /// G8 — Delete-last-instance guard (00-overview §3.6, **Tier-2**, data-loss). Removing an item from
    /// its ONLY folder must not silently delete it: `NotesNavigationModel.removeMembership` returns
    /// `.wasLastInstance` WITHOUT mutating, and the view raises a mandatory confirmation. **Cancel** keeps
    /// the note on disk (and its membership); only **Delete Note** moves it to the Trash
    /// (`NoteStore.delete` → `FileManager.trashItem`, recoverable — never `removeItem`). Driven entirely
    /// through a folder-specific a11y id (`an.locations.remove.<folder-id>`, Locations inspector) →
    /// `an.dialog.deleteLastInstance.{cancel,confirm}`.
    ///
    /// Target = the Zotero note (`idZotero`, a real `kind: note`), the sole member of "Ideas". No check
    /// after G8 depends on it (G9 extracts from `idPlain`), so trashing it in the confirm leg is safe;
    /// the next pre-run fixture rebuild restores it. Needs the folder graph loaded (DEBUG index-DB seam).
    func testG8_DeleteLastInstanceGuardCancelKeepsThenConfirmTrashes() throws {
        try withFixture { try runG8_DeleteLastInstanceGuardCancelKeepsThenConfirmTrashes() }
    }

    private func runG8_DeleteLastInstanceGuardCancelKeepsThenConfirmTrashes() throws {
        XCTAssertTrue(itemDirs().contains(Self.idZotero), "fixture: the Zotero note should exist on disk")
        guard let before = organizationMemberships() else {
            return XCTFail("should read the fixture organization.json")
        }
        XCTAssertTrue(before.contains([Self.folderIdeas, Self.idZotero]),
                      "fixture: the Zotero note should start as a member of Ideas")
        XCTAssertEqual(before.filter { $0[1] == Self.idZotero }.count, 1,
                       "fixture: the Zotero note must be a SOLE membership (the delete-last-instance case)")

        selectItem(uuid: Self.idZotero)

        // Sole membership → this folder-specific remove control is unambiguous.
        let remove = app.descendants(matching: .any)["an.locations.remove.\(Self.folderIdeas)"]
        XCTAssertTrue(remove.waitForExistence(timeout: 10), "Locations ▸ Remove should be present")

        // --- Cancel leg: the confirmation must appear, and cancelling must NOT delete the note. ---
        _ = pollUntil(timeout: 8) { app.activate(); return remove.isHittable }
        remove.click()
        let cancel = app.descendants(matching: .any)["an.dialog.deleteLastInstance.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 8),
                      "removing the last instance must raise the confirmation dialog")
        cancel.click()
        _ = pollUntil(timeout: 3) { !cancel.exists }
        XCTAssertTrue(itemDirs().contains(Self.idZotero), "Cancel must NOT delete the note")
        XCTAssertTrue((organizationMemberships() ?? []).contains([Self.folderIdeas, Self.idZotero]),
                      "Cancel must leave the membership intact")

        // --- Confirm leg: Delete moves the note out of items/ (to the Trash) + drops the membership. ---
        let remove2 = app.descendants(matching: .any)["an.locations.remove.\(Self.folderIdeas)"]
        XCTAssertTrue(remove2.waitForExistence(timeout: 8), "Remove should still be present after Cancel")
        _ = pollUntil(timeout: 8) { app.activate(); return remove2.isHittable }
        remove2.click()
        let confirm = app.descendants(matching: .any)["an.dialog.deleteLastInstance.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 8), "the confirmation dialog should appear again")
        confirm.click()

        let trashed = pollUntil(timeout: 15) { !itemDirs().contains(Self.idZotero) }
        XCTAssertTrue(trashed,
                      "Delete Note must move the item out of items/ (to the Trash); items = \(itemDirs())")
        XCTAssertFalse((organizationMemberships() ?? []).contains([Self.folderIdeas, Self.idZotero]),
                       "Delete Note must drop the last membership from organization.json")
    }

    /// W21.vmgui-c-fu — a note-passage chip in the Extracts window must react when its cited note is
    /// trashed from the Note window. The attachment provider is not in the accessibility tree, so the
    /// DEBUG-only `an.editor.test.passageChips` probe reads the *rendered text storage* after
    /// `passageGeneration` re-styles it. `passageSourceMissing` is the provider's direct tint input
    /// (`.secondaryLabelColor` when true; accent otherwise), making the visual state deterministic without
    /// a brittle pixel-coordinate assertion. The source has two fixture memberships: removing the first
    /// proves it stays live; removing the second reaches the real last-instance confirmation and recoverable
    /// trash path. The guard rejects any environment override before either mutating click.
    func testW21_CrossWindowPassageChipReStylesAfterSourceTrash() throws {
        try withFixture { try runW21_CrossWindowPassageChipReStylesAfterSourceTrash() }
    }

    private func runW21_CrossWindowPassageChipReStylesAfterSourceTrash() throws {
        try requireCanonicalScratchFixtureForStoreWrites()

        let expectedLabel = "Moore on Intel culture — 1968"
        let noteWin = mainWindow
        let extractWin = try openExtractsWindow()
        defer { closeExtractsWindow(extractWin) }

        // The extract's initial rendered storage must resolve the still-live cited note, not merely retain
        // the markdown snapshot. Scope every query because both windows own an editor/test strip.
        frontWindow(named: "Extracts")
        let extractCell = extractWin.descendants(matching: .any)["an.cell.title.\(Self.idExtract)"]
        XCTAssertTrue(extractCell.waitForExistence(timeout: 10), "the fixture extract should be listed")
        _ = pollUntil(timeout: 10) { app.activate(); return extractCell.isHittable }
        XCTAssertTrue(extractCell.isHittable, "the extract row should be selectable")
        extractCell.click()
        let extractEditor = extractWin.textViews["an.editor.text"]
        XCTAssertTrue(pollUntil(timeout: 10) {
            ((extractEditor.value as? String) ?? "").contains("Moore says he and Noyce")
        }, "the extract editor should load before observing its chip")

        let before = passageChipStates(in: extractWin)
        let beforeSource = before?.first { ($0["id"] as? String) == Self.idReader }
        XCTAssertEqual(beforeSource?["label"] as? String, expectedLabel,
                       "a live cited note should contribute its resolved title/date label")
        XCTAssertEqual(beforeSource?["missing"] as? Bool, false,
                       "before trashing, the rendered provider must use the non-missing/accent state")

        // Delete the source through the production Locations inspector. Removing Ideas leaves the Reading
        // membership intact, so this is specifically a two-home → last-home transition, not a direct delete.
        frontWindow(named: "Archive Notes")
        selectItem(uuid: Self.idReader)
        let ideasRemove = noteWin.descendants(matching: .any)["an.locations.remove.\(Self.folderIdeas)"]
        XCTAssertTrue(ideasRemove.waitForExistence(timeout: 10), "the Ideas membership remove control should exist")
        _ = pollUntil(timeout: 8) { app.activate(); return ideasRemove.isHittable }
        XCTAssertTrue(ideasRemove.isHittable, "the Ideas remove control should be hittable")
        ideasRemove.click()
        XCTAssertTrue(pollUntil(timeout: 12) {
            guard let memberships = organizationMemberships() else { return false }
            return !memberships.contains([Self.folderIdeas, Self.idReader])
                && memberships.contains([Self.folderReading, Self.idReader])
                && itemDirs().contains(Self.idReader)
        }, "removing one home must keep the cited source live in Reading")

        let readingRemove = noteWin.descendants(matching: .any)["an.locations.remove.\(Self.folderReading)"]
        XCTAssertTrue(readingRemove.waitForExistence(timeout: 10), "the remaining Reading remove control should exist")
        _ = pollUntil(timeout: 8) { app.activate(); return readingRemove.isHittable }
        XCTAssertTrue(readingRemove.isHittable, "the Reading remove control should be hittable")
        readingRemove.click()
        let confirm = app.descendants(matching: .any)["an.dialog.deleteLastInstance.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10),
                      "removing the last source home must require the production confirmation")
        confirm.click()
        XCTAssertTrue(pollUntil(timeout: 15) {
            !itemDirs().contains(Self.idReader)
                && !(organizationMemberships() ?? []).contains([Self.folderReading, Self.idReader])
        }, "confirming must move the cited source out of the scratch items directory")

        // Keep Extracts inactive: making it key would render its editor and could itself perform the
        // re-style this test is meant to prove happened reactively after the source trash. The passive
        // accessibility child below returns its last renderer-time snapshot without touching the editor.
        var afterSource: [String: Any]?
        XCTAssertTrue(pollUntil(timeout: 15) {
            afterSource = passageChipStates(timeout: 3, in: extractWin)?
                .first { ($0["id"] as? String) == Self.idReader }
            return afterSource?["label"] as? String == expectedLabel
                && afterSource?["missing"] as? Bool == true
        }, "the existing Extracts editor must re-style its cited chip as missing after source trash; state = \(String(describing: afterSource))")
    }

    /// G10 — Jump-to-source (W7-S3, 00-overview §7). An extract's `note-passage` provenance chip carries
    /// a "Jump to Source" action; firing it must navigate to the linked source note. NOTE: the on-screen
    /// chip button (`an.chip.jump`) is a TextKit-2 attachment-view-provider subview that XCUITest can't
    /// hit-test (confirmed this pass — it never resolves in the a11y tree), so this drives the SAME
    /// `onJump` callback with the SAME anchor through a DEBUG seam (`an.editor.test.jump`), exactly as
    /// G4/G9 handle the un-drivable paste/selection gestures; the literal chip CLICK is owner-eye (G2).
    /// The jump is a cross-window `NotesModel.openItem` signal: `NotePassageResolve.openAction` routes it
    /// to the window whose FIXED `windowKind` matches the target's kind. The source `idReader` is a
    /// `kind: note`, so the **Note window** (windowKind `.note`) owns the select+scroll — regardless of
    /// its current kind FILTER. That lets this run single-window: show BOTH kinds in the Note window so the
    /// extract is selectable *here*, click its chip, and observe THIS window select the source note.
    ///
    /// Observed via the window's editor content (deterministic, no cross-window disambiguation): selecting
    /// the extract loads the extract body ("Moore says he and Noyce…"); after the jump the same editor
    /// loads the source note's body ("Moore on Intel's early egalitarian culture.") — the two phrases are
    /// unique to each item, so the transition proves the source note was selected and its body loaded. The
    /// scroll-to-`#block-0` offset itself isn't XCUITest-observable (unit-covered by
    /// `NotePassageResolveTests.scrollRange`; visual scroll position is owner-eye). Read-only w.r.t. the
    /// store (no writes), so no file-safety surface beyond the shared scratch-fixture launch.
    func testG10_JumpToSourceSelectsSourceNoteInNoteWindow() throws {
        try withFixture { try runG10_JumpToSourceSelectsSourceNoteInNoteWindow() }
    }

    private func runG10_JumpToSourceSelectsSourceNoteInNoteWindow() throws {
        // Scope to the Note window explicitly: the Extracts window may also be open (state restoration),
        // and both would carry an `an.editor.text` / `an.filter.kind`. The source note is a `.note`, so it
        // only ever appears in THIS window's list anyway, but scoping keeps the editor query unambiguous.
        let win = app.windows["Archive Notes"]
        XCTAssertTrue(win.waitForExistence(timeout: 10), "the Note window should exist")
        let ed = win.textViews["an.editor.text"]

        // Show BOTH kinds so the extract is selectable in the (note-featuring) window. The kind control is
        // a SwiftUI segmented Picker (`an.filter.kind`, segments Notes/Extracts/Both); drive the "Both"
        // segment as an element, falling back to a coordinate tap on the rightmost third if the segments
        // aren't individually exposed. "Both" is unique to this control (the tag-combine picker is All/Any).
        XCTAssertTrue(setKind(to: "Both", in: win), "should switch the kind filter to Both")

        // The extract row now appears; select it → the editor loads the extract body + renders the
        // note-passage chip (which carries the Jump-to-Source button).
        let extractCell = win.descendants(matching: .any)["an.cell.title.\(Self.idExtract)"]
        XCTAssertTrue(extractCell.waitForExistence(timeout: 20),
                      "the extract row should appear once Both kinds are shown")
        _ = pollUntil(timeout: 10) { app.activate(); return extractCell.isHittable }
        if extractCell.isHittable { extractCell.click() }
        else { extractCell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }

        XCTAssertTrue(editor.waitForExistence(timeout: 10), "editor should exist")
        XCTAssertTrue(pollUntil(timeout: 12) { ((ed.value as? String) ?? "").contains("Moore says") },
                      "selecting the extract should load its body into the editor")

        // Fire the note-passage chip's "Jump to Source" via the DEBUG seam (`an.editor.test.jump`). The
        // chip's on-screen NSButton (`an.chip.jump`) is a TextKit-2 attachment-view-provider subview that
        // XCUITest can't hit-test (confirmed this pass — `an.chip.jump` never resolves), so — exactly as
        // G4/G9 do for the un-drivable paste/selection gestures — the seam invokes the SAME `onJump`
        // callback with the SAME anchor the button's `jumpClicked` would (only the click gesture is
        // bypassed; the literal chip click is owner-eye, like G2's typing). This runs the real
        // openItem → cross-window `openAction` → select+load path.
        XCTAssertTrue(jumpFirstPassageViaSeam(),
                      "the DEBUG jump seam must be drivable (an.editor.test.jump)")

        // The Note window selects the source note (idReader) and its editor loads the source body. That
        // body text is unique to idReader ("Moore on Intel…", vs the extract's "Moore says…"), so its
        // appearance in the SAME editor proves the jump selected the source note and loaded it.
        XCTAssertTrue(pollUntil(timeout: 15) { ((ed.value as? String) ?? "").contains("Moore on Intel") },
                      "Jump to Source should select the source note and load its body into the editor")
    }

    // MARK: - G10 helper

    /// Switch the kind segmented control (`an.filter.kind`) to the named segment ("Notes"/"Extracts"/
    /// "Both"), scoped to `win`. Tries the segment as a button / radio button / any labeled descendant,
    /// then a coordinate tap positioned by segment index (Notes=0, Extracts=1, Both=2 of 3) as a fallback
    /// for when the segments aren't individually queryable. Returns false only if the control is absent.
    @discardableResult
    private func setKind(to segment: String, in win: XCUIElement) -> Bool {
        let control = win.descendants(matching: .any)["an.filter.kind"]
        guard control.waitForExistence(timeout: 10) else { return false }
        let candidates = [control.buttons[segment], control.radioButtons[segment],
                          control.descendants(matching: .any)[segment]]
        for el in candidates where el.waitForExistence(timeout: 2) {
            _ = pollUntil(timeout: 4) { app.activate(); return el.isHittable }
            if el.isHittable { el.click(); return true }
        }
        // Coordinate fallback: tap the center of the segment's slot (index/2, 3 segments).
        let index = ["Notes": 0, "Extracts": 1, "Both": 2][segment] ?? 2
        let dx = (Double(index) + 0.5) / 3.0
        control.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.5)).tap()
        return true
    }

    // MARK: - G6 / G11 — external-URL dispatch (NSWorkspace-open spy)

    /// G6 — a reader-page source block's "Reveal in Reader" dispatches the correct
    /// `archivereader://reveal?…` deep link. The REAL Reader launch + row selection is owner-eye (and
    /// the chip's `an.chip.reveal` button is a TextKit-2 attachment-view-provider subview XCUITest can't
    /// hit-test — same limit as G10's jump), so this drives the SAME `onReveal` callback with the SAME
    /// anchor via the DEBUG seam (`an.editor.test.reveal`) and asserts the dispatched URL through the
    /// `WorkspaceOpenSpy` read-back (`an.editor.test.lastOpenedURL`). Under `-ANUITestStorePath` the open
    /// is RECORDED, not dispatched, so no external app launches. Read-only w.r.t. the store.
    func testG6_RevealSourceBlockDispatchesReaderDeepLink() throws {
        try withFixture { try runG6_RevealSourceBlockDispatchesReaderDeepLink() }
    }

    private func runG6_RevealSourceBlockDispatchesReaderDeepLink() throws {
        // The reader-page note (idReader) is a kind:note → present in the default Note window list.
        _ = selectItem(uuid: Self.idReader)
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "editor should exist")
        ensureStyled()
        // Its body is unique ("egalitarian culture"); wait until it loads so the reader-page chip is present.
        XCTAssertTrue(pollUntil(timeout: 12) { ((editor.value as? String) ?? "").contains("egalitarian culture") },
                      "selecting the reader-page note should load its body (chip present)")

        XCTAssertTrue(revealFirstSourceViaSeam(),
                      "the reveal seam must be drivable (an.editor.test.reveal)")

        let url = lastOpenedURL(startingWith: "archivereader://reveal")
        XCTAssertTrue(url.hasPrefix("archivereader://reveal?root=\(Self.corpusRootGUID)"),
                      "Reveal should dispatch the reader deep link for the corpus root; got \(url)")
        XCTAssertTrue(url.contains("rel=sample.pdf"),
                      "the deep link should carry the source rel path; got \(url)")
    }

    /// G11 — a Zotero source block's "Open in Zotero" dispatches the correct `zotero://select/…` link.
    /// The REAL Zotero launch is owner-eye (Zotero may not be installed on the run machine; the chip's
    /// `an.chip.zoteroOpen` is likewise an un-hit-testable attachment subview), so this drives the SAME
    /// open path via the DEBUG seam (`an.editor.test.zoteroOpen`) and asserts the dispatched URL through
    /// the `WorkspaceOpenSpy` read-back. Under `-ANUITestStorePath` the open is RECORDED, not dispatched.
    func testG11_ZoteroChipDispatchesSelectLink() throws {
        try withFixture { try runG11_ZoteroChipDispatchesSelectLink() }
    }

    private func runG11_ZoteroChipDispatchesSelectLink() throws {
        // The Zotero note (idZotero) is a kind:note → present in the default Note window list.
        _ = selectItem(uuid: Self.idZotero)
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "editor should exist")
        ensureStyled()
        XCTAssertTrue(pollUntil(timeout: 12) { ((editor.value as? String) ?? "").contains("Lovelace") },
                      "selecting the Zotero note should load its body (chip present)")

        XCTAssertTrue(openFirstZoteroViaSeam(),
                      "the zotero seam must be drivable (an.editor.test.zoteroOpen)")

        let url = lastOpenedURL(startingWith: "zotero://select")
        XCTAssertEqual(url, "zotero://select/library/items/ABCD1234",
                       "Open in Zotero should dispatch the item's select link; got \(url)")
    }

    // MARK: - G12 / G13 / G14 — the W14.4 (b/d) + W14.3 checks that sat on the owner's manual list
    //
    // Each of these shipped with unit proof and a "live GUI drive → Daemon Report" tail, i.e. behaviour
    // never once driven through the real UI. They run here, off-screen in the Tart VM, which is what
    // W21.vmgui-c exists for. W14.4's third tail — (c) the cross-window chip recolour — is now covered
    // separately by `testW21_CrossWindowPassageChipReStylesAfterSourceTrash`, which needs a deliberate,
    // scratch-only source trash rather than G14's read-only raise/focus setup.

    /// G12 — per-window column visibility (W14.4 d). The Note window hides the `sources` column, which is
    /// always blank for notes; the Extracts window shows it. `NotesAppSettings.defaultHiddenColumns(for:)`
    /// decides that per window kind and `NotesTableView` applies it as `NSTableColumn.isHidden`, so a hidden
    /// column materialises no cell views at all — its per-row cell id is simply absent from the
    /// accessibility tree. That is what makes the negative half of this check meaningful, and it is paired
    /// with the positive half in the other window (same row, same identifier, present), so a typo in the
    /// identifier cannot pass itself off as "correctly hidden".
    ///
    /// Read-only w.r.t. the store. Deliberately uses the EXTRACT row: `sourcesText` is a count for extracts
    /// and blank for notes, and an empty `NSTextField` may not surface in the a11y tree at all — so on a
    /// note row this check could not tell "column hidden" from "cell empty".
    func testG12_SourcesColumnIsHiddenInTheNoteWindowAndShownInTheExtractsWindow() throws {
        try withFixture { try runG12_SourcesColumnIsHiddenInTheNoteWindowAndShownInTheExtractsWindow() }
    }

    private func runG12_SourcesColumnIsHiddenInTheNoteWindowAndShownInTheExtractsWindow() throws {
        let noteWin = app.windows["Archive Notes"]
        XCTAssertTrue(noteWin.waitForExistence(timeout: 10), "the Note window should exist")

        // Note window: show BOTH kinds so the extract row is listed here too, then assert its title cell
        // exists (the row IS there) while its sources cell does not (that column is hidden).
        XCTAssertTrue(setKind(to: "Both", in: noteWin), "should switch the Note window's kind filter to Both")
        let noteTitleCell = noteWin.descendants(matching: .any)["an.cell.title.\(Self.idExtract)"]
        XCTAssertTrue(noteTitleCell.waitForExistence(timeout: 20),
                      "the extract row should be listed in the Note window once Both kinds are shown")
        let noteSourcesCell = noteWin.descendants(matching: .any)["an.cell.sources.\(Self.idExtract)"]
        XCTAssertFalse(noteSourcesCell.waitForExistence(timeout: 3),
                       "the Note window hides the sources column, so that row should have no sources cell")

        // Extracts window: the same row, the same identifier — present, because the column is shown.
        let extractWin = try openExtractsWindow()
        let extractTitleCell = extractWin.descendants(matching: .any)["an.cell.title.\(Self.idExtract)"]
        XCTAssertTrue(extractTitleCell.waitForExistence(timeout: 20),
                      "the extract row should be listed in the Extracts window")
        let extractSourcesCell = extractWin.descendants(matching: .any)["an.cell.sources.\(Self.idExtract)"]
        XCTAssertTrue(extractSourcesCell.waitForExistence(timeout: 10),
                      "the Extracts window shows the sources column, so that row should have a sources cell")

        closeExtractsWindow(extractWin)
    }

    /// G13 — a live copy→paste carries inline-image BYTES into the extract's own `assets/` (W14.3). The
    /// shipped fix made `MarkdownEditorView.handlePassagePaste` import the `com.archivenotes.passage`
    /// payload's bytes via `ExtractBuilder.pastedExtractMarkdown(from:importingAssetsVia:)` instead of
    /// inserting bare references that render as missing-asset placeholders until re-saved. Unit tests cover
    /// the builder; this is the end-to-end drive, and it asserts **bytes**, not just a reference: the file
    /// that lands in the extract must be byte-identical to the one in the source note.
    ///
    /// Self-contained rather than fixture-dependent: the fixture's only `![](assets/…)` line is a
    /// reader-page block's thumbnail, which the chip CONSUMES, so no fixture note carries a free-standing
    /// inline image. So this pastes one in first (the G4 path) and then copies it out. Depending on G4
    /// having run would be wrong regardless — XCTest orders methods alphabetically and `testG13…` sorts
    /// before `testG4…`.
    ///
    /// Both new seams exist because ⌘C/⌘V route to the FIRST RESPONDER and XCUITest cannot reliably make the
    /// styled TextKit-2 text view first responder — the same reason `an.editor.test.select` and
    /// `.pasteImage` exist. They call the production `copy(_:)`/`paste(_:)` handlers verbatim; only the
    /// keystroke is bypassed (the literal ⌘C/⌘V gesture stays owner-eye, like G2's typing).
    /// Writes only inside the scratch fixture — `idPlain`'s and `idExtract`'s own `assets/`.
    func testG13_LiveCopyPasteImportsInlineImageBytesIntoTheExtract() throws {
        try withFixture { try runG13_LiveCopyPasteImportsInlineImageBytesIntoTheExtract() }
    }

    private func runG13_LiveCopyPasteImportsInlineImageBytesIntoTheExtract() throws {
        guard let png = Self.makePNGData() else {
            return XCTFail("should build PNG bytes for the pasteboard")
        }
        let sourceAssetsBefore = Set(assetFiles(inItemDir: Self.idPlain))
        let extractAssetsBefore = Set(assetFiles(inItemDir: Self.idExtract))

        func newAsset(in dir: String, since before: Set<String>) -> String? {
            Set(assetFiles(inItemDir: dir)).subtracting(before).first { $0.hasSuffix(".png") }
        }
        func assetBytes(_ dir: String, _ name: String) -> Data? {
            try? Data(contentsOf: URL(fileURLWithPath: itemsDir + "/" + dir + "/assets/" + name))
        }

        // --- 1. Give the source NOTE a free-standing inline image (the G4 path). ---
        selectItem(uuid: Self.idPlain)
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "editor text view should exist")
        XCTAssertTrue(pollUntil(timeout: 10) { !((editor.value as? String) ?? "").isEmpty },
                      "the note body should load before pasting")
        ensureStyled()
        let pb = NSPasteboard.general
        pb.clearContents()
        XCTAssertTrue(pb.setData(png, forType: .png), "should seed the pasteboard with PNG bytes")
        XCTAssertTrue(pasteImageViaSeam(), "the DEBUG image-paste seam must be drivable")
        XCTAssertTrue(pollUntil(timeout: 12) { newAsset(in: Self.idPlain, since: sourceAssetsBefore) != nil },
                      "the pasted image should land in the source note's assets/")
        guard let sourceAsset = newAsset(in: Self.idPlain, since: sourceAssetsBefore),
              let sourceBytes = assetBytes(Self.idPlain, sourceAsset), !sourceBytes.isEmpty else {
            return XCTFail("should read the pasted asset's bytes back out of the source note")
        }

        // --- 2. Copy the whole note body as a passage (the length is clamped, so this selects all). ---
        XCTAssertTrue(setEditorSelection(location: 0, length: 100_000),
                      "the DEBUG selection seam must be drivable")
        XCTAssertTrue(clickStripButton("an.editor.test.copyPassage", timeout: 10),
                      "the copy-passage seam must be drivable (an.editor.test.copyPassage)")
        // The COPY's own verdict, carrying the count of image bytes it actually put on the pasteboard
        // (W21.vmgui-g13). A copy that succeeds with imgs=0 makes the paste report `ok` while importing
        // nothing — the leading explanation for this test's RED, and previously unobservable.
        let copyOutcome = copyPassageOutcome()
        XCTAssertTrue(copyOutcome.hasPrefix("ok"),
                      "the passage COPY must succeed, not decline — it reported: \(copyOutcome)")
        XCTAssertFalse(copyOutcome.contains("imgs=0"),
                       "the copy must embed the source note's image bytes in the payload, or the paste has "
                       + "nothing to import — it reported: \(copyOutcome)")

        // --- 3. Paste it into the EXTRACT — `handlePassagePaste` declines unless an extract is loaded. ---
        setKind(to: "Both", in: app.windows["Archive Notes"])
        selectItem(uuid: Self.idExtract)
        XCTAssertTrue(pollUntil(timeout: 12) { ((editor.value as? String) ?? "").contains("Moore says") },
                      "selecting the extract should load its body into the editor")
        ensureStyled()
        // Not `_ =`: this silently failed for the whole life of the test (the field was never cleared, so the
        // parse produced three parts and the seam was never called). W21.vmgui-g13.
        XCTAssertTrue(setEditorSelection(location: 0, length: 0),
                      "the selection seam must be drivable for the paste's caret")
        XCTAssertTrue(clickStripButton("an.editor.test.pastePassage", timeout: 10),
                      "the paste-passage seam must be drivable (an.editor.test.pastePassage)")
        // The paste's OWN verdict (W21.vmgui-g13). Asserting the button was clickable proved nothing about
        // whether the paste ran: `handlePassagePaste` declines at four guards and reported that only through
        // a Bool the seam discarded. Every assertion below quotes this, so a failure names its own cause.
        let outcome = pastePassageOutcome()

        // --- 4. The BYTES must be in the extract's own assets/, and the .md must reference them there. ---
        XCTAssertTrue(outcome.hasPrefix("ok"),
                      "the passage paste must RUN, not decline — it reported: \(outcome) "
                      + "(the target extract is \(Self.idExtract.prefix(8)))")
        // ⚠️ ORDER IS LOAD-BEARING. `continueAfterFailure = false`, so the FIRST failing assertion aborts
        // the test — a discriminating check placed after the one that fails never runs. This one goes first
        // for exactly that reason: it separates "the paste declined" from "the paste imported into the WRONG
        // item". `ItemAssetStore.addAsset` picks its directory from `itemID`, which
        // `NoteEditorPane.refreshAssetStore(for:)` retargets per selection, so a paste against a stale
        // target writes a SECOND copy into the source note — on the filesystem indistinguishable from no
        // import at all, unless you look where the bytes should NOT be. (W21.vmgui-g13)
        XCTAssertEqual(Set(assetFiles(inItemDir: Self.idPlain)).subtracting(sourceAssetsBefore).count, 1,
                       "the extract paste must not add an asset to the SOURCE note — it should hold exactly "
                       + "the one image step 1 pasted. The paste reported: \(outcome)")
        XCTAssertTrue(pollUntil(timeout: 15) { newAsset(in: Self.idExtract, since: extractAssetsBefore) != nil },
                      "the pasted passage's image bytes should be imported into the extract's own assets/ "
                      + "— the paste reported: \(outcome)")
        guard let importedAsset = newAsset(in: Self.idExtract, since: extractAssetsBefore) else { return }
        XCTAssertEqual(assetBytes(Self.idExtract, importedAsset), sourceBytes,
                       "the imported file must be byte-identical to the source note's asset — a reference "
                       + "without the bytes is exactly the W14.3 bug")
        XCTAssertTrue(pollUntil(timeout: 10) {
            (rawMarkdown(inItemDir: Self.idExtract) ?? "").contains("](assets/\(importedAsset))")
        }, "the extract .md should reference the imported asset by its own assets/ path")
        // (Both items are left dirty — the runner can't delete under /Users/; the next pre-run fixture
        // rebuild restores them.)
    }

    /// G14 — the target window is RAISED and FOCUSED, not merely updated (W14.4 b). Two phases over one
    /// setup, matching the two triggers the shipped fix wired: `NotesModel.createExtract` routes the new
    /// extract through `openItem`, and `NoteEditorPane.handleOpen` fronts the featuring window
    /// (`openWindow(id:)` + `NSApp.activate`) — for jump-to-source as well.
    ///
    /// Asserted through the DEBUG `an.status.keyWindow` probe, which both windows carry under the same
    /// identifier so a window-scoped query answers *about that window*. XCUITest exposes no
    /// `isKeyWindow`/`isMainWindow` on a window element, so without that probe this check could only assert
    /// the *selection* half while claiming a raise it never observed. Both windows are asserted at each
    /// step (one key, the other not), because "the target is key" alone would also hold if nothing moved.
    ///
    /// W14.4 (c)'s cross-window chip recolour is intentionally separate in
    /// `testW21_CrossWindowPassageChipReStylesAfterSourceTrash`: it must trash the cited note in the
    /// generated fixture and observe the other window's freshly re-styled text storage. Keeping this G14
    /// route read-only makes its raise/focus proof independent of that Tier-2 mutation.
    func testG14_CreateExtractAndJumpRaiseTheFeaturingWindow() throws {
        try withFixture { try runG14_CreateExtractAndJumpRaiseTheFeaturingWindow() }
    }

    private func runG14_CreateExtractAndJumpRaiseTheFeaturingWindow() throws {
        let noteWin = app.windows["Archive Notes"]
        XCTAssertTrue(noteWin.waitForExistence(timeout: 10), "the Note window should exist")
        let extractWin = try openExtractsWindow()

        // --- Phase 1: ⌘⌥E in the Note window must raise the EXTRACTS window. ---
        // Focus the Note window first (opening the Extracts window took it), so a raise is a real
        // transition rather than the state we started in.
        // Front the Note window through the WINDOW MENU, not by clicking inside it. The two windows open
        // stacked with a one-pixel cascade offset — measured in the VM 2026-08-10:
        //     note    (417, 265, 1121, 612)
        //     extract (417, 266, 1121, 612)   ← on top, and key
        // so every element in the Note window sits under the Extracts window, and a coordinate click
        // aimed at one of its cells lands on the Extracts window instead. `selectItem` alone therefore
        // left the Note window NOT key and this check failed for a reason that looks like the product
        // refusing to take focus. (It also means the row was never actually selected.)
        frontWindow(named: "Archive Notes")
        selectItem(uuid: Self.idPlain)
        XCTAssertTrue(pollUntil(timeout: 10) { isKey(noteWin) },
                      "selecting in the Note window should make it key before the trigger")
        XCTAssertFalse(isKey(extractWin), "the Extracts window should not be key at this point")

        // Every query below is window-SCOPED: both windows carry an `an.editor.text` and a control strip,
        // so an unscoped one resolves to "multiple matching elements" and throws.
        let noteEditor = noteWin.textViews["an.editor.text"]
        XCTAssertTrue(noteEditor.waitForExistence(timeout: 10), "the Note window's editor should exist")
        XCTAssertTrue(pollUntil(timeout: 10) { !((noteEditor.value as? String) ?? "").isEmpty },
                      "the note body should load before selecting text")
        XCTAssertTrue(setEditorSelection(location: 0, length: 8, in: noteWin),
                      "the DEBUG selection seam must be drivable")
        app.activate()
        app.typeKey("e", modifierFlags: [.command, .option])

        XCTAssertTrue(pollUntil(timeout: 15) { isKey(extractWin) },
                      "Create Extract should front + focus the Extracts window (W14.4 b)")
        XCTAssertFalse(isKey(noteWin), "the Note window should have resigned key to the Extracts window")
        // The raise comes paired with a selection: the new extract's body is the copied passage, so the
        // Extracts window's editor now holds content.
        let extractEditor = extractWin.textViews["an.editor.text"]
        XCTAssertTrue(pollUntil(timeout: 15) { !((extractEditor.value as? String) ?? "").isEmpty },
                      "the raised Extracts window should have loaded the new extract")

        // --- Phase 2: Jump-to-Source from the Extracts window must raise the NOTE window back. ---
        // The new extract carries a note-passage chip pointing at idPlain, a `.note`, so `openAction`
        // routes the jump to the note-featuring window.
        XCTAssertTrue(clickStripButton("an.editor.test.jump", timeout: 10, in: extractWin),
                      "the jump seam must be drivable in the Extracts window")

        XCTAssertTrue(pollUntil(timeout: 15) { isKey(noteWin) },
                      "Jump to Source should front + focus the Note window (W14.4 b)")
        XCTAssertFalse(isKey(extractWin),
                       "the Extracts window should have resigned key back to the Note window")

        closeExtractsWindow(extractWin)
    }

    // MARK: - G12/G13/G14 helpers

    /// Is `win` the key window, per its own `an.status.keyWindow` probe? The probe publishes `key`/`notkey`
    /// as its accessibility VALUE and `key:<Note|Extract>` as its label; accept either, since some SwiftUI
    /// static texts surface their string only via `.label` (the `an.status.indexReady` lesson, W8-S8b).
    private func isKey(_ win: XCUIElement) -> Bool {
        let probe = win.descendants(matching: .any)["an.status.keyWindow"].firstMatch
        guard probe.exists else { return false }
        if let v = probe.value as? String, !v.isEmpty { return v == "key" }
        return probe.label.hasPrefix("key:")
    }

    /// Bring a `Window(title:id:)` scene to the front by NAME, through the same automatic Window menu
    /// `openExtractsWindow` uses. Coordinate-free on purpose.
    ///
    /// Clicking inside a window does not reliably front it in this app: the Note and Extracts windows
    /// open stacked with a one-pixel cascade offset, so any click aimed at an element of the lower
    /// window lands on the upper one. Anything that needs a specific window to be KEY must say so by
    /// name — a click can only ever confirm what was already on top.
    private func frontWindow(named title: String) {
        app.activate()
        let windowMenu = app.menuBars.menuBarItems["Window"]
        XCTAssertTrue(windowMenu.waitForExistence(timeout: 10), "the Window menu should exist")
        windowMenu.click()
        let item = app.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 5),
                      "Window ▸ \(title) should be offered for that Window scene")
        item.click()
    }

    /// The Extracts window, opened if it is not already up. SwiftUI's automatic Window menu carries one
    /// item per `Window(title:id:)` scene, so `Window ▸ Extracts` fronts (or reopens) it; the app declares
    /// no custom command for this. Whether that window is already open at launch is state-dependent, so
    /// handle both.
    private func openExtractsWindow() throws -> XCUIElement {
        let win = app.windows["Extracts"]
        if !win.exists {
            let windowMenu = app.menuBars.menuBarItems["Window"]
            XCTAssertTrue(windowMenu.waitForExistence(timeout: 10), "the Window menu should exist")
            windowMenu.click()
            let item = app.menuItems["Extracts"]
            XCTAssertTrue(item.waitForExistence(timeout: 5),
                          "Window ▸ Extracts should be offered for the second Window scene")
            item.click()
        }
        XCTAssertTrue(win.waitForExistence(timeout: 15), "the Extracts window should be open")
        return win
    }

    /// Put the window set back the way the rest of the suite expects to find it. SwiftUI persists which
    /// `Window` scenes were open, the container is NOT wiped between tests in a run, and the sibling checks
    /// query unscoped (`app.textViews["an.editor.text"]`) — so a second window left open could make a LATER
    /// test fail with "multiple matching elements", which reads as a bug in whatever ran next. Called at the
    /// end of the two tests that open it. (If one of them FAILS first, `continueAfterFailure = false` aborts
    /// before this runs and the run is already RED, so the cascade is noise on a real failure, not a
    /// false one.)
    private func closeExtractsWindow(_ win: XCUIElement) {
        guard win.exists else { return }
        let close = win.buttons[XCUIIdentifierCloseWindow]
        if close.waitForExistence(timeout: 5), close.isHittable { close.click() }
        _ = pollUntil(timeout: 5) { !win.exists }
    }
}
