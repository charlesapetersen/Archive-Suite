import SwiftUI
import AppKit
import ArchiveCore

/// The reusable 3-pane browsing shell (folder tree │ item list │ detail), instantiated as the
/// Notes window and the Extracts window (06-viewers §1, W6-S1). The tree and item-list panes are
/// placeholders here — W6-S2 swaps in `NotesFolderTreeView`, W6-S3 the item-list table — while the
/// detail pane already hosts the shipped W3 editor (`NoteEditorPane`).
///
/// Persistence (W6-S1): panel widths + the tree-visibility toggle survive relaunch via `@AppStorage`
/// over the `an.*` keys; the window size persists via `NotesAppSettings` (mirrors Reader's DV-1
/// document-window sizing).
struct NotesBrowserView: View {
    let kind: ItemKindShell

    @AppStorage(NotesLayoutSettingsKey.showTree)    private var showingTree = true
    @AppStorage(NotesLayoutSettingsKey.treeWidth)   private var treeWidth   = NotesLayoutSettings.defaultTreeWidth
    @AppStorage(NotesLayoutSettingsKey.detailWidth) private var detailWidth = NotesLayoutSettings.defaultDetailWidth

    @State private var window: NSWindow?
    @State private var didConfigureWindow = false

    var body: some View {
        HStack(spacing: 0) {
            if showingTree {
                SidebarPane(kind: kind)
                    .frame(width: treeWidth)
                    .transition(.move(edge: .leading))
                PanelDivider(width: $treeWidth, panelOnLeft: true,
                             range: NotesLayoutSettings.treeWidthRange, id: "an.divider.tree")
            }
            ItemListPane(kind: kind)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            PanelDivider(width: $detailWidth, panelOnLeft: false,
                         range: NotesLayoutSettings.detailWidthRange, id: "an.divider.detail")
            DetailPane(kind: kind)
                .frame(width: detailWidth)
        }
        .frame(minWidth: 900, minHeight: 560)
        .animation(.easeInOut(duration: 0.18), value: showingTree)
        .background(NotesWindowAccessor { configureWindow($0) })   // restore/remember window size (DV-1)
        .toolbar { toolbar }
        // On close, the current window size becomes the default the next time this window opens.
        .onDisappear { if let w = window { NotesAppSettings.setWindowSize(w.frame.size) } }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                withAnimation { showingTree.toggle() }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help(showingTree ? "Hide Folders" : "Show Folders")
            .accessibilityIdentifier("an.toggleTree")
        }
    }

    /// Restore the saved window frame on first appearance (centered on the active screen); if none
    /// was saved the window keeps its scene default. Runs once per window (guarded), then keeps the
    /// handle so `onDisappear` can persist the final size. Mirrors Reader `configureWindow` (DV-1).
    private func configureWindow(_ window: NSWindow) {
        guard !didConfigureWindow else { return }
        didConfigureWindow = true
        self.window = window
        guard let size = NotesAppSettings.windowSize else { return }
        if abs(window.frame.width - size.width) > 2 || abs(window.frame.height - size.height) > 2 {
            var frame = window.frame
            frame.size = size
            if let vis = (window.screen ?? NSScreen.main)?.visibleFrame {
                frame.origin = CGPoint(x: vis.midX - size.width / 2, y: vis.midY - size.height / 2)
            }
            window.setFrame(frame, display: true)
        }
    }
}

// MARK: - Placeholder panes (replaced in W6-S2 / W6-S3)

/// Left pane — folder tree. Placeholder until `NotesFolderTreeView` lands in W6-S2.
private struct SidebarPane: View {
    let kind: ItemKindShell
    var body: some View { placeholder("Folders") }
}

/// Center pane — item list. Placeholder until the `NotesTableView` list pane lands in W6-S3.
private struct ItemListPane: View {
    let kind: ItemKindShell
    var body: some View { placeholder("Items") }
}

/// Right pane — detail. Already the shipped W3 editor (source-block chips, formatting, Zotero).
private struct DetailPane: View {
    let kind: ItemKindShell
    var body: some View {
        NoteEditorPane()
    }
}

private func placeholder(_ t: String) -> some View {
    ZStack { Color(nsColor: .textBackgroundColor); Text(t).foregroundStyle(.tertiary) }
}
