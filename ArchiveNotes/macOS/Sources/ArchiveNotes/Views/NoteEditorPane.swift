import SwiftUI
import AppKit
import Combine
import ArchiveCore

/// Center pane of the 3-pane shell: hosts the Markdown editor with formatting toolbar.
struct NoteEditorPane: View {
    @State private var markdown = ""
    @State private var isRaw = false
    @StateObject private var formatting = FormattingContext()
    @EnvironmentObject private var previewPopover: SourceBlockPreviewState
    @EnvironmentObject private var zoteroStatus: ZoteroStatusModel

    var body: some View {
        VStack(spacing: 0) {
            if let ref = zoteroStatus.clipboardRef {
                zoteroBanner(ref)
                Divider()
            }
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
        .onAppear { refreshZotero() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Frontmost-only: re-read the clipboard when the app becomes active
            // (no background polling).
            refreshZotero()
        }
    }

    /// "Zotero link on clipboard — Attach" affordance (00-overview §D.5).
    private func zoteroBanner(_ ref: ZoteroRef) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .foregroundStyle(Color.accentColor)
            Text("Zotero link on clipboard")
                .font(.callout)
            Text(ref.itemKey)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Attach") {
                formatting.attachZoteroLink()
                zoteroStatus.dismissClipboardRef()
            }
            .accessibilityIdentifier("ar.zotero.banner.attach")
            Button {
                zoteroStatus.dismissClipboardRef()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.10))
        .accessibilityIdentifier("ar.zotero.banner")
    }

    private func refreshZotero() {
        zoteroStatus.refreshClipboard()
        zoteroStatus.refreshAvailability()
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
