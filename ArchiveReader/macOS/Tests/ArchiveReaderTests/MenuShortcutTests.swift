import XCTest
import AppKit
@testable import ArchiveReader

/// `W40.fix-suite-shortcuts`: no two menu-bar commands share a shortcut, and the suite's shared keys are where
/// `REFERENCE.md` §Keyboard map says. Reads the real menu bar the app builds (`ArchiveReaderCommands`) under the
/// unit-test host, so it sees the menus as they are with no window in front: the items that are listed only with
/// the navigation window in front (Hide Sidebar, Hide Tag Cloud) are checked in the VM (`ViewerUITests`).
/// The same check is in Notes' bundle; the Processor has no unit bundle, so its keys are in its UITests.
@MainActor
final class MenuShortcutTests: XCTestCase {

    private struct Shortcut: Hashable, CustomStringConvertible {
        let key: String
        let modifiers: UInt
        var description: String { "\(modifiers):\(key.unicodeScalars.map { String($0.value, radix: 16) })" }
    }

    /// Every item with a key equivalent, by its menu path ("Tags ▸ Mark Read").
    private func shortcuts(in menu: NSMenu, path: String = "") -> [(String, Shortcut)] {
        menu.items.flatMap { item -> [(String, Shortcut)] in
            let here = path.isEmpty ? item.title : "\(path) ▸ \(item.title)"
            var found: [(String, Shortcut)] = []
            if !item.keyEquivalent.isEmpty {
                var mods = item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
                // AppKit reads an upper-case key as ⇧ plus the letter.
                if item.keyEquivalent != item.keyEquivalent.lowercased() { mods.insert(.shift) }
                found.append((here, Shortcut(key: item.keyEquivalent.lowercased(), modifiers: mods.rawValue)))
            }
            if let sub = item.submenu { found += shortcuts(in: sub, path: here) }
            return found
        }
    }

    private func menuBar() throws -> [(String, Shortcut)] {
        for _ in 0..<20 where (NSApp.mainMenu?.items.count ?? 0) < 4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let menu = try XCTUnwrap(NSApp.mainMenu, "the app should have built its menu bar")
        let all = shortcuts(in: menu)
        XCTAssertTrue(all.contains { $0.0.hasPrefix("Tags ▸ ") }, "the app's own menus should be in the menu bar: \(all.map(\.0))")
        return all
    }

    private func shortcut(_ key: String, _ mods: NSEvent.ModifierFlags) -> Shortcut {
        Shortcut(key: key, modifiers: mods.rawValue)
    }

    func testNoTwoCommandsShareAShortcut() throws {
        // ⌘Z / ⇧⌘Z are the one deliberate pair: Tags ▸ Undo/Redo Tag Change answer them unless a text field has
        // the caret, where Edit ▸ Undo/Redo undo the typing (`TextUndoGuard`, REFERENCE §Keyboard map).
        let allowed: Set<Set<String>> = [
            ["Edit ▸ Undo", "Tags ▸ Undo Tag Change"],
            ["Edit ▸ Redo", "Tags ▸ Redo Tag Change"],
        ]
        let byShortcut = Dictionary(grouping: try menuBar(), by: \.1)
        for (key, items) in byShortcut where items.count > 1 {
            let paths = Set(items.map(\.0))
            XCTAssertTrue(allowed.contains(paths), "\(key) is bound by more than one command: \(paths.sorted())")
        }
    }

    func testTheSuiteSharedKeysAreInPlace() throws {
        let all = try menuBar()
        func key(of path: String) -> Shortcut? { all.first { $0.0 == path }?.1 }
        XCTAssertEqual(key(of: "File ▸ Choose Archive Folder…"), shortcut("o", [.command, .shift]))
        // Owner preference: prose takes ⇧⌘C; file links take ⌥⌘C, including with the preview up.
        XCTAssertEqual(key(of: "Selection ▸ Copy Link(s)"), shortcut("c", [.command, .option]))
        XCTAssertEqual(key(of: "Edit ▸ Copy Cleaned for Prose"), shortcut("c", [.command, .shift]))
        XCTAssertEqual(key(of: "Selection ▸ Open in Document Window"), shortcut("o", [.command]))
        // The Inspector is on ⌥⌘I, as in Archive Notes (W40.reader-commands-table); ⌘I is free.
        XCTAssertEqual(key(of: "View ▸ Show Inspector"), shortcut("i", [.command, .option]))
        XCTAssertNil(all.first { $0.1 == shortcut("i", [.command]) }, "⌘I was Edit Info's key and is free")
        XCTAssertEqual(key(of: "Document ▸ Find…"), shortcut("f", [.command]))
        // ⌥⌘T is the Mac's Show/Hide Toolbar and ⌃⌘S its Show/Hide Sidebar: nothing else may take them.
        XCTAssertNil(all.first { $0.1 == shortcut("t", [.command, .option]) }, "⌥⌘T is the Mac's toolbar key")
    }
}
