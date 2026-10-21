import XCTest
import AppKit
import Darwin   // getpwuid / getuid — the opt-in flag lives in the REAL home

/// W40.e12 — the screen-by-screen visual review tour (the Processor half of `W40.e10` / `W40.e11`).
///
/// Opens every screen, sheet, popover, menu and empty state the Processor reaches without starting a run, in
/// light and dark, at the main window's minimum size and at a typical size, and screenshots each one twice: on
/// open and again once the app is idle. A person — or a session — then LOOKS at every shot; this file asserts
/// only that the tour reached each surface, never anything about how it looked.
///
/// The run-time review sheets (document segment review, collection confirm, manual tagging, finalize) open
/// only inside a real run; `W40.d2` drives those by hand on a ground-truth collection. What this tour reaches
/// are the three modes, Settings in each backend, the Tools sheets, the key and Local Agent wizards, and the
/// DEBUG launch seams `ProcessorUITests` already uses (multi-page re-OCR, flagged review, the Live Capture
/// finishing scrim and emptied pane), plus `-APUITestSyntheticVolume`: 60 dropped page images, some with long
/// archival names.
///
/// **Opt-in.** The tour takes minutes and writes a few hundred PNGs, so it must not ride along in the default
/// VM selector or the health gate. It runs only while `~/.visual-review` exists in the guest (the directory
/// above the Processor's GUI fixture); `vm-gui-runner.sh` creates it for `VISUAL_REVIEW=1` and removes it after:
///
///     VISUAL_REVIEW=1 ONLY_TESTING=ArchiveProcessorUITests/VisualReviewUITests ops/gui/vm-gui-runner.sh processor xcuitest
///
/// **Writes nothing that matters.** Scratch IN/OUT, as in `ProcessorUITests`; no OCR, no key, no network. Every
/// sheet and alert is dismissed with Cancel, Done or Escape. The Settings pass switches the OCR backend to look
/// at each one and puts it back on Direct API.
///
/// Shots are cropped to the app's windows, sheets and popovers (plus a margin; menus keep the whole screen).
/// Names: `uitest-visual-<appearance>-<size>-<surface>-<open|idle>`.
@MainActor
final class VisualReviewUITests: XCTestCase {

    static let flagPath: String = {
        let home: String
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            home = String(cString: dir)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser.path
        }
        return "\(home)/.visual-review"
    }()

    let idleDelay: TimeInterval = 3

    private var app: XCUIApplication!
    private var scratchRoot: URL!
    private var shotDirectory: URL!
    private var missing: [String] = []
    private var prefix = ""

    override func setUp() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.flagPath),
                          "visual review is opt-in — VISUAL_REVIEW=1 in vm-gui-runner.sh")
        continueAfterFailure = true
        scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-processor-visual-\(UUID().uuidString)", isDirectory: true)
        shotDirectory = scratchRoot.appendingPathComponent("shots", isDirectory: true)
        for sub in ["IN", "OUT", "shots"] {
            try FileManager.default.createDirectory(at: scratchRoot.appendingPathComponent(sub, isDirectory: true),
                                                    withIntermediateDirectories: true)
        }
        app = .archiveProcessorUITestApp()
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
    }

    // MARK: - The tours

    func testTourLight() throws { tour(dark: false) }
    func testTourDark() throws { tour(dark: true) }
    func testStatesLight() throws { states(dark: false) }
    func testStatesDark() throws { states(dark: true) }
    func testVolumeLight() throws { volume(dark: false) }
    func testVolumeDark() throws { volume(dark: true) }

    private enum WindowSize: String, CaseIterable {
        case min, typical
        /// `min` asks for far less than the window allows, so the app's own minimum wins.
        var main: CGSize { self == .min ? CGSize(width: 400, height: 300) : CGSize(width: 1280, height: 860) }
    }

    /// Every mode, its menus and its sheets, at both sizes; Settings once, since its window is fixed-size.
    private func tour(dark: Bool) {
        for size in WindowSize.allCases {
            relaunch(dark: dark)
            prefix = "\(dark ? "dark" : "light")-\(size.rawValue)"
            resizeMainWindow(to: size.main)

            selectMode("Process Files")
            shoot("files-empty")
            scrollMain()
            shoot("files-empty-scrolled")
            let picker = element("ap.segmentation.picker")
            if picker.waitForExistence(timeout: 3) {
                picker.click()
                pause(0.5)
                shootOnce("files-segmentation-menu")
                escape()
            } else { missing.append("segmentation picker") }
            if menu("Processing") { shootOnce("menu-processing"); escape() }

            selectMode("Live Capture")
            shoot("live-idle")
            scrollMain()
            shoot("live-idle-scrolled")

            selectMode("Tools")
            shoot("tools")
            toolsSheets()

            selectMode("Process Files")
            if size == .typical { settingsWindow() }
        }
        reportMissing()
    }

    private func toolsSheets() {
        if clickButton("Compare Models…") {
            if waitForSheet() { shoot("tools-compare-models-sheet") } else { missing.append("Compare Models sheet") }
            cancel()
        }
        if clickButton("View History…") {
            if waitForSheet() {
                shoot("tools-history-sheet")
                if clickButton("Clear History…") || clickButton("Clear History") {
                    pause(0.8)
                    shoot("tools-history-clear-confirm")
                    cancel()
                }
            } else { missing.append("History sheet") }
            if !clickButton("Done") { escape() }
            pause(0.5)
        }
        // Test Resolution is disabled without a key; the disabled card is in the "tools" shot.
    }

    private func settingsWindow() {
        let settings = openSettings()
        guard let settings else { missing.append("Settings window"); return }
        shoot("settings-direct")
        scrollSettings(settings, name: "settings-direct")
        settings.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: 4000)
        pause(0.5)

        // A help popover (one is enough: they share one view).
        let help = settings.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'help' OR label CONTAINS[c] 'question'")).firstMatch
        if help.waitForExistence(timeout: 2) && help.isHittable {
            help.click()
            if app.popovers.firstMatch.waitForExistence(timeout: 3) { shoot("settings-help-popover") }
            else { missing.append("help popover") }
            escape()
        } else { missing.append("help button") }

        if clickButton("Save current settings as a profile…") {
            pause(0.8)
            shoot("settings-save-profile-alert")
            cancel()
        }

        if clickButton("Manage custom models…") {
            if waitForSheet() {
                shoot("settings-manage-models")
                if clickButton("Add Model...") || clickButton("Add Model…") {
                    pause(1)
                    shoot("settings-add-model")
                    cancel()
                }
            } else { missing.append("Manage models sheet") }
            if !clickButton("Done") { escape() }
            pause(0.5)
        }

        let guided = element("ap.settings.guidedKeySetup")
        if guided.waitForExistence(timeout: 3) {
            guided.click()
            if element("ap.keyWizard.providerPicker").waitForExistence(timeout: 5) {
                shoot("key-wizard")
                wizardProviders()
            } else { missing.append("key wizard") }
            cancel()
            pause(0.5)
        } else { missing.append("guided key setup button") }

        for backend in ["API Gateway", "Local CLI Agent", "Apple Vision (on this Mac)"] {
            guard chooseBackend(backend) else { continue }
            let slug = backend.split(separator: " ").first.map { String($0).lowercased() } ?? "backend"
            shoot("settings-\(slug)")
            scrollSettings(settings, name: "settings-\(slug)")
            if backend == "Local CLI Agent" {
                let wizard = element("ap.settings.localAgentGuidedSetup")
                if wizard.waitForExistence(timeout: 3) {
                    wizard.click()
                    if element("ap.localAgentWizard.toolPicker").waitForExistence(timeout: 5) {
                        shoot("local-agent-wizard")
                    } else { missing.append("Local Agent wizard") }
                    if !clickButton("Done") { cancel() }
                    pause(0.5)
                } else { missing.append("Local Agent guided setup") }
            }
        }
        _ = chooseBackend("Direct API")
        app.typeKey("w", modifierFlags: .command)
        pause(0.5)
    }

    /// The key wizard's provider choices: each changes the steps, console link and notes.
    private func wizardProviders() {
        let picker = element("ap.keyWizard.providerPicker")
        let segments = picker.radioButtons.allElementsBoundByIndex
        if segments.count > 1 {
            for (i, seg) in segments.enumerated().dropFirst() where seg.isHittable {
                seg.click()
                pause(0.5)
                shoot("key-wizard-provider\(i)")
            }
        } else {
            picker.click()
            let items = app.menuItems.allElementsBoundByIndex.filter { $0.isHittable }
            escape()
            for i in 1..<max(1, items.count) {
                picker.click()
                let item = app.menuItems.allElementsBoundByIndex.filter { $0.isHittable }
                guard i < item.count else { escape(); break }
                item[i].click()
                pause(0.5)
                shoot("key-wizard-provider\(i)")
            }
        }
    }

    // MARK: - Seeded states

    private func states(dark: Bool) {
        let appearance = dark ? "dark" : "light"
        for size in WindowSize.allCases {
            prefix = "\(appearance)-\(size.rawValue)"

            relaunch(dark: dark, extra: ["-APUITestSyntheticMultiPagePDF"])
            resizeMainWindow(to: size.main)
            shoot("files-multipage-pdf")
            scrollMain()
            shoot("files-multipage-pdf-scrolled")
            let choose = element("ap.ocr.institutionalComputeChoose")
            if size == .typical, choose.waitForExistence(timeout: 3) {
                choose.click()
                if app.buttons["Use Cluster Folder"].waitForExistence(timeout: 5) {
                    pause(1)
                    shootOnce("files-institutional-folder-panel")
                } else { missing.append("institutional folder panel") }
                escape()
            }

            relaunch(dark: dark, extra: ["-APUITestLocalAgent", "-APUITestSyntheticMultiPagePDF"])
            resizeMainWindow(to: size.main)
            shoot("files-local-agent")

            relaunch(dark: dark, extra: ["-APUITestFlaggedReview"])
            if element("flaggedReview.counter").waitForExistence(timeout: 10) {
                shoot("flagged-review-first")
                element("flaggedReview.split").click()
                pause(0.5)
                shoot("flagged-review-second")
                element("flaggedReview.keep").click()
                pause(0.5)
                shoot("flagged-review-answered")
            } else { missing.append("flagged review") }

            relaunch(dark: dark, extra: ["-APUITestLiveCaptureFinishingScrim"])
            resizeMainWindow(to: size.main)
            if element("live.finishing-throbber").waitForExistence(timeout: 10) { shoot("live-finishing-scrim") }
            else { missing.append("finishing scrim") }

            relaunch(dark: dark, extra: ["-APUITestLiveCaptureEmptyPaneClear"])
            resizeMainWindow(to: size.main)
            let clear = element("live.clear")
            if clear.waitForExistence(timeout: 10) {
                shoot("live-emptied-pane")
                clear.click()
                if app.sheets.firstMatch.waitForExistence(timeout: 5) { shoot("live-clear-confirm") }
                else { missing.append("clear confirmation") }
                let cancelButton = element("live.clear-cancel")
                if cancelButton.exists { cancelButton.click() } else { escape() }
            } else { missing.append("emptied pane") }
        }
        reportMissing()
    }

    /// 60 dropped page images, a seventh of them with 150-character archival names.
    private func volume(dark: Bool) {
        for size in WindowSize.allCases {
            prefix = "\(dark ? "dark" : "light")-\(size.rawValue)"
            relaunch(dark: dark, extra: ["-APUITestSyntheticVolume"])
            resizeMainWindow(to: size.main)
            shoot("files-volume")
            scrollMain()
            shoot("files-volume-scrolled")
            // The dropped-file list has its own scroll view inside the panel.
            let lists = app.windows.firstMatch.scrollViews.allElementsBoundByIndex
            if lists.count > 1 {
                lists[1].scroll(byDeltaX: 0, deltaY: -40000)
                pause(0.5)
                shoot("files-volume-list-end")
            }
        }
        reportMissing()
    }

    // MARK: - Mechanics

    private func relaunch(dark: Bool, extra: [String] = []) {
        app.terminate()
        app.launchArguments = UITestLaunch.arguments([
            "-APUITestMode",
            "-APUITestInputDirectory", scratchRoot.appendingPathComponent("IN").path,
            "-APUITestOutputDirectory", scratchRoot.appendingPathComponent("OUT").path,
        ] + (dark ? LayoutGuard.darkModeArguments : LayoutGuard.lightModeArguments) + extra)
        app.launchEnvironment["ARCHIVEPROC_HEADLESS"] = "1"
        app.launch()
        app.activate()
        if !app.windows.firstMatch.waitForExistence(timeout: 10) {
            print("PROCESSOR_UI_NO_WINDOW")
            missing.append("main window (\(extra.joined(separator: " ")))")
        }
        pause(1)
    }

    private func selectMode(_ title: String) {
        let win = app.windows.firstMatch
        for candidate in [win.radioButtons[title], win.buttons[title]] where candidate.exists {
            candidate.click()
            pause(1)
            return
        }
        missing.append("mode \(title)")
    }

    private func openSettings() -> XCUIElement? {
        app.activate()
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.containing(.any, identifier: "ap.settings.guidedKeySetup").firstMatch
        guard settings.waitForExistence(timeout: 10) else { return nil }
        pause(1)
        return settings
    }

    private func chooseBackend(_ title: String) -> Bool {
        let picker = element("ap.settings.backendPicker")
        guard picker.waitForExistence(timeout: 3) else { missing.append("backend picker"); return false }
        if !picker.isHittable {
            app.windows.containing(.any, identifier: "ap.settings.guidedKeySetup").firstMatch
                .scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: 4000)
            pause(0.5)
        }
        picker.click()
        let item = app.menuItems[title]
        guard item.waitForExistence(timeout: 3) else { missing.append("backend \(title)"); escape(); return false }
        item.click()
        pause(1)
        return true
    }

    /// Page down through the Settings form, one shot per screenful, until it stops moving.
    private func scrollSettings(_ settings: XCUIElement, name: String) {
        let form = settings.scrollViews.firstMatch
        guard form.exists else { missing.append("\(name) scroll view"); return }
        form.scroll(byDeltaX: 0, deltaY: 4000)   // to the top
        pause(0.3)
        for page in 1...8 {
            let before = settingsSnapshot(settings)
            form.scroll(byDeltaX: 0, deltaY: -520)
            pause(0.6)
            if settingsSnapshot(settings) == before { break }
            shoot("\(name)-p\(page)")
        }
        form.scroll(byDeltaX: 0, deltaY: 40000)
        pause(0.3)
    }

    /// The frames of the form's first few texts: equal before and after a scroll means the end was reached.
    private func settingsSnapshot(_ settings: XCUIElement) -> [CGRect] {
        settings.staticTexts.allElementsBoundByIndex.prefix(6).map(\.frame)
    }

    private func scrollMain(deltaY: CGFloat = -40000) {
        let win = app.windows.firstMatch
        let scroll = win.scrollViews.firstMatch
        if scroll.exists { scroll.scroll(byDeltaX: 0, deltaY: deltaY) } else { win.scroll(byDeltaX: 0, deltaY: deltaY) }
        pause(0.6)
    }

    /// Move the main window to the top-left of the screen, then drag its bottom-right corner so it is
    /// `target` in size (or the app's minimum, when `target` is below it).
    private func resizeMainWindow(to target: CGSize) {
        let win = app.windows.firstMatch
        guard win.waitForExistence(timeout: 5) else { missing.append("main window for resize"); return }
        func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
            let f = win.frame
            return win.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x - f.minX, dy: y - f.minY))
        }
        var f = win.frame
        let grab = CGPoint(x: f.minX + f.width * 0.8, y: f.minY + 12)
        point(grab.x, grab.y).click(forDuration: 0.2, thenDragTo: point(grab.x - f.minX + 40, grab.y - f.minY + 40))
        pause(0.5)
        f = win.frame
        point(f.maxX - 2, f.maxY - 2).click(forDuration: 0.2,
                                            thenDragTo: point(f.minX + target.width, f.minY + target.height))
        pause(1)
        print("[visual] main window \(prefix) requested \(target) got \(win.frame.size)")
    }

    private func shoot(_ surface: String, menu: Bool = false) {
        capture("\(prefix)-\(surface)-open", crop: !menu)
        pause(idleDelay)
        capture("\(prefix)-\(surface)-idle", crop: !menu)
    }

    /// One shot only — a menu closes on its own if left open too long under XCUITest.
    private func shootOnce(_ surface: String) {
        capture("\(prefix)-\(surface)-open", crop: false)
    }

    private func capture(_ name: String, crop: Bool) {
        let shot = XCUIScreen.main.screenshot()
        var rect = CGRect.null
        if crop {
            for group in [app.windows, app.popovers, app.sheets] {
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
        let url = shotDirectory.appendingPathComponent("uitest-visual-\(name).png")
        do {
            try data.write(to: url, options: .atomic)
            print("[shot] visual-\(name): wrote \(url.path)")
        } catch {
            print("[shot] visual-\(name): could not write \(url.path) — \(error)")
        }
    }

    @discardableResult
    private func menu(_ bar: String) -> Bool {
        let item = app.menuBars.element(boundBy: 0).menuBarItems[bar]
        guard item.waitForExistence(timeout: 2) else { missing.append("menu \(bar)"); return false }
        item.click()
        pause(0.5)
        return true
    }

    /// A button inside one of the app's windows (not its Touch Bar copy), clicked if it is there and enabled.
    @discardableResult
    private func clickButton(_ title: String) -> Bool {
        let button = app.windows.buttons.matching(NSPredicate(format: "title == %@ OR label == %@", title, title)).firstMatch
        guard button.waitForExistence(timeout: 2), button.isEnabled, button.isHittable else { return false }
        button.click()
        return true
    }

    private func waitForSheet() -> Bool {
        let ok = app.sheets.firstMatch.waitForExistence(timeout: 5)
        pause(1)
        return ok
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func cancel() {
        if !clickButton("Cancel") { escape() }
        pause(0.5)
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
