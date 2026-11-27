import AppKit
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
                // W40.notes-underline-highlight: written `<u>…</u>` and `<mark>…</mark>` (`MarkdownBridge`).
                Button("Underline") { formatting?.toggleUnderline() }
                    .keyboardShortcut("u", modifiers: .command)
                    .disabled(formatting == nil)
                Button("Highlight") { formatting?.toggleHighlight() }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
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
/// Also File ▸ New Library… and Open Library… (W40.fix-notes-choose-store, W49.notes-store-format), in the
/// same group so the folder choices sit together. `notesModel` is passed in for the same reason as
/// `previewState`.
///
/// A library double-clicked in Finder takes the same route, wired here rather than from the main window: a launch
/// by double-click opens no window by itself (the app is launched to open a document, and nothing is restored on
/// a first launch), so a window's `onAppear` never ran and the library waited unasked (measured with the Release
/// build in the VM, W49.notes-finder-open-check). The menu bar is built at launch whether or not a window is.
///
/// Open Recent and Reveal Library in Finder (W49.notes-library-ux) sit with them, and Reload Library
/// (W49.notes-reload-library).
struct ReaderRootCommands: Commands {
    let previewState: SourceBlockPreviewState
    let notesModel: NotesModel
    let appDelegate: NotesAppDelegate
    @Environment(\.openWindow) private var openWindow

    /// Opens a library from Finder: the main window first, so the app is there behind the question and after a
    /// Cancel, then Open Library…'s checks and confirmation.
    private func openLibraryFromFinder(_ url: URL) {
        openWindow(id: NotesWindowID.notes)
        NSApp.activate(ignoringOtherApps: true)
        LibraryActions.open(url, model: notesModel, previewState: previewState)
    }

    var body: some Commands {
        // Idempotent: a rebuilt menu bar only hands over the same route again.
        let _ = appDelegate.openLibrary = openLibraryFromFinder
        CommandGroup(after: .newItem) {
            // ⇧⌘O, as in the Reader (W40.fix-suite-shortcuts).
            Button("Choose Archive Folder\u{2026}") { previewState.chooseArchiveFolder() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("New Library\u{2026}") { LibraryActions.newLibrary(model: notesModel, previewState: previewState) }
            Button("Open Library\u{2026}") { LibraryActions.openLibrary(model: notesModel, previewState: previewState) }
            if let recents = notesModel.recentLibraries {
                Menu("Open Recent") {
                    OpenRecentMenuItems(recents: recents, model: notesModel, previewState: previewState)
                }
            }
            Button("Reveal Library in Finder") { notesModel.revealLibraryInFinder() }
                .disabled(notesModel.libraryURL == nil)
            // Notes and folders changed on disk outside the app (W49.notes-reload-library).
            Button("Reload Library") { Task { await notesModel.reloadLibrary() } }
                .disabled(notesModel.libraryURL == nil || notesModel.isReloadingLibrary)
        }
    }
}

/// File ▸ Open Recent's items: the libraries opened before, newest first, then Clear Menu. The open library is
/// listed but greyed, as there is nothing to switch to.
struct OpenRecentMenuItems: View {
    @ObservedObject var recents: RecentLibraries
    let model: NotesModel
    let previewState: SourceBlockPreviewState

    var body: some View {
        let current = model.libraryURL.map(RecentLibraries.canonicalPath)
        ForEach(recents.entries) { entry in
            Button(recents.title(for: entry)) {
                LibraryActions.openRecent(entry, recents: recents, model: model, previewState: previewState)
            }
            .disabled(entry.path == current)
        }
        if !recents.entries.isEmpty { Divider() }
        Button("Clear Menu") { recents.clear() }
            .disabled(recents.entries.isEmpty)
    }
}

/// The library commands, shared by the File menu and the No Library Open state's buttons
/// (W49.notes-library-ux). Each runs from a menu or button action, never a `Task`: it may end in Restart and
/// Switch, whose quit needs the main run loop (`StoreFolderChooser.onMainRunLoop`).
@MainActor
enum LibraryActions {
    static func newLibrary(model: NotesModel, previewState: SourceBlockPreviewState) {
        grantArchiveIfAsked(model.storeFolderChooser?.newLibrary(readerRoots: previewState.grantedArchiveFolders),
                            previewState)
    }

    static func openLibrary(model: NotesModel, previewState: SourceBlockPreviewState) {
        grantArchiveIfAsked(model.storeFolderChooser?.choose(readerRoots: previewState.grantedArchiveFolders),
                            previewState)
    }

    /// A library given by URL (from Finder, or Open Recent): Open Library…'s checks and confirmation.
    static func open(_ url: URL, model: NotesModel, previewState: SourceBlockPreviewState) {
        grantArchiveIfAsked(model.storeFolderChooser?.use(url, readerRoots: previewState.grantedArchiveFolders),
                            previewState)
    }

    /// Open Recent: a library that can no longer be found is said so and taken off the list. The scope its
    /// bookmark started is held only while the choice is made; a switch quits first.
    static func openRecent(_ entry: RecentLibraries.Entry, recents: RecentLibraries,
                           model: NotesModel, previewState: SourceBlockPreviewState) {
        guard let url = recents.resolve(entry) else {
            recents.remove(entry)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "“\(entry.name)” can't be found."
            alert.informativeText = "It may have been moved, renamed or deleted, or be on a disk that is not "
                + "connected. It has been taken off the Open Recent list. To use it, choose File ▸ Open Library… "
                + "and find it."
            alert.runModal()
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        open(url, model: model, previewState: previewState)
    }

    /// "Is it inside an archive?" answered with Choose Archive Folder…: grant the archive first.
    private static func grantArchiveIfAsked(_ outcome: StoreFolderChooser.Outcome?,
                                            _ previewState: SourceBlockPreviewState) {
        if case .chooseArchiveFirst = outcome { previewState.chooseArchiveFolder() }
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
            // Nothing to make an item in with no library open (W49.notes-library-ux). A switch restarts the app,
            // so whether one is open never changes while it runs.
            Group {
                Button("New Note") { create(.note) }
                    .keyboardShortcut("n", modifiers: .command)
                Button("New Extract") { create(.extract) }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                Button("New Template\u{2026}") { newTemplate() }
            }
            .disabled(!notesModel.isLibraryOpen)
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
        let folderId = model.selectedFolderId
        if let templateId {
            await registry.flushAll()
            guard !model.hasFailedTemplateBodySave(templateId) else { return nil }
        }
        return await model.newItem(kind: kind, in: folderId, from: templateId)
    }
}

/// Duplicate Note (Edit ▸ Duplicate Note, ⌘D, and the row menu; W49.notes-polish-small). Every open editor is saved
/// first, so the copy has what the user sees; a note whose last save failed is not copied, because the copy would
/// be made from the older text on disk.
@MainActor
enum DuplicateNoteFlow {
    static func duplicate(_ id: UUID, nav: NotesNavigationModel, flushing registry: EditorFlushRegistry) async {
        if !(await registry.flushAll()), registry.unsavedDrafts().contains(where: { $0.itemID == id }) {
            nav.model.statusMessage = "This note's last changes aren't saved yet, so it can't be duplicated."
            return
        }
        guard let copy = await nav.model.duplicateNote(id) else { return }
        nav.showingTemplates = false
        nav.select(copy)
    }
}

/// File ▸ Export…, Export Listed…, Page Setup… and Print… (⌘P) (W49.notes-export-print). Export and Print act on
/// the focused window's selected rows; Export Listed on every row its list shows, which is the selected folder
/// after the filters. `NoteExportFlow` asks where and how, and writes only new files outside the library.
struct ExportPrintCommands: Commands {
    let notesModel: NotesModel
    let flushRegistry: EditorFlushRegistry
    let previewState: SourceBlockPreviewState
    @FocusedValue(\.exportTarget) private var target

    var body: some Commands {
        CommandGroup(replacing: .printItem) {
            Button(exportTitle) { export(target?.selected() ?? []) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled((target?.selectedCount ?? 0) == 0)
            Button("Export Listed\u{2026}") { export(target?.listed() ?? []) }
                .disabled((target?.listedCount ?? 0) == 0)
            Divider()
            Button("Page Setup\u{2026}") { NSApp.runPageLayout(nil) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Print\u{2026}") {
                let ids = target?.selected() ?? [], model = notesModel, registry = flushRegistry
                Task { await NoteExportFlow.print(ids, model: model, registry: registry) }
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled((target?.selectedCount ?? 0) == 0)
        }
    }

    private var exportTitle: String {
        let count = target?.selectedCount ?? 0
        return count > 1 ? "Export \(count) Items\u{2026}" : "Export\u{2026}"
    }

    private func export(_ ids: [UUID]) {
        let model = notesModel, registry = flushRegistry, roots = previewState.grantedArchiveFolders
        Task { await NoteExportFlow.export(ids, model: model, registry: registry, archiveRoots: roots) }
    }
}

/// The rows Export and Print act on in the focused window: the selection and the whole list, each in list order.
/// The lists are read only when a command runs; the menu needs only the counts.
struct ExportTarget {
    let selectedCount: Int
    let listedCount: Int
    let selected: @MainActor () -> [UUID]
    let listed: @MainActor () -> [UUID]
}

struct ExportTargetKey: FocusedValueKey {
    typealias Value = ExportTarget
}

extension FocusedValues {
    var exportTarget: ExportTarget? {
        get { self[ExportTargetKey.self] }
        set { self[ExportTargetKey.self] = newValue }
    }
}

/// Edit ▸ Advanced Search… (⇧⌥⌘F, as in the Reader; W40.notes-advanced-search): the focused window's form.
struct AdvancedSearchCommands: Commands {
    @FocusedValue(\.advancedSearchAction) private var advancedSearch

    var body: some Commands {
        // TextEditingCommands replaces the text-editing group; an insertion there disappears from Edit.
        // Anchor to the standard clipboard commands so the window's search stays in the menu and key map.
        CommandGroup(after: .pasteboard) {
            Button("Advanced Search\u{2026}") { advancedSearch?.open() }
                .keyboardShortcut("f", modifiers: [.command, .option, .shift])
                .disabled(advancedSearch == nil)
        }
    }
}

struct AdvancedSearchAction {
    let open: @MainActor () -> Void
}

struct AdvancedSearchActionKey: FocusedValueKey {
    typealias Value = AdvancedSearchAction
}

extension FocusedValues {
    var advancedSearchAction: AdvancedSearchAction? {
        get { self[AdvancedSearchActionKey.self] }
        set { self[AdvancedSearchActionKey.self] = newValue }
    }
}

/// Edit ▸ Duplicate Note (⌘D) copies the one selected note (`DuplicateNoteFlow`).
/// Edit ▸ Delete Note… (⌘⌫, as in Finder; W40.fix-notes-delete-redo, notes-2 row 16): the selected rows (Delete N
/// Notes… for several, one prompt for them all; W49.notes-multiselect-actions), through
/// the same confirmation as the row menu's Delete…. The menu sees ⌘⌫ before a text view does, so in the editor or a
/// text field the key keeps its own meaning, deleting to the start of the line; outside the note list it does nothing.
struct DeleteCommands: Commands {
    @FocusedValue(\.deleteItemAction) private var deleteItem
    @FocusedValue(\.duplicateItemAction) private var duplicateItem

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Duplicate Note") { duplicateItem?.perform() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(duplicateItem == nil)
            Button((deleteItem?.count ?? 1) > 1 ? "Delete \(deleteItem?.count ?? 0) Notes\u{2026}" : "Delete Note\u{2026}") {
                perform()
            }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(deleteItem == nil)
        }
    }

    private func perform() {
        let responder = NSApp.keyWindow?.firstResponder
        if let text = responder as? NSTextView {
            text.doCommand(by: #selector(NSResponder.deleteToBeginningOfLine(_:)))
            return
        }
        // Only the note list's own selection: with the sidebar, a sheet's control or the inspector focused,
        // the selected row is not what ⌘⌫ is aimed at.
        guard responder is ContextMenuTableView else { NSSound.beep(); return }
        deleteItem?.perform()
    }
}

struct DeleteItemAction {
    /// How many notes it deletes, for the menu's title.
    var count = 1
    let perform: @MainActor () -> Void
}

struct DeleteItemActionKey: FocusedValueKey {
    typealias Value = DeleteItemAction
}

extension FocusedValues {
    var deleteItemAction: DeleteItemAction? {
        get { self[DeleteItemActionKey.self] }
        set { self[DeleteItemActionKey.self] = newValue }
    }
}

/// View menu: side by side, or the list above the note (W48.notes-stacked-layout), and Show/Hide Inspector
/// (⌥⌘I, W40.notes-detail-layout; ⌘I is Italic here). Both windows follow the one remembered choice;
/// `NotesBrowserView` reads the same keys.
///
/// Each other part of the window shows and hides here too (W40.notes-window-panes; owner, notes-2 row 22), so the
/// filters, the list and the note text can be all there is: the Folders pane (⌃⌘S, the toolbar's left button), the
/// note's header (title, date), its formatting bar and its tag bar. Hiding the header or the tag bar loses
/// nothing: the list renames a note, the inspector shows its dates, and with the bar hidden its tags.
struct LayoutCommands: Commands {
    @AppStorage(NotesLayoutSettingsKey.layoutMode) private var layoutMode: NotesLayoutMode = .sideBySide
    @AppStorage(NotesLayoutSettingsKey.showInspector) private var showingInspector = true
    @AppStorage(NotesLayoutSettingsKey.showTree) private var showingTree = true
    @AppStorage(NotesLayoutSettingsKey.showNoteHeader) private var showingNoteHeader = true
    @AppStorage(NotesLayoutSettingsKey.showFormattingBar) private var showingFormattingBar = true
    @AppStorage(NotesLayoutSettingsKey.showTagBar) private var showingTagBar = true

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button(showingTree ? "Hide Folders" : "Show Folders") {
                withAnimation { showingTree.toggle() }
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            Button(showingInspector ? "Hide Inspector" : "Show Inspector") {
                showingInspector.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
            Button(showingNoteHeader ? "Hide Note Header" : "Show Note Header") { showingNoteHeader.toggle() }
            Button(showingFormattingBar ? "Hide Formatting Bar" : "Show Formatting Bar") {
                showingFormattingBar.toggle()
            }
            Button(showingTagBar ? "Hide Tag Bar" : "Show Tag Bar") { showingTagBar.toggle() }
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
///
/// ⌃⌘Z Attach and ⌃⌥⌘Z Auto-fill, Z for Zotero (W40.fix-notes-zotero-paste, notes-2 row 27); ⌘V of a
/// `zotero://select/…` link attaches it too. A greyed Auto-fill says why on the line under it (row 28).
struct ZoteroCommands: Commands {
    @FocusedValue(\.formattingContext) private var formatting
    @FocusedValue(\.zoteroAutoFillState) private var autoFillState
    @FocusedValue(\.copyLinkAvailable) private var copyLinkAvailable

    var body: some Commands {
        CommandMenu("Note") {
            // ⇧⌘C, the Reader's Copy Link(s) (W40.fix-suite-shortcuts).
            Button("Copy Link") { formatting?.copyCurrentItemLink() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(copyLinkAvailable != true)
            Divider()
            Button("Attach Zotero Link\u{2026}") { formatting?.attachZoteroLink() }
                .keyboardShortcut("z", modifiers: [.command, .control])
                .disabled(formatting == nil)
            Button("Auto-fill from Zotero\u{2026}") { formatting?.autoFillFromZotero() }
                .keyboardShortcut("z", modifiers: [.command, .control, .option])
                .disabled(autoFillState?.isAvailable != true)
                .help(autoFillState?.reason ?? "")
            if let reason = (autoFillState ?? .noNote).reason {
                Button(reason) {}
                    .disabled(true)
            }
            Divider()
            SourceChipMenuItems()
        }
    }
}

/// Note menu: the actions of the source chip whose block holds the caret (W49.notes-chip-access), so a chip's
/// buttons work from the keyboard. ⌃⌘, beside ⌃⌘Z's Zotero commands. With the caret in no chip's block, or on a
/// chip that lacks the action, the command beeps.
struct SourceChipMenuItems: View {
    var body: some View {
        item(.jump, "j")
        item(.reveal, "r")
        item(.preview, "y")
        item(.copyForZotero, nil)
        item(.addToZotero, nil)
        item(.openInZotero, "o")
    }

    @ViewBuilder
    private func item(_ action: BlockHeaderChipAction, _ key: Character?) -> some View {
        let button = Button(action.menuTitle) { Self.perform(action) }
        if let key {
            button.keyboardShortcut(KeyEquivalent(key), modifiers: [.command, .control])
        } else {
            button
        }
    }

    @MainActor
    static func perform(_ action: BlockHeaderChipAction) {
        guard let editor = NSApp.keyWindow?.firstResponder as? EditorTextView,
              editor.performChipActionAtCursor(action) else {
            NSSound.beep()
            return
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

/// Tags menu (W40.tag-rename-suite): rename or merge a subject across every note and extract, near-duplicates, and the
/// renames other apps recorded in the archive. The focused window's sheets (`NotesTagRenameSheets`).
struct TagCommands: Commands {
    @FocusedValue(\.tagSheetAction) private var tags

    var body: some Commands {
        CommandMenu("Tags") {
            Button("Rename Tag\u{2026}") { tags?.open(.rename(from: tags?.selectedSubject, to: "")) }
                .disabled(tags == nil)
            Button("Find Similar Tags\u{2026}") { tags?.open(.similar) }
                .disabled(tags == nil)
            Divider()
            Button("Tag Changes from Other Apps\u{2026}") { tags?.open(.changes) }
                .disabled(tags == nil)
        }
    }
}

struct TagSheetAction {
    /// The first subject of the selected note, to seed Rename Tag….
    var selectedSubject: String?
    let open: @MainActor (NotesTagSheet) -> Void
}

struct TagSheetActionKey: FocusedValueKey {
    typealias Value = TagSheetAction
}

extension FocusedValues {
    var tagSheetAction: TagSheetAction? {
        get { self[TagSheetActionKey.self] }
        set { self[TagSheetActionKey.self] = newValue }
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

struct DuplicateItemAction {
    let perform: @MainActor () -> Void
}

struct DuplicateItemActionKey: FocusedValueKey {
    typealias Value = DuplicateItemAction
}

extension FocusedValues {
    var duplicateItemAction: DuplicateItemAction? {
        get { self[DuplicateItemActionKey.self] }
        set { self[DuplicateItemActionKey.self] = newValue }
    }
}
