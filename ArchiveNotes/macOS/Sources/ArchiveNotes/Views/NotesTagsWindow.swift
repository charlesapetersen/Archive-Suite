import SwiftUI
import AppKit
import ArchiveCore
import ArchiveCoreUI

/// Window ▸ Tags (W40.tag-window-notes): the suite's shared Tags window (ArchiveCoreUI `TagsWindowView`) over every
/// note and extract. Each subject in use with how many carry it; Rename, Merge and Remove run through
/// `NotesModel.applyTagsWindowPlan` (front matter, then the Finder mirror; one Undo in this window; recorded for the
/// other apps); Show Notes filters the Archive Notes window to the tag. The window itself writes nothing.
struct NotesTagsWindow: View {
    @EnvironmentObject private var model: NotesModel

    var body: some View {
        NotesTagsWindowContent(model: model, tags: model.tagsWindow)
    }
}

private struct NotesTagsWindowContent: View {
    @ObservedObject var model: NotesModel
    let tags: TagsWindowModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        TagsWindowView(model: tags) {
            OtherAppsChanges(model: model) {
                model.pendingTagSheet = .changes
                openWindow(id: NotesWindowID.notes)
            }
        }
        // Edit ▸ Undo reads the NSWindow's undo manager, not the environment's (as the browser's delete does).
        .background(NotesWindowAccessor { [model] window in model.tagsWindowUndo = window.undoManager })
        // The list follows the notes while the window shows; `$allItems` delivers the new list.
        .onReceive(model.$allItems) { [model] items in model.refreshTagsWindow(items) }
        .onAppear { [model, tags, openWindow] in
            tags.showItems = { [weak model] entry in
                model?.pendingShowTag = entry.name
                openWindow(id: NotesWindowID.notes)
            }
        }
    }
}

/// Tag Changes from Other Apps, as a section of the window: how many wait, and the Archive Notes window's sheet that
/// applies them.
private struct OtherAppsChanges: View {
    @ObservedObject var model: NotesModel
    let review: () -> Void

    var body: some View {
        let waiting = model.tagChangeOffers.count
        if waiting > 0 {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
                Text(waiting == 1 ? "1 tag change from another app is waiting."
                                  : "\(waiting) tag changes from other apps are waiting.")
                Spacer()
                Button("Review…", action: review)
                    .accessibilityIdentifier("an.tagsWindow.tagChanges")
            }
            .padding(10)
            Divider()
        }
    }
}
