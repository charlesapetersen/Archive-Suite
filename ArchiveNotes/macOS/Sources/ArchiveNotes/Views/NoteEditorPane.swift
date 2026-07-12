import SwiftUI
import AppKit
import ArchiveCore

/// Center pane of the 3-pane shell: hosts the Markdown editor with formatting toolbar.
struct NoteEditorPane: View {
    @State private var markdown = ""
    @State private var isRaw = false
    @StateObject private var formatting = FormattingContext()
    @EnvironmentObject private var previewPopover: SourceBlockPreviewState

    var body: some View {
        VStack(spacing: 0) {
            if !isRaw {
                FormattingToolbar(context: formatting)
                Divider()
            }
            rawToggleBar
            Divider()
            MarkdownEditorView(
                markdown: $markdown,
                isRaw: $isRaw,
                formatting: formatting,
                onRevealBlock: { anchor in
                    guard let link = anchor.link, let url = URL(string: link) else { return }
                    NSWorkspace.shared.open(url)
                },
                onPreviewBlock: { [weak previewPopover] anchor, anchorView in
                    previewPopover?.show(for: anchor, relativeTo: anchorView)
                }
            )
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
