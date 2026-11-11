import Testing
import AppKit
@testable import ArchiveNotes

/// W40.fix-suite-shortcuts — no two menu-bar commands share a shortcut, and the keys Notes shares with the Reader
/// are the Reader's. Reads the real menu bar the app builds (`ArchiveNotesCommands.swift`) under the unit-test host.
/// Notes had ⇧⌘O on Numbered List while the Reader's ⇧⌘O was Choose Archive Folder… (notes-1, row 1); the lists
/// are ⌥⌘U and ⌥⌘O now, beside the other block formats. The same check is in the Reader's bundle.
@Suite("MenuShortcutTests — W40.fix-suite-shortcuts")
@MainActor
struct MenuShortcutTests {

    private struct Shortcut: Hashable, CustomStringConvertible {
        let key: String
        let modifiers: UInt
        var description: String { "\(modifiers):\(key.unicodeScalars.map { String($0.value, radix: 16) })" }
    }

    /// Every item with a key equivalent, by its menu path ("Format ▸ Bold").
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
        let menu = try #require(NSApp.mainMenu, "the app should have built its menu bar")
        let all = shortcuts(in: menu)
        #expect(all.contains { $0.0.hasPrefix("Format ▸ ") }, "the app's own menus should be in the menu bar: \(all.map(\.0))")
        return all
    }

    private func shortcut(_ key: String, _ mods: NSEvent.ModifierFlags) -> Shortcut {
        Shortcut(key: key, modifiers: mods.rawValue)
    }

    @Test func noTwoCommandsShareAShortcut() throws {
        for (key, items) in Dictionary(grouping: try menuBar(), by: \.1) where items.count > 1 {
            Issue.record("\(key) is bound by more than one command: \(items.map(\.0).sorted())")
        }
    }

    @Test func theSuiteSharedKeysAreInPlace() throws {
        let all = try menuBar()
        func key(of path: String) -> Shortcut? { all.first { $0.0 == path }?.1 }
        #expect(key(of: "File ▸ Choose Archive Folder…") == shortcut("o", [.command, .shift]))
        #expect(key(of: "Note ▸ Copy Link") == shortcut("c", [.command, .shift]))
        #expect(key(of: "File ▸ New Note") == shortcut("n", [.command]))
        // W40.fix-notes-zotero-paste (notes-2 row 27): both Zotero commands have a key, Z for Zotero.
        #expect(key(of: "Note ▸ Attach Zotero Link…") == shortcut("z", [.command, .control]))
        #expect(key(of: "Note ▸ Auto-fill from Zotero…") == shortcut("z", [.command, .control, .option]))
        #expect(key(of: "Format ▸ Bulleted List") == shortcut("u", [.command, .option]))
        #expect(key(of: "Format ▸ Numbered List") == shortcut("o", [.command, .option]))
        #expect(key(of: "Edit ▸ Advanced Search…") == shortcut("f", [.command, .option, .shift]),
                "Advanced Search must survive installation of TextEditingCommands: \(all.map(\.0))")
        #expect(all.contains { $0.0.hasPrefix("Edit ▸ ") && $0.1 == shortcut("f", [.command]) },
                "⌘F is Edit ▸ Find: \(all.filter { $0.0.hasPrefix("Edit") }.map(\.0))")
    }
}
