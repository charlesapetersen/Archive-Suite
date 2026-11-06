import SwiftUI

/// Format menu for the editor, dispatched via FocusedValue to the active editor's FormattingContext.
struct FormatCommands: Commands {
    @FocusedValue(\.formattingContext) private var formatting

    var body: some Commands {
        CommandMenu("Format") {
            Section {
                Button("Bold") { formatting?.toggleBold() }
                    .keyboardShortcut("b", modifiers: .command)
                    .disabled(formatting == nil)
                Button("Italic") { formatting?.toggleItalic() }
                    .keyboardShortcut("i", modifiers: .command)
                    .disabled(formatting == nil)
                Button("Inline Code") { formatting?.toggleInlineCode() }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                    .disabled(formatting == nil)
                Button("Link\u{2026}") { formatting?.insertLink() }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(formatting == nil)
            }
            Section {
                Button("Body") { formatting?.setPlain() }
                    .keyboardShortcut("0", modifiers: [.command, .option])
                    .disabled(formatting == nil)
                ForEach(1...6, id: \.self) { level in
                    Button("Heading \(level)") { formatting?.setHeading(level) }
                        .keyboardShortcut(KeyEquivalent(Character("\(level)")),
                                          modifiers: [.command, .option])
                        .disabled(formatting == nil)
                }
            }
            // Block formats share ⌥⌘ (headings, Body, Blockquote, Code Block). The lists were ⇧⌘U and ⇧⌘O
            // until W40.fix-suite-shortcuts: ⇧⌘O is Choose Archive Folder… in every app of the suite.
            Section {
                Button("Bulleted List") { formatting?.toggleUnorderedList() }
                    .keyboardShortcut("u", modifiers: [.command, .option])
                    .disabled(formatting == nil)
                Button("Numbered List") { formatting?.toggleOrderedList() }
                    .keyboardShortcut("o", modifiers: [.command, .option])
                    .disabled(formatting == nil)
                Button("Blockquote") { formatting?.toggleBlockquote() }
                    .keyboardShortcut("q", modifiers: [.command, .option])
                    .disabled(formatting == nil)
                Button("Code Block") { formatting?.toggleCodeBlock() }
                    .keyboardShortcut("k", modifiers: [.command, .option])
                    .disabled(formatting == nil)
            }
        }
    }
}

/// File-menu addition: grant Archive Notes access to a Reader archive folder (W26.notesabsence-fu2).
///
/// Takes `SourceBlockPreviewState` directly rather than via `@FocusedValue` — `previewState` is a
/// single app-lifetime `@StateObject` the App itself owns, not per-window editor state, and
/// SwiftUI's `.commands` builder does not inherit `@EnvironmentObject`s set on a window's content.
///
/// Also File ▸ Choose Store Folder… (W40.fix-notes-choose-store), in the same group so the two folder
/// choices sit together. `notesModel` is passed in for the same reason as `previewState`.
struct ReaderRootCommands: Commands {
    let previewState: SourceBlockPreviewState
    let notesModel: NotesModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            // ⇧⌘O, as in the Reader (W40.fix-suite-shortcuts).
            Button("Choose Archive Folder\u{2026}") { previewState.chooseArchiveFolder() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Choose Store Folder\u{2026}") {
                notesModel.storeFolderChooser?.choose(readerRoots: previewState.grantedArchiveFolders)
            }
        }
    }
}

/// File ▸ New Note (⌘N) and New Extract (⌥⌘N) (W40.fix-notes-new-note, notes-1 rows 5 and 38). ⌘N was bound only
/// inside the toolbar's New menu, so the menu bar had no New and the key did nothing. The key window creates
/// through its own `NewItemAction`; with no window open, the item is made in the shared folder scope and the
/// window featuring its kind opens to show it.
///
/// New Template… (W40.fix-notes-templates, notes-1 rows 35 and 41): a template could be made only from the
/// sidebar's Templates row and its +, which the owner could not find. It shows the templates manager and its
/// New Template sheet, which asks the kind.
struct NewItemCommands: Commands {
    let notesModel: NotesModel
    let flushRegistry: EditorFlushRegistry
    @FocusedValue(\.newItemAction) private var newItem
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") { create(.note) }
                .keyboardShortcut("n", modifiers: .command)
            Button("New Extract") { create(.extract) }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Button("New Template\u{2026}") { newTemplate() }
        }
    }

    private func newTemplate() {
        if let newItem { newItem.newTemplate(); return }
        notesModel.pendingNewTemplate = true
        openWindow(id: NotesWindowID.notes)
    }

    private func create(_ kind: Item.Kind) {
        if let newItem { newItem.perform(kind); return }
        let model = notesModel, registry = flushRegistry, open = openWindow
        Task {
            let template = model.defaultTemplateID(for: kind, in: model.selectedFolderId)
            guard let id = await NewItemFlow.create(kind: kind, from: template, model: model, flushing: registry)
            else { return }
            model.openItem(id: id, block: nil)
            // One turn later, as `NoteEditorPane`'s own open does: a window built now would read the
            // request before it is stored.
            DispatchQueue.main.async { open(id: kind == .extract ? NotesWindowID.extracts : NotesWindowID.notes) }
        }
    }
}

/// A window's way to make a new item, published to the menu bar as a focused scene value: `perform(kind)` makes a
/// `kind` item from the selected folder's template of that kind; `newTemplate()` shows the window's templates
/// manager with its New Template sheet.
struct NewItemAction {
    let perform: @MainActor (Item.Kind) -> Void
    let newTemplate: @MainActor () -> Void
}

struct NewItemActionKey: FocusedValueKey {
    typealias Value = NewItemAction
}

extension FocusedValues {
    var newItemAction: NewItemAction? {
        get { self[NewItemActionKey.self] }
        set { self[NewItemActionKey.self] = newValue }
    }
}

/// The one creation path behind every New: a template's open body edits are saved first, and a template whose
/// last save failed makes nothing, so a note never starts from text that is not on disk.
@MainActor
enum NewItemFlow {
    static func create(kind: Item.Kind, from templateId: UUID?, model: NotesModel,
                       flushing registry: EditorFlushRegistry) async -> UUID? {
        if let templateId {
            await registry.flushAll()
            guard !model.hasFailedTemplateBodySave(templateId) else { return nil }
        }
        return await model.newItem(kind: kind, in: model.selectedFolderId, from: templateId)
    }
}

/// View menu: side by side, or the list above the note (W48.notes-stacked-layout), and Show/Hide Inspector
/// (⌥⌘I, W40.notes-detail-layout; ⌘I is Italic here). Both windows follow the one remembered choice;
/// `NotesBrowserView` reads the same keys.
struct LayoutCommands: Commands {
    @AppStorage(NotesLayoutSettingsKey.layoutMode) private var layoutMode: NotesLayoutMode = .sideBySide
    @AppStorage(NotesLayoutSettingsKey.showInspector) private var showingInspector = true

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button(showingInspector ? "Hide Inspector" : "Show Inspector") {
                withAnimation { showingInspector.toggle() }
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
            Picker("Layout", selection: $layoutMode) {
                ForEach(NotesLayoutMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.inline)
            Divider()
        }
    }
}

/// Edit-menu additions: paste archive links as source blocks.
struct SourceBlockCommands: Commands {
    @FocusedValue(\.formattingContext) private var formatting

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Paste as Source Block(s)") {
                formatting?.pasteSourceBlocks()
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .disabled(formatting == nil)
        }
    }
}

/// Note-menu command: attach a Zotero reference from the clipboard (or a prompt).
struct ZoteroCommands: Commands {
    @FocusedValue(\.formattingContext) private var formatting
    @FocusedValue(\.zoteroAutoFillAvailable) private var autoFillAvailable
    @FocusedValue(\.copyLinkAvailable) private var copyLinkAvailable

    var body: some Commands {
        CommandMenu("Note") {
            // ⇧⌘C, the Reader's Copy Link(s) (W40.fix-suite-shortcuts).
            Button("Copy Link") { formatting?.copyCurrentItemLink() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(copyLinkAvailable != true)
            Divider()
            Button("Attach Zotero Link\u{2026}") { formatting?.attachZoteroLink() }
                .disabled(formatting == nil)
            Button("Auto-fill from Zotero\u{2026}") { formatting?.autoFillFromZotero() }
                .disabled(autoFillAvailable != true)
        }
    }
}

/// Extract menu: mint a new extract from the current note selection, or append it to an existing one
/// (07-extracts §5/§6). Dispatched to the focused editor's `FormattingContext`, which holds the live
/// selection + the shared model. Both source a passage FROM a note; invoked with an extract loaded (the
/// Extracts window) or no selection, they no-op with a status hint. (The plan sketched a "Selection"
/// menu; a dedicated Extract menu is the coherent realization alongside the existing Format/Note menus.)
struct ExtractCommands: Commands {
    @FocusedValue(\.formattingContext) private var formatting

    var body: some Commands {
        CommandMenu("Extract") {
            Button("Create Extract") { formatting?.createExtract() }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(formatting == nil)
            Button("Append to Extract\u{2026}") { formatting?.appendToExtract() }
                .disabled(formatting == nil)
        }
    }
}

#if DEBUG
/// Debug menu: insert a test source block to exercise the chip rendering + round-trip.
struct DebugBlockCommands: Commands {
    @FocusedValue(\.formattingContext) private var formatting

    var body: some Commands {
        CommandMenu("Debug") {
            Button("Insert Test Source Block") {
                formatting?.insertTestBlock()
            }
            .disabled(formatting == nil)
        }
    }
}
#endif
