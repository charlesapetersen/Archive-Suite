import AppKit
import XCTest
@testable import ArchiveReader

/// W40.fix-reader-undo-focus: which ⌘Z presses the text-field guard takes before the Undo Tag Change
/// menu item can. The whole path, typing and tags on disk, is `UndoFocusUITests` in the VM.
@MainActor
final class TextUndoGuardTests: XCTestCase {
    private var window: NSWindow!
    private var field: NSTextField!
    private var table: NSTableView!

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
                          backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false   // ARC owns it; the default would release it twice on close
        field = NSTextField(frame: NSRect(x: 10, y: 10, width: 200, height: 24))
        table = NSTableView(frame: NSRect(x: 10, y: 50, width: 200, height: 100))
        window.contentView?.addSubview(field)
        window.contentView?.addSubview(table)
    }

    override func tearDown() async throws {
        window.close()
        window = nil
    }

    private func key(_ chars: String, _ flags: NSEvent.ModifierFlags, type: NSEvent.EventType = .keyDown) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: 6)!
    }

    func testCommandZInAnEditingFieldGoesToTheText() {
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertNotNil(TextUndoGuard.editingTextView(for: key("z", .command), in: window),
                        "with the field editor up, ⌘Z must undo the typing, not a tag change")
        XCTAssertNotNil(TextUndoGuard.editingTextView(for: key("z", [.command, .capsLock]), in: window),
                        "Caps Lock does not change which ⌘Z it is")
        XCTAssertNotNil(TextUndoGuard.editingTextView(for: key("Z", [.command, .shift]), in: window),
                        "⇧⌘Z redoes the typing, not a tag change (W40.fix-reader-redo)")
    }

    func testOtherKeysAndOtherFocusFallThroughToTheMenus() {
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertNil(TextUndoGuard.editingTextView(for: key("Z", [.command, .shift, .option]), in: window))
        XCTAssertNil(TextUndoGuard.editingTextView(for: key("z", [.command, .option]), in: window))
        XCTAssertNil(TextUndoGuard.editingTextView(for: key("r", .command), in: window))
        XCTAssertNil(TextUndoGuard.editingTextView(for: key("z", .command, type: .keyUp), in: window))

        XCTAssertTrue(window.makeFirstResponder(table))
        XCTAssertNil(TextUndoGuard.editingTextView(for: key("z", .command), in: window),
                     "with the list focused, ⌘Z is Undo Tag Change")
        XCTAssertNil(TextUndoGuard.editingTextView(for: key("Z", [.command, .shift]), in: window),
                     "and ⇧⌘Z is Redo Tag Change")
        XCTAssertNil(TextUndoGuard.editingTextView(for: key("z", .command), in: nil))
    }

    func testANonEditableTextViewDoesNotTakeIt() {
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        text.isEditable = false
        window.contentView?.addSubview(text)
        XCTAssertTrue(window.makeFirstResponder(text))
        XCTAssertNil(TextUndoGuard.editingTextView(for: key("z", .command), in: window),
                     "read-only text (selectable labels) has no typing to undo")
    }
}
