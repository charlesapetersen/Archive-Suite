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

    private var noSelection: Bool { nav?.selection.isEmpty ?? true }

    var body: some Commands {
        // File
        CommandGroup(replacing: .newItem) {
            Button("Choose Archive Folder…") { nav?.chooseRoot() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
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
            Button("Copy Link(s)") { nav?.copyLinks() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(noSelection)
            Divider()
            Button("Select Document Run") { nav?.extendSelectionToDocumentRun() }
                .disabled(noSelection)
        }

        // Tags (nav window)
        CommandMenu("Tags") {
            Button("Mark Read") { nav?.mark(.read) }
                .keyboardShortcut("r", modifiers: .command).disabled(noSelection)
            Button("Mark Unread") { nav?.mark(.unread) }
                .keyboardShortcut("u", modifiers: .command).disabled(noSelection)
            Button("Edit Tags…") { nav?.showingEditor = true }
                .keyboardShortcut("i", modifiers: .command).disabled(noSelection)
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
            Button("Clear Filters & Search") {
                nav?.filter = LibraryFilter()
                nav?.fullTextQuery = ""
                nav?.runFullTextSearch()
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(nav == nil)
        }

        // Document (document window)
        CommandMenu("Document") {
            Button("Copy Text") { doc?.copySelection() }
                .keyboardShortcut("c", modifiers: .command).disabled(doc == nil)
            Button("Find…") { doc?.showingFind = true }
                .keyboardShortcut("f", modifiers: .command).disabled(doc == nil)
            Divider()
            Button("Zoom In (Image)") { doc?.leftController.zoomIn() }.disabled(doc == nil)
            Button("Zoom Out (Image)") { doc?.leftController.zoomOut() }.disabled(doc == nil)
            Button("Fit Image") { doc?.leftController.fit() }.disabled(doc == nil)
            Divider()
            Button("Zoom In (Text)") { doc?.rightController.zoomIn() }.disabled(doc == nil)
            Button("Zoom Out (Text)") { doc?.rightController.zoomOut() }.disabled(doc == nil)
            Button("Fit Text") { doc?.rightController.fit() }.disabled(doc == nil)
        }
    }

    private func sortBy(_ field: SortField) -> [ARSortDescriptor] {
        [ARSortDescriptor(field: field, ascending: true), ARSortDescriptor(field: .name, ascending: true)]
    }
}
