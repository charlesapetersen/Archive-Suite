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
    @FocusedValue(\.archiveLinkTarget) private var linkTarget: ArchiveLinkTarget?
    @AppStorage("ar.showSidebar") private var showingSidebar = true
    @AppStorage("ar.showTagCloud") private var showingTagCloud = false

    private var noSelection: Bool { nav?.selection.isEmpty ?? true }

    var body: some Commands {
        // View — panel toggles (placed in the system View menu)
        CommandGroup(before: .sidebar) {
            Button(showingSidebar ? "Hide Sidebar" : "Show Sidebar") {
                showingSidebar.toggle()
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            Button(showingTagCloud ? "Hide Tag Cloud" : "Show Tag Cloud") {
                showingTagCloud.toggle()
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
        }

        // File
        CommandGroup(replacing: .newItem) {
            Button("Choose Archive Folder…") { nav?.chooseRoot() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(nav == nil)
            // W26: with Spotlight's live `DidUpdate` gone and the FSEvents watcher still to come, this
            // is the only way to pick up an external change. ⌘⌥R because ⌘R is Mark Read.
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

        // Tags (nav window)
        CommandMenu("Tags") {
            Button("Mark Read") { nav?.mark(.read) }
                .keyboardShortcut("r", modifiers: .command).disabled(noSelection)
            Button("Mark Unread") { nav?.mark(.unread) }
                .keyboardShortcut("u", modifiers: .command).disabled(noSelection)
            // G4 one-key triage: mark Read (via TagWriter, undoable) then jump to the next unread.
            // Bare \ also works when the list has key focus (text-field-safe).
            Button("Mark Read & Next Unread") { nav?.markReadAndAdvance() }
                .keyboardShortcut("m", modifiers: [.command, .shift]).disabled(noSelection)
            Button("Edit Tags…") { nav?.showingEditor = true }
                .keyboardShortcut("i", modifiers: .command).disabled(noSelection)
            Button("Rename Tag…") { nav?.beginRenameTag() }
                .disabled(nav == nil)
            Button("Find Similar Tags…") { nav?.showingSimilarTags = true }
                .disabled(nav == nil)
            Button("Toggle Flag") { nav?.toggleFlagSelection() }
                .keyboardShortcut("f", modifiers: [.command, .shift]).disabled(noSelection)
            Divider()
            Button("Undo Tag Change") { nav?.undoLast() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(nav == nil || (nav?.undoDepth ?? 0) == 0)
        }

        // View (nav window): sorting + clearing
        CommandMenu("Sort & Filter") {
            Button("Sort by Document Date") { nav?.sort = sortBy(.date) }.disabled(nav == nil)
            Button("Sort by File Name") { nav?.sort = sortBy(.name) }.disabled(nav == nil)
            Button("Sort by Priority") { nav?.sort = sortBy(.priority) }.disabled(nav == nil)
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
        // bound here). The focused pane (⌘⌥←/→) is what ⌘↑/⌘↓ zoom.
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
                .keyboardShortcut(.upArrow, modifiers: .command).disabled(doc == nil)
            Button("Zoom Out") { doc?.zoomFocusedOut() }
                .keyboardShortcut(.downArrow, modifiers: .command).disabled(doc == nil)
            Button("Fit Page") { doc?.fitFocused() }
                .keyboardShortcut("0", modifiers: .command).disabled(doc == nil)
            Divider()
            Button("Copy Archive Link to This Page") {
                if let doc, let linkTarget { doc.copyArchivePageLink(target: linkTarget) }
            }
            .disabled(doc == nil || linkTarget == nil)
            Button("Copy") { doc?.copyPlainSelection() }
                .keyboardShortcut("c", modifiers: .command).disabled(doc == nil)
            Button("Copy Cleaned for Prose") { doc?.copySelection() }
                .keyboardShortcut("c", modifiers: [.command, .shift]).disabled(doc == nil)
            Button("Find…") { doc?.showingFind = true }
                .keyboardShortcut("f", modifiers: .command).disabled(doc == nil)
            Button("Find Next") { doc?.showingFind = true; doc?.findNext() }
                .keyboardShortcut("g", modifiers: .command).disabled(doc == nil)
            Button("Find Previous") { doc?.showingFind = true; doc?.findPrevious() }
                .keyboardShortcut("g", modifiers: [.command, .shift]).disabled(doc == nil)
            Divider()
            Button("Zoom In (Image)") { doc?.leftController.zoomIn() }.disabled(doc == nil)
            Button("Zoom Out (Image)") { doc?.leftController.zoomOut() }.disabled(doc == nil)
            Button("Zoom In (Text)") { doc?.rightController.zoomIn() }.disabled(doc == nil)
            Button("Zoom Out (Text)") { doc?.rightController.zoomOut() }.disabled(doc == nil)
        }
    }

    private func sortBy(_ field: SortField) -> [ARSortDescriptor] {
        [ARSortDescriptor(field: field, ascending: true), ARSortDescriptor(field: .name, ascending: true)]
    }
}
