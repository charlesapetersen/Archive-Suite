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
    /// W14.4(b) — used to bring THIS window forward when it consumes a jump-to-source / new-extract
    /// open request (the singleton `Window` scene fronts the existing window; it never duplicates).
    @Environment(\.openWindow) private var openWindow

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
    /// W7-S6 — app-level registry this pane registers its flush into, so a hard ⌘Q / app terminate (which
    /// doesn't reliably fire `.onDisappear`) still persists the last keystrokes via the app delegate.
    @EnvironmentObject private var flushRegistry: EditorFlushRegistry
    /// Stable per-pane identity for the flush registry (survives re-renders; each window's pane is
    /// distinct), so register/deregister pair up and a closed window removes exactly its own entry.
    @State private var paneID = UUID()

#if DEBUG
    /// DEBUG-only UITest seam (W8-S7 §3.3): a hidden control strip (shown ONLY under `-ANUITestStorePath`)
    /// lets XCUITest commit body text / set a selection without focusing the styled NSTextView (a known
    /// XCUITest weak spot). Stable across re-renders like `flushBox`. Compiled out of Release.
    @State private var testBox = EditorTestBox()
    @State private var testCommitInput = ""
    @State private var testSelectionInput = ""
    /// The last external URL the app dispatched via `openExternalURL`, surfaced for the G6/G11 checks to
    /// read back (the reveal/zotero seams fire synchronously, so the button action re-reads the spy).
    @State private var testLastOpened = ""
#endif

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
            bodyEditorView
                .disabled(nav.selectedItemID == nil)   // nothing single-selected → no editable target
#if DEBUG
            uiTestControlStrip
#endif
        }
        .background(Color(nsColor: .textBackgroundColor))
        .focusedSceneValue(\.formattingContext, formatting)
        .onAppear {
            wireBodySeams()
            syncFormattingIdentity()
            refreshAssetStore(for: nav.selectedItemID)
            Task { await bodyEditor.select(nav.selectedItemID) }
            refreshZotero()
            // W7-S6: register this pane's flush so app-terminate persists its pending edit (idempotent —
            // onAppear may fire more than once, and the same paneID just overwrites its own entry).
            flushRegistry.register(paneID) { [bodyEditor] in await bodyEditor.flushPending() }
        }
        .onChange(of: nav.selectedItemID) { _, newID in
            syncFormattingIdentity()
            refreshAssetStore(for: newID)
            Task { await bodyEditor.select(newID) }
        }
        .onDisappear {
            // Persist the in-flight edit before the pane/window tears down (never drop a dirty buffer),
            // and drop this pane from the terminate registry so a later quit doesn't flush a dead editor.
            flushRegistry.deregister(paneID)
            Task { await bodyEditor.flushPending() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Frontmost-only: re-read the clipboard when the app becomes active
            // (no background polling).
            refreshZotero()
        }
        // W7-S3 jump-to-source consume side: the window featuring the target's kind selects it + scrolls.
        .onReceive(nav.model.$pendingOpen) { handleOpen($0) }
    }

    /// The Markdown editor. Extracted from `body` so the DEBUG UITest seam (W8-S7 §3.3) can be attached
    /// to the value-type representable before it's returned; Release omits the seam entirely (the editor
    /// is byte-identical to the previous inline construction).
    private var bodyEditorView: MarkdownEditorView {
        var view = MarkdownEditorView(
            markdown: $bodyEditor.markdown,
            isRaw: $isRaw,
            formatting: formatting,
            assetStore: assetStore,
            flushBox: flushBox,
            onRevealBlock: { anchor in
                guard let link = anchor.link, let url = URL(string: link) else { return }
                // Dispatch through the shared choke-point (records under a UITest launch for G6; opens
                // for real otherwise). The chip's reveal action fires on the main thread; assumeIsolated
                // satisfies the @Sendable callback without an async hop (mirrors onJumpBlock).
                MainActor.assumeIsolated { openExternalURL(url) }
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
            passageGeneration: nav.model.itemsGeneration,   // reactive chip-title refresh (W14.4 c)
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
#if DEBUG
        view.testBox = testBox
#endif
        return view
    }

#if DEBUG
    /// Hidden UITest control strip (W8-S7 §3.3). Present ONLY under `-ANUITestStorePath`, so a normal
    /// DEBUG run never shows it. XCUITest reliably types into these plain `TextField`s + clicks these
    /// buttons (unlike the styled NSTextView), driving the editor through `testBox`.
    @ViewBuilder
    private var uiTestControlStrip: some View {
        if Self.isUITestHarness {
            HStack(spacing: 2) {
                TextField("", text: $testCommitInput)
                    .accessibilityIdentifier("an.editor.test.input")
                Button("commit") { testBox.replaceMarkdown?(testCommitInput) }
                    .accessibilityIdentifier("an.editor.test.commit")
                Button("insert") { testBox.insertMarkdown?(testCommitInput) }
                    .accessibilityIdentifier("an.editor.test.insert")
                TextField("", text: $testSelectionInput)
                    .accessibilityIdentifier("an.editor.test.selectionInput")
                Button("select") {
                    let parts = testSelectionInput.split(separator: ",")
                    if parts.count == 2,
                       let loc = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                       let len = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                        testBox.setSelection?(loc, len)
                    }
                }
                .accessibilityIdentifier("an.editor.test.select")
                Button("pasteImage") { testBox.pasteImage?() }
                    .accessibilityIdentifier("an.editor.test.pasteImage")
                Button("jump") { testBox.jumpFirstPassage?() }
                    .accessibilityIdentifier("an.editor.test.jump")
                Button("reveal") {
                    testBox.revealFirstSource?()
                    testLastOpened = WorkspaceOpenSpy.shared.lastOpenedURL ?? ""
                }
                .accessibilityIdentifier("an.editor.test.reveal")
                Button("zoteroOpen") {
                    testBox.openFirstZotero?()
                    testLastOpened = WorkspaceOpenSpy.shared.lastOpenedURL ?? ""
                }
                .accessibilityIdentifier("an.editor.test.zoteroOpen")
                // Read-back of the last external URL dispatched (G6/G11). A visible static text (not a
                // 1×1 hidden element — the `an.status.indexReady` probe's queryability hazard) so XCUITest
                // resolves it; "-" keeps the element present before the first dispatch.
                Text(testLastOpened.isEmpty ? "-" : testLastOpened)
                    .accessibilityIdentifier("an.editor.test.lastOpenedURL")
            }
            // Height/font kept generous enough that XCUITest reliably hit-tests + focuses these controls
            // (a 14 pt / .caption2 strip is a known XCUITest hit-testing hazard — W8-S8 §G9). DEBUG- and
            // `-ANUITestStorePath`-gated, so a normal run never shows it and Release omits it entirely.
            .frame(height: 28)
        }
    }

    /// True when the app was launched by the UITest harness (`-ANUITestStorePath`), mirroring the
    /// `RootFolderStore` / `NotesTagProjector` gate — keeps the test strip out of a normal DEBUG run.
    private static var isUITestHarness: Bool {
        if let p = UserDefaults.standard.string(forKey: "ANUITestStorePath"), !p.isEmpty { return true }
        return false
    }
#endif

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
            // W14.4(b): bring THIS window (the one featuring the target's kind) to the front + focus it,
            // so a jump-to-source or a freshly-created extract isn't stranded behind the initiating
            // window. Only this window reached `.selectAndScroll` (others `.ignore`), so exactly the
            // featuring window raises. `openWindow` fronts the singleton scene without duplicating it.
            openWindow(id: nav.windowKind == .extract ? NotesWindowID.extracts : NotesWindowID.notes)
            NSApp.activate(ignoringOtherApps: true)
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
            .accessibilityIdentifier("an.zotero.banner.attach")
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
        .accessibilityIdentifier("an.zotero.banner")
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
            .accessibilityIdentifier("an.editor.rawToggle")
            .padding(.trailing, 8)
        }
        .frame(height: 28)
        .background(.bar)
    }
}
