import AppKit
import SwiftUI
import XCTest
@testable import ArchiveNotes

/// Real AppKit field-editor handoff in an unordered window; nothing reaches the host display.
@MainActor
final class ListCellEditingLifecycleTests: XCTestCase {
    func testAnUntouchedDateCannotClearTheScratchNote() async throws {
        try await withScratchDateCell { field, store, id in
            let url = try await store.mdURL(for: id)
            let before = try Data(contentsOf: url)
            var writes = 0
            var requestedWrite: XCTestExpectation?
            let commit = field.onCommit
            field.onCommit = { text, completion in
                writes += 1
                let finished = self.expectation(description: "any requested write finishes")
                requestedWrite = finished
                commit?(text) { saved in completion(saved); finished.fulfill() }
            }
            field.beginRename()
            // A control/field-editor reset is not user input. This is precisely the unsafe case:
            // the old field accepted this empty value as a request to erase the stored date.
            field.stringValue = ""
            field.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
            if let requestedWrite { await self.fulfillment(of: [requestedWrite], timeout: 5) }
            XCTAssertEqual(writes, 0, "an untouched field must not even request a write")
            XCTAssertEqual(try Data(contentsOf: url), before)
        }
    }

    func testUserDateReplacementAndClearStillReachTheScratchStore() async throws {
        try await withScratchDateCell { field, store, id in
            for text in ["March 1971", ""] {
                field.beginRename()
                let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
                let saved = self.expectation(description: "date saved")
                let commit = field.onCommit
                field.onCommit = { text, completion in
                    commit?(text) { result in
                        XCTAssertTrue(result)
                        completion(result)
                        saved.fulfill()
                    }
                }
                editor.insertText(text, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
                // The last actual input remains authoritative if AppKit resets the control at handoff.
                field.stringValue = ""
                XCTAssertTrue(field.window!.makeFirstResponder(nil))
                await self.fulfillment(of: [saved], timeout: 5)
                field.onCommit = commit
                let note = try await store.load(id)
                XCTAssertEqual(note.date, text.isEmpty ? nil : "1971-03")
                XCTAssertEqual(note.datePrecision, text.isEmpty ? nil : .month)
                XCTAssertEqual(note.tags, ["Intel", "Silicon Valley"])
                XCTAssertEqual(note.trailingBodyRaw?.trimmingCharacters(in: .whitespacesAndNewlines), "Keep this body.")
            }
        }
    }

    func testUntouchedTagsCannotCommitAnIncidentalEmptyTokenList() {
        var commits: [[String]] = []
        let field = NoteTagsCellField(tags: ["Intel", "Silicon Valley"], suggestions: { [] },
                                      onCommit: { commits.append($0) }, onEnd: {})
        field.objectValue = [String]()
        field.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        XCTAssertTrue(commits.isEmpty)
    }

    func testDeletingTagsWithTheFieldEditorStillCommits() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var commits: [[String]] = []
        let field = NoteTagsCellField(tags: ["Intel", "Silicon Valley"], suggestions: { [] },
                                      onCommit: { commits.append($0) }, onEnd: {})
        field.frame = NSRect(x: 0, y: 0, width: 400, height: 30)
        window.contentView!.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor())
        editor.selectAll(nil)
        editor.delete(nil)
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertEqual(commits, [[]], "genuine token deletion must still clear tags")
    }

    func testUnchangedDateSurvivesFieldEditorHandoff() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let field = NoteTitleTextField(labelWithString: "Mar 12, 1968")
        field.frame = NSRect(x: 0, y: 0, width: 200, height: 30)
        field.noteTitle = "1968-03-12"
        field.commitsEmpty = true
        window.contentView!.addSubview(field)
        var commits: [String] = []
        field.onCommit = { text, completion in commits.append(text); completion(true) }
        field.beginRename()
        let editor = try XCTUnwrap(field.currentEditor())
        XCTAssertEqual(editor.string, "1968-03-12")
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertFalse(field.isRenaming)
        XCTAssertTrue(commits.isEmpty, "leaving an untouched date must never request a write")
        XCTAssertEqual(field.stringValue, "Mar 12, 1968")
    }

    /// Use the production date-cell factory and its real model write closure, over a scratch store.
    /// The window stays unordered; AppKit still supplies its actual shared field editor.
    private func withScratchDateCell(_ body: @MainActor (NoteTitleTextField, NoteStore, UUID) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-cell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = NotesIndex(url: root.appendingPathComponent("index.sqlite"))
        try await index.open()
        do {
            let organization = OrganizationStore(index: index)
            try await organization.load(storeRoot: root)
            let store = NoteStore(root: root)
            let id = UUID()
            let note = try FrontMatterCodec.decode("""
            ---
            id: \(id.uuidString)
            title: Test note
            date: 1968-03-12
            date_precision: day
            tags: [Intel, Silicon Valley]
            ---
            Keep this body.
            """)
            _ = try await store.create(note)
            let model = NotesModel(organization: organization, index: index, noteStore: store)
            model.replaceItems(await store.allItemSummaries())
            let nav = NotesNavigationModel(model: model, defaultKind: .note)
            let view = NotesTableView(model: nav, selection: .constant([]), onDoubleClick: {}, buildContextMenu: { _ in nil })
            let coordinator = view.makeCoordinator()
            coordinator.displayedByID = Dictionary(uniqueKeysWithValues: model.allItems.map { ($0.id, $0) })
            let table = NSTableView()
            let column = NSTableColumn(identifier: .init("date"))
            let cell = try XCTUnwrap(coordinator.makeCell(tableView: table, column: column, itemID: id) as? NSTableCellView)
            let field = try XCTUnwrap(cell.textField as? NoteTitleTextField)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 100),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView!.addSubview(cell)
            cell.frame = NSRect(x: 0, y: 0, width: 200, height: 30)
            try await body(field, store, id)
            await index.close()
        } catch {
            await index.close()
            throw error
        }
    }
}
