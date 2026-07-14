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
    /// W7-S3 — a pending jump-to-source request this window should honor (select the note + scroll to
    /// its block). Set by `handleOpen`; the scroll fires once `bodyEditor.loadedID` reaches the target.
    @State private var jumpTarget: NotesModel.OpenRequest?
    @StateObject private var formatting = FormattingContext()
    /// Stable across re-renders (populated once in `MarkdownEditorView.makeNSView`) so flush-on-switch
    /// keeps working after the parent re-renders.
    @State private var flushBox = EditorFlushBox()
    /// W7-S5 — item-scoped inline-image asset store (one instance, retargeted to the selected item), so a
    /// pasted/dropped image persists into that item's `assets/`. Created lazily once the model's
    /// `NoteStore` has bootstrapped; nil for an injected (store-less) model.
    @State private var assetStore: ItemAssetStore?
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
                assetStore: assetStore,
                flushBox: flushBox,
                onRevealBlock: { anchor in
                    guard let link = anchor.link, let url = URL(string: link) else { return }
                    NSWorkspace.shared.open(url)
                },
                onPreviewBlock: { [weak previewPopover] anchor, anchorView in
                    previewPopover?.show(for: anchor, relativeTo: anchorView)
                },
                onJumpBlock: { [model = nav.model] anchor in
                    // W7-S3: extract provenance chip → in-app navigation to the source note + block.
                    // The chip's action fires on the main thread; assumeIsolated satisfies the
                    // @Sendable callback type without an async hop.
                    guard let target = anchor.notePassageTarget else { return }
                    MainActor.assumeIsolated { model.openItem(id: target.id, block: target.block) }
                },
                passageSummaries: nav.model.allItems,   // resolve chip live titles / missing state
                scrollRequest: scrollRequest,
                onScrollOutcome: { hitExact in
                    // Runs inside updateNSView — defer state mutation out of the view-update pass.
                    DispatchQueue.main.async {
                        if !hitExact {
                            nav.model.statusMessage = "The source note has changed since this extract was made."
                        }
                        jumpTarget = nil
                    }
                }
            )
            .disabled(nav.selectedItemID == nil)   // nothing single-selected → no editable target
        }
        .background(Color(nsColor: .textBackgroundColor))
        .focusedSceneValue(\.formattingContext, formatting)
        .onAppear {
            wireBodySeams()
            syncFormattingIdentity()
            refreshAssetStore(for: nav.selectedItemID)
            Task { await bodyEditor.select(nav.selectedItemID) }
            refreshZotero()
        }
        .onChange(of: nav.selectedItemID) { _, newID in
            syncFormattingIdentity()
            refreshAssetStore(for: newID)
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
        // W7-S3 jump-to-source consume side: the window featuring the target's kind selects it + scrolls.
        .onReceive(nav.model.$pendingOpen) { handleOpen($0) }
    }

    /// The scroll request to hand the editor: present only once the target item's body is actually
    /// loaded (`loadedID` matches), so the block-ordinal map maps against the right note's content.
    private var scrollRequest: EditorScrollRequest? {
        guard let t = jumpTarget, bodyEditor.loadedID == t.id else { return nil }
        return EditorScrollRequest(token: t.token, block: t.block)
    }

    /// Handle an in-app open request (jump-to-source or an `archivenotes://open`). Only the window that
    /// features the target's kind acts; degradations (deleted / non-note source) surface a status. Pure
    /// decision in `NotePassageResolve.openAction`; this method does the SwiftUI select + scroll setup.
    private func handleOpen(_ req: NotesModel.OpenRequest?) {
        guard let req else { return }
        switch NotePassageResolve.openAction(forItemID: req.id, block: req.block,
                                             among: nav.model.allItems, windowKind: nav.windowKind) {
        case let .selectAndScroll(id, _):
            // Make sure the note is reachable in this window's list before selecting it.
            if !nav.displayed.contains(where: { $0.id == id }) { nav.clearUserFilters() }
            nav.select(id)          // triggers the body load via the selectedItemID onChange
            jumpTarget = req        // arm the scroll; fires when loadedID reaches the target
            DispatchQueue.main.async { nav.model.consumeOpen() }
        case .reportSourceMissing:
            nav.model.statusMessage = "The source note for this passage no longer exists — the extract text is preserved."
            DispatchQueue.main.async { nav.model.consumeOpen() }
        case .ignore:
            break               // the window featuring the target's kind handles it
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

    /// Ensure the item-scoped inline-image asset store exists (lazily, once the model's `NoteStore` has
    /// bootstrapped) and point it at the selected item (W7-S5). One instance is retargeted per selection
    /// — a paste always lands in the *current* note's `assets/`, and the editor coordinator's wiring
    /// (established in `makeNSView`) never goes stale across selection switches.
    private func refreshAssetStore(for id: UUID?) {
        if assetStore == nil { assetStore = nav.model.makeAssetStore() }
        assetStore?.itemID = id
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
