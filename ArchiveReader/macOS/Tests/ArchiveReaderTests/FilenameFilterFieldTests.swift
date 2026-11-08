import AppKit
import SwiftUI
import XCTest
@testable import ArchiveReader

/// Real AppKit field-editor edits in a window that is never ordered onto the host screen.
/// Explicit input groups test history and bindings; real keystroke coalescing is covered in the VM.
@MainActor
final class FilenameFilterFieldTests: XCTestCase {
    private var window: NSWindow!
    private var field: FilenameFilterTextField!
    private var editor: NSTextView!
    private var changes: [String] = []

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 100),
                          styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        field = FilenameFilterTextField(frame: NSRect(x: 10, y: 10, width: 300, height: 28))
        field.onChange = { [weak self] value in
            self?.changes.append(value)
            // Simulate SwiftUI echoing the updated binding, including subsequent list refreshes.
            self?.field.synchronize(value)
        }
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        // XCTest isn't NSApplication's event loop, so scope each synthetic input event explicitly.
        editor.undoManager?.groupsByEvent = false
        editor.undoManager?.removeAllActions()
    }

    override func tearDown() async throws {
        window.makeFirstResponder(nil)
        window.close()
        editor = nil
        field = nil
        window = nil
    }

    private func type(_ text: String) {
        beginEvent()
        editor.insertText(text, replacementRange: editor.selectedRange())
        finishEvent()
    }

    private func beginEvent() {
        if editor === field.currentEditor(), let undo = editor.undoManager, undo.groupingLevel == 0 {
            undo.beginUndoGrouping()
        }
    }

    private func finishEvent() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        // Deliver AppKit's notifications before ending the synthetic input event.
        if editor === field.currentEditor(), let undo = editor.undoManager {
            XCTAssertLessThanOrEqual(undo.groupingLevel, 1)
            if undo.groupingLevel > 0 { undo.endUndoGrouping() }
        }
    }

    private func undo() throws {
        try XCTUnwrap(editor.undoManager).undo()
        finishEvent()
    }
    private func redo() throws {
        try XCTUnwrap(editor.undoManager).redo()
        finishEvent()
    }

    func testTypingUndoesAndRedoesEachEditWhileBindingEchoes() throws {
        for character in ["a", "b", "c"] { type(character) }
        XCTAssertEqual(field.stringValue, "abc")
        for expected in ["ab", "a", ""] {
            try undo()
            XCTAssertEqual(editor.string, expected)
            XCTAssertEqual(field.stringValue, expected)
            XCTAssertEqual(changes.last, expected, "undo must update the filter binding")
        }
        XCTAssertFalse(try XCTUnwrap(editor.undoManager).canUndo)
        for expected in ["a", "ab", "abc"] {
            try redo()
            XCTAssertEqual(field.stringValue, expected)
            XCTAssertEqual(changes.last, expected, "redo must update the filter binding")
        }
        XCTAssertFalse(try XCTUnwrap(editor.undoManager).canRedo)
    }

    func testTypingAfterUndoKeepsOlderStepsAndDropsRedo() throws {
        for character in ["a", "b", "c"] { type(character) }
        try undo()
        type("x")
        XCTAssertEqual(field.stringValue, "abx")
        XCTAssertFalse(try XCTUnwrap(editor.undoManager).canRedo)
        for expected in ["ab", "a", ""] {
            try undo()
            XCTAssertEqual(field.stringValue, expected)
        }
    }

    func testReplacementAndDeletionAreEachOneUndoStep() throws {
        type("pasted query")
        editor.setSelectedRange(NSRange(location: 0, length: 6))
        type("new")
        XCTAssertEqual(field.stringValue, "new query")
        beginEvent()
        editor.deleteBackward(nil)
        finishEvent()
        XCTAssertEqual(field.stringValue, "ne query")
        for expected in ["new query", "pasted query", ""] {
            try undo()
            XCTAssertEqual(field.stringValue, expected)
        }
    }

    func testFirstEditEnablesUndoWithoutTestSetupEnablingIt() throws {
        type("a")
        XCTAssertTrue(editor.allowsUndo)
        try undo()
        XCTAssertEqual(field.stringValue, "")
    }

    func testExternalResetThenTypingStartsFreshHistory() throws {
        for character in ["a", "b", "c"] { type(character) }
        field.synchronize("")
        XCTAssertEqual(editor.string, "")
        type("x")
        try undo()
        XCTAssertEqual(field.stringValue, "")
        XCTAssertFalse(try XCTUnwrap(editor.undoManager).canUndo,
                       "a cleared filter must not revive edits to its old value")
    }

    func testSwitchingFieldsDoesNotUndoTheFilenameInAnotherField() throws {
        type("a")
        type("b")
        let other = NSTextField(frame: NSRect(x: 10, y: 50, width: 300, height: 28))
        window.contentView?.addSubview(other)
        XCTAssertTrue(window.makeFirstResponder(other))
        editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.allowsUndo = true
        type("other")
        try undo()
        XCTAssertEqual(other.stringValue, "")
        XCTAssertEqual(field.stringValue, "ab")
        XCTAssertFalse(try XCTUnwrap(editor.undoManager).canUndo)
        XCTAssertTrue(window.makeFirstResponder(field))
        editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        type("x")
        XCTAssertEqual(field.stringValue, "abx")
        try undo()
        XCTAssertEqual(field.stringValue, "ab")
        XCTAssertEqual(changes.last, "ab")
        try redo()
        XCTAssertEqual(field.stringValue, "abx")
        XCTAssertEqual(changes.last, "abx")
        XCTAssertEqual(other.stringValue, "")
    }

    func testMarkedTextPreservesNativeCompositionBehavior() throws {
        // Direct NSTextInputClient calls do not carry a real input method's undo transactions.
        // Compare the same marked-text sequence with native NSTextView rather than inventing
        // what an input method must group. The field's undo history must retain native marked text.
        let native = NativeCompositionEditor()
        native.isFieldEditor = true
        native.allowsUndo = true
        func trace(_ target: NSTextView) throws -> [String] {
            let history = try XCTUnwrap(target.undoManager)
            history.groupsByEvent = false
            func event(_ edit: () -> Void) {
                history.beginUndoGrouping()
                edit()
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                XCTAssertEqual(history.groupingLevel, 1)
                history.endUndoGrouping()
            }
            event { target.insertText("a", replacementRange: target.selectedRange()) }
            for marked in ["n", "ni"] {
                event {
                    target.setMarkedText(marked, selectedRange: NSRange(location: marked.count, length: 0),
                                         replacementRange: NSRange(location: NSNotFound, length: 0))
                }
                XCTAssertTrue(target.hasMarkedText())
                XCTAssertEqual(target.string, "a\(marked)")
            }
            event { target.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0)) }
            XCTAssertFalse(target.hasMarkedText())
            XCTAssertEqual(target.string, "a你")
            var states = [target.string]
            while history.canUndo && states.count < 10 {
                history.undo()
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                states.append(target.string)
                if target === editor { XCTAssertEqual(changes.last, target.string) }
            }
            XCTAssertFalse(history.canUndo)
            return states
        }
        XCTAssertEqual(try trace(editor), try trace(native))
    }

    func testProductionFieldRendersPlaceholderAndValue() throws {
        window.makeFirstResponder(nil)
        for value in ["", "Box 12"] {
            let view = NSHostingView(rootView: FilenameFilterField(text: .constant(value)))
            window.contentView = view
            let png = try XCTUnwrap(RenderProbe.pngData(fromAppKitView: view,
                                                       size: CGSize(width: 300, height: 32)))
            writeRenderArtifact(png, named: value.isEmpty ? "filename-filter-placeholder.png" : "filename-filter-value.png")
            let pixels = try XCTUnwrap(RenderProbe.cgImage(fromPNG: png))
            assertRendersNonBlank(pixels, "filename filter \(value)")
        }
    }
}

@MainActor
private final class NativeCompositionEditor: NSTextView {
    private let history = UndoManager()
    override var undoManager: UndoManager? { history }
}
