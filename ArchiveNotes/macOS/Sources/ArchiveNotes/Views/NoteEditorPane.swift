import SwiftUI

/// Center pane of the 3-pane shell: hosts the Markdown editor with formatting toolbar.
struct NoteEditorPane: View {
    @State private var markdown = ""
    @State private var isRaw = false
    @StateObject private var formatting = FormattingContext()

    var body: some View {
        VStack(spacing: 0) {
            if !isRaw {
                FormattingToolbar(context: formatting)
                Divider()
            }
            rawToggleBar
            Divider()
            MarkdownEditorView(markdown: $markdown, isRaw: $isRaw, formatting: formatting)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .focusedSceneValue(\.formattingContext, formatting)
    }

    private var rawToggleBar: some View {
        HStack {
            Spacer()
            Button {
                isRaw.toggle()
            } label: {
                Image(systemName: isRaw ? "doc.plaintext" : "doc.richtext")
                    .help(isRaw ? "Switch to styled mode" : "Switch to raw Markdown (⌘/)")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("/", modifiers: .command)
            .padding(.trailing, 8)
        }
        .frame(height: 28)
        .background(.bar)
    }
}
