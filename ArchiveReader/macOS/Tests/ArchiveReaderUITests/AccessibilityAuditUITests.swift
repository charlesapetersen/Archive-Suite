import XCTest

/// W40.e3 — Xcode's accessibility audit (`packages/UITestSupport/Runner/AccessibilityAudit.swift`) over the
/// Reader's main screens: the navigation window with a document selected, the preview sheet, the document viewer
/// window, and Settings. One test per appearance, because contrast differs and the appearance is a launch argument.
/// Read-only: nothing here edits the fixture. Findings and their triage:
/// `verification/evidence/core/W40.e3-accessibility-audit.md`.
final class AccessibilityAuditUITests: FixtureUITestCase {

    func testMainScreensPassAuditInLightMode() throws {
        relaunch(LayoutGuard.lightModeArguments)
        auditMainScreens(appearance: "light")
    }

    func testMainScreensPassAuditInDarkMode() throws {
        relaunch(LayoutGuard.darkModeArguments)
        auditMainScreens(appearance: "dark")
    }

    // The same sweeps with the mode coming from the Appearance setting rather than the test argument
    // (W48.appearance-reader; plan rule 7: the existing checks run in the new mode as well as the old).
    func testMainScreensPassAuditInLightModeBySetting() throws {
        relaunch(LayoutGuard.lightSettingArguments)
        auditMainScreens(appearance: "light")
    }

    func testMainScreensPassAuditInDarkModeBySetting() throws {
        relaunch(LayoutGuard.darkSettingArguments)
        auditMainScreens(appearance: "dark")
    }

    /// `FixtureUITestCase.setUp` has already launched with the fixture; relaunch with the appearance added.
    private func relaunch(_ appearance: [String]) {
        app.terminate()
        app.launchArguments += appearance + ["-ar.showSidebar", "YES", "-ar.showTagCloud", "YES"]
        app.launch()
        app.activate()
        XCTAssertTrue(table.waitForExistence(timeout: 10), "Table should appear after the relaunch")
        waitForRows(minimum: 1, timeout: 15)
    }

    private func auditMainScreens(appearance: String) {
        continueAfterFailure = true   // an issue on one screen must not hide the next screen's
        let sweep = AccessibilityAudit(app, appearance: appearance, in: self,
                                       known: Self.known)
        let main = app.windows["Archive Reader"]
        // The saved 900-pt window scrolls Type/Read off screen once both side panels are open. A wide window
        // keeps the actual table factories under the pixel check, rather than silently auditing only counts.
        let wide = LayoutGuard.dragCorner(of: main, to: CGPoint(x: main.frame.minX + 1800, y: main.frame.minY + 760))
        XCTAssertGreaterThan(wide.width, 1700)
        waitForRows(minimum: 3, timeout: 10)
        clickRow(0)
        LayoutGuard.waitUntilSettled(main)
        for (id, name) in [("ar.filter.tagField", "Filter by tags"), ("ar.filter.name", "Filter file name"),
                           ("ar.filter.ocr", "Search OCR text"), ("ar.table", "Archive files")] {
            XCTAssertEqual(main.descendants(matching: .any).matching(identifier: id).firstMatch.label, name)
        }
        for (id, name) in [("ar.divider.sidebar", "Sidebar width"), ("ar.divider.tagCloud", "Tags in view width")] {
            let splitter = main.splitters[id]
            XCTAssertTrue(splitter.exists, "\(id) should expose the native splitter role")
            XCTAssertEqual(splitter.label, name)
            XCTAssertGreaterThan(splitter.frame.height, 300, "the splitter must fill its panel's height")
        }
        // The native accessibility handle must still support the original pointer resize gesture.
        for id in ["ar.divider.sidebar", "ar.divider.tagCloud"] {
            let splitter = main.splitters[id]
            let before = splitter.frame.midX
            splitter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: splitter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    .withOffset(CGVector(dx: 20, dy: 0)))
            LayoutGuard.waitUntilSettled(main)
            XCTAssertGreaterThan(splitter.frame.midX, before + 10, "\(id) should move with a pointer drag")
            splitter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: splitter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    .withOffset(CGVector(dx: -20, dy: 0)))
            LayoutGuard.waitUntilSettled(main)
            XCTAssertEqual(splitter.frame.midX, before, accuracy: 2)
        }
        assertSmallTextContrast(in: main, appearance: appearance, requiresTableLabels: true)
        sweep.audit(main, screen: "navigation window")
        captureScreenshot("reader-aa-navigation-\(appearance)")

        toolbarButton("ar.toolbar.preview").click()
        let open = app.buttons["ar.preview.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5), "the preview sheet should open")
        LayoutGuard.waitUntilSettled(main)
        // macOS exposes an empty AXSheet wrapper; the actual content is a separate SwiftUI group.
        // Assert a real control is inside our group, so an empty wrapper can never make the audit pass.
        let preview = main.groups["ar.preview.content"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue(preview.buttons["ar.preview.open"].exists)
        assertPageTitles(in: preview)
        assertSmallTextContrast(in: preview, appearance: appearance)
        sweep.audit(preview, screen: "preview sheet")
        captureScreenshot("reader-aa-preview-\(appearance)")

        open.click()
        let viewer = app.windows.matching(NSPredicate(format: "title != %@", "Archive Reader")).firstMatch
        XCTAssertTrue(viewer.waitForExistence(timeout: 10), "Open in Viewer should bring up the document window")
        LayoutGuard.waitUntilSettled(viewer)
        assertPageTitles(in: viewer)
        assertSmallTextContrast(in: viewer, appearance: appearance)
        sweep.audit(viewer, screen: "document viewer")
        captureScreenshot("reader-aa-viewer-\(appearance)")
        viewer.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(viewer.waitForNonExistence(timeout: 5), "the viewer should close")

        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(NSPredicate(format: "title != %@", "Archive Reader")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "Settings should open")
        LayoutGuard.waitUntilSettled(settings)
        sweep.audit(settings, screen: "settings")
        captureScreenshot("reader-aa-settings-\(appearance)")
        sweep.finish()
    }

    /// Check the assigned small labels even when Xcode does not nominate them as contrast issues. The
    /// general audit's 24-pt-frame heuristic is unsuitable here: these are all small text, so AA is 4.5:1.
    private func assertSmallTextContrast(in container: XCUIElement, appearance: String, requiresTableLabels: Bool = false) {
        guard let tree = try? container.snapshot(), let pixels = ScreenPixels(XCUIScreen.main.screenshot()) else {
            XCTFail("Could not capture the small-text contrast check")
            return
        }
        var measured = 0
        var tableLabels = Set<String>()
        var families = Set<String>()
        func visit(_ node: XCUIElementSnapshot) {
            defer { node.children.forEach(visit) }
            // SwiftUI exposes static text as AXValue in snapshots; AppKit's warning uses AXLabel.
            let label = node.label.isEmpty ? (node.value as? String ?? "") : node.label
            guard node.elementType == .staticText, !label.isEmpty, tree.frame.contains(node.frame) else { return }
            let id = node.identifier
            let target = ["ar.sidebar.allFiles", "ar.sidebar.folder", "ar.sidebar.smart", "ar.tagCloud"].contains(id)
                || id.hasPrefix("ar.cell.type.") || id.hasPrefix("ar.cell.read.")
                || (id.hasPrefix("ar.cell.warning.") && label == "OCR warning")
                || label.range(of: #"^\d+ of \d+$"#, options: .regularExpression) != nil
                || label.contains(" shown · ") || label.hasSuffix(" selected")
            guard target else { return }
            let ratio = pixels.contrast(under: node.frame)
            print("[reader-aa] \(appearance) \(id) \(label) frame=\(node.frame): \(ratio ?? 0)")
            XCTAssertGreaterThanOrEqual(ratio ?? 0, 4.5, "\(appearance) \(id) \(label) small text must clear AA")
            measured += 1
            if Int(label) != nil {
                if id == "ar.sidebar.allFiles" { families.insert("allFilesCount") }
                if id == "ar.sidebar.folder" { families.insert("folderCount") }
                if id == "ar.tagCloud" { families.insert("tagCloudCount") }
            }
            if label.contains(" shown · ") { families.insert("summary") }
            if label.hasSuffix(" selected") { families.insert("selectedCount") }
            if label.range(of: #"^\d+ of \d+$"#, options: .regularExpression) != nil { families.insert("pageCounter") }
            for column in ["type", "read", "warning"] where id.hasPrefix("ar.cell.\(column).") {
                tableLabels.insert(column)
            }
        }
        visit(tree)
        XCTAssertGreaterThan(measured, 0, "Each navigation/preview/viewer screen must expose the small text being checked")
        if requiresTableLabels {
            XCTAssertEqual(tableLabels, ["type", "read", "warning"], "Type, Read and a real warning must all be visible")
            XCTAssertTrue(Set(["allFilesCount", "folderCount", "tagCloudCount", "summary", "selectedCount"])
                .isSubset(of: families), "All assigned counts/status labels must be measured: \(families)")
        } else {
            XCTAssertTrue(families.contains("pageCounter"), "The preview/viewer page counter must be measured")
        }
    }

    private func assertPageTitles(in container: XCUIElement) {
        // XCUITest prints AXTitle in the snapshot but does not expose it as label/value/identifier.
        // Check the actual element subtree, excluding the query chain that follows it.
        let tree = container.debugDescription.components(separatedBy: "Path to element:").first ?? ""
        for title in ["Original image page", "OCR text page"] {
            let present = tree.contains("title: '\(title)'")
            print("[pdf-external] \(title): \(present ? "present" : "MISSING")")
            XCTAssertTrue(present, "the PDF page must have an AXTitle in the external tree: \(title)")
        }
    }

    // No contrast exemptions: counts, status, page counters, Type/Read and warnings are audited in both modes.
    @MainActor static let known: [AccessibilityAudit.KnownIssue] = []
}
