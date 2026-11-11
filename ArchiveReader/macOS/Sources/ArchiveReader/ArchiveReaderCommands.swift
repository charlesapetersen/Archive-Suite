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
/// (nav vs. document), and are where the keyboard shortcuts are bound (the toolbars are clickable but
/// declare no shortcuts, so nothing double-registers). Names and keys come from `ReaderCommand`.
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
    /// Holds the navigation window's model whichever window is in front, so File ▸ Choose Archive Folder…
    /// can reach it from a document window or with no window open (W40.fix-reader-choose-folder-shortcut).
    let router: DeepLinkRouter
    @AppStorage("ar.showSidebar") private var showingSidebar = true
    @AppStorage("ar.showTagCloud") private var showingTagCloud = false

    private var noReadingPane: Bool { doc == nil || doc?.showingAllPages == true }

    private var noSelection: Bool { nav?.selectedFiles.isEmpty ?? true }
    /// W40.fix-reader-menus-follow-window: the Tags menu follows the window in front. With the navigation
    /// window in front (its preview sheet included) it acts on the list's selection; with a document window
    /// in front, which publishes no `NavigationModel`, on the file that window shows.
    private var docTags: DocumentTagActions? { nav == nil ? documentTags : nil }
    private var noTagTarget: Bool { nav != nil ? noSelection : !(docTags?.canTag ?? false) }
    /// The model the corpus-wide tag sheets (Rename, Find Similar) open in; from a document window they open
    /// over the navigation window, which is brought forward.
    private var tagSheetNav: NavigationModel? { nav ?? docTags?.navigation }
    /// The Inspector in the window in front is open; it names the View menu's Show/Hide Inspector.
    private var inspectorShown: Bool { nav?.showingEditor ?? docTags?.viewer.showingTagEditor ?? false }
    /// No viewer, or a viewer with no find bar (the preview sheet) — see the Find items below.
    private var noFind: Bool { !(doc?.supportsFind ?? false) }
    /// The navigation window is in front with nothing over it, so Find… searches the library.
    private var findSearchesLibrary: Bool { nav.map { !$0.showingPreview } ?? false }

    var body: some Commands {
        // View — panel toggles (placed in the system View menu)
        CommandGroup(before: .sidebar) {
            // Both panels belong to the navigation window, so they are listed only while it is in front
            // (W40.fix-reader-menus-follow-window; owner session reader-1, row 14).
            // ⌃⌘S is the Mac's Show/Hide Sidebar, and the tag cloud takes the T beside it. They were ⌥⌘S and ⌥⌘T
            // until W40.fix-suite-shortcuts; ⌥⌘T is the Mac's Show/Hide Toolbar.
            if nav != nil {
                Button(ReaderCommand.showSidebar.title(showing: showingSidebar)) {
                    showingSidebar.toggle()
                }
                .keyboardShortcut(.showSidebar)
                Button(ReaderCommand.showTagCloud.title(showing: showingTagCloud)) {
                    showingTagCloud.toggle()
                }
                .keyboardShortcut(.showTagCloud)
            }
            // The Inspector (Edit Info until W40.reader-commands-table) beside the list, or beside a document
            // window's file. Named and keyed as Archive Notes' panel is: View ▸ Show/Hide Inspector, ⌥⌘I.
            Button(ReaderCommand.showInspector.title(showing: inspectorShown)) {
                if let nav { nav.showingEditor.toggle() } else { docTags?.editTags() }
            }
            .keyboardShortcut(.showInspector)
            .disabled(nav == nil && !(docTags?.canTag ?? false))
            // Preview's page views, on its keys (W40.reader-page-views), in the document window and the preview
            // sheet alike: one is checked at a time. Choosing the checked one again leaves only the contact
            // sheet, which returns to the page it was opened from.
            if let doc, doc.supportsPageOverview {
                Divider()
                Toggle(ReaderCommand.singlePage.title, isOn: Binding(
                    get: { doc.pageView == .single }, set: { _ in doc.setPageView(.single) }
                ))
                .keyboardShortcut(.singlePage)
                Toggle(ReaderCommand.thumbnails.title, isOn: Binding(
                    get: { doc.pageView == .thumbnails }, set: { _ in doc.setPageView(.thumbnails) }
                ))
                .keyboardShortcut(.thumbnails)
                .disabled(!doc.canShowThumbnails)
                Toggle(ReaderCommand.contactSheet.title, isOn: Binding(
                    get: { doc.showingAllPages }, set: { doc.setShowingAllPages($0) }
                ))
                .keyboardShortcut(.contactSheet)
                .disabled(!doc.canShowAllPages)
                Divider()
            }
            // The source switch applies to the reading panes; tiles always depict PDF pages.
            if let doc {
                Button(ReaderCommand.showJPEG.title(showing: doc.isShowingJPEG)) {
                    doc.toggleImageSource()
                }
                .keyboardShortcut(.showJPEG)
                .disabled(!doc.hasJPEGPartner || doc.showingAllPages)
            }
        }

        // Edit — the two copies of what is on screen sit beside the standard Copy, where a reader looks for
        // them (owner session reader-1, row 15; they were under Document until W40.fix-reader-edit-menu-copy).
        // No "Copy" here: ⌘C is the standard Edit ▸ Copy, which reaches the viewer through the responder
        // chain (`ReaderPDFView.copy(_:)`). A second ⌘C matched first and copied the PDF selection with the
        // caret in the find field (W48.reader-copy-shortcut).
        CommandGroup(after: .pasteboard) {
            Divider()
            // Owner, 2026-11-08: ⇧⌘C cleans prose; Selection ▸ Copy Link(s) takes ⌥⌘C so
            // both commands keep distinct shortcuts while the preview sheet is open.
            Button(ReaderCommand.copyCleaned.title) { doc?.copySelection() }
                .keyboardShortcut(.copyCleaned).disabled(noReadingPane)
            // ⌥⌘L: ⌘L is Focus Tag Filter and ⇧⌘L Copy Archive Link(s), which the preview sheet leaves enabled
            // beside this one, so the page link takes the remaining L.
            Button(ReaderCommand.copyPageLink.title) {
                if let doc, let linkContext { doc.copyArchivePageLink(context: linkContext) }
            }
            .keyboardShortcut(.copyPageLink)
            .disabled(noReadingPane || linkContext?.target == nil)
        }

        // File
        CommandGroup(replacing: .newItem) {
            // Enabled from every Reader window and with none open: the owner pressed ⇧⌘O over a document
            // window and nothing happened (notes-1, row 1). The library window comes forward for the panel.
            Button(ReaderCommand.chooseFolder.title) {
                if let nav { nav.chooseRoot() } else {
                    router.requestChooseRoot { openWindow(id: WindowID.navigation) }
                }
            }
            .keyboardShortcut(.chooseFolder)
            // Explicit recovery even though FSEvents normally keeps the library live. ⌘⌥R because
            // ⌘R is Mark Read.
            Button(ReaderCommand.rescan.title) { nav?.rescan() }
                .keyboardShortcut(.rescan)
                .disabled(nav == nil)
            Button(ReaderCommand.saveSearch.title) { nav?.showingSaveDialog = true }
                .disabled(nav == nil)
        }

        // Selection (nav window)
        CommandMenu("Selection") {
            Button(ReaderCommand.open.title) { openSelection?() }
                .keyboardShortcut(.open)
                .disabled(openSelection == nil || noSelection)
            Button(ReaderCommand.preview.title) { nav?.showingPreview = true }
                .keyboardShortcut(.preview)
                .disabled(noSelection)
            Button(ReaderCommand.revealInFinder.title) { nav?.revealInFinder() }
                .keyboardShortcut(.revealInFinder)
                .disabled(noSelection)
            Button(ReaderCommand.copyLinks.title) { nav?.copyLinks() }
                .keyboardShortcut(.copyLinks)
                .disabled(noSelection)
            Button(ReaderCommand.copyArchiveLinks.title) { nav?.copyArchiveLinks() }
                .keyboardShortcut(.copyArchiveLinks)
                .disabled(noSelection)
            Divider()
            Button(ReaderCommand.selectRun.title) { nav?.extendSelectionToDocumentRun() }
                .disabled(noSelection)
            Divider()
            // G4 keyboard triage. Bare ] / [ also work when the list has key focus (text-field-safe);
            // the ⌘ accelerators are the discoverable menu equivalents.
            Button(ReaderCommand.nextUnread.title) { nav?.selectNextUnread() }
                .keyboardShortcut(.nextUnread).disabled(nav == nil)
            Button(ReaderCommand.previousUnread.title) { nav?.selectPreviousUnread() }
                .keyboardShortcut(.previousUnread).disabled(nav == nil)
        }

        // Tags — the list's selection, or the document window's open file (`docTags`)
        CommandMenu("Tags") {
            Button(ReaderCommand.markRead.title) { if let nav { nav.mark(.read) } else { docTags?.mark(.read) } }
                .keyboardShortcut(.markRead).disabled(noTagTarget)
            Button(ReaderCommand.markUnread.title) { if let nav { nav.mark(.unread) } else { docTags?.mark(.unread) } }
                .keyboardShortcut(.markUnread).disabled(noTagTarget)
            // G4 one-key triage: mark Read (via TagWriter, undoable) then jump to the next unread.
            // Bare \ also works when the list has key focus (text-field-safe).
            Button(ReaderCommand.markReadAndNext.title) {
                if let nav { nav.markReadAndAdvance() } else { docTags?.markReadAndNextUnread() }
            }
            .keyboardShortcut(.markReadAndNext).disabled(noTagTarget)
            Button(ReaderCommand.renameTag.title) {
                if nav == nil { openWindow(id: WindowID.navigation) }
                tagSheetNav?.beginRenameTag()
            }
            .disabled(tagSheetNav == nil)
            Button(ReaderCommand.findSimilarTags.title) {
                if nav == nil { openWindow(id: WindowID.navigation) }
                tagSheetNav?.showingSimilarTags = true
            }
            .disabled(tagSheetNav == nil)
            Button(ReaderCommand.toggleFlag.title) { if let nav { nav.toggleFlagSelection() } else { docTags?.toggleFlag() } }
                .keyboardShortcut(.toggleFlag).disabled(noTagTarget)
            Divider()
            Button(ReaderCommand.undoTagChange.title) { if let nav { nav.undoLast() } else { docTags?.undo() } }
                .keyboardShortcut(.undoTagChange)
                .disabled(nav != nil ? (nav?.undoDepth ?? 0) == 0 : !(docTags?.canUndo ?? false))
            Button(ReaderCommand.redoTagChange.title) { if let nav { nav.redoLast() } else { docTags?.redo() } }
                .keyboardShortcut(.redoTagChange)
                .disabled(nav != nil ? (nav?.redoDepth ?? 0) == 0 : !(docTags?.canRedo ?? false))
        }

        // View (nav window): sorting + clearing
        CommandMenu("Sort & Filter") {
            Button("Sort by Document Date") { nav?.sort = sortBy(.date) }.disabled(nav == nil)
            Button("Sort by File Name") { nav?.sort = sortBy(.name) }.disabled(nav == nil)
            Button("Sort by Quality") { nav?.sort = sortBy(.quality) }.disabled(nav == nil)
            Button("Sort by Read State") { nav?.sort = sortBy(.readState) }.disabled(nav == nil)
            Button("Sort by Flag") { nav?.sort = sortBy(.flag) }.disabled(nav == nil)
            Button("Sort by Needs Attention") { nav?.sort = sortBy(.attention) }.disabled(nav == nil)
            Divider()
            Button(ReaderCommand.clearAll.title) { nav?.clearUserFilters() }
            .keyboardShortcut(.clearAll)
            .disabled(nav == nil)
            Divider()
            Button(ReaderCommand.focusTagFilter.title) { nav?.requestFocusTagFilter() }
                .keyboardShortcut(.focusTagFilter).disabled(nav == nil)
            Button(ReaderCommand.searchOCRText.title) { nav?.requestFocusSearch() }
                .keyboardShortcut(.searchOCRText).disabled(nav == nil)
            Button(ReaderCommand.advancedSearch.title) { nav?.openAdvancedSearch() }
                .keyboardShortcut(.advancedSearch).disabled(nav == nil)
        }

        // Document (document window). ↑/↓ ALONE scroll the focused page (handled by the PDF view, not
        // bound here). The focused pane (⌘⌥←/→) is what ⌘+/⌘− zoom. A menu item holds one shortcut, so
        // ⌘= and the older ⌘↑/⌘↓ are answered by the panes themselves (`ReaderPDFView.performKeyEquivalent`).
        CommandMenu("Document") {
            Button(ReaderCommand.previousPage.title) { doc?.previous() }
                .keyboardShortcut(.previousPage).disabled(doc == nil)
            Button(ReaderCommand.nextPage.title) { doc?.next() }
                .keyboardShortcut(.nextPage).disabled(doc == nil)
            Divider()
            Button(ReaderCommand.focusImagePane.title) { doc?.focusPane(.left) }
                .keyboardShortcut(.focusImagePane).disabled(noReadingPane)
            Button(ReaderCommand.focusTextPane.title) { doc?.focusPane(.right) }
                .keyboardShortcut(.focusTextPane).disabled(noReadingPane)
            Divider()
            Button(ReaderCommand.zoomIn.title) { doc?.zoomFocusedIn() }
                .keyboardShortcut(.zoomIn).disabled(noReadingPane)
            Button(ReaderCommand.zoomOut.title) { doc?.zoomFocusedOut() }
                .keyboardShortcut(.zoomOut).disabled(noReadingPane)
            Button(ReaderCommand.fitPage.title) { doc?.fitFocused() }
                .keyboardShortcut(.fitPage).disabled(noReadingPane)
            Divider()
            // W40.reader-view-rotate: a turn is a view of the image page, remembered in the Reader's own store; the
            // file is never changed. In the preview sheet too, whose model is published to the scene.
            Button(ReaderCommand.rotateLeft.title) { doc?.rotateLeft() }
                .keyboardShortcut(.rotateLeft).disabled(!(doc?.canRotate ?? false))
            Button(ReaderCommand.rotateRight.title) { doc?.rotateRight() }
                .keyboardShortcut(.rotateRight).disabled(!(doc?.canRotate ?? false))
            Button(ReaderCommand.resetRotation.title) { doc?.resetRotation() }
                .disabled(!(doc?.canRotate ?? false) || !(doc?.isRotated ?? false))
            Divider()
            // These three need MORE than a published viewer: they need one whose view renders a find bar.
            // The preview sheet publishes a model so zoom/paging/copy/page-link reach it (W26.previewzoom),
            // which enables every `doc == nil` item (here and under Edit) — but it has no find bar and no way to type a
            // query, so ⌘F looked live and did nothing there (W26.previewzoom-fu1).
            // ⌘F is Find in every window (W40.fix-suite-shortcuts): with the navigation window in front, and no
            // preview sheet over it, it is Search OCR Text, as ⌥⌘F is. The preview sheet still has no find.
            Button(ReaderCommand.find.title) { if !noFind { doc?.beginFind() } else { nav?.requestFocusSearch() } }
                .keyboardShortcut(.find).disabled(noFind && !findSearchesLibrary)
            Button(ReaderCommand.findNext.title) { doc?.showingFind = true; doc?.findNext() }
                .keyboardShortcut(.findNext).disabled(noFind)
            Button(ReaderCommand.findPrevious.title) { doc?.showingFind = true; doc?.findPrevious() }
                .keyboardShortcut(.findPrevious).disabled(noFind)
            Divider()
            Button("Zoom In (Image)") { doc?.leftController.zoomIn() }.disabled(noReadingPane)
            Button("Zoom Out (Image)") { doc?.leftController.zoomOut() }.disabled(noReadingPane)
            Button("Zoom In (Text)") { doc?.zoomTextIn() }.disabled(noReadingPane)
            Button("Zoom Out (Text)") { doc?.zoomTextOut() }.disabled(noReadingPane)
        }
    }

    private func sortBy(_ field: SortField) -> [ARSortDescriptor] {
        [ARSortDescriptor(field: field, ascending: true), ARSortDescriptor(field: .name, ascending: true)]
    }
}
