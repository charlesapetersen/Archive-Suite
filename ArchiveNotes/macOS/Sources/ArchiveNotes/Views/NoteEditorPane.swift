import SwiftUI

/// Center pane of the 3-pane shell: hosts the Markdown editor with a raw-toggle toolbar button.
struct NoteEditorPane: View {
    @State private var markdown = ""
    @State private var isRaw = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            MarkdownEditorView(markdown: $markdown, isRaw: $isRaw)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var toolbar: some View {
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
