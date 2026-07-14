import SwiftUI
import AppKit
import Combine
import ArchiveCore

/// Center pane of the 3-pane shell: hosts the Markdown editor with formatting toolbar, bound to the
/// currently-selected item's body (W7-S1a). Loading + autosaving the selected note's Markdown via the
/// `NoteStore` is driven by `NoteBodyEditorModel`, which keeps the save-back race-safe across selection
/// switches (edit note A, switch to B → A is saved, B is not clobbered). Body text is Notes' own store
/// only — never a Finder tag, never the archival corpus.
struct NoteEditorPane: View {
    @ObservedObject var nav: NotesNavigationModel

    @StateObject private var bodyEditor = NoteBodyEditorModel()
    @State private var isRaw = false
    @StateObject private var formatting = FormattingContext()
    /// Stable across re-renders (populated once in `MarkdownEditorView.makeNSView`) so flush-on-switch
    /// keeps working after the parent re-renders.
    @State private var flushBox = EditorFlushBox()
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
                markdown: $bodyEditor.markdown,
                isRaw: $isRaw,
                formatting: formatting,
                flushBox: flushBox,
                onRevealBlock: { anchor in
                    guard let link = anchor.link, let url = URL(string: link) else { return }
                    NSWorkspace.shared.open(url)
                },
                onPreviewBlock: { [weak previewPopover] anchor, anchorView in
                    previewPopover?.show(for: anchor, relativeTo: anchorView)
                }
            )
            .disabled(nav.selectedItemID == nil)   // nothing single-selected → no editable target
        }
        .background(Color(nsColor: .textBackgroundColor))
        .focusedSceneValue(\.formattingContext, formatting)
        .onAppear {
            wireBodySeams()
            syncFormattingIdentity()
            Task { await bodyEditor.select(nav.selectedItemID) }
            refreshZotero()
        }
        .onChange(of: nav.selectedItemID) { _, newID in
            syncFormattingIdentity()
            Task { await bodyEditor.select(newID) }
        }
        .onDisappear {
            // Persist the in-flight edit before the pane/window tears down (never drop a dirty buffer).
            Task { await bodyEditor.flush() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Frontmost-only: re-read the clipboard when the app becomes active
            // (no background polling).
            refreshZotero()
        }
    }

    /// Point the body controller's load/save/flush seams at the shared `NotesModel` + the live editor.
    /// Idempotent — safe if `onAppear` runs more than once.
    private func wireBodySeams() {
        // Capture the shared model strongly: it lives for the app's lifetime (no meaningful cycle — it
        // does not reference this pane), and strong capture avoids `String??` / `Void?` seam types.
        let model = nav.model
        bodyEditor.load = { id in await model.loadBody(for: id) }
        bodyEditor.save = { id, markdown in await model.setBody(markdown, for: id) }
        bodyEditor.flushEditor = { [flushBox] in flushBox.flush?() }
        // W7-S2: give the formatting context the shared model so Create/Append Extract can persist.
        formatting.notesModel = model
    }

    /// Publish the selected item's identity to the formatting context so W7's Create-Extract can anchor
    /// a passage's provenance (source id + snapshot title/date).
    private func syncFormattingIdentity() {
        formatting.currentItemID = nav.selectedItemID
        formatting.currentItemTitle = nav.selectedSummary?.title ?? ""
        formatting.currentItemDateDisplay = nav.selectedSummary?.displayDate ?? ""
        formatting.currentItemKind = nav.selectedSummary?.kind   // W7-S2: gate Create/Append Extract to notes
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
