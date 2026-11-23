import CoreGraphics
import SQLite3
import XCTest

@MainActor
final class CatalogueRepairUITests: XCTestCase {
    func testRepairAfterRelaunchAsksFirstAndUndoRestoresTheFormerCompanion() throws {
        continueAfterFailure = false
        let parent = URL(fileURLWithPath: FixtureUITestCase.canonicalFixturePath, isDirectory: true)
        let expectedMarker = Data((#"{"guid":"a4f1c2d8-0e3b-4a71-9c55-6d8e1f2a3b40","name":"AR-GUI-Fixture","kind":"reader","createdAt":"2026-07-30T00:00:00Z"}"# + "\n").utf8)
        let values = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              try Data(contentsOf: parent.appendingPathComponent(".archive-suite-root.json")) == expectedMarker else {
            XCTFail("The generated GUI scratch fixture is required for catalogue repair.")
            return
        }

        let root = parent.appendingPathComponent("AR-CatalogueRepair-\(UUID().uuidString)", isDirectory: true)
        let memory = parent.appendingPathComponent(root.lastPathComponent + ".catalogue-pairs.sqlite3", isDirectory: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: memory)
        }
        let originalPDF = root.appendingPathComponent("Letter.pdf")
        let movedPDF = root.appendingPathComponent("Renamed.pdf")
        let oldCompanion = root.appendingPathComponent("Letter.pdf.archivesuite.json")
        let newCompanion = root.appendingPathComponent("Renamed.pdf.archivesuite.json")
        let fileID = UUID()
        let contentID = UUID()
        let documentID = UUID()
        try makePDF(at: originalPDF, fileID: fileID, contentID: contentID)
        let originalPDFBytes = try Data(contentsOf: originalPDF)
        let record = Data("""
            {"schema":1,"fileID":"\(fileID)","contentRevision":"\(contentID)","revision":"\(UUID())",
             "parents":[],"pages":[{"id":"\(UUID())","physicalIndex":0,"documentID":"\(documentID)","role":"searchable"}],
             "documents":[{"id":"\(documentID)","ownerFileID":"\(fileID)","fields":{}}],"fileFields":{}}
            """.utf8)
        try record.write(to: oldCompanion)

        let app = XCUIApplication.archiveUITestApp()
        app.launchArguments += ["-ARUITestRootPath", root.path, "-ARUITestCatalogue", "YES",
                                "-ARUITestRememberCataloguePairs"]
        defer { app.terminate() }
        app.launch()
        XCTAssertTrue(app.tables["ar.table"].tableRows.firstMatch.waitForExistence(timeout: 20), "The untagged pair is listed.")
        waitFor("Reader saved local evidence of the original pair") { remembered(fileID, at: memory) }
        app.terminate()
        try FileManager.default.moveItem(at: originalPDF, to: movedPDF)

        app.launch()
        app.activate()
        let row = app.tables["ar.table"].tableRows.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "The renamed PDF is listed.")
        row.click()
        if !app.buttons["ar.tagEditor.done"].exists { app.typeKey("i", modifierFlags: [.command, .option]) }
        let offer = app.buttons["ar.catalogueRepair.offer"]
        XCTAssertTrue(offer.waitForExistence(timeout: 15), "Reader offers a repair based on the prior verified pair.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: newCompanion.path))
        _ = captureScreenshot("catalogue-repair-offer")
        offer.click()
        let repair = app.buttons["Repair"].firstMatch
        XCTAssertTrue(repair.waitForExistence(timeout: 10))
        XCTAssertFalse(FileManager.default.fileExists(atPath: newCompanion.path), "The confirmation has not written anything.")
        _ = captureScreenshot("catalogue-repair-confirmation")
        repair.click()
        waitFor("Reader repaired the companion name") { FileManager.default.fileExists(atPath: newCompanion.path) }
        XCTAssertEqual(try Data(contentsOf: newCompanion), record)
        XCTAssertEqual(try Data(contentsOf: movedPDF), originalPDFBytes)

        let edit = app.menuBars.menuBarItems["Edit"]
        edit.click()
        let undo = edit.menuItems["Undo Catalogue Companion Repair"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        undo.click()
        waitFor("Undo restored the previous companion name") { FileManager.default.fileExists(atPath: oldCompanion.path) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: newCompanion.path))
        XCTAssertEqual(try Data(contentsOf: oldCompanion), record)
        XCTAssertEqual(try Data(contentsOf: movedPDF), originalPDFBytes)
    }

    func testTitleEditSurvivesRelaunchAndUndoRedoKeepsThePDF() throws {
        continueAfterFailure = false
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("Letter.pdf")
        let companion = root.appendingPathComponent("Letter.pdf.archivesuite.json")
        let fileID = UUID(), contentID = UUID()
        try makePDF(at: pdf, fileID: fileID, contentID: contentID)
        let originalPDFBytes = try Data(contentsOf: pdf)
        let documentID = UUID()
        try Data("""
            {"schema":1,"fileID":"\(fileID)","contentRevision":"\(contentID)","revision":"\(UUID())",
             "parents":[],"pages":[{"id":"\(UUID())","physicalIndex":0,"documentID":"\(documentID)","role":"searchable"}],
             "documents":[{"id":"\(documentID)","ownerFileID":"\(fileID)","fields":{
                 "title":{"state":"value","value":"Old title","fieldRevision":"\(UUID())","origin":"user"}}}],"fileFields":{}}
            """.utf8).write(to: companion)

        let app = XCUIApplication.archiveUITestApp()
        app.launchArguments += ["-ARUITestRootPath", root.path, "-ARUITestCatalogue", "YES",
                                "-ARUITestLedgerID", root.lastPathComponent]
        defer { app.terminate() }
        app.launch()
        app.activate()
        let row = app.tables["ar.table"].tableRows.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.click()
        if !app.buttons["ar.tagEditor.done"].exists { app.typeKey("i", modifierFlags: [.command, .option]) }
        let title = app.textFields["ar.catalogue.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertEqual(title.value as? String, "Old title")
        title.click()
        title.typeKey("a", modifierFlags: .command)
        title.typeText("Corrected title\n")
        waitFor("The Inspector saves the title to the companion") {
            (try? String(contentsOf: companion, encoding: .utf8))?.contains("Corrected title") == true
        }
        XCTAssertTrue(app.staticTexts["Saved 1 catalogue record."].firstMatch.waitForExistence(timeout: 10))
        _ = captureScreenshot("catalogue-title-edited")
        app.terminate()

        app.launch()
        app.activate()
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        let edit = app.menuBars.menuBarItems["Edit"]
        let undo = edit.menuItems["Undo Catalogue Change"]
        // The write-ahead history loads after the first catalogue scan.
        waitFor("The relaunched app offers catalogue Undo") {
            edit.click()
            if undo.exists { return true }
            app.typeKey(.escape, modifierFlags: [])
            return false
        }
        undo.click()
        waitFor("Undo restores the previous title") {
            (try? String(contentsOf: companion, encoding: .utf8))?.contains("Old title") == true
        }
        edit.click()
        let redo = edit.menuItems["Redo Catalogue Change"]
        XCTAssertTrue(redo.waitForExistence(timeout: 5))
        redo.click()
        waitFor("Redo restores the edited title") {
            (try? String(contentsOf: companion, encoding: .utf8))?.contains("Corrected title") == true
        }
        XCTAssertEqual(try Data(contentsOf: pdf), originalPDFBytes)
    }

    private func makeScratchRoot() throws -> URL {
        let parent = URL(fileURLWithPath: FixtureUITestCase.canonicalFixturePath, isDirectory: true)
        let values = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let marker = try String(contentsOf: parent.appendingPathComponent(".archive-suite-root.json"), encoding: .utf8)
        guard values.isDirectory == true, values.isSymbolicLink == false,
              marker.contains("a4f1c2d8-0e3b-4a71-9c55-6d8e1f2a3b40") else {
            throw CocoaError(.fileReadNoPermission)
        }
        let root = parent.appendingPathComponent("AR-CatalogueEdit-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func waitFor(_ description: String, condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(20)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(condition(), description)
    }

    private func remembered(_ fileID: UUID, at url: URL) -> Bool {
        var db: OpaquePointer?
        let opened = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(db) }
        guard opened == SQLITE_OK else { return false }
        var query: OpaquePointer?
        let sql = "SELECT 1 FROM instance_pairs WHERE file_id = '\(fileID.uuidString)'"
        guard sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(query) }
        return sqlite3_step(query) == SQLITE_ROW
    }

    private func makePDF(at url: URL, fileID: UUID, contentID: UUID) throws {
        let metadata = Data("""
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
            <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:ascat="https://github.com/charlesapetersen/Archive-Suite/ns/catalogue/1.0/">
            <ascat:identity>\(fileID) \(contentID)</ascat:identity>
            </rdf:Description></rdf:RDF></x:xmpmeta>
            """.utf8)
        var page = CGRect(x: 0, y: 0, width: 200, height: 200)
        let pdf = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &page, nil))
        pdf.addDocumentMetadata(metadata as CFData)
        pdf.beginPDFPage(nil)
        pdf.fill(page.insetBy(dx: 20, dy: 20))
        pdf.endPDFPage()
        pdf.closePDF()
    }
}
