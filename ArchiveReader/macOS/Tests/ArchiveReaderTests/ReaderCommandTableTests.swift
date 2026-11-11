import XCTest
import AppKit
import SwiftUI
@testable import ArchiveReader

/// W40.reader-commands-table: `ReaderCommand` is the one place a command's name, key and help are written.
/// These fail on two commands sharing a key where both can answer it, on a menu item that differs from the
/// table, and on help or message text anywhere in the app's sources that names a key the table does not bind.
/// `MenuShortcutTests` checks the real menu bar for clashes with the system's own items.
@MainActor
final class ReaderCommandTableTests: XCTestCase {

    // MARK: One key, one command, in each place keys are answered

    func testNoTwoCommandsShareAKeyInOneContext() {
        // The menu bar answers in every window, so each other context is checked together with it.
        for context in CommandContext.allCases {
            let live = ReaderCommand.allCases.filter { $0.context == context || $0.context == .menuBar }
            let byKey = Dictionary(grouping: live.filter { $0.key != nil }, by: { $0.key! })
            for (key, commands) in byKey where commands.count > 1 {
                XCTFail("\(key.glyph) is bound by \(commands.map(\.rawValue)) in \(context)")
            }
        }
    }

    func testTheInspectorIsOnOptionCommandIAndCommandIIsFree() {
        XCTAssertEqual(ReaderCommand.showInspector.key, CommandKey("i", [.command, .option]))
        XCTAssertEqual(ReaderCommand.showInspector.title, "Show Inspector")
        XCTAssertEqual(ReaderCommand.showInspector.title(showing: true), "Hide Inspector")
        XCTAssertFalse(ReaderCommand.allCases.contains { $0.key == CommandKey("i") })
    }

    func testCopyCleanedIsShiftCommandCInEveryHelpText() {
        XCTAssertEqual(ReaderCommand.copyCleaned.help,
                       "Copy the selected text cleaned for prose — joins lines, de-hyphenates (⇧⌘C)")
        XCTAssertEqual(ReaderCommand.copyLinks.glyph, "⌥⌘C")
    }

    // MARK: The menu bar reads the table

    /// Every menu item the table names carries the table's key, and every key in the Reader's own menus belongs
    /// to a command in the table. Items listed only with a window in front (Hide Sidebar) are not in the unit
    /// host's menu bar; the VM's `ViewerUITests` sees those.
    func testTheMenuBarMatchesTheTable() throws {
        for _ in 0..<20 where (NSApp.mainMenu?.items.count ?? 0) < 4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let bar = try XCTUnwrap(NSApp.mainMenu)
        let ownMenus: Set<String> = ["Selection", "Tags", "Sort & Filter", "Document"]
        let menuCommands = ReaderCommand.allCases.filter { $0.context == .menuBar && !$0.reserved }
        var matched = 0
        for top in bar.items {
            for item in top.submenu?.items ?? [] where !item.isSeparatorItem {
                let key = Self.key(of: item)
                let named = menuCommands.filter { [$0.title, $0.title(showing: true)].contains(item.title) }
                if let command = named.first(where: { $0.key == key }) ?? named.first {
                    matched += 1
                    // SwiftUI clears a disabled item's key while an enabled item shares it: Undo Tag Change
                    // shows ⌘Z only when there is a tag change to undo, Edit ▸ Undo holding it otherwise.
                    if key == nil, !item.isEnabled, command.key != nil { continue }
                    XCTAssertEqual(key, command.key, "\(top.title) ▸ \(item.title) should be on \(command.glyph)")
                } else if ownMenus.contains(top.title), let key {
                    XCTFail("\(top.title) ▸ \(item.title) binds \(key.glyph), which is not in ReaderCommand")
                }
            }
        }
        XCTAssertGreaterThan(matched, 30, "the table's commands should be on the menu bar")
    }

    /// No key held for a later item is already on the menu bar, the system's own items included.
    func testReservedKeysAreFree() throws {
        let bar = try XCTUnwrap(NSApp.mainMenu)
        func all(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(all) ?? []) } }
        let bound = Set(all(bar).compactMap(Self.key(of:)))
        for command in ReaderCommand.allCases where command.reserved {
            XCTAssertFalse(bound.contains(command.key!), "\(command.glyph), held for \(command.title), is taken")
        }
    }

    private static func key(of item: NSMenuItem) -> CommandKey? {
        guard !item.keyEquivalent.isEmpty, let c = item.keyEquivalent.first else { return nil }
        var mods: EventModifiers = []
        let flags = item.keyEquivalentModifierMask
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.shift) || item.keyEquivalent != item.keyEquivalent.lowercased() { mods.insert(.shift) }
        let arrows: [UInt32: KeyEquivalent] = [UInt32(NSUpArrowFunctionKey): .upArrow,
                                               UInt32(NSDownArrowFunctionKey): .downArrow,
                                               UInt32(NSLeftArrowFunctionKey): .leftArrow,
                                               UInt32(NSRightArrowFunctionKey): .rightArrow]
        if let scalar = c.unicodeScalars.first, let arrow = arrows[scalar.value] { return CommandKey(arrow, mods) }
        return CommandKey(KeyEquivalent(Character(String(c).lowercased())), mods)
    }

    // MARK: No text names a key the table does not bind

    /// Keys a help or message text may name that are answered outside the table's commands: the panes answer
    /// ⌘= and the older ⌘↑ / ⌘↓ zoom themselves (`ReaderPDFView.performKeyEquivalent`), since a menu item holds
    /// one key; ⇧↑ / ⇧↓ extend the selection in the list and the preview sheet.
    private static let answeredElsewhere: Set<CommandKey> = [
        CommandKey("="), CommandKey(.upArrow), CommandKey(.downArrow),
        CommandKey(.upArrow, .shift), CommandKey(.downArrow, .shift),
    ]

    func testEveryKeyNamedInTheTablesHelpIsBound() {
        let bound = Set(ReaderCommand.allCases.compactMap(\.key)).union(Self.answeredElsewhere)
        for command in ReaderCommand.allCases {
            for named in Self.keysNamed(in: command.help) where !bound.contains(named) {
                XCTFail("\(command.rawValue)'s help names \(named.glyph), which nothing binds")
            }
        }
    }

    /// The app's string literals (tooltips, status lines, warnings) name only keys the table binds. Comments
    /// are skipped; they explain history, where an old key is the point.
    func testNoStringInTheAppNamesAnUnboundKey() throws {
        let sources = URL(fileURLWithPath: #filePath)        // …/Tests/ArchiveReaderTests/<this file>
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ArchiveReader", isDirectory: true)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 20, "the app's sources should be readable at \(sources.path)")
        let bound = Set(ReaderCommand.allCases.compactMap(\.key)).union(Self.answeredElsewhere)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (line, literal) in Self.stringLiterals(in: text) {
                let plain = literal.replacingOccurrences(of: #"\\\([^)]*\)"#, with: " ", options: .regularExpression)
                for named in Self.keysNamed(in: plain) where !bound.contains(named) {
                    XCTFail("\(file.lastPathComponent):\(line) names \(named.glyph), which nothing binds: \(literal)")
                }
            }
        }
    }

    func testKeysNamedReadsAnyModifierOrder() {
        XCTAssertEqual(Self.keysNamed(in: "Rescan with ⌘⌥R or ⌥⌘R."),
                       [CommandKey("r", [.command, .option]), CommandKey("r", [.command, .option])])
        XCTAssertEqual(Self.keysNamed(in: "(⌘⇧↑)"), [CommandKey(.upArrow, [.command, .shift])])
        XCTAssertEqual(Self.keysNamed(in: "⌘+/⌘−, ⇧-click"), [CommandKey("+"), CommandKey("-")])
    }

    /// Each key a text names: a run of modifier glyphs in any order, then the key. "⇧-click" is a click.
    static func keysNamed(in text: String) -> [CommandKey] {
        let glyphs: [Character: EventModifiers] = ["⌃": .control, "⌥": .option, "⇧": .shift, "⌘": .command]
        let arrows: [Character: KeyEquivalent] = ["↑": .upArrow, "↓": .downArrow, "←": .leftArrow, "→": .rightArrow]
        let chars = Array(text)
        var found: [CommandKey] = []
        var i = 0
        while i < chars.count {
            guard glyphs[chars[i]] != nil else { i += 1; continue }
            var mods: EventModifiers = []
            while i < chars.count, let m = glyphs[chars[i]] { mods.insert(m); i += 1 }
            guard i < chars.count else { break }
            var c = chars[i]
            if c == "−" { c = "-" }
            let isClick = c == "-" && i + 1 < chars.count && chars[i + 1].isLetter
            if !isClick, !c.isWhitespace {
                found.append(arrows[c].map { CommandKey($0, mods) }
                             ?? CommandKey(KeyEquivalent(Character(String(c).lowercased())), mods))
            }
            i += 1
        }
        return found
    }

    /// The string literals of a Swift file with their line numbers, outside `//` comments. The caller drops
    /// interpolations, whose keys come from the table ("⇧\\(glyph)").
    static func stringLiterals(in source: String) -> [(Int, String)] {
        var out: [(Int, String)] = []
        for (n, raw) in source.components(separatedBy: "\n").enumerated() {
            let chars = Array(raw)
            var inString = false, escaped = false, current = ""
            var i = 0
            while i < chars.count {
                let c = chars[i]
                if inString {
                    if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" {
                        inString = false; out.append((n + 1, current)); current = ""; i += 1; continue
                    }
                    current.append(c)
                } else if c == "\"" {
                    inString = true
                } else if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                    break   // the rest of the line is a comment
                }
                i += 1
            }
        }
        return out
    }
}
