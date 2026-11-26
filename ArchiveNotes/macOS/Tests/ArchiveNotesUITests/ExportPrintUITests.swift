import XCTest

/// W49.notes-export-print — File ▸ Export… and Print… (⌘P) in the VM. The folder panel runs out of process, so the
/// app takes the folder and format from `-ANUITestExportPath` / `-ANUITestExportFormat` (DEBUG) and the rest of the
/// route is the real one: the menu item, the selection it reads, the save of open edits and the writer. The export
/// folder is a sibling of the scratch fixture (`AN-GUI-Export`), the one other path the runner may write.
final class ExportPrintUITests: NotesFixtureUITestCase {

    private var exportFormat = "markdown"

    static let exportPath: String = {
        URL(fileURLWithPath: canonicalFixturePath).deletingLastPathComponent()
            .appendingPathComponent("AN-GUI-Export", isDirectory: true).path
    }()

    override var extraLaunchArguments: [String] {
        ["-ANUITestExportPath", Self.exportPath, "-ANUITestExportFormat", exportFormat]
    }

    private func freshExportFolder() throws {
        let fm = FileManager.default
        try? fm.removeItem(atPath: Self.exportPath)
        try fm.createDirectory(atPath: Self.exportPath, withIntermediateDirectories: true)
    }

    private func exported() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: Self.exportPath)) ?? []).sorted()
    }

    private func fileMenuItem(_ title: String) -> XCUIElement {
        app.activate()
        let fileMenu = app.menuBars.menuBarItems["File"]
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 10), "the File menu should exist")
        fileMenu.click()
        return fileMenu.menuItems[title]
    }

    /// A note with a source block and an image: File ▸ Export… as Markdown writes a folder holding the `.md`, whose
    /// source line replaces the block header, and the image beside it under `assets/`.
    func testFileMenuExportsMarkdownWithItsImage() throws {
        exportFormat = "markdown"
        try freshExportFolder()
        try withFixture {
            XCTAssertTrue(mainWindow.waitForExistence(timeout: 10))
            XCTAssertTrue(waitForIndexReady(timeout: 20))
            _ = selectItem(uuid: Self.idReader)
            let export = fileMenuItem("Export…")
            XCTAssertTrue(export.waitForExistence(timeout: 5), "File ▸ Export… should exist")
            XCTAssertTrue(export.isEnabled, "Export… should be enabled with a note selected")
            XCTAssertTrue(app.menuBars.menuBarItems["File"].menuItems["Print…"].exists, "File ▸ Print… should exist")
            shot("file-menu-export")
            export.click()

            let folder = URL(fileURLWithPath: Self.exportPath).appendingPathComponent("Moore on Intel culture")
            XCTAssertTrue(pollUntil(timeout: 15) {
                FileManager.default.fileExists(atPath: folder.appendingPathComponent("Moore on Intel culture.md").path)
            }, "the note should be exported as a folder with its .md: \(exported())")
            let md = try String(contentsOf: folder.appendingPathComponent("Moore on Intel culture.md"), encoding: .utf8)
            XCTAssertTrue(md.hasPrefix("# Moore on Intel culture"), md)
            XCTAssertTrue(md.contains("> Source: sample.pdf — p. 1"), "the block's source should be a visible line: \(md)")
            XCTAssertTrue(md.contains("Moore on Intel's early egalitarian culture."), md)
            XCTAssertFalse(md.contains("<!--"), "no block header in the export: \(md)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("assets/p1-thumb.png").path),
                          "the image should be copied beside the .md")
        }
    }

    /// ⇧⌘E with the PDF format writes a PDF named after the note; a second export never replaces the first.
    func testShortcutExportsPDFWithoutReplacing() throws {
        exportFormat = "pdf"
        try freshExportFolder()
        try withFixture {
            XCTAssertTrue(mainWindow.waitForExistence(timeout: 10))
            XCTAssertTrue(waitForIndexReady(timeout: 20))
            _ = selectItem(uuid: Self.idPlain)
            app.typeKey("e", modifierFlags: [.command, .shift])
            let first = URL(fileURLWithPath: Self.exportPath).appendingPathComponent("My First Note.pdf")
            XCTAssertTrue(pollUntil(timeout: 15) { FileManager.default.fileExists(atPath: first.path) },
                          "⇧⌘E should export the PDF: \(exported())")
            let bytes = try Data(contentsOf: first)
            XCTAssertEqual(bytes.prefix(4), Data("%PDF".utf8), "the file should be a PDF")

            _ = selectItem(uuid: Self.idPlain)
            app.typeKey("e", modifierFlags: [.command, .shift])
            XCTAssertTrue(pollUntil(timeout: 15) { self.exported().contains("My First Note 2.pdf") },
                          "a second export should take a new name: \(exported())")
            XCTAssertEqual(try Data(contentsOf: first), bytes, "the first export should be untouched")
        }
    }

    /// File ▸ Print… opens the print panel on the note's window; Cancel prints nothing.
    func testPrintOpensThePrintPanel() throws {
        try withFixture {
            XCTAssertTrue(mainWindow.waitForExistence(timeout: 10))
            XCTAssertTrue(waitForIndexReady(timeout: 20))
            _ = selectItem(uuid: Self.idPlain)
            let print = fileMenuItem("Print…")
            XCTAssertTrue(print.waitForExistence(timeout: 5))
            XCTAssertTrue(print.isEnabled, "Print… should be enabled with a note selected")
            print.click()
            // The panel is a sheet on the note's window, or a dialog of its own; either way it has Print and Cancel.
            var panel: XCUIElement?
            XCTAssertTrue(pollUntil(timeout: 20) {
                panel = [self.mainWindow.sheets.firstMatch, self.app.sheets.firstMatch, self.app.dialogs.firstMatch]
                    .first { $0.exists && $0.buttons["Cancel"].exists }
                return panel != nil
            }, "Print… should open the print panel: \(app.debugDescription)")
            shot("print-panel", app.windows.firstMatch)
            guard let panel else { return }
            panel.buttons["Cancel"].click()
            XCTAssertTrue(pollUntil(timeout: 10) { !panel.exists }, "Cancel should close the print panel")
        }
    }

    private func shot(_ name: String, _ window: XCUIElement? = nil) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uitest-export-\(name).png")
        do {
            try (window ?? mainWindow).screenshot().pngRepresentation.write(to: url, options: .atomic)
            print("[shot] export-\(name): wrote \(url.path)")
        } catch {
            print("[shot] export-\(name): could not write \(url.path) — \(error)")
        }
    }
}
