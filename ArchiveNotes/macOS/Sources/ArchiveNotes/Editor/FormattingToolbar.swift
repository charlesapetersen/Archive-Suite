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
            toggleButton(systemImage: "bold", active: context.state.isBold) {
                context.toggleBold()
            }
            toggleButton(systemImage: "italic", active: context.state.isItalic) {
                context.toggleItalic()
            }
            toggleButton(systemImage: "chevron.left.forwardslash.chevron.right",
                         active: context.state.isCode) {
                context.toggleInlineCode()
            }
            toggleButton(systemImage: "link", active: context.state.hasLink) {
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
                         active: context.state.isUnorderedList) {
                context.toggleUnorderedList()
            }
            toggleButton(systemImage: "list.number",
                         active: context.state.isOrderedList) {
                context.toggleOrderedList()
            }
            toggleButton(systemImage: "text.quote",
                         active: context.state.isBlockquote) {
                context.toggleBlockquote()
            }
            toggleButton(systemImage: "curlybraces",
                         active: context.state.isCodeBlock) {
                context.toggleCodeBlock()
            }
        }
    }

    // MARK: - Helpers

    private func toggleButton(systemImage: String,
                               active: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .background(active ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
