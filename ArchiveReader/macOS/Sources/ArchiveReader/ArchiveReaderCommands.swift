import SwiftUI

// A focused closure the nav window publishes so the "Open" menu command can open a document window
// (which needs the view's openWindow environment action).
struct OpenSelectionKey: FocusedValueKey { typealias Value = () -> Void }
extension FocusedValues {
    var openSelection: (() -> Void)? {
        get { self[OpenSelectionKey.self] }
        set { self[OpenSelectionKey.self] = newValue }
    }
}

/// The app's menu bar. Commands act on whichever window is frontmost via `@FocusedObject`
/// (nav vs. document), and are the single source of the keyboard shortcuts (the toolbars are
/// clickable but no longer declare these shortcuts, so nothing double-registers).
struct ArchiveReaderCommands: Commands {
    @FocusedObject private var nav: NavigationModel?
    @FocusedObject private var doc: DocumentViewerModel?
    @FocusedValue(\.openSelection) private var openSelection: (() -> Void)?
    // W23.m4: the root + marker a page link needs, published by EVERY window that shows a document.
    // Reading it as a focused value (instead of reaching through `nav`) is what makes
    // "Copy Archive Link to This Page" work in the document window, where there is no NavigationModel.
    @FocusedValue(\.archiveLinkContext) private var linkContext: ArchiveLinkContext?
    @FocusedValue(\.documentTagActions) private var documentTags: DocumentTagActions?
    @Environment(\.openWindow) private var openWindow
    @AppStorage("ar.showSidebar") private var showingSidebar = true
    @AppStorage("ar.showTagCloud") private var showingTagCloud = false

    private var noSelection: Bool { nav?.selectedFiles.isEmpty ?? true }
    /// W40.fix-reader-menus-follow-window: the Tags menu follows the window in front. With the navigation
    /// window in front (its preview sheet included) it acts on the list's selection; with a document window
    /// in front, which publishes no `NavigationModel`, on the file that window shows.
    private var docTags: DocumentTagActions? { nav == nil ? documentTags : nil }
    private var noTagTarget: Bool { nav != nil ? noSelection : !(docTags?.canTag ?? false) }
    /// The model the corpus-wide tag sheets (Rename, Find Similar) open in; from a document window they open
    /// over the navigation window, which is brought forward.
    private var tagSheetNav: NavigationModel? { nav ?? docTags?.navigation }
    /// No viewer, or a viewer with no find bar (the preview sheet) — see the Find items below.
    private var noFind: Bool { !(doc?.supportsFind ?? false) }

    var body: some Commands {
        // View — panel toggles (placed in the system View menu)
        CommandGroup(before: .sidebar) {
            // Both panels belong to the navigation window, so they are listed only while it is in front
            // (W40.fix-reader-menus-follow-window; owner session reader-1, row 14).
            if nav != nil {
                Button(showingSidebar ? "Hide Sidebar" : "Show Sidebar") {
                    showingSidebar.toggle()
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                Button(showingTagCloud ? "Hide Tag Cloud" : "Show Tag Cloud") {
                    showingTagCloud.toggle()
                }
                .keyboardShortcut("t", modifiers: [.command, .option])
            }
            // W40.fix-reader-jpeg-toolbar: listed whenever a document is open, disabled without a JPEG
            // original, so it can be found; the document toolbar's PDF / JPEG switch says why.
            if let doc {
                Button(doc.isShowingJPEG ? "Show PDF Image" : "Show JPEG Image") {
                    doc.toggleImageSource()
                }
                .keyboardShortcut("j", modifiers: [.command, .option])
                .disabled(!doc.hasJPEGPartner)
            }
        }

        // Edit — the two copies of what is on screen sit beside the standard Copy, where a reader looks for
        // them (owner session reader-1, row 15; they were under Document until W40.fix-reader-edit-menu-copy).
        // No "Copy" here: ⌘C is the standard Edit ▸ Copy, which reaches the viewer through the responder
        // chain (`ReaderPDFView.copy(_:)`). A second ⌘C matched first and copied the PDF selection with the
        // caret in the find field (W48.reader-copy-shortcut).
        CommandGroup(after: .pasteboard) {
            Divider()
            // ⌥⌘C, not ⇧⌘C: ⇧⌘C is Selection ▸ Copy Link(s), and with the preview sheet up both items are
            // enabled in the nav window at once (W40.fix-reader-visual-polish).
            Button("Copy Cleaned for Prose") { doc?.copySelection() }
                .keyboardShortcut("c", modifiers: [.command, .option]).disabled(doc == nil)
            // ⌥⌘L: ⌘L is Focus Tag Filter and ⇧⌘L Copy Archive Link(s), which the preview sheet leaves enabled
            // beside this one, so the page link takes the remaining L.
            Button("Copy Archive Link to This Page") {
                if let doc, let linkContext { doc.copyArchivePageLink(context: linkContext) }
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
            .disabled(doc == nil || linkContext?.target == nil)
        }

        // File
        CommandGroup(replacing: .newItem) {
            Button("Choose Archive Folder…") { nav?.chooseRoot() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(nav == nil)
            // Explicit recovery even though FSEvents normally keeps the library live. ⌘⌥R because
            // ⌘R is Mark Read.
            Button("Rescan Archive Folder") { nav?.rescan() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(nav == nil)
            Button("Save Current Search…") { nav?.showingSaveDialog = true }
                .disabled(nav == nil)
        }

        // Selection (nav window)
        CommandMenu("Selection") {
            Button("Open in Document Window") { openSelection?() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(openSelection == nil || noSelection)
            Button("Preview") { nav?.showingPreview = true }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(noSelection)
            Button("Reveal in Finder") { nav?.revealInFinder() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(noSelection)
            Button("Copy Link(s)") { nav?.copyLinks() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(noSelection)
            Button("Copy Archive Link(s)") { nav?.copyArchiveLinks() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(noSelection)
            Divider()
            Button("Select Document Run") { nav?.extendSelectionToDocumentRun() }
                .disabled(noSelection)
            Divider()
            // G4 keyboard triage. Bare ] / [ also work when the list has key focus (text-field-safe);
            // the ⌘ accelerators are the discoverable menu equivalents.
            Button("Next Unread") { nav?.selectNextUnread() }
                .keyboardShortcut("]", modifiers: .command).disabled(nav == nil)
            Button("Previous Unread") { nav?.selectPreviousUnread() }
                .keyboardShortcut("[", modifiers: .command).disabled(nav == nil)
        }

        // Tags — the list's selection, or the document window's open file (`docTags`)
        CommandMenu("Tags") {
            Button("Mark Read") { if let nav { nav.mark(.read) } else { docTags?.mark(.read) } }
                .keyboardShortcut("r", modifiers: .command).disabled(noTagTarget)
            Button("Mark Unread") { if let nav { nav.mark(.unread) } else { docTags?.mark(.unread) } }
                .keyboardShortcut("u", modifiers: .command).disabled(noTagTarget)
            // G4 one-key triage: mark Read (via TagWriter, undoable) then jump to the next unread.
            // Bare \ also works when the list has key focus (text-field-safe).
            Button("Mark Read & Next Unread") {
                if let nav { nav.markReadAndAdvance() } else { docTags?.markReadAndNextUnread() }
            }
            .keyboardShortcut("m", modifiers: [.command, .shift]).disabled(noTagTarget)
            Button("Edit Info…") { if let nav { nav.showingEditor = true } else { docTags?.editTags() } }
                .keyboardShortcut("i", modifiers: .command).disabled(noTagTarget)
            Button("Rename Tag…") {
                if nav == nil { openWindow(id: WindowID.navigation) }
                tagSheetNav?.beginRenameTag()
            }
            .disabled(tagSheetNav == nil)
            Button("Find Similar Tags…") {
                if nav == nil { openWindow(id: WindowID.navigation) }
                tagSheetNav?.showingSimilarTags = true
            }
            .disabled(tagSheetNav == nil)
            Button("Toggle Flag") { if let nav { nav.toggleFlagSelection() } else { docTags?.toggleFlag() } }
                .keyboardShortcut("f", modifiers: [.command, .shift]).disabled(noTagTarget)
            Divider()
            Button("Undo Tag Change") { if let nav { nav.undoLast() } else { docTags?.undo() } }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(nav != nil ? (nav?.undoDepth ?? 0) == 0 : !(docTags?.canUndo ?? false))
            Button("Redo Tag Change") { if let nav { nav.redoLast() } else { docTags?.redo() } }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(nav != nil ? (nav?.redoDepth ?? 0) == 0 : !(docTags?.canRedo ?? false))
        }

        // View (nav window): sorting + clearing
        CommandMenu("Sort & Filter") {
            Button("Sort by Document Date") { nav?.sort = sortBy(.date) }.disabled(nav == nil)
            Button("Sort by File Name") { nav?.sort = sortBy(.name) }.disabled(nav == nil)
            Button("Sort by Quality") { nav?.sort = sortBy(.quality) }.disabled(nav == nil)
            Button("Sort by Read State") { nav?.sort = sortBy(.readState) }.disabled(nav == nil)
            Divider()
            Button("Clear Filters & Search") { nav?.clearUserFilters() }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(nav == nil)
            Divider()
            Button("Focus Tag Filter") { nav?.requestFocusTagFilter() }
                .keyboardShortcut("l", modifiers: .command).disabled(nav == nil)
            Button("Search OCR Text") { nav?.requestFocusSearch() }
                .keyboardShortcut("f", modifiers: [.command, .option]).disabled(nav == nil)
        }

        // Document (document window). ↑/↓ ALONE scroll the focused page (handled by the PDF view, not
        // bound here). The focused pane (⌘⌥←/→) is what ⌘+/⌘− zoom. A menu item holds one shortcut, so
        // ⌘= and the older ⌘↑/⌘↓ are answered by the panes themselves (`ReaderPDFView.performKeyEquivalent`).
        CommandMenu("Document") {
            Button("Previous Page in Segment") { doc?.previous() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .shift]).disabled(doc == nil)
            Button("Next Page in Segment") { doc?.next() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .shift]).disabled(doc == nil)
            Divider()
            Button("Focus Image Page") { doc?.focusPane(.left) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option]).disabled(doc == nil)
            Button("Focus Text Page") { doc?.focusPane(.right) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option]).disabled(doc == nil)
            Divider()
            Button("Zoom In") { doc?.zoomFocusedIn() }
                .keyboardShortcut("+", modifiers: .command).disabled(doc == nil)
            Button("Zoom Out") { doc?.zoomFocusedOut() }
                .keyboardShortcut("-", modifiers: .command).disabled(doc == nil)
            Button("Fit Page") { doc?.fitFocused() }
                .keyboardShortcut("0", modifiers: .command).disabled(doc == nil)
            Divider()
            // These three need MORE than a published viewer: they need one whose view renders a find bar.
            // The preview sheet publishes a model so zoom/paging/copy/page-link reach it (W26.previewzoom),
            // which enables every `doc == nil` item (here and under Edit) — but it has no find bar and no way to type a
            // query, so ⌘F looked live and did nothing there (W26.previewzoom-fu1).
            Button("Find…") { doc?.beginFind() }
                .keyboardShortcut("f", modifiers: .command).disabled(noFind)
            Button("Find Next") { doc?.showingFind = true; doc?.findNext() }
                .keyboardShortcut("g", modifiers: .command).disabled(noFind)
            Button("Find Previous") { doc?.showingFind = true; doc?.findPrevious() }
                .keyboardShortcut("g", modifiers: [.command, .shift]).disabled(noFind)
            Divider()
            Button("Zoom In (Image)") { doc?.leftController.zoomIn() }.disabled(doc == nil)
            Button("Zoom Out (Image)") { doc?.leftController.zoomOut() }.disabled(doc == nil)
            Button("Zoom In (Text)") { doc?.zoomTextIn() }.disabled(doc == nil)
            Button("Zoom Out (Text)") { doc?.zoomTextOut() }.disabled(doc == nil)
        }
    }

    private func sortBy(_ field: SortField) -> [ARSortDescriptor] {
        [ARSortDescriptor(field: field, ascending: true), ARSortDescriptor(field: .name, ascending: true)]
    }
}
