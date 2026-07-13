import SwiftUI
import AppKit
import ArchiveCore

/// The reusable 3-pane browsing shell (folder tree │ item list │ detail), instantiated as the
/// Notes window and the Extracts window (06-viewers §1, W6-S1). W6-S2 swapped in the folder tree;
/// W6-S3 swaps in the item-list table (`NotesTableView`) + kind segmented control; the detail pane
/// hosts the shipped W3 editor (`NoteEditorPane`) with a selected-item header.
///
/// The shared `NotesModel` (org graph + item source, one instance for both windows) is passed in from
/// `ArchiveNotesApp`; each window owns a private `NotesNavigationModel` (@StateObject) seeded with its
/// default kind, so the two windows differ by kind/sort/selection while reading one item source.
///
/// Persistence (W6-S1): panel widths + tree-visibility survive relaunch via `@AppStorage`; window size
/// via `NotesAppSettings`; hidden item-list columns via `NotesAppSettings.hiddenColumns` (W6-S3).
struct NotesBrowserView: View {
    let kind: ItemKindShell

    /// The shared UI façade (folder tree + scope + item source), passed from the app.
    @ObservedObject private var model: NotesModel
    /// Per-window item-list state (kind filter, sort, selection, displayed list).
    @StateObject private var nav: NotesNavigationModel

    @AppStorage(NotesLayoutSettingsKey.showTree)    private var showingTree = true
    @AppStorage(NotesLayoutSettingsKey.treeWidth)   private var treeWidth   = NotesLayoutSettings.defaultTreeWidth
    @AppStorage(NotesLayoutSettingsKey.detailWidth) private var detailWidth = NotesLayoutSettings.defaultDetailWidth

    @State private var window: NSWindow?
    @State private var didConfigureWindow = false

    init(kind: ItemKindShell, model: NotesModel) {
        self.kind = kind
        self._model = ObservedObject(wrappedValue: model)
        self._nav = StateObject(wrappedValue: NotesNavigationModel(model: model, defaultKind: kind))
    }

    var body: some View {
        HStack(spacing: 0) {
            if showingTree {
                NotesFolderTreeView(model: model)
                    .frame(width: treeWidth)
                    .transition(.move(edge: .leading))
                PanelDivider(width: $treeWidth, panelOnLeft: true,
                             range: NotesLayoutSettings.treeWidthRange, id: "an.divider.tree")
            }
            ItemListPane(nav: nav)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            PanelDivider(width: $detailWidth, panelOnLeft: false,
                         range: NotesLayoutSettings.detailWidthRange, id: "an.divider.detail")
            DetailPane(nav: nav)
                .frame(width: detailWidth)
        }
        .frame(minWidth: 900, minHeight: 560)
        .animation(.easeInOut(duration: 0.18), value: showingTree)
        .background(NotesWindowAccessor { configureWindow($0) })   // restore/remember window size (DV-1)
        .task { await model.bootstrap() }   // open the store + load organization + items (idempotent)
        .toolbar { toolbar }
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

    /// Restore the saved window frame on first appearance (centered on the active screen). Runs once
    /// per window (guarded), then keeps the handle so `onDisappear` persists the final size (DV-1).
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

// MARK: - Item-list pane (W6-S3)

/// Center pane: kind segmented control (notes / extracts / both) above the virtualized item table.
private struct ItemListPane: View {
    @ObservedObject var nav: NotesNavigationModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Kind", selection: $nav.kindFilter) {
                    Text("Notes").tag(KindFilter.notes)
                    Text("Extracts").tag(KindFilter.extracts)
                    Text("Both").tag(KindFilter.both)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)
                .accessibilityIdentifier("an.list.kind")
                Spacer()
                Text("\(nav.displayed.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Items shown")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()
            NotesTableView(
                model: nav,
                selection: $nav.selection,
                onDoubleClick: { /* focus/open in detail — dedicated editor window is a future step */ },
                buildContextMenu: { _ in nil }   // context menu accretes in W6-S4..S7 (open/link/delete/…)
            )
            .accessibilityIdentifier("an.list.table")
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: - Detail pane

/// Right pane: a compact header for the currently-selected item above the shipped W3 editor. The
/// header is the visible "selection → detail" signal (W6-S3). Wiring the editor to load + autosave the
/// selected note's Markdown via `NoteStore` is the remaining detail-integration step (flagged to
/// Morning Review); the editor below is the existing (not-yet-persistence-wired) note editor.
private struct DetailPane: View {
    @ObservedObject var nav: NotesNavigationModel

    var body: some View {
        VStack(spacing: 0) {
            selectedHeader
            Divider()
            NoteEditorPane()
        }
    }

    @ViewBuilder private var selectedHeader: some View {
        if let item = nav.selectedSummary {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: item.kind == .extract ? "quote.opening" : "doc.text")
                        .foregroundStyle(.secondary)
                    Text(item.title.isEmpty ? "Untitled" : item.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                HStack(spacing: 10) {
                    if let d = item.displayDate { Label(d, systemImage: "calendar").labelStyle(.titleAndIcon) }
                    if item.quality != nil { Text(item.qualityStars).foregroundStyle(.yellow) }
                    if !item.authors.isEmpty {
                        Label(item.authors.joined(separator: ", "), systemImage: "person")
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .accessibilityIdentifier("an.detail.header")
        } else {
            Text(nav.selection.count > 1 ? "\(nav.selection.count) items selected" : "No note selected")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
    }
}
