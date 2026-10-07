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
    @State private var parseFailureMessage: String?
    /// W7-S3 — a pending jump-to-source request this window should honor (select the note + scroll to
    /// its block). Set by `handleOpen`; the scroll fires once `bodyEditor.loadedID` reaches the target.
    @State private var jumpTarget: NotesModel.OpenRequest?
    /// Set in `onAppear`; until then an open request is left pending for `onAppear` to handle (W9.b5-fu1).
    @State private var hasAppeared = false
    @State private var initialEditorFocusRequested = false
    @State private var initialEditorFocusCompleted = false
    @State private var editorFocusToken = 0
    @State private var extractEditorGeneration = 0
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
    @State private var zoteroItem: Item?
    @State private var zoteroReadGeneration = 0
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
    /// Observe the real dispatch choke-point, including clicks on note-level Zotero chips.
    @ObservedObject private var testOpenSpy = WorkspaceOpenSpy.shared
    /// Read-back of the last passage-paste outcome (W21.vmgui-g13) — the paste's own answer, which the
    /// seam used to discard. "-" keeps the element present before the first paste.
    @State private var testPasteOutcome = "-"
    /// Same for the COPY half — it was the other silent seam (W21.vmgui-g13).
    @State private var testCopyOutcome = "-"
#endif

    var body: some View {
        VStack(spacing: 0) {
            if let ref = clipboardReference {
                zoteroBanner(ref)
                Divider()
            }
            if !isRaw {
                FormattingToolbar(context: formatting)
                Divider()
            }
            rawToggleBar
            Divider()
            if let parseFailureMessage {
                Label(parseFailureMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .accessibilityIdentifier("an.editor.parseFailure")
            }
            bodyEditorView
                .id(bodyEditor.loadedID)
                .id(extractEditorGeneration)
                .disabled(nav.selectedItemID == nil)   // nothing single-selected → no editable target
#if DEBUG
            uiTestControlStrip
#endif
        }
        .background(Color(nsColor: .textBackgroundColor))
        .focusedSceneValue(\.formattingContext, formatting)
        .focusedSceneValue(\.zoteroAutoFillAvailable, formatting.canAutoFillFromZotero)
        // Read from `nav`, not the context: `syncFormattingIdentity` runs in onChange, after this body.
        .focusedSceneValue(\.copyLinkAvailable, nav.selectedItemID != nil && nav.selectedSummary?.kind != nil)
        .sheet(item: $formatting.zoteroAutoFillModel) { model in
            ZoteroAutoFillSheet(model: model) { formatting.zoteroAutoFillModel = nil }
        }
        .alert("Couldn't auto-fill from Zotero", isPresented: Binding(
            get: { formatting.zoteroAutoFillError != nil },
            set: { if !$0 { formatting.dismissZoteroAutoFillError() } }
        )) {
            Button("OK", role: .cancel) { formatting.dismissZoteroAutoFillError() }
        } message: {
            Text(formatting.zoteroAutoFillError ?? "")
        }
        .onAppear {
            wireBodySeams()
            syncFormattingIdentity()
            refreshAssetStore(for: nav.selectedItemID)
            formatting.clearZoteroAutoFillReference()
            Task {
                await bodyEditor.select(nav.selectedItemID)
                refreshZoteroAutoFillReference(for: nav.selectedItemID)
                requestInitialEditorFocusIfReady()
            }
            refreshZotero()
            // W7-S6: register this pane's flush so app-terminate persists its pending edit (idempotent —
            // onAppear may fire more than once, and the same paneID just overwrites its own entry).
            flushRegistry.register(paneID) { [bodyEditor] in await bodyEditor.flushPending() }
            // W9.b5-fu1: a window opened FOR an open request (`.openFeaturingWindow`) can get that request
            // as `onReceive`'s initial value, before this `onAppear` has wired the body seams above.
            // Selecting then would load through the default `load` (returns nil): the item would be marked
            // loaded with an EMPTY body, this method's own select would no-op, and a next keystroke would
            // save over the real body. So a request already pending is handled here, once wired.
            hasAppeared = true
            if nav.model.pendingOpen != nil {
                DispatchQueue.main.async { handleOpen(nav.model.pendingOpen) }
            }
        }
        .onChange(of: nav.selectedItemID) { _, newID in
            parseFailureMessage = nil
            syncFormattingIdentity()
            refreshAssetStore(for: newID)
            formatting.clearZoteroAutoFillReference()
            Task {
                await bodyEditor.select(newID)
                refreshZoteroAutoFillReference(for: newID)
                requestInitialEditorFocusIfReady()
            }
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
        // Only once this pane has appeared — `onAppear` picks up a request that was already pending.
        .onReceive(nav.model.$pendingOpen) { if hasAppeared { handleOpen($0) } }
        .onReceive(nav.model.$itemsGeneration) { _ in
            refreshZoteroAutoFillReference(for: nav.selectedItemID)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            if initialEditorFocusRequested && !initialEditorFocusCompleted { editorFocusToken &+= 1 }
        }
    }

    /// The Markdown editor. Extracted from `body` so the DEBUG UITest seam (W8-S7 §3.3) can be attached
    /// to the value-type representable before it's returned; Release omits the seam entirely (the editor
    /// is byte-identical to the previous inline construction).
    private var bodyEditorView: MarkdownEditorView {
        let editorItemID = bodyEditor.loadedID
        var view = MarkdownEditorView(
            markdown: Binding(
                get: { bodyEditor.markdown },
                set: { bodyEditor.acceptEditorMarkdown($0, for: editorItemID) }
            ),
            isRaw: $isRaw,
            formatting: formatting,
            assetStore: assetStore,
            onParseFailure: { message in
                DispatchQueue.main.async { parseFailureMessage = message }
            },
            onPasteDegraded: { message in nav.model.statusMessage = message },
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
            missingThumbnailProvider: { [weak previewPopover] anchor in
                guard let previewPopover else { return nil }
                return await previewPopover.thumbnail(for: anchor)
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
            contentID: bodyEditor.loadedID,
            revealFirstBlockOnModeSwitch: nav.selectedSummary?.kind == .extract,
            onStyledSwitchApplied: { extractEditorGeneration &+= 1 },
            focusRequestToken: initialEditorFocusRequested && !initialEditorFocusCompleted ? editorFocusToken : nil,
            onFocusApplied: {
                DispatchQueue.main.async { initialEditorFocusCompleted = true }
            },
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
            // TWO ROWS, not one (W21.vmgui-c). The strip lives inside the fixed-width detail pane, so a
            // single row of ten controls measured 361 pt in a 360 pt pane — its right-hand end sat outside
            // the pane, hence outside the window, hence `isHittable == false`. That is exactly how
            // `reveal`/`zoteroOpen` went unreachable while `select`/`pasteImage`/`jump` to their left kept
            // working. Wrapping bounds each row at ~250 pt, so adding a seam can't silently push the last
            // one off-window again. Labels stay short for the same reason.
            VStack(spacing: 2) {
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
                }
                HStack(spacing: 2) {
                    Button("pasteImg") { testBox.pasteImage?() }
                        .accessibilityIdentifier("an.editor.test.pasteImage")
                    Button("jump") { testBox.jumpFirstPassage?() }
                        .accessibilityIdentifier("an.editor.test.jump")
                    Button("reveal") {
                        testBox.revealFirstSource?()
                    }
                    .accessibilityIdentifier("an.editor.test.reveal")
                    Button("zotero") {
                        testBox.openFirstZotero?()
                    }
                    .accessibilityIdentifier("an.editor.test.zoteroOpen")
                    // W14.3's live copy→paste: ⌘C/⌘V go to the first responder, which XCUITest cannot
                    // reliably make the styled text view. These call the production handlers verbatim.
                    Button("copyP") { testCopyOutcome = testBox.copyPassage?() ?? "declined:seamNil" }
                        .accessibilityIdentifier("an.editor.test.copyPassage")
                        .accessibilityValue(testCopyOutcome)
                    // The paste's verdict rides on the BUTTON's own a11y value (W21.vmgui-g13) — no new
                    // element, no new row, no height change. The first cut added a third row and grew the
                    // strip 58 -> 84 pt; that run saw G14 take 1101 s (vs 29 s) and leave a second window
                    // open, cascading `Multiple matching elements` into every editor-using test after it.
                    // Whether the height did that was never established, and it does not need to be: the
                    // diagnosis does not require a layout change, so it should not make one.
                    // `declined:seamNil` (not "-") so "seam not wired" cannot alias onto the pre-click
                    // sentinel — three distinct states used to read the same string.
                    Button("pasteP") { testPasteOutcome = testBox.pastePassage?() ?? "declined:seamNil" }
                        .accessibilityIdentifier("an.editor.test.pastePassage")
                        .accessibilityValue(testPasteOutcome)
                    // Read-back of the last external URL dispatched (G6/G11). A visible static text (not a
                    // 1×1 hidden element — the `an.status.indexReady` probe's queryability hazard) so
                    // XCUITest resolves it; "-" keeps the element present before the first dispatch.
                    Text(testOpenSpy.lastOpenedURL ?? "-")
                        .accessibilityIdentifier("an.editor.test.lastOpenedURL")
                }
            }
            // Height/font kept generous enough that XCUITest reliably hit-tests + focuses these controls
            // (a 14 pt / .caption2 strip is a known XCUITest hit-testing hazard — W8-S8 §G9). DEBUG- and
            // `-ANUITestStorePath`-gated, so a normal run never shows it and Release omits it entirely.
            .frame(height: 58)
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

    private func requestInitialEditorFocusIfReady() {
        guard let id = nav.selectedItemID, bodyEditor.loadedID == id else { return }
        if initialEditorFocusCompleted { return }
        initialEditorFocusRequested = true
        // Selection may change while a previous deferred makeFirstResponder is in flight. Its
        // content-identity guard will reject it; issue a fresh token now that the new body is loaded.
        editorFocusToken &+= 1
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
        case let .openFeaturingWindow(kind):
            // W9.b5-fu1: the featuring window may be closed, leaving no pane to act. Opening it mounts
            // its pane, whose `onAppear` picks up the still-pending request; if it is already open this
            // only fronts it (singleton `Window`), and its own pane handles + consumes the request.
            // One turn later, not here: `@Published` emits in `willSet`, and `openWindow` builds a closed
            // window synchronously — its pane would read `pendingOpen` before the request is stored, see
            // nil, and never act (measured in the VM).
            let windowID = kind == .extract ? NotesWindowID.extracts : NotesWindowID.notes
            DispatchQueue.main.async { openWindow(id: windowID) }
        case .ignore:
            break               // a missing target is reported by the Note window only
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
        formatting.zoteroStatus = zoteroStatus
        formatting.flushCurrentNote = { [bodyEditor] in await bodyEditor.flushPending() }
    }

    /// Ensure the item-scoped inline-image asset store exists (lazily, once the model's `NoteStore` has
    /// bootstrapped) and point it at the selected item (W7-S5). One instance is retargeted per selection
    /// — a paste always lands in the *current* note's `assets/`, and the editor coordinator's wiring
    /// (established in `makeNSView`) never goes stale across selection switches.
    private func refreshAssetStore(for id: UUID?) {
        if assetStore == nil { assetStore = nav.model.makeAssetStore() }
        assetStore?.itemID = id
        formatting.assetStore = assetStore
    }

    /// Auto-fill is enabled only after the selected persisted note proves it carries one unambiguous
    /// Zotero reference. Clearing first prevents an older async read from advertising a ref on a newly
    /// selected note; the id guard rejects the same stale completion.
    private func refreshZoteroAutoFillReference(for id: UUID?) {
        // A prior body-selection task may finish after the user has already moved elsewhere.
        guard id == nav.selectedItemID else { return }
        formatting.clearZoteroAutoFillReference()
        zoteroItem = nil
        zoteroReadGeneration &+= 1
        let generation = zoteroReadGeneration
        guard let id else { return }
        Task {
            guard let item = await nav.model.itemForZoteroAutoFill(id),
                  nav.selectedItemID == id, generation == zoteroReadGeneration else { return }
            zoteroItem = item
            formatting.updateZoteroAutoFillReference(from: item)
        }
    }

    /// Dedup is window/selection-local, not cached against the shared pasteboard change count. Moving
    /// between notes with an unchanged clipboard (or attaching a reference) must re-evaluate the banner.
    private var clipboardReference: ZoteroRef? {
        guard let item = zoteroItem, item.id == nav.selectedItemID else { return nil }
        let attached = Set(item.zotero.map(\.selectLink) + item.blocks.compactMap { $0.source?.zoteroSelect })
        return ZoteroClipboardDetect.detect(pasteboardString: zoteroStatus.clipboardRef?.selectLink,
                                            attachedLinks: attached)
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

// MARK: - Template body editor (W9.d3)

/// The template pane uses the same Markdown editor and save-on-switch model as notes, with
/// Template/<uuid> load/save seams. A model-owned lease keeps its independent buffer exclusive
/// across the Notes and Extracts windows.
struct TemplateBodyEditorPane: View {
    @ObservedObject var model: NotesModel
    let templateID: UUID?

    @StateObject private var bodyEditor = NoteBodyEditorModel()
    @StateObject private var formatting = FormattingContext()
    @State private var isRaw = false
    @State private var parseFailureMessage: String?
    @State private var flushBox = EditorFlushBox()
    @State private var paneID = UUID()
    @State private var ownedID: UUID?
    @State private var canEdit = false
    @State private var selectionGeneration = 0
    @State private var transition: Task<Void, Never>?
    @State private var teardown: Task<Void, Never>?
    @EnvironmentObject private var flushRegistry: EditorFlushRegistry
#if DEBUG
    @State private var testBox = EditorTestBox()
    @State private var testCommitInput = ""
#endif

    var body: some View {
        VStack(spacing: 0) {
            if !isRaw {
                FormattingToolbar(context: formatting)
                    .disabled(!canEdit)
                Divider()
            }
            HStack {
                Text("Template body").font(.caption).foregroundStyle(.secondary)
                    .help("Edit Markdown here. Add images after creating a note from this template.")
                Spacer()
                Button { isRaw.toggle() } label: {
                    Image(systemName: isRaw ? "doc.plaintext" : "doc.richtext")
                }
                .buttonStyle(.borderless)
                .disabled(!canEdit)
                .help(isRaw ? "Switch to styled mode" : "Switch to raw Markdown (⌘/)")
                .keyboardShortcut("/", modifiers: .command)
                .accessibilityIdentifier("an.template.editor.rawToggle")
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(.bar)
            if let parseFailureMessage {
                Label(parseFailureMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .accessibilityIdentifier("an.template.editor.parseFailure")
            }
            if let templateID, !canEdit {
                HStack {
                    Text(model.hasFailedTemplateBodyLoad(templateID)
                         ? "This template couldn't be opened. Its existing body is safe."
                         : model.isTemplateEditedElsewhere(templateID, pane: paneID)
                           ? "This template is open for editing in another window."
                           : "Opening template…")
                    Spacer()
                    Button("Retry") { switchToTemplate(templateID) }
                }
                .font(.caption)
                .padding(8)
            }
            templateEditorView
                .disabled(!canEdit)
                .accessibilityIdentifier("an.template.editor")
#if DEBUG
            if UserDefaults.standard.string(forKey: "ANUITestStorePath") != nil {
                HStack {
                    TextField("Template body test input", text: $testCommitInput)
                        .accessibilityIdentifier("an.template.editor.test.input")
                    Button("commit") { testBox.replaceMarkdown?(testCommitInput) }
                        .disabled(!canEdit)
                        .accessibilityIdentifier("an.template.editor.test.commit")
                    Text(String(bodyEditor.markdown.prefix(80)))
                        .accessibilityIdentifier("an.template.editor.test.current")
                }
                .frame(height: 36)
            }
#endif
        }
        .focusedSceneValue(\.formattingContext, formatting)
        .onAppear {
            bodyEditor.load = { [model] id in await model.loadTemplateBody(for: id) }
            bodyEditor.save = { [model] id, markdown in await model.setTemplateBody(markdown, for: id) }
            bodyEditor.flushEditor = { [flushBox] in flushBox.flush?() }
            flushRegistry.register(paneID) {
                await transition?.value
                await teardown?.value
                await bodyEditor.flushPending()
            }
            switchToTemplate(templateID)
        }
        .onChange(of: templateID) { _, id in switchToTemplate(id) }
        .onDisappear {
            selectionGeneration &+= 1  // invalidate any in-flight load before teardown
            let closingGeneration = selectionGeneration
            let previous = transition
            let previousTeardown = teardown
            canEdit = false
            teardown = Task { @MainActor in
                await previousTeardown?.value
                await previous?.value
                await bodyEditor.flushPending()
                if let ownedID { model.releaseTemplateEdit(ownedID, pane: paneID) }
                ownedID = nil
                if selectionGeneration == closingGeneration {
                    flushRegistry.deregister(paneID)
                }
            }
        }
    }

    private var templateEditorView: MarkdownEditorView {
        var view = MarkdownEditorView(markdown: $bodyEditor.markdown, isRaw: $isRaw,
                                      formatting: formatting, rejectImagePaste: true,
                                      flushBox: flushBox)
        view.onParseFailure = { message in
            DispatchQueue.main.async { parseFailureMessage = message }
        }
#if DEBUG
        view.testBox = testBox
#endif
        return view
    }

    private func switchToTemplate(_ id: UUID?) {
        parseFailureMessage = nil
        selectionGeneration &+= 1
        let generation = selectionGeneration
        let previous = transition
        let closing = teardown
        canEdit = false
        transition = Task { @MainActor in
            await closing?.value
            await previous?.value
            guard generation == selectionGeneration else { return }
            await bodyEditor.select(nil)       // flush outgoing body before releasing its lease
            if let ownedID { model.releaseTemplateEdit(ownedID, pane: paneID) }
            ownedID = nil
            guard generation == selectionGeneration, let id,
                  model.claimTemplateEdit(id, pane: paneID) else { return }
            ownedID = id
            await bodyEditor.select(id)
            canEdit = generation == selectionGeneration
                   && !model.hasFailedTemplateBodyLoad(id)
                   && bodyEditor.loadedID == id
        }
    }
}
