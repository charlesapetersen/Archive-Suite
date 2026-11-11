import SwiftUI

/// Formatting toolbar shown above the editor, reflecting and driving the current formatting state.
struct FormattingToolbar: View {
    @ObservedObject var context: FormattingContext

    var body: some View {
        HStack(spacing: 2) {
            inlineGroup
            Divider().frame(height: 16)
            headingMenu
            Divider().frame(height: 16)
            blockGroup
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(.bar)
    }

    // MARK: - Inline buttons

    private var inlineGroup: some View {
        Group {
            toggleButton(systemImage: "bold", active: context.state.isBold,
                         identifier: "an.editor.toolbar.bold",
                         help: "Bold (⌘B)") {
                context.toggleBold()
            }
            toggleButton(systemImage: "italic", active: context.state.isItalic,
                         identifier: "an.editor.toolbar.italic",
                         help: "Italic (⌘I)") {
                context.toggleItalic()
            }
            toggleButton(systemImage: "underline", active: context.state.isUnderline,
                         identifier: "an.editor.toolbar.underline",
                         help: "Underline (⌘U)") {
                context.toggleUnderline()
            }
            toggleButton(systemImage: "highlighter", active: context.state.isHighlight,
                         identifier: "an.editor.toolbar.highlight",
                         help: "Highlight (⇧⌘H)") {
                context.toggleHighlight()
            }
            toggleButton(systemImage: "chevron.left.forwardslash.chevron.right",
                         active: context.state.isCode,
                         identifier: "an.editor.toolbar.code",
                         help: "Inline Code (⌥⌘C)") {
                context.toggleInlineCode()
            }
            toggleButton(systemImage: "link", active: context.state.hasLink,
                         identifier: "an.editor.toolbar.link",
                         help: "Link (⌘K)") {
                context.insertLink()
            }
        }
    }

    // MARK: - Heading picker

    private var headingMenu: some View {
        Menu {
            Button("Body") { context.setPlain() }
            Divider()
            ForEach(1...6, id: \.self) { level in
                Button("Heading \(level)") { context.setHeading(level) }
            }
        } label: {
            Text(headingLabel)
                .font(.system(size: 11))
                .frame(minWidth: 36)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Paragraph style: Body (⌥⌘0) or Heading 1–6 (⌥⌘1–⌥⌘6)")
        .accessibilityIdentifier("an.editor.toolbar.heading")
    }

    private var headingLabel: String {
        if let level = context.state.headingLevel {
            return "H\(level)"
        }
        return "¶"
    }

    // MARK: - Block buttons

    private var blockGroup: some View {
        Group {
            toggleButton(systemImage: "list.bullet",
                         active: context.state.isUnorderedList,
                         identifier: "an.editor.toolbar.bullet",
                         help: "Bulleted List (⌥⌘U)") {
                context.toggleUnorderedList()
            }
            toggleButton(systemImage: "list.number",
                         active: context.state.isOrderedList,
                         identifier: "an.editor.toolbar.numbered",
                         help: "Numbered List (⌥⌘O)") {
                context.toggleOrderedList()
            }
            toggleButton(systemImage: "text.quote",
                         active: context.state.isBlockquote,
                         identifier: "an.editor.toolbar.quote",
                         help: "Blockquote (⌥⌘Q)") {
                context.toggleBlockquote()
            }
            toggleButton(systemImage: "curlybraces",
                         active: context.state.isCodeBlock,
                         identifier: "an.editor.toolbar.codeblock",
                         help: "Code Block (⌥⌘K)") {
                context.toggleCodeBlock()
            }
        }
    }

    // MARK: - Helpers

    private func toggleButton(systemImage: String,
                               active: Bool,
                               identifier: String,
                               help: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .background(active ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        // The owner's notes-2 session (row 5): the icons had no names. The shortcut is the Format menu's.
        .help(help)
        .accessibilityIdentifier(identifier)
    }
}
