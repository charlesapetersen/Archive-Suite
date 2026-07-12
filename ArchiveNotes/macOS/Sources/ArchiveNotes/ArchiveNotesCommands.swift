import SwiftUI

/// Format menu for the editor, dispatched via FocusedValue to the active editor's FormattingContext.
struct FormatCommands: Commands {
    @FocusedValue(\.formattingContext) private var formatting

    var body: some Commands {
        CommandMenu("Format") {
            Section {
                Button("Bold") { formatting?.toggleBold() }
                    .keyboardShortcut("b", modifiers: .command)
                    .disabled(formatting == nil)
                Button("Italic") { formatting?.toggleItalic() }
                    .keyboardShortcut("i", modifiers: .command)
                    .disabled(formatting == nil)
                Button("Inline Code") { formatting?.toggleInlineCode() }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                    .disabled(formatting == nil)
                Button("Link\u{2026}") { formatting?.insertLink() }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(formatting == nil)
            }
            Section {
                Button("Body") { formatting?.setPlain() }
                    .keyboardShortcut("0", modifiers: [.command, .option])
                    .disabled(formatting == nil)
                ForEach(1...6, id: \.self) { level in
                    Button("Heading \(level)") { formatting?.setHeading(level) }
                        .keyboardShortcut(KeyEquivalent(Character("\(level)")),
                                          modifiers: [.command, .option])
                        .disabled(formatting == nil)
                }
            }
            Section {
                Button("Bulleted List") { formatting?.toggleUnorderedList() }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                    .disabled(formatting == nil)
                Button("Numbered List") { formatting?.toggleOrderedList() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(formatting == nil)
                Button("Blockquote") { formatting?.toggleBlockquote() }
                    .keyboardShortcut("q", modifiers: [.command, .option])
                    .disabled(formatting == nil)
                Button("Code Block") { formatting?.toggleCodeBlock() }
                    .keyboardShortcut("k", modifiers: [.command, .option])
                    .disabled(formatting == nil)
            }
        }
    }
}

#if DEBUG
/// Debug menu: insert a test source block to exercise the chip rendering + round-trip.
struct DebugBlockCommands: Commands {
    @FocusedValue(\.formattingContext) private var formatting

    var body: some Commands {
        CommandMenu("Debug") {
            Button("Insert Test Source Block") {
                formatting?.insertTestBlock()
            }
            .disabled(formatting == nil)
        }
    }
}
#endif
