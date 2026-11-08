import XCTest
import AppKit
import SwiftUI
import ArchiveCore
@testable import ArchiveReader

@MainActor
final class FileHealthDetailTests: XCTestCase {
    private struct Fixture {
        let model: NavigationModel
        let coordinator: AppKitTableView.Coordinator
        let table: NSTableView
        let files: [ArchiveFile]
    }

    private func fixture() async throws -> Fixture {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("FileHealth-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: scratch) }
        let indexer = ContentIndexer(url: scratch.appendingPathComponent("content.sqlite3"), extractPDFForTesting: { url in
            if url.lastPathComponent == "unreadable.pdf" { return nil }
            return ExtractedContent(fullBody: url.lastPathComponent == "no-text.pdf" ? "" : "Readable text",
                                    strippedBody: "", classification: nil, pageCount: 1)
        })
        addTeardownBlock { await indexer.closeForTesting() }
        let model = NavigationModel(defaults: fixtureDefaults(), indexer: indexer, thumbnailer: nil)
        let files = ["unreadable.pdf", "no-text.pdf", "dated.pdf", "healthy.pdf"].map { name in
            ArchiveFile(url: scratch.appendingPathComponent(name), name: name, fileType: "PDF",
                        tags: DocumentTags.parse(raw: name == "dated.pdf" ? ["Unread", "1980", "1984"] : ["Unread"],
                                                 labelNumber: nil), contentModified: nil)
        }
        model.library.replaceFilesForTesting(files)
        let deadline = Date().addingTimeInterval(10)
        while model.formatStatuses.count != files.count, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.formatStatuses.count, files.count)
        model.recompute()
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 250, height: 100))
        let coordinator = AppKitTableView.Coordinator(AppKitTableView(
            model: model, selection: .constant([]), fontSize: 13, scrollRequest: 0, scrollTargetID: nil,
            onDoubleClick: {}, buildContextMenu: { _ in nil }))
        coordinator.tableView = table
        coordinator.showRows(model.displayed)
        return Fixture(model: model, coordinator: coordinator, table: table, files: files)
    }

    private func cell(_ f: Fixture, _ file: ArchiveFile, column: String = "warning") throws -> FileHealthCellView {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column))
        return try XCTUnwrap(f.coordinator.makeCell(tableView: f.table, column: column, itemID: file.id) as? FileHealthCellView)
    }

    func testTableWarningsExplainDifferentSymptomsAndHealthyCellsHaveNoAction() async throws {
        let f = try await fixture()
        let unreadable = try cell(f, f.files[0])
        let missingText = try cell(f, f.files[1])
        XCTAssertEqual(unreadable.textField?.stringValue, "⚠")
        XCTAssertEqual(missingText.textField?.stringValue, "⚠")
        XCTAssertTrue(try XCTUnwrap(unreadable.actionButton?.toolTip).contains("password-protected"))
        XCTAssertTrue(try XCTUnwrap(missingText.actionButton?.toolTip).contains("use an OCR tool"))
        XCTAssertFalse(try XCTUnwrap(missingText.actionButton?.toolTip).contains("damaged"))
        let healthy = try cell(f, f.files[3])
        XCTAssertEqual(healthy.textField?.stringValue, "")
        XCTAssertNil(healthy.actionButton)
        XCTAssertNil(healthy.makeDetailView())
        let unambiguousDate = try cell(f, f.files[3], column: "date")
        XCTAssertNil(unambiguousDate.actionButton)

        // A real control receives a click anywhere in the narrow warning cell, including the glyph.
        missingText.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
        missingText.layoutSubtreeIfNeeded()
        XCTAssertTrue(missingText.hitTest(NSPoint(x: 12, y: 12)) === missingText.actionButton)
    }

    func testDateWarningEditInfoTargetsNamedFileAfterSelectionChangesAndCellReuse() async throws {
        let f = try await fixture()
        let dated = f.files[2]
        let cell = try cell(f, dated, column: "date")
        let view = try XCTUnwrap(cell.makeDetailView())
        XCTAssertTrue(view.detail.dateIssue?.reason.contains("1980 was set aside") == true)
        f.model.selection = [f.files[0].id, f.files[1].id]
        // Simulate reuse while the presentation is alive. The captured action must keep its original target.
        cell.configure(detail: FileHealthDetail(file: f.files[0], status: .unreadable), onAction: { _ in
            XCTFail("the reused cell's action must not replace the presented action")
        })
        view.onAction(.editInfo)
        XCTAssertTrue(f.model.showingEditor)
        XCTAssertEqual(f.model.selectedFiles.map(\.id), [dated.id])
    }

    func testOpenDocumentActsOnWarningFileWithoutChangingMultiSelection() async throws {
        let f = try await fixture()
        var opened: ArchiveFile.ID?
        f.coordinator.parent.onOpenFile = { opened = $0.id }
        f.model.selection = [f.files[0].id, f.files[3].id]
        let originalSelection = f.model.selection
        let warning = try cell(f, f.files[1])
        let view = try XCTUnwrap(warning.makeDetailView())
        view.onAction(.openDocument)
        XCTAssertEqual(opened, f.files[1].id)
        XCTAssertEqual(f.model.selection, originalSelection)
        XCTAssertFalse(f.model.showingEditor, "opening details and a document must not start a tag edit")
    }

    func testFileHealthPopoverRendersReasonsAndActionsInBothAppearances() async throws {
        let f = try await fixture()
        for (index, name) in [(0, "unreadable"), (1, "no-text"), (2, "date")] {
            let cell = try cell(f, f.files[index], column: index == 2 ? "date" : "warning")
            let view = try XCTUnwrap(cell.makeDetailView())
            for (scheme, suffix) in [(ColorScheme.light, "light"), (.dark, "dark")] {
                let host = NSHostingView(rootView: view
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, scheme))
                host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                let size = host.fittingSize
                XCTAssertGreaterThan(size.height, 200)
                XCTAssertLessThan(size.height, 650, "all guidance and actions must fit in the popover")
                let png = try XCTUnwrap(RenderProbe.pngData(fromAppKitView: host, size: size))
                let cg = try XCTUnwrap(RenderProbe.cgImage(fromPNG: png))
                assertRendersNonBlank(cg, "file health \(name) \(suffix)")
                writeRenderArtifact(png, named: "file-health-\(name)-\(suffix).png")
            }
        }
    }
}
